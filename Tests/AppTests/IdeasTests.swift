import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Ideas first, Phase 1: an idea you open — File ▸ New Idea, a package of its own on the Ideas shelf,
// one section that goes round, and never on a list of songs. Demos/plans/ideas-first.md.

@MainActor
enum IdeasFixture {
    /// A frame on a scratch library holding one song, saved; autosave off.
    static func app(_ label: String) throws -> (app: AppState, directory: URL, song: Song) {
        let directory = GuidanceFixture.temporaryDirectory("ideas-\(label)")
        let store = LibraryStore(directoryURL: directory)
        var song = Song(title: "Arrival", key: Key(parsing: "D major"), tempo: 113,
                        sections: [Section(name: "Verse", stitch: [], lengthInBars: 8)])
        let groove = TransportFixture.grooveVersion()
        try song.append(groove)
        song.sections[0].stitch = [Lane(part: groove.partID)]
        try store.save(Library(songs: [song]))
        let app = AppState(library: try store.load(), song: nil, store: store, status: .loaded(directory),
                           transportHost: StubTransportHost())
        app.autosaveDelay = nil
        return (app, directory, song)
    }

    /// A new idea in the frame with a groove in it, saved.
    static func savedIdea(in app: AppState, title: String = "Hum") throws -> SongID {
        let id = app.newIdea()
        app.setTitle(title)
        app.setTempo(92)
        app.record(TransportFixture.grooveVersion())
        app.save()
        return id
    }
}

@Suite("Ideas: one you open, on a shelf of its own") @MainActor
struct IdeasTests {

    @Test("New Idea opens an idea: one section four bars long, no fills, its settings showing, the loop on")
    func newIdea() throws {
        let (app, directory, _) = try IdeasFixture.app("new")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(app.isLooping == false)
        app.newIdea()
        let idea = try #require(app.song)
        #expect(idea.isIdea)
        #expect(idea.title.hasPrefix("Idea, "))
        #expect(idea.sections.count == 1 && idea.sections[0].lengthInBars == Song.startingIdeaBars)
        #expect(idea.sections[0].name == Song.ideaSectionName)
        #expect(!idea.playsFills)
        #expect(app.wantsSongSettings)
        #expect(app.isLooping, "an idea goes round")
        #expect(app.ideaBars == 4)
        #expect(WindowChrome.subtitle(isIdea: true, edited: false) == "Idea")
        #expect(WindowChrome.subtitle(isIdea: true, edited: true) == "Idea · Edited")
        #expect(WindowChrome.subtitle(isIdea: false, edited: true) == "Edited")
    }

    @Test("an idea's length is set in bars, kept in range; a song has none to set")
    func bars() throws {
        let (app, directory, song) = try IdeasFixture.app("bars")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.newIdea()
        #expect(app.setIdeaBars(8))
        #expect(app.song?.sections.first?.lengthInBars == 8)
        #expect(!app.setIdeaBars(8), "no change, no line")
        #expect(app.setIdeaBars(1_000))
        #expect(app.ideaBars == AppState.ideaBarsRange.upperBound)
        app.openSong(song.id)
        #expect(app.ideaBars == nil)
        #expect(!app.setIdeaBars(4))
        #expect(app.song?.sections.first?.lengthInBars == 8)
    }

    @Test("saved, an idea is on the ideas and never on the songs; a song opened after it puts the loop back")
    func kept() throws {
        let (app, directory, song) = try IdeasFixture.app("kept")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try IdeasFixture.savedIdea(in: app)
        #expect(app.library.ideaSongs.map(\.id) == [id])
        #expect(app.library.songs.map(\.id) == [song.id])
        #expect(app.library.song(id)?.title == "Hum")

        let reread = try LibraryStore(directoryURL: directory).load()
        #expect(reread.ideaSongs.map(\.id) == [id] && reread.songs.map(\.id) == [song.id])
        #expect(reread.ideaSongs.first?.tempo == 92)

        app.openSong(song.id)
        #expect(!app.isLooping, "the loop as it was for songs")
        app.openSong(id)
        #expect(app.song?.isIdea == true && app.isLooping)
    }

    @Test("in an idea there is no Structure, Merge or Master: not in the dock, not performed")
    func surfaces() throws {
        let (app, directory, song) = try IdeasFixture.app("surfaces")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Guidance.dockSurfaces(for: app.library.song(song.id)).contains(.structure))
        app.newIdea()
        let dock = Guidance.dockSurfaces(for: app.song)
        #expect(!dock.contains(.structure))
        #expect(dock.contains(.grid) && dock.contains(.booth) && dock.contains(.pianoRoll) && dock.contains(.chords))
        #expect(!app.canPerform(SurfaceAction(surface: .structure, title: "Structure")))
        #expect(!app.canPerform(SurfaceAction(surface: .master, title: "Master")))
        #expect(app.canPerform(SurfaceAction(surface: .grid, title: "New groove")))
    }

    @Test("the Ideas shelf lists an idea with its key, tempo, bars and parts; Open is what a double-click does, and a drag opens it")
    func shelf() throws {
        let (app, directory, song) = try IdeasFixture.app("shelf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try IdeasFixture.savedIdea(in: app)
        app.setKey(Key(parsing: "A minor"))
        app.setIdeaBars(8)
        let index = app.libraryIndex
        let ideas = index.items(on: .ideas)
        let facts = try #require(ideas.first { $0.id == .ideaSong(id) })
        #expect(facts.isIdeaSong)
        #expect(facts.title == "Hum")
        #expect(facts.tempo == 92)
        #expect(facts.bars == 8)
        #expect(facts.key?.name == "A minor")
        #expect(facts.kind == .groove)
        #expect(facts.note?.isEmpty == false)
        #expect(index.isIdeaSong(.ideaSong(id)))
        #expect(!index.items(on: .songs).contains { $0.id.id == id.rawValue }, "never on the songs")
        #expect(index.items(on: .songs).contains { $0.id == .song(song.id) })
        let columns = LibraryColumn.columns(for: .ideas)
        #expect(columns.contains(.tempo) && columns.contains(.bars))

        let actions = LibraryActions.actions(for: .ideaSong(id), in: app).map(\.id)
        #expect(actions.contains("open") && actions.contains("duplicate") && actions.contains("trash"))
        #expect(!actions.contains("album") && !actions.contains("adopt"))
        #expect(LibraryActions.primary(for: .ideaSong(id), in: app)?.id == "open")
        #expect(LibraryActions.shelf(.ideas, in: app).map(\.id) == ["new-idea"])
        #expect(LibrarySurfaceView.payload(for: facts)?.kind == .song)
    }

    @Test("an idea is never a track, nor one of the songs before")
    func notASong() throws {
        let (app, directory, song) = try IdeasFixture.app("not-a-song")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try IdeasFixture.savedIdea(in: app)
        let album = try #require(app.createAlbum(title: "Record"))
        #expect(!app.addSong(id, to: album))
        #expect(app.library.album(album)?.songs.isEmpty == true)
        let open = try #require(app.song)
        #expect(!AlbumSurfaceView.addable(to: try #require(app.library.album(album)), from: app.library, open: open)
            .contains { $0.id == id })
        #expect(app.addSong(song.id, to: album))
        #expect(SongsBefore.of(app.library, besides: nil).entries.allSatisfy { $0.title != "Hum" })
    }

    @Test("a copy of an idea is an idea; one moved to the Trash leaves the shelf")
    func duplicateAndTrash() throws {
        let (app, directory, _) = try IdeasFixture.app("copy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try IdeasFixture.savedIdea(in: app)
        let copy = try #require(app.duplicateSong(id))
        #expect(Set(app.library.ideaSongs.map(\.id)) == [id, copy])
        #expect(app.library.song(copy)?.isIdea == true)
        #expect(app.library.song(copy)?.playsFills == false)
        let bin = GuidanceFixture.temporaryDirectory("ideas-bin")
        defer { try? FileManager.default.removeItem(at: bin) }
        app.trash = { url in
            let moved = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
        #expect(app.deleteSong(copy))
        #expect(app.library.ideaSongs.map(\.id) == [id])
    }

    @Test("with nothing open the band offers to start an idea; in one it offers nothing a song alone has")
    func nextQuestion() throws {
        let (app, directory, _) = try IdeasFixture.app("next")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = NextAdvisor.question(for: app)
        #expect(launch.options.contains { $0.move == .newIdea }, "\(launch.options.map(\.title))")
        #expect(NextMove.newIdea.worksInIdeas && !NextMove.develop.worksInIdeas && !NextMove.exportMaster.worksInIdeas)
        #expect(!NextMove.surface(SurfaceAction(surface: .structure, title: "Structure")).worksInIdeas)

        _ = try IdeasFixture.savedIdea(in: app)
        for option in NextAdvisor.question(for: app).options {
            #expect(option.move.worksInIdeas, "\(option.title)")
        }
    }
}
