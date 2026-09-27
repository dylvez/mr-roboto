import Foundation

/// A second beat tracker's word on the first one's grid.
///
/// The beat grid is what every bar, chop and groove stands on, and it came from one tracker. When
/// that tracker found none, the record arrived with no bars at all; when it found the wrong one — a
/// song heard in double time is the common case — nothing said so. A second tracker, run alongside,
/// covers both: it stands in when the first finds nothing, and otherwise says how far the two agree.
public struct BeatCheck: Hashable, Codable, Sendable {
    /// The tracker that checked the grid, or stood in for it.
    public var checker: String
    /// The beat F-measure between the two grids at `tolerance`, when both had one. Nil when the
    /// checker stood in.
    public var agreement: Double?
    /// Each tracker's tempo, from its own figure or its beats' median spacing.
    public var primaryBPM: Double?
    public var checkerBPM: Double?
    /// Whether the report's grid is the checker's, because the first tracker had none to give.
    public var usedChecker: Bool

    /// Two beats within 70 ms are the same beat: the MIREX convention.
    public static let tolerance = 0.07
    /// Below this the two trackers are said to disagree.
    public static let agreeing = 0.8
    /// Fewer beats than this is not a grid a bar can be read from.
    public static let minimumBeats = 4

    public init(checker: String, agreement: Double?, primaryBPM: Double?, checkerBPM: Double?, usedChecker: Bool) {
        self.checker = checker
        self.agreement = agreement
        self.primaryBPM = primaryBPM
        self.checkerBPM = checkerBPM
        self.usedChecker = usedChecker
    }

    public var agrees: Bool { usedChecker || (agreement ?? 0) >= Self.agreeing }

    /// Whether one tracker hears the song at twice the other's tempo, within 4%.
    public var isOctaveApart: Bool {
        guard let a = primaryBPM, let b = checkerBPM, a > 0, b > 0 else { return false }
        let ratio = max(a, b) / min(a, b)
        return abs(ratio - 2) < 0.08
    }

    /// The grid to keep, and what checking it found. The first tracker's grid is kept whenever it
    /// has one; the checker's is used only in its place.
    public static func reconcile(primary: BeatTrackingResult?, checker: String,
                                 checked: BeatTrackingResult?) -> (beats: BeatTrackingResult?, check: BeatCheck?) {
        func usable(_ result: BeatTrackingResult?) -> BeatTrackingResult? {
            guard let result, result.beats.count >= minimumBeats else { return nil }
            return result
        }
        switch (usable(primary), usable(checked)) {
        case let (first?, second?):
            let f = BeatComparison.compare(estimate: first, reference: second, tolerance: tolerance).fMeasure
            return (first, BeatCheck(checker: checker, agreement: f, primaryBPM: bpm(of: first),
                                     checkerBPM: bpm(of: second), usedChecker: false))
        case let (nil, second?):
            return (second, BeatCheck(checker: checker, agreement: nil, primaryBPM: nil,
                                      checkerBPM: bpm(of: second), usedChecker: true))
        default:
            return (primary, nil)
        }
    }

    /// A tracker's own tempo, else 60 over the median spacing of its beats.
    public static func bpm(of result: BeatTrackingResult) -> Double? {
        if let bpm = result.bpm, bpm > 0 { return bpm }
        let beats = result.beats.sorted()
        guard beats.count >= 2 else { return nil }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        return median > 0 ? 60 / median : nil
    }
}
