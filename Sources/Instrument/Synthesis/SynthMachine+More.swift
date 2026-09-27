import Foundation

// MARK: - Four more machines
//
// The 808, the 909 and the LinnDrum are built voice by voice from their circuits, with a source at
// every number. These four are not. Each is **derived** from those voices — retuned, its decays
// and brightness moved, and given the conversion its era had — to reach the character the machine
// is known for. Every change below is ours, chosen by ear against that character, not read off a
// schematic or a service manual, and each machine's summary says "flavour" for that reason.
//
// What each is reaching for:
//   * **CR-78** — Roland's CompuRhythm (1978), the preset box before the 808: every voice analog,
//     short and round, the kick a soft bonk and the hats a thin tick. It had congas and bongos
//     rather than toms, and no clap; the toms here are pitched up into that range, and the clap is
//     a soft two-burst one so the voice exists.
//   * **TR-707** — Roland's all-sample machine (1985): the 909's voices as short, clean, early-
//     digital recordings, tighter and less wild than the 909 itself. The 25 kHz clock is the figure
//     the 909's notes attribute to the 707/727; the bit depths are ours.
//   * **DMX** — Oberheim's 8-bit sampler (1981), the machine of early hip hop: the LinnDrum's kind
//     of voice, but a deeper, longer kick, a fatter snare and a bigger clap, all driven harder.
//   * **Studio Kit** — no machine at all: the acoustic voices with nothing in the way. No
//     companding, no decimation, a beater you can hear, cymbals that ring out.

extension SynthMachine {

    public static let cr78 = SynthMachine(
        id: "cr78",
        name: "CR-78",
        summary: "CR-78 flavour: soft, round analog voices — a bonk of a kick, a ticking hat, pitched-up hand drums.",
        voices: [cr78Kick, cr78Snare, cr78ClosedHat, cr78OpenHat, cr78Clap, cr78Rim,
                 cr78LowTom, cr78MidTom, cr78HighTom, cr78Cowbell, cr78Crash, cr78Ride]
    )

    public static let tr707 = SynthMachine(
        id: "tr707",
        name: "TR-707",
        summary: "TR-707 flavour: crisp, tight early-digital samples of a 909-ish kit.",
        voices: [tr707Kick, tr707Snare, tr707ClosedHat, tr707OpenHat, tr707Clap, tr707Rim,
                 tr707LowTom, tr707MidTom, tr707HighTom, tr707Cowbell, tr707Crash, tr707Ride]
    )

    public static let dmx = SynthMachine(
        id: "dmx",
        name: "DMX",
        summary: "DMX flavour: punchy 8-bit samples — a deep kick, a fat snare, a big clap.",
        voices: [dmxKick, dmxSnare, dmxClosedHat, dmxOpenHat, dmxClap, dmxRim,
                 dmxLowTom, dmxMidTom, dmxHighTom, dmxCowbell, dmxCrash, dmxRide]
    )

    public static let studio = SynthMachine(
        id: "studio",
        name: "Studio Kit",
        summary: "A clean acoustic kit: no sampler in the way, a beater you can hear, cymbals that ring.",
        voices: [studioKick, studioSnare, studioClosedHat, studioOpenHat, studioClap, studioRim,
                 studioLowTom, studioMidTom, studioHighTom, studioCowbell, studioCrash, studioRide]
    )

    /// A copy of `base` that says it is `machine`'s, with its own seed, changed by `change`.
    static func derived(_ base: SynthVoiceSpec, _ machine: String, seed: UInt64,
                                _ change: (inout SynthVoiceSpec) -> Void) -> SynthVoiceSpec {
        var spec = base
        spec.machine = machine
        spec.seed = seed
        change(&spec)
        return spec
    }

    // MARK: CR-78

    static let cr78Kick = derived(tr808Kick, "cr78", seed: 0x78_0001) { s in
        s.tone.frequencyHz = 64
        s.tone.pitchPeakHz = 105
        s.tone.decayShortestSeconds = 0.08
        s.tone.decayMidSeconds = 0.22
        s.tone.decayLongestSeconds = 0.5
        s.click.level = 0.04
        s.output = SynthOutput(toneDarkHz: 700, toneBrightHz: 2_600, highPassHz: 30, drive: 0.05)
        s.controls.level = 0.95
        s.durationSeconds = 0.6
    }
    static let cr78Snare = derived(tr808Snare, "cr78", seed: 0x78_0002) { s in
        s.controls.snappy = 0.32
        s.stretch(0.65)
        s.output.toneBrightHz = min(s.output.toneBrightHz, 7_000)
    }
    static let cr78ClosedHat = derived(tr808ClosedHat, "cr78", seed: 0x78_0003) { s in
        s.stretch(0.6)
        s.controls.level *= 0.85
    }
    static let cr78OpenHat = derived(tr808OpenHat, "cr78", seed: 0x78_0004) { s in
        s.stretch(0.55)
        s.controls.level *= 0.85
    }
    static let cr78Clap = derived(tr808Clap, "cr78", seed: 0x78_0007) { s in
        s.burst?.count = 2
        s.burst?.tailLevel = 0.4
        s.stretch(0.7)
        s.controls.level *= 0.75
    }
    static let cr78Rim = derived(tr808Rim, "cr78", seed: 0x78_0008) { s in
        s.stretch(0.8)
        s.controls.level *= 0.9
    }
    static let cr78LowTom = cr78Drum(tr808LowTom, seed: 0x78_0009)
    static let cr78MidTom = cr78Drum(tr808MidTom, seed: 0x78_000A)
    static let cr78HighTom = cr78Drum(tr808HighTom, seed: 0x78_000B)
    static let cr78Cowbell = derived(tr808Cowbell, "cr78", seed: 0x78_000C) { s in
        s.stretch(0.75)
        s.controls.level *= 0.7
    }
    static let cr78Crash = derived(tr808Crash, "cr78", seed: 0x78_0005) { s in
        s.stretch(0.55)
        s.controls.level *= 0.8
    }
    static let cr78Ride = derived(tr808Ride, "cr78", seed: 0x78_0006) { s in
        s.stretch(0.6)
        s.controls.level *= 0.8
    }

    /// The CR-78's hand drums in the tom slots: a fifth up and shorter, like a conga or a bongo.
    private static func cr78Drum(_ tom: SynthVoiceSpec, seed: UInt64) -> SynthVoiceSpec {
        derived(tom, "cr78", seed: seed) { s in
            s.tone.frequencyHz *= 1.5
            s.tone.pitchPeakHz *= 1.5
            s.stretch(0.55)
        }
    }

    // MARK: TR-707

    /// The drums at 8 bits and the metal at 6, both at 25 kHz: clean enough to read as digital
    /// rather than broken, which is the 707's whole sound against a LinnDrum.
    private static func sampled707(_ spec: inout SynthVoiceSpec, bits: Int = 8) {
        spec.sampled = SynthSampled(bits: bits, playbackRateHz: 25_000)
    }

    static let tr707Kick = derived(tr909Kick, "tr707", seed: 0x707_0001) { s in
        s.stretch(0.55)
        s.click.level *= 0.6
        sampled707(&s)
    }
    static let tr707Snare = derived(tr909Snare, "tr707", seed: 0x707_0002) { s in
        s.stretch(0.7)
        sampled707(&s)
    }
    static let tr707ClosedHat = derived(tr909ClosedHat, "tr707", seed: 0x707_0003) { s in
        s.stretch(0.8)
        sampled707(&s, bits: 6)
    }
    static let tr707OpenHat = derived(tr909OpenHat, "tr707", seed: 0x707_0004) { s in
        s.stretch(0.7)
        sampled707(&s, bits: 6)
    }
    static let tr707Clap = derived(tr909Clap, "tr707", seed: 0x707_0007) { s in
        s.stretch(0.75)
        sampled707(&s)
    }
    static let tr707Rim = derived(tr909Rim, "tr707", seed: 0x707_0008) { s in
        sampled707(&s)
    }
    static let tr707LowTom = derived(tr909LowTom, "tr707", seed: 0x707_0009) { s in
        s.stretch(0.65)
        sampled707(&s)
    }
    static let tr707MidTom = derived(tr909MidTom, "tr707", seed: 0x707_000A) { s in
        s.stretch(0.65)
        sampled707(&s)
    }
    static let tr707HighTom = derived(tr909HighTom, "tr707", seed: 0x707_000B) { s in
        s.stretch(0.65)
        sampled707(&s)
    }
    static let tr707Cowbell = derived(tr808Cowbell, "tr707", seed: 0x707_000C) { s in
        s.stretch(0.8)
        sampled707(&s)
    }
    static let tr707Crash = derived(tr909Crash, "tr707", seed: 0x707_0005) { s in
        s.stretch(0.7)
        sampled707(&s, bits: 6)
    }
    static let tr707Ride = derived(tr909Ride, "tr707", seed: 0x707_0006) { s in
        s.stretch(0.75)
        sampled707(&s, bits: 6)
    }

    // MARK: DMX

    /// 8-bit µ-law like the LinnDrum, clocked a little lower so the top end folds more.
    private static func sampledDMX(_ spec: inout SynthVoiceSpec, rateHz: Double = 25_000) {
        spec.sampled = SynthSampled(bits: 8, playbackRateHz: rateHz)
    }

    static let dmxKick = derived(linnKick, "dmx", seed: 0xD3_0001) { s in
        s.tone.frequencyHz = 54
        s.tone.pitchPeakHz = 170
        s.stretch(1.5)
        s.output.drive = 0.3
        s.output.toneBrightHz = 3_800
        sampledDMX(&s)
    }
    static let dmxSnare = derived(linnSnare, "dmx", seed: 0xD3_0002) { s in
        s.tone.frequencyHz = 175
        s.tone.level = 0.5
        s.output.drive = 0.32
        s.stretch(1.1)
        sampledDMX(&s)
    }
    static let dmxClosedHat = derived(linnClosedHat, "dmx", seed: 0xD3_0003) { s in
        s.stretch(0.8)
        sampledDMX(&s, rateHz: 30_000)
    }
    static let dmxOpenHat = derived(linnOpenHat, "dmx", seed: 0xD3_0004) { s in
        s.stretch(0.9)
        sampledDMX(&s, rateHz: 30_000)
    }
    static let dmxClap = derived(linnClap, "dmx", seed: 0xD3_0007) { s in
        s.burst?.count = 5
        s.burst?.tailLevel = 0.7
        s.stretch(1.25)
        s.output.drive = 0.2
        sampledDMX(&s)
    }
    static let dmxRim = derived(linnRim, "dmx", seed: 0xD3_0008) { s in
        sampledDMX(&s)
    }
    static let dmxLowTom = derived(linnLowTom, "dmx", seed: 0xD3_0009) { s in
        s.tone.frequencyHz *= 0.9
        s.output.drive = 0.22
        sampledDMX(&s)
    }
    static let dmxMidTom = derived(linnMidTom, "dmx", seed: 0xD3_000A) { s in
        s.tone.frequencyHz *= 0.9
        s.output.drive = 0.22
        sampledDMX(&s)
    }
    static let dmxHighTom = derived(linnHighTom, "dmx", seed: 0xD3_000B) { s in
        s.tone.frequencyHz *= 0.9
        s.output.drive = 0.22
        sampledDMX(&s)
    }
    static let dmxCowbell = derived(linnCowbell, "dmx", seed: 0xD3_000C) { s in
        sampledDMX(&s)
    }
    static let dmxCrash = derived(linnCrash, "dmx", seed: 0xD3_0005) { s in
        sampledDMX(&s, rateHz: 30_000)
    }
    static let dmxRide = derived(linnRide, "dmx", seed: 0xD3_0006) { s in
        sampledDMX(&s, rateHz: 30_000)
    }

    // MARK: Studio Kit

    /// The LinnDrum's recordings with the LinnDrum taken away: full resolution, opened up, and
    /// allowed to ring.
    private static func studioVoice(_ base: SynthVoiceSpec, seed: UInt64, ring: Double = 1.2,
                                    _ change: (inout SynthVoiceSpec) -> Void = { _ in }) -> SynthVoiceSpec {
        derived(base, "studio", seed: seed) { s in
            s.sampled = nil
            s.output.toneDarkHz = max(s.output.toneDarkHz, min(s.output.toneBrightHz, s.output.toneDarkHz * 1.8))
            s.output.toneBrightHz = min(18_000, s.output.toneBrightHz * 1.3)
            s.output.drive = min(s.output.drive, 0.06)
            s.stretch(ring)
            change(&s)
        }
    }

    static let studioKick = studioVoice(linnKick, seed: 0x57_0001) { s in
        s.click.level = 0.3
    }
    static let studioSnare = studioVoice(linnSnare, seed: 0x57_0002)
    static let studioClosedHat = studioVoice(linnClosedHat, seed: 0x57_0003, ring: 1.0)
    static let studioOpenHat = studioVoice(linnOpenHat, seed: 0x57_0004)
    static let studioClap = studioVoice(linnClap, seed: 0x57_0007, ring: 1.1)
    static let studioRim = studioVoice(linnRim, seed: 0x57_0008, ring: 1.0)
    static let studioLowTom = studioVoice(linnLowTom, seed: 0x57_0009, ring: 1.3)
    static let studioMidTom = studioVoice(linnMidTom, seed: 0x57_000A, ring: 1.3)
    static let studioHighTom = studioVoice(linnHighTom, seed: 0x57_000B, ring: 1.3)
    static let studioCowbell = studioVoice(tr808Cowbell, seed: 0x57_000C, ring: 1.0) { s in
        s.controls.level *= 0.8
    }
    static let studioCrash = studioVoice(linnCrash, seed: 0x57_0005, ring: 1.5)
    static let studioRide = studioVoice(linnRide, seed: 0x57_0006, ring: 1.5)
}

extension SynthVoiceSpec {
    /// Every decay the knobs reach, and the render's length, scaled by `factor`: a longer or a
    /// tighter drum of the same kind. Attack, pitch sweep and click are left alone — they are the
    /// hit, not the ring.
    mutating func stretch(_ factor: Double) {
        tone.decayShortestSeconds *= factor
        tone.decayMidSeconds *= factor
        tone.decayLongestSeconds *= factor
        tone.altDecaySeconds *= factor
        noise.decayShortestSeconds *= factor
        noise.decayMidSeconds *= factor
        noise.decayLongestSeconds *= factor
        burst?.tailDecaySeconds *= factor
        durationSeconds = max(0.15, durationSeconds * factor)
    }
}
