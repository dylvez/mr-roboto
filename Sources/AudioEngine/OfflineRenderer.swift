import AVFAudio
import Foundation

/// Renders whatever the engine's sources have scheduled to a WAV file or an in-memory
/// buffer, using manual rendering mode. No audio device is involved.
///
/// The engine must be prepared offline, started, and have a running transport. Sources are
/// asked to schedule ahead before every render chunk (see `Engine.renderOffline`), which
/// mirrors the realtime look-ahead timer.
@AudioActor
public enum OfflineRenderer {
    public enum SampleFormat: Sendable {
        case float32
        case int16
    }

    public struct FileResult: Sendable, Hashable {
        public let url: URL
        public let frameCount: AVAudioFramePosition
    }

    /// Render `seconds` of audio to `url` (a `.wav` path).
    public static func render(engine: Engine, seconds: Double, to url: URL,
                              sampleFormat: SampleFormat = .float32) throws -> FileResult {
        guard case .offline(let sampleRate, _) = engine.mode else { throw EngineError.notInOfflineMode }
        let frames = AVAudioFramePosition((seconds * sampleRate).rounded())
        return try render(engine: engine, frames: frames, to: url, sampleFormat: sampleFormat)
    }

    /// Render `frames` frames to `url` (a `.wav` path). Any existing file is replaced.
    public static func render(engine: Engine, frames: AVAudioFramePosition, to url: URL,
                              sampleFormat: SampleFormat = .float32) throws -> FileResult {
        try checkReady(engine)
        let renderFormat = engine.avEngine.manualRenderingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: renderFormat.channelCount,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        switch sampleFormat {
        case .float32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        case .int16:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: renderFormat.commonFormat, interleaved: renderFormat.isInterleaved)
        var written: AVAudioFramePosition = 0
        do {
            try renderChunks(engine: engine, frames: frames) { chunk in
                try file.write(from: chunk)
                written += AVAudioFramePosition(chunk.frameLength)
            }
        } catch {
            file.close()
            throw error
        }
        file.close()
        return FileResult(url: url, frameCount: written)
    }

    /// Render `frames` frames into a single buffer in the engine's manual rendering format.
    public static func renderBuffer(engine: Engine, frames: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        try checkReady(engine)
        let renderFormat = engine.avEngine.manualRenderingFormat
        guard let out = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw EngineError.renderFailed("could not allocate \(frames) frames")
        }
        try renderChunks(engine: engine, frames: frames) { chunk in
            append(chunk, to: out)
        }
        return out
    }

    /// Drive the engine chunk by chunk, handing each rendered chunk to `sink`.
    public static func renderChunks(engine: Engine, frames total: AVAudioFramePosition,
                                    sink: (AVAudioPCMBuffer) throws -> Void) throws {
        try checkReady(engine)
        let renderFormat = engine.avEngine.manualRenderingFormat
        let maxFrames = engine.avEngine.manualRenderingMaximumFrameCount
        guard let chunk = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: maxFrames) else {
            throw EngineError.renderFailed("could not allocate render chunk")
        }
        var rendered: AVAudioFramePosition = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), total - rendered))
            let status = try engine.renderOffline(frames: n, into: chunk)
            switch status {
            case .success:
                try sink(chunk)
                rendered += AVAudioFramePosition(chunk.frameLength)
            case .insufficientDataFromInputNode:
                // No input node in this graph; treat as a (short) success.
                try sink(chunk)
                rendered += AVAudioFramePosition(chunk.frameLength)
            case .cannotDoInCurrentContext:
                throw EngineError.renderFailed("engine cannot render in the current context")
            case .error:
                throw EngineError.renderFailed("render error")
            @unknown default:
                throw EngineError.renderFailed("unknown render status \(status.rawValue)")
            }
        }
    }

    /// Offline mode, running, transport started — in that order, so the error names the
    /// first missing step. Also keeps `manualRenderingFormat` (undefined outside manual
    /// mode) from being touched.
    private static func checkReady(_ engine: Engine) throws {
        guard engine.mode.isOffline else { throw EngineError.notInOfflineMode }
        guard engine.isRunning else { throw EngineError.notRunning }
        guard engine.transport != nil else { throw EngineError.transportNotStarted }
    }

    private static func append(_ chunk: AVAudioPCMBuffer, to out: AVAudioPCMBuffer) {
        guard let src = chunk.floatChannelData, let dst = out.floatChannelData else { return }
        let n = Int(chunk.frameLength)
        let offset = Int(out.frameLength)
        guard offset + n <= Int(out.frameCapacity) else { return }
        let channels = Int(out.format.channelCount)
        if chunk.stride == 1 && out.stride == 1 {
            for c in 0..<channels { (dst[c] + offset).update(from: src[c], count: n) }
        } else {
            for c in 0..<channels {
                for i in 0..<n { dst[c][(offset + i) * out.stride] = src[c][i * chunk.stride] }
            }
        }
        out.frameLength += AVAudioFrameCount(n)
    }
}
