import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// Tests for the degradation chain. Each one pins a claim the header makes, because the whole point
/// of this stage is accuracy to specific machines and an inaccurate degrader is just noise.
@Suite("Degrade chain")
struct DegradeChainTests {

    static let sr: Double = 48_000

    // MARK: - Bypass

    @Test("clean is bit-transparent, not merely quiet")
    func cleanPresetIsBitTransparent() throws {
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 2, settings: .clean)
        #expect(chain.isBypassed)
        #expect(chain.latencyFrames == 0)

        let buffer = PlanarBuffer(channelCount: 2, frameCount: 8_192)
        buffer.fill { channel, frame in
            let t = Double(frame) / Self.sr
            let v = 0.7 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 3_171 * t)
            return Float(channel == 0 ? v : -v * 0.63)
        }
        let before = (0..<2).map { buffer.samples($0) }
        buffer.process(with: chain)
        for c in 0..<2 {
            // Exact float equality on every sample: nothing was read, so nothing was written.
            #expect(buffer.samples(c) == before[c])
        }
    }

    @Test("a chain that has been dirty stays on the path until it is reset")
    func bypassIsAColdStartProperty() throws {
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: .clean)
        #expect(chain.isBypassed)
        chain.apply(.sp1200)
        #expect(!chain.isBypassed)
        #expect(chain.latencyFrames > 0)
        chain.settings = .clean
        // Still on the path: leaving it would jump the signal forward by the chain's latency.
        #expect(!chain.isBypassed)
        chain.reset()
        #expect(chain.isBypassed)
        #expect(chain.latencyFrames == 0)
    }

    // MARK: - Quantisation

    @Test("8 bits lands on exactly the levels a signed 8-bit converter has")
    func eightBitQuantisationHitsTheExpectedLevels() throws {
        var settings = DegradeSettings()
        settings.bitDepth = 8
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
        let latency = chain.latencyFrames
        #expect(latency > 0)

        let rampFrames = 4_096
        let buffer = PlanarBuffer(channelCount: 1, frameCount: rampFrames + latency)
        buffer.fill { _, frame in
            frame < rampFrames ? Float(-1 + 2 * Double(frame) / Double(rampFrames - 1)) : 1
        }
        let input = buffer.samples(0)
        buffer.process(with: chain)
        let output = buffer.samples(0)

        var levels = Set<Float>()
        for i in 0..<rampFrames {
            let got = output[i + latency]
            #expect(got == DegradeFixtures.expectedQuantisation(input[i], bits: 8))
            // The grid itself: every output value is an exact multiple of 1/128.
            #expect((Double(got) * 128).rounded() == Double(got) * 128)
            levels.insert(got)
        }
        // A full-scale ramp should visit essentially the whole code range (256 codes, top one
        // unreachable because the converter clamps at 127/128).
        #expect(levels.count >= 250)
        #expect(levels.max() == Float(127) / Float(128))
        #expect(levels.min() == Float(-1))
    }

    @Test("a fractional bit depth is a real setting, not a rounded one")
    func fractionalBitDepthQuantisesFiner() throws {
        func levelCount(bits: Double) throws -> Int {
            var settings = DegradeSettings()
            settings.bitDepth = bits
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let latency = chain.latencyFrames
            let n = 8_192
            let buffer = PlanarBuffer(channelCount: 1, frameCount: n + latency)
            buffer.fill { _, frame in
                frame < n ? Float(-1 + 2 * Double(frame) / Double(n - 1)) : 1
            }
            buffer.process(with: chain)
            return Set(buffer.samples(0)[latency..<(latency + n)]).count
        }
        let six = try levelCount(bits: 6)
        let sixAndAHalf = try levelCount(bits: 6.5)
        let seven = try levelCount(bits: 7)
        #expect(six == 64)
        #expect(seven == 128)
        // 2^6.5 = 90.5, so a half bit really does sit between the two.
        #expect(sixAndAHalf > six && sixAndAHalf < seven)
    }

    // MARK: - Rate reduction

    @Test("the anti-aliased decimator suppresses an out-of-band tone, the naive one folds it down")
    func antiAliasingSuppressesTheAliasedImage() throws {
        // 9 kHz into a 12 kHz target: the naive fold lands at |9000 - 12000| = 3000 Hz, well inside
        // the band and impossible to confuse with anything else in the signal.
        let toneHz = 9_000.0
        let targetHz = 12_000.0
        let aliasHz = abs(toneHz - targetHz)
        let frames = 48_000

        func aliasAmplitude(_ mode: DegradeSettings.AntiAliasing) throws -> Double {
            var settings = DegradeSettings()
            settings.targetSampleRate = targetHz
            settings.antiAliasing = mode
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
            let tone = DegradeFixtures.sine(frequency: toneHz, amplitude: 0.5,
                                            frames: frames, sampleRate: Self.sr)
            buffer.fill { _, frame in tone[frame] }
            buffer.process(with: chain)
            // Skip the delay line's priming; measure over a whole number of alias cycles.
            let settled = buffer.samples(0)[4_800...]
            return DegradeFixtures.magnitude(of: settled, at: aliasHz, sampleRate: Self.sr)
        }

        let naive = try aliasAmplitude(.none)
        let filtered = try aliasAmplitude(.filtered)

        // The naive path really does produce the alias — otherwise the comparison below is vacuous.
        #expect(naive > 0.25)
        let suppression = DegradeFixtures.decibels(naive / filtered)
        print("anti-alias suppression at \(Int(aliasHz)) Hz: \(String(format: "%.1f", suppression)) dB "
              + "(naive \(String(format: "%.4f", naive)), filtered \(String(format: "%.6f", filtered)))")
        #expect(suppression >= 40)
    }

    @Test("the zero-order hold's imaging survives in both modes, because that is the missing reconstruction filter")
    func holdImagingIsKeptInBothModes() throws {
        // A 2 kHz tone is well inside a 12 kHz target's band, so nothing folds down; what the hold
        // adds is an image at 12000 - 2000 = 10 kHz. It must be there whether or not the input
        // filter is on.
        let frames = 48_000
        func imageAmplitude(_ mode: DegradeSettings.AntiAliasing) throws -> Double {
            var settings = DegradeSettings()
            settings.targetSampleRate = 12_000
            settings.antiAliasing = mode
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
            let tone = DegradeFixtures.sine(frequency: 2_000, amplitude: 0.5,
                                            frames: frames, sampleRate: Self.sr)
            buffer.fill { _, frame in tone[frame] }
            buffer.process(with: chain)
            return DegradeFixtures.magnitude(of: buffer.samples(0)[4_800...], at: 10_000, sampleRate: Self.sr)
        }
        #expect(try imageAmplitude(.none) > 0.02)
        #expect(try imageAmplitude(.filtered) > 0.02)
    }

    // MARK: - Wow and flutter

    @Test("wow modulates pitch by the depth it is asked for, at the rate it is asked for")
    func wowProducesTheExpectedPitchModulation() throws {
        var settings = DegradeSettings()
        settings.wowDepth = 0.02        // 2%: far more than any real deck, and easy to measure
        settings.wowRate = 1.0          // 1 Hz
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)

        let frames = Int(3 * Self.sr)
        let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
        let tone = DegradeFixtures.sine(frequency: 1_000, amplitude: 0.9,
                                        frames: frames, sampleRate: Self.sr)
        buffer.fill { _, frame in tone[frame] }
        buffer.process(with: chain)

        let freqs = DegradeFixtures.zeroCrossingFrequencies(buffer.samples(0),
                                                            sampleRate: Self.sr,
                                                            from: 2_000)
        let lowest = try #require(freqs.min())
        let highest = try #require(freqs.max())
        print("wow: instantaneous pitch ranged \(String(format: "%.2f", lowest)) - "
              + "\(String(format: "%.2f", highest)) Hz around 1000 Hz")
        // 1000 Hz +/- 2%.
        #expect(abs(lowest - 980) < 3)
        #expect(abs(highest - 1_020) < 3)

        // And the wobble happens once per second: count the maxima of the instantaneous frequency
        // over three seconds by looking at how many times it crosses its own mean upwards.
        let mean = freqs.reduce(0, +) / Double(freqs.count)
        var crossings = 0
        for i in 1..<freqs.count where freqs[i - 1] <= mean && freqs[i] > mean { crossings += 1 }
        #expect(crossings == 3)
    }

    @Test("with wow and flutter both off the delay line is transparent apart from its delay")
    func delayLineIsTransparentWhenNotModulated() throws {
        var settings = DegradeSettings()
        settings.drive = 1.0000001   // just enough to keep the chain off the bypass path
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
        let latency = chain.latencyFrames
        let frames = 4_096
        let buffer = PlanarBuffer(channelCount: 1, frameCount: frames + latency)
        let tone = DegradeFixtures.sine(frequency: 997, amplitude: 0.8,
                                        frames: frames + latency, sampleRate: Self.sr)
        buffer.fill { _, frame in frame < frames ? tone[frame] : 0 }
        buffer.process(with: chain)
        let out = buffer.samples(0)
        for i in 0..<frames {
            #expect(abs(out[i + latency] - tone[i]) < 2e-6)
        }
    }

    // MARK: - Noise

    @Test("vinyl noise is seeded, reproducible byte for byte, and changes with the seed")
    func vinylNoiseIsDeterministic() throws {
        func render(seed: UInt64) throws -> [Float] {
            var settings = DegradeSettings(preset: .vinyl)
            settings.seed = seed
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            // Silence in: whatever comes out is entirely the noise generator.
            let buffer = PlanarBuffer(channelCount: 1, frameCount: Int(2 * Self.sr))
            buffer.process(with: chain)
            return buffer.samples(0)
        }

        let a = try render(seed: 12_345)
        let b = try render(seed: 12_345)
        let c = try render(seed: 12_346)

        #expect(a == b)                                   // byte-identical, not merely close
        #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
        #expect(a != c)
        // And it is actually generating something: hiss, rumble and at least a few ticks.
        let peak = a.map { abs($0) }.max() ?? 0
        #expect(peak > 0.01)
        #expect(peak < 0.5)
    }

    @Test("block size does not change the output")
    func outputIsIndependentOfBlockSize() throws {
        func render(blockSize: Int) throws -> [Float] {
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1,
                                         settings: DegradeSettings(preset: .cassette))
            let frames = 20_000
            let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
            let tone = DegradeFixtures.sine(frequency: 220, amplitude: 0.6,
                                            frames: frames, sampleRate: Self.sr)
            buffer.fill { _, frame in tone[frame] }
            buffer.process(with: chain, blockSize: blockSize)
            return buffer.samples(0)
        }
        #expect(try render(blockSize: 64) == (try render(blockSize: 1_024)))
    }

    // MARK: - Saturation

    @Test("every saturation curve is monotonic and finite at an absurd drive", arguments: DegradeSettings.Saturation.allCases)
    func saturationIsMonotonicAndFinite(_ curve: DegradeSettings.Saturation) throws {
        for drive in [1.0, 12.0, 1e6, 1e30] {
            var settings = DegradeSettings()
            settings.saturation = curve
            settings.drive = drive
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let latency = chain.latencyFrames
            let n = 8_192
            let buffer = PlanarBuffer(channelCount: 1, frameCount: n + latency)
            buffer.fill { _, frame in
                frame < n ? Float(-4 + 8 * Double(frame) / Double(n - 1)) : 4
            }
            buffer.process(with: chain)
            let out = buffer.samples(0)

            var previous = -Float.greatestFiniteMagnitude
            for i in latency..<(latency + n) {
                #expect(out[i].isFinite, "\(curve) at drive \(drive) produced \(out[i])")
                #expect(out[i] >= previous - 1e-6, "\(curve) at drive \(drive) went backwards at \(i)")
                previous = out[i]
            }
            // Every curve is normalised to unity small-signal gain, so none of them can make a
            // sample bigger than it arrived. `.none` is the exception on purpose: it is a gain.
            let peak = Double(out.map { abs($0) }.max() ?? 0)
            if curve == .none {
                #expect(peak <= 4 * min(drive, 1e6) * 1.0001)
            } else {
                #expect(peak <= 4.0001, "\(curve) at drive \(drive) amplified a 4.0 peak to \(peak)")
                #expect(peak <= 4.0 / max(drive, 1) + 1e-3)
            }
        }
    }

    @Test("the asymmetric curves generate even harmonics and the symmetric one does not")
    func tapeAndTubeAreAsymmetric() throws {
        func secondHarmonic(_ curve: DegradeSettings.Saturation) throws -> Double {
            var settings = DegradeSettings()
            settings.saturation = curve
            settings.drive = 4
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let frames = 48_000
            let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
            let tone = DegradeFixtures.sine(frequency: 500, amplitude: 0.8,
                                            frames: frames, sampleRate: Self.sr)
            buffer.fill { _, frame in tone[frame] }
            buffer.process(with: chain)
            let settled = buffer.samples(0)[4_800...]
            return DegradeFixtures.magnitude(of: settled, at: 1_000, sampleRate: Self.sr)
        }
        let soft = try secondHarmonic(.soft)
        let tape = try secondHarmonic(.tape)
        let tube = try secondHarmonic(.tube)
        #expect(soft < 1e-3)
        #expect(tape > soft * 10)
        #expect(tube > tape)
    }

    // MARK: - Parameter smoothing

    @Test("a mid-buffer parameter jump produces no sample-to-sample discontinuity")
    func parameterSmoothingHasNoDiscontinuity() throws {
        // DC in, so anything that moves in the output is the parameters moving and nothing else.
        // `drive` starts at 1.2 rather than 1 deliberately: at exactly unity with every other stage
        // off these would be bypass settings, and the chain would be cold — the jump would then be
        // the documented bypass-exit edge rather than the knob turn this test is about. That edge
        // has its own test below.
        var before = DegradeSettings()
        before.drive = 1.2
        before.saturation = .none
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: before)
        let latency = chain.latencyFrames

        let half = 8_192
        let buffer = PlanarBuffer(channelCount: 1, frameCount: half * 2)
        buffer.fill { _, _ in 0.5 }

        var pointers: [UnsafeMutablePointer<Float>?] = [buffer[0]]
        pointers.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: half) }
        var after = before
        after.drive = 6
        after.mix = 0.5
        chain.settings = after
        var second: [UnsafeMutablePointer<Float>?] = [buffer[0] + half]
        second.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: half) }

        let out = buffer.samples(0)
        // Steady states: 0.5 * 1.2 = 0.6, then 0.5 + (0.5 * 6 - 0.5) * 0.5 = 1.75.
        #expect(abs(out[half - 1] - 0.6) < 1e-5)
        #expect(abs(out[half * 2 - 1] - 1.75) < 1e-4)
        // Skip the delay line's priming edge at `latency`, which is the buffer starting, not a knob.
        let worst = DegradeFixtures.largestStep(out, from: latency + 2)
        let unsmoothed = abs(1.75 - 0.6)
        print("smoothing: worst step \(String(format: "%.6f", worst)) vs \(unsmoothed) unsmoothed")
        #expect(worst < 0.01)
        #expect(Double(worst) < unsmoothed / 30)
    }

    @Test("leaving bypass is a mode switch and is allowed to step, unlike a knob")
    func leavingBypassIsTheOneUnsmoothedTransition() throws {
        // The header is explicit that this edge exists: a cold chain reads and writes nothing, so
        // its delay line is empty, and the first block after it joins the path starts from silence.
        // This test is here so the edge stays deliberate rather than becoming a surprise.
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: .clean)
        #expect(chain.isBypassed)
        let buffer = PlanarBuffer(channelCount: 1, frameCount: 8_192)
        buffer.fill { _, _ in 0.5 }
        var first: [UnsafeMutablePointer<Float>?] = [buffer[0]]
        first.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: 2_048) }
        #expect(buffer.samples(0)[0..<2_048].allSatisfy { $0 == 0.5 })   // untouched

        chain.apply(.cassette)
        var second: [UnsafeMutablePointer<Float>?] = [buffer[0] + 2_048]
        second.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: 6_144) }
        // It re-primes over the latency and gets back to a steady output rather than staying broken.
        let tail = buffer.samples(0)[5_000...]
        #expect(tail.allSatisfy { $0.isFinite })
        #expect(abs(Double(tail.reduce(0, +)) / Double(tail.count)) > 0.3)
    }

    @Test("a jump on a real signal is no rougher than either steady state")
    func parameterSmoothingOnAToneAddsNoRoughness() throws {
        var quiet = DegradeSettings()
        quiet.saturation = .soft
        quiet.drive = 1
        quiet.highCut = 18_000
        var loud = quiet
        loud.drive = 8
        loud.highCut = 2_000

        let frames = 16_384
        let tone = DegradeFixtures.sine(frequency: 220, amplitude: 0.5,
                                        frames: frames, sampleRate: Self.sr)

        func steadyStep(_ settings: DegradeSettings) throws -> Float {
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: settings)
            let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
            buffer.fill { _, frame in tone[frame] }
            buffer.process(with: chain)
            return DegradeFixtures.largestStep(buffer.samples(0), from: 4_000)
        }

        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 1, settings: quiet)
        let buffer = PlanarBuffer(channelCount: 1, frameCount: frames)
        buffer.fill { _, frame in tone[frame] }
        let half = frames / 2
        var first: [UnsafeMutablePointer<Float>?] = [buffer[0]]
        first.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: half) }
        chain.settings = loud
        var second: [UnsafeMutablePointer<Float>?] = [buffer[0] + half]
        second.withUnsafeBufferPointer { chain.processInPlace($0.baseAddress!, channelCount: 1, frameCount: half) }

        let switched = DegradeFixtures.largestStep(buffer.samples(0), from: 4_000)
        let bound = max(try steadyStep(quiet), try steadyStep(loud))
        print("smoothing on a tone: switched \(String(format: "%.6f", switched)) vs steady-state bound "
              + "\(String(format: "%.6f", bound))")
        // The switched render slews no faster than the harder of its two endpoints does on its own,
        // which is the honest statement of "no click": drive really does make a sine steeper, and
        // that steepness is the signal, not a discontinuity.
        #expect(switched <= bound * 1.05)
    }

    @Test("settings can be hammered from another thread while the audio thread renders")
    func settingsAreSafeToChangeUnderProcessing() throws {
        // The header promises `dg_set_params` is safe under `dg_process`. This does not prove the
        // absence of a race on its own — that is what the release/acquire epoch in `degrade.c` is
        // for — but it does catch a chain that falls over, produces a NaN, or deadlocks when the
        // two threads actually overlap.
        let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 2,
                                     settings: DegradeSettings(preset: .sp1200))
        let stop = ManagedAtomicFlag()
        let writer = Thread {
            var i = 0
            while !stop.isSet {
                var s = DegradeSettings(preset: DegradeSettings.Preset.allCases[i % DegradeSettings.Preset.allCases.count])
                s.drive = 1 + Double(i % 17) / 4
                s.mix = Double(i % 11) / 10
                chain.settings = s
                i += 1
            }
        }
        writer.start()
        defer { stop.set() }

        let buffer = PlanarBuffer(channelCount: 2, frameCount: 64 * 512)
        buffer.fill { channel, frame in
            Float(0.4 * sin(2 * .pi * 330 * Double(frame) / Self.sr) * (channel == 0 ? 1 : 0.7))
        }
        for _ in 0..<20 { buffer.process(with: chain, blockSize: 512) }

        for c in 0..<2 {
            let s = buffer.samples(c)
            #expect(s.allSatisfy { $0.isFinite })
            #expect((s.map { abs($0) }.max() ?? 0) < 4)
        }
    }

    // MARK: - Settings

    @Test("settings round-trip through Codable and tolerate a blob written before a field existed")
    func settingsRoundTripAndDecodeTolerantly() throws {
        for preset in DegradeSettings.Preset.allCases {
            let settings = DegradeSettings(preset: preset)
            let data = try JSONEncoder().encode(settings)
            let back = try JSONDecoder().decode(DegradeSettings.self, from: data)
            #expect(back == settings)
            #expect(back.matchingPreset == preset)
        }
        let sparse = try JSONDecoder().decode(DegradeSettings.self, from: Data(#"{"drive":2.5}"#.utf8))
        #expect(sparse.drive == 2.5)
        #expect(sparse.bitDepth == DegradeSettings.bitDepthOff)
        #expect(sparse.mix == 1)
        #expect(sparse.saturation == .none)
    }

    @Test("the presets are the machines the header says they are")
    func presetsMatchTheirDocumentedMachines() throws {
        let sp = DegradeSettings(preset: .sp1200)
        #expect(sp.bitDepth == 12)
        #expect(sp.targetSampleRate == 26_040)   // Rossum's own figure for the machine
        #expect(sp.companding == 0)              // "12-bit linear data format"
        #expect(sp.antiAliasing == .none)        // the drop-sample path, artifacts and all

        let mpc = DegradeSettings(preset: .mpc60)
        #expect(mpc.bitDepth == 12)
        #expect(mpc.targetSampleRate == 40_000)
        #expect(mpc.companding > 0)              // "12-bit non-linear"
        #expect(mpc.antiAliasing == .filtered)

        let vinyl = DegradeSettings(preset: .vinyl)
        #expect(abs(vinyl.wowRate - 0.5556) < 0.001)   // one revolution at 33 1/3 rpm
        #expect(vinyl.crackleDensity > 0)

        let cassette = DegradeSettings(preset: .cassette)
        #expect(cassette.wowRate < 4)        // wow is below 4 Hz by convention
        #expect(cassette.flutterRate > 4)    // and flutter above it
        #expect(cassette.wowDepth < 0.01)    // real decks are specified in tenths of a percent
        #expect(cassette.saturation == .tape)
        #expect(cassette.drive > 1)   // tape compression is part of the sound

        #expect(DegradeSettings(preset: .clean).isBypass)
        for preset in DegradeSettings.Preset.allCases where preset != .clean {
            #expect(!DegradeSettings(preset: preset).isBypass, "\(preset) should do something")
        }
    }

    @Test("every preset is stable on a real-ish signal in stereo")
    func presetsAreStable() throws {
        for preset in DegradeSettings.Preset.allCases {
            let chain = try DegradeChain(sampleRate: Self.sr, channelCount: 2,
                                         settings: DegradeSettings(preset: preset))
            let frames = Int(Self.sr)
            let buffer = PlanarBuffer(channelCount: 2, frameCount: frames)
            buffer.fill { channel, frame in
                let t = Double(frame) / Self.sr
                let env = exp(-8 * (t.truncatingRemainder(dividingBy: 0.25)))
                let v = env * (0.6 * sin(2 * .pi * 110 * t) + 0.3 * sin(2 * .pi * 5_400 * t))
                return Float(channel == 0 ? v : v * 0.8)
            }
            buffer.process(with: chain)
            for c in 0..<2 {
                let s = buffer.samples(c)
                #expect(s.allSatisfy { $0.isFinite }, "\(preset) channel \(c) produced a non-finite sample")
                #expect((s.map { abs($0) }.max() ?? 0) < 2.0, "\(preset) channel \(c) ran away")
            }
        }
    }

    @Test("an offline bounce is latency-compensated and reproducible")
    func offlineBounceIsAlignedAndReproducible() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1))
        let frames = 8_192
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        source.frameLength = AVAudioFrameCount(frames)
        let tone = DegradeFixtures.sine(frequency: 330, amplitude: 0.7, frames: frames, sampleRate: Self.sr)
        let data = try #require(source.floatChannelData)
        for i in 0..<frames { data[0][i] = tone[i] }

        var settings = DegradeSettings(preset: .sp1200)
        settings.wowDepth = 0
        let a = try DegradeChain.rendered(source, settings: settings)
        let b = try DegradeChain.rendered(source, settings: settings)
        #expect(a.frameLength == AVAudioFrameCount(frames))

        let outA = try #require(a.floatChannelData)
        let outB = try #require(b.floatChannelData)
        var maxDelta: Float = 0
        for i in 0..<frames {
            #expect(outA[0][i] == outB[0][i])
            maxDelta = max(maxDelta, abs(outA[0][i] - tone[i]))
        }
        // Aligned: the processed signal tracks the source rather than sitting 8 ms behind it. The
        // SP-1200 preset is not transparent, so this is a correlation check, not an equality one.
        #expect(maxDelta < 0.25)
        var sum = 0.0
        for i in 1_000..<frames { sum += Double(outA[0][i]) * Double(tone[i]) }
        #expect(sum > 0)
    }
}
