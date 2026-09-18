import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The two checks the Beatmaker runs over a groove before anybody hears it.

// MARK: - Measuring the swing a source already has

/// The swing in a piece of audio, read off its own onsets against its own grid.
///
/// The arithmetic is `Swing`'s, run backwards. Linn's swing delays the second sixteenth of each
/// eighth-note pair and leaves the first alone, and the percentage *is* the share of the eighth the
/// first sixteenth gets. So an onset landing at fraction `f` of the way through its eighth-note pair
/// reports a swing of `100·f` directly, with no conversion in between: 0.50 is straight, 0.667 is a
/// triplet, 0.75 is the machines' maximum.
///
/// The median rather than the mean, because one onset the detector put in the wrong place should not
/// move the answer, and a real break's odd sixteenths are not all displaced by the same amount.
///
/// This is the measurement that makes "a re-groove that fights the source's own swing" checkable
/// rather than a matter of ear. Frane measured thirty canonical breaks this way — Pro Tools, onsets
/// marked by hand, hi-hat given precedence as the timekeeper — and found a median ratio of 1.2:1
/// (54.5% in this scale), a mean of 1.3:1 (56.5%), a range of 1.0–2.1:1, and, notably, **no
/// correlation with tempo**, which is why nothing here scales the estimate by BPM.
///
/// Sources: A. Frane, "Swing Rhythm in Classic Drum Breaks From Hip-Hop's Breakbeat Canon",
/// *Music Perception* 34(3), 2017, 291–302,
/// <https://shamslab.psych.ucla.edu/wp-content/uploads/sites/57/2017/01/Frane_SwingInBreakbeats_2017.pdf>;
/// Roger Linn on the mechanism, <https://brettworks.com/2013/07/23/roger-linn-on-drum-machine-groove-and-j-dillas-off-beat-sound/>.
public enum SourceSwing {

    /// Below this many usable onsets the estimate is not reported. Six is two bars of eighth-note
    /// upbeats in 4/4 — the least that can produce a median worth the name.
    public static let minimumOnsets = 6

    /// An onset is treated as an odd-sixteenth candidate when it lands this far into its eighth
    /// pair. The window is deliberately wider than the machines' own 50–75% range so an onset
    /// outside it is excluded as "not the swung note" rather than clamped into the answer.
    public static let candidateWindow: ClosedRange<Double> = 0.35...0.90

    public struct Estimate: Hashable, Sendable {
        /// MPC percent, clamped to the machines' 50…75.
        public var percent: Double
        /// How many onsets the median rests on.
        public var support: Int
        /// True when there were enough onsets to believe it.
        public var isUsable: Bool { support >= SourceSwing.minimumOnsets }
    }

    /// Estimate the swing in `onsets` (seconds, in the grid's own time) against `grid`.
    public static func estimate(onsets: [Double], grid: BeatGrid) -> Estimate {
        guard grid.beats.count >= 2 else { return Estimate(percent: 50, support: 0) }
        var candidates: [Double] = []
        for onset in onsets {
            guard let index = grid.beatIndex(at: onset), index + 1 < grid.beats.count else { continue }
            let beatStart = grid.beats[index]
            let beatLength = grid.beats[index + 1] - beatStart
            guard beatLength > 0 else { continue }
            // Position within the beat, then within the eighth-note pair that contains it.
            let inBeat = (onset - beatStart) / beatLength
            guard inBeat >= 0, inBeat < 1 else { continue }
            let pair = inBeat < 0.5 ? 0.0 : 0.5
            let inPair = (inBeat - pair) / 0.5
            guard candidateWindow.contains(inPair) else { continue }
            candidates.append(inPair * 100)
        }
        guard !candidates.isEmpty else { return Estimate(percent: 50, support: 0) }
        candidates.sort()
        let median = candidates.count % 2 == 1
            ? candidates[candidates.count / 2]
            : (candidates[candidates.count / 2 - 1] + candidates[candidates.count / 2]) / 2
        return Estimate(percent: min(Swing.maximumPercent, max(Swing.minimumPercent, median)),
                        support: candidates.count)
    }

    /// How far a swing percentage actually moves the second sixteenth, in milliseconds, at a tempo.
    ///
    /// `(percent − 50)/100 × one eighth note`, and one eighth note is `30/BPM` seconds. This is the
    /// conversion that lets a swing difference be compared against a perceptual threshold in
    /// milliseconds instead of against a threshold in percent, which would mean something different
    /// at every tempo.
    public static func displacementMS(percent: Double, tempo: Double) -> Double {
        guard tempo > 0 else { return 0 }
        return (percent - 50) / 100 * (30 / tempo) * 1000
    }
}

// MARK: - A re-groove that fights the source's own swing

/// Does the groove's swing agree with the swing already in the audio?
///
/// The failure has two shapes and they sound different. **Swinging a swung source** delays a note
/// that was already late, so the backbeat arrives twice: once where the sample put it and once
/// where the grid wanted it. **Straightening a swung source** is the quieter mistake — the grid
/// pulls the slices onto lines they were never played on, and the break stops being a performance.
///
/// ## The threshold is 10 ms, and it is measured
///
/// Not a swing-percentage difference, which would mean a different amount of time at every tempo,
/// but the actual displacement each swing setting produces. Frane takes **10 ms as the perceptual
/// detection threshold** for swing displacement and classifies ratios below 1.1:1 as effectively
/// straight on that basis. So the rule is: convert both swings to milliseconds at the groove's own
/// tempo, and fire when they disagree by more than 10 ms.
///
/// At 90 BPM one eighth note is 333 ms, so 10 ms is three percentage points of swing; at 140 BPM it
/// is nearly five. A trap groove therefore gets more latitude than a boom-bap one for the same
/// percentage figure, which is correct and is the thing a percentage threshold would have got wrong.
///
/// Source: A. Frane, *Music Perception* 34(3), 2017,
/// <https://shamslab.psych.ucla.edu/wp-content/uploads/sites/57/2017/01/Frane_SwingInBreakbeats_2017.pdf>.
public struct SwingClashCritic: GrooveCritic {
    public let id = CriticID.swingClash
    public let name = "Swing check"
    public let persona = PersonaID.beatmaker

    /// The perceptual detection threshold for a swing displacement, in milliseconds.
    public var thresholdMS: Double

    public init(thresholdMS: Double = 10) {
        self.thresholdMS = thresholdMS
    }

    public var checks: String {
        String(format: "A groove whose swing displaces the offbeats more than %.0f ms away from where "
                     + "the source already put them.", thresholdMS)
    }

    public func review(_ input: GrooveReview) -> [Finding] {
        guard let source = input.sourceSwingPercent,
              input.sourceSwingSupport >= SourceSwing.minimumOnsets else { return [] }
        let observation = input.observation
        let tempo = observation.tempo
        guard tempo > 0 else { return [] }

        let targetMS = SourceSwing.displacementMS(percent: observation.swingPercent, tempo: tempo)
        let sourceMS = SourceSwing.displacementMS(percent: source, tempo: tempo)
        let gap = targetMS - sourceMS
        guard abs(gap) > thresholdMS else { return [] }

        let adding = gap > 0
        let headline = adding
            ? String(format: "The groove swings %.1f ms further than the source already does", gap)
            : String(format: "The groove straightens the source by %.1f ms", -gap)
        let why = adding
            ? "The offbeats were already late in the audio, so the swing lever moves them again and the "
            + "backbeat arrives twice."
            : "The slices were played off the grid, and pulling them onto it takes out the timing the "
            + "break was chosen for."

        let secondFix: Fix = adding
            ? Fix("go-straight",
                  title: "Set the groove straight and let the slices swing it",
                  detail: "The source's own displacement is the only swing, which is how a chopped break "
                        + "keeps its feel. Costs you the swing lever as a control.",
                  change: .setSwing(percent: Swing.minimumPercent))
            : Fix("cut-on-onsets-swing",
                  title: "Re-cut on the transients instead of the grid",
                  detail: "Each slice keeps the time it was played at, so the groove does not have to "
                        + "carry the swing at all. The chop stops lining up with the bar.",
                  change: .setSnapTolerance(0))

        return [Finding(
            critic: id, criticName: name, persona: persona,
            subject: .bar(0),
            locus: Locus(bar: 0, beat: 0, start: 0, end: 60 / tempo * Double(observation.timeSignature.beatsPerBar)),
            headline: headline,
            why: why,
            severity: .warn,
            measurement: Measurement(.swingPercent, measured: targetMS,
                                     threshold: .between(.swingPercent,
                                                         sourceMS - thresholdMS, sourceMS + thresholdMS,
                                                         unit: "ms"),
                                     unit: "ms"),
            first: Fix("match-source",
                       title: String(format: "Match the source at %.1f%%", source),
                       detail: "The groove stops arguing with the audio. Costs nothing except the "
                             + "swing figure you typed.",
                       change: .setSwing(percent: source)),
            second: secondFix)]
    }
}

// MARK: - Slices that clash

/// Two ways a re-groove turns a set of good slices into mud, both read straight off `SlicePlacement`.
///
/// **A slice that overruns its room.** `Regroove` already computes `available` — the seconds until
/// the feel asks for that voice again — and `overruns` for the case where the slice is longer than
/// that. Overrunning is not itself a fault: `.ring` is the default precisely because an MPC lets a
/// pad play through and that thickness is the sound. It becomes a fault at a factor, not at a
/// boundary. Twice the room is the line taken here: at 2× the slice is still sounding when the
/// *next* hit's own step is half over, so the hit that was supposed to define the beat arrives
/// underneath the one before it.
///
/// **Two hits in the flam window.** Two placements within 25 ms of each other, on different voices,
/// whose slices are the same drum to within half an octave of centroid, read as one hit played
/// badly rather than as two hits. Sound on Sound names this failure in the context of sampling —
/// duplicating a percussive transient produces a flam — and 25 ms is the tolerance this project's
/// own `Chopper.snapTolerance` already uses for "close enough to be a timing error".
///
/// Both are capped so a four-bar re-groove cannot produce forty findings: the worst overrun per
/// voice, and the worst flam per bar. A Check surface shows one finding at a time, and a queue of
/// forty identical ones is a queue nobody reads.
///
/// **INFERRED**: the 2× factor and the half-octave centroid window. The 25 ms is the engine's own
/// figure. Sources: <https://www.soundonsound.com/techniques/lost-art-sampling-part-4> (the flam);
/// `Performance.Chopper.snapTolerance` (25 ms).
public struct SliceClashCritic: GrooveCritic {
    public let id = CriticID.sliceClash
    public let name = "Clash check"
    public let persona = PersonaID.beatmaker

    /// A slice longer than this multiple of the room it has is covering the next hit.
    public var overrunFactor: Double
    /// Two hits closer than this read as one flam.
    public var flamWindow: Double
    /// How close two centroids have to be, in octaves, to be the same drum.
    public var sameDrumOctaves: Double

    public init(overrunFactor: Double = 2, flamWindow: Double = 0.025, sameDrumOctaves: Double = 0.5) {
        self.overrunFactor = overrunFactor
        self.flamWindow = flamWindow
        self.sameDrumOctaves = sameDrumOctaves
    }

    public var checks: String {
        String(format: "A slice ringing more than %.0f× past the room the feel gives it, or two hits of "
                     + "the same drum inside %.0f ms.", overrunFactor, flamWindow * 1000)
    }

    public func review(_ input: GrooveReview) -> [Finding] {
        var findings: [Finding] = []
        findings.append(contentsOf: overruns(input))
        findings.append(contentsOf: flams(input))
        return findings
    }

    // MARK: Overruns

    private func overruns(_ input: GrooveReview) -> [Finding] {
        // Worst per voice, so a groove with a long kick sample says so once.
        var worst: [String: PlacedSlice] = [:]
        for placement in input.placements {
            guard placement.available > 0, placement.stretchRatio == nil else { continue }
            let factor = placement.naturalDuration / placement.available
            guard factor > overrunFactor else { continue }
            let key = placement.voice.rawValue
            if let existing = worst[key],
               existing.naturalDuration / max(1e-9, existing.available) >= factor { continue }
            worst[key] = placement
        }

        return worst.values.sorted { ($0.time, $0.voice.rawValue) < ($1.time, $1.voice.rawValue) }.map { placement in
            let factor = placement.naturalDuration / placement.available
            let beat = beatOf(placement, in: input.observation)
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .step(bar: placement.bar, step: placement.step, voice: placement.voice.rawValue),
                locus: Locus(bar: placement.bar, beat: beat,
                             start: placement.time, end: placement.time + placement.naturalDuration),
                headline: String(format: "Slice %d rings %.1f× past the room the %@ gives it",
                                 placement.sliceIndex, factor, placement.voice.rawValue),
                why: String(format: "It is still sounding %.0f ms after the next %@ hits, so the hit that "
                                  + "defines the beat arrives underneath the one before it.",
                            (placement.naturalDuration - placement.available) * 1000,
                            placement.voice.rawValue),
                severity: .warn,
                measurement: Measurement(.sliceDensity, measured: factor,
                                         threshold: .atMost(.sliceDensity, overrunFactor, unit: "×"),
                                         unit: "×"),
                first: Fix("stretch-to-fit",
                           title: "Squeeze the slice into its step",
                           detail: "Time-stretches it to end where the next hit starts. Right when the "
                                 + "target tempo is much slower than the source's; it thins the drum.",
                           change: .setOverlap(Regroove.Overlap.stretchToFit.rawValue)),
                second: Fix("reclassify",
                            title: String(format: "Send slice %d somewhere it has room", placement.sliceIndex),
                            detail: "Re-label it so the rotation puts it on a voice with a longer gap. "
                                  + "Keeps the drum whole and changes what plays the backbeat.",
                            change: .reclassifySlice(slice: placement.sliceIndex, as: SliceClass.kick.rawValue)))
        }
    }

    // MARK: Flams

    private func flams(_ input: GrooveReview) -> [Finding] {
        let sorted = input.placements.sorted { $0.time < $1.time }
        var perBar: [Int: (a: PlacedSlice, b: PlacedSlice, gap: Double)] = [:]

        for i in sorted.indices {
            for j in (i + 1)..<sorted.count {
                let gap = sorted[j].time - sorted[i].time
                if gap > flamWindow { break }
                guard sorted[i].voice != sorted[j].voice else { continue }
                guard sorted[i].sliceIndex != sorted[j].sliceIndex else { continue }
                guard let one = input.sliceCentroid[sorted[i].sliceIndex],
                      let two = input.sliceCentroid[sorted[j].sliceIndex],
                      one > 0, two > 0,
                      abs(log2(one / two)) <= sameDrumOctaves else { continue }
                // Two ghost notes 20 ms apart are a drag, not a mistake.
                guard sorted[i].velocity >= VelocityTier.normal.velocity,
                      sorted[j].velocity >= VelocityTier.normal.velocity else { continue }
                let bar = sorted[i].bar
                if let existing = perBar[bar], existing.gap <= gap { continue }
                perBar[bar] = (sorted[i], sorted[j], gap)
            }
        }

        return perBar.keys.sorted().map { bar in
            let entry = perBar[bar]!
            let beat = beatOf(entry.a, in: input.observation)
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .step(bar: entry.a.bar, step: entry.a.step, voice: entry.a.voice.rawValue),
                locus: Locus(bar: entry.a.bar, beat: beat,
                             start: entry.a.time, end: entry.b.time + 0.1),
                headline: String(format: "Slices %d and %d are %.0f ms apart and the same drum",
                                 entry.a.sliceIndex, entry.b.sliceIndex, entry.gap * 1000),
                why: "Inside the flam window two hits of one drum read as one hit played badly, so the "
                   + "\(entry.b.voice.rawValue) sounds like a mistake on the \(entry.a.voice.rawValue).",
                severity: .warn,
                measurement: Measurement(.pocketSpreadMS, measured: entry.gap * 1000,
                                         threshold: .atLeast(.pocketSpreadMS, flamWindow * 1000, unit: "ms"),
                                         unit: "ms"),
                first: Fix("drop-second",
                           title: String(format: "Take slice %d off that step", entry.b.sliceIndex),
                           detail: "One hit where there were two. Costs the density the second one added.",
                           change: .dropSlice(entry.b.sliceIndex)),
                second: Fix("separate",
                            title: "Pull them apart past the flam window",
                            detail: String(format: "Displace the %@ to %.0f ms so the two read as a "
                                                 + "deliberate drag rather than as one bad hit.",
                                           entry.b.voice.rawValue, flamWindow * 1000 * 1.6),
                            change: .setVoiceLag(voice: entry.b.voice.rawValue,
                                                 milliseconds: flamWindow * 1000 * 1.6)))
        }
    }

    // MARK: Position

    /// Beat within the bar, fractional, from the step index and the groove's subdivision.
    private func beatOf(_ placement: PlacedSlice, in observation: GrooveObservation) -> Double {
        let perBeat = max(1, observation.subdivision)
        return Double(placement.step) / perBeat
    }
}
