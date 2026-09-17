import Foundation
import Testing
@testable import Instrument

/// What the synthesizer promises: the same spec always makes the same samples, every voice lands
/// where its machine's circuit puts it, the knobs do what the panel says, and nothing ever produces
/// a sample a sampler cannot play.
@Suite("Drum synthesizer")
struct DrumSynthesizerTests {
    static let sr: Double = 48_000

    // MARK: Determinism

    @Test("two renders of the same spec are byte identical")
    func rendersAreDeterministic() {
        for spec in SynthMachine.all.flatMap(\.voices) {
            let a = DrumSynthesizer.render(spec, velocity: 100, sampleRate: Self.sr)
            let b = DrumSynthesizer.render(spec, velocity: 100, sampleRate: Self.sr)
            #expect(a == b, "\(spec.machine) \(spec.kind.rawValue) is not deterministic")
        }
    }

    @Test("a spec renders identically after a round trip through JSON")
    func jsonRoundTripPreservesTheRender() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for spec in SynthMachine.all.flatMap(\.voices) {
            let decoded = try decoder.decode(SynthVoiceSpec.self, from: encoder.encode(spec))
            #expect(decoded == spec, "\(spec.machine) \(spec.kind.rawValue) changed value in JSON")
            let before = DrumSynthesizer.render(spec, velocity: 96, sampleRate: Self.sr)
            let after = DrumSynthesizer.render(decoded, velocity: 96, sampleRate: Self.sr)
            #expect(before == after, "\(spec.machine) \(spec.kind.rawValue) renders differently after JSON")
        }
    }

    @Test("the seed, and only the seed, decides the noise")
    func seedDecidesTheNoise() throws {
        let snare = try #require(SynthMachine.tr808.spec(for: .snare))
        var reseeded = snare
        reseeded.seed = snare.seed &+ 1
        let a = DrumSynthesizer.render(snare, velocity: 110, sampleRate: Self.sr)
        let b = DrumSynthesizer.render(reseeded, velocity: 110, sampleRate: Self.sr)
        #expect(a != b, "changing the seed did not change the noise")
        #expect(a.count == b.count)
        // Same drum, though: the envelope and the band are unchanged, so the energy matches closely.
        let energyA = a.reduce(0.0) { $0 + Double($1 * $1) }
        let energyB = b.reduce(0.0) { $0 + Double($1 * $1) }
        #expect(abs(energyA - energyB) / max(energyA, energyB) < 0.2)
    }

    // MARK: Safety

    @Test("no voice clips or produces NaN at any velocity")
    func nothingClipsOrGoesNaN() {
        for spec in SynthMachine.all.flatMap(\.voices) {
            for velocity in [1, 8, 32, 64, 90, 110, 127] {
                let x = DrumSynthesizer.render(spec, velocity: velocity, sampleRate: Self.sr)
                #expect(!x.isEmpty)
                let bad = x.first { !$0.isFinite }
                #expect(bad == nil, "\(spec.machine) \(spec.kind.rawValue) v\(velocity) produced \(bad ?? 0)")
                let peak = SynthMeasure.peak(x)
                #expect(peak <= 1.0, "\(spec.machine) \(spec.kind.rawValue) v\(velocity) peaked at \(peak)")
                #expect(peak > 0, "\(spec.machine) \(spec.kind.rawValue) v\(velocity) is silent")
            }
        }
    }

    @Test("every voice renders at 44.1 kHz and at 96 kHz too")
    func rendersAtOtherRates() {
        for rate in [44_100.0, 96_000.0] {
            for spec in SynthMachine.all.flatMap(\.voices) {
                let x = DrumSynthesizer.render(spec, velocity: 100, sampleRate: rate)
                let finite = x.allSatisfy(\.isFinite)
                #expect(finite, "\(spec.kind.rawValue) at \(rate) went non-finite")
                #expect(SynthMeasure.peak(x) > 0, "\(spec.kind.rawValue) at \(rate) is silent")
            }
        }
    }

    // MARK: The 808 kick

    @Test("the 808 kick settles on its tuned frequency and starts above it")
    func kick808PitchEnvelope() throws {
        var kick = try #require(SynthMachine.tr808.spec(for: .kick))
        let tuned = kick.tone.frequency(tune: kick.controls.tune)
        #expect(kick.tone.pitchPeakHz > tuned * 2, "the spec has no upward pitch envelope")

        // The click is measured separately; here it would sit on top of the first half cycle and
        // move the zero crossing this test reads.
        kick.click.level = 0
        let x = DrumSynthesizer.render(kick, velocity: 110, sampleRate: Self.sr)

        // Where the body settles: a DFT over the sustained part, long after the 6 ms sweep.
        let settled = SynthMeasure.dominantFrequency(x, in: Int(0.02 * Self.sr)..<Int(0.20 * Self.sr),
                                                     band: 30...200, sampleRate: Self.sr, resolution: 0.5)
        #expect(abs(settled - tuned) < 3, "808 kick settled at \(settled) Hz, tuned to \(tuned) Hz")

        // That the attack is *higher* has to be measured cycle by cycle: the whole sweep is worth
        // less than a tenth of a cycle of extra phase at 49 Hz, which is exactly why it is heard as
        // snap and not as a bend. Half-period lengths give the instantaneous frequency directly.
        let crossings = Self.zeroCrossings(x, limit: 6)
        #expect(crossings.count >= 3, "found only \(crossings.count) zero crossings in the kick")
        let firstHalfPeriod = crossings[0]
        let laterHalfPeriod = crossings[2] - crossings[1]
        let firstFrequency = 0.5 / firstHalfPeriod
        let laterFrequency = 0.5 / laterHalfPeriod
        #expect(firstFrequency > laterFrequency * 1.08,
                "first half cycle implies \(firstFrequency) Hz, later \(laterFrequency) Hz — no sweep")
        #expect(abs(laterFrequency - tuned) < 3,
                "after the sweep the ring is at \(laterFrequency) Hz, tuned to \(tuned) Hz")
    }

    /// Times, in seconds, of the first `limit` zero crossings in either direction, linearly
    /// interpolated. Consecutive gaps are therefore half-periods, which is the finest resolution
    /// available for "what was the frequency right now".
    static func zeroCrossings(_ x: [Float], limit: Int) -> [Double] {
        var times: [Double] = []
        for i in 1..<x.count where (x[i - 1] >= 0) != (x[i] >= 0) {
            let t = Double(abs(x[i - 1])) / Double(abs(x[i - 1]) + abs(x[i]))
            times.append((Double(i - 1) + t) / sr)
            if times.count == limit { break }
        }
        return times
    }

    @Test("the 808 kick's DECAY knob changes the time to -60 dB across the documented range")
    func kick808DecayKnob() throws {
        var kick = try #require(SynthMachine.tr808.spec(for: .kick))
        kick.durationSeconds = 4.0

        var shortest = kick; shortest.controls.decay = 0
        var centre = kick; centre.controls.decay = 0.5
        var longest = kick; longest.controls.decay = 1

        let t60Short = SynthMeasure.decayTime(DrumSynthesizer.render(shortest, velocity: 110, sampleRate: Self.sr),
                                              toDB: 60, sampleRate: Self.sr)
        let t60Centre = SynthMeasure.decayTime(DrumSynthesizer.render(centre, velocity: 110, sampleRate: Self.sr),
                                               toDB: 60, sampleRate: Self.sr)
        let t60Long = SynthMeasure.decayTime(DrumSynthesizer.render(longest, velocity: 110, sampleRate: Self.sr),
                                             toDB: 60, sampleRate: Self.sr)

        // Monotone, and spanning the range the hardware's DECAY knob covers. Roland publishes
        // 50 / 300 / 800 ms as time-to-one-tenth, so the T60 targets are 0.15 / 0.9 / 2.4 s.
        #expect(t60Short < t60Centre && t60Centre < t60Long,
                "decay is not monotone: \(t60Short), \(t60Centre), \(t60Long)")
        #expect(t60Short > 0.08 && t60Short < 0.3,
                "shortest decay measured \(t60Short) s, expected near 0.15 s")
        #expect(t60Centre > 0.6 && t60Centre < 1.3,
                "centre decay measured \(t60Centre) s, expected near 0.9 s")
        #expect(t60Long > 1.8, "longest decay measured \(t60Long) s, expected near 2.4 s")
    }

    @Test("the 808 kick's TUNE knob moves the fundamental")
    func kick808TuneKnob() throws {
        var low = try #require(SynthMachine.tr808.spec(for: .kick))
        var high = low
        low.controls.tune = 0
        high.controls.tune = 1
        let lowF = low.tone.frequency(tune: 0)
        let highF = high.tone.frequency(tune: 1)
        #expect(highF > lowF * 1.2)

        let range = Int(0.02 * Self.sr)..<Int(0.15 * Self.sr)
        let measuredLow = SynthMeasure.dominantFrequency(
            DrumSynthesizer.render(low, velocity: 110, sampleRate: Self.sr),
            in: range, band: 20...200, sampleRate: Self.sr, resolution: 0.5)
        let measuredHigh = SynthMeasure.dominantFrequency(
            DrumSynthesizer.render(high, velocity: 110, sampleRate: Self.sr),
            in: range, band: 20...200, sampleRate: Self.sr, resolution: 0.5)
        #expect(abs(measuredLow - lowF) < 3, "tuned down to \(lowF) Hz, measured \(measuredLow) Hz")
        #expect(abs(measuredHigh - highF) < 4, "tuned up to \(highF) Hz, measured \(measuredHigh) Hz")
    }

    // MARK: Snares

    @Test("the 808 snare carries both of its documented tone oscillators")
    func snare808TwoOscillators() throws {
        var snare = try #require(SynthMachine.tr808.spec(for: .snare))
        // Turn SNAPPY down so the tuned pair is what dominates; the noise band sits well above both.
        snare.controls.snappy = 0
        let x = DrumSynthesizer.render(snare, velocity: 110, sampleRate: Self.sr)
        let window = Int(0.002 * Self.sr)..<Int(0.06 * Self.sr)

        let low = snare.tone.frequencyHz
        let high = snare.tone.altFrequencyHz
        let atLow = SynthMeasure.magnitude(x, at: low, in: window, sampleRate: Self.sr)
        let atHigh = SynthMeasure.magnitude(x, at: high, in: window, sampleRate: Self.sr)
        // A frequency between the two, where neither oscillator sits, must be quieter than both.
        let between = SynthMeasure.magnitude(x, at: (low + high) / 2, in: window, sampleRate: Self.sr)
        #expect(atLow > between * 2, "no peak at the \(low) Hz oscillator")
        #expect(atHigh > between * 2, "no peak at the \(high) Hz oscillator")
    }

    @Test("SNAPPY moves the 808 snare's balance from tone to noise")
    func snare808SnappyControl() throws {
        var dry = try #require(SynthMachine.tr808.spec(for: .snare))
        var snappy = dry
        dry.controls.snappy = 0
        snappy.controls.snappy = 1
        let window = Int(0.002 * Self.sr)..<Int(0.08 * Self.sr)
        let dryCentroid = SynthMeasure.spectralCentroid(
            DrumSynthesizer.render(dry, velocity: 110, sampleRate: Self.sr), in: window, sampleRate: Self.sr)
        let snappyCentroid = SynthMeasure.spectralCentroid(
            DrumSynthesizer.render(snappy, velocity: 110, sampleRate: Self.sr), in: window, sampleRate: Self.sr)
        #expect(snappyCentroid > dryCentroid * 1.3,
                "SNAPPY moved the centroid from \(dryCentroid) Hz only to \(snappyCentroid) Hz")
    }

    @Test("the 909 snare is noise dominant where the 808's is tone dominant")
    func snare909IsNoiseDominant() throws {
        let snare808 = try #require(SynthMachine.tr808.spec(for: .snare))
        let snare909 = try #require(SynthMachine.tr909.spec(for: .snare))
        let window = Int(0.002 * Self.sr)..<Int(0.08 * Self.sr)
        let c808 = SynthMeasure.spectralCentroid(
            DrumSynthesizer.render(snare808, velocity: 110, sampleRate: Self.sr), in: window, sampleRate: Self.sr)
        let c909 = SynthMeasure.spectralCentroid(
            DrumSynthesizer.render(snare909, velocity: 110, sampleRate: Self.sr), in: window, sampleRate: Self.sr)
        #expect(c909 > c808, "909 snare centroid \(c909) Hz is not above the 808's \(c808) Hz")
    }

    // MARK: Hats, cymbals, cowbell

    @Test("every hat, cymbal and cowbell sits in the band its filter defines")
    func brightVoicesSitInTheirBand() {
        let bright: Set<SynthVoiceKind> = [.closedHat, .openHat, .crash, .ride, .cowbell]
        for machine in SynthMachine.all {
            for spec in machine.voices where bright.contains(spec.kind) {
                let x = DrumSynthesizer.render(spec, velocity: 110, sampleRate: Self.sr)
                let window = Int(0.001 * Self.sr)..<min(x.count, Int(0.06 * Self.sr))
                let centroid = SynthMeasure.spectralCentroid(x, in: window, sampleRate: Self.sr)
                // Within a factor of 2.5 of the band-pass centre in either direction: a band-pass
                // of this Q, fed squares or noise, cannot put its energy anywhere else.
                let band = spec.noise.bandHz
                #expect(centroid > band / 2.5 && centroid < band * 2.5,
                        "\(machine.id) \(spec.kind.rawValue): centroid \(centroid) Hz against a \(band) Hz band")
            }
        }
    }

    @Test("the 808 open hat rings far longer than the closed hat")
    func openHatRingsLonger() throws {
        let closed = try #require(SynthMachine.tr808.spec(for: .closedHat))
        let open = try #require(SynthMachine.tr808.spec(for: .openHat))
        let tClosed = SynthMeasure.decayTime(DrumSynthesizer.render(closed, velocity: 110, sampleRate: Self.sr),
                                             toDB: 40, sampleRate: Self.sr)
        let tOpen = SynthMeasure.decayTime(DrumSynthesizer.render(open, velocity: 110, sampleRate: Self.sr),
                                           toDB: 40, sampleRate: Self.sr)
        #expect(tOpen > tClosed * 4, "closed \(tClosed) s vs open \(tOpen) s")
        #expect(tClosed < 0.12, "808 closed hat decayed in \(tClosed) s, expected a few tens of ms")
    }

    @Test("the 808 cowbell is two of the hi-hat's squares")
    func cowbellUsesHatOscillators() throws {
        let hat = try #require(SynthMachine.tr808.spec(for: .closedHat))
        let cowbell = try #require(SynthMachine.tr808.spec(for: .cowbell))
        #expect(cowbell.tone.partialsHz.count == 2)
        for f in cowbell.tone.partialsHz {
            #expect(hat.tone.partialsHz.contains { abs($0 - f) < 0.001 },
                    "\(f) Hz is not one of the hi-hat's oscillators")
        }
    }

    // MARK: Clap

    @Test("the 808 clap produces its documented number of transients")
    func clapTransients() throws {
        let clap = try #require(SynthMachine.tr808.spec(for: .clap))
        let burst = try #require(clap.burst)
        #expect(burst.count == 4, "the 808 clap is three retriggers plus the final discharge")
        #expect(abs(burst.intervalSeconds - 0.010) < 0.0005, "the retrigger oscillator runs at 100 Hz")

        let x = DrumSynthesizer.render(clap, velocity: 110, sampleRate: Self.sr)
        // Four amplitude events: the envelope is retriggered three times, 10 ms apart, and then the
        // last trigger opens the second VCA onto the long discharge that is the machine's room.
        let window = 0..<min(x.count, Int((Double(burst.count) * burst.intervalSeconds + 0.006) * Self.sr))
        let count = SynthMeasure.transientCount(Array(x[window]), sampleRate: Self.sr)
        #expect(count == burst.count, "counted \(count) transients, expected \(burst.count)")

        // And nothing more after that: the retrigger oscillator stops.
        let after = Array(x[window.upperBound...])
        let tailTransients = SynthMeasure.transientCount(after, sampleRate: Self.sr)
        #expect(tailTransients <= 1, "the clap kept retriggering into its tail (\(tailTransients))")

        // The tail really is longer than the burst train.
        let total = SynthMeasure.decayTime(x, toDB: 40, sampleRate: Self.sr)
        #expect(total > Double(burst.count) * burst.intervalSeconds * 3,
                "clap tail is \(total) s, barely longer than its \(burst.count) bursts")
    }

    // MARK: Velocity

    @Test("velocity is level first, with only a second-order effect on timbre")
    func velocityIsMostlyLevel() throws {
        let kick = try #require(SynthMachine.tr808.spec(for: .kick))
        let soft = DrumSynthesizer.render(kick, velocity: 32, sampleRate: Self.sr)
        let hard = DrumSynthesizer.render(kick, velocity: 127, sampleRate: Self.sr)
        let ratio = Double(SynthMeasure.peak(hard) / SynthMeasure.peak(soft))
        let dB = 20 * log10(ratio)
        // The spec asks for `rangeDB` across the whole velocity span; 32→127 is most of it.
        #expect(dB > 6 && dB < kick.velocity.rangeDB + 2,
                "velocity 32 to 127 moved the peak by \(dB) dB")
    }

    @Test("the voices that were samples in hardware are the ones with a sampled block")
    func sampledVoicesAreTheSampledOnes() throws {
        // Nothing in a TR-808 is a sample.
        for spec in SynthMachine.tr808.voices {
            #expect(spec.sampled == nil, "808 \(spec.kind.rawValue) should be analog")
        }
        // On the TR-909 the hats and cymbals were 6-bit PCM in ROM; everything else is a circuit.
        let sampled909: Set<SynthVoiceKind> = [.closedHat, .openHat, .crash, .ride]
        for spec in SynthMachine.tr909.voices {
            if sampled909.contains(spec.kind) {
                let block = try #require(spec.sampled, "909 \(spec.kind.rawValue) was a sample")
                #expect(block.bits == 6, "the 909's cymbal ROM is 6-bit, not \(block.bits)")
                // ~60 kHz NAND oscillator divided by two. Not the 25 kHz that circulates, which is
                // a TR-707 figure.
                #expect(block.playbackRateHz > 28_000 && block.playbackRateHz < 33_000,
                        "909 sample clock set to \(block.playbackRateHz) Hz")
            } else {
                #expect(spec.sampled == nil, "909 \(spec.kind.rawValue) should be analog")
            }
        }
        // Every LinnDrum voice was a sample.
        for spec in SynthMachine.linn.voices {
            let block = try #require(spec.sampled, "linn \(spec.kind.rawValue) has no sampled block")
            #expect(block.bits == 8, "the LinnDrum is 8-bit companded, not \(block.bits)")
        }
    }

    @Test("companding and decimation actually change the signal")
    func sampledStageChangesTheSignal() throws {
        let linn = try #require(SynthMachine.linn.spec(for: .snare))
        var analog = linn
        analog.sampled = nil
        let sampled = DrumSynthesizer.render(linn, velocity: 110, sampleRate: Self.sr)
        let clean = DrumSynthesizer.render(analog, velocity: 110, sampleRate: Self.sr)
        #expect(sampled != clean, "the sampled stage did nothing")
        let finite = sampled.allSatisfy(\.isFinite)
        #expect(finite)
        #expect(SynthMeasure.peak(sampled) > 0)
        #expect(SynthMeasure.peak(sampled) <= 1.0)
    }

    // MARK: Knobs that are not what their names suggest

    @Test("the 909 kick's TUNE knob lengthens the pitch sweep instead of moving the pitch")
    func kick909TuneIsTheSweepTime() throws {
        let kick = try #require(SynthMachine.tr909.spec(for: .kick))
        #expect(kick.tone.tuneSemitones == 0, "909 TUNE should not transpose the drum")
        // The documented 30 ms to 120 ms.
        #expect(abs(kick.tone.pitchEnvelope(tune: 0) - 0.030) < 0.001)
        #expect(abs(kick.tone.pitchEnvelope(tune: 1) - 0.120) < 0.001)

        var short = kick, long = kick
        short.controls.tune = 0
        long.controls.tune = 1
        short.click.level = 0
        long.click.level = 0
        // A longer sweep means the drum is still above its final pitch later on, so the number of
        // zero crossings in a fixed early window is higher.
        let window = Int(0.08 * Self.sr)
        func crossings(_ spec: SynthVoiceSpec) -> Int {
            let x = Array(DrumSynthesizer.render(spec, velocity: 110, sampleRate: Self.sr)[0..<window])
            return (1..<x.count).reduce(0) { $0 + (((x[$1 - 1] >= 0) != (x[$1] >= 0)) ? 1 : 0) }
        }
        #expect(crossings(long) > crossings(short),
                "TUNE up did not lengthen the sweep: \(crossings(long)) vs \(crossings(short))")
    }

    @Test("the 909 snare's TONE knob changes the noise length, not a filter")
    func snare909ToneIsNoiseLength() throws {
        let snare = try #require(SynthMachine.tr909.spec(for: .snare))
        #expect(snare.toneControl == .noiseDecay)
        var dark = snare, bright = snare
        dark.controls.tone = 0
        bright.controls.tone = 1
        let tDark = SynthMeasure.decayTime(DrumSynthesizer.render(dark, velocity: 110, sampleRate: Self.sr),
                                           toDB: 40, sampleRate: Self.sr)
        let tBright = SynthMeasure.decayTime(DrumSynthesizer.render(bright, velocity: 110, sampleRate: Self.sr),
                                             toDB: 40, sampleRate: Self.sr)
        #expect(tBright > tDark * 1.5, "TONE fully up gave \(tBright) s against \(tDark) s")
    }

    @Test("the 909 kick's ATTACK knob is the click circuit's level")
    func kick909AttackIsAClickLevel() throws {
        let kick = try #require(SynthMachine.tr909.spec(for: .kick))
        #expect(kick.click.level > 0, "the 909 kick has no click circuit to control")
        var off = kick, on = kick
        off.controls.attack = 0
        on.controls.attack = 1
        // The click does not raise the *peak*: the body is far louder at the onset. What ATTACK
        // adds is a separate high-passed transient, so the honest measurement is the difference
        // between the two renders, which is exactly the click circuit's contribution.
        let window = 0..<Int(0.006 * Self.sr)
        let quiet = DrumSynthesizer.render(off, velocity: 120, sampleRate: Self.sr)
        let loud = DrumSynthesizer.render(on, velocity: 120, sampleRate: Self.sr)
        let difference = window.map { loud[$0] - quiet[$0] }
        // Peak, not RMS: the click is a few milliseconds long against a body that lasts half a
        // second, so any windowed average buries it while the ear does not.
        let clickPeak = SynthMeasure.peak(difference)
        let bodyPeak = SynthMeasure.peak(Array(quiet[window]))
        #expect(clickPeak > bodyPeak * 0.15,
                "ATTACK contributed a peak of \(clickPeak) against a body of \(bodyPeak)")

        // And what it contributes is high-frequency, which is the point of the circuit.
        let clickCentroid = SynthMeasure.spectralCentroid(difference, in: 0..<difference.count,
                                                          sampleRate: Self.sr)
        let bodyCentroid = SynthMeasure.spectralCentroid(quiet, in: window, sampleRate: Self.sr)
        #expect(clickCentroid > 2_000, "the click's centroid is only \(clickCentroid) Hz")
        #expect(clickCentroid > bodyCentroid * 2,
                "the click's centroid is \(clickCentroid) Hz, the body's \(bodyCentroid) Hz")
    }
}
