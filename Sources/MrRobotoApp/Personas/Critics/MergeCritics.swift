import Foundation
import Performance
import SongGraph

// The two checks the Sampler runs over a merge before it is stitched: a sample moved too far, and
// two records' drums in one section. Pure functions of a `MergeReview`, like every critic here.

/// Everything a merge critic is handed.
public struct MergeReview: Sendable {
    public struct Fragment: Sendable {
        public var label: String
        /// Signed semitones the plan moves it; 0 for a written part left alone or a groove.
        public var semitones: Int
        public var isSample: Bool
        public var isDrums: Bool
        /// The record it came from, when known, and whether that record is cleared.
        public var source: String?
        public var uncleared: Bool

        public init(label: String, semitones: Int, isSample: Bool, isDrums: Bool,
                    source: String? = nil, uncleared: Bool = false) {
            self.label = label
            self.semitones = semitones
            self.isSample = isSample
            self.isDrums = isDrums
            self.source = source
            self.uncleared = uncleared
        }
    }

    public var label: String
    public var fragments: [Fragment]
    /// The section's length in seconds, for the locus.
    public var seconds: Double

    public init(label: String, fragments: [Fragment], seconds: Double = 0) {
        self.label = label
        self.fragments = fragments
        self.seconds = seconds
    }

    /// How many fragments carry drums.
    public var drumSources: Int { fragments.filter(\.isDrums).count }
    /// The uncleared sources, named once each.
    public var uncleared: [String] {
        var seen = Set<String>()
        return fragments.compactMap { $0.uncleared ? $0.source : nil }.filter { seen.insert($0).inserted }
    }

    /// The review of a plan over two versions, as the merge tool and the surface build it.
    public static func of(_ plan: MergePlan, a: PartVersion, b: PartVersion, aFragment: MergeFragment,
                          bFragment: MergeFragment, sources: (PartVersion) -> (name: String?, uncleared: Bool),
                          seconds: Double) -> MergeReview {
        func fragment(_ version: PartVersion, _ fragment: MergeFragment, _ move: MergeMove) -> Fragment {
            let source = sources(version)
            return Fragment(label: fragment.label, semitones: move.semitones, isSample: fragment.kind == .sample,
                            isDrums: fragment.isDrums, source: source.name, uncleared: source.uncleared)
        }
        return MergeReview(label: "\(aFragment.label) + \(bFragment.label)",
                           fragments: [fragment(a, aFragment, plan.a), fragment(b, bFragment, plan.b)], seconds: seconds)
    }
}

public protocol MergeCritic: Critic {
    func review(_ input: MergeReview) -> [Finding]
}

// MARK: - A sample moved too far

/// Fires on a sample moved more than four semitones (the Sampler's `sampler.past-four-semitones`).
public struct TooFarTransposedCritic: MergeCritic {
    public let id = CriticID.tooFarTransposed
    public let name = "Transposition check"
    public let persona = PersonaID.sampler
    public var limit: Double

    public init(limit: Double = Sampler.transposeFlagSemitones) { self.limit = limit }

    public var checks: String {
        "A sample moved more than \(Int(limit)) semitones from the key it was cut in — the timbre gives it away."
    }

    public func review(_ input: MergeReview) -> [Finding] {
        input.fragments.compactMap { fragment in
            guard fragment.isSample, Double(abs(fragment.semitones)) > limit else { return nil }
            let other = input.fragments.first { $0.label != fragment.label }
            let direction = fragment.semitones > 0 ? "up" : "down"
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .source,
                locus: Locus(start: 0, end: input.seconds),
                headline: "\(fragment.label) moves \(abs(fragment.semitones)) semitones \(direction)",
                why: "Past \(Int(limit)) the formants are held but the body of the sound sits \(abs(fragment.semitones)) "
                    + "semitones from where it was recorded, and it stops passing as the same record.",
                severity: abs(fragment.semitones) > Sampler.transposeCeilingSemitones ? .warn : .note,
                measurement: Measurement(.transposeSemitones, measured: Double(abs(fragment.semitones)),
                                         threshold: .atMost(.transposeSemitones, limit, unit: "semitones"), unit: "semitones"),
                first: Fix("keep-the-sample", title: "Take \(fragment.label)'s own key",
                           detail: "Leave the sample where it was cut and move \(other?.label ?? "the other part") instead"
                               + (other?.isSample == false ? " — by arithmetic, which costs nothing." : "."),
                           change: .setTranspose(label: fragment.label, semitones: 0)),
                second: Fix("accept-the-shift", title: "Keep the shift",
                            detail: "Listen first: at \(abs(fragment.semitones)) semitones it may be the sound you want.",
                            change: .accept))
        }
    }
}

// MARK: - Two records' drums in one section

/// Fires when more than one fragment in a section carries drums (`sampler.one-drum-source`).
public struct TwoDrumSourcesCritic: MergeCritic {
    public let id = CriticID.twoDrumSources
    public let name = "Drums check"
    public let persona = PersonaID.sampler

    public init() {}

    public var checks: String { "Two fragments with drums in one section — two rooms, two kits, two pockets." }

    public func review(_ input: MergeReview) -> [Finding] {
        let drums = input.fragments.filter(\.isDrums)
        guard drums.count > 1 else { return [] }
        return [Finding(
            critic: id, criticName: name, persona: persona,
            subject: .source,
            locus: Locus(start: 0, end: input.seconds),
            headline: "\(drums.map(\.label).joined(separator: " and ")) both carry drums",
            why: "Two breaks in one bar is two rooms and two pockets, and nobody hears either. One record's drums, "
                + "the other's harmony.",
            measurement: Measurement(.drumSources, measured: Double(drums.count),
                                     threshold: .atMost(.drumSources, 1, unit: "sources"), unit: "sources"),
            first: Fix("drop-second-drums", title: "Drop \(drums[1].label)",
                       detail: "Keep \(drums[0].label)'s drums; if \(drums[1].label) matters, it is another section.",
                       change: .dropFragment(drums[1].label)),
            second: Fix("drop-first-drums", title: "Drop \(drums[0].label)",
                        detail: "Keep \(drums[1].label)'s drums instead.",
                        change: .dropFragment(drums[0].label)))]
    }
}
