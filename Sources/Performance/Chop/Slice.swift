import Foundation
import MusicTheory
import SongGraph

/// Why a slice starts where it does.
///
/// The distinction matters for the ear, not for bookkeeping: a slice that starts on a detected
/// transient keeps the attack of the drum that made it, while a slice that starts on a grid line
/// starts wherever the bar says, which may be a millisecond of decay from the previous hit.
public enum SliceOrigin: String, Hashable, Sendable, Codable, CaseIterable {
    /// A detected transient, kept exactly where the onset detector put it.
    case onset
    /// A detected transient that was within the snap tolerance of a grid line and was moved onto it.
    case snapped
    /// A beat, or a subdivision of a beat, of a supplied `BeatGrid`.
    case grid
    /// An equal division of the region, with no grid and no detection involved.
    case division
    /// The stretch of audio before the first detected transient, kept so playing the slices back
    /// in order reproduces the source rather than starting late.
    case leadIn

    /// True when a transient was detected here, snapped or not.
    public var isOnset: Bool { self == .onset || self == .snapped }
    /// True when this start sits on a grid line.
    public var isGridAligned: Bool { self == .snapped || self == .grid || self == .division }
}

/// One region of a source buffer: where it starts and ends, how loud it is, and why it is there.
///
/// Frames are relative to frame 0 of the buffer that was chopped, never to the record it came
/// from — `Chop.sourceOffset` carries that. `end` is exclusive, matching `Zone.sampleEnd`.
public struct Slice: Hashable, Sendable, Codable, Identifiable {
    /// Position in the chop, 0-based. Also the pad order.
    public var index: Int
    /// First frame, inclusive.
    public var start: Int
    /// Last frame, exclusive.
    public var end: Int
    public var sampleRate: Double
    public var origin: SliceOrigin
    /// Largest absolute sample in the region.
    public var peak: Float
    /// Root mean square of the region.
    public var rms: Float
    /// Seconds the start moved when it snapped; positive means it moved later. 0 when it did not.
    public var snapOffset: Double

    public init(index: Int, start: Int, end: Int, sampleRate: Double, origin: SliceOrigin,
                peak: Float = 0, rms: Float = 0, snapOffset: Double = 0) {
        self.index = index
        self.start = start
        self.end = max(start, end)
        self.sampleRate = sampleRate
        self.origin = origin
        self.peak = peak
        self.rms = rms
        self.snapOffset = snapOffset
    }

    public var id: Int { index }
    public var frameCount: Int { end - start }
    public var range: Range<Int> { start..<end }
    public var startSeconds: Double { sampleRate > 0 ? Double(start) / sampleRate : 0 }
    public var endSeconds: Double { sampleRate > 0 ? Double(end) / sampleRate : 0 }
    /// Length in seconds.
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    /// Peak in dBFS, or -inf for silence.
    public var peakDB: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }

    /// Peak and RMS measured over `signal[start..<end]`, clamped to the signal's bounds.
    public mutating func measure(in signal: [Float]) {
        let lo = max(0, min(start, signal.count))
        let hi = max(lo, min(end, signal.count))
        guard hi > lo else { peak = 0; rms = 0; return }
        var maximum: Float = 0
        var sum = 0.0
        for i in lo..<hi {
            let x = signal[i]
            let a = abs(x)
            if a > maximum { maximum = a }
            sum += Double(x) * Double(x)
        }
        peak = maximum
        rms = Float((sum / Double(hi - lo)).squareRoot())
    }
}

/// A sliced buffer: the regions, plus what is needed to put them back where they came from.
public struct Chop: Hashable, Sendable, Codable {
    public var slices: [Slice]
    public var sampleRate: Double
    /// Length of the buffer that was chopped, in frames.
    public var sourceFrameCount: Int
    /// Where frame 0 of that buffer sits in the record it was cut from, in seconds. A bar lifted
    /// from 14.2 s into a stem has `sourceOffset == 14.2`, so slice markers can be written back
    /// into a `SongGraph.Sample` in the record's own time.
    public var sourceOffset: Double
    /// Tempo the chop was cut at, when the caller knew it.
    public var detectedTempo: Double?

    public init(slices: [Slice], sampleRate: Double, sourceFrameCount: Int,
                sourceOffset: Double = 0, detectedTempo: Double? = nil) {
        self.slices = slices
        self.sampleRate = sampleRate
        self.sourceFrameCount = sourceFrameCount
        self.sourceOffset = sourceOffset
        self.detectedTempo = detectedTempo
    }

    public var count: Int { slices.count }
    public var isEmpty: Bool { slices.isEmpty }
    public subscript(index: Int) -> Slice { slices[index] }

    /// Length of the source in seconds.
    public var duration: Double { sampleRate > 0 ? Double(sourceFrameCount) / sampleRate : 0 }

    /// Slices whose start is a detected transient.
    public var onsetSlices: [Slice] { slices.filter { $0.origin.isOnset } }
    /// Slices that were moved onto a grid line by snapping.
    public var snappedSlices: [Slice] { slices.filter { $0.origin == .snapped } }

    // MARK: SongGraph

    /// Slice markers in the record's own time, for a `SongGraph.Sample` payload.
    public var markers: [SliceMarker] {
        slices.map { SliceMarker(position: sourceOffset + $0.startSeconds, label: $0.origin.rawValue) }
    }

    /// The chop as the `Sample` part payload: media by hash, the markers above, root pitch and tempo.
    public func samplePart(media: MediaRef, rootPitch: Pitch? = nil,
                           sourceRecord: RecordID? = nil) -> Sample {
        Sample(media: media, slices: markers, rootPitch: rootPitch,
               detectedTempo: detectedTempo, sourceRecord: sourceRecord)
    }
}
