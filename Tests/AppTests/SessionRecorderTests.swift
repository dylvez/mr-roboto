import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// What was said and done is on disk, and a reopened song is not a blank conversation.

@Suite("Sessions: the rail and the tool calls, kept", .serialized) @MainActor
struct SessionRecorderTests {

    @Test("every rail entry and tool call is a line in the day's file, with the song it was about")
    func recorded() throws {
        let directory = WiringFixture.temporaryDirectory("sessions")
        defer { WiringFixture.remove(directory) }
        let song = FormFixture.build(tempo: 100).song
        let app = BandFixture.app(in: directory, song: song)
        let recorder = try #require(app.sessions)
        app.note(.you, "three bars of a Latin swing beat at 120", detail: "to Beatmaker only")
        app.recordTool("write_groove", failed: false, message: "3 bars from Son Clave 3-2")
        app.recordTool("import_record", failed: true, message: "no file named")
        app.note(.director, "Three bars are down and playing.")
        app.note(.persona("Bassist"), "24 kicks and nothing under them.", detail: "bassist.kick-coverage")

        let records = recorder.records(forSong: song.id.description)
        #expect(records.map(\.who) == ["you", "tool", "tool", "director", "Bassist"])
        #expect(records[0].text == "three bars of a Latin swing beat at 120" && records[0].detail == "to Beatmaker only" && records[0].song == song.title)
        #expect(records[2].text == "import_record failed" && records[2].detail == "no file named")
        let file = recorder.file()
        #expect(FileManager.default.fileExists(atPath: file.path) && file.lastPathComponent.hasSuffix(".jsonl"))
        #expect(file.deletingLastPathComponent().lastPathComponent == "sessions")
        #expect(recorder.records(forSong: "someone-else").isEmpty)
    }

    @Test("opening a song in a fresh launch puts what was said about it back in the rail, marked as earlier, without the tool lines")
    func restored() throws {
        let directory = WiringFixture.temporaryDirectory("sessions-restore")
        defer { WiringFixture.remove(directory) }
        let song = FormFixture.build(tempo: 100).song
        let first = BandFixture.app(in: directory, song: song)
        first.note(.you, "make the hats busier")
        first.recordTool("set_velocity", failed: false, message: "")
        first.note(.director, "Hats are doubled in bar 2.")
        first.sessions?.flush()

        // A new launch: an app with nothing in its rail, opening the same song.
        let second = AppState(library: Library(songs: [song]), song: nil, store: LibraryStore(directoryURL: directory), transportHost: StubTransportHost())
        #expect(second.log.isEmpty)
        second.open(song)
        let texts = second.log.map(\.text)
        #expect(Array(texts.prefix(2)) == ["make the hats busier", "Hats are doubled in bar 2."], "\(texts)")
        #expect(texts.contains { $0.hasPrefix("Earlier, up to ") } && texts.contains("Opened \(song.title)"))
        let marker = try #require(texts.firstIndex { $0.hasPrefix("Earlier, up to ") }), opened = try #require(texts.firstIndex(of: "Opened \(song.title)"))
        #expect(marker == 2 && opened > marker, "history, the marker, then today")
        #expect(!texts.contains("set_velocity"), "tool lines are for the file, not the rail")

        // Reopening in the same launch does not pile the history up again.
        second.open(song)
        #expect(second.log.filter { $0.text == "make the hats busier" }.count == 1)
        #expect(second.log.filter { $0.text.hasPrefix("Earlier, up to ") }.count == 1)
    }

    @Test("an app with no library keeps nothing and breaks nothing")
    func noLibrary() {
        let app = AppState(library: Library(), song: Song(title: "Loose"), store: nil, transportHost: StubTransportHost())
        #expect(app.sessions == nil)
        app.note(.you, "hello")
        app.recordTool("read_song", failed: false, message: "")
        #expect(app.log.count == 1)
    }
}
