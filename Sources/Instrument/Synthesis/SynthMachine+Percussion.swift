import Foundation

// MARK: - Hand percussion
//
// Every kit carries eight hand-percussion voices beside its drums — shaker, tambourine, high and
// low conga, high and low bongo, claves and woodblock — so a feel that asks for a conga tumbao or a
// shaker in sixteenths is heard on whichever kit the song is on, rather than being silent on all
// of them, which is what the old catch-all `perc` voice was.
//
// Two sets, both ours, chosen by ear toward the instruments rather than measured from recordings:
//   * **Played** — the skins ring at a pitch, bend down a little as the head relaxes, and carry a
//     slap and a little skin noise; the shaker swells into its hit; the tambourine is jingles
//     (a cluster of unrelated high partials) over a frame knock.
//   * **Electronic** — the drum machines that had congas and claves (the TR-808, the CR-78) made
//     them from the same circuits as their toms and rim: a pure ring with no skin, no slap, and
//     claves that are nothing but the ring. The 808's congas are documented as its tom circuits
//     switched to a higher, shorter setting; the pitches here are ours.
//
// A kit whose snare is a companded PCM voice (the LinnDrum, the samplers) gets its percussion
// through the same converter, so it sits in the kit rather than on top of it. Levels stay well
// under the kick: `SynthesizedKit` scales a whole kit by its loudest sample, and a conga must not
// be what sets that.
extension SynthMachine {

    /// The eight hand-percussion voices for `machine`. `electronic` picks the circuit set;
    /// `sampled` puts every voice through that converter.
    static func handPercussion(_ machine: String, seed: UInt64, electronic: Bool = false,
                               sampled: SynthSampled? = nil) -> [SynthVoiceSpec] {
        let voices = electronic ? electronicPercussion(machine, seed: seed) : playedPercussion(machine, seed: seed)
        return voices.map { voice in
            var voice = voice
            if let sampled { voice.sampled = sampled }
            return voice
        }
    }

    /// A machine's drums followed by its hand percussion, taking the converter from its snare.
    static func withPercussion(_ drums: [SynthVoiceSpec], _ machine: String, seed: UInt64,
                               electronic: Bool = false) -> [SynthVoiceSpec] {
        let sampled = drums.first { $0.kind == .snare }?.sampled
        return drums + handPercussion(machine, seed: seed, electronic: electronic, sampled: sampled)
    }

    // MARK: Played

    private static func playedPercussion(_ machine: String, seed: UInt64) -> [SynthVoiceSpec] {
        [
            // A shaker is a swell, not a hit: the beads take ten or fifteen milliseconds to arrive,
            // and what arrives is a band of noise high up with nothing under it.
            SynthVoiceSpec(
                kind: .shaker, engine: .filteredNoise, machine: machine,
                controls: SynthControls(level: 0.42),
                noise: SynthNoise(level: 0.9, bandHz: 6_800, bandQ: 0.7, highPassHz: 3_400,
                                  decayShortestSeconds: 0.07, decayMidSeconds: 0.12,
                                  decayLongestSeconds: 0.22, attackSeconds: 0.012),
                output: SynthOutput(toneDarkHz: 9_000, toneBrightHz: 16_000, highPassHz: 2_000),
                velocity: SynthVelocity(rangeDB: 14, decayFactor: 1.1, brightnessFactor: 1.1),
                durationSeconds: 0.4, seed: seed + 1),
            // Jingles: unrelated partials between 3.7 and 9 kHz ringing a few hundred milliseconds,
            // a wash of noise with them, and the knock of the hand on the frame.
            SynthVoiceSpec(
                kind: .tambourine, engine: .squareCluster, machine: machine,
                controls: SynthControls(level: 0.36),
                // No TUNE: jingles are the pitch they are, and a knob that moved nothing would lie.
                tone: SynthTone(tuneSemitones: 0,
                                decayShortestSeconds: 0.2, decayMidSeconds: 0.38, decayLongestSeconds: 0.7,
                                attackSeconds: 0.001, level: 0.55,
                                partialsHz: [3_720, 4_310, 5_150, 6_020, 7_380, 8_930]),
                noise: SynthNoise(level: 0.3, bandHz: 7_200, bandQ: 0.9, highPassHz: 4_000,
                                  decayShortestSeconds: 0.12, decayMidSeconds: 0.22,
                                  decayLongestSeconds: 0.4, attackSeconds: 0.001),
                click: SynthClick(level: 0.18, decaySeconds: 0.004, highPassHz: 700, noiseFraction: 0.5),
                output: SynthOutput(toneDarkHz: 10_000, toneBrightHz: 17_000, highPassHz: 400),
                velocity: SynthVelocity(rangeDB: 14, decayFactor: 1.15, brightnessFactor: 1.1),
                durationSeconds: 0.9, seed: seed + 2),
            skin(.highConga, machine, seed: seed + 3, hz: 330, peak: 395, decay: (0.16, 0.3, 0.5), slap: 0.22),
            skin(.lowConga, machine, seed: seed + 4, hz: 220, peak: 262, decay: (0.2, 0.4, 0.7), slap: 0.18),
            skin(.highBongo, machine, seed: seed + 5, hz: 490, peak: 590, decay: (0.07, 0.14, 0.24), slap: 0.3),
            skin(.lowBongo, machine, seed: seed + 6, hz: 370, peak: 440, decay: (0.09, 0.18, 0.3), slap: 0.26),
            // Two hardwood sticks: one strong resonance near 2.5 kHz that rings about a tenth of
            // a second, a faint overtone, and the contact.
            SynthVoiceSpec(
                kind: .claves, engine: .ring, machine: machine,
                controls: SynthControls(level: 0.34),
                tone: SynthTone(frequencyHz: 2_480, altFrequencyHz: 6_150, altLevel: 0.12, tuneSemitones: 7,
                                decayShortestSeconds: 0.06, decayMidSeconds: 0.1, decayLongestSeconds: 0.17,
                                attackSeconds: 0.0003, level: 0.7),
                click: SynthClick(level: 0.12, decaySeconds: 0.002, highPassHz: 2_000, noiseFraction: 0.4),
                output: SynthOutput(toneDarkHz: 9_000, toneBrightHz: 16_000, highPassHz: 300),
                velocity: SynthVelocity(rangeDB: 12, brightnessFactor: 1.05),
                durationSeconds: 0.3, seed: seed + 7),
            // A hollow block: lower and shorter than the claves, with a stronger second mode.
            SynthVoiceSpec(
                kind: .woodblock, engine: .ring, machine: machine,
                controls: SynthControls(level: 0.38),
                tone: SynthTone(frequencyHz: 1_080, altFrequencyHz: 2_690, altLevel: 0.35, tuneSemitones: 7,
                                decayShortestSeconds: 0.04, decayMidSeconds: 0.075, decayLongestSeconds: 0.13,
                                attackSeconds: 0.0003, level: 0.7),
                click: SynthClick(level: 0.2, decaySeconds: 0.003, highPassHz: 1_200, noiseFraction: 0.5),
                output: SynthOutput(toneDarkHz: 7_000, toneBrightHz: 14_000, highPassHz: 200),
                velocity: SynthVelocity(rangeDB: 12, brightnessFactor: 1.1),
                durationSeconds: 0.25, seed: seed + 8),
        ]
    }

    /// A hand drum: a pitched ring that relaxes a few percent in its first hundredth of a second,
    /// a band of skin noise, and the slap of the palm.
    private static func skin(_ kind: SynthVoiceKind, _ machine: String, seed: UInt64, hz: Double, peak: Double,
                             decay: (Double, Double, Double), slap: Double) -> SynthVoiceSpec {
        SynthVoiceSpec(
            kind: kind, engine: .bridgedT, machine: machine,
            controls: SynthControls(level: 0.5),
            tone: SynthTone(frequencyHz: hz, tuneSemitones: 7, pitchPeakHz: peak, pitchEnvelopeSeconds: 0.03,
                            decayShortestSeconds: decay.0, decayMidSeconds: decay.1, decayLongestSeconds: decay.2,
                            attackSeconds: 0.0006, level: 0.8),
            noise: SynthNoise(level: 0.1, bandHz: 1_900, bandQ: 0.7, highPassHz: 600,
                              decayShortestSeconds: 0.025, decayMidSeconds: 0.045,
                              decayLongestSeconds: 0.08, attackSeconds: 0.0003),
            click: SynthClick(level: slap, decaySeconds: 0.003, highPassHz: 1_400, noiseFraction: 0.6),
            output: SynthOutput(toneDarkHz: 3_500, toneBrightHz: 10_000, highPassHz: 70, drive: 0.06),
            velocity: SynthVelocity(rangeDB: 14, pitchCents: 40, decayFactor: 1.1, brightnessFactor: 1.2),
            durationSeconds: max(0.3, decay.2 + 0.1), seed: seed)
    }

    // MARK: Electronic

    private static func electronicPercussion(_ machine: String, seed: UInt64) -> [SynthVoiceSpec] {
        let played = playedPercussion(machine, seed: seed)
        return played.map { voice in
            var s = voice
            switch s.kind {
            case .highConga, .lowConga, .highBongo, .lowBongo:
                // The tom circuit switched up: a pure ring with a short upward snap, no skin.
                s.noise.level = 0
                s.click = SynthClick(level: 0.06, decaySeconds: 0.002, highPassHz: 900, noiseFraction: 0.2)
                s.tone.pitchEnvelopeSeconds = 0.008
                s.output.drive = 0.1
            case .claves:
                // The rim circuit on its claves setting: the ring and nothing else.
                s.tone.altLevel = 0
                s.click.level = 0
                s.tone.frequencyHz = 2_500
            case .shaker:
                // Maracas: a very short burst of high-passed noise, no swell.
                s.noise.attackSeconds = 0.001
                s.noise.decayShortestSeconds = 0.03
                s.noise.decayMidSeconds = 0.05
                s.noise.decayLongestSeconds = 0.1
                s.noise.highPassHz = 5_000
            default:
                break
            }
            return s
        }
    }
}
