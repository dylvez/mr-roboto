import AVFAudio
import AudioEngine
import Foundation
import Testing
@testable import Instrument

/// The sampler is a real `ScheduledSource`: the engine drives it, and an offline bounce through the
/// actual `Engine` and its look-ahead scheduling lands a hit on the frame the transport asked for.
/// The rest of the sampler's behaviour is covered without an engine in `VoiceSamplerTests`; this is
/// the one test that proves the two modules meet correctly.
@Suite("VoiceSampler as a ScheduledSource", .serialized)
struct VoiceSamplerEngineTests {

    @Test("the engine drives its schedule and the hit lands on the transport frame")
    @AudioActor
    func drivenByTheEngine() async throws {
        let sampleRate = 48_000.0
        let temp = try TempDirectory()
        defer { temp.remove() }
        let kit = try AudioFixtures.kit(
            in: temp.url, sampleRate: sampleRate,
            samples: ["tone.wav": AudioFixtures.cosineBurst(frequency: 440, seconds: 0.5,
                                                            sampleRate: sampleRate)],
            zones: [Zone(id: "tone", sample: "tone.wav", key: .note(60), velocity: 1...127)]
        )

        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: sampleRate, channels: 2)
        guard let node = sampler.node else { Issue.record("sampler produced no node"); return }

        let engine = try Engine(playerCount: 1, sampleRate: sampleRate, channels: 2)
        engine.avEngine.attach(node)
        // Explicit format, for the same reason the engine connects its sampler explicitly:
        // an implicit one leaves this node's bus at its own rate and drifts against the render.
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.avEngine.connectNode(node, to: engine.mainMixer, format: format)
        try engine.prepare(offlineSampleRate: sampleRate, maximumFrames: 4096)
        engine.add(sampler)

        sampler.enqueue([VoiceSampler.Hit(note: 60, velocity: 100, at: 0.25)])
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: sampleRate))

        // renderBuffer chunks to the engine's maximum frame count and calls schedule(through:)
        // before each chunk, which is exactly the path a real bounce takes.
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(sampleRate))
        engine.stopTransport()
        engine.stop()
        engine.avEngine.detach(node)

        let data = out.floatChannelData![0]
        let onset = (0..<Int(out.frameLength)).first { abs(data[$0]) > 1e-6 }
        #expect(sampler.droppedEventCount == 0)
        #expect(onset != nil, "the engine never delivered the hit")
        if let onset {
            #expect(abs(onset - 12_000) <= 1, "onset landed at \(onset), expected frame 12000")
        }
        sampler.unprepare()
    }
}
