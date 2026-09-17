import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// `AuditionService`, driven offline.
///
/// This shell has no audio device, so nothing here waits to hear anything. The engine is put in
/// manual rendering mode — `enableManualRenderingMode(.offline, ...)` behind `Engine.prepare` — and
/// the question asked of every audition is the one an offline bounce can answer: *did samples come
/// out of the graph*. That is exactly how `InstrumentTests` and `AudioEngineTests` check the same
/// code paths, and it is the only honest way to check them here.
///
/// Serialized because each test builds a whole `AVAudioEngine` graph and a kit cache.
@Suite("Wiring: the audition service", .serialized)
struct WiringAuditionTests {

    private static let sampleRate: Double = 48_000

    /// An engine in manual rendering mode with a running transport — `OfflineRenderer`'s
    /// preconditions, and the shape `VoiceSamplerEngineTests` uses.
    @AudioActor
    private func offlineEngine(channels: AVAudioChannelCount = 1) throws -> Engine {
        let engine = try Engine(playerCount: 1, sampleRate: Self.sampleRate, channels: channels)
        try engine.prepare(offlineSampleRate: Self.sampleRate, maximumFrames: 4096)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: Self.sampleRate))
        return engine
    }

    @AudioActor
    private func teardown(_ service: AuditionService, _ engine: Engine) async {
        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }

    @Test("raw samples reach the graph, and the engine is started once rather than per touch")
    @AudioActor
    func rawSamplesAreRendered() async throws {
        let kits = WiringFixture.temporaryDirectory("kits")
        defer { WiringFixture.remove(kits) }
        let engine = try offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)

        await service.play(WiringFixture.tone(sampleRate: Self.sampleRate), sampleRate: Self.sampleRate)
        let first = try OfflineRenderer.renderBuffer(engine: engine,
                                                    frames: AVAudioFramePosition(Self.sampleRate / 4))
        #expect(await service.lastFailure == nil)
        #expect(WiringFixture.peak(first) > 0.01, "nothing came out of the graph")

        // The second touch is the one that matters: the engine is already running, and auditioning
        // again must not stop and restart it.
        #expect(engine.isRunning)
        await service.play(WiringFixture.tone(frequency: 660, sampleRate: Self.sampleRate),
                           sampleRate: Self.sampleRate)
        #expect(engine.isRunning)
        let second = try OfflineRenderer.renderBuffer(engine: engine,
                                                     frames: AVAudioFramePosition(Self.sampleRate / 4))
        #expect(WiringFixture.peak(second) > 0.01)

        await teardown(service, engine)
    }

    @Test("samples at another rate are converted to the graph's rather than played at the wrong speed")
    @AudioActor
    func ratesAreConverted() async throws {
        let kits = WiringFixture.temporaryDirectory("kits")
        defer { WiringFixture.remove(kits) }
        let engine = try offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)

        // Half a second at 22.05 kHz must still be half a second at 48 kHz.
        let source = 22_050.0
        await service.play(WiringFixture.tone(seconds: 0.5, sampleRate: source), sampleRate: source)
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                  frames: AVAudioFramePosition(Self.sampleRate / 2))
        #expect(await service.lastFailure == nil)
        #expect(WiringFixture.peak(out) > 0.01)

        // And the conversion itself, checked without a graph: the frame count follows the ratio.
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let converted = try #require(AuditionService.buffer(planar: [Array(repeating: Float(0.5), count: 11_025)],
                                                            sampleRate: source, in: target))
        #expect(abs(Int(converted.frameLength) - 24_000) < 64)

        await teardown(service, engine)
    }

    @Test("a prepared kit plays its hits, and a kit swap is a swap rather than a new engine")
    @AudioActor
    func kitsAndHits() async throws {
        let kits = WiringFixture.temporaryDirectory("kits")
        defer { WiringFixture.remove(kits) }
        let engine = try offlineEngine(channels: 2)
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)

        try await service.prepare(machine: .tr808)
        #expect(await service.currentKitID == SynthMachine.tr808.id)

        await service.play([VoiceSampler.Hit(.kick, velocity: 110, at: 0)])
        #expect(await service.lastFailure == nil)
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                  frames: AVAudioFramePosition(Self.sampleRate / 2))
        #expect(WiringFixture.peak(out) > 0.001, "the 808 kick never reached the graph")

        // Switching machine swaps the kit under the same sampler on the same engine.
        try await service.prepare(machine: .tr909)
        #expect(await service.currentKitID == SynthMachine.tr909.id)
        #expect(engine.isRunning)
        await service.play([VoiceSampler.Hit(.snare, velocity: 110, at: 0)])
        let after = try OfflineRenderer.renderBuffer(engine: engine,
                                                    frames: AVAudioFramePosition(Self.sampleRate / 2))
        #expect(WiringFixture.peak(after) > 0.001)

        await teardown(service, engine)
    }

    @Test("a set of hits that spans time is spread across it rather than fired at once")
    @AudioActor
    func spanningHitsKeepTheirTimes() async throws {
        let kits = WiringFixture.temporaryDirectory("kits")
        defer { WiringFixture.remove(kits) }
        let engine = try offlineEngine(channels: 2)
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        try await service.prepare(machine: .tr808)

        // One hit now and one a quarter of a second later: the second must not be at the front.
        await service.play([VoiceSampler.Hit(.kick, velocity: 110, at: 0),
                            VoiceSampler.Hit(.kick, velocity: 110, at: 0.25)])
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                  frames: AVAudioFramePosition(Self.sampleRate / 2))
        let samples = WiringFixture.channel(out)
        let quiet = Int(Self.sampleRate * 0.15)..<Int(Self.sampleRate * 0.24)
        let late = Int(Self.sampleRate * 0.25)..<Int(Self.sampleRate * 0.35)
        #expect(samples.count > late.upperBound)
        let gap = quiet.reduce(Float(0)) { max($0, abs(samples[$1])) }
        let second = late.reduce(Float(0)) { max($0, abs(samples[$1])) }
        #expect(second > gap, "the second hit did not land after the gap")

        await teardown(service, engine)
    }

    @Test("with no engine an audition is quiet and says why, rather than trapping")
    @AudioActor
    func noEngineIsQuiet() async {
        let kits = WiringFixture.temporaryDirectory("kits")
        defer { WiringFixture.remove(kits) }
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)

        await service.play([0.1, 0.2, 0.3], sampleRate: Self.sampleRate)
        #expect(await service.lastFailure?.contains("no audio device") == true)

        await service.play([VoiceSampler.Hit(.kick, velocity: 100, at: 0)])
        #expect(await service.lastFailure != nil)

        // And stopping something that never started is not an error.
        await service.stop()
        await service.shutdown()
    }
}
