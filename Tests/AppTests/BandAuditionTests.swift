import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// The Director's `audition` tool, wired to the rig that makes a sound.
///
/// `Director.live` used to pass `audition: nil`, which made the tool honestly report silence in the
/// running app as well as in a test — the band could describe a groove and never play one. These are
/// the tests of what it passes instead.
///
/// No audio device here either: the engine runs in manual rendering mode and the question asked is
/// the one an offline bounce can answer — *did samples come out of the graph at the frames the
/// groove put them at*. Nothing in this file needs a key or a network.
@Suite("Band: the Director can audition", .serialized)
struct BandAuditionTests {

    private static let sampleRate: Double = 48_000

    @AudioActor
    private func offlineEngine() throws -> Engine {
        let engine = try Engine(playerCount: 1, sampleRate: Self.sampleRate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.sampleRate, maximumFrames: 4096)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 90, sampleRate: Self.sampleRate))
        return engine
    }

    /// Renders offline and answers with a number: `AVAudioPCMBuffer` is not `Sendable`, so the
    /// buffer never leaves the audio actor.
    @AudioActor
    private func peakAfterRendering(_ engine: Engine, seconds: Double) throws -> Float {
        let buffer = try OfflineRenderer.renderBuffer(
            engine: engine, frames: AVAudioFramePosition(Self.sampleRate * seconds))
        return WiringFixture.peak(buffer)
    }

    /// A workbench holding one real chopped, classified, re-grooved bar — through the same tools the
    /// Director calls, so the handle under test is a handle the model could actually have produced.
    private func grooved(_ workbench: DirectorWorkbench) async throws -> String {
        let url = try DirectorAudioFixture.write(DirectorAudioFixture.bar())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try await workbench.loadAudio(at: url)
        let chop = try await ChopBarTool(workbench: workbench)
            .run(.init(audio: handle, bar: nil, startSeconds: 0,
                       endSeconds: 4 * 60 / DirectorAudioFixture.tempo,
                       method: .divisions, division: 4))
        _ = try await ClassifySlicesTool(workbench: workbench).run(.init(chop: chop.chop, overrides: nil))
        return try await RegrooveChopTool(workbench: workbench)
            .run(.init(chop: chop.chop, feel: "Boom-Bap", tempo: 90, bars: 1,
                       overlap: "ring", rotate: true)).groove
    }

    @Test("the tool plays the groove it names, and says how much of it")
    @MainActor
    func theBandPlaysWhatItProposed() async throws {
        let kits = WiringFixture.temporaryDirectory("band-kits")
        defer { WiringFixture.remove(kits) }
        let engine = try await offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 1))
        let handle = try await grooved(workbench)

        let directory = WiringFixture.temporaryDirectory("band-audition")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let rig = DirectorAuditionRig(workbench: workbench, service: service, app: app)

        // Through the tool, not around it: the schema, the bar clamp and the honest `played` flag
        // are the thing being wired.
        let output = try await AuditionTool(workbench: workbench, audition: rig)
            .run(.init(groove: handle, bars: 1))
        #expect(output.played, "the band still cannot play what it proposes")
        #expect(output.bars == 1)
        #expect(output.detail.contains("hits"))
        #expect(await service.lastFailure == nil)

        let peak = try await peakAfterRendering(engine, seconds: 2)
        #expect(peak > 0.001, "nothing came out of the graph")

        // And the rail says the band played something, in the Director's own voice.
        #expect(app.log.contains { $0.source == .director && $0.text.contains(handle) })

        await service.shutdown()
        await engine.stopTransport()
        await engine.stop()
    }

    @Test("only the bars that were asked for are played")
    @MainActor
    func barsAreHonoured() async throws {
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 1))
        let handle = try await grooved(workbench)
        let stored = try await workbench.groove(handle)

        // Two bars of the feel, one bar asked for: the hits past the first bar are not played.
        let oneBar = DirectorAuditionRig.seconds(bars: 1, tempo: 90, beatsPerBar: 4)
        #expect(abs(oneBar - 8.0 / 3.0) < 1e-9)
        #expect(stored.performance.hits.contains { $0.time < oneBar })
    }

    @Test("with no audio device the tool says nothing was played, and nothing else claims otherwise")
    @MainActor
    func silenceIsSaidOutLoud() async throws {
        let kits = WiringFixture.temporaryDirectory("band-kits-silent")
        defer { WiringFixture.remove(kits) }
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 1))
        let handle = try await grooved(workbench)

        let directory = WiringFixture.temporaryDirectory("band-audition-silent")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let rig = DirectorAuditionRig(workbench: workbench, service: service, app: app)

        let output = try await AuditionTool(workbench: workbench, audition: rig)
            .run(.init(groove: handle, bars: 1))
        #expect(!output.played)
        #expect(!output.detail.isEmpty)
        #expect(!app.log.contains { $0.source == .director && $0.text.hasPrefix("Played") },
                "the rail claimed something was played on a machine with no output device")
    }

    @Test("a handle that is not on the workbench is a sentence, not a thrown error")
    @MainActor
    func anUnknownHandleIsASentence() async throws {
        let kits = WiringFixture.temporaryDirectory("band-kits-unknown")
        defer { WiringFixture.remove(kits) }
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let workbench = DirectorWorkbench()
        let rig = DirectorAuditionRig(workbench: workbench, service: service, app: nil)

        let outcome = await rig.audition(DirectorAuditionRequest(handle: "groove-9", bars: 1, tempo: 90))
        #expect(!outcome.played)
        #expect(outcome.detail.contains("groove-9"))
    }
}
