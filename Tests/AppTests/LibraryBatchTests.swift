import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Organising the library: favourites and tags kept in library.json alone, searches saved by name,
// several items chosen at once and acted on together.

@MainActor
enum BatchFixture {
    static func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-batch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every file under `directory` with its bytes, to compare before and after.
    static func snapshot(_ directory: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return out
    }
}

@Suite("Favourites and tags", .serialized) @MainActor
struct LibraryMarkTests {

    @Test("a library nobody marked is written byte for byte as before, and one marked and unmarked comes back to it")
    func roundTrip() throws {
        let (app, shelf, directory) = try LibraryBrowserFixture.stored("marks-round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("library.json")
        let store = LibraryStore(directoryURL: directory)
        // As the frame writes it: library.json alone, listing the packages on disk.
        try store.saveDocument(try store.loadDocumentOnly())
        let before = try Data(contentsOf: document)
        #expect(!String(decoding: before, as: UTF8.self).contains("\"marks\""))
        try store.saveDocument(try store.loadDocumentOnly())
        #expect(try Data(contentsOf: document) == before, "read and written again: the same bytes")

        let packages = try BatchFixture.snapshot(directory).filter { $0.key.contains(".roboto/") }
        #expect(app.setFavourite(true, for: [.record(shelf.drifter.id), .song(shelf.river.id)]))
        #expect(app.addTag("dusty", to: [.record(shelf.drifter.id)]))
        #expect(String(decoding: try Data(contentsOf: document), as: UTF8.self).contains("\"marks\""))
        #expect(try store.loadDocumentOnly().mark(.record, shelf.drifter.id.rawValue)?.tags == ["dusty"], "kept, and read back")
        #expect(try BatchFixture.snapshot(directory).filter { $0.key.contains(".roboto/") } == packages, "no song's package touched")

        #expect(app.setFavourite(false, for: [.record(shelf.drifter.id), .song(shelf.river.id)]))
        #expect(app.removeTag("DUSTY", from: [.record(shelf.drifter.id)]), "a tag is a tag however it is cased")
        #expect(app.library.marks == nil)
        #expect(try Data(contentsOf: document) == before, "nothing marked: what it always wrote")
    }

    @Test("a tag is trimmed and kept once, and every tag is searched and filtered by")
    func tags() throws {
        let (app, shelf, directory) = try LibraryBrowserFixture.stored("marks-tags")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.addTag("  after   hours ", to: [.song(shelf.river.id), .song(shelf.quiet.id)])
        app.addTag("After Hours", to: [.song(shelf.river.id)])
        #expect(app.mark(of: .song(shelf.river.id))?.tags == ["after hours"])
        #expect(app.allTags == ["after hours"])
        app.setFavourite(true, for: [.song(shelf.quiet.id)])

        let index = app.libraryIndex
        #expect(index.facts(.song(shelf.quiet.id))?.favourite == true)
        #expect(index.tags(on: .songs) == ["after hours"])
        #expect(LibraryQuery(shelf: .songs, text: "hours").run(index).map(\.title) == ["River", "Quiet"], "tags are searched")
        #expect(LibraryQuery(shelf: .songs, favourites: true).run(index).map(\.title) == ["Quiet"])
        #expect(LibraryQuery(shelf: .songs, tag: "AFTER HOURS").run(index).map(\.title) == ["River", "Quiet"])
        #expect(LibraryQuery(shelf: .samples, tag: "dusty").run(index).map(\.title) == ["Drifter hit"], "a sample's own tags count")
        let chop = try #require(index.facts(.sample(shelf.chop.id)))
        #expect(chop.tags == ["dusty"] && chop.markedTags.isEmpty, "its own, not a mark to take off")
    }

    @Test("an item's menu offers its star and its tags, before what cannot be undone")
    func actions() throws {
        let (app, shelf) = LibraryBrowserFixture.app()
        let ids = LibraryActions.actions(for: .record(shelf.drifter.id), in: app).map(\.id)
        #expect(ids == ["start", "add", "adopt", "separate", "read", "grid", "rename", "favourite", "tag", "remove"])
        #expect(LibraryActions.actions(for: .album(shelf.album.id), in: app).map(\.id) == ["open", "rename", "favourite", "tag", "delete"])
    }
}

@Suite("Saved searches") @MainActor
struct SavedSearchTests {

    @Test("a search is kept by name with its words, filters and order, and is one press away")
    func saved() {
        let (app, _) = LibraryBrowserFixture.app()
        let memory = LibraryBrowserMemory.inMemory()
        let model = LibraryBrowserModel(app: app, memory: memory)
        model.choose(.records)
        model.text = "drift"
        model.cycleStems()
        model.sort(by: .tempo)
        #expect(model.saveSearchAction.isEnabled)
        model.saveSearch(named: "  Drums to cut ")
        #expect(model.saved.map(\.name) == ["Drums to cut"])
        #expect(model.appliedSearch?.name == "Drums to cut")

        let again = LibraryBrowserModel(app: app, memory: memory)
        again.choose(.songs)
        let search = again.saved[0]
        again.apply(search)
        #expect(again.shelf == .records && again.query.text == "drift" && again.query.hasStems == true && again.query.sort == .init(.tempo))
        #expect(again.rows.map(\.title) == ["Drifter"])
        again.saveSearch(named: "drums to CUT")
        #expect(again.saved.count == 1, "the same name, replaced")
        again.forget(again.saved[0])
        #expect(LibraryBrowserModel(app: app, memory: memory).saved.isEmpty)
        #expect(LibrarySurfaceView.describe(search.query) == "“drift” · with stems · by tempo")
    }
}

@Suite("Choosing several", .serialized) @MainActor
struct LibraryBatchTests {

    @Test("⌘ adds and takes away, ⇧ runs from the last chosen, ⌘A takes everything showing")
    func choosing() {
        let (app, shelf) = LibraryBrowserFixture.app()
        let model = LibraryBrowserModel(app: app, memory: .inMemory())
        model.sort(by: .title)    // Café Noir, Night Bus, Quiet, River
        model.select(.song(shelf.nightBus.id))
        #expect(!model.isBatch)
        model.toggleChoice(.song(shelf.river.id))
        #expect(model.isBatch && model.chosenRows.map(\.title) == ["Night Bus", "River"])
        #expect(model.selection == .song(shelf.river.id), "the last chosen is the one ⇧ runs from")
        model.extendChoice(to: .song(shelf.cafe.id))
        #expect(model.chosenRows.map(\.title) == ["Café Noir", "Night Bus", "Quiet", "River"])
        model.toggleChoice(.song(shelf.quiet.id))
        #expect(model.chosenRows.map(\.title) == ["Café Noir", "Night Bus", "River"])
        model.select(.song(shelf.quiet.id))
        #expect(!model.isBatch && model.chosenRows.map(\.title) == ["Quiet"])
        model.text = "n"
        model.chooseAll()
        #expect(model.chosenRows.map(\.title) == model.rows.map(\.title) && model.isBatch)
        model.choose(.records)
        #expect(!model.isBatch, "each shelf its own")
    }

    @Test("each shelf's batch, with how many said in what is asked first")
    func actions() {
        let (app, shelf) = LibraryBrowserFixture.app()
        let work = LibraryBatchWork(app: app)
        func ids(_ items: [LibraryItemID]) -> [String] { LibraryActions.batch(items, in: app, work: work).map(\.id) }
        let songs: [LibraryItemID] = [.song(shelf.nightBus.id), .song(shelf.river.id)]
        #expect(ids(songs) == ["album", "export", "favourite", "tag", "trash"])
        #expect(ids([.record(shelf.drifter.id), .record(shelf.brass.id)]) == ["separate", "read", "favourite", "tag", "remove"])
        #expect(ids([.idea(shelf.idea.id)]) == ["adopt", "favourite", "tag", "remove"])
        #expect(ids([.album(shelf.album.id)]) == ["favourite", "tag", "delete"])
        let trash = LibraryActions.batch(songs, in: app, work: work).first { $0.id == "trash" }
        if case .confirm(let question, let detail, let verb, _)? = trash?.kind {
            #expect(question == "Move 2 songs to the Trash?" && verb == "Move to Trash")
            #expect(detail.contains("where Finder can put them back"))
        } else {
            Issue.record("a batch to the Trash asks first")
        }
        let export = LibraryActions.batch(songs, in: app, work: work).first { $0.id == "export" }
        #expect(export?.isEnabled == false, "no library folder to export from")
    }

    @Test("records removed together, songs added to an album together, each written once")
    func performing() throws {
        let (app, shelf, directory) = try LibraryBrowserFixture.stored("batch-perform")
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = LibraryBatchWork(app: app)
        let records: [LibraryItemID] = [.record(shelf.drifter.id), .record(shelf.brass.id)]
        for action in LibraryActions.batch(records, in: app, work: work) where action.id == "remove" {
            if case .confirm(_, _, _, let run) = action.kind { run() }
        }
        #expect(app.library.records.map(\.title) == ["Ferry Bells"])

        let other = try #require(app.createAlbum(title: "Night drives"))
        let songs: [LibraryItemID] = [.song(shelf.river.id), .song(shelf.cafe.id)]
        for action in LibraryActions.batch(songs, in: app, work: work) where action.id == "album" {
            if case .menu(let albums) = action.kind, let pick = albums.first(where: { $0.title == "Night drives" }), case .run(let run) = pick.kind { run() }
        }
        #expect(app.library.album(other)?.songs == [shelf.river.id, shelf.cafe.id])
        #expect(try LibraryStore(directoryURL: directory).loadDocumentOnly().album(other)?.songs.count == 2)
    }

    @Test("a crate batch queues each record once, and each failure is said against its record")
    func crate() async throws {
        let (app, shelf, directory) = try LibraryBrowserFixture.stored("batch-crate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = LibraryBatchWork(app: app)
        let records: [LibraryItemID] = [.record(shelf.drifter.id), .record(shelf.brass.id)]
        let separate = try #require(LibraryActions.batch(records, in: app, work: work).first { $0.id == "separate" })
        if case .run(let run) = separate.kind { run(); run() }
        await app.crate.waitUntilIdle()
        #expect(app.crate.finished.filter { $0.kind == .separate }.compactMap(\.record).sorted() == [shelf.drifter.id, shelf.brass.id].sorted(),
                "once each, asked twice")
        // Neither record's audio is in the fixture's folder: each fails, each on its own row.
        #expect(app.crate.failures[shelf.drifter.id] != nil && app.crate.failures[shelf.brass.id] != nil)
        #expect(app.crate.failures[shelf.ferry.id] == nil)
    }

    @Test("several masters exported one after another, each into its own folder")
    func export() async throws {
        let directory = try BatchFixture.directory("export")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory.appendingPathComponent("Library", isDirectory: true))
        var first = ListeningFixture.grooveSong()
        first.title = "First"
        var second = ListeningFixture.grooveSong()
        second.title = "Second"
        let silent = Song(title: "Nothing yet")
        try store.save(Library(songs: [first, second, silent]))
        let app = AppState(library: try store.load(), song: nil, store: store, status: .loaded(store.directoryURL), transportHost: StubTransportHost())
        app.autosaveDelay = nil
        let work = LibraryBatchWork(app: app)
        work.directory = { directory.appendingPathComponent("Exports/\($0.title)", isDirectory: true) }
        work.exportMasters([first.id, silent.id, second.id])
        #expect(work.isRunning)
        await work.finish()
        #expect(!work.isRunning && work.line == nil)
        #expect(work.exported[first.id]?.lastPathComponent == "First — master.wav")
        #expect(work.exported[second.id].map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(work.failures[silent.id] != nil && work.exported[silent.id] == nil, "said against that song, and the rest went on")
    }
}
