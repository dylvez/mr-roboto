/// Musical time shared by analysis, the song graph, and the engine: a meter and a beat grid in seconds.
/// One definition, so a grid found by analysis drives the transport without conversion.

/// A time signature such as 4/4 or 6/8: beats per bar over the note value that gets one beat.
public struct TimeSignature: Hashable, Codable, Sendable, CustomStringConvertible {
    public var beatsPerBar: Int
    public var beatUnit: Int

    public init(beatsPerBar: Int, beatUnit: Int = 4) {
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
    }

    public init(_ beatsPerBar: Int, _ beatUnit: Int) { self.init(beatsPerBar: beatsPerBar, beatUnit: beatUnit) }

    public static let fourFour = TimeSignature(beatsPerBar: 4)
    public static let threeFour = TimeSignature(beatsPerBar: 3)
    public static let sixEight = TimeSignature(beatsPerBar: 6, beatUnit: 8)

    public var description: String { "\(beatsPerBar)/\(beatUnit)" }
}

/// Beat and bar start times in seconds with a tempo and a meter, plus the lookups a transport, a loop
/// player, or a quantizer needs. Beats and bars are sorted ascending on init. This is the shape Music
/// Understanding and Beat This! results take, and what a fixed-tempo transport produces.
public struct BeatGrid: Hashable, Codable, Sendable {
    public var beats: [Double]
    public var bars: [Double]
    /// Tempo in beats per minute: the tracker's figure if it gave one, else the median beat interval.
    public var bpm: Double?
    public var timeSignature: TimeSignature

    /// - Parameter timeSignature: pass nil to guess from the modal number of beats between bar starts.
    public init(beats: [Double], bars: [Double], bpm: Double? = nil, timeSignature: TimeSignature? = nil) {
        self.beats = beats.sorted()
        self.bars = bars.sorted()
        self.bpm = bpm ?? BeatGrid.medianTempo(of: self.beats)
        self.timeSignature = timeSignature ?? BeatGrid.guessTimeSignature(beats: self.beats, bars: self.bars)
    }

    /// A regular grid: `barCount` bars of `timeSignature.beatsPerBar` beats at `bpm`, starting at `start`.
    public static func regular(bpm: Double, timeSignature: TimeSignature = .fourFour, bars barCount: Int, startingAt start: Double = 0) -> BeatGrid {
        let beatLength = 60 / bpm
        let perBar = timeSignature.beatsPerBar
        let beats = (0..<(barCount * perBar)).map { start + Double($0) * beatLength }
        let bars = (0..<barCount).map { start + Double($0 * perBar) * beatLength }
        return BeatGrid(beats: beats, bars: bars, bpm: bpm, timeSignature: timeSignature)
    }

    public var isEmpty: Bool { beats.isEmpty && bars.isEmpty }
    public var beatCount: Int { beats.count }
    public var barCount: Int { bars.count }

    /// Median interval between consecutive beats, in seconds.
    public var medianBeatInterval: Double? { BeatGrid.medianInterval(of: beats) }

    // MARK: Lookups

    /// Index of the beat closest to `time`, or nil for an empty grid.
    public func nearestBeatIndex(to time: Double) -> Int? { BeatGrid.nearestIndex(in: beats, to: time) }

    /// Time of the beat closest to `time`, or nil for an empty grid.
    public func nearestBeat(to time: Double) -> Double? { nearestBeatIndex(to: time).map { beats[$0] } }

    /// Index of the beat containing `time` (the last beat at or before it), or nil before the first beat.
    public func beatIndex(at time: Double) -> Int? { BeatGrid.lastIndex(in: beats, atOrBefore: time) }

    /// Index of the bar containing `time` (the last bar start at or before it), or nil before the first bar.
    public func barIndex(at time: Double) -> Int? { BeatGrid.lastIndex(in: bars, atOrBefore: time) }

    /// Shorthand for `barIndex(at:)`.
    public func bar(at time: Double) -> Int? { barIndex(at: time) }

    /// Index of the bar start closest to `time`, or nil for a grid without bars.
    public func nearestBarIndex(to time: Double) -> Int? { BeatGrid.nearestIndex(in: bars, to: time) }

    /// Start time of bar `index`. `index == bars.count` returns the extrapolated end of the last
    /// bar, so `[startBar, endBar)` regions can include the final bar.
    public func time(ofBar index: Int) -> Double? {
        guard !bars.isEmpty, index >= 0, index <= bars.count else { return nil }
        return index < bars.count ? bars[index] : endOfLastBar
    }

    /// The extrapolated end of the last bar: last start plus the previous bar's length, or the
    /// beat spacing times beats-per-bar when there is only one bar.
    public var endOfLastBar: Double? {
        guard let last = bars.last else { return nil }
        if bars.count >= 2 { return last + (last - bars[bars.count - 2]) }
        guard let interval = medianBeatInterval else { return nil }
        return last + interval * Double(timeSignature.beatsPerBar)
    }

    /// Length of bar `index` in seconds.
    public func duration(ofBar index: Int) -> Double? {
        guard let start = time(ofBar: index), let end = time(ofBar: index + 1) else { return nil }
        return end - start
    }

    /// Start and end of bar `index`, in seconds.
    public func bounds(ofBar index: Int) -> (start: Double, end: Double)? {
        guard let start = time(ofBar: index), let end = time(ofBar: index + 1) else { return nil }
        return (start, end)
    }

    /// Start and end of bars `first..<last` (bar indices), e.g. `bounds(ofBars: 8..<16)`.
    public func bounds(ofBars indices: Range<Int>) -> (start: Double, end: Double)? {
        guard let start = time(ofBar: indices.lowerBound), let end = time(ofBar: indices.upperBound) else { return nil }
        return (start, end)
    }

    /// Position of `time` as (bar, beat-in-bar) both 0-based, or nil before the first bar.
    public func position(at time: Double) -> (bar: Int, beat: Int)? {
        guard let bar = bar(at: time) else { return nil }
        let barStart = bars[bar]
        let beatsInBar = beats.filter { $0 >= barStart - 1e-6 && $0 <= time + 1e-6 }
        return (bar, max(0, beatsInBar.count - 1))
    }

    /// Beat indices that coincide with a bar start (within `tolerance`), i.e. the accented beats.
    public func downbeatIndices(tolerance: Double = 0.02) -> Set<Int> {
        var result = Set<Int>()
        for bar in bars {
            if let i = nearestBeatIndex(to: bar), abs(beats[i] - bar) <= tolerance { result.insert(i) }
        }
        return result
    }

    /// The grid moved in time by `offset` seconds.
    public func shifted(by offset: Double) -> BeatGrid {
        BeatGrid(beats: beats.map { $0 + offset }, bars: bars.map { $0 + offset }, bpm: bpm, timeSignature: timeSignature)
    }

    // MARK: Estimation helpers

    /// Tempo from the median inter-beat interval.
    public static func medianTempo(of beats: [Double]) -> Double? {
        medianInterval(of: beats).map { 60 / $0 }
    }

    public static func medianInterval(of times: [Double]) -> Double? {
        guard times.count >= 2 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        let mid = intervals.count / 2
        return intervals.count % 2 == 1 ? intervals[mid] : (intervals[mid - 1] + intervals[mid]) / 2
    }

    /// The modal count of beats between consecutive bar starts, as an `n/4` guess. Defaults to 4/4.
    public static func guessTimeSignature(beats: [Double], bars: [Double]) -> TimeSignature {
        guard bars.count >= 2, !beats.isEmpty else { return .fourFour }
        var counts: [Int: Int] = [:]
        for (start, end) in zip(bars, bars.dropFirst()) {
            let n = beats.filter { $0 >= start - 1e-6 && $0 < end - 1e-6 }.count
            if n > 0 { counts[n, default: 0] += 1 }
        }
        guard let best = counts.max(by: { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }) else { return .fourFour }
        return TimeSignature(beatsPerBar: best.key)
    }

    // MARK: Binary search

    public static func nearestIndex(in times: [Double], to t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        let after = lowerBound(times, t)
        if after == 0 { return 0 }
        if after == times.count { return times.count - 1 }
        return (t - times[after - 1]) <= (times[after] - t) ? after - 1 : after
    }

    public static func lastIndex(in times: [Double], atOrBefore t: Double) -> Int? {
        let after = upperBound(times, t)
        return after == 0 ? nil : after - 1
    }

    /// First index whose value is `>= t`.
    static func lowerBound(_ a: [Double], _ t: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index whose value is `> t`.
    static func upperBound(_ a: [Double], _ t: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
