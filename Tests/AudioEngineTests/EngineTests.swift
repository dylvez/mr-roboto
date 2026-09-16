import Testing
import AVFAudio
@testable import AudioEngine

@Suite struct EngineTests {
    @Test @AudioActor func startsAndStops100TimesOffline() throws {
        let engine = try makeOfflineEngine(sampleRate: 48_000)
        #expect(engine.mode == .offline(sampleRate: 48_000, maximumFrames: 4096))
        for _ in 0..<100 {
            try engine.start()
            #expect(engine.isRunning)
            engine.stop()
            #expect(!engine.isRunning)
        }
        // Still usable afterwards: start a transport and render a chunk.
        try engine.start()
        let transport = try engine.startTransport(clock: TransportClock(tempo: 120))
        #expect(transport.mode.isOffline)
        #expect(transport.sampleRate == 48_000)
        let buffer = try OfflineRenderer.renderBuffer(engine: engine, frames: 10_000)
        #expect(buffer.frameLength == 10_000)
        #expect(engine.transportSeconds.map { abs($0 - 10_000.0 / 48_000) < 1e-9 } == true)
        engine.stop()
        #expect(!engine.isTransportRunning)
    }

    @Test @AudioActor func offlinePrepareReconnectsGraphAtRenderRate() throws {
        let engine = try Engine(playerCount: 1, sampleRate: 48_000, channels: 2)
        try engine.prepare(offlineSampleRate: 44_100, channels: 1)
        #expect(engine.format.sampleRate == 44_100)
        #expect(engine.format.channelCount == 1)
        #expect(engine.players[0].outputFormat(forBus: 0).sampleRate == 44_100)
        try engine.start()
        let transport = try engine.startTransport(clock: TransportClock(tempo: 90))
        #expect(transport.playerTime(atSeconds: 1).sampleTime == 44_100)
        #expect(transport.auSampleTime(atSeconds: 0.5) == 22_050)
        engine.stop()
    }

    @Test @AudioActor func transportErrors() throws {
        let engine = try makeOfflineEngine()
        #expect(throws: EngineError.notRunning) {
            try engine.startTransport(clock: TransportClock(tempo: 120))
        }
        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 120))
        #expect(throws: EngineError.transportAlreadyStarted) {
            try engine.startTransport(clock: TransportClock(tempo: 120))
        }
        #expect(throws: EngineError.playerIndexOutOfRange(7)) { try engine.player(7) }
        engine.stop()
    }
}
