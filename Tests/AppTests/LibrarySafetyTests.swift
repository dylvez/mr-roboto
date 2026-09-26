import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// From an audit of saving and the library: the ways a library could lose work, each fixed.

private func scratch(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-safety-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func song(_ title: String, versions: Int = 1) -> Song {
    var song = Song(title: title, tempo: 92)
    for _ in 0..<versions { try? song.append(TransportFixture.grooveVersion()) }
    return song
}

@Suite("The library keeps what it holds", .serialized) @MainActor
struct LibrarySafetyTests {

    @Test("a song titled like another but for case gets its own package, not the other's")
    func caseInsensitiveNames() throws {
        let directory = scratch("case")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let demo = song("Demo", versions: 5)
        try store.save(Library(songs: [demo]))
        let lower = song("demo")
        try store.save(Library(songs: [demo, lower]))
        let reloaded = try store.load()
        #expect(reloaded.songs.count == 2)
        #expect(reloaded.song(demo.id)?.versions.count == 5, "Demo is intact")
        #expect(try store.songStores().count == 2)
        // And one saved on its own, the way an import saves.
        try store.saveSong(song("DEMO"))
        #expect(try store.load().songs.count == 3)
    }

    @Test("a package this build cannot read is left alone, and every other song, album and record still loads")
    func unreadablePackage() throws {
        let directory = scratch("unreadable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let kept = song("Kept"), broken = song("Broken")
        var library = Library(songs: [kept, broken])
        library.albums = [Album(title: "Precious", songs: [kept.id, broken.id])]
        try store.save(library)
        let brokenFile = try store.songStore(for: broken.id).documentURL
        try Data("not a song".utf8).write(to: brokenFile)

        let (loaded, unreadable) = try store.loadReporting()
        #expect(loaded.songs.map(\.id) == [kept.id])
        #expect(unreadable.map(\.package) == ["Broken.roboto"])
        #expect(loaded.albums.first?.title == "Precious", "the album survives")

        // Saved back from what loaded: the album and the unreadable package are both still there.
        try store.save(loaded)
        #expect(try String(contentsOf: brokenFile, encoding: .utf8) == "not a song", "never written over")
        #expect(try store.loadReporting().library.albums.first?.songs == [kept.id, broken.id])
    }

    @Test("with library.json unreadable, the frame writes nothing to the library but the open song's own package")
    func unreadableLibraryIsNotWritten() throws {
        let directory = scratch("no-document")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        var library = Library(songs: [song("Arrival")])
        library.albums = [Album(title: "Precious", songs: [])]
        try store.save(library)
        let documentURL = directory.appendingPathComponent("library.json")
        let garbled = Data("{ not json".utf8)
        try garbled.write(to: documentURL)

        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        app.autosaveDelay = nil
        app.reloadLibrary()
        #expect(!app.libraryIsWritable)
        #expect(app.createAlbum(title: "New") == nil)
        #expect(try Data(contentsOf: documentURL) == garbled, "library.json untouched")
    }

    @Test("a title too long for the disk still makes a package that saves")
    func longTitle() throws {
        let directory = scratch("long")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let long = song(String(repeating: "a very long title ", count: 20))
        try store.save(Library(songs: [long]))
        #expect(try store.load().song(long.id) != nil)
        #expect(SongStore.packageName(for: long.title).count <= 130)
    }

    @Test("deleting the open song keeps it open and unsaved-changes intact when the Trash refuses")
    func deleteThatFails() throws {
        let (app, directory, _) = CompletenessFixture.app("delete-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Arrival"))
        app.save()
        #expect(app.setTempo(84))
        struct Refused: Error {}
        app.trash = { _ in throw Refused() }
        #expect(!app.deleteSong(app.song!.id))
        #expect(app.song?.title == "Arrival" && app.song?.tempo == 84 && app.hasUnsavedChanges)
    }
}
