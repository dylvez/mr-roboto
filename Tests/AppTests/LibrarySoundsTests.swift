import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// What the parts play on, on shelves of their own: the instruments and the kits, heard in place
// and put on a part of the open song; and the band searching the library the way the shelves do.

@Suite("Instruments and kits in the Library", .serialized) @MainActor
struct LibrarySoundsTests {

    @Test("the instruments are listed by family with where each came from, and the kits by kind")
    func shelves() throws {
        let index = LibraryIndex(library: Library(), sounds: .builtIn)
        let instruments = index.items(on: .instruments)
        #expect(instruments.count == InstrumentVoiceSpec.all.count + ImportedInstruments.all.count)
        let rhodes = try #require(index.facts(.instrument("rhodes")))
        #expect(rhodes.title == InstrumentVoiceSpec.preset(id: "rhodes")?.name && rhodes.family == "Keys" && rhodes.pack == "Built in")
        #expect(rhodes.code == "rhodes" && !rhodes.isImported && rhodes.range == nil)
        let kits = index.items(on: .kits)
        #expect(kits.count == SynthMachine.available.count)
        let tr808 = try #require(index.facts(.kit("tr808")))
        #expect(tr808.family == "Drum machines" && tr808.title == "TR-808" && tr808.note?.isEmpty == false)
        #expect(index.facts(.kit("jazz"))?.family == "Acoustic kits")
        #expect(LibraryItemID.instrument("rhodes") == LibraryItemID.instrument("rhodes"), "the same item every launch")
        #expect(LibraryItemID.instrument("rhodes") != LibraryItemID.kit("rhodes"))
        #expect(LibraryQuery(shelf: .instruments, text: "keys built in").run(index).contains { $0.code == "rhodes" })
        #expect(LibraryQuery(shelf: .kits, text: "acoustic").run(index).map(\.code).contains("jazz"))
        #expect(LibraryIndex.sfz(in: "Sampled, from Alto Recorder.sfz: 12 zones from 12 recordings, E♭4–A6.") == "Alto Recorder.sfz")
    }

    @Test("an instrument plays the song's chords and tune, or one part; a kit the drums, or one groove")
    func use() throws {
        var song = Song(title: "Night Bus", key: Key(parsing: "C major"), tempo: 92)
        let chords = TransportFixture.progressionVersion()
        let groove = TransportFixture.grooveVersion()
        try song.append(chords)
        try song.append(groove)
        let app = AppState(library: Library(songs: [song]), song: song, transportHost: StubTransportHost())
        app.autosaveDelay = nil
        func actions(_ item: LibraryItemID) -> [LibraryAction] { LibraryActions.actions(for: item, in: app) }
        #expect(actions(.instrument("rhodes")).map(\.id) == ["use", "use-on", "favourite", "tag"], "a built-in one cannot be removed")
        #expect(LibraryActions.primary(for: .kit("tr909"), in: app)?.id == "use")

        if case .run(let run)? = actions(.instrument("wurlitzer")).first(where: { $0.id == "use" })?.kind { run() }
        #expect(SongPlayback.instrumentID(for: nil, in: app.song!) == "wurlitzer")
        let onePart = actions(.instrument("rhodes")).first { $0.id == "use-on" }
        if case .menu(let parts)? = onePart?.kind {
            #expect(parts.map(\.title) == [PartLabel.title(of: chords)])
            if case .run(let run)? = parts.first?.kind { run() }
        }
        #expect(SongPlayback.instrumentID(for: chords.partID, in: app.song!) == "rhodes")
        #expect(LibrarySurfaceView.parts(playing: "rhodes", shelf: .instruments, in: app.song!) == [PartLabel.title(of: chords)])

        if case .run(let run)? = actions(.kit("tr909")).first(where: { $0.id == "use" })?.kind { run() }
        #expect(SongPlayback.drumSoundID(for: groove.partID, in: app.song!) == "tr909")
        #expect(LibrarySurfaceView.parts(playing: "tr909", shelf: .kits, in: app.song!) == [PartLabel.title(of: groove)])

        let closed = AppState(transportHost: StubTransportHost())
        #expect(LibraryActions.actions(for: .instrument("rhodes"), in: closed).first?.isEnabled == false, "no song to play it in")
    }

    @Test("a shelf of sounds offers its imports and the percussion switch, and keeps its marks")
    func shelfActions() throws {
        let app = AppState(transportHost: StubTransportHost())
        #expect(LibraryActions.shelf(.instruments, in: app).map(\.id) == ["import-instrument"])
        #expect(LibraryActions.shelf(.kits, in: app).map(\.id) == ["import-kit", "import-percussion"])
        let (stored, _, directory) = try LibraryBrowserFixture.stored("sounds-marks")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(stored.setFavourite(true, for: [.instrument("rhodes"), .kit("tr808")]))
        #expect(stored.library.mark(.instrument, LibraryItemID.instrument("rhodes").id)?.isFavourite == true)
        let index = stored.libraryIndex
        #expect(LibraryQuery(shelf: .instruments, favourites: true).run(index).map(\.code) == ["rhodes"])
        #expect(LibraryQuery(shelf: .kits, favourites: true).run(index).map(\.code) == ["tr808"])
    }

    @Test("an instrument is heard by a phrase that suits it, a kit by a groove, both under the Library's name")
    func heard() async throws {
        let app = AppState(transportHost: StubTransportHost())
        let host = StubListening()
        let model = LibraryBrowserModel(app: app, memory: .inMemory(), listening: host)
        await model.preview.play(.instrument("rhodes"))
        #expect(host.phrases.last?.instrument == "rhodes" && (host.phrases.last?.notes.count ?? 0) > 8, "chords, for keys")
        #expect(model.preview.isSounding(.instrument("rhodes")))
        await model.preview.play(.kit("linn"))
        #expect(host.grooves.last?.machine == "linn" && host.grooves.last?.tempo == LibraryPhrases.grooveTempo)
        #expect(model.preview.isSounding(.kit("linn")) && !model.preview.isSounding(.instrument("rhodes")))

        // A tune moved by octaves into what a recording reaches.
        let tune = [60, 64, 67, 72].map { NoteEvent(pitch: Pitch(midi: $0), start: 0, duration: 1) }
        #expect(LibraryPhrases.fitted(tune, into: 36...55).map(\.pitch.midi) == [36, 40, 43, 48])
        #expect(LibraryPhrases.fitted(tune, into: 55...90).map(\.pitch.midi) == [60, 64, 67, 72], "already inside: left")
    }
}

@Suite("The band searches the library") @MainActor
struct ReadLibrarySearchTests {

    private func run(_ app: AppState, _ fields: [(String, DirectorJSON)]) async -> [String: Any] {
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        let result = await toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object(DirectorJSONObject(fields.map { .init($0.0, $0.1) }))))
        return (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? ["error": result.content]
    }

    private func titles(_ read: [String: Any], _ list: String, _ field: String = "title") -> [String] {
        (read[list] as? [[String: Any]] ?? []).compactMap { $0[field] as? String }
    }

    private static let empty: [(String, DirectorJSON)] = [
        ("shelf", .string("")), ("words", .string("")), ("key", .string("")), ("within", .int(0)),
        ("tempo", .double(0)), ("goes_with_song", .bool(false)), ("show", .bool(false)),
    ]

    private func with(_ changes: [(String, DirectorJSON)]) -> [(String, DirectorJSON)] {
        Self.empty.map { field in changes.first { $0.0 == field.0 } ?? field }
    }

    @Test("every field empty is the whole library, as before")
    func everything() async {
        let (app, _) = LibraryBrowserFixture.app(open: { $0.nightBus })
        let read = await run(app, Self.empty)
        #expect(titles(read, "records") == ["Drifter", "Ferry Bells", "Brass Band 78"])
        #expect(titles(read, "songs").count == 4 && titles(read, "samples", "name") == ["Drifter hit"])
        let none = await run(app, [])
        #expect(titles(none, "records").count == 3, "an older call with no fields at all still reads everything")
    }

    @Test("a key, a tempo and a shelf narrow it as the Library would, and say what was searched")
    func narrowed() async {
        let (app, _) = LibraryBrowserFixture.app(open: { $0.nightBus })
        let minor = await run(app, with([("key", .string("C major")), ("within", .int(2))]))
        #expect(titles(minor, "records") == ["Brass Band 78"], "A minor is C major's relative; D minor is five off")
        #expect(titles(minor, "songs") == ["Night Bus", "River"], "B minor is two down")
        let tempo = await run(app, with([("shelf", .string("songs")), ("tempo", .double(85))]))
        #expect(titles(tempo, "songs") == ["Night Bus", "River", "Café Noir"], "River at 170 is 85 at half time")
        #expect(titles(tempo, "records").isEmpty, "one shelf asked for, one shelf answered")
        #expect((tempo["detail"] as? String)?.contains("Searched the songs for") == true)
        let words = await run(app, with([("words", .string("tides"))]))
        #expect(titles(words, "records") == ["Drifter"] && titles(words, "songs").isEmpty)
    }

    @Test("what goes with the open song, nearest first, each saying how it would come in")
    func goesWith() async {
        let (app, _) = LibraryBrowserFixture.app(open: { $0.nightBus })
        let read = await run(app, with([("goes_with_song", .bool(true))]))
        #expect(titles(read, "records") == ["Brass Band 78"])
        let all = await run(app, Self.empty)
        let drifter = (all["records"] as? [[String: Any]])?.first { $0["title"] as? String == "Drifter" }
        #expect((drifter?["fit"] as? String)?.hasPrefix("far: The record of Drifter down 5 semitones to A minor") == true)
        let closed = await run(LibraryBrowserFixture.app().app, with([("goes_with_song", .bool(true))]))
        #expect(titles(closed, "records").count == 3, "no song open: nothing held back")
        #expect((closed["detail"] as? String)?.contains("No song is open, so nothing is held back") == true)
    }

    @Test("show opens the Library on the same search; a key it cannot read is said")
    func show() async {
        let (app, _) = LibraryBrowserFixture.app(open: { $0.nightBus })
        let read = await run(app, with([("key", .string("A minor")), ("show", .bool(true))]))
        #expect(app.bench.active?.kind == .library)
        #expect(app.libraryQueryAsk?.shelf == .records && app.libraryQueryAsk?.key?.key == Key(parsing: "A minor"))
        #expect((read["detail"] as? String)?.contains("The Library is open on the records it found") == true)
        let model = LibraryBrowserModel(app: app, memory: .inMemory())
        #expect(model.shelf == .records && model.rows.map(\.title) == ["Brass Band 78"] && app.libraryQueryAsk == nil)
        let wrong = await run(app, with([("key", .string("H major"))]))
        #expect((wrong["error"] as? String)?.contains("is not a key") == true || String(describing: wrong).contains("is not a key"))
    }
}
