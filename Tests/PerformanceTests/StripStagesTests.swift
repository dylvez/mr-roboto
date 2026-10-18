import AVFAudio
import AudioEngine
import CStripFX
import Foundation
import SongGraph
import Testing

@testable import Performance

/// The stages around a strip's insert and the returns' own effects, rendered offline through the
/// graph the transport plays: the pump ducks on the transport's beats and the kick's steps, the
/// filter holds and sweeps by section, the modulation and the pedal move the sound and keep its
/// level, and the spring, the gated room and the tape echo each do what they are named for.
@Suite("Strip stages and returns: pump, filter, modulation, pedal, spring, gate, tape", .serialized)
struct StripStagesTests {
    private static let rate = 48_000.0

    enum Source {
        case tone(Double)
        /// Tones at these frequencies, summed: a stand-in for a chord or a pad.
        case tones([Double])
        /// A burst of a tone this long, then silence.
        case burst(Double, seconds: Double)
    }

    private func buffer(_ source: Source, seconds: Double, amplitude: Float, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<frames {
                let t = Double(i) / Self.rate
                let value: Double
                switch source {
                case .tone(let hz): value = sin(2 * .pi * hz * t)
                case .tones(let all): value = all.reduce(0) { $0 + sin(2 * .pi * $1 * t + $1) } / Double(all.count).squareRoot()
                case .burst(let hz, let length): value = t < length ? sin(2 * .pi * hz * t) : 0
                }
                buffer.floatChannelData![channel][i] = amplitude * Float(value)
            }
        }
        return buffer
    }

    @AudioActor
    private func render(_ source: Source, amplitude: Float = 0.25, part: PartID, mix: Mix, timeline: MixTimeline? = nil,
                        seconds: Double = 2, tempo: Double = 120) throws -> [[Float]] {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        let player = try engine.player(0)
        try graph.route(player, to: part)
        graph.tempo = tempo
        graph.timeline = timeline
        graph.apply(mix)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: tempo, sampleRate: Self.rate))
        player.scheduleBuffer(buffer(source, seconds: seconds, amplitude: amplitude, format: engine.format), at: nil, options: [], completionHandler: nil)
        player.play()
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(seconds * Self.rate))
        engine.stop()
        let frames = Int(out.frameLength)
        return (0..<Int(out.format.channelCount)).map { c in Array(UnsafeBufferPointer(start: out.floatChannelData![c], count: frames)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        let energy = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(energy / Double(max(1, x.count)), 1e-20))
    }

    /// The level over the 10 ms ending at `seconds`.
    private func level(_ x: [Float], at seconds: Double, window: Double = 0.01) -> Double {
        let end = min(x.count, Int(seconds * Self.rate)), start = max(0, end - Int(window * Self.rate))
        return rms(x[start..<end])
    }

    private func whole(_ sections: [MixTimeline.Section], cycle: Double? = nil) -> MixTimeline { MixTimeline(sections: sections, cycleBeats: cycle) }

    // MARK: The pump

    @Test("Every beat, the pump ducks the strip by its depth and lets it back up, on the transport's beats")
    @AudioActor
    func pumpOnTheBeat() async throws {
        let part = PartID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Pad", pump: StripPump(trigger: .beat, depthDB: 12, releaseBeats: 0.5)))
        let out = try render(.tone(220), part: part, mix: mix, timeline: whole([.init(section: nil, startBeat: 0, lengthBeats: 1_000)]))
        // 120 to the minute: a beat every half second.
        for beat in [1.0, 2.0, 3.0] {
            let seconds = beat * 0.5
            let before = level(out[0], at: seconds - 0.002, window: 0.008)
            let after = level(out[0], at: seconds + 0.012, window: 0.008)
            #expect(before - after > 8, "beat \(beat): \(before) before, \(after) just after")
        }
        // Mostly back by the next beat.
        let late = level(out[0], at: 0.98), dry = try render(.tone(220), part: part, mix: .unity, seconds: 1)
        #expect(level(dry[0], at: 0.98) - late < 3)
    }

    @Test("On the kick, it ducks where the groove's kick hits and nowhere else")
    @AudioActor
    func pumpOnTheKick() async throws {
        let part = PartID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Chords", pump: StripPump(trigger: .kick, depthDB: 12, releaseBeats: 0.25)))
        // Kicks on 1, the "and" of 2 and the "and" of 3.
        let timeline = whole([.init(section: nil, startBeat: 0, lengthBeats: 1_000, kicks: [0, 1.5, 2.5], patternBeats: 4)])
        let out = try render(.tone(220), part: part, mix: mix, timeline: timeline, seconds: 2.2)
        func dip(_ seconds: Double) -> Double { level(out[0], at: seconds - 0.002, window: 0.008) - level(out[0], at: seconds + 0.012, window: 0.008) }
        #expect(dip(0.75) > 8 && dip(1.25) > 8 && dip(2.0) > 8, "the kicks: \(dip(0.75)), \(dip(1.25)), \(dip(2.0))")
        #expect(abs(dip(0.5)) < 1.5 && abs(dip(1.0)) < 1.5, "no kick on 2 or 3: \(dip(0.5)), \(dip(1.0))")
    }

    @Test("A section can turn the pump off, and the section after keeps the strip's")
    @AudioActor
    func pumpBySection() async throws {
        let part = PartID(), verse = SectionID(), breakdown = SectionID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Pad", pump: StripPump(trigger: .beat, depthDB: 12, releaseBeats: 0.5)))
        mix.setSectionEffect(SectionEffect(section: breakdown, part: part, pumpDB: 0))
        let timeline = whole([.init(section: verse, startBeat: 0, lengthBeats: 2), .init(section: breakdown, startBeat: 2, lengthBeats: 1_000)])
        let out = try render(.tone(220), part: part, mix: mix, timeline: timeline)
        func dip(_ seconds: Double) -> Double { level(out[0], at: seconds - 0.002, window: 0.008) - level(out[0], at: seconds + 0.012, window: 0.008) }
        #expect(dip(0.5) > 8)
        #expect(abs(dip(1.5)) < 1, "no pump in the breakdown: \(dip(1.5))")
    }

    // MARK: The filter

    @Test("A held high-pass takes the low end away; a low-pass at its corner lets it through")
    @AudioActor
    func filterHeld() async throws {
        let part = PartID()
        let dry = try render(.tone(100), part: part, mix: .unity, seconds: 1)
        var mix = Mix()
        mix.set(Strip(part: part, label: "Drums", filter: StripFilter(kind: .highPass, cutoffHz: 1_000)))
        let thin = try render(.tone(100), part: part, mix: mix, seconds: 1)
        #expect(level(dry[0], at: 0.9, window: 0.2) - level(thin[0], at: 0.9, window: 0.2) > 30)
        mix.set(Strip(part: part, label: "Drums", filter: StripFilter(kind: .lowPass, cutoffHz: 1_000)))
        let kept = try render(.tone(100), part: part, mix: mix, seconds: 1)
        #expect(abs(level(dry[0], at: 0.9, window: 0.2) - level(kept[0], at: 0.9, window: 0.2)) < 1)
    }

    @Test("A section sweeps the low-pass open across its bars, and the next section holds where it says")
    @AudioActor
    func filterSweep() async throws {
        let part = PartID(), build = SectionID(), drop = SectionID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Chords", filter: StripFilter(kind: .lowPass)))
        mix.setSectionEffect(SectionEffect(section: build, part: part, filterFromHz: 200, filterToHz: 20_000))
        // The build is four beats, two seconds; the drop after it leaves the filter open.
        let timeline = whole([.init(section: build, startBeat: 0, lengthBeats: 4), .init(section: drop, startBeat: 4, lengthBeats: 1_000)])
        let out = try render(.tone(3_000), part: part, mix: mix, timeline: timeline, seconds: 2.6)
        let early = level(out[0], at: 0.3, window: 0.1), middle = level(out[0], at: 1.2, window: 0.1), late = level(out[0], at: 1.95, window: 0.1)
        #expect(late - early > 30, "early \(early), late \(late)")
        #expect(middle > early && late > middle, "it opens on the way: \(early), \(middle), \(late)")
        let drop2 = level(out[0], at: 2.5, window: 0.1)
        #expect(abs(drop2 - late) < 2, "open in the drop: \(drop2) against \(late)")
    }

    // MARK: Modulation and the pedal

    @Test("Each modulation moves the sound, keeps its level within a few dB and never runs away")
    @AudioActor
    func modulation() async throws {
        let part = PartID()
        let source = Source.tones([196, 247, 294, 392])
        let dry = try render(source, part: part, mix: .unity)
        for (id, modulation) in StripModulation.named where modulation.kind != .off {
            var mix = Mix()
            mix.set(Strip(part: part, label: "Pad", modulation: modulation))
            let wet = try render(source, part: part, mix: mix)
            #expect(wet != dry, "\(id) changes nothing")
            let change = rms(wet[0][24_000...]) - rms(dry[0][24_000...])
            // A flanger's notches sweep through a chord of four notes: that is the effect.
            #expect(abs(change) < (modulation.kind == .flanger ? 8 : 4), "\(id) moves the level \(change) dB")
            #expect(wet.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1 } }, "\(id) runs away")
        }
        // The chorus is what makes a mono part wide: the sides differ.
        var mix = Mix()
        mix.set(Strip(part: part, label: "Pad", modulation: .chorus))
        let wide = try render(source, part: part, mix: mix)
        let sides = zip(wide[0][24_000...], wide[1][24_000...]).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }
        #expect(sides > 10, "left and right differ by \(sides)")
    }

    @Test("A Juno brings its chorus to its strip, as an organ brings its speaker, and the mix can take it off")
    @AudioActor
    func instrumentsOwnModulation() async throws {
        let part = PartID()
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        graph.instrumentModulations = [part: .chorus]
        _ = graph.strip(for: part)
        graph.apply(.unity)
        #expect(graph.chain(for: part, in: nil).modulation == .chorus)
        var mix = Mix()
        mix.set(Strip(part: part, label: "Pad", modulation: .off))
        graph.apply(mix)
        #expect(graph.chain(for: part, in: nil).modulation == nil)
    }

    @Test("The wah rocked in time and the envelope filter both move the sound and keep within a few dB")
    @AudioActor
    func pedals() async throws {
        let part = PartID()
        let source = Source.tones([110, 220, 330, 440, 660, 880, 1_320])
        let dry = try render(source, part: part, mix: .unity)
        for (id, pedal) in StripPedal.named {
            var mix = Mix()
            mix.set(Strip(part: part, label: "Clav", pedal: pedal))
            let wet = try render(source, part: part, mix: mix, timeline: whole([.init(section: nil, startBeat: 0, lengthBeats: 1_000)]))
            #expect(wet != dry, "\(id) changes nothing")
            let change = rms(wet[0][24_000...]) - rms(dry[0][24_000...])
            #expect(abs(change) < 8, "\(id) moves the level \(change) dB")
            #expect(wet.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1.5 } }, "\(id) runs away")
        }
        // The wah sweeps: its level in 20 ms windows moves by several dB over a beat.
        var mix = Mix()
        mix.set(Strip(part: part, label: "Guitar", pedal: .wahQuarters))
        let wah = try render(.tone(1_800), part: part, mix: mix, timeline: whole([.init(section: nil, startBeat: 0, lengthBeats: 1_000)]))
        let levels = stride(from: 1.0, to: 1.5, by: 0.02).map { level(wah[0], at: $0, window: 0.02) }
        #expect((levels.max()! - levels.min()!) > 6, "the wah's sweep: \(levels.max()! - levels.min()!) dB")
    }

    @Test("Everything off, the stages leave the signal sample for sample")
    @AudioActor
    func stagesOffAreTransparent() async throws {
        let part = PartID()
        let unity = try render(.tone(440), part: part, mix: .unity, seconds: 0.5)
        var mix = Mix()
        mix.set(Strip(part: part, label: "Keys", modulation: .off))
        let off = try render(.tone(440), part: part, mix: mix, timeline: whole([.init(section: nil, startBeat: 0, lengthBeats: 1_000)]), seconds: 0.5)
        #expect(unity == off)
    }

    // MARK: The returns

    @AudioActor
    private func send(_ room: Room?, echo: Echo? = nil, seconds: Double = 1.5, tempo: Double = 120) throws -> [[Float]] {
        let part = PartID()
        var mix = Mix()
        // A 20 ms hit: past it, what is heard is what comes back from the returns. The sends are
        // after the fader, so the strip is not silenced.
        mix.set(Strip(part: part, label: "Snare", sendDB: echo == nil ? 0 : nil, echoDB: echo == nil ? nil : 0))
        mix.room = room
        mix.echo = echo
        return try render(.burst(1_000, seconds: 0.02), amplitude: 0.5, part: part, mix: mix, seconds: seconds, tempo: tempo)
    }

    @Test("The spring rings on after a hit and dies away, and sounds unlike the room")
    @AudioActor
    func spring() async throws {
        let out = try send(.spring)
        let ringing = level(out[0], at: 0.3, window: 0.1), later = level(out[0], at: 1.4, window: 0.1)
        #expect(ringing > -45, "the spring at 0.2–0.3 s: \(ringing)")
        #expect(later < ringing - 10, "it dies away: \(ringing) then \(later)")
        #expect(out.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1 } })
        #expect(try send(.room) != out)
    }

    @Test("The gated room is loud for a quarter of a second after the hit and gone after it")
    @AudioActor
    func gated() async throws {
        let out = try send(.gated)
        let open = level(out[0], at: 0.2, window: 0.1), shut = level(out[0], at: 0.6, window: 0.1)
        #expect(open > -40, "open: \(open)")
        #expect(open - shut > 30, "cut off: \(open) then \(shut)")
    }

    @Test("The tape echo comes back on the beat, quieter each time, and wanders a little")
    @AudioActor
    func tape() async throws {
        // A dotted eighth at 100: repeats every 0.45 s.
        let out = try send(nil, echo: Echo(beats: 0.75, feedback: 0.5, toneHz: 6_000, tape: true), seconds: 1.6, tempo: 100)
        let window = 480
        let levels = stride(from: 0, to: out[0].count - window, by: window).map { rms(out[0][$0..<($0 + window)]) }
        let first = levels.indices.filter { Double($0) * 0.01 > 0.3 && Double($0) * 0.01 < 0.6 }.max { levels[$0] < levels[$1] }!
        let second = levels.indices.filter { Double($0) * 0.01 > 0.75 && Double($0) * 0.01 < 1.05 }.max { levels[$0] < levels[$1] }!
        #expect(abs(Double(first) * 0.01 - 0.45) < 0.03, "first repeat at \(Double(first) * 0.01) s")
        #expect(abs(Double(second) * 0.01 - 0.90) < 0.03, "second repeat at \(Double(second) * 0.01) s")
        #expect(levels[second] < levels[first] - 3)
        #expect(out.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1 } })
    }

    @Test("A bounce through the new stages is the same twice")
    @AudioActor
    func deterministic() async throws {
        let part = PartID(), build = SectionID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Pad", pedal: .envelope, modulation: .phaserSlow, filter: StripFilter(kind: .lowPass),
                      pump: .standard))
        mix.setSectionEffect(SectionEffect(section: build, part: part, filterFromHz: 300, filterToHz: 8_000))
        mix.room = .spring
        let timeline = whole([.init(section: build, startBeat: 0, lengthBeats: 8, kicks: [0, 1, 2, 3], patternBeats: 4)])
        let a = try render(.tones([196, 294, 392]), part: part, mix: mix, timeline: timeline, seconds: 1)
        let b = try render(.tones([196, 294, 392]), part: part, mix: mix, timeline: timeline, seconds: 1)
        #expect(a == b)
    }

    @Test("A groove's kicks are read off its steps, swung where its odd steps are")
    func kickBeats() {
        var steps = [VelocityTier](repeating: .rest, count: 16)
        steps[0] = .accent; steps[6] = .normal; steps[11] = .normal
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0.5, patterns: [GroovePattern(voice: .kick, steps: steps)])
        let beats = groove.kickBeats(beatsPerBar: 4)
        #expect(beats.count == 3)
        #expect(abs(beats[0]) < 1e-9 && abs(beats[1] - 1.5) < 1e-9)
        // Step 11 is odd: a sixteenth is a quarter beat, half of it swung by half.
        #expect(abs(beats[2] - (2.75 + 0.0625)) < 1e-9)
    }
}
