import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The three checks the Sampler runs over its own chop before anybody hears it.
//
// All three are pure functions of a `ChopReview`. None of them touches audio except by reading the
// mono buffer the caller already has, none allocates a kit, and none applies anything.

// MARK: - A cut that shaves a transient

/// Did a cut land *after* the attack it was meant to capture?
///
/// This is the one unambiguous chopping mistake, and it has a direction. A cut a little early is
/// harmless: the pad picks up a fraction of a millisecond of whatever came before, which is why
/// `Chopper.zeroCrossingWindow` only ever searches backwards. A cut a little *late* leaves the front
/// of the attack on the previous pad, so the pad you fire starts part-way up the transient — a drum
/// with its click missing, and a previous pad that ends on a spike.
///
/// The engine records this directly. `Chopper` pulls a detected onset onto a grid line when the two
/// are within `snapTolerance` (25 ms by default), stores how far it moved in `Slice.snapOffset`, and
/// a **positive** offset means the marker moved later than the transient it came from. That is the
/// measurement; no waveform analysis is needed for it. Where the offsets are absent — a hand-placed
/// marker, a chop loaded from a version — the critic falls back to the detected onsets and measures
/// the same quantity against the nearest transient at or before the cut.
///
/// ## The threshold
///
/// 2 ms. From this project's own `ChopMap.Declick` note, which sizes the anti-click fade against
/// real attack lengths: "a kick's own attack is tens of milliseconds, a hat's one or two". A cut
/// 2 ms late has removed an entire closed hat's attack, and the fade meant to hide a discontinuity
/// is then hiding a missing transient instead. Below 2 ms the shave is inside the declick's own
/// working range and inside the onset detector's resolution (a 256-sample hop at 44.1 kHz is 5.8 ms,
/// so a sub-2 ms disagreement is not even a measurement).
///
/// **INFERRED**, from the engine's own documented attack lengths rather than from a producer source.
/// The published record on where to cut relative to a transient is thin: the direction is
/// well supported — slicers are documented placing markers late on slow-attack sounds, and the Akai
/// S950 shipped *pretrigger recording* as a named feature in 1988, which is a manufacturer building
/// pre-transient capture into hardware — but no primary source states a millisecond figure.
///
/// Sources: <https://www.vintagedigital.com.au/akai-s950/> (pretrigger recording);
/// <https://sampleroll.com/blog/chopping-by-transients-how-to> (auto-slicers placing markers late on
/// slow attacks, and dragging the marker earlier as the manual fix);
/// <https://www.soundonsound.com/techniques/lost-art-sampling-part-4> (zero crossings and the flam a
/// duplicated transient produces — and no millisecond figures anywhere in it).
public struct TransientCutCritic: ChopCritic {
    public let id = CriticID.transientCut
    public let name = "Transient check"
    public let persona = PersonaID.sampler

    /// A cut later than this much past its transient has shaved an attack, in seconds.
    public var shaveLimit: Double
    /// How far back to look for the transient a cut belongs to, when working from detected onsets.
    /// Matches `Chopper.snapTolerance`, because a cut further from an onset than the chopper would
    /// ever have snapped is a cut that belongs to a different transient.
    public var searchWindow: Double

    public init(shaveLimit: Double = 0.002, searchWindow: Double = 0.025) {
        self.shaveLimit = shaveLimit
        self.searchWindow = searchWindow
    }

    public var checks: String {
        String(format: "A cut more than %.0f ms after the transient it was taken from.", shaveLimit * 1000)
    }

    public func review(_ input: ChopReview) -> [Finding] {
        let onsets = input.detectedOnsets.sorted()
        var findings: [Finding] = []

        for slice in input.chop.slices {
            // The lead-in is by definition not on a transient, and a division cut never claimed to
            // be: neither can shave an attack it was not aiming at.
            guard slice.origin == .snapped || slice.origin == .onset || slice.origin == .grid else { continue }

            var shave = max(0, slice.snapOffset)
            if shave <= 0, !onsets.isEmpty {
                // Nearest transient at or before this cut, within the chopper's own tolerance.
                let start = slice.startSeconds
                if let onset = onsets.last(where: { $0 <= start && start - $0 <= searchWindow }) {
                    shave = start - onset
                }
            }
            guard shave > shaveLimit else { continue }

            let ms = shave * 1000
            let threshold = Threshold.atMost(.attackShaveMS, shaveLimit * 1000, unit: "ms")
            let headline = String(format: "Slice %d starts %.1f ms after its transient", slice.index, ms)
            findings.append(Finding(
                critic: id, criticName: name, persona: persona,
                subject: .slice(slice.index),
                locus: Locus(start: max(0, slice.startSeconds - shave), end: slice.startSeconds + 0.05),
                headline: headline,
                why: "The front of the attack is left on the pad before it, so this pad begins part-way "
                   + "up the transient and the one before it ends on a spike.",
                severity: .warn,
                measurement: Measurement(.attackShaveMS, measured: ms, threshold: threshold, unit: "ms"),
                first: Fix("move-earlier",
                           title: String(format: "Move the cut %.1f ms earlier", ms),
                           detail: "Puts the whole attack on this pad. Costs the previous pad the same "
                                 + "few milliseconds of tail, which is below the ear's resolution for a drum.",
                           change: .moveSliceStart(slice: slice.index, by: -shave)),
                second: Fix("cut-on-onsets",
                            title: "Cut on the transients, not the grid",
                            detail: "Fixes every cut in the chop at once by dropping the snap. The chop "
                                  + "stops lining up with the bar, which is the whole point on a break "
                                  + "that was not played to a click.",
                            change: .setSnapTolerance(0))))
        }
        return findings
    }
}

// MARK: - Levels that will not survive the mix

/// Three level failures, each with a threshold derived from something the engine already knows.
///
/// **Clipping into the chain.** A slice already at full scale, fed a drive above unity, hits the
/// saturation curve's ceiling before the curve has any shape left to give. `DegradeSettings.drive`
/// is a linear gain *into* the curve, so peak + drive is the number that matters, and the SP-1200
/// and MPC60 presets both carry drive above 1 (1.40 and 1.20) as their stand-in for the machine's
/// output stage. A slice at −0.3 dBFS through 1.40 is 2.6 dB into hard territory.
///
/// **Under the source's own floor.** A slice whose peak is inside 6 dB of the recording's own noise
/// floor is not a drum, it is the room. 6 dB is one bit and the conventional edge of "distinguishable
/// from the floor"; the floor itself is measured, not assumed (`SourceMeasurement.noiseFloorDB`).
/// The numbers this lands on are in the right place for the material: a microgroove LP's dynamic
/// range is published at 55–65 dB, up to 70 dB on a first play of the outer grooves, and a compact
/// cassette's at 50–56 dB, so a slice 60 dB under peak on a vinyl-sourced break genuinely is noise.
///
/// **Spread inside a class.** This is the one that actually ruins a re-groove, and it is the one
/// nobody hears until the second bar. `Regroove.Policy.rotate` hands the slices of a class out in
/// turn, so two snares 20 dB apart mean the backbeat alternates loud and quiet regardless of what
/// the feel's velocities asked for. The threshold is therefore not a taste figure: it is the
/// velocity map's **own dynamic range**, `20·log10(accent/ghost)`. Once the source spread exceeds
/// that, the feel's tiers can no longer reorder the hits — an accent on the quiet slice is still
/// under a ghost on the loud one — and the groove is being written by the sample library instead of
/// by the feel.
///
/// Sources: dynamic ranges of vinyl and cassette, <https://en.wikipedia.org/wiki/Dynamic_range>;
/// the drive figures are this project's own presets in `Sources/CDegrade/degrade.c`. The 6 dB
/// "distinguishable from the floor" margin is **INFERRED**.
public struct SliceLevelCritic: ChopCritic {
    public let id = CriticID.sliceLevel
    public let name = "Level check"
    public let persona = PersonaID.sampler

    /// Peak, in dBFS, at or above which a slice is treated as already at the ceiling.
    public var ceilingDB: Double
    /// How far above the measured noise floor a slice has to peak to be a sound rather than the room.
    public var floorMarginDB: Double

    public init(ceilingDB: Double = -0.3, floorMarginDB: Double = 6) {
        self.ceilingDB = ceilingDB
        self.floorMarginDB = floorMarginDB
    }

    public var checks: String {
        "A slice clipping into the chain's drive, a slice inside 6 dB of the source's noise floor, "
        + "or a spread inside one class wider than the velocity map's own range."
    }

    /// The velocity map's dynamic range in dB: how far a ghost sits under an accent.
    public static func dynamicRangeDB(_ map: VelocityMap) -> Double {
        20 * log10(Double(max(1, map.accent)) / Double(max(1, map.ghost)))
    }

    public func review(_ input: ChopReview) -> [Finding] {
        var findings: [Finding] = []
        let observation = input.observation

        // 1. Clipping into the chain.
        if let degrade = input.degrade, degrade.drive > 1, !degrade.isBypass {
            let driveDB = 20 * log10(degrade.drive)
            let hottest = observation.slicePeakDB
                .filter { $0.value.isFinite }
                .max { $0.value < $1.value }
            if let hottest, hottest.value >= ceilingDB {
                let over = hottest.value + driveDB
                findings.append(Finding(
                    critic: id, criticName: name, persona: persona,
                    subject: .slice(hottest.key),
                    locus: locus(of: hottest.key, in: input),
                    headline: String(format: "Slice %d peaks at %.1f dBFS into %.2f× drive",
                                     hottest.key, hottest.value, degrade.drive),
                    why: String(format: "The drive puts it %.1f dB past full scale before the curve has "
                                      + "any shape left, so the attack flattens instead of thickening.", over),
                    severity: .warn,
                    measurement: Measurement(.sliceFloorDB, measured: hottest.value,
                                             threshold: .atMost(.sliceFloorDB, ceilingDB, unit: "dBFS"),
                                             unit: "dBFS"),
                    first: Fix("trim-slice",
                               title: String(format: "Trim slice %d by %.1f dB", hottest.key, over + 1),
                               detail: "Gives the curve room to work on this slice only; the rest of the "
                                     + "chop keeps its level.",
                               change: .setSliceGain(slice: hottest.key, dB: -(over + 1))),
                    second: Fix("back-off-drive",
                                title: "Back the chain off to dry",
                                detail: "Keeps every slice's level and loses the saturation. The right "
                                      + "answer when the source was already pushed before you got it.",
                                change: .setDegradeMix(0))))
            }
        }

        // 2. Slices inside the noise floor.
        if let floor = observation.noiseFloorDB, floor.isFinite {
            let buried = observation.slicePeakDB
                .filter { $0.value.isFinite && $0.value < floor + floorMarginDB }
                .sorted { $0.key < $1.key }
            if let worst = buried.min(by: { $0.value < $1.value }) {
                findings.append(Finding(
                    critic: id, criticName: name, persona: persona,
                    subject: .slice(worst.key),
                    locus: locus(of: worst.key, in: input),
                    headline: String(format: "Slice %d peaks %.1f dB over the source's own noise floor",
                                     worst.key, worst.value - floor),
                    why: "Anything this close to the floor is the room rather than a drum, and the mix "
                       + "will bury it before the first fader move.",
                    severity: .warn,
                    measurement: Measurement(.sliceFloorDB, measured: worst.value - floor,
                                             threshold: .atLeast(.sliceFloorDB, floorMarginDB, unit: "dB"),
                                             unit: "dB"),
                    first: Fix("drop-slice",
                               title: "Take it out of the rotation",
                               detail: "The other slices of its class cover the steps it was serving. "
                                     + "Costs one variation.",
                               change: .dropSlice(worst.key)),
                    second: Fix("lift-slice",
                                title: String(format: "Lift it %.0f dB", max(6, floor + floorMarginDB - worst.value)),
                                detail: "Brings the hit up and the floor with it — you will hear the "
                                      + "room under this pad and not under the others.",
                                change: .setSliceGain(slice: worst.key,
                                                      dB: max(6, floor + floorMarginDB - worst.value)))))
            }
        }

        // 3. Spread inside a class, against the velocity map's own range.
        let range = Self.dynamicRangeDB(input.velocities)
        for kind in SliceClass.allCases {
            let spread = observation.spreadDB(of: kind)
            guard spread > range else { continue }
            let members = observation.sliceClass.filter { $0.value == kind }.map(\.key)
            guard let quietest = members
                .compactMap({ index in observation.slicePeakDB[index].map { (index, $0) } })
                .filter({ $0.1.isFinite })
                .min(by: { $0.1 < $1.1 }) else { continue }
            findings.append(Finding(
                critic: id, criticName: name, persona: persona,
                subject: .slice(quietest.0),
                locus: locus(of: quietest.0, in: input),
                headline: String(format: "The %@ slices span %.1f dB, wider than the map's %.1f dB",
                                 kind.rawValue, spread, range),
                why: "The rotation alternates them, so the source's own levels decide the accents and "
                   + "the feel's velocity tiers stop meaning anything.",
                severity: .warn,
                measurement: Measurement(.sliceSpreadDB, measured: spread,
                                         threshold: .atMost(.sliceSpreadDB, range, unit: "dB"),
                                         unit: "dB"),
                first: Fix("match-levels",
                           title: String(format: "Lift slice %d to match its class", quietest.0),
                           detail: "Puts the rotation back under the feel's control. Costs the natural "
                                 + "dynamic the break was played with.",
                           change: .setSliceGain(slice: quietest.0, dB: spread - range)),
                second: Fix("stop-rotating",
                            title: "Play the strongest one every time",
                            detail: "A single hit on every step of that voice, which is how an SP-1200 "
                                  + "with one snare in it sounds. Costs the variation.",
                            change: .dropSlice(quietest.0))))
        }

        return findings
    }

    private func locus(of index: Int, in input: ChopReview) -> Locus {
        guard let slice = input.chop.slices.first(where: { $0.index == index }) else { return Locus() }
        return Locus(start: slice.startSeconds, end: slice.endSeconds)
    }
}

// MARK: - A chain with nothing left to take

/// Is the degradation chain doing anything the source has not already had done to it?
///
/// Two ways it is not.
///
/// **The corner is above the source's own top end.** Every preset in the chain ends in a high cut —
/// 12 kHz for the SP-1200, 17 kHz for the MPC60, 14 kHz for the cassette, 16 kHz for vinyl — and a
/// source whose energy already stops below that corner will not be made darker by it. What the
/// preset *will* still do is add its noise bed, its crackle and its wow. So the chain stops being
/// a character and becomes a layer of hiss over something that already had character, which is the
/// commonest way a lo-fi chain makes a record worse.
///
/// The measurement is the source's 95% spectral rolloff (`SourceMeasurement.rolloff`) against the
/// chain's `highCut`. Nothing subjective in it.
///
/// **It is the second pass.** A source that arrived through a 12-bit machine, or that a previous
/// version already ran through a preset, is quantised once. Quantising again at the same width adds
/// error without adding the artifact anybody wanted, because the first pass already put the signal
/// on the 12-bit lattice. `SourceObservation.priorDegrades` is what records that, and the check is
/// categorical rather than thresholded: a second lossy pass over a source that has had one is worth
/// saying out loud.
///
/// Both of these are structural facts about the chain rather than opinions about taste, which is why
/// they are critic findings rather than Sampler rules. The persona's own position — that the SP-303
/// let you run **one effect at a time** and that Madlib printed the effect at capture rather than
/// stacking it afterwards — is in `Sampler.swift`.
///
/// Sources: the preset corners are this project's own, in `Sources/CDegrade/degrade.c`; the SP-303's
/// one-effect-at-a-time constraint,
/// <https://musictech.com/features/boss-sp-303-hip-hop-connection-j-dilla-madlib-mf-doom/>; vinyl
/// and cassette dynamic ranges, <https://en.wikipedia.org/wiki/Dynamic_range>.
public struct DegradeStackCritic: ChopCritic {
    public let id = CriticID.degradeStack
    public let name = "Chain check"
    public let persona = PersonaID.sampler

    /// Bit depths at or above this are the chain's "off" setting.
    public var bitDepthOff: Double { DegradeSettings.bitDepthOff }

    public init() {}

    public var checks: String {
        "A chain whose high cut is above the source's own 95% rolloff, or a second lossy pass over a "
        + "source that has already had one."
    }

    public func review(_ input: ChopReview) -> [Finding] {
        guard let degrade = input.degrade, !degrade.isBypass else { return [] }
        var findings: [Finding] = []
        let observation = input.observation
        let presetName = degrade.presetIgnoringMix.map { Dust.machineName($0.rawValue) } ?? "the chain"
        let locus = Locus(start: 0, end: observation.duration)

        if let bandwidth = observation.bandwidthHz, degrade.highCut > 0, bandwidth <= degrade.highCut {
            findings.append(Finding(
                critic: id, criticName: name, persona: persona,
                subject: .source,
                locus: locus,
                headline: String(format: "%@'s corner is at %.0f Hz; the source stops at %.0f Hz",
                                 presetName, degrade.highCut, bandwidth),
                why: "There is nothing above the corner left to remove, so the only thing this chain "
                   + "still adds is its own noise bed over a source that was already dark.",
                severity: .note,
                measurement: Measurement(.bandwidthHz, measured: bandwidth,
                                         threshold: .atLeast(.bandwidthHz, degrade.highCut, unit: "Hz"),
                                         unit: "Hz"),
                first: Fix("chain-off",
                           title: "Take the chain off",
                           detail: "The source keeps the character it arrived with. Costs the noise bed, "
                                 + "which is the only thing the chain was still contributing.",
                           change: .setDegradePreset(nil)),
                second: Fix("noise-only",
                            title: "Keep it at a third",
                            detail: "Enough hiss and crackle to sit the chop in a room, without the "
                                  + "second bandwidth limit. Use when the bed is the point.",
                            change: .setDegradeMix(0.33))))
        }

        if !observation.priorDegrades.isEmpty, degrade.bitDepth < bitDepthOff {
            let prior = observation.priorDegrades.map(Dust.machineName).joined(separator: ", ")
            findings.append(Finding(
                critic: id, criticName: name, persona: persona,
                subject: .source,
                locus: locus,
                headline: String(format: "Second quantiser: %@ over %@", presetName, prior),
                why: "The source is already on a \(Int(degrade.bitDepth.rounded()))-bit lattice from \(prior), "
                   + "so this pass adds quantisation error without adding the artifact you wanted.",
                severity: .warn,
                measurement: Measurement(.bitDepth, measured: degrade.bitDepth,
                                         threshold: .atLeast(.bitDepth, bitDepthOff, unit: "bits"),
                                         unit: "bits"),
                first: Fix("bits-off",
                           title: "Turn the quantiser off and keep the rest",
                           detail: "The saturation, the wow and the noise still apply; the second "
                                 + "lattice does not. This is the fix nine times out of ten.",
                           change: .setDegradePreset(DegradeSettings.Preset.cassette.rawValue)),
                second: Fix("chain-off-stack",
                            title: "Take the second chain off entirely",
                            detail: "The source already went through \(prior). One machine's sound is a "
                                  + "sound; two is mud.",
                            change: .setDegradePreset(nil))))
        }

        return findings
    }
}
