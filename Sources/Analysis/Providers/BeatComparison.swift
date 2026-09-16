import MusicTheory
import Foundation

/// Agreement between two beat lists, in the standard MIREX terms: F-measure at a tolerance,
/// downbeat agreement, and the timing offset of the matched beats. Used to score a provider
/// against a golden (Beat This! output) or against another provider.
public struct BeatComparison: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Matching tolerance in seconds.
    public var tolerance: Double
    public var estimateCount: Int
    public var referenceCount: Int
    /// Estimated beats matched one-to-one to a reference beat within the tolerance.
    public var matched: Int
    public var precision: Double
    public var recall: Double
    public var fMeasure: Double
    /// Mean of (estimate − reference) over matched pairs, seconds. Positive means the estimate is late.
    public var meanOffset: Double
    /// Median of (estimate − reference) over matched pairs, seconds.
    public var medianOffset: Double
    /// Mean absolute offset over matched pairs, seconds.
    public var meanAbsoluteOffset: Double
    /// The same F-measure computed on downbeats, when both sides have them.
    public var downbeatFMeasure: Double?
    /// Fraction of matched estimate beats whose downbeat-ness agrees with the reference beat's, when both sides have downbeats.
    public var downbeatAgreement: Double?

    public var description: String {
        var text = String(format: "F=%.3f (P=%.3f R=%.3f, %d/%d matched @ %.0f ms), offset mean %+.1f ms median %+.1f ms",
                          fMeasure, precision, recall, matched, referenceCount, tolerance * 1000, meanOffset * 1000, medianOffset * 1000)
        if let downbeatFMeasure { text += String(format: ", downbeat F=%.3f", downbeatFMeasure) }
        if let downbeatAgreement { text += String(format: " agreement %.3f", downbeatAgreement) }
        return text
    }

    // MARK: Golden data

    /// The shape of `Bench/goldens/<track>/beats.json`.
    public struct Golden: Hashable, Codable, Sendable {
        public var beats: [Double]
        public var downbeats: [Double]

        public init(beats: [Double], downbeats: [Double] = []) {
            self.beats = beats
            self.downbeats = downbeats
        }

        public init(contentsOf url: URL) throws {
            self = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        }

        public var asTrackingResult: BeatTrackingResult { BeatTrackingResult(beats: beats, downbeats: downbeats) }
    }

    // MARK: Comparison

    /// Compares plain beat lists. Downbeat figures are nil.
    public static func compare(estimate: [Double], reference: [Double], tolerance: Double = 0.07) -> BeatComparison {
        compare(estimate: BeatTrackingResult(beats: estimate, downbeats: []), reference: BeatTrackingResult(beats: reference, downbeats: []), tolerance: tolerance)
    }

    /// Compares a tracking result against a golden file.
    public static func compare(estimate: BeatTrackingResult, golden: Golden, tolerance: Double = 0.07) -> BeatComparison {
        compare(estimate: estimate, reference: golden.asTrackingResult, tolerance: tolerance)
    }

    /// Compares two tracking results: beats one-to-one within `tolerance`, plus downbeat figures
    /// when both sides list downbeats.
    public static func compare(estimate: BeatTrackingResult, reference: BeatTrackingResult, tolerance: Double = 0.07) -> BeatComparison {
        let estimateBeats = estimate.beats.sorted()
        let referenceBeats = reference.beats.sorted()
        let pairs = match(estimateBeats, referenceBeats, tolerance: tolerance)
        let offsets = pairs.map { estimateBeats[$0.estimate] - referenceBeats[$0.reference] }
        let (precision, recall, f) = prf(matched: pairs.count, estimates: estimateBeats.count, references: referenceBeats.count)

        var comparison = BeatComparison(
            tolerance: tolerance, estimateCount: estimateBeats.count, referenceCount: referenceBeats.count, matched: pairs.count,
            precision: precision, recall: recall, fMeasure: f,
            meanOffset: mean(offsets), medianOffset: median(offsets), meanAbsoluteOffset: mean(offsets.map(abs)))

        if !estimate.downbeats.isEmpty, !reference.downbeats.isEmpty {
            let estimateDown = estimate.downbeats.sorted()
            let referenceDown = reference.downbeats.sorted()
            let downPairs = match(estimateDown, referenceDown, tolerance: tolerance)
            comparison.downbeatFMeasure = prf(matched: downPairs.count, estimates: estimateDown.count, references: referenceDown.count).f
            if !pairs.isEmpty {
                let estimateIsDown = Set(pairs.map(\.estimate).filter { isDownbeat(estimateBeats[$0], in: estimateDown, tolerance: tolerance) })
                let referenceIsDown = Set(pairs.map(\.reference).filter { isDownbeat(referenceBeats[$0], in: referenceDown, tolerance: tolerance) })
                let agreeing = pairs.filter { estimateIsDown.contains($0.estimate) == referenceIsDown.contains($0.reference) }.count
                comparison.downbeatAgreement = Double(agreeing) / Double(pairs.count)
            }
        }
        return comparison
    }

    // MARK: Helpers

    /// Greedy one-to-one matching of two ascending lists: walk both, pair when within tolerance,
    /// otherwise advance whichever is earlier. Optimal for well-separated beat lists.
    static func match(_ estimate: [Double], _ reference: [Double], tolerance: Double) -> [(estimate: Int, reference: Int)] {
        var pairs: [(estimate: Int, reference: Int)] = []
        var i = 0, j = 0
        while i < estimate.count, j < reference.count {
            let delta = estimate[i] - reference[j]
            if abs(delta) <= tolerance {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if delta < 0 {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func prf(matched: Int, estimates: Int, references: Int) -> (precision: Double, recall: Double, f: Double) {
        let precision = estimates > 0 ? Double(matched) / Double(estimates) : 0
        let recall = references > 0 ? Double(matched) / Double(references) : 0
        let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return (precision, recall, f)
    }

    static func isDownbeat(_ time: Double, in downbeats: [Double], tolerance: Double) -> Bool {
        guard let nearest = BeatGrid.nearestIndex(in: downbeats, to: time) else { return false }
        return abs(downbeats[nearest] - time) <= tolerance
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
