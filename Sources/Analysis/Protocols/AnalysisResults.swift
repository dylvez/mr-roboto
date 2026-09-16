import Foundation
import MusicTheory

// Plain-value result types shared by every analysis provider. All times are seconds from the
// start of the audio; all musical values use MusicTheory types. Everything here is Codable so a
// Song's analysis part can be persisted, diffed and replayed without the provider that made it.

/// A half-open time span `[start, end)` in seconds.
public struct TimeRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public init(_ start: Double, _ end: Double) {
        self.init(start: start, end: end)
    }

    public var duration: Double { end - start }
    public var midpoint: Double { (start + end) / 2 }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public var description: String { String(format: "%.3f–%.3f", start, end) }
}

/// A value sampled at a point in time (a loudness reading, an activity level …).
public struct TimedSample: Hashable, Codable, Sendable {
    public var time: Double
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// A value that holds over a time range (a pace estimate, a key …).
public struct RangedSample: Hashable, Codable, Sendable {
    public var range: TimeRange
    public var value: Double

    public init(range: TimeRange, value: Double) {
        self.range = range
        self.value = value
    }
}

// MARK: - Key

/// One key holding over a span of the track.
public struct KeyRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: Double
    public var end: Double
    public var key: Key
    /// 0…1 when the estimator reports one; nil when it does not (Music Understanding does not).
    public var confidence: Double?

    public init(start: Double, end: Double, key: Key, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.key = key
        self.confidence = confidence
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }
    public var duration: Double { end - start }

    public var description: String { "\(key.name) \(range)" }
}

/// The key estimate for a whole track: one or more key ranges in time order.
public struct KeyEstimate: Hashable, Codable, Sendable {
    public var ranges: [KeyRange]

    public init(ranges: [KeyRange]) {
        self.ranges = ranges.sorted { $0.start < $1.start }
    }

    /// A single-key estimate covering `duration` seconds.
    public init(key: Key, duration: Double, confidence: Double? = nil) {
        self.init(ranges: [KeyRange(start: 0, end: duration, key: key, confidence: confidence)])
    }

    /// The key that holds for the longest total time, or nil when there are no ranges.
    public var dominantKey: Key? {
        var totals: [Key: Double] = [:]
        for range in ranges { totals[range.key, default: 0] += range.duration }
        return totals.max { a, b in a.value < b.value || (a.value == b.value && a.key.name > b.key.name) }?.key
    }

    /// The key holding at `time`, or nil outside every range.
    public func key(at time: Double) -> Key? {
        ranges.first { $0.range.contains(time) }?.key
    }

    /// True when the track is analysed as a single key throughout.
    public var isStable: Bool { Set(ranges.map(\.key)).count <= 1 }
}

// MARK: - Beats

/// Beat and downbeat times with an optional tempo and per-beat confidence.
public struct BeatTrackingResult: Hashable, Codable, Sendable {
    /// Beat onset times in seconds, ascending.
    public var beats: [Double]
    /// Bar (downbeat) start times in seconds, ascending. Normally a subset of `beats`.
    public var downbeats: [Double]
    /// Global tempo in beats per minute, when the tracker reports one.
    public var bpm: Double?
    /// One 0…1 value per entry of `beats`, when the tracker reports them.
    public var confidence: [Double]?

    public init(beats: [Double], downbeats: [Double], bpm: Double? = nil, confidence: [Double]? = nil) {
        self.beats = beats
        self.downbeats = downbeats
        self.bpm = bpm
        self.confidence = confidence
    }

    /// The same data as a queryable grid.
    public var grid: BeatGrid { BeatGrid(beats: beats, bars: downbeats, bpm: bpm) }
}

// MARK: - Structure

/// Musical form at three granularities, each a list of time ranges in order.
public struct StructureAnalysis: Hashable, Codable, Sendable {
    /// Large-scale parts (intro, verse, chorus …), unlabeled.
    public var sections: [TimeRange]
    /// Finer subdivisions of sections.
    public var segments: [TimeRange]
    /// Phrase-level ranges, typically a few bars each.
    public var phrases: [TimeRange]

    public init(sections: [TimeRange], segments: [TimeRange] = [], phrases: [TimeRange] = []) {
        self.sections = sections
        self.segments = segments
        self.phrases = phrases
    }

    /// Index of the section containing `time`, or nil.
    public func sectionIndex(at time: Double) -> Int? {
        sections.firstIndex { $0.contains(time) }
    }
}

// MARK: - Loudness

/// EBU R 128 style loudness: integrated and peak for the whole track plus the two rolling series.
public struct LoudnessAnalysis: Hashable, Codable, Sendable {
    /// Integrated loudness of the whole track in LUFS.
    public var integrated: Double
    /// Peak level in dB (true peak where the meter measures it).
    public var truePeak: Double
    /// Momentary (400 ms window) loudness series in LUFS.
    public var momentary: [TimedSample]
    /// Short-term (3 s window) loudness series in LUFS.
    public var shortTerm: [TimedSample]

    public init(integrated: Double, truePeak: Double, momentary: [TimedSample] = [], shortTerm: [TimedSample] = []) {
        self.integrated = integrated
        self.truePeak = truePeak
        self.momentary = momentary
        self.shortTerm = shortTerm
    }

    /// Loudness range: the spread between the 10th and 95th percentile of short-term values, in LU.
    public var range: Double? {
        let values = shortTerm.map(\.value).filter { $0.isFinite }.sorted()
        guard values.count >= 2 else { return nil }
        func percentile(_ p: Double) -> Double { values[Int((Double(values.count - 1) * p).rounded())] }
        return percentile(0.95) - percentile(0.10)
    }
}

// MARK: - Instruments

/// The instrument groups analysers distinguish (the four-stem convention).
public enum Instrument: String, CaseIterable, Hashable, Codable, CodingKeyRepresentable, Sendable, CustomStringConvertible {
    case vocal, drums, bass, other

    public var description: String { rawValue }
}

/// Where each instrument is present and how strongly, over time.
public struct InstrumentActivity: Hashable, Codable, Sendable {
    /// Time ranges in which the instrument is judged present.
    public var presence: [Instrument: [TimeRange]]
    /// Activity level (0…1) sampled over time.
    public var activity: [Instrument: [TimedSample]]

    public init(presence: [Instrument: [TimeRange]], activity: [Instrument: [TimedSample]] = [:]) {
        self.presence = presence
        self.activity = activity
    }

    /// Instruments with at least one presence range.
    public var instruments: [Instrument] {
        Instrument.allCases.filter { !(presence[$0] ?? []).isEmpty }
    }

    /// True when `instrument` is present at `time`.
    public func isPresent(_ instrument: Instrument, at time: Double) -> Bool {
        (presence[instrument] ?? []).contains { $0.contains(time) }
    }

    /// Seconds during which `instrument` is present.
    public func presentDuration(of instrument: Instrument) -> Double {
        (presence[instrument] ?? []).reduce(0) { $0 + $1.duration }
    }
}

// MARK: - Onsets

/// Note onset times, optionally with the novelty curve they were picked from.
public struct OnsetResult: Hashable, Codable, Sendable {
    /// Onset times in seconds, ascending.
    public var onsets: [Double]
    /// The onset-strength (novelty) function, when the detector exposes it.
    public var strength: [TimedSample]?

    public init(onsets: [Double], strength: [TimedSample]? = nil) {
        self.onsets = onsets
        self.strength = strength
    }
}
