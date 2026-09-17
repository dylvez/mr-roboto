import AVFoundation
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

// MARK: - Synthetic drums
//
// Deliberately plain: a kick is a decaying sine, a snare is lowpassed noise plus a tone, a hat is
// highpassed noise. Every one ends on a raised-cosine fade, because a buffer that stops mid-cycle
// is a step, and a step is a transient the onset detector is right to report. The fixtures exist
// to test the chopper, not to sound good.

enum ChopFixtures {
    struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static func fadeOut(_ x: inout [Float], seconds: Double, sampleRate: Double) {
        let n = x.count
        let fade = min(n / 4, max(1, Int(seconds * sampleRate)))
        guard fade > 1 else { return }
        for i in (n - fade)..<n {
            x[i] *= Float(0.5 * (1 + cos(.pi * Double(i - (n - fade)) / Double(fade))))
        }
    }

    static func decayingSine(sampleRate: Double, frequency: Double, duration: Double,
                             decay: Double, amplitude: Double = 0.9) -> [Float] {
        let n = max(1, Int(duration * sampleRate))
        var out = (0..<n).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(sin(2 * .pi * frequency * t) * exp(-t * decay) * amplitude)
        }
        fadeOut(&out, seconds: 0.02, sampleRate: sampleRate)
        return out
    }

    static func noiseBurst(sampleRate: Double, duration: Double, decay: Double,
                           seed: UInt64 = 1, amplitude: Double = 0.8) -> [Float] {
        var rng = RNG(state: seed &* 2862933555777941757 &+ 3037000493)
        let n = max(1, Int(duration * sampleRate))
        var out = (0..<n).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(rng.next() * exp(-t * decay) * amplitude)
        }
        fadeOut(&out, seconds: 0.005, sampleRate: sampleRate)
        return out
    }

    static func lowpass(_ x: [Float], cutoff: Double, sampleRate: Double, poles: Int = 2) -> [Float] {
        var y = x
        let a = exp(-2 * .pi * cutoff / sampleRate)
        for _ in 0..<poles {
            var z = 0.0
            for i in y.indices {
                z = Double(y[i]) * (1 - a) + z * a
                y[i] = Float(z)
            }
        }
        return y
    }

    static func highpass(_ x: [Float], cutoff: Double, sampleRate: Double) -> [Float] {
        let lp = lowpass(x, cutoff: cutoff, sampleRate: sampleRate, poles: 1)
        return zip(x, lp).map { $0 - $1 }
    }

    static func kick(_ sampleRate: Double) -> [Float] {
        decayingSine(sampleRate: sampleRate, frequency: 60, duration: 0.3, decay: 18)
    }

    static func snare(_ sampleRate: Double) -> [Float] {
        var body = lowpass(noiseBurst(sampleRate: sampleRate, duration: 0.18, decay: 26,
                                      seed: 3, amplitude: 3.0),
                           cutoff: 2200, sampleRate: sampleRate, poles: 2)
        let tone = decayingSine(sampleRate: sampleRate, frequency: 190, duration: 0.18,
                                decay: 26, amplitude: 0.45)
        for i in 0..<min(body.count, tone.count) { body[i] += tone[i] }
        let peak = body.map { abs($0) }.max() ?? 1
        if peak > 0 { body = body.map { $0 / peak * 0.8 } }
        return body
    }

    static func hat(_ sampleRate: Double) -> [Float] {
        highpass(noiseBurst(sampleRate: sampleRate, duration: 0.045, decay: 100, seed: 7),
                 cutoff: 4000, sampleRate: sampleRate)
    }

    /// Sums the given sounds into a buffer of `length` seconds at the given times.
    static func place(_ hits: [(time: Double, sound: [Float])], length: Double,
                      sampleRate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: max(1, Int((length * sampleRate).rounded())))
        for hit in hits {
            let offset = Int((hit.time * sampleRate).rounded())
            guard offset >= 0 else { continue }
            for i in 0..<hit.sound.count where offset + i < out.count {
                out[offset + i] += hit.sound[i]
            }
        }
        return out
    }

    /// Four kicks on the beat at `bpm`, one bar of 4/4, the first one exactly at frame 0.
    static func fourOnTheFloor(bpm: Double = 120, sampleRate: Double = 48_000)
        -> (signal: [Float], times: [Double]) {
        let beat = 60 / bpm
        let times = (0..<4).map { Double($0) * beat }
        let signal = place(times.map { (time: $0, sound: kick(sampleRate)) },
                           length: beat * 4, sampleRate: sampleRate)
        return (signal, times)
    }

    /// One bar of a break: kicks on 1, the "and" of 2 and the "and" of 3, snares on 2 and 4, hats
    /// on every eighth. Sixteen steps, `bpm`, 4/4.
    static func breakBar(bpm: Double = 90, sampleRate: Double = 48_000)
        -> (signal: [Float], step: Double, length: Double) {
        let step = 60 / bpm / 4
        let length = step * 16
        var hits: [(time: Double, sound: [Float])] = []
        for s in [0, 6, 10] { hits.append((Double(s) * step, kick(sampleRate))) }
        for s in [4, 12] { hits.append((Double(s) * step, snare(sampleRate))) }
        for s in stride(from: 0, to: 16, by: 2) { hits.append((Double(s) * step, hat(sampleRate))) }
        return (place(hits, length: length, sampleRate: sampleRate), step, length)
    }

    /// A boom-bap feel: kick on 1 and the "and" of 3 with a pickup, snare on 2 and 4, hats on the
    /// eighths with ghosted sixteenths. Written here rather than taken from the feel library so
    /// this suite does not depend on another task's types.
    static func boomBap(swing: Double = 0.25) -> Groove {
        func steps(_ pattern: String) -> [VelocityTier] {
            pattern.map {
                switch $0 {
                case "X": return .accent
                case "x": return .normal
                case ".": return .ghost
                default: return .rest
                }
            }
        }
        return Groove(stepsPerBar: 16, bars: 1, swing: swing, patterns: [
            GroovePattern(voice: .kick,      steps: steps("X-----x---X-----")),
            GroovePattern(voice: .snare,     steps: steps("----X--.----X---")),
            GroovePattern(voice: .closedHat, steps: steps("x.x.x.x.x.x.x.x.")),
        ])
    }

    /// A straight four-to-the-floor feel, for contrast in the demo.
    static func fourFour() -> Groove {
        func steps(_ pattern: String) -> [VelocityTier] {
            pattern.map { $0 == "X" ? .accent : ($0 == "x" ? .normal : ($0 == "." ? .ghost : .rest)) }
        }
        return Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .kick,      steps: steps("X---X---X---X---")),
            GroovePattern(voice: .snare,     steps: steps("----X-------X---")),
            GroovePattern(voice: .closedHat, steps: steps("--x---x---x---x-")),
        ])
    }
}

// MARK: - Signal helpers

enum ChopSignal {
    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
        guard let data = buffer.floatChannelData,
              buffer.format.channelCount > AVAudioChannelCount(channel) else { return [] }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        return (0..<n).map { data[channel][$0 * stride] }
    }

    static func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    /// Normalised cross-correlation of two equal-length signals at zero lag, 1 = identical shape.
    static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a.prefix(n), b.prefix(n)) {
            dot += Double(x) * Double(y)
            na += Double(x) * Double(x)
            nb += Double(y) * Double(y)
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na * nb).squareRoot()
    }

    /// Largest absolute difference between two signals over their common length.
    static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for i in 0..<min(a.count, b.count) { worst = max(worst, abs(a[i] - b[i])) }
        return worst
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

// MARK: - Offline host
//
// The same manual-rendering harness `InstrumentTests` uses, kept here because that one is in
// another test target. No audio device is involved, which is what this machine's automated
// shells require.

final class ChopOfflineHost {
    let av = AVAudioEngine()
    let sampler: VoiceSampler
    let sampleRate: Double
    let format: AVAudioFormat
    var lookAhead: Double = 0.25

    private(set) var originSampleTime: AVAudioFramePosition = 0
    private(set) var transportRunning = false
    private var stopped = false

    init(sampler: VoiceSampler, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
         maximumFrames: AVAudioFrameCount = 4096) throws {
        self.sampler = sampler
        self.sampleRate = sampleRate
        self.format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                                 channels: channels))
        let node = try #require(sampler.node, "prepare(_:) the sampler before hosting it")
        av.attach(node)
        av.connect(node, to: av.mainMixerNode, format: format)
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        try av.start()
    }

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

    func render(seconds: Double) throws -> AVAudioPCMBuffer {
        try render(frames: AVAudioFramePosition((seconds * sampleRate).rounded()))
    }

    func render(frames total: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        let maxFrames = av.manualRenderingMaximumFrameCount
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(max(total, 1))))
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
                ChopSignal.append(chunk, to: out)
                rendered += AVAudioFramePosition(chunk.frameLength)
            default:
                Issue.record("offline render returned \(status.rawValue)")
                return out
            }
        }
        return out
    }

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

// MARK: - Rendering a chop

enum ChopRender {
    /// Write a chop kit to a temporary folder, render `hits` through the real `VoiceSampler`, and
    /// return the mono result. This is the whole playback path — cache, zone table, C core — not
    /// a simulation of it.
    static func render(_ kit: ChopKit, hits: [VoiceSampler.Hit], seconds: Double,
                       sampleRate: Double = 48_000, in folder: URL? = nil) throws -> [Float] {
        let root = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("chop-render-\(UUID().uuidString)", isDirectory: true)
        let loaded = try kit.write(to: root)
        defer { if folder == nil { try? FileManager.default.removeItem(at: root) } }
        return try render(loaded, hits: hits, seconds: seconds, sampleRate: sampleRate)
    }

    static func render(_ kit: LoadedKit, hits: [VoiceSampler.Hit], seconds: Double,
                       sampleRate: Double = 48_000) throws -> [Float] {
        // The cache's default decoder, deliberately: it reads whole files, so this is the path a
        // real chop kit loads through, last slice's tail included.
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: sampleRate, channels: 1)
        let host = try ChopOfflineHost(sampler: sampler, sampleRate: sampleRate, channels: 1)
        defer { host.stop(); sampler.unprepare() }
        host.startTransport()
        sampler.enqueue(hits.sorted { $0.time < $1.time })
        return ChopSignal.samples(try host.render(seconds: seconds))
    }
}

// MARK: - Repo paths

enum ChopPaths {
    /// The repo root, resolved from this file — the same trick `SynthDemoRenderTests` uses.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PerformanceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// The real drum stem the integration test and the demo use, or nil when it is not checked out.
    static var drumStem: URL? {
        let url = repoRoot.appendingPathComponent("Bench/goldens/Arrival/stems/drums.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var demoFolder: URL {
        if let override = ProcessInfo.processInfo.environment["CHOP_DEMO_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("Demos/chops", isDirectory: true)
    }
}
