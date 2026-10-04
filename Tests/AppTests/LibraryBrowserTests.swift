import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The Library surface: its model, the actions it shares with the strip on the left, and its place
// on the bench and in the dock.

@MainActor
enum LibraryBrowserFixture {
    /// The index fixture's library in a frame with no store, one of its songs open.
    static func app(open: (LibraryIndexFixture.Shelf) -> Song? = { _ in nil }) -> (app: AppState, shelf: LibraryIndexFixture.Shelf) {
        let shelf = LibraryIndexFixture.shelf()
        let app = AppState(library: shelf.library, song: open(shelf), transportHost: StubTransportHost())
        app.autosaveDelay = nil
        return (app, shelf)
    }

    /// The same, with a store in a scratch directory, for the actions that write.
    static func stored(_ label: String) throws -> (app: AppState, shelf: LibraryIndexFixture.Shelf, directory: URL) {
        let shelf = LibraryIndexFixture.shelf()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-browser-\(label)-\(UUID().uuidString)", isDirectory: true)
        let store = LibraryStore(directoryURL: directory)
        try store.save(shelf.library)
        let app = AppState(library: try store.load(), song: nil, store: store, status: .loaded(directory), transportHost: StubTransportHost())
        app.autosaveDelay = nil
        return (app, shelf, directory)
    }
}

@Suite("The Library surface") @MainActor
struct LibraryBrowserTests {

    @Test("it opens on the shelf it was left on, each shelf with its order and filters, and never the words")
    func remembers() {
        let (app, _) = LibraryBrowserFixture.app()
        let memory = LibraryBrowserMemory.inMemory()
        let first = LibraryBrowserModel(app: app, memory: memory)
        #expect(first.shelf == .songs)
        first.choose(.records)
        first.sort(by: .tempo)
        first.cycleStems()
        first.text = "drift"
        first.choose(.songs)
        first.setGenre("house")

        let again = LibraryBrowserModel(app: app, memory: memory)
        #expect(again.shelf == .songs)
        #expect(again.query.genre == "house")
        again.choose(.records)
        #expect(again.query.sort == .init(.tempo) && again.query.hasStems == true)
        #expect(again.query.text.isEmpty, "a search is for now")
        #expect(again.rows.map(\.title) == ["Drifter"])
    }

    @Test("a column sorts up, then down, then back to the library's order; dates and counts start with the most")
    func sorting() {
        let model = LibraryBrowserModel(app: LibraryBrowserFixture.app().app, memory: .inMemory())
        model.sort(by: .title)
        #expect(model.query.sort == .init(.title))
        model.sort(by: .title)
        #expect(model.query.sort == .init(.title, ascending: false))
        model.sort(by: .title)
        #expect(model.query.sort == nil)
        model.sort(by: .changed)
        #expect(model.query.sort == .init(.changed, ascending: false))
        #expect(model.rows.first?.title == "Café Noir")
    }

    @Test("a link turns to the other shelf, and clears the words and filters that would hide what it shows")
    func links() {
        let (app, shelf) = LibraryBrowserFixture.app()
        let model = LibraryBrowserModel(app: app, memory: .inMemory())
        model.text = "quiet"
        model.sort(by: .tempo)
        model.show(.record(shelf.drifter.id))
        #expect(model.shelf == .records && model.selection == .record(shelf.drifter.id))
        model.show(.song(shelf.nightBus.id))
        #expect(model.shelf == .songs && model.selected?.title == "Night Bus")
        #expect(model.query.text.isEmpty && model.query.sort == .init(.tempo), "the words went; the order stayed")
        model.choose(.records)
        #expect(model.selection == .record(shelf.drifter.id), "each shelf keeps what was chosen on it")
    }

    @Test("the arrows move the choice through the rows as they are ordered")
    func arrows() {
        let model = LibraryBrowserModel(app: LibraryBrowserFixture.app().app, memory: .inMemory())
        model.sort(by: .title)
        model.moveSelection(by: 1)
        #expect(model.selected?.title == "Café Noir", "nothing chosen: the first")
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selected?.title == "Quiet")
        model.moveSelection(by: 5)
        #expect(model.selected?.title == "River", "and no further than the last")
        model.moveSelection(by: -1)
        #expect(model.selected?.title == "Quiet")
    }

    @Test("it opens with the open song chosen, and takes an item asked for from the strip once")
    func asked() throws {
        let (app, _) = LibraryBrowserFixture.app(open: { $0.quiet })
        let model = LibraryBrowserModel(app: app, memory: .inMemory())
        #expect(model.selected?.title == "Quiet")
        app.showInLibrary(.sample(app.library.samples[0].id))
        #expect(app.bench.active?.kind == .library)
        model.takeAsk()
        #expect(model.shelf == .samples && model.selected?.title == "Drifter hit")
        #expect(app.libraryAsk == nil)
    }

    @Test("the narrowest surface still shows the title and what fits beside it")
    func columnsFit() {
        let narrow = LibrarySurfaceView.columns(for: .songs, width: Design.Metric.surfaceMinimumWidth)
        #expect(narrow.first == .title)
        let used = narrow.dropFirst().reduce(LibrarySurfaceView.titleMinimum + 24 + LibrarySurfaceView.playWidth + LibrarySurfaceView.columnSpacing) {
            $0 + (LibrarySurfaceView.width(of: $1) ?? 0) + LibrarySurfaceView.columnSpacing
        }
        #expect(used <= Design.Metric.surfaceMinimumWidth)
        let wide = LibrarySurfaceView.columns(for: .songs, width: 1440 - LibrarySurfaceView.shelvesWidth - LibrarySurfaceView.detailWidth)
        #expect(wide == LibraryColumn.columns(for: .songs), "every column at a wide window")
    }

    @Test("what a song is made from, and what takes from a record, as the detail says it")
    func detail() {
        let (app, shelf) = LibraryBrowserFixture.app()
        let model = LibraryBrowserModel(app: app, memory: .inMemory())
        let made = model.madeFrom(shelf.river.id)
        #expect(made.map(\.record.title) == ["Drifter", "Ferry Bells"])
        #expect(model.usedIn(shelf.drifter.id).map(\.song) == [shelf.nightBus.id, shelf.river.id])
        #expect(model.usedIn(shelf.drifter.id).first?.uses.count == 2, "Night Bus's fitted drums and its chop")
    }
}

@Suite("The library's actions") @MainActor
struct LibraryActionTests {

    private func ids(_ actions: [LibraryAction]) -> [String] { actions.map(\.id) }

    @Test("each shelf offers what the strip's menus offered, as one list")
    func lists() {
        let (app, shelf) = LibraryBrowserFixture.app()
        #expect(ids(LibraryActions.actions(for: .song(shelf.nightBus.id), in: app)) == ["open", "rename", "duplicate", "album", "finder", "favourite", "tag", "trash"])
        #expect(ids(LibraryActions.actions(for: .album(shelf.album.id), in: app)) == ["open", "rename", "favourite", "tag", "delete"])
        #expect(ids(LibraryActions.actions(for: .idea(shelf.idea.id), in: app)) == ["adopt", "favourite", "tag", "remove"])
        #expect(ids(LibraryActions.actions(for: .sample(shelf.chop.id), in: app)) == ["adopt", "favourite", "tag", "remove"])
        #expect(ids(LibraryActions.actions(for: .record(shelf.drifter.id), in: app))
                == ["start", "add", "adopt", "separate", "read", "grid", "rename", "favourite", "tag", "remove"])
        #expect(ids(LibraryActions.actions(for: .record(shelf.ferry.id), in: app)) == ["start", "add", "adopt", "separate", "read", "rename", "favourite", "tag", "remove"],
                "no reading, no grid to correct")
        #expect(LibraryActions.actions(for: .song(SongID()), in: app).isEmpty, "gone from the library: nothing to do")
    }

    @Test("what needs an open song says so, and what needs a reading waits for one")
    func enabled() {
        let (app, shelf) = LibraryBrowserFixture.app()
        func action(_ id: String, _ item: LibraryItemID) -> LibraryAction? { LibraryActions.actions(for: item, in: app).first { $0.id == id } }
        #expect(action("adopt", .idea(shelf.idea.id))?.isEnabled == false)
        #expect(action("add", .record(shelf.drifter.id))?.isEnabled == false)
        #expect(action("start", .record(shelf.drifter.id))?.isEnabled == true)
        #expect(action("start", .record(shelf.ferry.id))?.isEnabled == false, "Ferry Bells has not been read")
        #expect(action("album", .song(shelf.nightBus.id))?.isEnabled == false, "it is on the only album")
        #expect(action("album", .song(shelf.river.id))?.isEnabled == true)
        #expect(LibraryActions.primary(for: .record(shelf.drifter.id), in: app)?.id == "start")
        #expect(LibraryActions.primary(for: .idea(shelf.idea.id), in: app) == nil)

        let (open, other) = LibraryBrowserFixture.app(open: { $0.cafe })
        #expect(LibraryActions.actions(for: .idea(other.idea.id), in: open).first?.isEnabled == true)
        #expect(LibraryActions.primary(for: .record(other.drifter.id), in: open)?.id == "add")
        #expect(LibraryActions.primary(for: .song(other.river.id), in: open)?.id == "open")
    }

    @Test("what cannot be undone asks first, in the words the strip used")
    func confirmations() {
        let (app, shelf) = LibraryBrowserFixture.app()
        func question(_ item: LibraryItemID) -> (String, String, String)? {
            for action in LibraryActions.actions(for: item, in: app) {
                if case .confirm(let question, let detail, let verb, _) = action.kind { return (question, detail, verb) }
            }
            return nil
        }
        #expect(question(.song(shelf.nightBus.id))?.0 == "Move “Night Bus” to the Trash?")
        #expect(question(.song(shelf.nightBus.id))?.2 == "Move to Trash")
        #expect(question(.album(shelf.album.id))?.0 == "Delete the album “Late”?")
        #expect(question(.record(shelf.drifter.id))?.1.contains("songs made from it still play") == true)
        #expect(question(.sample(shelf.chop.id))?.0 == "Remove “Drifter hit” from Samples?")
        var asked: [String] = []
        for action in LibraryActions.actions(for: .album(shelf.album.id), in: app) where ["rename", "delete"].contains(action.id) {
            LibraryActions.perform(action) { asked.append($0.id) }
        }
        #expect(asked == ["rename", "delete"], "a rename and a delete are handed over to be asked, and neither ran")
        #expect(app.library.albums.count == 1)
    }

    @Test("the actions are the app's own calls: a record removed, an album renamed, a song added to an album")
    func performing() throws {
        let (app, shelf, directory) = try LibraryBrowserFixture.stored("perform")
        defer { try? FileManager.default.removeItem(at: directory) }
        for action in LibraryActions.actions(for: .record(shelf.brass.id), in: app) {
            if action.id == "remove", case .confirm(_, _, _, let run) = action.kind { run() }
        }
        #expect(app.library.record(shelf.brass.id) == nil)
        #expect(try LibraryStore(directoryURL: directory).loadDocumentOnly().record(shelf.brass.id) == nil)
        for action in LibraryActions.actions(for: .album(shelf.album.id), in: app) {
            if action.id == "rename", case .rename(let current, _, let run) = action.kind {
                #expect(current == "Late")
                run("  Later  ")
            }
        }
        #expect(app.library.album(shelf.album.id)?.title == "Later")
        let add = LibraryActions.actions(for: .song(shelf.river.id), in: app).first { $0.id == "album" }
        if case .menu(let albums) = add?.kind, let first = albums.first, case .run(let run) = first.kind { run() }
        #expect(app.library.album(shelf.album.id)?.songs.last == shelf.river.id)
        #expect(app.libraryIndex.albums(holding: shelf.river.id) == [shelf.album.id], "and the index follows the write")
    }

    @Test("the strip's row text is the index's")
    func rowText() {
        let (app, shelf) = LibraryBrowserFixture.app()
        let index = app.libraryIndex
        #expect(index.facts(.song(shelf.nightBus.id))?.line == "C major · 85 bpm · 16 bars")
        #expect(index.facts(.record(shelf.drifter.id))?.line == "D minor · 100 bpm · 8 bars · 12¢ sharp · 2 stems")
        #expect(index.facts(.sample(shelf.chop.id))?.line == "D3 · 100 bpm · 2 slices")
        #expect(index.facts(.album(shelf.album.id))?.line == "2 songs")
        #expect(index.facts(.idea(shelf.idea.id))?.line == "the changes")
        #expect(LibrarySidebar.recordDetail(shelf.drifter) == "D minor · 100 bpm · 8 bars · 12¢ sharp · 2 stems")
        #expect(LibrarySidebar.recordDetail(shelf.ferry) == "WAV", "nothing read: what it is")
    }
}

@Suite("The Library on the bench") @MainActor
struct LibraryOnTheBenchTests {

    @Test("it is first on the dock, counts what the library holds, and opens with no song")
    func dock() {
        let (app, _) = LibraryBrowserFixture.app()
        #expect(Guidance.dockSurfaces(for: nil).first == .library)
        #expect(app.dockCount(for: .library) == 10, "4 songs, 3 records, an idea, a sample, an album")
        app.showSurface(.library)
        #expect(app.bench.active?.kind == .library && app.bench.active?.title == "Library")
        #expect(AppState(transportHost: StubTransportHost()).dockCount(for: .library) == nil, "an empty library counts nothing")
    }

    @Test("opening a song from it leaves it on the bench; the song's surfaces go as before")
    func outlivesTheSong() {
        let (app, shelf) = LibraryBrowserFixture.app(open: { $0.quiet })
        app.showSurface(.library)
        app.openSurface(.structure, title: "Quiet")
        #expect(app.bench.items.count == 2)
        app.openSong(shelf.river.id)
        #expect(app.song?.id == shelf.river.id)
        #expect(app.bench.items.map(\.kind) == [.library])
        #expect(app.bench.active?.kind == .library)
    }

    @Test("the Director is not offered it yet: the band reads the library through read_library")
    func notDirectable() {
        #expect(!SurfaceKind.directable.contains(.library))
        #expect(SurfaceKind.directable.count == SurfaceKind.allCases.count - 1)
    }
}
