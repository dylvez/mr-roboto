import Foundation
import MusicTheory

/// Turns Beat This! framewise logits into beat and downbeat times.
///
/// The first stage is the reference's `Postprocessor(type="minimal")` (`beat_this/model/postprocessor.py`),
/// the `dbn=False` path the goldens were made with: a frame is a peak when its logit is positive
/// (probability > 0.5) and equals the maximum over ±3 frames (±60 ms); runs of adjacent peak frames are
/// merged at their mean index; times are `frame / 50`; each downbeat is moved to the nearest beat and
/// duplicates are dropped.
///
/// The second stage is ours: a tempo-consistency pass that rejects *isolated* beats, those whose
/// intervals to both neighbours deviate from the local median interval by more than `tolerance` while
/// the gap they sit in is itself a whole number of local beat periods, i.e. a spurious insertion the
/// grid does not need. Downbeats that lost their beat go with it. Tempo is the median interval of the
/// surviving beats.
public struct BeatThisPostprocessor: Hashable, Sendable {
    public struct TempoConsistency: Hashable, Sendable {
        /// Maximum relative deviation of an interval from the local median before it is off-tempo.
        public var tolerance: Double
        /// Intervals on each side of a beat that form its local median.
        public var window: Int

        public init(tolerance: Double = 0.25, window: Int = 8) {
            self.tolerance = tolerance
            self.window = window
        }
    }

    public struct Output: Hashable, Sendable {
        public var beats: [Double]
        public var downbeats: [Double]
        /// 60 / median inter-beat interval of `beats`, nil with fewer than two beats.
        public var bpm: Double?
        /// Sigmoid of the beat logit at each beat's frame, one per entry of `beats`.
        public var confidence: [Double]
        /// Beats the tempo-consistency pass removed.
        public var rejectedBeats: [Double]
    }

    public var framesPerSecond: Double
    /// nil disables the tempo-consistency pass.
    public var tempoConsistency: TempoConsistency?

    public init(framesPerSecond: Double = 50, tempoConsistency: TempoConsistency? = TempoConsistency()) {
        self.framesPerSecond = framesPerSecond
        self.tempoConsistency = tempoConsistency
    }

    public func process(beatLogits: [Float], downbeatLogits: [Float]) -> Output {
        let beatFrames = Self.deduplicate(Self.peakFrames(beatLogits))
        let downbeatFrames = Self.deduplicate(Self.peakFrames(downbeatLogits))
        var beats = beatFrames.map { $0 / framesPerSecond }
        var downbeats = Self.snap(downbeatFrames.map { $0 / framesPerSecond }, to: beats)

        var rejected: [Double] = []
        if let tempoConsistency {
            (beats, rejected) = Self.rejectIsolated(beats, tolerance: tempoConsistency.tolerance, window: tempoConsistency.window)
            if !rejected.isEmpty {
                let kept = Set(beats)
                downbeats = downbeats.filter { kept.contains($0) }
            }
        }

        let confidence = beats.map { time -> Double in
            let frame = min(max(Int((time * framesPerSecond).rounded()), 0), beatLogits.count - 1)
            return beatLogits.isEmpty ? 0 : 1 / (1 + exp(-Double(beatLogits[frame])))
        }
        return Output(beats: beats, downbeats: downbeats, bpm: BeatGrid.medianTempo(of: beats),
                      confidence: confidence, rejectedBeats: rejected)
    }

    // MARK: Reference stages

    /// Frames whose logit is positive and equal to the maximum over `[t - 3, t + 3]` (the reference's
    /// `max_pool1d(kernel 7, stride 1, padding 3)` comparison; outside the series counts as -inf).
    static func peakFrames(_ logits: [Float]) -> [Int] {
        var peaks: [Int] = []
        for t in logits.indices where logits[t] > 0 {
            let lo = max(0, t - 3), hi = min(logits.count - 1, t + 3)
            if logits[t] == logits[lo...hi].max() { peaks.append(t) }
        }
        return peaks
    }

    /// Replaces each run of peak frames no more than `width` apart by the mean of the run's indices
    /// (`deduplicate_peaks`), so two equal adjacent maxima become one half-frame peak.
    static func deduplicate(_ peaks: [Int], width: Int = 1) -> [Double] {
        var result: [Double] = []
        var iterator = peaks.makeIterator()
        guard var p = iterator.next().map(Double.init) else { return result }
        var count = 1.0
        while let next = iterator.next() {
            let p2 = Double(next)
            if p2 - p <= Double(width) {
                count += 1
                p += (p2 - p) / count
            } else {
                result.append(p)
                p = p2
                count = 1
            }
        }
        result.append(p)
        return result
    }

    /// Moves each downbeat to the nearest beat (first on ties, as `np.argmin`) and drops duplicates,
    /// keeping the result sorted (`np.unique`). Downbeats are left alone when there are no beats.
    static func snap(_ downbeats: [Double], to beats: [Double]) -> [Double] {
        guard !beats.isEmpty else { return downbeats }
        var seen = Set<Double>()
        var out: [Double] = []
        for downbeat in downbeats {
            var best = 0
            var bestDistance = Double.infinity
            for (i, beat) in beats.enumerated() where abs(beat - downbeat) < bestDistance {
                best = i
                bestDistance = abs(beat - downbeat)
            }
            if seen.insert(beats[best]).inserted { out.append(beats[best]) }
        }
        return out.sorted()
    }

    // MARK: Tempo consistency

    /// One pass over the beats, judged against the original series (rejections do not cascade).
    static func rejectIsolated(_ beats: [Double], tolerance: Double, window: Int) -> (kept: [Double], rejected: [Double]) {
        guard beats.count >= 4 else { return (beats, []) }
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        var rejected: [Double] = []
        var kept: [Double] = [beats[0]]
        kept.reserveCapacity(beats.count)
        for i in 1..<(beats.count - 1) {
            let previous = intervals[i - 1], next = intervals[i]
            let neighbourhood = Array(intervals[max(0, i - window)..<min(intervals.count, i + window)])
            guard let median = BeatGrid.medianInterval(of: cumulative(neighbourhood)), median > 0 else {
                kept.append(beats[i])
                continue
            }
            let previousOff = abs(previous - median) / median > tolerance
            let nextOff = abs(next - median) / median > tolerance
            let gap = previous + next
            let periods = (gap / median).rounded()
            let gapFits = periods >= 1 && abs(gap - periods * median) / median <= tolerance
            if previousOff && nextOff && gapFits {
                rejected.append(beats[i])
            } else {
                kept.append(beats[i])
            }
        }
        kept.append(beats[beats.count - 1])
        return (kept, rejected)
    }

    /// Times whose consecutive differences are `intervals`, for `BeatGrid.medianInterval`.
    private static func cumulative(_ intervals: [Double]) -> [Double] {
        var times = [0.0]
        for interval in intervals { times.append(times[times.count - 1] + interval) }
        return times
    }
}
