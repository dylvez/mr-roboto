import Analysis
import Foundation

/// How Beat This! runs on pieces longer than its 1500-frame (30 s) training length: a port of
/// `beat_this.inference.split_piece` and `aggregate_prediction` with `overlap_mode="keep_first"`.
///
/// Chunks are `chunkFrames` long and overlap by `border` frames on each side; the first and last are
/// zero-padded by `border` at the piece's edges, and the last chunk start is moved left so it ends
/// exactly at the end of the piece (`avoid_short_end=True`). The model was not trained on chunk edges
/// (max-pooled loss), so `border` frames are discarded from each prediction and, where chunks overlap,
/// the earlier chunk's prediction is kept. Pieces of at most `chunkFrames - 2 · border` frames form one
/// shorter chunk padded by `border` on both sides.
public struct BeatThisChunking: Hashable, Sendable {
    public static let defaultChunkFrames = 1500
    public static let defaultBorder = 6

    /// One model input: `spectrogram[sliceStart..<sliceEnd]` with zero frames before and after.
    public struct Chunk: Hashable, Sendable {
        /// The chunk's nominal start in piece frames (negative for the padded first chunk).
        public var start: Int
        public var sliceStart: Int
        public var sliceEnd: Int
        public var leftPad: Int
        public var rightPad: Int

        public var frames: Int { leftPad + (sliceEnd - sliceStart) + rightPad }
    }

    public var chunkFrames: Int
    public var border: Int

    public init(chunkFrames: Int = BeatThisChunking.defaultChunkFrames, border: Int = BeatThisChunking.defaultBorder) {
        precondition(chunkFrames > 2 * border && border >= 0)
        self.chunkFrames = chunkFrames
        self.border = border
    }

    /// The chunks covering a piece of `frameCount` frames, in order.
    public func chunks(frameCount: Int) -> [Chunk] {
        guard frameCount > 0 else { return [] }
        let step = chunkFrames - 2 * border
        // np.arange(-border, len - border, chunk - 2 * border)
        var starts = Array(stride(from: -border, to: frameCount - border, by: step))
        if starts.isEmpty { starts = [-border] }
        if frameCount > step {
            starts[starts.count - 1] = frameCount - (chunkFrames - border)
        }
        return starts.map { start in
            let sliceStart = max(start, 0)
            let sliceEnd = min(start + chunkFrames, frameCount)
            return Chunk(start: start, sliceStart: sliceStart, sliceEnd: sliceEnd,
                         leftPad: max(0, -start),
                         rightPad: max(0, min(border, start + chunkFrames - frameCount)))
        }
    }

    /// The model input for `chunk`: `chunk.frames × binCount` values, frame-major, zero padded.
    public func input(for chunk: Chunk, from spectrogram: Spectrogram) -> [Float] {
        let bins = spectrogram.binCount
        var out = [Float](repeating: 0, count: chunk.frames * bins)
        let source = spectrogram.values[(chunk.sliceStart * bins)..<(chunk.sliceEnd * bins)]
        out.replaceSubrange((chunk.leftPad * bins)..<((chunk.leftPad + chunk.sliceEnd - chunk.sliceStart) * bins), with: source)
        return out
    }

    /// Stitches per-chunk framewise predictions into one `frameCount`-long series, discarding `border`
    /// frames at each chunk edge and keeping the earliest chunk's value where chunks overlap. Frames no
    /// chunk covers (only possible with a malformed plan) are `-1000`, as in the reference.
    public func aggregate(_ predictions: [[Float]], chunks: [Chunk], frameCount: Int) -> [Float] {
        precondition(predictions.count == chunks.count)
        var out = [Float](repeating: -1000, count: frameCount)
        var written = [Bool](repeating: false, count: frameCount)
        for (chunk, prediction) in zip(chunks, predictions) {
            precondition(prediction.count == chunk.frames, "prediction length must match the chunk")
            let regionStart = chunk.start + border
            let regionEnd = min(chunk.start + chunkFrames, chunk.start + chunk.frames) - border
            for frame in max(regionStart, 0)..<min(regionEnd, frameCount) where !written[frame] {
                out[frame] = prediction[frame - chunk.start]
                written[frame] = true
            }
        }
        return out
    }
}
