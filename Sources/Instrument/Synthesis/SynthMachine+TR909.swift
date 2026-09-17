import Foundation

// MARK: - TR-909
//
// The TR-909 (1983) is a **hybrid**: kick, snare, toms, rim and clap are analog, and the hi-hats,
// crash and ride are PCM samples in ROM. That split is the machine's identity and it is modelled
// honestly here — the sampled voices use the `filteredNoise` engine and say in their comments that
// they approximate a recording rather than model a circuit.
//
// ## Where these numbers come from, and what is missing
//
// Primary sources:
//   * Roland TR-909 Service Notes.
//     <https://archive.org/stream/roland_TR-909_SERVICE_NOTES/TR-909_SERVICE_NOTES_djvu.txt>
//   * network-909.de, a block-by-block reading of the schematic with part designators.
//     <http://www.network-909.de/circuit.htm>
//   * Colin Fraser, who dumped the cymbal ROMs and physically modified the analog voices.
//     <http://www.colinfraser.com/tr909/my909.htm> and <http://www.colinfraser.com/tr909/909cyms.htm>
//   * Robin Whittle, "TR-909 Sound Mods" (2018).
//     <https://www.firstpr.com.au/rwi/tr-909/TR-909-Sound-Mods.pdf>
//
// **The big difference from the 808: Roland published no frequency or decay table for the 909's
// analog voices.** The 808's service notes have a "CHECKING VOICES" table giving a frequency and a
// decay for every voice; the 909's has nothing equivalent. So where the 808 preset quotes Roland,
// this one quotes *structure* (what the circuit is, what each knob is wired to, the one or two
// timings Roland did print) and **approximates every absolute frequency and decay**. Each such value
// is marked `APPROXIMATED`. They are chosen to sound like a 909, not measured from one.
//
// Two figures that circulate widely and are **wrong for this machine**, and are therefore not used:
//   * "238 Hz / 476 Hz" for the 909 snare's oscillators. Those are the **TR-808** service notes'
//     snare figures, misattributed.
//   * "25 kHz" for the 909's sample rate. That is a **TR-707/727** number from a Roland article.
//     The 909's sample clock is a 2-NAND relaxation oscillator at about 60 kHz divided by two.

extension SynthMachine {

    /// The Roland TR-909 (1983): analog kick, snare, toms, rim and clap; sampled metal.
    public static let tr909 = SynthMachine(
        id: "tr909",
        name: "TR-909",
        summary: "Roland TR-909: analog kick, snare and toms; the hats and cymbals were 6-bit samples.",
        voices: [tr909Kick, tr909Snare, tr909ClosedHat, tr909OpenHat, tr909Clap, tr909Rim,
                 tr909LowTom, tr909MidTom, tr909HighTom, tr909Cowbell, tr909Crash, tr909Ride]
    )

    // MARK: Bass drum

    /// **BD.** A **VCO**, not a bridged-T — the 808's kick is a filter that rings and damps itself,
    /// the 909's is an oscillator with envelopes on its pitch and its amplitude. That is the
    /// structural difference behind everything people say about the two kicks.
    ///
    /// The VCO is a hysteresis comparator driving an integrator; its output is a **triangle**, which
    /// a diode clipper rounds towards a sine. (Sound on Sound describes it as a sawtooth through a
    /// waveshaper; every source that reads the schematic — Fraser, Whittle, network-909, Tiptop's
    /// own BD909 notes — says triangle through a diode clipper. The schematic readings are used
    /// here.) `pitchedClick` reproduces that as a sine driven into saturation.
    ///
    /// **TUNE is not a pitch control.** It sets the *decay time of the pitch-sweep envelope*,
    /// documented as covering roughly **30 ms to 120 ms**. Turning it up makes the drop longer, not
    /// the drum higher. That is why the pitch-envelope range, not `tuneSemitones`, is what TUNE
    /// moves here. (network-909 describes VR2 as a modulation *depth* control instead; Fraser and
    /// Whittle both physically modified the circuit and both say decay time, so they win.)
    /// <http://www.colinfraser.com/tr909/my909.htm>
    ///
    /// **ATTACK** is a separate circuit, not a VCA attack time: a pulse (shaped by a low-pass and a
    /// band-pass off the trigger) plus filtered noise, through its own VCA and envelope, mixed with
    /// the oscillator at IC11a. The ATTACK knob is that circuit's level.
    /// <http://www.network-909.de/bassdrum.htm>
    ///
    /// APPROXIMATED: the base frequency and every decay time. Roland published none of them, and the
    /// only absolute figure anywhere near is a clone's ("about 30 Hz to 240 Hz" for the Hexinverter
    /// Mutant BD9), which is a different, extended circuit.
    static let tr909Kick = SynthVoiceSpec(
        kind: .kick, engine: .pitchedClick, machine: "tr909",
        controls: SynthControls(tune: 0.5, decay: 0.45, tone: 0.55, attack: 1.0, level: 1.0),
        tone: SynthTone(
            frequencyHz: 55,                        // APPROXIMATED
            tuneSemitones: 0,                       // TUNE moves the sweep time, not the pitch
            pitchPeakHz: 320,                       // APPROXIMATED
            pitchEnvelopeSeconds: 0.055,
            pitchEnvelopeShortestSeconds: 0.030,    // the documented 30 ms…
            pitchEnvelopeLongestSeconds: 0.120,     // …to 120 ms that TUNE covers
            decayShortestSeconds: 0.12,             // APPROXIMATED
            decayMidSeconds: 0.45,                  // APPROXIMATED
            decayLongestSeconds: 1.2,               // APPROXIMATED
            attackSeconds: 0.0005,
            // Deliberately well below full scale: the ATTACK circuit is summed *after* this, and a
            // body at 0.8 would leave the click nothing but the clipper to live in.
            level: 0.6),
        click: SynthClick(level: 0.35, decaySeconds: 0.004, highPassHz: 1_200, noiseFraction: 0.55,
                          postFilter: true),
        output: SynthOutput(toneDarkHz: 900, toneBrightHz: 7_000, highPassHz: 22, drive: 0.12),
        velocity: SynthVelocity(rangeDB: 14, pitchCents: 200, decayFactor: 1.15, brightnessFactor: 1.3),
        durationSeconds: 1.2, seed: 0x909_0001)

    // MARK: Snare

    /// **SD.** Two VCOs plus two separately filtered noise paths.
    ///
    /// The two oscillators are identical circuits differing only in their charging capacitors (C69
    /// and C71); VCO-1 runs lower. Both are **reset by the trigger**, so they start phase-locked on
    /// every hit — which is exactly what this model does, and for once the fixed start phase is the
    /// hardware's behaviour rather than a concession to determinism.
    ///
    /// **Roland published one timing for this voice and it is the pitch bend: the CV generator
    /// changes VCO-1's charging rate "continuously for about 20 ms", giving "a pitch bend of Snare
    /// drum sound for that period".** That is the `pitchEnvelopeSeconds` below.
    /// <https://archive.org/stream/roland_TR-909_SERVICE_NOTES/TR-909_SERVICE_NOTES_djvu.txt>
    ///
    /// **TONE sets the length of the noise, not a filter.** It is a decay control on the noise
    /// envelope. **SNAPPY is the noise section's gain.** Both are the opposite of what the panel
    /// names suggest, and neither matches the 808's wiring of the same two words.
    /// <https://www.tiptopaudio.com/manuals/Tiptop_Audio_SD909_ns.pdf>
    ///
    /// The noise generator itself is a clocked pseudo-random shift register, not the 808's noisy
    /// transistor junction — so a 909's noise is *deterministic and repeating*, which makes
    /// `SeededRandom` a closer model here than it is anywhere else in this file. (Roland's notes say
    /// two cascaded registers making 32 stages; Whittle says two 18-stage registers. Unresolved, and
    /// it does not change the model.)
    ///
    /// APPROXIMATED: both oscillator frequencies and every decay.
    static let tr909Snare = SynthVoiceSpec(
        kind: .snare, engine: .dualToneNoise, machine: "tr909",
        controls: SynthControls(tune: 0.5, decay: 0.45, tone: 0.5, snappy: 0.62, level: 0.9),
        toneControl: .noiseDecay,
        tone: SynthTone(
            frequencyHz: 185,                   // APPROXIMATED
            altFrequencyHz: 330,                // APPROXIMATED
            altLevel: 0.55,
            tuneSemitones: 10,
            pitchPeakHz: 260,
            pitchEnvelopeSeconds: 0.020,        // Roland's published ~20 ms pitch bend
            decayShortestSeconds: 0.05,
            decayMidSeconds: 0.11,
            decayLongestSeconds: 0.2,
            altDecaySeconds: 0.07,
            attackSeconds: 0.0004,
            level: 0.38),                       // quieter than the 808's: the noise leads here
        noise: SynthNoise(level: 0.72, bandHz: 3_600, bandQ: 0.5, highPassHz: 1_200,
                          decayShortestSeconds: 0.05, decayMidSeconds: 0.16,
                          decayLongestSeconds: 0.45, attackSeconds: 0.0002),
        output: SynthOutput(toneDarkHz: 16_000, toneBrightHz: 16_000, highPassHz: 120, drive: 0.18),
        velocity: SynthVelocity(rangeDB: 14, decayFactor: 1.1, brightnessFactor: 1.15),
        durationSeconds: 0.8, seed: 0x909_0002)

    // MARK: Sampled metal

    /// The 909's hi-hats, crash and ride were **PCM in ROM**. Roland's own notes: they "are
    /// reproduced out of digital sound memories which have been sampled from an actual instrument".
    /// There is no circuit here to model, so this is an imitation of a recording, and it is labelled
    /// `filteredNoise` so nobody reads these parameters as circuit values.
    ///
    /// What *is* documented, and what the `sampled` block reproduces:
    ///
    /// * **6 bits.** Confirmed by Roland (Atsushi Hoshiai: they "sampled the hi-hats at 6-bit"), by
    ///   network-909, and by Colin Fraser, who dumped the ROMs and found the data in the top six
    ///   bits of each 8-bit word with the low two unused.
    ///   <https://articles.roland.com/atsushi-hoshiai-tr-909/>
    /// * **About 30 kHz.** The sample clock is a 2-NAND relaxation oscillator — no crystal — running
    ///   at roughly 60 kHz and divided by two. Fraser, working from the hardware, picked 32 kHz for
    ///   his ROM dumps as "pretty close to the rate used for the hats". Being RC-derived, it drifts
    ///   from machine to machine. **Not** the 25 kHz that circulates; that is a TR-707 figure.
    /// * **Companded before storage**, with the envelope restored in the analog domain: the samples
    ///   were compressed "in order to have greater S/N ratio and higher digital resolution", and an
    ///   analog VCA after the DAC puts the dynamics back. That is why a DECAY knob works at all on a
    ///   sampled voice, and why the model applies an envelope and *then* quantises.
    /// * Two low-pass filters in series after the DAC, to remove the sample-rate images.
    /// * The **closed hat's decay resistance is one tenth of the open hat's** — same ROM, same DAC,
    ///   different RC on the envelope.
    ///
    /// APPROXIMATED: every band-pass frequency and Q here, and the decay ranges.
    static func tr909Metal(_ kind: SynthVoiceKind, bandHz: Double, bandQ: Double, highPassHz: Double,
                           shortest: Double, mid: Double, longest: Double, knob: Double,
                           level: Double, duration: Double, seed: UInt64) -> SynthVoiceSpec {
        SynthVoiceSpec(
            kind: kind, engine: .filteredNoise, machine: "tr909",
            controls: SynthControls(decay: knob, tone: 0.55, level: level),
            tone: SynthTone(tuneSemitones: 0, level: 0),
            noise: SynthNoise(level: 0.8, bandHz: bandHz, bandQ: bandQ, highPassHz: highPassHz,
                              decayShortestSeconds: shortest, decayMidSeconds: mid,
                              decayLongestSeconds: longest, attackSeconds: 0.0002),
            output: SynthOutput(toneDarkHz: 9_000, toneBrightHz: 18_000,
                                highPassHz: highPassHz * 0.6, drive: 0.08),
            velocity: SynthVelocity(rangeDB: 12, brightnessFactor: 1.15),
            sampled: SynthSampled(bits: 6, playbackRateHz: 30_000),
            durationSeconds: duration, seed: seed)
    }

    /// Closed hat. Shares the open hat's ROM; the counter stops after about 8192 words, which at
    /// ~30 kHz is roughly 270 ms of sample — consistent with the short envelope here.
    static let tr909ClosedHat = tr909Metal(.closedHat, bandHz: 9_000, bandQ: 0.6, highPassHz: 6_000,
                                           shortest: 0.05, mid: 0.09, longest: 0.16, knob: 0.4,
                                           level: 0.58, duration: 0.3, seed: 0x909_0003)
    /// Open hat. About 24576 words of the same ROM, roughly 820 ms at ~30 kHz, and an envelope
    /// resistance ten times the closed hat's.
    static let tr909OpenHat = tr909Metal(.openHat, bandHz: 8_000, bandQ: 0.55, highPassHz: 5_000,
                                         shortest: 0.2, mid: 0.7, longest: 1.4, knob: 0.5,
                                         level: 0.55, duration: 1.2, seed: 0x909_0004)
    /// Crash. Its own 32 KB ROM, and — unlike the hats — **no decay pot**: the envelope is derived
    /// from the ROM *address*, anti-log tapered, so the decay always tracks the tune setting and
    /// matches the sample's own length. The DECAY knob here is therefore ours, not Roland's.
    static let tr909Crash = tr909Metal(.crash, bandHz: 4_500, bandQ: 0.35, highPassHz: 2_000,
                                       shortest: 0.6, mid: 1.6, longest: 2.8, knob: 0.5,
                                       level: 0.5, duration: 2.2, seed: 0x909_0005)
    /// Ride. Same address-derived envelope as the crash, its own ROM.
    static let tr909Ride = tr909Metal(.ride, bandHz: 6_500, bandQ: 0.45, highPassHz: 3_500,
                                      shortest: 0.4, mid: 1.0, longest: 1.8, knob: 0.45,
                                      level: 0.48, duration: 1.4, seed: 0x909_0006)

    // MARK: Clap, rim, toms, cowbell

    /// **CP.** Analog, essentially the 808's circuit: band-passed noise split two ways, one through
    /// a VCA driven by a cascade of envelopes (each op-amp firing the next) and one through a slow
    /// envelope that is the room. The 909's cascade has **four stages** where the 808 retriggers
    /// three times, so this is four bursts and a tail rather than three and a tail.
    /// <http://www.network-909.de/handclap.htm>
    ///
    /// APPROXIMATED: the interval between bursts. The 808's 10 ms is documented; the 909's is set by
    /// a trimpot and nobody publishes the figure.
    static let tr909Clap = SynthVoiceSpec(
        kind: .clap, engine: .burstNoise, machine: "tr909",
        controls: SynthControls(decay: 0.45, tone: 0.6, level: 1.0),
        tone: SynthTone(tuneSemitones: 0, level: 0),
        noise: SynthNoise(level: 0.58, bandHz: 1_500, bandQ: 0.9,
                          decayShortestSeconds: 0.12, decayMidSeconds: 0.22, decayLongestSeconds: 0.4),
        burst: SynthBurst(count: 5, intervalSeconds: 0.0085, burstDecaySeconds: 0.010,
                          tailLevel: 0.5, tailDecaySeconds: 0.22),
        output: SynthOutput(toneDarkHz: 4_000, toneBrightHz: 11_000, highPassHz: 350, drive: 0.12),
        velocity: SynthVelocity(rangeDB: 12, brightnessFactor: 1.05),
        durationSeconds: 0.5, seed: 0x909_0007)

    /// **RIM.** The one voice on the 909 that **is** a bridged-T circuit — three of them, at
    /// documented frequencies of **500, 220 and 1000 Hz**, each with its own Q, mixed and then run
    /// into a diode clipper and a high-pass output stage. (network-909's explanation of why the rest
    /// of the machine is not bridged-T is worth reading: a bridged-T's frequency depends on every R
    /// and C in it, and 5% parts made that unacceptable for the tuned voices.)
    /// <http://www.network-909.de/rimshot.htm>
    static let tr909Rim = SynthVoiceSpec(
        kind: .rim, engine: .ring, machine: "tr909",
        controls: SynthControls(decay: 0.45, tone: 0.65, level: 0.68),
        tone: SynthTone(frequencyHz: 1_000, altFrequencyHz: 500, altLevel: 0.5, tuneSemitones: 4,
                        decayShortestSeconds: 0.02, decayMidSeconds: 0.035, decayLongestSeconds: 0.06,
                        attackSeconds: 0.0002, level: 0.5,
                        partialsHz: [220]),     // the third resonator
        noise: SynthNoise(level: 0.10, bandHz: 3_000, bandQ: 0.8,
                          decayShortestSeconds: 0.006, decayMidSeconds: 0.01, decayLongestSeconds: 0.02),
        // The output stage really is a high-pass after a diode clipper.
        output: SynthOutput(toneDarkHz: 5_000, toneBrightHz: 14_000, highPassHz: 400, drive: 0.35),
        velocity: SynthVelocity(rangeDB: 12, brightnessFactor: 1.1),
        durationSeconds: 0.2, seed: 0x909_0008)

    /// **TOM.** Analog, and more elaborate than the 808's: **three** VCOs per tom, all reset on
    /// trigger, plus a noise channel mixed in before the VCA so the attack sounds like a struck skin
    /// rather than a tone burst. VCO-1's diode clipper is *itself* modulated, so that oscillator
    /// changes from a hard-clipped square towards a sine across the note; the DECAY knob is VCO-2's
    /// envelope, so at long settings only one oscillator is left after a few tens of milliseconds.
    /// The three toms differ only in their VCO tunings.
    /// <http://www.network-909.de/toms.htm>
    ///
    /// APPROXIMATED: all three frequencies and the decays — none are published. A second-hand figure
    /// gives the low tom's three oscillators a ratio of about 1 : 1.5 : 2.77, which is roughly the
    /// spread used here between `frequencyHz` and `pitchPeakHz`.
    static func tr909Tom(_ kind: SynthVoiceKind, frequencyHz: Double, t60: Double, seed: UInt64) -> SynthVoiceSpec {
        SynthVoiceSpec(
            kind: kind, engine: .bridgedT, machine: "tr909",
            controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.5, level: 0.78),
            tone: SynthTone(
                frequencyHz: frequencyHz,
                tuneSemitones: 10,
                pitchPeakHz: frequencyHz * 2.0,
                pitchEnvelopeSeconds: 0.045,
                decayShortestSeconds: t60 * 0.5, decayMidSeconds: t60, decayLongestSeconds: t60 * 1.8,
                attackSeconds: 0.0006, level: 0.78),
            noise: SynthNoise(level: 0.14, bandHz: 900, bandQ: 0.5,
                              decayShortestSeconds: t60 * 0.3, decayMidSeconds: t60 * 0.5,
                              decayLongestSeconds: t60 * 0.8),
            click: SynthClick(level: 0.07, decaySeconds: 0.0022, highPassHz: 1_600, noiseFraction: 0.6),
            output: SynthOutput(toneDarkHz: 1_400, toneBrightHz: 7_000, highPassHz: 40, drive: 0.15),
            velocity: SynthVelocity(rangeDB: 12, pitchCents: 120, decayFactor: 1.1, brightnessFactor: 1.2),
            durationSeconds: max(0.6, t60 * 1.8), seed: seed)
    }

    static let tr909LowTom = tr909Tom(.lowTom, frequencyHz: 82, t60: 0.75, seed: 0x909_0009)
    static let tr909MidTom = tr909Tom(.midTom, frequencyHz: 124, t60: 0.6, seed: 0x909_000A)
    static let tr909HighTom = tr909Tom(.highTom, frequencyHz: 178, t60: 0.5, seed: 0x909_000B)

    /// **The TR-909 has no cowbell.** The 808's is carried over unchanged so that a groove written
    /// for one machine plays on the other; it is labelled `tr909` only because it lives in this kit.
    static let tr909Cowbell: SynthVoiceSpec = {
        var spec = SynthMachine.tr808Cowbell
        spec.machine = "tr909"
        spec.seed = 0x909_000C
        return spec
    }()
}
