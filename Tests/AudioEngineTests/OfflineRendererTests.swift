import Testing
import AVFAudio
import Foundation
@testable import AudioEngine

@Suite struct OfflineRendererTests {
    /// Metronome + loop + a sampler note: everything the engine can schedule.
    @AudioActor
    static func buildSchedule(sampleRate: Double, kit: URL) throws -> (Engine, [any ScheduledSource]) {
        let engine = try makeOfflineEngine(sampleRate: sampleRate, channels: 2, playerCount: 2)
        let clock = TransportClock(tempo: 128, sampleRate: sampleRate)
        let metronome = try Metronome(engine: engine, playerIndex: 0, clock: clock, bars: 2)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let source = AudioSynth.sineBurst(format: format, frequency: 110, duration: clock.secondsPerBar * 2, amplitude: 0.3)!
        let loop = try LoopPlayer(engine: engine, playerIndex: 1, buffer: AVReadOnlyAudioPCMBuffer(copying: source),
                                  grid: clock.grid(bars: 2), startBar: 1, endBar: 2)
        let sampler = SamplerKit(engine: engine)
        try sampler.load(folder: kit)
        sampler.play(38, at: 0.25, duration: 0.2)
        sampler.play(36, at: 1.0, duration: 0.2)

        engine.add(metronome)
        engine.add(loop)
        engine.add(sampler)
        try engine.start()
        try engine.startTransport(clock: clock)
        return (engine, [metronome, loop, sampler])
    }

    @Test @AudioActor func sameScheduleRendersByteIdenticalWAVs() throws {
        let sr = 48_000.0
        let kit = try SamplerKitTests.makeSyntheticKit(sampleRate: sr)
        let dir = try Analysis.temporaryDirectory("render")
        var data: [Data] = []
        var counts: [AVAudioFramePosition] = []
        for pass in 0..<2 {
            let (engine, sources) = try Self.buildSchedule(sampleRate: sr, kit: kit)
            let url = dir.appendingPathComponent("pass\(pass).wav")
            let result = try OfflineRenderer.render(engine: engine, seconds: 4, to: url, sampleFormat: .float32)
            engine.stop()
            withExtendedLifetime(sources) {}
            data.append(try Data(contentsOf: url))
            counts.append(result.frameCount)
        }
        #expect(counts == [192_000, 192_000])
        #expect(data[0].count > 192_000 * 2 * 4)
        #expect(data[0] == data[1])

        // The render is not silent and contains the loop, clicks and sampler notes.
        let rendered = try Analysis.read(dir.appendingPathComponent("pass0.wav"))
        #expect(rendered.format.channelCount == 2)
        let x = Analysis.samples(rendered)
        #expect(Analysis.maxAbs(x[0..<1000]) > 0.5)               // downbeat click at 0
        #expect(Analysis.maxAbs(x[Int(1.9 * sr)..<Int(1.95 * sr)]) > 0.05)  // loop (bar 1 onwards)
    }

    @Test @AudioActor func int16RenderMatchesFrameCountAndFormat() throws {
        let sr = 44_100.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let metronome = try Metronome(engine: engine, clock: TransportClock(tempo: 60), bars: 1)
        engine.add(metronome)
        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 60))
        let url = try Analysis.temporaryDirectory("int16").appendingPathComponent("clicks.wav")
        let result = try OfflineRenderer.render(engine: engine, frames: 100_001, to: url, sampleFormat: .int16)
        engine.stop()
        #expect(result.frameCount == 100_001)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 100_001)
        #expect(file.fileFormat.sampleRate == sr)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        // 16-bit mono: 2 bytes per frame plus the header (CoreAudio pads with a FLLR chunk).
        let bytes = try Data(contentsOf: url).count
        #expect(bytes >= 200_002 && bytes < 200_002 + 8192, "\(bytes) bytes")
    }

    @Test @AudioActor func rendererRequiresOfflineModeAndTransport() throws {
        let engine = try Engine(playerCount: 1, sampleRate: 48_000, channels: 1)
        #expect(throws: EngineError.notInOfflineMode) {
            try OfflineRenderer.renderBuffer(engine: engine, frames: 10)
        }
        try engine.prepare(offlineSampleRate: 48_000)
        #expect(throws: EngineError.notRunning) {
            try OfflineRenderer.renderBuffer(engine: engine, frames: 10)
        }
        try engine.start()
        #expect(throws: EngineError.transportNotStarted) {
            try OfflineRenderer.renderBuffer(engine: engine, frames: 10)
        }
        engine.stop()
    }
}
