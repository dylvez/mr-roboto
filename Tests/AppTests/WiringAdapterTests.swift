import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// The four adapters, each against a real `AppState`.
///
/// What is worth asserting here is exactly what four agents working in isolation could not check:
/// that each host protocol is genuinely satisfied by the frame's own object, that the version a
/// surface hands over reaches the parts ledger rather than a stub's array, and that the rail says
/// so in the user's voice. None of it makes a sound; the audio path is `WiringAuditionTests`.
@Suite("Wiring: adapters", .serialized) @MainActor
struct WiringAdapterTests {

    // MARK: Import

    @Test("the Import adapter is an ImportHosting over the frame's library, and a promotion lands in the ledger")
    func importAdapter() async throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let store = try #require(app.store)
        let host: any ImportHosting = ImportAdapter(app: app, service: WiringFixture.silentService(),
                                                   live: LiveImportHost(library: store))

        // The surface writes its package through the frame's own library, not a second one.
        #expect(host.library.directoryURL == store.directoryURL)

        let before = app.versions.count
        let promoted = WiringFixture.promotedBar()
        await host.didCommit(promoted, in: WiringFixture.song())

        #expect(app.versions.count == before + 1)
        #expect(app.version(promoted.id) != nil)
        #expect(app.selectedVersion == promoted.id)
        let line = try #require(app.log.last(where: { $0.source == .you && $0.text.contains("sample") }))
        #expect(line.text.lowercased().contains("chop"))
    }

    @Test("promoting a region opens a Chop lane bound to it")
    func importToChopLaneHandOff() async throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host: any ImportHosting = ImportAdapter(app: app, service: WiringFixture.silentService(),
                                                   live: LiveImportHost(library: try #require(app.store)))
        #expect(app.bench.items.isEmpty)

        let promoted = WiringFixture.promotedBar()
        await host.didCommit(promoted, in: WiringFixture.song())

        let lane = try #require(app.bench.items.first { $0.kind == .chopLane })
        #expect(app.bound(for: lane.id) == [promoted.id])
        #expect(lane.title == promoted.note)
        // And the lane's binding finds that bar rather than reporting nothing to chop.
        let binding = ChopLaneBinding(item: lane, app: app, service: WiringFixture.silentService())
        #expect(!binding.state.isUnbound)
    }

    @Test("a promotion the frame already holds is selected rather than recorded twice")
    func promotionAlreadyInTheOpenSong() async throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        var song = WiringFixture.song()
        let promoted = WiringFixture.promotedBar()
        try song.append(promoted)
        let app = WiringFixture.app(in: directory, song: song)

        let count = app.versions.count
        app.adoptPromotedRegion(promoted, from: song)

        // Appending it again would have thrown `duplicateVersion` and logged a failure.
        #expect(app.versions.count == count)
        #expect(app.selectedVersion == promoted.id)
        #expect(app.bench.items.contains { $0.kind == .chopLane })
        #expect(!app.log.contains { $0.text.contains("Could not record") })
    }

    @Test("with no song open a promotion is refused out loud and no lane is opened")
    func promotionWithNoSongOpen() async {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory, song: nil)

        app.adoptPromotedRegion(WiringFixture.promotedBar(), from: WiringFixture.song())

        #expect(app.versions.isEmpty)
        #expect(app.bench.items.isEmpty)
        #expect(app.log.contains { $0.source == .session && $0.text.contains("No song open") })
    }

    // MARK: Grid

    @Test("the Grid adapter is a GridHosting, and a commit lands in the ledger with a rail line")
    func gridAdapter() async throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host: any GridHosting = GridAdapter(app: app, service: WiringFixture.silentService())

        let version = WiringFixture.groove()
        await host.commit(version)

        #expect(app.versions.map(\.id).contains(version.id))
        #expect(app.selectedVersion == version.id)
        let line = try #require(app.log.last)
        #expect(line.source == .you)
        #expect(line.text.contains("groove"))

        // The other three members are reachable with no audio device and say so rather than trapping.
        await host.audition(.kick, velocity: 110)
        await host.setPattern(GridModel.emptyGroove(), options: GrooveRenderOptions(),
                              tempo: 96, timeSignature: .fourFour)
        await #expect(throws: (any Error).self) { try await host.loadMachine(.tr808) }
    }

    @Test("a grid built through the wiring commits through the adapter into the ledger")
    func gridModelCommitsThroughTheAdapter() async throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let item = BenchItem(id: SurfaceID(), kind: .grid, title: "Grid")
        app.openSurface(.grid, title: "Grid", id: item.id)

        let model = wiring.gridModel(for: item, app: app)
        #expect(model.tempo == 96, "an unbound grid opens at the song's tempo")
        model.toggle(.kick, step: 0)
        let version = model.commit(note: "one kick")

        // `GridModel.commit` hands the version over on a task; the ledger has it once that lands.
        try await until { app.version(version.id) != nil }
        #expect(app.versions.map(\.id).contains(version.id))
    }

    // MARK: Sound

    @Test("the Sound adapter bridges the frame's selection and records through it")
    func soundAdapter() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        var song = WiringFixture.song()
        let sound = WiringFixture.sound()
        try song.append(sound)
        let app = WiringFixture.app(in: directory, song: song)
        let host: any SoundSurfaceHost = SoundAdapter(app: app, service: WiringFixture.silentService())

        // `AppState` has `selectedVersion: VersionID?` and `version(_:)`; the surface wants a
        // `PartVersion?`. That bridge is the adapter's, not the frame's.
        app.select(sound.id)
        #expect(host.selectedPart?.id == sound.id)

        // And it is filtered: a melody row is not something to derive a sound from.
        app.select(app.versions.first?.id)
        #expect(host.selectedPart == nil)

        let edited = sound.deriving(sound.kind, by: .user, operation: Operation.edit, note: "warmer")
        #expect(host.record(edited))
        #expect(app.versions.map(\.id).contains(edited.id))
        #expect(app.log.last?.source == .you)
    }

    @Test("a Sound surface built through the wiring commits into the ledger")
    func soundSurfaceCommits() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let item = BenchItem(id: SurfaceID(), kind: .sound, title: "Sound")
        app.openSurface(.sound, title: "Sound", id: item.id)

        let (surface, adapter) = wiring.soundSurface(for: item, app: app)
        #expect(adapter.selectedPart == nil, "nothing sound-shaped is selected")
        surface.setValue(0.8, for: .machine(.decay))
        let version = try #require(surface.commit(note: "longer"))
        #expect(app.versions.map(\.id).contains(version.id))
    }

    // MARK: Chop lane

    @Test("the Chop lane adapter reads the frame's song and records through it")
    func chopLaneAdapter() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host: any ChopLaneHost = ChopLaneAdapter(app: app, service: WiringFixture.silentService(),
                                                    surface: SurfaceID())

        #expect(host.song?.id == app.song?.id)

        let chop = WiringFixture.promotedBar()
        #expect(host.record(chop))
        #expect(app.versions.map(\.id).contains(chop.id))
        #expect(app.log.last?.source == .you)

        // Nothing is prepared and there is no device: both audition members are quiet, not fatal.
        host.audition([VoiceSampler.Hit(note: 36, velocity: 100, at: 0)])
        host.stopAudition()
    }

    @Test("a re-groove committed from the lane opens the Grid on it")
    func chopLaneToGridHandOff() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host = ChopLaneAdapter(app: app, service: WiringFixture.silentService(), surface: SurfaceID())

        let regroove = WiringFixture.groove()
        #expect(host.record(regroove))

        let grid = try #require(app.bench.items.first { $0.kind == .grid })
        #expect(app.bound(for: grid.id) == [regroove.id])

        // A chop is not a groove, so it does not open a grid.
        #expect(host.record(WiringFixture.promotedBar()))
        #expect(app.bench.items.filter { $0.kind == .grid }.count == 1)
    }

    @Test("a version the frame refuses is reported as refused, not swallowed")
    func refusedVersion() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory, song: nil)
        let host = ChopLaneAdapter(app: app, service: WiringFixture.silentService(), surface: SurfaceID())
        #expect(!host.record(WiringFixture.groove()))
        #expect(app.bench.items.isEmpty)
    }

    // MARK: Which bar was promoted

    @Test("a promoted sample's region is recovered from the bars its markers fall in")
    func regionOfAPromotedSample() {
        let bars = (0..<8).map { SongGraph.TimeRange(start: Double($0) * 2.5, end: Double($0 + 1) * 2.5) }
        let sample = Sample(media: WiringFixture.media,
                            slices: [SliceMarker(position: 5.0), SliceMarker(position: 7.5)],
                            detectedTempo: 96)
        let region = ChopLaneBinding.region(of: sample, bars: bars, tempo: 96)
        #expect(region.start == 5.0)
        #expect(region.end == 10.0)

        // With no analysis to hand, one bar at the detected tempo past the last marker.
        let fallback = ChopLaneBinding.region(of: sample, bars: [], tempo: 120)
        #expect(fallback.start == 5.0)
        #expect(abs(fallback.end - (7.5 + 2)) < 1e-9)

        // And with no markers at all it is an honest guess rather than a zero-length region.
        let bare = ChopLaneBinding.region(of: Sample(media: WiringFixture.media), bars: bars, tempo: nil)
        #expect(bare.duration > 0)
    }
}

/// Spin until a fire-and-forget hand-off has landed, or give up. The surfaces commit on a `Task`,
/// so there is no completion to await; this is the same shape `GridSurfaceTests` needs and why that
/// suite is serialized.
@MainActor
func until(_ condition: () -> Bool, within seconds: Double = 2) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
        if ContinuousClock.now >= deadline { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "the hand-off never landed")
}
