import Foundation

// MARK: - Ten more kits
//
// Derived like the four in `SynthMachine+More.swift`: every voice starts as one of the modelled
// 808, 909 or LinnDrum voices, or the Studio Kit built from them, and is retuned, lengthened or
// shortened, darkened, driven and given the conversion its era had. Every change is ours, chosen
// toward the character each kit is known for; none is measured from the hardware or a recording.
//
// They come in four kinds, which is how the Grid's menu groups them (`SynthMachine.Family`):
//   * **Drum machines** — the TR-606, the 808's thin little sibling; and a Simmons SDS-V, the
//     electronic kit whose toms sweep down.
//   * **Samplers** — an SP-1200 and an MPC60: an acoustic kit through each one's converter, the
//     12-bit grit and the folded top end hip hop was made on.
//   * **Acoustic kits** — jazz brushes, a big rock kit, a tight funk kit and a vintage kit.
//   * **Styles** — trap, on a long tuned 808 kick; and lo-fi, dark and crushed.

extension SynthMachine {

    /// How a picker groups the machines.
    public enum Family: String, CaseIterable, Sendable {
        case machine, sampler, acoustic, style

        public var title: String {
            switch self {
            case .machine: return "Drum machines"
            case .sampler: return "Samplers"
            case .acoustic: return "Acoustic kits"
            case .style: return "Styles"
            }
        }
    }

    /// Which group a machine is listed in. A machine not among the presets is a drum machine.
    public var family: Family {
        switch id {
        case "sp1200", "mpc60": return .sampler
        case "studio", "jazz", "rock", "funk", "vintage": return .acoustic
        case "trap", "lofi": return .style
        default: return .machine
        }
    }

    public static let tr606 = SynthMachine(
        id: "tr606", name: "TR-606",
        summary: "TR-606 flavour: the 808's thin little sibling — a tight kick, a papery snare, bright hats.",
        voices: [tr606Kick, tr606Snare, tr606ClosedHat, tr606OpenHat, tr606Clap, tr606Rim,
                 tr606LowTom, tr606MidTom, tr606HighTom, tr606Cowbell, tr606Crash, tr606Ride])

    public static let simmons = SynthMachine(
        id: "simmons", name: "Simmons",
        summary: "Simmons SDS-V flavour: toms that sweep down, a snare that is half tone, a kick with a click.",
        voices: [simmonsKick, simmonsSnare, simmonsClosedHat, simmonsOpenHat, simmonsClap, simmonsRim,
                 simmonsLowTom, simmonsMidTom, simmonsHighTom, simmonsCowbell, simmonsCrash, simmonsRide])

    public static let sp1200 = SynthMachine(
        id: "sp1200", name: "SP-1200",
        summary: "SP-1200 flavour: an acoustic kit at 12 bits and 26 kHz — heavy low end, gritty, folded top.",
        voices: sampler(studioVoices, id: "sp1200", seed: 0x1200_0000, bits: 12, rateHz: 26_040, weight: 1.25))

    public static let mpc60 = SynthMachine(
        id: "mpc60", name: "MPC60",
        summary: "MPC60 flavour: an acoustic kit at 12 bits and 40 kHz — punchy and warm.",
        voices: sampler(studioVoices, id: "mpc60", seed: 0x60_0000, bits: 12, rateHz: 40_000, weight: 1.1))

    public static let jazz = SynthMachine(
        id: "jazz", name: "Jazz Brushes",
        summary: "A jazz kit played with brushes: a soft felt kick, a swishing snare, a ride that sings.",
        voices: [jazzKick, jazzSnare, jazzClosedHat, jazzOpenHat, jazzClap, jazzRim,
                 jazzLowTom, jazzMidTom, jazzHighTom, jazzCowbell, jazzCrash, jazzRide])

    public static let rock = SynthMachine(
        id: "rock", name: "Rock Kit",
        summary: "A big rock kit: a deep kick, a fat snare with room, crashes that open up.",
        voices: [rockKick, rockSnare, rockClosedHat, rockOpenHat, rockClap, rockRim,
                 rockLowTom, rockMidTom, rockHighTom, rockCowbell, rockCrash, rockRide])

    public static let funk = SynthMachine(
        id: "funk", name: "Funk Kit",
        summary: "A tight funk kit: a dry, punchy kick, a crisp high snare, tight hats for ghost notes.",
        voices: [funkKick, funkSnare, funkClosedHat, funkOpenHat, funkClap, funkRim,
                 funkLowTom, funkMidTom, funkHighTom, funkCowbell, funkCrash, funkRide])

    public static let vintage = SynthMachine(
        id: "vintage", name: "Vintage Kit",
        summary: "A late-sixties kit: a muffled kick, a dark snare, cymbals like an old record.",
        voices: studioVoices.enumerated().map { index, voice in
            derived(voice, "vintage", seed: 0x1969_0000 + UInt64(index)) { s in
                s.darken(by: 0.55)
                s.output.drive = 0.12
                if s.kind == .kick || s.kind == .snare { s.stretch(0.8) }
            }
        })

    public static let trap = SynthMachine(
        id: "trap", name: "Trap Kit",
        summary: "Trap: a long, tuned 808 kick, a sharp clap and snare, crisp hats for rolls.",
        voices: [trapKick, trapSnare, trapClosedHat, trapOpenHat, trapClap, trapRim,
                 trapLowTom, trapMidTom, trapHighTom, trapCowbell, trapCrash, trapRide])

    public static let lofi = SynthMachine(
        id: "lofi", name: "Lo-fi Kit",
        summary: "Lo-fi: a dusty acoustic kit, dark and soft, crushed to 10 bits at 22 kHz.",
        voices: studioVoices.enumerated().map { index, voice in
            derived(voice, "lofi", seed: 0x10F1_0000 + UInt64(index)) { s in
                s.darken(by: 0.6)
                s.sampled = SynthSampled(bits: 10, playbackRateHz: 22_050)
                s.controls.level *= 0.9
                if s.kind == .snare { s.tone.level *= 1.3 }
            }
        })

    /// The Studio Kit's voices, in the kit order every machine uses.
    private static var studioVoices: [SynthVoiceSpec] { studio.voices }

    /// An acoustic kit through a sampler's converter: its bits and its clock, the kick and snare
    /// given `weight` more low end and drive, the way these machines were fed and played.
    private static func sampler(_ voices: [SynthVoiceSpec], id: String, seed: UInt64, bits: Int,
                                rateHz: Double, weight: Double) -> [SynthVoiceSpec] {
        voices.enumerated().map { index, voice in
            derived(voice, id, seed: seed + UInt64(index)) { s in
                s.sampled = SynthSampled(bits: bits, playbackRateHz: rateHz)
                switch s.kind {
                case .kick:
                    s.tone.frequencyHz *= 1 / weight
                    s.stretch(weight)
                    s.output.drive = 0.22
                case .snare:
                    s.tone.level *= weight
                    s.output.drive = 0.22
                case .closedHat, .openHat:
                    s.stretch(0.85)
                default:
                    break
                }
            }
        }
    }

    // MARK: TR-606

    static let tr606Kick = derived(tr808Kick, "tr606", seed: 0x606_0001) { s in
        s.tone.frequencyHz = 60
        s.tone.pitchPeakHz = 150
        s.tone.decayShortestSeconds = 0.08
        s.tone.decayMidSeconds = 0.2
        s.tone.decayLongestSeconds = 0.45
        s.click.level = 0.12
        s.durationSeconds = 0.6
    }
    static let tr606Snare = derived(tr808Snare, "tr606", seed: 0x606_0002) { s in
        s.controls.snappy = 0.7
        s.tone.level *= 0.75
        s.stretch(0.7)
    }
    static let tr606ClosedHat = derived(tr808ClosedHat, "tr606", seed: 0x606_0003) { s in
        s.stretch(0.8)
    }
    static let tr606OpenHat = derived(tr808OpenHat, "tr606", seed: 0x606_0004) { s in
        s.stretch(0.75)
    }
    /// The 606 had no clap; a short one, so the voice is there.
    static let tr606Clap = derived(tr808Clap, "tr606", seed: 0x606_0007) { s in
        s.stretch(0.7)
        s.controls.level *= 0.8
    }
    static let tr606Rim = derived(tr808Rim, "tr606", seed: 0x606_0008) { _ in }
    static let tr606LowTom = tr606Tom(tr808LowTom, seed: 0x606_0009)
    static let tr606MidTom = tr606Tom(tr808MidTom, seed: 0x606_000A)
    static let tr606HighTom = tr606Tom(tr808HighTom, seed: 0x606_000B)
    static let tr606Cowbell = derived(tr808Cowbell, "tr606", seed: 0x606_000C) { s in s.stretch(0.8) }
    static let tr606Crash = derived(tr808Crash, "tr606", seed: 0x606_0005) { s in s.stretch(0.6) }
    static let tr606Ride = derived(tr808Ride, "tr606", seed: 0x606_0006) { s in s.stretch(0.7) }

    private static func tr606Tom(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "tr606", seed: seed) { s in
            s.tone.frequencyHz *= 1.15
            s.tone.pitchPeakHz *= 1.15
            s.stretch(0.7)
        }
    }

    // MARK: Simmons

    static let simmonsKick = derived(tr909Kick, "simmons", seed: 0x5D5_0001) { s in
        s.tone.pitchPeakHz = 420
        s.click.level = 0.5
        s.stretch(0.8)
    }
    /// Half tone: the SDS-V's snare mixed a drum oscillator with its noise, and players turned the
    /// tone up.
    static let simmonsSnare = derived(tr909Snare, "simmons", seed: 0x5D5_0002) { s in
        s.tone.level = min(1, s.tone.level * 1.6)
        s.tone.pitchPeakHz = s.tone.frequencyHz * 1.8
        s.tone.pitchEnvelopeSeconds = 0.06
        s.noise.level *= 0.7
        s.stretch(1.2)
    }
    /// The SDS-V had no hats of its own; the 909's metal, left analog, stands in.
    static let simmonsClosedHat = derived(tr909ClosedHat, "simmons", seed: 0x5D5_0003) { s in s.sampled = nil }
    static let simmonsOpenHat = derived(tr909OpenHat, "simmons", seed: 0x5D5_0004) { s in s.sampled = nil }
    static let simmonsClap = derived(tr909Clap, "simmons", seed: 0x5D5_0007) { _ in }
    static let simmonsRim = derived(tr909Rim, "simmons", seed: 0x5D5_0008) { _ in }
    static let simmonsLowTom = simmonsTom(tr909LowTom, seed: 0x5D5_0009)
    static let simmonsMidTom = simmonsTom(tr909MidTom, seed: 0x5D5_000A)
    static let simmonsHighTom = simmonsTom(tr909HighTom, seed: 0x5D5_000B)
    static let simmonsCowbell = derived(tr808Cowbell, "simmons", seed: 0x5D5_000C) { _ in }
    static let simmonsCrash = derived(tr909Crash, "simmons", seed: 0x5D5_0005) { s in s.sampled = nil }
    static let simmonsRide = derived(tr909Ride, "simmons", seed: 0x5D5_0006) { s in s.sampled = nil }

    /// The sound the kit is known for: a tom that starts well above its note and sweeps down to it.
    private static func simmonsTom(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "simmons", seed: seed) { s in
            s.tone.pitchPeakHz = s.tone.frequencyHz * 3
            s.tone.pitchEnvelopeSeconds = 0.3
            s.noise.level *= 0.6
            s.stretch(1.4)
        }
    }

    // MARK: Jazz brushes

    static let jazzKick = derived(studioKick, "jazz", seed: 0x1A22_0001) { s in
        s.click.level = 0.08
        s.output.toneBrightHz = min(s.output.toneBrightHz, 2_200)
        s.output.toneDarkHz = min(s.output.toneDarkHz, 900)
        s.controls.level *= 0.8
        s.stretch(0.8)
    }
    /// A brush: next to no drum tone, and noise that swells in over a few milliseconds rather than
    /// cracking, then sweeps away.
    static let jazzSnare = derived(studioSnare, "jazz", seed: 0x1A22_0002) { s in
        s.tone.level *= 0.25
        s.noise.attackSeconds = 0.012
        s.noise.bandHz = 2_600
        s.noise.highPassHz = 600
        s.stretch(1.6)
        s.output.toneBrightHz = min(s.output.toneBrightHz, 9_000)
        s.output.toneDarkHz = min(s.output.toneDarkHz, s.output.toneBrightHz)
        s.controls.level *= 0.75
    }
    static let jazzClosedHat = derived(studioClosedHat, "jazz", seed: 0x1A22_0003) { s in
        s.stretch(0.9)
        s.controls.level *= 0.8
    }
    static let jazzOpenHat = derived(studioOpenHat, "jazz", seed: 0x1A22_0004) { s in s.controls.level *= 0.8 }
    /// No clap in a jazz kit: a single soft slap, so the voice is there.
    static let jazzClap = derived(studioClap, "jazz", seed: 0x1A22_0007) { s in
        s.burst?.count = 1
        s.stretch(0.7)
        s.controls.level *= 0.6
    }
    /// A cross-stick.
    static let jazzRim = derived(studioRim, "jazz", seed: 0x1A22_0008) { s in s.controls.level *= 0.8 }
    static let jazzLowTom = jazzTom(studioLowTom, seed: 0x1A22_0009)
    static let jazzMidTom = jazzTom(studioMidTom, seed: 0x1A22_000A)
    static let jazzHighTom = jazzTom(studioHighTom, seed: 0x1A22_000B)
    static let jazzCowbell = derived(studioCowbell, "jazz", seed: 0x1A22_000C) { s in s.controls.level *= 0.6 }
    static let jazzCrash = derived(studioCrash, "jazz", seed: 0x1A22_0005) { s in
        s.stretch(1.3)
        s.controls.level *= 0.8
    }
    /// The timekeeper in jazz, so it rings longest and sits forward.
    static let jazzRide = derived(studioRide, "jazz", seed: 0x1A22_0006) { s in
        s.stretch(1.5)
        s.controls.level = min(1, s.controls.level * 1.15)
    }

    /// Small, high toms, tuned up and left open.
    private static func jazzTom(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "jazz", seed: seed) { s in
            s.tone.frequencyHz *= 1.25
            s.tone.pitchPeakHz *= 1.25
            s.stretch(1.1)
        }
    }

    // MARK: Rock

    static let rockKick = derived(studioKick, "rock", seed: 0x70C4_0001) { s in
        s.tone.frequencyHz = 52
        s.click.level = 0.35
        s.output.drive = 0.2
        s.stretch(1.3)
    }
    static let rockSnare = derived(studioSnare, "rock", seed: 0x70C4_0002) { s in
        s.tone.frequencyHz = 170
        s.tone.level = min(1, s.tone.level * 1.2)
        s.output.drive = 0.25
        s.controls.level = min(1, s.controls.level * 1.08)
        s.stretch(1.4)
    }
    static let rockClosedHat = derived(studioClosedHat, "rock", seed: 0x70C4_0003) { _ in }
    static let rockOpenHat = derived(studioOpenHat, "rock", seed: 0x70C4_0004) { s in s.stretch(1.1) }
    static let rockClap = derived(studioClap, "rock", seed: 0x70C4_0007) { s in s.stretch(1.2) }
    static let rockRim = derived(studioRim, "rock", seed: 0x70C4_0008) { _ in }
    static let rockLowTom = rockTom(studioLowTom, seed: 0x70C4_0009)
    static let rockMidTom = rockTom(studioMidTom, seed: 0x70C4_000A)
    static let rockHighTom = rockTom(studioHighTom, seed: 0x70C4_000B)
    static let rockCowbell = derived(studioCowbell, "rock", seed: 0x70C4_000C) { _ in }
    static let rockCrash = derived(studioCrash, "rock", seed: 0x70C4_0005) { s in
        s.stretch(1.3)
        s.controls.level = min(1, s.controls.level * 1.15)
    }
    static let rockRide = derived(studioRide, "rock", seed: 0x70C4_0006) { s in s.stretch(1.2) }

    /// Big toms, tuned down and left to ring.
    private static func rockTom(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "rock", seed: seed) { s in
            s.tone.frequencyHz *= 0.85
            s.tone.pitchPeakHz *= 0.85
            s.output.drive = 0.2
            s.stretch(1.4)
        }
    }

    // MARK: Funk

    static let funkKick = derived(studioKick, "funk", seed: 0xF0C_0001) { s in
        s.click.level = 0.35
        s.stretch(0.6)
    }
    static let funkSnare = derived(studioSnare, "funk", seed: 0xF0C_0002) { s in
        s.tone.frequencyHz *= 1.2
        s.tone.altFrequencyHz *= 1.2
        s.controls.snappy = min(1, s.controls.snappy + 0.1)
        s.stretch(0.7)
    }
    static let funkClosedHat = derived(studioClosedHat, "funk", seed: 0xF0C_0003) { s in s.stretch(0.7) }
    static let funkOpenHat = derived(studioOpenHat, "funk", seed: 0xF0C_0004) { s in s.stretch(0.8) }
    static let funkClap = derived(studioClap, "funk", seed: 0xF0C_0007) { s in s.stretch(0.8) }
    static let funkRim = derived(studioRim, "funk", seed: 0xF0C_0008) { _ in }
    static let funkLowTom = funkTom(studioLowTom, seed: 0xF0C_0009)
    static let funkMidTom = funkTom(studioMidTom, seed: 0xF0C_000A)
    static let funkHighTom = funkTom(studioHighTom, seed: 0xF0C_000B)
    static let funkCowbell = derived(studioCowbell, "funk", seed: 0xF0C_000C) { _ in }
    static let funkCrash = derived(studioCrash, "funk", seed: 0xF0C_0005) { s in s.stretch(0.8) }
    static let funkRide = derived(studioRide, "funk", seed: 0xF0C_0006) { s in s.stretch(0.9) }

    private static func funkTom(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "funk", seed: seed) { s in
            s.tone.frequencyHz *= 1.1
            s.tone.pitchPeakHz *= 1.1
            s.stretch(0.8)
        }
    }

    // MARK: Trap

    /// The long 808: the bridged-T's decay run out to seconds so the kick is also the bass, with
    /// enough drive to be heard on a phone.
    static let trapKick = derived(tr808Kick, "trap", seed: 0x7FA9_0001) { s in
        s.tone.decayShortestSeconds = 0.5
        s.tone.decayMidSeconds = 1.1
        s.tone.decayLongestSeconds = 2.6
        s.output.drive = 0.3
        s.controls.level = 0.85
        s.durationSeconds = 2.8
    }
    static let trapSnare = derived(tr909Snare, "trap", seed: 0x7FA9_0002) { s in
        s.controls.snappy = min(1, s.controls.snappy + 0.2)
        s.stretch(0.7)
    }
    static let trapClosedHat = derived(tr909ClosedHat, "trap", seed: 0x7FA9_0003) { s in s.stretch(0.6) }
    static let trapOpenHat = derived(tr909OpenHat, "trap", seed: 0x7FA9_0004) { s in s.stretch(0.8) }
    static let trapClap = derived(tr909Clap, "trap", seed: 0x7FA9_0007) { s in
        s.controls.level = min(1, s.controls.level * 1.1)
    }
    static let trapRim = derived(tr808Rim, "trap", seed: 0x7FA9_0008) { _ in }
    static let trapLowTom = derived(tr808LowTom, "trap", seed: 0x7FA9_0009) { _ in }
    static let trapMidTom = derived(tr808MidTom, "trap", seed: 0x7FA9_000A) { _ in }
    static let trapHighTom = derived(tr808HighTom, "trap", seed: 0x7FA9_000B) { _ in }
    static let trapCowbell = derived(tr808Cowbell, "trap", seed: 0x7FA9_000C) { _ in }
    static let trapCrash = derived(tr909Crash, "trap", seed: 0x7FA9_0005) { _ in }
    static let trapRide = derived(tr909Ride, "trap", seed: 0x7FA9_0006) { _ in }
}

extension SynthVoiceSpec {
    /// A darker voice: the output low-pass at both ends of TONE moved down by `factor`, and the
    /// noise band and its high-pass half as far (in octaves). What a room, a tape or an old record
    /// does to a drum: the top goes, the drum's own ring mostly stays where it was.
    mutating func darken(by factor: Double) {
        output.toneDarkHz *= factor
        output.toneBrightHz *= factor
        noise.bandHz *= factor.squareRoot()
        noise.highPassHz *= factor.squareRoot()
    }
}
