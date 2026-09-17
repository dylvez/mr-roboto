import Analysis
import Foundation
import MusicTheory

/// Cuts a buffer into slices, three ways: at detected onsets, on a `BeatGrid`, or in equal parts.
///
/// ## Snapping
///
/// Onset slicing takes an optional grid. A detected transient within `snapTolerance` of a grid
/// line is moved onto the line, because a slice that starts eight milliseconds before the beat
/// sounds like a mistake when it is played back on the beat — you hear the tail of the previous
/// bar as a flam. A transient further away than the tolerance is left where it was found: it is
/// a deliberately early or late hit, and moving it would flatten the feel the record has.
///
/// The tolerance is a *time*, not a fraction of a beat, on purpose: the ear's tolerance for a
/// misplaced drum attack does not scale with tempo.
///
/// ## What a slice is
///
/// A slice runs from its own start to the next start, and the last one runs to the end of the
/// buffer. Nothing is dropped and nothing overlaps, so playing every slice in order at its own
/// start time reproduces the source sample for sample (`ChopKitTests` asserts exactly that).
public struct Chopper: Sendable {
    /// The onset detector used by `sliceByOnsets`. Its defaults are already tuned for drums.
    public var detector: SpectralFluxOnsetDetector
    /// How far a detected onset may be from a grid line and still be pulled onto it, in seconds.
    /// 25 ms is a little under a 32nd note at 90 bpm: close enough to be a timing error, far
    /// enough that a swung or dragged hit survives.
    public var snapTolerance: Double
    /// Slices shorter than this are merged into their predecessor. Two "onsets" 3 ms apart are one
    /// attack the detector saw twice, not two pads.
    public var minimumSliceDuration: Double
    /// Keep the audio before the first detected transient as a slice of its own (`.leadIn`), so a
    /// chop played back in order starts with what the bar starts with.
    public var includeLeadIn: Bool

    public init(detector: SpectralFluxOnsetDetector = SpectralFluxOnsetDetector(),
                snapTolerance: Double = 0.025,
                minimumSliceDuration: Double = 0.015,
                includeLeadIn: Bool = true) {
        self.detector = detector
        self.snapTolerance = snapTolerance
        self.minimumSliceDuration = minimumSliceDuration
        self.includeLeadIn = includeLeadIn
    }

    // MARK: Onsets

    /// Slice at detected onsets, optionally snapped to a grid.
    ///
    /// - Parameters:
    ///   - signal: mono samples of the region to chop.
    ///   - grid: a grid in the *record's* time, if the onsets should snap to it. `nil` leaves every
    ///     onset where the detector put it.
    ///   - division: subdivisions per beat of the snap grid. 4 snaps to sixteenths.
    ///   - sourceOffset: where frame 0 of `signal` sits in the record, in seconds — what lines the
    ///     grid up with the buffer.
    public func sliceByOnsets(_ signal: [Float], sampleRate: Double,
                              snappingTo grid: BeatGrid? = nil, division: Int = 4,
                              sourceOffset: Double = 0, detectedTempo: Double? = nil) -> Chop {
        let onsets = detector.onsets(in: signal, sampleRate: sampleRate)
        return slice(atOnsets: onsets, signal: signal, sampleRate: sampleRate, snappingTo: grid,
                     division: division, sourceOffset: sourceOffset, detectedTempo: detectedTempo)
    }

    /// Slice at onset times the caller already has (in seconds from frame 0 of `signal`).
    ///
    /// Separate from `sliceByOnsets` so a caller with better onsets — a persona's hand edit, a
    /// different detector, a MIDI trigger track — gets the same snapping and the same measurement.
    public func slice(atOnsets onsets: [Double], signal: [Float], sampleRate: Double,
                      snappingTo grid: BeatGrid? = nil, division: Int = 4,
                      sourceOffset: Double = 0, detectedTempo: Double? = nil) -> Chop {
        let duration = sampleRate > 0 ? Double(signal.count) / sampleRate : 0
        let lines = grid.map {
            Chopper.gridLines($0, division: division, from: sourceOffset, duration: duration)
        } ?? []
        var starts: [Start] = onsets.sorted().map { onset in
            guard !lines.isEmpty,
                  let nearest = Chopper.nearest(lines, to: onset),
                  abs(nearest - onset) <= snapTolerance else {
                return Start(time: onset, origin: .onset, snapOffset: 0)
            }
            return Start(time: nearest, origin: .snapped, snapOffset: nearest - onset)
        }
        if includeLeadIn, let first = starts.first, first.time > minimumSliceDuration {
            starts.insert(Start(time: 0, origin: .leadIn, snapOffset: 0), at: 0)
        }
        return build(starts, signal: signal, sampleRate: sampleRate,
                     sourceOffset: sourceOffset, detectedTempo: detectedTempo)
    }

    // MARK: Grid

    /// Slice on the grid: every beat, or every `division`th part of a beat.
    ///
    /// The grid's own beat times are used, so an uneven grid — a tracker's output on a record that
    /// breathes — produces uneven slices that still line up with the record.
    public func sliceByGrid(_ signal: [Float], sampleRate: Double, grid: BeatGrid,
                            division: Int = 1, sourceOffset: Double = 0,
                            detectedTempo: Double? = nil) -> Chop {
        let duration = sampleRate > 0 ? Double(signal.count) / sampleRate : 0
        let lines = Chopper.gridLines(grid, division: division, from: sourceOffset, duration: duration)
        let starts = lines.map { Start(time: $0, origin: .grid, snapOffset: 0) }
        return build(starts, signal: signal, sampleRate: sampleRate, sourceOffset: sourceOffset,
                     detectedTempo: detectedTempo ?? grid.bpm)
    }

    // MARK: Equal divisions

    /// Slice into `divisions` equal parts — the classic "chop a bar into 16" with no analysis at all.
    public func sliceByDivisions(_ signal: [Float], sampleRate: Double, divisions: Int,
                                 sourceOffset: Double = 0, detectedTempo: Double? = nil) -> Chop {
        guard divisions > 0, !signal.isEmpty else {
            return Chop(slices: [], sampleRate: sampleRate, sourceFrameCount: signal.count,
                        sourceOffset: sourceOffset, detectedTempo: detectedTempo)
        }
        let duration = Double(signal.count) / sampleRate
        let starts = (0..<divisions).map {
            Start(time: duration * Double($0) / Double(divisions), origin: .division, snapOffset: 0)
        }
        return build(starts, signal: signal, sampleRate: sampleRate, sourceOffset: sourceOffset,
                     detectedTempo: detectedTempo)
    }

    // MARK: Grid lines

    /// Grid line times **relative to frame 0 of the buffer**, covering `[0, duration)`.
    ///
    /// Beats come from the grid itself; `division > 1` interpolates inside each beat, which keeps
    /// the subdivisions of an uneven grid proportional to the beat they belong to. Past the last
    /// beat the final interval is extrapolated, so a bar that ends a hair after the last tracked
    /// beat still gets its line.
    public static func gridLines(_ grid: BeatGrid, division: Int, from sourceOffset: Double,
                                 duration: Double) -> [Double] {
        let beats = grid.beats
        guard !beats.isEmpty, duration > 0 else { return [] }
        let parts = max(1, division)
        let start = sourceOffset
        let end = sourceOffset + duration
        // Past the tracked beats the *local* interval carries on — the last real gap forward and
        // the first one backward, not the median. A record that slows into its last bar should
        // keep slowing rather than snap back to an average.
        let median = grid.medianBeatInterval ?? 0.5
        let forward = beats.count >= 2 ? beats[beats.count - 1] - beats[beats.count - 2] : median
        let backward = beats.count >= 2 ? beats[1] - beats[0] : median
        var anchors = beats
        while let last = anchors.last, last < end + forward { anchors.append(last + forward) }
        if let first = anchors.first, first > start {
            // A buffer can start before the first tracked beat.
            var padded: [Double] = []
            var t = first
            while t > start - backward { t -= backward; padded.append(t) }
            anchors = padded.reversed() + anchors
        }

        var lines: [Double] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            for p in 0..<parts {
                let t = a + (b - a) * Double(p) / Double(parts)
                if t >= start - 1e-9 && t < end - 1e-9 { lines.append(t - start) }
            }
        }
        return lines.sorted()
    }

    static func nearest(_ times: [Double], to t: Double) -> Double? {
        BeatGrid.nearestIndex(in: times, to: t).map { times[$0] }
    }

    // MARK: Building

    struct Start {
        var time: Double
        var origin: SliceOrigin
        var snapOffset: Double
    }

    /// Turn start times into measured, non-overlapping slices covering the buffer.
    private func build(_ starts: [Start], signal: [Float], sampleRate: Double,
                       sourceOffset: Double, detectedTempo: Double?) -> Chop {
        let frames = signal.count
        guard frames > 0, sampleRate > 0 else {
            return Chop(slices: [], sampleRate: sampleRate, sourceFrameCount: frames,
                        sourceOffset: sourceOffset, detectedTempo: detectedTempo)
        }
        let minimumFrames = max(1, Int((minimumSliceDuration * sampleRate).rounded()))
        var kept: [Start] = []
        for start in starts.sorted(by: { $0.time < $1.time }) {
            let frame = Int((start.time * sampleRate).rounded())
            guard frame >= 0, frame < frames else { continue }
            if let previous = kept.last {
                let previousFrame = Int((previous.time * sampleRate).rounded())
                // Two starts closer than the floor are one attack seen twice: keep the earlier.
                if frame - previousFrame < minimumFrames { continue }
            }
            kept.append(Start(time: Double(frame) / sampleRate, origin: start.origin,
                              snapOffset: start.snapOffset))
        }
        // A start close to the end of the buffer would make a slice too short to be a pad — the
        // detector catching the tail of the last hit, or a grid line that lands a few milliseconds
        // before the bar ends. Drop it and let the previous slice run to the end.
        while kept.count > 1, frames - Int((kept[kept.count - 1].time * sampleRate).rounded()) < minimumFrames {
            kept.removeLast()
        }
        var slices: [Slice] = []
        slices.reserveCapacity(kept.count)
        for (i, start) in kept.enumerated() {
            let from = Int((start.time * sampleRate).rounded())
            let to = i + 1 < kept.count ? Int((kept[i + 1].time * sampleRate).rounded()) : frames
            var slice = Slice(index: i, start: from, end: to, sampleRate: sampleRate,
                              origin: start.origin, snapOffset: start.snapOffset)
            slice.measure(in: signal)
            slices.append(slice)
        }
        return Chop(slices: slices, sampleRate: sampleRate, sourceFrameCount: frames,
                    sourceOffset: sourceOffset, detectedTempo: detectedTempo)
    }
}
