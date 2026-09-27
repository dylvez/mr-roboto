import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// Every surface's title is a menu of the song's parts it works on, and choosing one turns that
// surface to it in place.

@Suite("Each surface switches between its parts", .serialized) @MainActor
struct PartSwitcherTests {

    private func app(_ label: String) -> (AppState, FormFixture.Built, URL) {
        let built = FormFixture.build()
        let directory = GuidanceFixture.temporaryDirectory(label)
        let app = FormFixture.app(built, in: directory)
        // As `live()` wires it: a surface let go of is built again from its binding.
        app.discardSurfaceModel = { SurfaceWiring.shared.discardModel(for: $0) }
        app.hasUnkeptChanges = { SurfaceWiring.shared.hasUnkeptChanges(for: $0) }
        app.keepAllSurfaces = { [weak app] in
            guard let app else { return }
            SurfaceWiring.shared.keepAll(on: app.bench)
        }
        app.startFreshPart = { [weak app] item, type in
            guard let app, type == .melody else { return }
            SurfaceWiring.shared.pianoRollModel(for: item, app: app).startFreshTune()
        }
        return (app, built, directory)
    }

    @Test("each surface offers the parts that open in it, as the Parts column would open them")
    func relevance() {
        let (app, built, directory) = app("switch-relevance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = app.partChoices(for: .grid)
        #expect(grid.map(\.title) == ["Motown, 120", "Boom-bap pocket"], "\(grid.map(\.title))")
        #expect(grid.map(\.part).contains(built.groove))

        let roll = app.partChoices(for: .pianoRoll)
        #expect(Set(roll.map(\.group)) == ["Melodies", "Bass lines"], "\(roll.map(\.group))")
        #expect(roll.contains { $0.part == built.bass })
        #expect(!roll.contains { $0.group == "Grooves" }, "a groove opens in the Grid")

        #expect(app.partChoices(for: .chords).map(\.part) == [built.progression])
        // The drums stem has been chopped, so it and its chop open the same lane: one choice,
        // named for the chop. The stems not chopped yet are the ledger's to cut.
        let lane = app.partChoices(for: .chopLane)
        #expect(lane.map(\.part) == [built.dryChop], "\(lane.map(\.title))")
        #expect(lane.first?.group == "Chops")
        #expect(app.partChoices(for: .master).map(\.bound) == app.partChoices(for: .mixer).map(\.bound))
        #expect(app.partChoices(for: .structure).isEmpty && app.partChoices(for: .booth).isEmpty)
    }

    @Test("choosing another groove turns the open Grid to it in place, keeping its place and pin")
    func switchesInPlace() throws {
        let (app, _, directory) = app("switch-grid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grooves = app.partChoices(for: .grid)
        let (first, second) = (grooves[0], grooves[1])
        let id = app.openSurface(.grid, title: first.title, bound: first.bound)
        app.setPinned(true, for: id)
        let open = app.bench.items.map(\.id)
        var item = try #require(app.bench.items.first { $0.id == id })
        #expect(app.currentChoice(among: grooves, for: item, working: nil) == first)
        #expect(SurfaceWiring.shared.gridModel(for: item, app: app).base?.partID == first.part)

        #expect(app.switchSurface(id, to: second))
        item = try #require(app.bench.items.first { $0.id == id })
        #expect(app.bench.items.map(\.id) == open, "turned, not opened beside")
        #expect(item.title == second.title && item.isPinned)
        #expect(app.bound(for: id) == second.bound)
        #expect(app.selectedVersion == second.version)
        #expect(app.currentChoice(among: app.partChoices(for: .grid), for: item, working: nil) == second)
        #expect(SurfaceWiring.shared.gridModel(for: item, app: app).base?.partID == second.part,
                "the model is built again from the new binding")
    }

    @Test("the Piano roll turns from a bass line to the tune, and a Grid is not turned to a bass line")
    func acrossKinds() throws {
        let (app, built, directory) = app("switch-roll")
        defer { try? FileManager.default.removeItem(at: directory) }
        let roll = app.partChoices(for: .pianoRoll)
        let bass = try #require(roll.first { $0.part == built.bass })
        let tune = try #require(roll.first { $0.group == "Melodies" })
        let id = app.openSurface(.pianoRoll, title: bass.title, bound: bass.bound)
        #expect(app.switchSurface(id, to: tune))
        let item = try #require(app.bench.items.first { $0.id == id })
        #expect(SurfaceWiring.shared.pianoRollModel(for: item, app: app).mode == .melody)

        let grid = app.openSurface(.grid, title: "Grid", bound: app.partChoices(for: .grid)[0].bound)
        #expect(!app.switchSurface(grid, to: bass), "a bass line is the Piano roll's")
        #expect(app.bound(for: grid) == app.partChoices(for: .grid)[0].bound)
    }

    @Test("what was painted before switching is kept in its own groove, not carried to the next")
    func keepsBeforeSwitching() throws {
        let (app, _, directory) = app("switch-keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let grooves = app.partChoices(for: .grid)
        let (first, second) = (grooves[0], grooves[1])
        let id = app.openSurface(.grid, title: first.title, bound: first.bound)
        let item = try #require(app.bench.items.first { $0.id == id })
        let before = app.song!.versions.filter { $0.partID == first.part }.count
        SurfaceWiring.shared.gridModel(for: item, app: app).toggle(.kick, step: 3)

        #expect(app.switchSurface(id, to: second))
        let kept = app.song!.versions.filter { $0.partID == first.part }
        #expect(kept.count == before + 1, "the painted step is a version of the first groove")
        #expect(app.song!.versions.filter { $0.partID == second.part }.count == 1, "and nothing of it went to the second")
    }

    @Test("New groove turns the Grid to an empty one, and the song has a new groove only once something is painted")
    func newGroove() throws {
        let (app, _, directory) = app("switch-new-groove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = app.partChoices(for: .grid)
        let id = app.openSurface(.grid, title: before[0].title, bound: before[0].bound)
        let fresh = try #require(SurfaceKind.grid.freshParts.first)
        #expect(fresh.title == "New groove")

        #expect(app.startNewPart(fresh, on: id))
        let item = try #require(app.bench.items.first { $0.id == id })
        #expect(app.bound(for: id).isEmpty && item.title == "New groove")
        let model = SurfaceWiring.shared.gridModel(for: item, app: app)
        #expect(model.base == nil)
        app.keepSurfaceWork()
        #expect(app.partChoices(for: .grid).count == before.count, "an empty grid is not a groove")

        model.toggle(.kick, step: 0)
        app.keepSurfaceWork()
        #expect(app.partChoices(for: .grid).count == before.count + 1)
    }

    @Test("New melody turns the roll to an empty tune rather than the bass line an octave up")
    func newMelody() throws {
        let (app, built, directory) = app("switch-new-melody")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bass = try #require(app.partChoices(for: .pianoRoll).first { $0.part == built.bass })
        let id = app.openSurface(.pianoRoll, title: bass.title, bound: bass.bound)
        let melodies = app.song!.versions.filter { $0.type == .melody }.count
        let basslines = Set(app.song!.versions.filter { $0.type == .bassline }.map(\.partID)).count

        let fresh = try #require(SurfaceKind.pianoRoll.freshParts.first { $0.type == .melody })
        #expect(app.startNewPart(fresh, on: id))
        let item = try #require(app.bench.items.first { $0.id == id })
        let model = SurfaceWiring.shared.pianoRollModel(for: item, app: app)
        #expect(model.mode == .melody && model.notes.isEmpty && !model.isTouched)

        model.addNote(pitch: 72, at: 0, duration: 1)
        app.keepSurfaceWork()
        #expect(app.song!.versions.filter { $0.type == .melody }.count == melodies + 1)
        #expect(Set(app.song!.versions.filter { $0.type == .bassline }.map(\.partID)).count == basslines,
                "the bass line drafted underneath was not kept")
        #expect(app.log.contains { $0.text == "New melody in Piano roll" })
    }

    @Test("only the surfaces that can start a part offer to, and only their own kind")
    func freshKinds() throws {
        let (app, _, directory) = app("switch-new-kinds")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SurfaceKind.chords.freshParts.map(\.type) == [.progression])
        #expect(SurfaceKind.lyrics.freshParts.map(\.type) == [.lyric])
        #expect(SurfaceKind.chopLane.freshParts.isEmpty && SurfaceKind.mixer.freshParts.isEmpty)
        let grid = app.openSurface(.grid, title: "Grid", bound: app.partChoices(for: .grid)[0].bound)
        let melody = try #require(SurfaceKind.pianoRoll.freshParts.last)
        #expect(!app.startNewPart(melody, on: grid))
        #expect(!app.bound(for: grid).isEmpty)
    }
}
