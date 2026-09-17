import AVFoundation
import Foundation
import SongGraph
import Testing
@testable import Instrument

/// Offline tests for the voice sampler. Everything renders through `AVAudioEngine`'s manual
/// rendering mode (see `OfflineHost`); no audio device is touched, so these run in an automated
/// shell.
@Suite struct VoiceSamplerTests {

    static let sr = 48_000.0

    static func allFinite(_ x: [Float]) -> Bool {
        for value in x where !value.isFinite { return false }
        return true
    }

    // MARK: Kits

    /// The kit `AudioEngineTests/SamplerKitTests` used, rebuilt in the A1 format: three sine
    /// bursts on three notes, plus the drum-voice map a groove addresses.
    static func sineKit(in folder: URL) throws -> LoadedKit {
        try AudioFixtures.kit(
            in: folder, name: "Sine Kit", sampleRate: sr,
            samples: [
                "samples/kick.wav": AudioFixtures.sine(frequency: 220, seconds: 0.5, sampleRate: sr),
                "samples/hat.wav": AudioFixtures.sine(frequency: 880, seconds: 0.5, sampleRate: sr),
                "samples/snare.wav": AudioFixtures.sine(frequency: 440, seconds: 0.5, sampleRate: sr),
            ],
            zones: [
                .drum(id: "kick", sample: "samples/kick.wav", note: 36),
                .drum(id: "hat", sample: "samples/hat.wav", note: 37),
                .drum(id: "snare", sample: "samples/snare.wav", note: 38),
            ],
            voices: [.kick: 36, .closedHat: 37, .snare: 38])
    }

    /// One zone whose sample is at full amplitude on its first frame, so an onset is exact.
    static func clickKit(in folder: URL, seconds: Double = 0.3) throws -> LoadedKit {
        try AudioFixtures.kit(
            in: folder, name: "Click Kit", sampleRate: sr,
            samples: ["click.wav": AudioFixtures.cosineBurst(frequency: 1000, seconds: seconds,
                                                             sampleRate: sr, amplitude: 0.8, decay: 0.05)],
            zones: [.drum(id: "click", sample: "click.wav", note: 36)],
            voices: [.kick: 36])
    }

    static func hostedSampler(kit: LoadedKit, channels: AVAudioChannelCount = 1,
                              maxVoices: Int = 64) throws -> (VoiceSampler, OfflineHost, SampleCache) {
        let cache = SampleCache()
        let sampler = VoiceSampler(cache: cache, maxVoices: maxVoices)
        try sampler.prepare(kit, sampleRate: sr, channels: Int(channels))
        let host = try OfflineHost(sampler: sampler, sampleRate: sr, channels: channels)
        return (sampler, host, cache)
    }

    // MARK: Replacing the Apple sampler

    @Test("a scheduled hit makes the sound the old AVAudioUnitSampler path made")
    func scheduledHitProducesSound() throws {
        let dir = TempDirectory("sine-kit")
        defer { dir.remove() }
        let kit = try Self.sineKit(in: dir.url)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        #expect(sampler.zoneCount == 3)
        #expect(sampler.kit?.manifest.name == "Sine Kit")

        host.startTransport()
        let onsetSeconds = 0.5
        sampler.enqueue([.init(note: 38, velocity: 110, at: onsetSeconds)])
        #expect(sampler.pendingHitCount == 1)

        let x = Signal.samples(try host.render(seconds: 1.5))
        #expect(sampler.pendingHitCount == 0)
        #expect(sampler.droppedEventCount == 0)

        let onset = Int(onsetSeconds * Self.sr)
        // Silent before the note, sound right after it.
        #expect(Signal.maxAbs(x[0..<(onset - 1)]) < 1e-6)
        #expect(Signal.maxAbs(x[onset..<(onset + 200)]) > 0.01)
        #expect(Signal.maxAbs(x[(onset + 1000)..<(onset + 5000)]) > 0.1)

        // The right zone played: note 38 is the 440 Hz sample, at its original pitch.
        let f = Signal.estimateFrequency(x, in: (onset + 2000)..<(onset + 14_000), sampleRate: Self.sr)
        #expect(abs(f - 440) < 10, "estimated \(f) Hz")
    }

    @Test("different notes play different samples, and a drum voice addresses the same zone")
    func differentNotesPlayDifferentSamples() throws {
        let dir = TempDirectory("sine-kit-notes")
        defer { dir.remove() }
        let kit = try Self.sineKit(in: dir.url)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([
            .init(note: 36, velocity: 100, at: 0.0),
            .init(.closedHat, velocity: 100, at: 1.0),   // voice-addressed: maps to note 37
        ])
        let x = Signal.samples(try host.render(seconds: 2.0))

        let f36 = Signal.estimateFrequency(x, in: 2_000..<12_000, sampleRate: Self.sr)
        let f37 = Signal.estimateFrequency(x, in: 50_000..<60_000, sampleRate: Self.sr)
        #expect(abs(f36 - 220) < 10, "note 36 -> \(f36) Hz")
        #expect(abs(f37 - 880) < 20, "closedHat -> \(f37) Hz")
        #expect(sampler.unmappedHitCount == 0)
    }

    @Test("a voice the kit does not map is reported, not silently dropped")
    func unmappedVoiceThrows() throws {
        let dir = TempDirectory("unmapped")
        defer { dir.remove() }
        let kit = try Self.sineKit(in: dir.url)
        let cache = SampleCache()
        let sampler = VoiceSampler(cache: cache)
        try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
        defer { sampler.unprepare() }

        #expect(throws: VoiceSampler.SamplerError.self) {
            try sampler.play(.init(.crash, velocity: 100, at: 0))
        }
    }

    // MARK: Sample-accurate onsets

    @Test("a hit scheduled at a known transport time starts on exactly that frame")
    func onsetIsSampleAccurate() throws {
        let dir = TempDirectory("onset")
        defer { dir.remove() }
        let kit = try Self.clickKit(in: dir.url)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        // Deliberately not a multiple of the 4096-frame render chunk.
        let onset = 37_123
        let onsetSeconds = Double(onset) / Self.sr
        sampler.enqueue([.init(.kick, velocity: 127, at: onsetSeconds)])

        let x = Signal.samples(try host.render(frames: 60_000))

        // Everything before the onset is exactly zero, and the onset frame itself is not.
        #expect(Signal.maxAbs(x[0..<onset]) == 0, "leaked \(Signal.maxAbs(x[0..<onset])) before the onset")
        #expect(x[onset] != 0)
        #expect(Signal.firstIndex(of: x, above: 0) == onset)

        // The sample's first frame is at full amplitude, so the value is predictable:
        // amplitude * zone gain * velocity gain * equal-power centre pan, folded to mono.
        let expected = Float(0.8) * 1 * 1 * Float(2.0).squareRoot() / 2
        #expect(abs(x[onset] - expected) < 1e-4, "first sample \(x[onset]), expected \(expected)")

        // The transport origin really is the node's render timeline.
        #expect(sampler.firstRenderStartFrame == 0)
        #expect(host.originSampleTime == 0)
    }

    @Test("onsets stay exact across render chunk boundaries")
    func onsetsAcrossChunks() throws {
        let dir = TempDirectory("onset-chunks")
        defer { dir.remove() }
        let kit = try Self.clickKit(in: dir.url, seconds: 0.05)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        let onsets = [0, 1, 4_095, 4_096, 4_097, 12_000, 40_961]
        sampler.enqueue(onsets.map { .init(.kick, velocity: 127, at: Double($0) / Self.sr) })
        let x = Signal.samples(try host.render(frames: 60_000))

        for onset in onsets {
            #expect(abs(x[onset]) > 0.5, "nothing at frame \(onset)")
            if onset > 0, !onsets.contains(onset - 1) {
                // The previous frame carries only the decayed tail of earlier hits, never this one.
                #expect(abs(x[onset]) > abs(x[onset - 1]), "hit at \(onset) started early")
            }
        }
        #expect(sampler.droppedEventCount == 0)
    }

    // MARK: Choke groups

    @Test("a closed hat with offBy silences the open hat inside the core's declick window")
    func closedHatChokesOpenHat() throws {
        let dir = TempDirectory("hats")
        defer { dir.remove() }
        // The closed hat's own sample is silence, so whatever is left in the output after the
        // choke is the open hat and nothing else.
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Hats", sampleRate: Self.sr,
            samples: [
                "open.wav": AudioFixtures.sine(frequency: 400, seconds: 2.0, sampleRate: Self.sr,
                                               amplitude: 0.8, fadeOut: false),
                "closed.wav": AudioFixtures.silence(seconds: 0.2, sampleRate: Self.sr),
            ],
            zones: [
                .drum(id: "open", sample: "open.wav", note: 46, offBy: 1),
                .drum(id: "closed", sample: "closed.wav", note: 42, group: 1),
            ],
            voices: [.openHat: 46, .closedHat: 42])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        let declick = sampler.declickFrames
        #expect(declick == Int((2.0 * 0.001 * Self.sr).rounded()))

        host.startTransport()
        let chokeFrame = 24_000
        sampler.enqueue([
            .init(.openHat, velocity: 127, at: 0.1),
            .init(.closedHat, velocity: 127, at: Double(chokeFrame) / Self.sr),
        ])
        let x = Signal.samples(try host.render(frames: 48_000))

        // Ringing right up to the choke...
        #expect(Signal.maxAbs(x[(chokeFrame - 2_000)..<chokeFrame]) > 0.3)
        // ...ramping down inside the window rather than being cut...
        #expect(Signal.maxAbs(x[chokeFrame..<(chokeFrame + declick)]) > 0.05)
        // ...and gone by the end of it.
        let after = Signal.maxAbs(x[(chokeFrame + declick)..<48_000])
        #expect(after == 0, "open hat still ringing at \(after) after the declick window")

        // The ramp really is monotone, i.e. a fade and not a truncation.
        let peakInRamp = Signal.maxAbs(x[chokeFrame..<(chokeFrame + 8)])
        let tailOfRamp = Signal.maxAbs(x[(chokeFrame + declick - 8)..<(chokeFrame + declick)])
        #expect(tailOfRamp < peakInRamp)
    }

    // MARK: Running off the end of a window

    @Test("a one-shot that ends mid-waveform rides its ramp down where it ends, not a block later")
    func windowEndRampsInPlace() throws {
        let dir = TempDirectory("window-end")
        defer { dir.remove() }
        // A sine that never fades, windowed to stop at a frame where it is nowhere near zero:
        // sin(2π · 100 · 20000/48000) = -0.866, so the voice is at -0.69 the instant it runs out.
        let end = 20_000
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Window", sampleRate: Self.sr,
            samples: ["tone.wav": AudioFixtures.sine(frequency: 100, seconds: 1.0,
                                                     sampleRate: Self.sr, amplitude: 0.8,
                                                     fadeOut: false)],
            zones: [Zone(id: "tone", sample: "tone.wav", key: .note(36),
                         sampleStart: 0, sampleEnd: end)],
            voices: [.kick: 36])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        let declick = sampler.declickFrames
        host.startTransport()
        sampler.enqueue([.init(.kick, velocity: 127, at: 0)])
        let x = Signal.samples(try host.render(frames: 48_000))

        // `end` is 4 blocks of 4096 plus 3616: the window runs out in the middle of a block, which
        // is the case that used to break. The voice stopped producing output there and its held
        // value reappeared, at full level, when the *next* block began — a hard cut followed 480
        // frames later by a step back up. So: sounding up to the end...
        #expect(Signal.maxAbs(x[(end - 2_000)..<end]) > 0.3)
        // ...ramping down over the declick window immediately after it...
        #expect(Signal.maxAbs(x[end..<(end + declick)]) > 0.05)
        // ...silent from the end of that window, with nothing coming back at the block boundary.
        let after = Signal.maxAbs(x[(end + declick)...])
        #expect(after == 0, "voice reappeared at \(after) after the ramp should have finished")

        // And the whole thing is smooth: the largest single-sample step anywhere is the sine's own
        // slope, not a cut. Before the fix this measured about 0.49.
        var worst: Float = 0
        for i in 1..<x.count { worst = max(worst, abs(x[i] - x[i - 1])) }
        #expect(worst < 0.02, "largest single-sample step \(worst)")
    }

    // MARK: Determinism

    @Test("two offline renders of the same sequence are byte-identical")
    func rendersAreByteIdentical() throws {
        let dir = TempDirectory("determinism")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Determinism", sampleRate: Self.sr,
            samples: [
                "noise.wav": AudioFixtures.noise(seconds: 0.4, sampleRate: Self.sr, amplitude: 0.5),
                "tone.wav": AudioFixtures.sine(frequency: 330, seconds: 0.4, sampleRate: Self.sr),
            ],
            zones: [
                .drum(id: "noise_a", sample: "noise.wav", note: 38, seqPosition: 1, seqLength: 2),
                .drum(id: "tone_b", sample: "tone.wav", note: 38, seqPosition: 2, seqLength: 2),
                .drum(id: "kick", sample: "tone.wav", note: 36, gainDB: -3),
            ],
            voices: [.kick: 36, .snare: 38])

        let hits: [VoiceSampler.Hit] = (0..<16).map { i in
            i.isMultiple(of: 2)
                ? .init(.kick, velocity: 100 + i, at: Double(i) * 0.05)
                : .init(.snare, velocity: 60 + i * 3, at: Double(i) * 0.05)
        }

        func renderOnce() throws -> [Float] {
            let (sampler, host, _) = try Self.hostedSampler(kit: kit)
            defer { host.stop(); sampler.unprepare() }
            host.startTransport()
            sampler.enqueue(hits)
            let x = Signal.samples(try host.render(frames: 60_000))
            #expect(sampler.droppedEventCount == 0)
            return x
        }

        let a = try renderOnce()
        let b = try renderOnce()
        #expect(a.count == b.count)
        let divergence = a.indices.first { $0 < b.count && a[$0] != b[$0] }
        #expect(a == b, "renders diverged at frame \(divergence.map(String.init) ?? "nowhere")")
        #expect(Signal.maxAbs(a) > 0.1)
    }

    // MARK: Polyphony

    @Test("64 simultaneous hits render with no dropped events, no stealing and no clipping")
    func sixtyFourSimultaneousHits() throws {
        let dir = TempDirectory("polyphony")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Polyphony", sampleRate: Self.sr,
            // Long enough that even the note transposed 39 semitones up (rate 9.5x) is still
            // sounding when the assertions run, so an inactive voice means a dropped hit.
            samples: ["tone.wav": AudioFixtures.sine(frequency: 300, seconds: 4.0, sampleRate: Self.sr,
                                                     amplitude: 0.8, fadeOut: false)],
            zones: [Zone(id: "tone", sample: "tone.wav", key: .range(36...99, rootNote: 60))])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit, maxVoices: 64)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        // 64 different notes on the same frame: 64 independent voices with 64 pitch ratios.
        sampler.enqueue((36..<100).map { .init(note: $0, velocity: 16, at: 0.02) })
        let x = Signal.samples(try host.render(frames: 9_600))

        #expect(sampler.droppedEventCount == 0)
        #expect(sampler.stolenVoiceCount == 0)
        #expect(sampler.hardCutCount == 0)
        #expect(sampler.activeVoiceCount == 64)
        let peak = Signal.maxAbs(x)
        #expect(peak > 0.05, "64 voices produced only \(peak)")
        #expect(peak < 1.0, "clipped at \(peak)")
        #expect(Self.allFinite(x))
    }

    // MARK: Zone selection

    @Test("velocity layers select the right zone")
    func velocityLayers() throws {
        let dir = TempDirectory("velocity")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Velocity", sampleRate: Self.sr,
            samples: [
                "soft.wav": AudioFixtures.sine(frequency: 220, seconds: 0.3, sampleRate: Self.sr, fadeOut: false),
                "hard.wav": AudioFixtures.sine(frequency: 880, seconds: 0.3, sampleRate: Self.sr, fadeOut: false),
            ],
            zones: [
                .drum(id: "soft", sample: "soft.wav", note: 38, velocity: 1...63),
                .drum(id: "hard", sample: "hard.wav", note: 38, velocity: 64...127),
            ],
            voices: [.snare: 38])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([
            .init(.snare, velocity: 40, at: 0.0),
            .init(.snare, velocity: 100, at: 0.5),
        ])
        let x = Signal.samples(try host.render(frames: 40_000))

        let soft = Signal.estimateFrequency(x, in: 1_000..<12_000, sampleRate: Self.sr)
        let hard = Signal.estimateFrequency(x, in: 25_000..<36_000, sampleRate: Self.sr)
        #expect(abs(soft - 220) < 8, "velocity 40 -> \(soft) Hz")
        #expect(abs(hard - 880) < 15, "velocity 100 -> \(hard) Hz")

        // The curve is applied as linear gain, so the quiet layer really is quieter.
        let softPeak = Signal.maxAbs(x[1_000..<12_000])
        let hardPeak = Signal.maxAbs(x[25_000..<36_000])
        let curve = kit.manifest.velocityCurve
        #expect(abs(softPeak - 0.8 * curve.gain(forVelocity: 40) * Float(2.0).squareRoot() / 2) < 0.01)
        #expect(abs(hardPeak - 0.8 * curve.gain(forVelocity: 100) * Float(2.0).squareRoot() / 2) < 0.01)
    }

    @Test("round robin cycles through the set and wraps")
    func roundRobinCyclesAndWraps() throws {
        let dir = TempDirectory("round-robin")
        defer { dir.remove() }
        let frequencies = [220.0, 440.0, 880.0]
        var samples: [String: [Float]] = [:]
        var zones: [Zone] = []
        for (i, f) in frequencies.enumerated() {
            samples["rr\(i).wav"] = AudioFixtures.sine(frequency: f, seconds: 0.25,
                                                       sampleRate: Self.sr, fadeOut: false)
            zones.append(.drum(id: ZoneID("rr\(i)"), sample: "rr\(i).wav", note: 38,
                               seqPosition: i + 1, seqLength: 3))
        }
        let kit = try AudioFixtures.kit(in: dir.url, name: "Round Robin", sampleRate: Self.sr,
                                        samples: samples, zones: zones, voices: [.snare: 38])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        let spacing = 0.3
        sampler.enqueue((0..<4).map { .init(.snare, velocity: 100, at: Double($0) * spacing) })
        let x = Signal.samples(try host.render(frames: 64_000))

        let expected = [220.0, 440.0, 880.0, 220.0]  // four hits over a three-slot set
        for (i, want) in expected.enumerated() {
            let start = Int(Double(i) * spacing * Self.sr) + 1_000
            let f = Signal.estimateFrequency(x, in: start..<(start + 9_000), sampleRate: Self.sr)
            #expect(abs(f - want) < 20, "hit \(i) -> \(f) Hz, expected \(want)")
        }
    }

    @Test("round robin restarts with the transport, so a second run repeats the first")
    func roundRobinResetsWithTheTransport() throws {
        let dir = TempDirectory("round-robin-reset")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "RR Reset", sampleRate: Self.sr,
            samples: [
                "a.wav": AudioFixtures.sine(frequency: 220, seconds: 0.2, sampleRate: Self.sr, fadeOut: false),
                "b.wav": AudioFixtures.sine(frequency: 880, seconds: 0.2, sampleRate: Self.sr, fadeOut: false),
            ],
            zones: [
                .drum(id: "a", sample: "a.wav", note: 38, seqPosition: 1, seqLength: 2),
                .drum(id: "b", sample: "b.wav", note: 38, seqPosition: 2, seqLength: 2),
            ],
            voices: [.snare: 38])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        func run() throws -> Double {
            host.startTransport()
            sampler.enqueue([.init(.snare, velocity: 100, at: 0.02)])
            let x = Signal.samples(try host.render(frames: 12_000))
            host.stopTransport()
            _ = try host.render(frames: 2_000)  // let the release finish
            return Signal.estimateFrequency(x, in: 2_000..<10_000, sampleRate: Self.sr)
        }

        let first = try run()
        let second = try run()
        #expect(abs(first - 220) < 10, "first run -> \(first) Hz")
        #expect(abs(second - 220) < 10, "second run -> \(second) Hz (counter leaked across runs)")
    }

    // MARK: Pitch

    @Test("a pitched zone transposed by an octave plays back at double rate")
    func octaveTransposeDoublesTheRate() throws {
        let dir = TempDirectory("pitched")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Pitched", sampleRate: Self.sr,
            samples: ["pad.wav": AudioFixtures.sine(frequency: 440, seconds: 1.0,
                                                    sampleRate: Self.sr, fadeOut: false)],
            zones: [Zone(id: "pad", sample: "pad.wav", key: .range(48...84, rootNote: 60))])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([
            .init(note: 60, velocity: 100, at: 0.0),   // root: 440 Hz
            .init(note: 72, velocity: 100, at: 1.2),   // +12 semitones: 880 Hz
            .init(note: 48, velocity: 100, at: 2.4),   // -12 semitones: 220 Hz
        ])
        let x = Signal.samples(try host.render(seconds: 3.4))

        func window(_ seconds: Double) -> Range<Int> {
            let start = Int(seconds * Self.sr) + 2_000
            return start..<(start + 19_200)  // 0.4 s
        }
        let root = Signal.estimateFrequency(x, in: window(0.0), sampleRate: Self.sr)
        let up = Signal.estimateFrequency(x, in: window(1.2), sampleRate: Self.sr)
        let down = Signal.estimateFrequency(x, in: window(2.4), sampleRate: Self.sr)
        #expect(abs(root - 440) < 5, "root -> \(root) Hz")
        #expect(abs(up - 880) < 10, "+1 octave -> \(up) Hz")
        #expect(abs(down - 220) < 5, "-1 octave -> \(down) Hz")

        // And the energy really moved: the 880 Hz bin dominates the 440 Hz bin an octave up.
        let at880 = Signal.magnitude(x, at: 880, in: window(1.2), sampleRate: Self.sr)
        let at440 = Signal.magnitude(x, at: 440, in: window(1.2), sampleRate: Self.sr)
        #expect(at880 > 10 * at440, "880 Hz \(at880) vs 440 Hz \(at440)")
    }

    @Test("zone tuning in cents and note transposition compose instead of doubling up")
    func tuningAndTranspositionCompose() throws {
        let dir = TempDirectory("tuning")
        defer { dir.remove() }
        // +1200 cents of tuning on a zone whose root is 60: note 60 must play one octave up, and
        // note 72 two octaves up. A draft that used `Zone.pitchRatio(forNote:)` as the per-voice
        // ratio on top of the zone ratio squared the tuning.
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Tuned", sampleRate: Self.sr,
            samples: ["tone.wav": AudioFixtures.sine(frequency: 220, seconds: 1.0,
                                                     sampleRate: Self.sr, fadeOut: false)],
            zones: [Zone(id: "tone", sample: "tone.wav", key: .range(48...84, rootNote: 60),
                         tuneCents: 1200)])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([
            .init(note: 60, velocity: 100, at: 0.0),
            .init(note: 72, velocity: 100, at: 0.8),
        ])
        let x = Signal.samples(try host.render(seconds: 1.6))
        let root = Signal.estimateFrequency(x, in: 2_000..<14_000, sampleRate: Self.sr)
        let up = Signal.estimateFrequency(x, in: 40_400..<50_000, sampleRate: Self.sr)
        #expect(abs(root - 440) < 6, "tuned root -> \(root) Hz, expected 440")
        #expect(abs(up - 880) < 12, "tuned +1 octave -> \(up) Hz, expected 880")
    }

    // MARK: Note-off and sustain

    @Test("a hit with a duration releases; a one-shot does not need one")
    func durationSchedulesANoteOff() throws {
        let dir = TempDirectory("sustain")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Sustain", sampleRate: Self.sr,
            samples: ["pad.wav": AudioFixtures.sine(frequency: 300, seconds: 2.0,
                                                    sampleRate: Self.sr, fadeOut: false)],
            zones: [Zone(id: "pad", sample: "pad.wav", key: .note(60),
                         envelope: Envelope(sustain: 1, release: 0.05))],
            voices: [.perc: 60])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([.init(note: 60, velocity: 100, at: 0.05, duration: 0.5)])
        let x = Signal.samples(try host.render(seconds: 1.2))

        let offFrame = Int(0.55 * Self.sr)
        let releaseFrames = Int(0.05 * Self.sr)
        #expect(Signal.maxAbs(x[(offFrame - 2_000)..<offFrame]) > 0.3)
        #expect(Signal.maxAbs(x[(offFrame + releaseFrames + 8)..<Int(1.1 * Self.sr)]) == 0)
        #expect(sampler.bufferedEventCount == 0)
    }

    @Test("a sounding voice can be stopped by handle")
    func stopByHandle() throws {
        let dir = TempDirectory("stop")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Stop", sampleRate: Self.sr,
            samples: ["pad.wav": AudioFixtures.sine(frequency: 300, seconds: 2.0,
                                                    sampleRate: Self.sr, fadeOut: false)],
            zones: [Zone(id: "pad", sample: "pad.wav", key: .note(60),
                         envelope: Envelope(sustain: 1, release: 0.02))])
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        let handles = try sampler.play([
            .init(note: 60, velocity: 100, at: 0.0),
            .init(note: 60, velocity: 100, at: 0.0),
        ])
        #expect(handles.count == 2)
        _ = try host.render(seconds: 0.2)
        #expect(sampler.activeVoiceCount == 2)

        sampler.stop(handles[0], at: host.transportSeconds)
        _ = try host.render(seconds: 0.2)
        #expect(sampler.activeVoiceCount == 1, "stopping one handle stopped \(2 - sampler.activeVoiceCount)")

        sampler.allNotesOff(at: host.transportSeconds)
        _ = try host.render(seconds: 0.2)
        #expect(sampler.activeVoiceCount == 0)
    }

    // MARK: Kit swaps

    @Test("preparing a second kit while the first is sounding neither crashes nor reads freed memory")
    func swappingKitsWhileSounding() throws {
        let dirA = TempDirectory("swap-a")
        let dirB = TempDirectory("swap-b")
        defer { dirA.remove(); dirB.remove() }

        let cache = SampleCache()
        let kitA = try AudioFixtures.kit(
            in: dirA.url, name: "Kit A", sampleRate: Self.sr,
            samples: ["a.wav": AudioFixtures.sine(frequency: 250, seconds: 4.0,
                                                  sampleRate: Self.sr, fadeOut: false)],
            zones: [.drum(id: "a", sample: "a.wav", note: 36)], voices: [.kick: 36])
        let kitB = try AudioFixtures.kit(
            in: dirB.url, name: "Kit B", sampleRate: Self.sr,
            samples: ["b.wav": AudioFixtures.noise(seconds: 1.0, sampleRate: Self.sr, amplitude: 0.4)],
            zones: [.drum(id: "b", sample: "b.wav", note: 36)], voices: [.kick: 36])

        let sampler = VoiceSampler(cache: cache)
        try sampler.prepare(kitA, sampleRate: Self.sr, channels: 1)
        let host = try OfflineHost(sampler: sampler, sampleRate: Self.sr, channels: 1)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([.init(.kick, velocity: 127, at: 0.05)])
        let before = Signal.samples(try host.render(seconds: 0.5))
        #expect(Signal.maxAbs(before) > 0.3)
        #expect(sampler.activeVoiceCount == 1)

        // Swap under the sounding voice.
        try sampler.prepare(kitB, sampleRate: Self.sr, channels: 1)
        #expect(sampler.kit?.manifest.name == "Kit B")
        #expect(sampler.retiredAllocationCount == 1, "the old table must be retired, not freed yet")

        let across = Signal.samples(try host.render(seconds: 0.2))
        #expect(Self.allFinite(across))
        // The stranded voice is zombied: it fades from its last value over the declick window and
        // reads nothing more, so the new table's memory is never mixed with the old one's.
        let declick = sampler.declickFrames
        #expect(Signal.maxAbs(across[(declick + 8)...]) == 0)

        // Now the core has acknowledged the publish, so the old allocations can actually go.
        sampler.reclaim()
        #expect(sampler.retiredAllocationCount == 0)
        #expect(cache.evict(kit: kitA.id) == 1, "kit A's samples should now be evictable")

        // Play the new kit: nothing here may touch kit A's freed sample memory.
        sampler.enqueue([.init(.kick, velocity: 127, at: host.transportSeconds + 0.05)])
        let after = Signal.samples(try host.render(seconds: 0.5))
        #expect(Signal.maxAbs(after) > 0.05)
        #expect(Self.allFinite(after))
        #expect(sampler.droppedEventCount == 0)
        #expect(!sampler.transportSampleRateMismatch)
    }

    @Test("the output format is fixed by the first prepare")
    func formatIsLocked() throws {
        let dir = TempDirectory("format")
        defer { dir.remove() }
        let kit = try Self.clickKit(in: dir.url)
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
        defer { sampler.unprepare() }
        #expect(sampler.format == VoiceSampler.Format(sampleRate: Self.sr, channels: 1))
        #expect(throws: VoiceSampler.SamplerError.self) {
            try sampler.prepare(kit, sampleRate: 44_100, channels: 1)
        }
        // Still usable at the format it was prepared for.
        #expect(sampler.zoneCount == 1)
    }

    @Test("stereo output keeps the pair and honours pan")
    func stereoPan() throws {
        let dir = TempDirectory("pan")
        defer { dir.remove() }
        let kit = try AudioFixtures.kit(
            in: dir.url, name: "Pan", sampleRate: Self.sr,
            samples: ["tone.wav": AudioFixtures.sine(frequency: 300, seconds: 0.5,
                                                     sampleRate: Self.sr, fadeOut: false)],
            zones: [
                Zone(id: "left", sample: "tone.wav", key: .note(36), pan: -1),
                Zone(id: "right", sample: "tone.wav", key: .note(38), pan: 1),
            ],
            voices: [.kick: 36, .snare: 38])

        let (sampler, host, _) = try Self.hostedSampler(kit: kit, channels: 2)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        sampler.enqueue([
            .init(.kick, velocity: 127, at: 0.05),
            .init(.snare, velocity: 127, at: 0.8),   // after the left hit's 0.5 s sample has ended
        ])
        let buffer = try host.render(seconds: 1.5)
        let l = Signal.samples(buffer, channel: 0)
        let r = Signal.samples(buffer, channel: 1)

        let hardLeft = 2_500..<25_000
        let hardRight = 40_000..<60_000
        #expect(Signal.maxAbs(l[hardLeft]) > 0.7)
        #expect(Signal.maxAbs(r[hardLeft]) < 1e-5)
        #expect(Signal.maxAbs(r[hardRight]) > 0.7)
        #expect(Signal.maxAbs(l[hardRight]) < 1e-5)
    }

    // MARK: Look-ahead

    @Test("the look-ahead pushes events before the block that needs them")
    func lookAheadPushesAhead() throws {
        let dir = TempDirectory("lookahead")
        defer { dir.remove() }
        let kit = try Self.clickKit(in: dir.url, seconds: 0.05)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }
        host.lookAhead = 0.25

        host.startTransport()
        // A hit far beyond the look-ahead window stays queued in Swift until the window reaches it,
        // so it can never occupy the core's fixed-capacity queue in the meantime.
        sampler.enqueue([.init(.kick, velocity: 127, at: 5.0)])
        #expect(sampler.pendingHitCount == 1)
        _ = try host.render(seconds: 0.5)
        #expect(sampler.pendingHitCount == 1, "a hit 5 s out was pushed 4.25 s early")

        _ = try host.render(seconds: 4.4)
        #expect(sampler.pendingHitCount == 0, "the hit was never pushed")
        let x = Signal.samples(try host.render(seconds: 0.5))
        #expect(Signal.maxAbs(x[0..<4_900]) > 0.5)
        #expect(sampler.droppedEventCount == 0)
    }

    @Test("hits enqueued after their time still sound, at the next block")
    func lateHitsAreEarlyNeverLost() throws {
        let dir = TempDirectory("late")
        defer { dir.remove() }
        let kit = try Self.clickKit(in: dir.url, seconds: 0.05)
        let (sampler, host, _) = try Self.hostedSampler(kit: kit)
        defer { host.stop(); sampler.unprepare() }

        host.startTransport()
        _ = try host.render(seconds: 0.5)
        // Already in the past by half a second.
        sampler.enqueue([.init(.kick, velocity: 127, at: 0.1)])
        let x = Signal.samples(try host.render(seconds: 0.5))
        #expect(Signal.firstIndex(of: x, above: 0.5) == 0, "a late hit should land on the next frame")
        #expect(sampler.droppedEventCount == 0)
    }
}
