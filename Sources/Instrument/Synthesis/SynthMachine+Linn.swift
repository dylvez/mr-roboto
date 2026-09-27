import Foundation

// MARK: - LinnDrum
//
// The LM-1 (1980) and the LinnDrum (1982) are the sampled-machine flavour. Nothing in them is
// synthesized: every drum voice is a short recording of a real kit — mostly played by the session
// drummer Art Wood — burned into EPROM, stored as **8-bit companded** data, and clocked out through
// a µ-law DAC at a fixed rate per voice. The TUNE pots (on the *rear* panel, one per voice) vary
// that clock, so tuning a voice down makes it longer and duller as well as lower: tape behaviour,
// nothing like moving an 808's resonance.
//
// There is therefore no circuit to model. What this preset does is generate a plausible acoustic
// drum and then put it through the parts of the machine that *are* reproducible:
//
//   * **µ-255 companding at 8 bits.** Roger Linn: "8 bit *companding*, an encoding method developed
//     by Bell Telephone… concentrated the 256 steps more densely around the zero crossing". The
//     part is an **AM6070**, whose datasheet gives a 15-segment µ-255 law and "72 dB dynamic range
//     equivalent to that achieved by a 12-bit converter". `SynthDegrade.compand` is that law.
//     <https://www.kvraudio.com/forum/viewtopic.php?t=567891>
//     <https://www.polynominal.com/roger-Linn-lm1/assets/files/Linn%20LM-1%20Drum%20Service%20Manual.pdf>
//   * **Decimation with no anti-alias filter in front of it.** This was deliberate. Roger Linn:
//     "I didn't incorporate strict textbook digital sampling theory… filtering on playback would
//     have made some of the drums sound pretty dull. Instead, I let some of the frequencies above
//     that point get through, because the results — which can get distorted — sounded like the
//     sizzle of drums anyway." The fold-down that produces is the machine's character.
//   * **A low-pass on the voices that had one.** The LM-1 Rev.2/3 put a **CEM3320, 24 dB/oct at zero
//     Q**, on the kick, toms and congas, swept by an envelope, specifically "to remove the horrible
//     8-bit quantization noise". Rev.1 had none — a Rev.1 and a Rev.2 LM-1 are materially different
//     instruments. The static two-pole low-pass in `SynthOutput` here is a coarse stand-in for the
//     swept four-pole; it is the one place this preset knowingly simplifies a documented circuit.
//
// ## Sample rates, and why they are uncertain
//
// * LM-1: Roger Linn says **28 kHz** on his own museum page and "**around 27 kHz**" in interviews.
//   Both figures are his. Nobody reconciles them.
// * LinnDrum: described as **35 kHz** ("beefed up… from 28 to a 35 kHz sample rate"), while
//   Wikipedia's infobox says **28–35 kHz**, which may mean genuine per-voice variation or may be
//   sloppy. Unresolved.
// * **No per-voice rate table exists for either machine.** Per-voice rates are real — each generator
//   has its own oscillator and its own tuning pot — but nobody has published them. The split used
//   below (35 kHz for the metal, 28 kHz for the drums) is **ours**, chosen so the cymbals keep their
//   top end, not quoted from anywhere.
//
// Two more documented facts worth knowing, neither of which this model reproduces:
//   * The **hi-hat ROM free-runs**: its counters are always counting, so a trigger only opens the
//     VCA and every hat hit starts at a different point in the loop. That is why LM-1 hats do not
//     sound machine-gunned. Here the hats are identical from hit to hit, which is the price of the
//     determinism the whole of A3 is built on.
//   * **Every other voice is hard-truncated** when its address counter reaches the end of the ROM;
//     there is no release tail. A 2 KB 2716 at 28 kHz is about 73 ms of audio.
//   * There is **no crash or ride on the LM-1** — "cymbals weren't included due to the high cost of
//     long sounds". They arrived with the LinnDrum, which is the machine this preset is named for.

extension SynthMachine {

    /// The LinnDrum flavour: acoustic drums, 8-bit µ-law, clocked out of ROM.
    public static let linn = SynthMachine(
        id: "linn",
        name: "LinnDrum",
        summary: "LinnDrum flavour: acoustic drums companded to 8 bits and clocked out of ROM.",
        voices: withPercussion([linnKick, linnSnare, linnClosedHat, linnOpenHat, linnClap, linnRim,
                 linnLowTom, linnMidTom, linnHighTom, linnCowbell, linnCrash, linnRide], "linn", seed: 0x11AA0900)
    )

    /// Attaches the `sampled` stage that makes a voice a LinnDrum voice.
    private static func linnVoice(_ spec: SynthVoiceSpec, rateHz: Double, seed: UInt64) -> SynthVoiceSpec {
        var out = spec
        out.machine = "linn"
        out.seed = seed
        out.sampled = SynthSampled(bits: 8, playbackRateHz: rateHz)
        return out
    }

    /// A short, dead acoustic kick: a low body with a fast pitch drop and a beater click. Nothing
    /// like an 808's sustained ring — this is a recording of a muffled bass drum, and one of the
    /// three voices (with the toms and congas) that got the CEM3320 low-pass, which is why the
    /// output filter here is set dark.
    static let linnKick = linnVoice(SynthVoiceSpec(
        kind: .kick, engine: .pitchedClick, machine: "linn",
        controls: SynthControls(tune: 0.5, decay: 0.4, tone: 0.45, level: 1.0),
        tone: SynthTone(frequencyHz: 62, tuneSemitones: 12, pitchPeakHz: 200,
                        pitchEnvelopeSeconds: 0.020,
                        decayShortestSeconds: 0.1, decayMidSeconds: 0.24, decayLongestSeconds: 0.5,
                        attackSeconds: 0.0006, level: 0.8),
        noise: SynthNoise(level: 0.10, bandHz: 1_800, bandQ: 0.7,
                          decayShortestSeconds: 0.012, decayMidSeconds: 0.02, decayLongestSeconds: 0.04),
        click: SynthClick(level: 0.22, decaySeconds: 0.003, highPassHz: 2_200, noiseFraction: 0.7),
        output: SynthOutput(toneDarkHz: 900, toneBrightHz: 4_500, highPassHz: 30, drive: 0.15),
        velocity: SynthVelocity(rangeDB: 16, decayFactor: 1.1, brightnessFactor: 1.35),
        durationSeconds: 0.6), rateHz: 28_000, seed: 0x1_11_0001)

    /// The machine's most-copied voice: a bright, big acoustic snare, noise-led. It had **no**
    /// CEM3320 filter, so its quantisation noise is part of the sound rather than something the
    /// machine tried to hide.
    static let linnSnare = linnVoice(SynthVoiceSpec(
        kind: .snare, engine: .dualToneNoise, machine: "linn",
        controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.5, snappy: 0.68, level: 0.92),
        tone: SynthTone(frequencyHz: 190, altFrequencyHz: 331, altLevel: 0.6, tuneSemitones: 8,
                        decayShortestSeconds: 0.05, decayMidSeconds: 0.1, decayLongestSeconds: 0.18,
                        altDecaySeconds: 0.06, attackSeconds: 0.0004, level: 0.4),
        noise: SynthNoise(level: 0.7, bandHz: 3_000, bandQ: 0.45, highPassHz: 900,
                          decayShortestSeconds: 0.07, decayMidSeconds: 0.16, decayLongestSeconds: 0.3),
        output: SynthOutput(toneDarkHz: 12_000, toneBrightHz: 12_000, highPassHz: 110, drive: 0.2),
        velocity: SynthVelocity(rangeDB: 16, decayFactor: 1.08, brightnessFactor: 1.2),
        durationSeconds: 0.6), rateHz: 28_000, seed: 0x1_11_0002)

    private static func linnMetal(_ kind: SynthVoiceKind, bandHz: Double, bandQ: Double,
                                  highPassHz: Double, shortest: Double, mid: Double, longest: Double,
                                  knob: Double, level: Double, duration: Double,
                                  rateHz: Double, seed: UInt64) -> SynthVoiceSpec {
        linnVoice(SynthVoiceSpec(
            kind: kind, engine: .filteredNoise, machine: "linn",
            controls: SynthControls(decay: knob, tone: 0.5, level: level),
            tone: SynthTone(tuneSemitones: 0, level: 0),
            noise: SynthNoise(level: 0.8, bandHz: bandHz, bandQ: bandQ, highPassHz: highPassHz,
                              decayShortestSeconds: shortest, decayMidSeconds: mid,
                              decayLongestSeconds: longest, attackSeconds: 0.0002),
            output: SynthOutput(toneDarkHz: 8_000, toneBrightHz: 14_000,
                                highPassHz: highPassHz * 0.6, drive: 0.08),
            velocity: SynthVelocity(rangeDB: 14, brightnessFactor: 1.2),
            durationSeconds: duration), rateHz: rateHz, seed: seed)
    }

    static let linnClosedHat = linnMetal(.closedHat, bandHz: 8_500, bandQ: 0.6, highPassHz: 5_500,
                                         shortest: 0.05, mid: 0.08, longest: 0.14, knob: 0.4,
                                         level: 0.55, duration: 0.25, rateHz: 35_000, seed: 0x1_11_0003)
    static let linnOpenHat = linnMetal(.openHat, bandHz: 7_500, bandQ: 0.55, highPassHz: 4_500,
                                       shortest: 0.18, mid: 0.5, longest: 0.9, knob: 0.5,
                                       level: 0.52, duration: 0.9, rateHz: 35_000, seed: 0x1_11_0004)
    /// The LinnDrum's addition; the LM-1 had no cymbals at all.
    static let linnCrash = linnMetal(.crash, bandHz: 4_000, bandQ: 0.35, highPassHz: 1_800,
                                     shortest: 0.5, mid: 1.3, longest: 2.2, knob: 0.5,
                                     level: 0.48, duration: 1.8, rateHz: 35_000, seed: 0x1_11_0005)
    static let linnRide = linnMetal(.ride, bandHz: 6_000, bandQ: 0.45, highPassHz: 3_000,
                                    shortest: 0.35, mid: 0.9, longest: 1.5, knob: 0.45,
                                    level: 0.46, duration: 1.2, rateHz: 35_000, seed: 0x1_11_0006)

    /// A recorded hand clap — reportedly Tom Petty and the Heartbreakers — rather than a train of
    /// retriggered noise bursts. Fewer, softer transients than an 808's, and a room that is an
    /// actual room. The clap voice is the one with the most ROM behind it: two 2716s in the Rev.2/3
    /// LM-1 against one for most voices.
    static let linnClap = linnVoice(SynthVoiceSpec(
        kind: .clap, engine: .burstNoise, machine: "linn",
        controls: SynthControls(decay: 0.5, tone: 0.5, level: 1.0),
        tone: SynthTone(tuneSemitones: 0, level: 0),
        noise: SynthNoise(level: 0.6, bandHz: 1_300, bandQ: 0.8,
                          decayShortestSeconds: 0.15, decayMidSeconds: 0.26, decayLongestSeconds: 0.45),
        burst: SynthBurst(count: 4, intervalSeconds: 0.012, burstDecaySeconds: 0.016,
                          tailLevel: 0.55, tailDecaySeconds: 0.26),
        output: SynthOutput(toneDarkHz: 3_500, toneBrightHz: 9_000, highPassHz: 300, drive: 0.1),
        velocity: SynthVelocity(rangeDB: 14, brightnessFactor: 1.05),
        durationSeconds: 0.55), rateHz: 28_000, seed: 0x1_11_0007)

    static let linnRim = linnVoice(SynthVoiceSpec(
        kind: .rim, engine: .ring, machine: "linn",
        controls: SynthControls(decay: 0.45, tone: 0.6, level: 0.65),
        tone: SynthTone(frequencyHz: 1_600, altFrequencyHz: 480, altLevel: 0.35, tuneSemitones: 4,
                        decayShortestSeconds: 0.02, decayMidSeconds: 0.04, decayLongestSeconds: 0.07,
                        attackSeconds: 0.0002, level: 0.5),
        noise: SynthNoise(level: 0.16, bandHz: 2_800, bandQ: 0.8,
                          decayShortestSeconds: 0.006, decayMidSeconds: 0.012, decayLongestSeconds: 0.02),
        output: SynthOutput(toneDarkHz: 5_000, toneBrightHz: 12_000, highPassHz: 350, drive: 0.3),
        velocity: SynthVelocity(rangeDB: 14, brightnessFactor: 1.1),
        durationSeconds: 0.2), rateHz: 28_000, seed: 0x1_11_0008)

    /// Toms and congas: the other voices behind the CEM3320 low-pass, so their filters are dark too.
    private static func linnTom(_ kind: SynthVoiceKind, frequencyHz: Double, t60: Double,
                                seed: UInt64) -> SynthVoiceSpec {
        linnVoice(SynthVoiceSpec(
            kind: kind, engine: .bridgedT, machine: "linn",
            controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.45, level: 0.8),
            tone: SynthTone(frequencyHz: frequencyHz, tuneSemitones: 10,
                            pitchPeakHz: frequencyHz * 1.6, pitchEnvelopeSeconds: 0.03,
                            decayShortestSeconds: t60 * 0.5, decayMidSeconds: t60,
                            decayLongestSeconds: t60 * 1.7, attackSeconds: 0.0006, level: 0.78),
            noise: SynthNoise(level: 0.16, bandHz: 1_100, bandQ: 0.5,
                              decayShortestSeconds: 0.02, decayMidSeconds: 0.035,
                              decayLongestSeconds: 0.06),
            click: SynthClick(level: 0.08, decaySeconds: 0.0025, highPassHz: 1_800, noiseFraction: 0.7),
            output: SynthOutput(toneDarkHz: 1_200, toneBrightHz: 5_000, highPassHz: 40, drive: 0.14),
            velocity: SynthVelocity(rangeDB: 14, pitchCents: 80, decayFactor: 1.08, brightnessFactor: 1.25),
            durationSeconds: max(0.6, t60 * 1.8)), rateHz: 28_000, seed: seed)
    }

    static let linnLowTom = linnTom(.lowTom, frequencyHz: 95, t60: 0.6, seed: 0x1_11_0009)
    static let linnMidTom = linnTom(.midTom, frequencyHz: 135, t60: 0.5, seed: 0x1_11_000A)
    static let linnHighTom = linnTom(.highTom, frequencyHz: 190, t60: 0.42, seed: 0x1_11_000B)

    /// The cowbell had its own 2716, like the clave. Its spectrum is close enough to the 808's two
    /// squares that the same generator serves, companded and decimated. The output filter is pulled
    /// down from the 808's setting because the cowbell is one of the voices with **no** CEM3320 in
    /// front of it, so eight bits of quantisation noise on a narrow-band source would otherwise sit
    /// right on top of it.
    static let linnCowbell: SynthVoiceSpec = {
        var spec = SynthMachine.tr808Cowbell
        spec.machine = "linn"
        spec.seed = 0x1_11_000C
        spec.output = SynthOutput(toneDarkHz: 2_400, toneBrightHz: 5_000, highPassHz: 350, drive: 0.2)
        spec.sampled = SynthSampled(bits: 8, playbackRateHz: 28_000)
        return spec
    }()
}
