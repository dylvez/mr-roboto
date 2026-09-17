import Foundation

/// Renders a `SynthVoiceSpec` into a buffer.
///
/// ## These are generators, not a realtime synth
///
/// Nothing here runs on the audio thread. A synthesized kit renders every voice at a small number
/// of velocity layers into WAV files at prepare time (`SynthesizedKit`), and the existing
/// `SampleCache` + `VoiceSampler` then play them. Choke groups, round robin, the velocity curve and
/// offline determinism all come from code that is already tested; A3 only has to make the samples.
///
/// ## Determinism
///
/// `render` is a pure function of `(spec, velocity, sampleRate)`. Every stochastic element comes
/// from `SeededRandom` seeded out of `spec.seed`, so two renders of the same spec are byte
/// identical — including after the spec has been through `kit.json`. The offline-bounce guarantee
/// rests on this: a mix re-rendered tomorrow has to be the same file.
///
/// The noise seed deliberately does **not** depend on velocity. All layers of one voice are the
/// same drum hit harder, not different takes.
public enum DrumSynthesizer {

    /// Renders one hit.
    ///
    /// - Parameters:
    ///   - spec: the voice to render.
    ///   - velocity: MIDI velocity 1…127. Affects level, and — second order, exactly as the ACCENT
    ///     bus does in hardware — the pitch envelope's peak, the decay and the brightness.
    ///   - sampleRate: render rate in hertz.
    /// - Returns: mono float samples, `spec.durationSeconds` long, peaking below 1.0.
    public static func render(_ spec: SynthVoiceSpec, velocity: Int, sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((spec.durationSeconds * sampleRate).rounded()))
        guard sampleRate > 0 else { return [Float](repeating: 0, count: frameCount) }

        let v = Double(min(127, max(1, velocity))) / 127
        var signal = [Double](repeating: 0, count: frameCount)

        let tuned = spec.tone.frequency(tune: spec.controls.tune)
        let pitchPeak = spec.tone.pitchPeakHz > 0
            ? spec.tone.pitchPeakHz * pow(2, spec.velocity.pitchCents * v / 1200)
            : 0
        let toneDecay = spec.tone.decaySeconds(decay: spec.controls.decay)
            * (1 + (spec.velocity.decayFactor - 1) * v)
        var noiseDecay = spec.noise.decaySeconds(decay: spec.controls.decay)
            * (1 + (spec.velocity.decayFactor - 1) * v)
        // The TR-909 snare's TONE knob is a noise *length* control, not a filter. Applied here so
        // the engines below never have to know which machine they are.
        if spec.toneControl == .noiseDecay {
            noiseDecay *= 0.35 + 1.65 * min(max(spec.controls.tone, 0), 1)
        }

        switch spec.engine {
        case .bridgedT:
            addPitchedBody(&signal, spec: spec, tuned: tuned, pitchPeak: pitchPeak,
                           decay: toneDecay, hardBody: false, sampleRate: sampleRate)
        case .pitchedClick:
            addPitchedBody(&signal, spec: spec, tuned: tuned, pitchPeak: pitchPeak,
                           decay: toneDecay, hardBody: true, sampleRate: sampleRate)
        case .dualToneNoise:
            addSnareTones(&signal, spec: spec, tuned: tuned, pitchPeak: pitchPeak,
                          decay: toneDecay, sampleRate: sampleRate)
        case .squareCluster:
            addSquareCluster(&signal, spec: spec, decay: toneDecay, sampleRate: sampleRate)
        case .burstNoise:
            addBursts(&signal, spec: spec, sampleRate: sampleRate)
        case .filteredNoise:
            break // the shared noise path below is the whole voice
        case .ring:
            addRing(&signal, spec: spec, tuned: tuned, decay: toneDecay, sampleRate: sampleRate)
        }

        // The noise channel. `burstNoise` makes its own (it has to retrigger), and everything else
        // that has any noise at all gets it here: snare rattle, tom skin, cymbal wash, 909 hats.
        if spec.engine != .burstNoise, spec.noise.level > 0 {
            addNoise(&signal, spec: spec, decay: noiseDecay, sampleRate: sampleRate)
        }

        // ATTACK scales the click circuit; on every voice but the 909 kick it is 1.
        let hasClick = spec.click.level * spec.controls.attack > 0
        if hasClick, !spec.click.postFilter {
            addClick(&signal, spec: spec, sampleRate: sampleRate)
        }

        // Output stage: fixed high-pass, the TONE low-pass, saturation, LEVEL, velocity.
        applyOutput(&signal, spec: spec, velocity: v, sampleRate: sampleRate)

        // A post-filter click is mixed here instead, scaled by the same LEVEL and velocity gain so
        // the two paths stay in the balance the panel sets.
        if hasClick, spec.click.postFilter {
            var click = [Double](repeating: 0, count: frameCount)
            addClick(&click, spec: spec, sampleRate: sampleRate)
            let gain = spec.controls.level * pow(10, spec.velocity.rangeDB * (v - 1) / 20)
            for i in signal.indices { signal[i] += gain * click[i] }
        }

        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let x = signal[i]
            out[i] = x.isFinite ? Float(min(1, max(-1, x))) : 0
        }

        // A companded, low-rate PCM voice: the `.linn` preset's whole character.
        if let sampled = spec.sampled {
            if sampled.bits > 0 {
                for i in out.indices { out[i] = Float(SynthDegrade.compand(Double(out[i]), bits: sampled.bits)) }
            }
            if sampled.playbackRateHz > 0 {
                out = SynthDegrade.decimate(out, from: sampleRate, to: sampled.playbackRateHz)
            }
            // Quantising and then reconstructing can overshoot the input by a fraction of a dB —
            // rounding up at the top of the companding curve, and the filter's own step response.
            // Real hardware clipped there too; a buffer bound for a sampler must not exceed 1.
            for i in out.indices { out[i] = min(1, max(-1, out[i])) }
        }

        // Nothing may end on a step: these buffers are played as one-shots to their last frame.
        SynthEnvelope.applyFadeOut(&out, seconds: min(0.01, spec.durationSeconds / 4), sampleRate: sampleRate)
        return out
    }

    // MARK: Engines

    /// The 808 kick and toms (`hardBody == false`) and the 909 kick (`hardBody == true`).
    ///
    /// The bridged-T network in the 808 is a band-pass whose feedback makes it self-oscillate; what
    /// comes out is a decaying sine whose frequency is swept upward for the first few milliseconds
    /// by the trigger's envelope. Modelling it as a phase-integrated sine with an exponential pitch
    /// envelope and an exponential VCA reproduces exactly that, and — unlike running a real
    /// time-varying resonator — is numerically exact, which is what makes the tests able to assert
    /// where the fundamental settles.
    ///
    /// `hardBody` adds gentle saturation to the oscillator *before* its VCA rather than after: the
    /// TR-909's VCO puts out a triangle that a diode clipper rounds towards a sine, so the body has
    /// a little more edge than the 808's pure bridged-T ring. It is deliberately gentle — a diode
    /// clipper rounds the peaks of a triangle, it does not square a sine, and over-driving here
    /// leaves the ATTACK circuit nothing to be heard over.
    private static func addPitchedBody(_ signal: inout [Double], spec: SynthVoiceSpec,
                                       tuned: Double, pitchPeak: Double, decay: Double,
                                       hardBody: Bool, sampleRate: Double) {
        var osc = PhaseOscillator()
        let sweep = pitchPeak > 0 ? pitchPeak - tuned : 0
        let pitchEnvelope = spec.tone.pitchEnvelope(tune: spec.controls.tune)
        for i in signal.indices {
            let t = Double(i) / sampleRate
            let f = tuned + sweep * SynthEnvelope.exponential(t: t, t60: pitchEnvelope)
            var body = osc.sine(frequency: f, sampleRate: sampleRate)
            if hardBody { body = SynthShaper.saturate(body, drive: 0.12) }
            let env = SynthEnvelope.percussive(t: t, attack: spec.tone.attackSeconds, t60: decay)
            signal[i] += spec.tone.level * env * body
        }
    }

    /// Both snares: two tuned oscillators (the 808's are two more bridged-T rings) plus the noise
    /// channel. The tuned pair carries the body, the noise carries the snares.
    ///
    /// **The knobs do what Roland says they do, which is not what most emulations assume.** The
    /// service notes describe VR8 (TONE) as setting *"the output ratio of the two"* bridged-T
    /// networks against each other — it is not a tone-versus-noise crossfade — and VR9 (SNAPPY) as
    /// controlling *"the amplitude of snappy envelope"*, i.e. how much trigger reaches the noise
    /// envelope generator. So here TONE balances the two oscillators and SNAPPY raises the noise
    /// without cutting the tone.
    /// <https://archive.org/stream/synthmanual-roland-tr-808-service-notes/rolandtr-808servicenotes_djvu.txt>
    ///
    /// Gordon Reid's Sound on Sound analysis of this circuit is contradicted on this exact point by
    /// two independent circuit readings, so it is deliberately not the source used here.
    /// <https://norgatronics.blogspot.com/2021/11/808-snare-mutations.html>
    private static func addSnareTones(_ signal: inout [Double], spec: SynthVoiceSpec,
                                      tuned: Double, pitchPeak: Double, decay: Double,
                                      sampleRate: Double) {
        var low = PhaseOscillator()
        var high = PhaseOscillator()
        // TUNE moves both oscillators together, keeping their ratio.
        let altTuned = spec.tone.altFrequencyHz * (tuned / max(spec.tone.frequencyHz, 1e-9))
        let sweep = pitchPeak > 0 ? pitchPeak - tuned : 0
        let pitchEnvelope = spec.tone.pitchEnvelope(tune: spec.controls.tune)
        // TONE balances the pair only on the machines that wire it that way (the 808). On the 909
        // TONE is a noise-length control and the two oscillators keep their preset levels.
        let balance = spec.toneControl == .oscillatorBalance
            ? min(max(spec.controls.tone, 0), 1) : 0.5
        let lowGain = spec.tone.level * 2 * (1 - balance)
        let highGain = spec.tone.level * spec.tone.altLevel * 2 * balance
        // The two rings have different Qs and therefore genuinely different decays, which is a
        // documented inconsistency with Roland's own single published figure — see the preset.
        let altDecay = spec.tone.altDecaySeconds > 0 ? spec.tone.altDecaySeconds : decay
        for i in signal.indices {
            let t = Double(i) / sampleRate
            let f = tuned + sweep * SynthEnvelope.exponential(t: t, t60: pitchEnvelope)
            let lowEnv = SynthEnvelope.percussive(t: t, attack: spec.tone.attackSeconds, t60: decay)
            var y = lowGain * lowEnv * low.sine(frequency: f, sampleRate: sampleRate)
            if altTuned > 0 {
                let highEnv = SynthEnvelope.percussive(t: t, attack: spec.tone.attackSeconds, t60: altDecay)
                y += highGain * highEnv * high.sine(frequency: altTuned, sampleRate: sampleRate)
            }
            signal[i] += y
        }
    }

    /// The 808's hats, cymbal and cowbell: a fixed cluster of square oscillators, summed and then
    /// band-passed. The squares are free-running in hardware and are *not* reset by a trigger, but
    /// they are reset here: a fixed start phase is what makes the render deterministic, and the
    /// phase relationship at onset is inaudible against the filter's own ring.
    private static func addSquareCluster(_ signal: inout [Double], spec: SynthVoiceSpec,
                                         decay: Double, sampleRate: Double) {
        let partials = spec.tone.partialsHz.filter { $0 > 0 }
        guard !partials.isEmpty else { return }
        var oscillators = [PhaseOscillator](repeating: PhaseOscillator(), count: partials.count)
        // A small fixed phase offset per oscillator so the six squares do not all step together on
        // the first sample, which would put a single large impulse at t = 0.
        for k in oscillators.indices {
            oscillators[k] = PhaseOscillator(phase: Double(k) * 2 * Double.pi / Double(partials.count))
        }
        var band = Biquad.bandPassUnity(frequency: spec.noise.bandHz, q: spec.noise.bandQ, sampleRate: sampleRate)
        var highPass = Biquad.highPass(frequency: max(spec.noise.highPassHz, 1), sampleRate: sampleRate)
        // 1/sqrt(n), not 1/n: the six oscillators are at unrelated frequencies, so their sum grows
        // like uncorrelated signals and dividing by the count would leave the hats 8 dB below where
        // a single oscillator sits.
        let scale = 1 / Double(partials.count).squareRoot()
        for i in signal.indices {
            let t = Double(i) / sampleRate
            var sum = 0.0
            for (k, f) in partials.enumerated() {
                sum += oscillators[k].square(frequency: f, sampleRate: sampleRate)
            }
            var y = band.process(sum * scale)
            if spec.noise.highPassHz > 0 { y = highPass.process(y) }
            let env = SynthEnvelope.percussive(t: t, attack: spec.tone.attackSeconds, t60: decay)
            signal[i] += spec.tone.level * env * y
        }
    }

    /// The clap: several very short noise bursts a few milliseconds apart, then one longer,
    /// quieter burst that decays smoothly — the "room" the circuit fakes with a slow RC.
    private static func addBursts(_ signal: inout [Double], spec: SynthVoiceSpec, sampleRate: Double) {
        guard let burst = spec.burst else { return }
        var rng = SeededRandom(seed: spec.seed &+ UInt64(0x5B))
        var band = Biquad.bandPassUnity(frequency: spec.noise.bandHz, q: spec.noise.bandQ, sampleRate: sampleRate)
        var highPass = Biquad.highPass(frequency: max(spec.noise.highPassHz, 1), sampleRate: sampleRate)
        let tailStart = Double(max(0, burst.count - 1)) * burst.intervalSeconds
        let tailDecay = spec.noise.decaySeconds(decay: spec.controls.decay)
        for i in signal.indices {
            let t = Double(i) / sampleRate
            var source = rng.bipolar()
            var y = band.process(source)
            if spec.noise.highPassHz > 0 { y = highPass.process(y) }
            source = y

            // The bursts. The circuit retriggers the same noise VCA, so they overlap rather than
            // replace one another; each is the same envelope started `interval` later.
            var envelope = 0.0
            for k in 0..<max(1, burst.count - 1) {
                let onset = Double(k) * burst.intervalSeconds
                if t >= onset {
                    envelope += SynthEnvelope.exponential(t: t - onset, t60: burst.burstDecaySeconds)
                }
            }
            // The tail: the last trigger opens the VCA onto a much slower discharge.
            if t >= tailStart {
                envelope += burst.tailLevel
                    * SynthEnvelope.exponential(t: t - tailStart, t60: max(tailDecay, burst.tailDecaySeconds))
            }
            signal[i] += spec.noise.level * envelope * source
        }
    }

    /// A rim shot: high-Q resonances that ring for a few tens of milliseconds and are then clipped
    /// hard. The TR-909's rim is the one voice on that machine that *is* a bridged-T circuit — three
    /// of them, at documented frequencies — so `partialsHz` carries any resonances beyond the pair
    /// in `frequencyHz`/`altFrequencyHz`. <http://www.network-909.de/rimshot.htm>
    private static func addRing(_ signal: inout [Double], spec: SynthVoiceSpec,
                                tuned: Double, decay: Double, sampleRate: Double) {
        var osc = PhaseOscillator()
        var alt = PhaseOscillator()
        let extras = spec.tone.partialsHz.filter { $0 > 0 }
        var extraOscillators = [PhaseOscillator](repeating: PhaseOscillator(), count: extras.count)
        for i in signal.indices {
            let t = Double(i) / sampleRate
            let env = SynthEnvelope.percussive(t: t, attack: spec.tone.attackSeconds, t60: decay)
            var y = osc.sine(frequency: tuned, sampleRate: sampleRate)
            if spec.tone.altFrequencyHz > 0 {
                y += spec.tone.altLevel * alt.sine(frequency: spec.tone.altFrequencyHz, sampleRate: sampleRate)
            }
            for (k, f) in extras.enumerated() {
                y += spec.tone.altLevel * extraOscillators[k].sine(frequency: f, sampleRate: sampleRate)
            }
            signal[i] += spec.tone.level * env * y
        }
    }

    /// The shared noise channel: white noise through an optional high-pass and a band-pass, with
    /// its own VCA. SNAPPY raises it against the tuned oscillators.
    private static func addNoise(_ signal: inout [Double], spec: SynthVoiceSpec,
                                 decay: Double, sampleRate: Double) {
        var rng = SeededRandom(seed: spec.seed &+ UInt64(0x9E))
        var band = Biquad.bandPassUnity(frequency: spec.noise.bandHz, q: spec.noise.bandQ, sampleRate: sampleRate)
        var highPass = Biquad.highPass(frequency: max(spec.noise.highPassHz, 1), sampleRate: sampleRate)
        // SNAPPY scales the trigger into the noise envelope generator, so on a snare it is the
        // noise channel's level. Everything else takes its noise level straight from the spec.
        let gain = spec.engine == .dualToneNoise
            ? spec.noise.level * 2 * min(max(spec.controls.snappy, 0), 1)
            : spec.noise.level
        for i in signal.indices {
            let t = Double(i) / sampleRate
            var y = band.process(rng.bipolar())
            if spec.noise.highPassHz > 0 { y = highPass.process(y) }
            let env = SynthEnvelope.percussive(t: t, attack: spec.noise.attackSeconds, t60: decay)
            signal[i] += gain * env * y
        }
    }

    /// The attack transient. Part impulse (the trigger pulse leaking past the oscillator) and part
    /// noise, high-passed so it reads as a click on top of the body rather than as more body.
    private static func addClick(_ signal: inout [Double], spec: SynthVoiceSpec, sampleRate: Double) {
        var rng = SeededRandom(seed: spec.seed &+ UInt64(0xC1))
        var highPass = Biquad.highPass(frequency: max(spec.click.highPassHz, 1), sampleRate: sampleRate)
        let noiseFraction = min(max(spec.click.noiseFraction, 0), 1)
        // A 1 ms pulse: the width of the 808's own trigger pulse.
        // <https://www.baratatronix.com/blog/808-bd-synthesis>
        let pulseFrames = max(1, Int(0.001 * sampleRate))
        for i in signal.indices {
            let t = Double(i) / sampleRate
            let pulse = i < pulseFrames ? 1.0 - Double(i) / Double(pulseFrames) : 0
            let source = (1 - noiseFraction) * pulse + noiseFraction * rng.bipolar()
            let y = highPass.process(source)
            let env = SynthEnvelope.exponential(t: t, t60: spec.click.decaySeconds)
            signal[i] += spec.click.level * max(0, spec.controls.attack) * env * y
        }
    }

    // MARK: Output

    private static func applyOutput(_ signal: inout [Double], spec: SynthVoiceSpec,
                                    velocity v: Double, sampleRate: Double) {
        let brightness = 1 + (spec.velocity.brightnessFactor - 1) * v
        // Only where TONE is wired to the output filter; otherwise the filter sits at its midpoint
        // and TONE is doing something else entirely (see `SynthToneControl`).
        let knob = spec.toneControl == .outputLowPass ? spec.controls.tone : 0.5
        let toneHz = spec.output.toneHz(knob) * brightness
        var lowPass = Biquad.lowPass(frequency: toneHz, sampleRate: sampleRate)
        var highPass = Biquad.highPass(frequency: max(spec.output.highPassHz, 1), sampleRate: sampleRate)
        // Velocity is a level change first and foremost: rangeDB from velocity 1 to 127.
        let gain = spec.controls.level * pow(10, spec.velocity.rangeDB * (v - 1) / 20)
        for i in signal.indices {
            var y = signal[i]
            if spec.output.highPassHz > 0 { y = highPass.process(y) }
            y = lowPass.process(y)
            y = SynthShaper.saturate(y, drive: spec.output.drive)
            signal[i] = gain * y
        }
    }
}
