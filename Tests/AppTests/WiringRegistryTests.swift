import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

/// The catalog, wired.
///
/// The frame's own registry tests already prove the fallback; these prove the opposite — that after
/// `registerGateASurfaces()` nothing falls back, and that a surface opened with no binding (the
/// Surfaces menu, ⌘1–⌘4) builds a real view rather than crashing or drawing an empty box.
@Suite("Wiring: registration", .serialized) @MainActor
struct WiringRegistryTests {

    @Test("registerGateASurfaces registers exactly the four Gate A kinds")
    func registersFourKinds() {
        SurfaceRegistry.registerGateASurfaces()
        let registry = SurfaceRegistry.shared
        #expect(registry.registeredKinds == SurfaceKind.gateA)
        #expect(registry.registeredKinds.count == 4)
        for kind in SurfaceKind.allCases {
            #expect(registry.hasBuilder(for: kind), "\(kind.rawValue) has no builder")
        }
    }

    @Test("every kind resolves to a surface rather than the placeholder")
    func everyKindResolves() {
        SurfaceRegistry.registerGateASurfaces()
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)

        // One at a time: the bench holds three, and a retired surface is not the thing under test.
        for kind in SurfaceKind.gateA {
            let item = open(kind, in: app)
            #expect(!SurfaceRegistry.shared.resolve(item, app: app).isPlaceholder,
                    "\(kind.rawValue) fell back to the placeholder")
            app.closeSurface(item.id)
        }
    }

    @Test("an unbound surface of each kind builds, and says what it is")
    func unboundSurfacesBuild() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let wiring = SurfaceWiring()

        // Import with nothing bound is the drop target it always is.
        let importItem = open(.importRecord, in: app)
        let model = wiring.importModel(for: importItem, app: app)
        #expect(model.state == .empty)
        #expect(model.state.phase == .empty)
        #expect(model.title == "Record")
        app.closeSurface(importItem.id)

        // Grid with nothing bound is an empty pattern at the song's tempo and meter.
        let gridItem = open(.grid, in: app)
        let grid = wiring.gridModel(for: gridItem, app: app)
        #expect(grid.tempo == app.song?.tempo)
        #expect(grid.timeSignature == app.song?.timeSignature)
        #expect(grid.stepCount == 16)
        #expect(grid.voices.allSatisfy { voice in
            (0..<grid.stepCount).allSatisfy { grid.tier(voice, step: $0) == .rest }
        }, "an unbound grid is silent, not pre-filled")
        app.closeSurface(gridItem.id)

        // Sound with nothing selected still edits something — a new part from the machine preset —
        // and the panel is told to say so.
        let soundItem = open(.sound, in: app)
        let (sound, soundAdapter) = wiring.soundSurface(for: soundItem, app: app)
        #expect(soundAdapter.selectedPart == nil)
        #expect(sound.boundVersion == nil)
        #expect(!sound.controls.isEmpty, "an unbound Sound surface still has its controls")
        app.closeSurface(soundItem.id)

        // The Chop lane is the one that genuinely has nothing to show, and says which gesture fills it.
        let chopItem = open(.chopLane, in: app)
        let chop = wiring.chopBinding(for: chopItem, app: app)
        #expect(chop.state.isUnbound)
    }

    @Test("the same bench item keeps the same model across renders, and a closed one is let go")
    func modelsAreStablePerSurface() {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let wiring = SurfaceWiring()

        let item = open(.grid, in: app)
        let first = wiring.gridModel(for: item, app: app)
        first.toggle(.snare, step: 4)
        let second = wiring.gridModel(for: item, app: app)
        #expect(first === second, "rebuilding per render would erase the edit in progress")
        #expect(second.tier(.snare, step: 4) != .rest)

        // Closing it lets the model go: the bench's own rule (three open, oldest unpinned retired)
        // is what decides when a surface's draft and its engine work are done with.
        app.closeSurface(item.id)
        let next = open(.grid, in: app)
        _ = wiring.gridModel(for: next, app: app)
        #expect(!wiring.holds(item.id), "a closed surface is still being held")
        #expect(wiring.holds(next.id))
    }

    @Test("a Grid opened on a groove version opens on that pattern")
    func gridBoundToAGroove() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        var song = WiringFixture.song()
        var groove = GridModel.emptyGroove()
        groove.patterns[0].steps[0] = .accent
        let version = PartVersion(partID: PartID(), kind: .groove(groove), author: .user,
                                  operation: Operation.written)
        try song.append(version)
        let app = WiringFixture.app(in: directory, song: song)

        let id = app.openSurface(.grid, title: "Bar", bound: [version.id])
        let item = try #require(app.bench.items.first { $0.id == id })
        let model = SurfaceWiring().gridModel(for: item, app: app)
        #expect(model.tier(.kick, step: 0) == .accent)
        #expect(model.base?.id == version.id)
    }

    private func open(_ kind: SurfaceKind, in app: AppState) -> BenchItem {
        let id = app.openSurface(kind, title: kind.rawValue)
        return app.bench.items.first { $0.id == id }
            ?? BenchItem(id: id, kind: kind, title: kind.rawValue)
    }
}
