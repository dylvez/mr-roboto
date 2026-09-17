import Foundation
import MusicTheory

/// Turns (bar, step) into seconds on a real `BeatGrid`.
///
/// The grid's own beat times are the anchors and everything between them is interpolated, so a
/// grid that breathes — a tracker's output on a record played by people — bends the steps with it
/// instead of laying a metronome over the top. Outside the tracked beats the first and last
/// intervals are extrapolated, which is what lets a groove be placed on the bar after the last
/// beat the tracker found.
public struct StepTimeline: Sendable {
    public var grid: BeatGrid
    /// Steps per bar, from the groove (16 for sixteenths in 4/4).
    public var stepsPerBar: Int
    /// 0 = straight, 1 = full triplet swing: the second step of every pair moves from halfway to
    /// two thirds of the way through the pair, which is a delay of a third of a step.
    public var swing: Double

    public init(grid: BeatGrid, stepsPerBar: Int = 16, swing: Double = 0) {
        self.grid = grid
        self.stepsPerBar = max(1, stepsPerBar)
        self.swing = swing
    }

    public var beatsPerBar: Int { max(1, grid.timeSignature.beatsPerBar) }
    /// Steps per beat, as a Double — 4 for sixteenths in 4/4, 2.67 for 16 steps in 6/8.
    public var stepsPerBeat: Double { Double(stepsPerBar) / Double(beatsPerBar) }

    /// Seconds at a fractional beat index, interpolating between the grid's beats.
    public func time(atBeat beat: Double) -> Double {
        let beats = grid.beats
        guard let first = beats.first else { return beat * 0.5 }
        guard beats.count >= 2 else {
            let interval = grid.medianBeatInterval ?? 0.5
            return first + beat * interval
        }
        if beat <= 0 {
            return first + beat * (beats[1] - beats[0])
        }
        let last = beats.count - 1
        if beat >= Double(last) {
            let interval = beats[last] - beats[last - 1]
            return beats[last] + (beat - Double(last)) * interval
        }
        let i = Int(beat.rounded(.down))
        let frac = beat - Double(i)
        return beats[i] + (beats[i + 1] - beats[i]) * frac
    }

    /// The (fractional) beat index where grid bar `bar` starts.
    public func beatIndex(ofBar bar: Int) -> Double {
        guard !grid.bars.isEmpty else { return Double(bar * beatsPerBar) }
        if bar >= 0, bar < grid.bars.count,
           let index = grid.nearestBeatIndex(to: grid.bars[bar]) {
            return Double(index)
        }
        // Past (or before) the tracked bars: count whole bars from the nearest tracked one.
        let anchor = min(max(0, bar), grid.bars.count - 1)
        let base = grid.nearestBeatIndex(to: grid.bars[anchor]).map(Double.init) ?? 0
        return base + Double((bar - anchor) * beatsPerBar)
    }

    /// Seconds of `step` in `bar`, swing included. `step` may run past `stepsPerBar`, which simply
    /// spills into the following bar.
    public func time(bar: Int, step: Int) -> Double {
        let straight = time(atBeat: beatIndex(ofBar: bar) + Double(step) / stepsPerBeat)
        guard swing != 0, step % 2 == 1 else { return straight }
        let next = time(atBeat: beatIndex(ofBar: bar) + Double(step + 1) / stepsPerBeat)
        return straight + swing * (next - straight) / 3
    }

    /// Length of `step` in `bar` in seconds, swing included, i.e. the gap to the next step.
    public func duration(bar: Int, step: Int) -> Double {
        max(0, time(bar: bar, step: step + 1) - time(bar: bar, step: step))
    }
}
