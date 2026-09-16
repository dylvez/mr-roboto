import AVFoundation
import Foundation
import Testing
@testable import Instrument

// MARK: - Offline host
//
// `InstrumentTests` does not link `AudioEngine` (the `Instrument` target does not depend on it),
// so this is the same manual-rendering harness `AudioEngine.Engine` + `OfflineRenderer` provide,
// reduced to the one node under test:
//
//   * `AVAudioEngine.enableManualRenderingMode(.offline, ...)`  — exactly `Engine.prepare(offlineSampleRate:)`
//   * transport zero anchored at `manualRenderingSampleTime`    — exactly `Transport.originSampleTime`
//   * `schedule(through:)` before every chunk                   — exactly `Engine.renderOffline(frames:into:)`
//   * chunked `renderOffline` accumulated into one buffer       — exactly `OfflineRenderer.renderBuffer`
//
// No audio device is involved, which is what this machine's automated shells require.

final class OfflineHost {
    let av = AVAudioEngine()
    let sampler: VoiceSampler
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let format: AVAudioFormat
    /// Mirrors `Engine.lookAhead`: how far past the end of a chunk sources are asked to schedule.
    var lookAhead: Double = 0.25

    private(set) var originSampleTime: AVAudioFramePosition = 0
    private(set) var transportRunning = false
    private var stopped = false

    init(sampler: VoiceSampler, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
         maximumFrames: AVAudioFrameCount = 4096) throws {
        self.sampler = sampler
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let node = try #require(sampler.node, "prepare(_:) the sampler before hosting it")
        av.attach(node)
        av.connect(node, to: av.mainMixerNode, format: format)
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        try av.start()
    }

    /// Anchor the transport at the current render position, as `Engine.startTransport` does.
    func startTransport() {
        originSampleTime = av.manualRenderingSampleTime
        sampler.transportDidStart(originSampleTime: Int64(originSampleTime), sampleRate: sampleRate)
        transportRunning = true
        sampler.schedule(through: lookAhead)
    }

    func stopTransport() {
        guard transportRunning else { return }
        sampler.transportWillStop()
        transportRunning = false
    }

    /// Transport seconds at the current render position.
    var transportSeconds: Double {
        Double(av.manualRenderingSampleTime - originSampleTime) / sampleRate
    }

    func render(seconds: Double) throws -> AVAudioPCMBuffer {
        try render(frames: AVAudioFramePosition((seconds * sampleRate).rounded()))
    }

    /// Render `frames` frames, asking the sampler to schedule ahead before every chunk.
    func render(frames total: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        let maxFrames = av.manualRenderingMaximumFrameCount
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(total, 1))))
        var rendered: AVAudioFramePosition = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), total - rendered))
            if transportRunning {
                let end = Double(av.manualRenderingSampleTime + AVAudioFramePosition(n) - originSampleTime) / sampleRate
                sampler.schedule(through: end + lookAhead)
            }
            let status = try av.renderOffline(n, to: chunk)
            switch status {
            case .success, .insufficientDataFromInputNode:
                Signal.append(chunk, to: out)
                rendered += AVAudioFramePosition(chunk.frameLength)
            default:
                Issue.record("offline render returned \(status.rawValue)")
                return out
            }
        }
        return out
    }

    /// Detach the node before anything frees the memory its render block reads — the lifetime
    /// contract `VoiceSampler.unprepare()` documents.
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopTransport()
        av.stop()
        if let node = sampler.node { av.detach(node) }
        if av.isInManualRenderingMode { av.disableManualRenderingMode() }
    }

    deinit { stop() }
}

// MARK: - Signal analysis

enum Signal {
    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.format.channelCount > AVAudioChannelCount(channel) else { return [] }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        return (0..<n).map { data[channel][$0 * stride] }
    }

    static func maxAbs(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }
    static func maxAbs(_ x: [Float]) -> Float { maxAbs(x[...]) }

    /// Index of the first sample whose magnitude exceeds `threshold`, or nil.
    static func firstIndex(of x: [Float], above threshold: Float) -> Int? {
        x.firstIndex { abs($0) > threshold }
    }

    /// Zero-crossing frequency estimate over `range` (rising crossings only).
    static func estimateFrequency(_ x: [Float], in range: Range<Int>, sampleRate: Double) -> Double {
        var crossings = 0
        for i in (range.lowerBound + 1)..<range.upperBound where x[i - 1] < 0 && x[i] >= 0 {
            crossings += 1
        }
        return Double(crossings) * sampleRate / Double(range.count)
    }

    /// Magnitude of the single-bin DFT at `frequency` over `range`, normalised by the window
    /// length — an FFT peak check without pulling in a transform.
    static func magnitude(_ x: [Float], at frequency: Double, in range: Range<Int>, sampleRate: Double) -> Double {
        var re = 0.0, im = 0.0
        for i in range {
            let phase = 2 * Double.pi * frequency * Double(i - range.lowerBound) / sampleRate
            re += Double(x[i]) * cos(phase)
            im -= Double(x[i]) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(range.count)
    }

    static func append(_ chunk: AVAudioPCMBuffer, to out: AVAudioPCMBuffer) {
        guard let src = chunk.floatChannelData, let dst = out.floatChannelData else { return }
        let n = Int(chunk.frameLength)
        let offset = Int(out.frameLength)
        guard offset + n <= Int(out.frameCapacity) else { return }
        for c in 0..<Int(out.format.channelCount) {
            for i in 0..<n { dst[c][(offset + i) * out.stride] = src[c][i * chunk.stride] }
        }
        out.frameLength += AVAudioFrameCount(n)
    }
}
