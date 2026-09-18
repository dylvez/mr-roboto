import Analysis
import Foundation
import Testing

@testable import MrRobotoApp

/// What `Director.live` hands its workbench to separate with.
///
/// `Director.live` used to default its engines to `DirectorEngines()`, whose separator is nil, so the
/// running app's `separate_stems` answered "no separation model loaded" while `m0 separate` used the
/// htdemucs weights sitting in Application Support. These are the tests of the wiring, not of the
/// separation: nothing here calls `separate` on the real Demucs, so nothing needs a model on disk,
/// a download, or the Metal library the `swift test` host cannot find.
@Suite("Director: the band can separate stems")
struct DirectorSeparationWiringTests {

    @MainActor
    private func live(engines: DirectorEngines? = nil, in directory: URL) -> Director {
        let app = BandFixture.app(in: directory)
        // An explicit audition keeps `SurfaceWiring`'s engine out of it; separation is the question.
        if let engines {
            return Director.live(for: app, engines: engines, audition: DirectorSilentAudition())
        }
        return Director.live(for: app, audition: DirectorSilentAudition())
    }

    @Test("the band the app builds is handed the app's Demucs")
    @MainActor
    func liveHasTheAppSeparator() async throws {
        let directory = WiringFixture.temporaryDirectory("band-separation")
        defer { WiringFixture.remove(directory) }

        let workbench = try #require(live(in: directory).workbench)
        let separator = try #require(await workbench.engines.separator,
                                     "separate_stems would say no model is loaded")
        #expect(separator.providerName == "demucsMLX")
        #expect(separator.models.first?.name == "htdemucs")
    }

    @Test("the band and the Import surface share one separator, so the model loads once")
    @MainActor
    func oneSeparatorForTheApp() async throws {
        let directory = WiringFixture.temporaryDirectory("band-separation")
        defer { WiringFixture.remove(directory) }

        let workbench = try #require(live(in: directory).workbench)
        let band = try #require(await workbench.engines.separator)
        let importing = try AnalysisProviders.app().stemSeparator()
        // Compared outside `#expect`: its binary-operator form over `AnyObject` crashes SILGen (Swift 6.4).
        let shared = (band as AnyObject) === (importing as AnyObject)
        #expect(shared, "two separators would each load htdemucs")
    }

    @Test("whatever separator the registry selects is the one the band's tool runs")
    @MainActor
    func registrySeparatorReachesTheTool() async throws {
        let directory = WiringFixture.temporaryDirectory("band-separation")
        defer { WiringFixture.remove(directory) }
        let url = try DirectorAudioFixture.write(DirectorAudioFixture.bar())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var providers = AnalysisProviders()
        providers.register(DirectorStubSeparator(), for: [.stemSeparation])
        let workbench = try #require(live(engines: .app(providers: providers), in: directory).workbench)
        #expect(await workbench.engines.separator?.providerName == "stub-separator")

        // Through the tool, on the workbench `live` built: the path the model's call takes.
        let handle = try await workbench.loadAudio(at: url)
        let output = try await SeparateStemsTool(workbench: workbench).run(.init(audio: handle, stems: nil))
        #expect(output.stems.map(\.name) == ["drums"])
    }

    /// Nil, not a crash and not a stand-in: `separate_stems` then says so (see DirectorToolTests).
    @Test("a registry with no separator gives a band that has none")
    @MainActor
    func noSeparatorRegistered() async throws {
        let directory = WiringFixture.temporaryDirectory("band-separation")
        defer { WiringFixture.remove(directory) }

        let workbench = try #require(live(engines: .app(providers: AnalysisProviders()), in: directory).workbench)
        #expect(await workbench.engines.separator == nil)
    }
}
