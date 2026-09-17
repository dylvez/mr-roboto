import Foundation
import MusicTheory

/// Where a groove's steps land in transport seconds: a metronomic tempo, or a `BeatGrid`.
///
/// The grid case is the reason this type exists. Re-grooving a chop onto the beat grid detected
/// from an imported record is M1's core move, and a detected grid is *not* metronomic — beats
/// drift by tens of milliseconds because the drummer did. Everything downstream therefore asks
/// this type for times instead of multiplying by `60 / bpm`: a step at beat 2.5 lands halfway
/// between the grid's own beat 2 and beat 3, whatever the record did between them, and a step
/// on a beat lands exactly on that beat's detected time.
///
/// Step ↔ beat: a groove's `stepsPerBar` divided by the meter's `beatsPerBar` gives steps per beat
/// (16-in-4/4 = four sixteenths, 12-in-4/4 = three triplet eighths, 12-in-3/4 = four sixteenths).
/// Everything here is in beats so the same arithmetic serves any subdivision.
public struct GrooveTimeline: Hashable, Sendable {

    /// The clock the beats come from.
    public enum Clock: Hashable, Sendable {
        /// A metronome: every beat is `60 / bpm` seconds.
        case fixedTempo(bpm: Double)
        /// A measured grid — typically from Music Understanding or Beat This! — used as it is.
        case grid(BeatGrid)
    }

    public var clock: Clock
    /// The meter the groove is read in. For a grid this defaults to the grid's own.
    public var timeSignature: TimeSignature
    /// Which beat of the clock the groove's beat 0 sits on. Lets a groove start at bar 9 of a record.
    public var startBeat: Int
    /// Seconds added to every time, after the clock has been consulted.
    public var offset: Double

    public init(clock: Clock, timeSignature: TimeSignature, startBeat: Int = 0, offset: Double = 0) {
        self.clock = clock
        self.timeSignature = timeSignature
        self.startBeat = startBeat
        self.offset = offset
    }

    /// A metronomic timeline. `offset` is where the groove's first step lands, in transport seconds.
    public static func tempo(_ bpm: Double, timeSignature: TimeSignature = .fourFour,
                             startingAt offset: Double = 0) -> GrooveTimeline {
        GrooveTimeline(clock: .fixedTempo(bpm: bpm > 0 ? bpm : 120), timeSignature: timeSignature, offset: offset)
    }

    /// A timeline riding a detected grid. Times come from the grid itself, so the groove inherits
    /// whatever the record actually did.
    ///
    /// - Parameters:
    ///   - grid: beats and bars in transport seconds.
    ///   - timeSignature: overrides the grid's own meter (pass nil to use it).
    ///   - startBeat: the grid beat the groove's first step lands on. `bar:` is the friendlier form.
    public static func grid(_ grid: BeatGrid, timeSignature: TimeSignature? = nil,
                            startBeat: Int = 0, offset: Double = 0) -> GrooveTimeline {
        GrooveTimeline(clock: .grid(grid), timeSignature: timeSignature ?? grid.timeSignature,
                       startBeat: startBeat, offset: offset)
    }

    /// The same, anchored to a bar of the grid rather than a beat.
    public static func grid(_ grid: BeatGrid, timeSignature: TimeSignature? = nil,
                            bar: Int, offset: Double = 0) -> GrooveTimeline {
        let meter = timeSignature ?? grid.timeSignature
        return GrooveTimeline(clock: .grid(grid), timeSignature: meter,
                              startBeat: bar * meter.beatsPerBar, offset: offset)
    }

    // MARK: Shape

    public var beatsPerBar: Int { max(1, timeSignature.beatsPerBar) }

    /// Tempo in BPM: the stated one, or the grid's estimate.
    public var bpm: Double? {
        switch clock {
        case .fixedTempo(let bpm): return bpm
        case .grid(let grid): return grid.bpm
        }
    }

    /// How many beats the clock can supply after `startBeat`, or nil when it is unbounded
    /// (a fixed tempo) or unmeasurable.
    public var availableBeats: Int? {
        switch clock {
        case .fixedTempo: return nil
        case .grid(let grid): return grid.beats.isEmpty ? nil : max(0, grid.beats.count - startBeat)
        }
    }

    // MARK: Lookups

    /// Transport seconds at `beat` beats after the groove's start. Fractional beats interpolate
    /// inside the containing beat; beats past either end extrapolate from the nearest interval.
    public func time(atBeat beat: Double) -> Double {
        offset + rawTime(atAbsoluteBeat: Double(startBeat) + beat)
    }

    /// Length in seconds of the beat containing `beat` — one beat of the *record*, not of a
    /// metronome, when this timeline rides a grid.
    public func beatDuration(atBeat beat: Double) -> Double {
        let absolute = Double(startBeat) + beat
        let index = Int(absolute.rounded(.down))
        return max(1e-6, beatTime(index + 1) - beatTime(index))
    }

    /// Beats since the groove's start for a transport time. The inverse of `time(atBeat:)`.
    public func beat(atTime seconds: Double) -> Double {
        rawBeat(atAbsoluteTime: seconds - offset) - Double(startBeat)
    }

    /// Transport seconds at step `step` of a groove with `stepsPerBar` steps per bar.
    public func time(ofStep step: Int, stepsPerBar: Int) -> Double {
        time(atBeat: beat(ofStep: step, stepsPerBar: stepsPerBar))
    }

    /// Length in seconds of one step at `step` — the swing and offset unit, which on a detected
    /// grid varies from beat to beat.
    public func stepDuration(ofStep step: Int, stepsPerBar: Int) -> Double {
        let perBar = max(1, stepsPerBar)
        return beatDuration(atBeat: beat(ofStep: step, stepsPerBar: perBar)) * Double(beatsPerBar) / Double(perBar)
    }

    /// Beats since the groove's start for a step index.
    public func beat(ofStep step: Int, stepsPerBar: Int) -> Double {
        Double(step) * Double(beatsPerBar) / Double(max(1, stepsPerBar))
    }

    // MARK: Clock arithmetic

    /// Seconds at an absolute beat coordinate of the clock (before `offset`).
    private func rawTime(atAbsoluteBeat beat: Double) -> Double {
        switch clock {
        case .fixedTempo(let bpm):
            return beat * (60 / (bpm > 0 ? bpm : 120))
        case .grid:
            let index = Int(beat.rounded(.down))
            let fraction = beat - Double(index)
            let start = beatTime(index)
            if fraction == 0 { return start }
            return start + fraction * (beatTime(index + 1) - start)
        }
    }

    private func rawBeat(atAbsoluteTime seconds: Double) -> Double {
        switch clock {
        case .fixedTempo(let bpm):
            return seconds / (60 / (bpm > 0 ? bpm : 120))
        case .grid(let grid):
            guard !grid.beats.isEmpty else { return 0 }
            if seconds <= grid.beats[0] {
                let interval = edgeInterval(grid, leading: true)
                return (seconds - grid.beats[0]) / interval
            }
            if let last = grid.beats.last, seconds >= last {
                let interval = edgeInterval(grid, leading: false)
                return Double(grid.beats.count - 1) + (seconds - last) / interval
            }
            let index = BeatGrid.lastIndex(in: grid.beats, atOrBefore: seconds) ?? 0
            let start = grid.beats[index]
            let span = max(1e-9, beatTime(index + 1) - start)
            return Double(index) + (seconds - start) / span
        }
    }

    /// Seconds at integer beat `index` of the clock, extrapolating past either end.
    private func beatTime(_ index: Int) -> Double {
        switch clock {
        case .fixedTempo(let bpm):
            return Double(index) * (60 / (bpm > 0 ? bpm : 120))
        case .grid(let grid):
            guard !grid.beats.isEmpty else {
                return Double(index) * (60 / (grid.bpm ?? 120))
            }
            if index < 0 {
                return grid.beats[0] + Double(index) * edgeInterval(grid, leading: true)
            }
            if index < grid.beats.count { return grid.beats[index] }
            let last = grid.beats.count - 1
            return grid.beats[last] + Double(index - last) * edgeInterval(grid, leading: false)
        }
    }

    /// The interval used to extrapolate off the front or the back of a grid: the grid's own first
    /// or last gap, falling back to its tempo when it has only one beat.
    private func edgeInterval(_ grid: BeatGrid, leading: Bool) -> Double {
        if grid.beats.count >= 2 {
            let interval = leading
                ? grid.beats[1] - grid.beats[0]
                : grid.beats[grid.beats.count - 1] - grid.beats[grid.beats.count - 2]
            if interval > 0 { return interval }
        }
        if let median = grid.medianBeatInterval, median > 0 { return median }
        return 60 / (grid.bpm ?? 120)
    }
}
