import Foundation

// MARK: - Machine

/// A complete set of voice specs: one drum machine's panel.
public struct SynthMachine: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier recorded in `kit.json` (`"tr808"`, `"linn"`, `"studio"`…).
    public var id: String
    public var name: String
    /// One line for a kit browser.
    public var summary: String
    public var voices: [SynthVoiceSpec]

    public init(id: String, name: String, summary: String, voices: [SynthVoiceSpec]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.voices = voices
    }

    public func spec(for kind: SynthVoiceKind) -> SynthVoiceSpec? { voices.first { $0.kind == kind } }

    /// By family, as the Grid lists them: the drum machines — the three modelled from the hardware
    /// first — then the samplers, the acoustic kits and the styles.
    public static var all: [SynthMachine] {
        [.tr808, .tr909, .linn, .cr78, .tr606, .tr707, .dmx, .simmons,
         .sp1200, .mpc60,
         .studio, .jazz, .rock, .funk, .vintage,
         .trap, .lofi]
    }

    /// The machine with this id, if it is one of the presets.
    public static func preset(id: String) -> SynthMachine? { all.first { $0.id == id } }
}

// MARK: - TR-808
//
// ## Where these numbers come from
//
// The primary source is Roland's own **TR-808 Service Notes (15 June 1981)**, whose "CHECKING
// VOICES" table publishes an amplitude, a frequency (LOW/MID/HIGH where the voice has a tuning
// control) and a decay (SHORT/MID/LONG) for every voice:
//   <https://archive.org/stream/synthmanual-roland-tr-808-service-notes/rolandtr-808servicenotes_djvu.txt>
// Roland's own footer on that table says the values are "typical and variable", and measurements of
// real units vary by well over 10%, so these are a centre, not a spec.
//
// **The decay figures in that table are not T60.** They are time-to-one-tenth-amplitude, i.e. T20,
// so every decay below is the published figure multiplied by three. This reading comes from Kurt
// James Werner's circuit analysis, which derives it from a figure printed beside the table:
//   <https://kurtjameswerner.tumblr.com/post/50876992798>
// It is the single assumption in this file with the most leverage on how the kit sounds. If it is
// wrong, every 808 decay here is three times too long.
//
// Secondary sources, each cited at the parameter it supports:
//   * Werner, Abel & Smith, "The TR-808 Cymbal: a Physically-Informed, Circuit-Bendable, Digital
//     Model", ICMC|SMC 2014 — the six hi-hat/cymbal oscillators and the cymbal's filter bank.
//     <https://www.icmc14-smc14.net/images/proceedings/OS24-B10-TheTR-808Cymbal.pdf>
//   * Werner, "A Physically-Informed, Circuit-Bendable, Digital Model of the Roland TR-808 Bass
//     Drum Circuit", DAFx-14. <https://dafx14.fau.de/papers/dafx14_kurt_james_werner_a_physically_informed,_ci.pdf>
//   * Norgatronics, "808 Snare – Mutations" — the two snare circuit revisions and measurements of
//     eleven real machines. <https://norgatronics.blogspot.com/2021/11/808-snare-mutations.html>
//   * Baratatronix, on the bass drum, the clap and the cymbal/hats.
//     <https://www.baratatronix.com/blog/808-bd-synthesis>
//     <https://www.baratatronix.com/blog/cascadia-808-clap-synthesis>
//     <https://www.baratatronix.com/blog/cascadia-808-cymbal-hi-hat-synthesis>
//
// ## What is NOT documented, and is therefore approximated here
//
// Marked `APPROXIMATED` at each site. In summary: the snare's noise high-pass corner and its noise
// envelope decay (Werner says he tuned these by ear and published no figures); the closed- and
// open-hat high-pass corners (Roland names the transistors, nothing more); the clap band-pass Q;
// the cowbell's mixing-filter centre and Q; and the depth of the toms' pitch envelope. Every one of
// these is a value chosen to sound right, not a value read off a schematic.

extension SynthMachine {

    /// The Roland TR-808 (1980–1983). Every voice is an analog circuit; nothing in the machine is
    /// a sample.
    public static let tr808 = SynthMachine(
        id: "tr808",
        name: "TR-808",
        summary: "Roland TR-808: bridged-T rings, six square oscillators and a noise generator.",
        voices: withPercussion([tr808Kick, tr808Snare, tr808ClosedHat, tr808OpenHat, tr808Clap, tr808Rim,
                 tr808LowTom, tr808MidTom, tr808HighTom, tr808Cowbell, tr808Crash, tr808Ride], "tr808", seed: 0x8080900, electronic: true)
    )

    // MARK: Bass drum

    /// **BD.** A bridged-T network whose feedback makes it self-oscillate, fired by the machine's
    /// 1 ms common trigger pulse. The pulse also opens a short envelope that pulls the network's
    /// centre frequency up for the first few milliseconds; that is the "snap", and it is too short
    /// to be heard as a pitch bend.
    ///
    /// Frequency: **49.4 Hz** computed from the service manual's component values (G1 + 14 cents).
    /// The service-notes table instead prints **56 Hz**, and measured units go as low as **48 Hz**.
    /// The computed figure is used here; the disagreement is real and unresolved.
    /// <https://www.baratatronix.com/blog/808-bd-synthesis>
    ///
    /// Pitch envelope: rises to about **130 Hz** and falls back over roughly **6 ms**. (Same source.
    /// N8 Synthesizers' clone analysis independently gives "~128 Hz" for the same moment:
    /// <https://www.n8synth.co.uk/diy-eurorack/eurorack-808-kick/>.) Over a 49 Hz cycle that sweep
    /// is worth only about 0.07 of a cycle of extra phase, which is why it reads as attack rather
    /// than as a bend.
    ///
    /// Decay: the DECAY knob sets how much signal is fed back through the bridged-T — less feedback
    /// is shorter and clickier, more is longer and boomier. Published as **50 / 300 / 800 ms**
    /// (T20), hence 150 / 900 / 2400 ms here.
    ///
    /// TONE is a passive low-pass after the band-pass, and mostly decides how much of the transient
    /// click survives. There is **no TUNE control on a real 808 bass drum**; the ±6 semitones here
    /// are ours, for a kit builder, not Roland's.
    static let tr808Kick = SynthVoiceSpec(
        kind: .kick, engine: .bridgedT, machine: "tr808",
        controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.45, level: 1.0),
        tone: SynthTone(
            frequencyHz: 49.4,
            tuneSemitones: 12,
            pitchPeakHz: 130,
            pitchEnvelopeSeconds: 0.006,
            decayShortestSeconds: 0.15,     // 50 ms T20
            decayMidSeconds: 0.9,           // 300 ms T20, the knob's detent
            decayLongestSeconds: 2.4,       // 800 ms T20
            attackSeconds: 0.0008,
            level: 0.82),
        // APPROXIMATED: the click's level and length. Roland publishes the 1 ms trigger width but no
        // figure for how much of it leaks past the oscillator into the output.
        click: SynthClick(level: 0.10, decaySeconds: 0.0035, highPassHz: 900, noiseFraction: 0.25),
        output: SynthOutput(toneDarkHz: 260, toneBrightHz: 4_000, highPassHz: 18, drive: 0.12),
        // Accent is specified as 0–10 dB, and it works by raising the common trigger from ~4 V to
        // ~14 V, which also drives the pitch envelope a little higher and lets the ring last a
        // little longer. The two non-level terms are APPROXIMATED: Roland publishes no figure.
        velocity: SynthVelocity(rangeDB: 10, pitchCents: 150, decayFactor: 1.18, brightnessFactor: 1.25),
        durationSeconds: 1.6, seed: 0x808_0001)

    // MARK: Snare

    /// **SD.** Two bridged-T rings plus a band of noise.
    ///
    /// Roland shipped **two revisions** of this circuit, differing by one capacitor per oscillator.
    /// Computed from components: Rev A is **249.6 / 499.0 Hz**, Rev B is **173.3 / 336.0 Hz**.
    /// The service-notes table prints **238 / 476 Hz**, which matches neither. Measurements of
    /// eleven real machines span **159–254 Hz** low and **326–526 Hz** high.
    /// <https://kurtjameswerner.tumblr.com/post/51352144814>
    /// <https://norgatronics.blogspot.com/2021/11/808-snare-mutations.html>
    ///
    /// Rev B is used here: it is what most surviving machines and modern clones are, and it is the
    /// pair — around 180 and 330 Hz — that people mean by "the 808 snare".
    ///
    /// Decay: Roland publishes **60 ms** (T20) for the snare, but the Qs computed from the component
    /// values — **16.3** low, **9.9** high — imply T60 of about **207 ms** and **65 ms**, which are
    /// nothing like each other. Both figures are kept (`decayMidSeconds` and `altDecaySeconds`) and
    /// the inconsistency is left visible rather than averaged away.
    ///
    /// TONE (VR8) sets the balance between the two rings. SNAPPY (VR9) sets how much trigger reaches
    /// the noise envelope generator. Neither is a tone-versus-noise crossfade; see `addSnareTones`.
    static let tr808Snare = SynthVoiceSpec(
        kind: .snare, engine: .dualToneNoise, machine: "tr808",
        controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.45, snappy: 0.5, level: 0.9),
        toneControl: .oscillatorBalance,
        tone: SynthTone(
            frequencyHz: 173.334,
            altFrequencyHz: 335.976,
            altLevel: 0.9,
            tuneSemitones: 7,               // ours: the 808 snare has no TUNE knob
            decayShortestSeconds: 0.09,
            decayMidSeconds: 0.207,         // from Q = 16.3 at 173.3 Hz
            decayLongestSeconds: 0.32,
            altDecaySeconds: 0.065,         // from Q = 9.9 at 336.0 Hz
            attackSeconds: 0.0004,
            level: 0.62),
        // APPROXIMATED, and the largest approximation in the 808 preset. Roland publishes no corner
        // frequency, no Q and no decay for the snare's noise path, and Werner states he tuned his
        // by ear. The 2466 Hz high-pass is N8 Synthesizers' *clone* design value, used here as the
        // only published number in the neighbourhood — it is not measured from an 808.
        // <https://www.n8synth.co.uk/diy-eurorack/eurorack-808-snare/>
        noise: SynthNoise(level: 0.42, bandHz: 4_200, bandQ: 0.55, highPassHz: 2_466,
                          decayShortestSeconds: 0.06, decayMidSeconds: 0.13,
                          decayLongestSeconds: 0.28, attackSeconds: 0.0002),
        output: SynthOutput(toneDarkHz: 14_000, toneBrightHz: 14_000, highPassHz: 90, drive: 0.15),
        velocity: SynthVelocity(rangeDB: 10, decayFactor: 1.1, brightnessFactor: 1.0),
        durationSeconds: 0.7, seed: 0x808_0002)

    // MARK: Hats and cymbal

    /// The six square-wave oscillators the hats, the cymbal and the cowbell all share.
    ///
    /// **205.3, 304.4, 369.6, 522.7, 540 and 800 Hz.** Only the first four are fixed by components;
    /// the last two run through factory trimpots over ranges of 359.4–1149.9 Hz and 254.3–627.2 Hz
    /// and are trimmed to 800 and 540 Hz — the same two the cowbell uses. Units before serial
    /// #000300 used different resistors again, and the capacitors vary up to 20% unit to unit.
    /// <https://www.icmc14-smc14.net/images/proceedings/OS24-B10-TheTR-808Cymbal.pdf>
    ///
    /// They are Schmitt-trigger (HD14584) oscillators at 5 V with a duty cycle of **47.98%**, not
    /// 50% — the asymmetry puts even harmonics in the sum. `PhaseOscillator.square` produces a true
    /// 50% square, so that asymmetry is one thing this model does not reproduce.
    public static let tr808HatOscillators: [Double] = [205.3, 304.4, 369.6, 522.7, 540, 800]

    /// **CH.** One gate and one filter off the six-oscillator sum. Decay is fixed at **50 ms** (T20)
    /// — the closed hat is the only hat with no decay control.
    ///
    /// APPROXIMATED: the closed hat's high-pass corner. Roland names only the transistor (Q31) and
    /// Werner's paper covers the *cymbal's* filters, not the hats'. The band here sits just under
    /// the cymbal's documented ~10.5 kHz resonant high-pass, which is the closest published anchor.
    static let tr808ClosedHat = SynthVoiceSpec(
        kind: .closedHat, engine: .squareCluster, machine: "tr808",
        controls: SynthControls(decay: 0.5, tone: 0.6, level: 0.8),
        tone: SynthTone(
            tuneSemitones: 0,
            decayShortestSeconds: 0.09,
            decayMidSeconds: 0.15,          // 50 ms T20
            decayLongestSeconds: 0.24,
            attackSeconds: 0.0002,
            level: 0.85,
            partialsHz: tr808HatOscillators),
        noise: SynthNoise(level: 0, bandHz: 9_500, bandQ: 0.75, highPassHz: 6_500),
        output: SynthOutput(toneDarkHz: 11_000, toneBrightHz: 17_000, highPassHz: 4_000, drive: 0.1),
        // CB, CY, OH and CH have their trigger range narrowed to 7–14 V on the voicing board to
        // improve signal-to-noise, so these four have a noticeably smaller accent range than the
        // rest of the machine.
        velocity: SynthVelocity(rangeDB: 6, brightnessFactor: 1.1),
        durationSeconds: 0.35, seed: 0x808_0003)

    /// **OH.** The same source and a single gate/filter path, with a decay control: **90 / 450 /
    /// 600 ms** (T20). The closed hat hard-chokes it in hardware — Q23 turns on and terminates the
    /// open hat's decay — which is exactly what the kit's `group`/`offBy` pair reproduces.
    static let tr808OpenHat = SynthVoiceSpec(
        kind: .openHat, engine: .squareCluster, machine: "tr808",
        controls: SynthControls(decay: 0.5, tone: 0.55, level: 0.78),
        tone: SynthTone(
            tuneSemitones: 0,
            decayShortestSeconds: 0.27,     // 90 ms T20
            decayMidSeconds: 1.35,          // 450 ms T20
            decayLongestSeconds: 1.8,       // 600 ms T20
            attackSeconds: 0.0002,
            level: 0.85,
            partialsHz: tr808HatOscillators),
        noise: SynthNoise(level: 0, bandHz: 9_000, bandQ: 0.7, highPassHz: 6_000),
        output: SynthOutput(toneDarkHz: 10_000, toneBrightHz: 16_000, highPassHz: 3_500, drive: 0.1),
        velocity: SynthVelocity(rangeDB: 6, brightnessFactor: 1.1),
        durationSeconds: 1.6, seed: 0x808_0004)

    /// **CY.** The same six oscillators split into three bands. The two band-passes are at about
    /// **3440 Hz** and **7100 Hz** and the resonant high-pass at about **10.5 kHz**; only the
    /// 3440 Hz band's VCA is under the DECAY knob, the highest band always decays fast. Decay is
    /// **350 / 800 / 1200 ms** (T20) — the longest envelope in the machine.
    /// <https://www.icmc14-smc14.net/images/proceedings/OS24-B10-TheTR-808Cymbal.pdf>
    ///
    /// This model has one band, not three: `bandHz` is the 3440 Hz band the decay knob acts on, and
    /// the upper bands are folded into the output filter rather than being separate voices.
    static let tr808Crash = SynthVoiceSpec(
        kind: .crash, engine: .squareCluster, machine: "tr808",
        controls: SynthControls(decay: 0.4, tone: 0.6, level: 0.72),
        tone: SynthTone(
            tuneSemitones: 0,
            decayShortestSeconds: 1.05,     // 350 ms T20
            decayMidSeconds: 2.4,           // 800 ms T20
            decayLongestSeconds: 3.6,       // 1200 ms T20
            attackSeconds: 0.0004,
            level: 0.8,
            partialsHz: tr808HatOscillators),
        noise: SynthNoise(level: 0, bandHz: 3_440, bandQ: 0.42, highPassHz: 2_200),
        output: SynthOutput(toneDarkHz: 8_000, toneBrightHz: 15_000, highPassHz: 1_500, drive: 0.12),
        velocity: SynthVelocity(rangeDB: 6, brightnessFactor: 1.15),
        durationSeconds: 2.5, seed: 0x808_0005)

    /// **The TR-808 has no ride cymbal.** This is the CY circuit with the decay short and the tone
    /// bright, which is how people used the machine's cymbal when they needed one — not a model of
    /// anything Roland built.
    static let tr808Ride = SynthVoiceSpec(
        kind: .ride, engine: .squareCluster, machine: "tr808",
        controls: SynthControls(decay: 0.18, tone: 0.75, level: 0.66),
        tone: SynthTone(
            tuneSemitones: 0,
            decayShortestSeconds: 1.05, decayMidSeconds: 2.4, decayLongestSeconds: 3.6,
            attackSeconds: 0.0004, level: 0.8,
            partialsHz: tr808HatOscillators),
        noise: SynthNoise(level: 0, bandHz: 7_100, bandQ: 0.5, highPassHz: 4_500),
        output: SynthOutput(toneDarkHz: 9_000, toneBrightHz: 16_000, highPassHz: 2_500, drive: 0.1),
        velocity: SynthVelocity(rangeDB: 6, brightnessFactor: 1.15),
        durationSeconds: 1.4, seed: 0x808_0006)

    // MARK: Clap

    /// **CP.** White noise through a band-pass, into two VCAs with different envelopes. A 30 ms gate
    /// pulse drives an oscillator that retriggers the fast envelope **three times, 10 ms apart**,
    /// then stops; the second VCA runs a much longer envelope that is the machine's fake room.
    /// Roland's own wording is that the recharge "process is repeated and advanced to the middle of
    /// the third time".
    ///
    /// Band-pass centre **1000 Hz** — two independent sources agree. Decay **100 ms** (T20) for the
    /// tail. The retrigger rate is quoted as a 100 Hz oscillator, i.e. 10 ms, by both.
    /// <https://www.baratatronix.com/blog/cascadia-808-clap-synthesis>
    /// <https://www.kvraudio.com/forum/viewtopic.php?t=336866>
    ///
    /// APPROXIMATED: the band-pass Q, which nobody publishes.
    ///
    /// A note on the service-notes table: it prints the clap's *accented* amplitude (2 Vpp) as lower
    /// than its unaccented one (6 Vpp), which is almost certainly a misprint — flagged independently
    /// by Werner. The accent behaviour here follows the rest of the machine instead.
    static let tr808Clap = SynthVoiceSpec(
        kind: .clap, engine: .burstNoise, machine: "tr808",
        controls: SynthControls(decay: 0.5, tone: 0.5, level: 1.0),
        tone: SynthTone(tuneSemitones: 0, level: 0),
        noise: SynthNoise(level: 0.6, bandHz: 1_000, bandQ: 1.1, highPassHz: 0,
                          decayShortestSeconds: 0.18, decayMidSeconds: 0.3, decayLongestSeconds: 0.5),
        burst: SynthBurst(count: 4,                  // three fast bursts, then the tail
                          intervalSeconds: 0.010,    // the 100 Hz retrigger
                          burstDecaySeconds: 0.013,
                          tailLevel: 0.62,
                          tailDecaySeconds: 0.3),    // 100 ms T20
        output: SynthOutput(toneDarkHz: 3_000, toneBrightHz: 9_000, highPassHz: 250, drive: 0.1),
        velocity: SynthVelocity(rangeDB: 10, brightnessFactor: 1.05),
        durationSeconds: 0.6, seed: 0x808_0007)

    // MARK: Rim

    /// **RS.** The shortest voice in the machine: **10 ms** decay (T20), around a resonance the
    /// service notes put at **1667 Hz** (a 0.6 ms period). Baratatronix reads the circuit as two
    /// oscillators, the second at **455 Hz**, while the service notes give 500 Hz for the *claves*
    /// circuit the rimshot reconfigures. The two readings are not reconciled; both frequencies are
    /// present here, with the lower one quiet.
    /// <https://www.baratatronix.com/blog/808-rimshot>
    static let tr808Rim = SynthVoiceSpec(
        kind: .rim, engine: .ring, machine: "tr808",
        controls: SynthControls(decay: 0.5, tone: 0.6, level: 0.7),
        tone: SynthTone(
            frequencyHz: 1_667,
            altFrequencyHz: 455,
            altLevel: 0.45,
            tuneSemitones: 4,
            decayShortestSeconds: 0.02, decayMidSeconds: 0.03, decayLongestSeconds: 0.05,
            attackSeconds: 0.0002, level: 0.55),
        // The rimshot's VCA is deliberately a "swing type" — non-linear, harmonic-rich — which is
        // why this voice, unlike the toms, is driven hard.
        output: SynthOutput(toneDarkHz: 4_000, toneBrightHz: 12_000, highPassHz: 300, drive: 0.4),
        velocity: SynthVelocity(rangeDB: 10, brightnessFactor: 1.1),
        durationSeconds: 0.2, seed: 0x808_0008)

    // MARK: Toms

    /// The three tom circuits, each a multi-feedback bridged-T on IC5 and each shared with a conga
    /// by a switch that changes one capacitor.
    ///
    /// Frequencies are the TUNING knob's LOW/MID/HIGH from the service-notes table:
    /// low **80 / 90 / 100 Hz**, mid **120 / 135 / 160 Hz**, high **165 / 185 / 220 Hz**.
    /// Decays are **200 / 130 / 100 ms** (T20) respectively; the toms have no decay knob, so the
    /// triple here is a narrow spread around the published value rather than a real control range.
    ///
    /// The pitch envelope is the interesting part, and it is **not a time envelope**. Roland: while
    /// the ring is loud, two diodes conduct and shorten the network's time constant, so the pitch is
    /// higher; as the ring decays the diodes stop conducting and the pitch falls to nominal. It is
    /// amplitude-dependent. This model uses a time envelope instead, which for an exponentially
    /// decaying ring is a close stand-in — and **APPROXIMATED**, because no source publishes how far
    /// the pitch actually travels.
    ///
    /// Only the **low tom** has a noise component, and Roland specifies it as **pink**, mixed in
    /// with a longer decay "to provide artificial reverberation". The mid and high toms and all
    /// three congas have none. The pink noise is approximated here by a low band-pass on white.
    static func tr808Tom(_ kind: SynthVoiceKind, low: Double, mid: Double, high: Double,
                         decayT20: Double, seed: UInt64, pinkNoise: Double = 0) -> SynthVoiceSpec {
        let t60 = decayT20 * 3
        return SynthVoiceSpec(
            kind: kind, engine: .bridgedT, machine: "tr808",
            controls: SynthControls(tune: 0.5, decay: 0.5, tone: 0.5, level: 0.8),
            tone: SynthTone(
                frequencyHz: mid,
                // The knob's real span, from the published LOW and HIGH ends.
                tuneSemitones: 12 * log2(high / low),
                pitchPeakHz: mid * 1.45,        // APPROXIMATED: depth is undocumented
                pitchEnvelopeSeconds: 0.025,    // APPROXIMATED
                decayShortestSeconds: t60 * 0.6,
                decayMidSeconds: t60,
                decayLongestSeconds: t60 * 1.6,
                attackSeconds: 0.0006,
                level: 0.8),
            noise: SynthNoise(level: pinkNoise, bandHz: 260, bandQ: 0.5, highPassHz: 0,
                              decayShortestSeconds: t60, decayMidSeconds: t60 * 1.5,
                              decayLongestSeconds: t60 * 2.2),
            click: SynthClick(level: 0.05, decaySeconds: 0.002, highPassHz: 1_400, noiseFraction: 0.5),
            output: SynthOutput(toneDarkHz: 900, toneBrightHz: 5_000, highPassHz: 35, drive: 0.1),
            velocity: SynthVelocity(rangeDB: 10, pitchCents: 90, decayFactor: 1.1, brightnessFactor: 1.2),
            durationSeconds: max(0.5, t60 * 1.9), seed: seed)
    }

    static let tr808LowTom = tr808Tom(.lowTom, low: 80, mid: 90, high: 100,
                                      decayT20: 0.200, seed: 0x808_0009, pinkNoise: 0.10)
    static let tr808MidTom = tr808Tom(.midTom, low: 120, mid: 135, high: 160,
                                      decayT20: 0.130, seed: 0x808_000A)
    static let tr808HighTom = tr808Tom(.highTom, low: 165, mid: 185, high: 220,
                                       decayT20: 0.100, seed: 0x808_000B)

    // MARK: Cowbell

    /// **CB.** Two of the hi-hat's squares — oscillators #5 and #6, the two with factory trimpots,
    /// trimmed to **800 Hz** and **540 Hz** — each through its own gate, then mixed by IC2. The
    /// service-notes table lists the pair with periods of 1.25 ms and 1.85 ms, which is exactly
    /// those two frequencies. Their ratio is 1.4815, about 20 cents flat of a perfect fifth.
    ///
    /// Decay **50 ms** (T20). Roland describes the envelope as having "abrupt level decay at the
    /// initial trailing edge to emphasize attack effect" — a two-stage decay, a sharp drop and then
    /// a slower tail. This model has one exponential, so it does not reproduce that shape.
    ///
    /// APPROXIMATED: the IC2 mixing filter's centre frequency and Q, which the service notes do not
    /// publish. (Werner et al. have a dedicated cowbell paper, AES 137 "More Cowbell", which is
    /// paywalled: <https://www.aes.org/e-lib/browse.cfm?elib=17530>.)
    static let tr808Cowbell = SynthVoiceSpec(
        kind: .cowbell, engine: .squareCluster, machine: "tr808",
        controls: SynthControls(decay: 0.5, tone: 0.5, level: 0.6),
        tone: SynthTone(
            tuneSemitones: 0,
            decayShortestSeconds: 0.09,
            decayMidSeconds: 0.15,          // 50 ms T20
            decayLongestSeconds: 0.25,
            attackSeconds: 0.0003,
            level: 0.8,
            partialsHz: [540, 800]),
        noise: SynthNoise(level: 0, bandHz: 1_700, bandQ: 0.45, highPassHz: 450),
        output: SynthOutput(toneDarkHz: 3_000, toneBrightHz: 8_000, highPassHz: 350, drive: 0.2),
        velocity: SynthVelocity(rangeDB: 6, brightnessFactor: 1.05),
        durationSeconds: 0.4, seed: 0x808_000C)
}
