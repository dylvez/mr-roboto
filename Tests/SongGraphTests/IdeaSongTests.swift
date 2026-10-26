import Foundation
import Testing
@testable import SongGraph

// Ideas you open: a song package flagged `idea`, kept apart from the songs wherever the library
// lists them, and found by id as a song is.

@Suite("Ideas: packages of their own, kept apart from the songs")
struct IdeaSongTests {

    private func idea(_ title: String) -> Song {
        var idea = Song(title: title, key: Fixtures.dMajor, tempo: 92,
                        sections: [Section(name: "Idea", stitch: [], lengthInBars: 4)])
        idea.idea = true
        return idea
    }

    @Test("a song writes no idea field, so every song from before reads and writes back byte for byte; an idea keeps its flag")
    func roundTrip() throws {
        let song = Song(title: "Arrival", key: Fixtures.dMajor, tempo: 113)
        let encoded = try SongGraphCodec.encode(song)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"idea\""))
        let decoded = try SongGraphCodec.decode(Song.self, from: encoded)
        #expect(!decoded.isIdea)
        #expect(try SongGraphCodec.encode(decoded) == encoded, "byte for byte")

        let back = try SongGraphCodec.decode(Song.self, from: try SongGraphCodec.encode(idea("Hum")))
        #expect(back.isIdea && back.idea == true)
    }

    @Test("the library files an idea with the ideas and a song with the songs, finds either by id, and moves one that changes")
    func routing() {
        var library = Library()
        let song = Song(title: "Arrival")
        var hum = idea("Hum")
        library.upsert(song)
        library.upsert(hum)
        #expect(library.songs.map(\.id) == [song.id])
        #expect(library.ideaSongs.map(\.id) == [hum.id])
        #expect(library.song(hum.id)?.title == "Hum")
        #expect(library.song(song.id)?.title == "Arrival")

        hum.title = "Morning hum"
        library.upsert(hum)
        #expect(library.ideaSongs.count == 1 && library.ideaSongs[0].title == "Morning hum")

        // An idea that became a song leaves the ideas.
        hum.idea = nil
        library.upsert(hum)
        #expect(library.ideaSongs.isEmpty && library.songs.count == 2)

        library.removeSong(hum.id)
        library.removeSong(song.id)
        #expect(library.songs.isEmpty && library.ideaSongs.isEmpty)
    }

    @Test("a library encoded before ideas could be opened decodes with none, and one with none encodes as before")
    func libraryCoding() throws {
        var library = Library(songs: [Song(title: "Arrival")])
        let encoded = try SongGraphCodec.encode(library)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ideaSongs"))
        let decoded = try SongGraphCodec.decode(Library.self, from: encoded)
        #expect(decoded.ideaSongs.isEmpty && decoded.songs.count == 1)

        library.upsert(idea("Hum"))
        let back = try SongGraphCodec.decode(Library.self, from: try SongGraphCodec.encode(library))
        #expect(back.ideaSongs.map(\.title) == ["Hum"] && back.songs.map(\.title) == ["Arrival"])
    }

    @Test("the store writes an idea into a package and library.json like a song, and reads it back as an idea")
    func store() throws {
        let root = try Fixtures.temporaryDirectory("idea-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directoryURL: root)
        var library = Library(songs: [Song(title: "Arrival")])
        library.upsert(idea("Hum"))
        try store.save(library)

        let packages = try store.songStores().map(\.packageURL.lastPathComponent).sorted()
        #expect(packages == ["Arrival.roboto", "Hum.roboto"])
        let document = String(decoding: try Data(contentsOf: store.documentURL), as: UTF8.self)
        #expect(document.contains("Hum.roboto"), "listed as every package is")

        let loaded = try store.load()
        #expect(loaded.songs.map(\.title) == ["Arrival"])
        #expect(loaded.ideaSongs.map(\.title) == ["Hum"])
        #expect(loaded.ideaSongs.first?.isIdea == true)

        // A write of library.json alone keeps listing it.
        try store.saveDocument(loaded)
        #expect(try store.load().ideaSongs.map(\.title) == ["Hum"])
    }
}
