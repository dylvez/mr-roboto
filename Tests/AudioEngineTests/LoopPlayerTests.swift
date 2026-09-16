import MusicTheory
import Testing
import AVFAudio
import Foundation
@testable import AudioEngine

@Suite struct LoopPlayerTests {
    /// 8 bars at 120 BPM (2 s per bar) with a +1.0 marker at the start of bar 2 and a
    /// -1.0 marker at the start of bar 6, on top of a quiet sine.
    static func makeSource(sampleRate: Double) -> (AVReadOnlyAudioPCMBuffer, BeatGrid) {
        let clock = TransportClock(tempo: 120, sampleRate: sampleRate)
        let grid = clock.grid(bars: 8)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(clock.frame(forBar: 8))
        let buffer = AudioSynth.silence(format: format, frames: frames)!
        let markerStart = Int(clock.frame(forBar: 2))
        let markerEnd = Int(clock.frame(forBar: 6))
        AudioSynth.fill(buffer) { i in
            if i == markerStart { return 1.0 }
            if i == markerEnd { return -1.0 }
            return 0.2 * Float(sin(2 * Double.pi * 220 * Double(i) / sampleRate))
        }
        return (AVReadOnlyAudioPCMBuffer(copying: buffer), grid)
    }

    @Test @AudioActor func fourBarLoopIsSampleExactAcrossTenIterations() async throws {
        let sr = 48_000.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let (source, grid) = Self.makeSource(sampleRate: sr)
        let counter = Counter()
        let loop = try LoopPlayer(engine: engine, playerIndex: 1, buffer: source, grid: grid,
                                  startBar: 2, endBar: 6) { counter.record($0) }
        loop.maxIterations = 10
        engine.add(loop)

        let regionLength = AVAudioFramePosition(4 * 2 * sr)  // 4 bars * 2 s
        #expect(loop.region.startFrame == AVAudioFramePosition(2 * 2 * sr))
        #expect(loop.region.endFrame == AVAudioFramePosition(6 * 2 * sr))
        #expect(AVAudioFramePosition(loop.region.length) == regionLength)
        #expect(loop.loopDuration == 8)

        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 120))

        let dir = try Analysis.temporaryDirectory("loop")
        let url = dir.appendingPathComponent("loop.wav")
        let expectedFrames = 10 * regionLength
        let result = try OfflineRenderer.render(engine: engine, seconds: 10 * loop.loopDuration, to: url)
        #expect(abs(result.frameCount - expectedFrames) <= 1)
        #expect(loop.iterationsScheduled == 10)

        let rendered = try Analysis.read(url)
        #expect(abs(AVAudioFramePosition(rendered.frameLength) - expectedFrames) <= 1)
        let x = Analysis.samples(rendered)

        // The +1.0 marker sits at the loop start: exactly once per iteration, at k * length.
        let positive = x.indices.filter { x[$0] > 0.9 }
        #expect(positive == (0..<10).map { Int($0 * Int(regionLength)) }, "markers at \(positive)")
        // The -1.0 marker at the loop END must never be rendered (region is half-open).
        #expect(x.indices.filter { x[$0] < -0.9 }.isEmpty)
        // Every rendered sample equals the region repeated: render[i] == source[start + i mod L].
        // This proves no sample is dropped or shifted at any of the ~940 render-chunk
        // boundaries or the 9 loop points.
        let sourceSamples = Analysis.samples(AVAudioPCMBuffer(copying: source))
        let regionStart = Int(loop.region.startFrame)
        let length = Int(regionLength)
        var mismatches = 0
        var firstMismatch = -1
        for i in 0..<min(x.count, 10 * length) {
            let expected = sourceSamples[regionStart + (i % length)]
            if abs(x[i] - expected) > 1e-4 {
                mismatches += 1
                if firstMismatch < 0 { firstMismatch = i }
            }
        }
        #expect(mismatches == 0, "\(mismatches) mismatching samples, first at \(firstMismatch)")

        await counter.wait(for: 10)
        #expect(counter.recorded == Array(0..<10))
        engine.stop()
    }

    @Test @AudioActor func regionValidation() throws {
        let sr = 48_000.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let (source, grid) = Self.makeSource(sampleRate: sr)
        #expect(throws: EngineError.self) {
            try LoopPlayer(engine: engine, buffer: source, grid: grid, startBar: 6, endBar: 6)
        }
        #expect(throws: EngineError.self) {
            try LoopPlayer(engine: engine, buffer: source, grid: grid, startBar: 0, endBar: 9)
        }
        // endBar == barCount uses the extrapolated end of the last bar.
        let whole = try LoopPlayer(engine: engine, buffer: source, grid: grid, startBar: 0, endBar: 8)
        #expect(whole.region.endFrame == AVAudioFramePosition(source.frameLength))
        // Wrong sample rate is rejected.
        let other = Self.makeSource(sampleRate: 44_100).0
        #expect(throws: EngineError.self) {
            try LoopPlayer(engine: engine, buffer: other, grid: grid, startBar: 0, endBar: 1)
        }
    }
}
