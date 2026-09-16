import MusicTheory
import AVFAudio
import Foundation

/// Plays the region `[startBar, endBar)` of a buffer on repeat, sample-accurately.
///
/// The loop boundaries come from a `BeatGrid` (bar start times in seconds, at the buffer's
/// sample rate). Each iteration is scheduled explicitly at
/// `startFrame + k * regionLength` on the player timeline, so iterations never drift and
/// the loop point is exact in both realtime and offline mode. `onLoop` is called (on a
/// non-main thread, from the player's completion handler) once each iteration has been
/// rendered.
@AudioActor
public final class LoopPlayer: ScheduledSource {
    public struct Region: Hashable, Sendable {
        /// First frame of the region in the source buffer.
        public let startFrame: AVAudioFramePosition
        /// One past the last frame of the region in the source buffer.
        public let endFrame: AVAudioFramePosition
        public var length: AVAudioFrameCount { AVAudioFrameCount(endFrame - startFrame) }
    }

    public let player: AVAudioPlayerNode
    public let region: Region
    public let startBar: Int
    public let endBar: Int
    public let sampleRate: Double
    /// Transport time at which iteration 0 starts.
    public var startAtSeconds: Double = 0
    /// Stop after this many iterations (nil = loop forever).
    public var maxIterations: Int?
    /// Called after iteration `k` (0-based) has been rendered by the player.
    public var onLoop: (@Sendable (Int) -> Void)?
    public private(set) var iterationsScheduled = 0

    public var loopDuration: Double { Double(region.length) / sampleRate }

    private let regionBuffer: AVReadOnlyAudioPCMBuffer
    private var transport: Transport?

    /// - Parameters:
    ///   - buffer: source audio; must be float32 at the engine's sample rate with the
    ///     player's channel count.
    ///   - grid: bar times in seconds on the buffer's own timeline.
    ///   - startBar: first bar of the loop (inclusive).
    ///   - endBar: last bar of the loop (exclusive); may equal `grid.barCount`.
    public init(engine: Engine, playerIndex: Int = 1, buffer: AVReadOnlyAudioPCMBuffer, grid: BeatGrid,
                startBar: Int, endBar: Int, onLoop: (@Sendable (Int) -> Void)? = nil) throws {
        let player = try engine.player(playerIndex)
        let playerFormat = player.outputFormat(forBus: 0)
        guard buffer.format.sampleRate == playerFormat.sampleRate else {
            throw EngineError.formatMismatch("buffer is \(buffer.format.sampleRate) Hz, player is \(playerFormat.sampleRate) Hz")
        }
        guard buffer.format.channelCount == playerFormat.channelCount else {
            throw EngineError.formatMismatch("buffer has \(buffer.format.channelCount) channels, player has \(playerFormat.channelCount)")
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32 else {
            throw EngineError.formatMismatch("buffer must be float32")
        }
        guard startBar < endBar, let start = grid.time(ofBar: startBar), let end = grid.time(ofBar: endBar) else {
            throw EngineError.invalidRegion("bars \(startBar)..<\(endBar) are not in the grid")
        }
        let sr = buffer.format.sampleRate
        let startFrame = AVAudioFramePosition((start * sr).rounded())
        let endFrame = AVAudioFramePosition((end * sr).rounded())
        guard startFrame >= 0, endFrame > startFrame, endFrame <= AVAudioFramePosition(buffer.frameLength) else {
            throw EngineError.invalidRegion("frames \(startFrame)..<\(endFrame) exceed buffer length \(buffer.frameLength)")
        }
        let region = Region(startFrame: startFrame, endFrame: endFrame)
        guard let slice = LoopPlayer.slice(of: buffer, region: region) else {
            throw EngineError.invalidRegion("could not copy region")
        }

        self.player = player
        self.region = region
        self.startBar = startBar
        self.endBar = endBar
        self.sampleRate = sr
        self.onLoop = onLoop
        self.regionBuffer = AVReadOnlyAudioPCMBuffer(copying: slice)
    }

    // MARK: ScheduledSource

    public func transportDidStart(_ transport: Transport) {
        self.transport = transport
        iterationsScheduled = 0
    }

    public func schedule(through seconds: Double) {
        guard let transport else { return }
        let base = transport.playerFrame(atSeconds: startAtSeconds)
        let length = AVAudioFramePosition(region.length)
        while maxIterations.map({ iterationsScheduled < $0 }) ?? true {
            let k = iterationsScheduled
            let frame = base + AVAudioFramePosition(k) * length
            let startSeconds = Double(frame) / sampleRate
            if startSeconds >= seconds { break }
            let callback = onLoop
            player.scheduleBuffer(regionBuffer, atTime: transport.playerTime(atFrame: frame), options: [],
                                  completionCallbackType: .dataRendered) {
                callback?(k)
            }
            iterationsScheduled += 1
        }
    }

    public func transportWillStop() {
        transport = nil
    }

    // MARK: helpers

    /// Transport time at which iteration `k` starts.
    public func startTime(ofIteration k: Int) -> Double {
        let base = (startAtSeconds * sampleRate).rounded()
        return (base + Double(k) * Double(region.length)) / sampleRate
    }

    private static func slice(of source: AVReadOnlyAudioPCMBuffer, region: Region) -> AVAudioPCMBuffer? {
        let mutableSource = AVAudioPCMBuffer(copying: source)
        guard let out = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: region.length),
              let src = mutableSource.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = region.length
        let channels = Int(source.format.channelCount)
        let srcStride = mutableSource.stride
        let dstStride = out.stride
        let n = Int(region.length)
        let offset = Int(region.startFrame)
        for c in 0..<channels {
            if srcStride == 1 && dstStride == 1 {
                dst[c].update(from: src[c] + offset, count: n)
            } else {
                for i in 0..<n { dst[c][i * dstStride] = src[c][(offset + i) * srcStride] }
            }
        }
        return out
    }
}
