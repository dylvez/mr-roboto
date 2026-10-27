import AudioEngine
import Foundation
import Instrument
import Analysis
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

    @Test("the Ideas shelf lists an idea with its key, tempo, bars and parts; Open is what a double-click does, and a drag carries it as an idea")
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
        #expect(LibrarySurfaceView.payload(for: facts)?.kind == .idea, "dropped on a song it goes in it; with none open, it opens")
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
        #expect(NextMove.newIdea.worksInIdeas && NextMove.develop.worksInIdeas && !NextMove.exportMaster.worksInIdeas)
        #expect(!NextMove.putBackDevelopment.worksInIdeas)
        #expect(!NextMove.surface(SurfaceAction(surface: .structure, title: "Structure")).worksInIdeas)

        _ = try IdeasFixture.savedIdea(in: app)
        for option in NextAdvisor.question(for: app).options {
            #expect(option.move.worksInIdeas, "\(option.title)")
        }
    }
}

// Ideas first, Phase 2: making things in an idea — it grows to hold a longer part or a take sung
// past its end, a take runs on with the idea going round under it, the band knows where it is, and
// developing one makes a song of it.

@Suite("Ideas: making things in one") @MainActor
struct IdeaMakingTests {

    private func melody(toBeat end: Double) -> PartVersion {
        TransportFixture.melodyVersion(Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1),
                                                      NoteEvent(pitch: Pitch(midi: 74), start: end - 1, duration: 1)]))
    }

    private func take(at offset: Double, seconds: Double) -> PartVersion {
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "a", count: 64))!, fileExtension: "wav"),
                          role: .take, sampleRate: 48_000, channelCount: 1, duration: seconds, alignmentOffset: offset)
        return PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded)
    }

    @Test("how many bars a part fills: a written part's own length, a groove's bars, a recording's last second")
    func barsHolding() {
        let song = Song(title: "Clock", tempo: 120)  // two seconds a bar
        #expect(song.bars(holding: TransportFixture.progressionVersion()) == 4)
        #expect(song.bars(holding: melody(toBeat: 30)) == 8)
        #expect(song.bars(holding: TransportFixture.grooveVersion(TransportFixture.groove(bars: 2))) == 2)
        #expect(song.bars(holding: take(at: 1, seconds: 9)) == 5)
        #expect(song.bars(holding: take(at: 0, seconds: 8.01)) == 4, "a hair into the next bar is not a bar sung")
        let words = PartVersion(partID: PartID(), kind: .lyric(Lyric(lines: [])), author: .user, operation: Operation.written)
        #expect(song.bars(holding: words) == nil)
    }

    @Test("an idea grows to hold a longer line or a take sung past its end, never shrinks, and a song's form is left alone")
    func grows() throws {
        let (app, directory, song) = try IdeasFixture.app("grows")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.newIdea()
        app.setTempo(120)
        #expect(app.record(TransportFixture.progressionVersion()))
        #expect(app.ideaBars == 4)
        #expect(app.record(melody(toBeat: 30)))
        #expect(app.ideaBars == 8)
        #expect(app.log.contains { $0.text == "The idea grew to 8 bars" })
        #expect(app.record(TransportFixture.grooveVersion(TransportFixture.groove(bars: 2))))
        #expect(app.ideaBars == 8, "never shorter")
        #expect(app.record(take(at: 0.1, seconds: 19.5)))
        #expect(app.ideaBars == 10)
        #expect(app.song?.sections.count == 1)

        app.openSong(song.id)
        #expect(app.record(melody(toBeat: 64)))
        #expect(app.song?.sections.map(\.lengthInBars) == [8], "a song's sections are its form")
    }

    @Test("a counted-in run in an idea plays it as a long section, the click going on past its last bar; a plain play loops it")
    func runway() async throws {
        let (app, directory, _) = try IdeasFixture.app("runway")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.newIdea()
        #expect(app.ideaTakePlan()?.lengthInBars == 64, "an empty idea still has a click to sing to")
        app.record(TransportFixture.grooveVersion())
        #expect(AppState.ideaRunwayBars(for: 4) == 64 && AppState.ideaRunwayBars(for: 40) == 80 && AppState.ideaRunwayBars(for: 200) == 256)

        await app.startTransport(fromBar: 0, countIn: 1, click: true)
        let take = try #require(await host.began.last)
        #expect(take.countInBars == 1 && take.lengthInBars == 65 && !take.loops)
        #expect(take.segments.first?.lengthInBars == 64 && take.segments.first?.startBar == 1)
        await app.stopTransport()

        await app.startTransport(fromBar: 0)
        let played = try #require(await host.began.last)
        #expect(played.loops && played.lengthInBars == 4, "the idea goes round at its own length")
        await app.stopTransport()
    }

    @Test("on the offline engine the idea's parts go on past its last bar on the take's run")
    func runwaySounds() async throws {
        let (app, directory, _) = try IdeasFixture.app("runway-sounds")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.newIdea()
        app.setTempo(180)
        app.record(TransportFixture.grooveVersion())
        var plan = try #require(app.ideaTakePlan())
        // Eight bars of the run are enough to hear past the idea's fourth.
        plan.segments[0].lengthInBars = 8
        plan.lengthInBars = 8
        let stems = try await SectionBounce.render(plan, kitsDirectory: directory.appendingPathComponent("kits"), onlyTheMix: true)
        let samples = stems.mix.first ?? []
        let barFrames = Int(stems.sampleRate * 4 * 60 / 180)
        #expect(samples.count >= 8 * barFrames - barFrames / 4)
        let past = samples[(5 * barFrames)..<min(samples.count, 7 * barFrames)]
        #expect(past.contains { abs($0) > 0.001 }, "bars 6 and 7 sound")
    }

    @Test("the Booth in an idea: counted in, clicked, no punch-out and no passes; in a song, as it was left")
    func booth() throws {
        var idea = Song.newIdea(title: "Hum")
        try idea.append(TransportFixture.grooveVersion())
        let model = BoothModel(host: StubBoothHost(song: idea))
        #expect(model.isIdea)
        #expect(model.countInBars >= 1 && model.click && !model.punchesOut && !model.keepsGoing)
        let song = BoothModel(host: StubBoothHost(song: Song(title: "Arrival", sections: [Section(name: "Verse", stitch: [], lengthInBars: 8)])))
        #expect(!song.isIdea && song.punchesOut)
    }

    @Test("developing an idea makes a song of it, developed and open, and leaves the idea as it was on its shelf")
    func develop() throws {
        let (app, directory, _) = try IdeasFixture.app("develop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try IdeasFixture.savedIdea(in: app)
        app.record(TransportFixture.progressionVersion())
        app.save()
        let before = try #require(app.library.song(id))
        #expect(app.canDevelop)
        let development = app.develop()
        #expect(development != nil)
        let made = try #require(app.song)
        #expect(made.id != id && !made.isIdea && made.title == "Hum")
        #expect(made.sections.count > 1, "a form of its own")
        #expect(app.library.songs.contains { $0.id == made.id })
        let idea = try #require(app.library.song(id))
        #expect(idea.isIdea && idea.sections == before.sections && idea.versions == before.versions)
        #expect(app.log.contains { $0.text == "Made a song of the idea Hum" })
    }

    @Test("an idea has no form to arrange: one section stays one, by hand or by the band")
    func noForm() throws {
        let (app, directory, _) = try IdeasFixture.app("no-form")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try IdeasFixture.savedIdea(in: app)
        let one = try #require(app.song?.sections.first)
        #expect(!app.arrange([one, Section(name: "Hook", stitch: one.stitch, lengthInBars: 4)]))
        #expect(app.song?.sections.count == 1)
        var longer = one
        longer.lengthInBars = 6
        #expect(app.arrange([longer]), "its one section can still change")
    }

    @Test("the band reads an idea as one, is refused the form and the master there, and may stitch its one section")
    func band() async throws {
        let (app, directory, _) = try IdeasFixture.app("band")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try IdeasFixture.savedIdea(in: app)
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func run(_ name: String, _ input: [(String, DirectorJSON)]) async -> ClaudeToolResult {
            await toolbox.run(ClaudeToolUse(id: name, name: name,
                                            input: .object(DirectorJSONObject(input.map { DirectorJSONObject.Member($0.0, $0.1) }))))
        }
        let read = await run("read_song", [])
        let song = try #require(try JSONSerialization.jsonObject(with: Data(read.content.utf8)) as? [String: Any])
        #expect(song["is_idea"] as? Bool == true)
        #expect((song["note"] as? String)?.contains("This is an idea, not a song") == true)

        let section = try #require(app.song?.sections.first)
        let refused = [
            await run("arrange", [("form", .string("Verse 8, Hook 8"))]),
            await run("split_section", [("section", .string(section.id.description)), ("after_bar", .int(2))]),
            await run("stitch_section", [("name", .string("Hook")), ("bars", .int(4)), ("versions", .array([])),
                                         ("position", .int(1)), ("section", .string(""))]),
            await run("master", [("target_lufs", .double(-14)), ("ceiling_dbtp", .double(-1)), ("gain_db", .double(0)),
                                 ("reason", .string("loud enough"))]),
        ]
        for result in refused {
            #expect(result.isError && result.content.contains("This is an idea"), "\(result.content)")
        }
        #expect(app.song?.sections.count == 1)
        #expect(DirectorPrompt.system.contains("read_song says is_idea"))
    }

    @Test("in an idea the band's suggestions and a part's line say the idea, not the song")
    func wording() throws {
        let (app, directory, _) = try IdeasFixture.app("wording")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try IdeasFixture.savedIdea(in: app)
        let groove = try #require(app.song?.versions.last)
        #expect(app.audibility(of: groove.partID) == .plays("in the idea"))
        let proposals = Guidance.proposals(for: try #require(app.song))
        let sing = proposals.first { $0.title.hasPrefix("Sing over") }
        #expect(sing?.rationale.contains("the idea grows to hold the take") == true)
        let words = proposals.first { $0.title == "Write the words" }
        #expect(words?.rationale.contains("[Verse]") == false)
    }
}

@Suite("Ideas: from elsewhere", .serialized) @MainActor
struct IdeasFromElsewhereTests {

    /// Six seconds of tone where `name` puts it.
    private static func tone(_ name: String, in directory: URL, seconds: Double = 6) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try BoothAdapter.write([(0..<Int(seconds * 48_000)).map { Float(0.3 * sin(Double($0) * 0.05)) }], sampleRate: 48_000, to: file)
        return file
    }

    /// A hum as the crate reads it: 100 bpm in D major, its first downbeat 0.9 s in, after a pickup.
    private static func pickupReport(path: String, duration: Double) -> AnalysisReport {
        var report = ImportKeepFixture.report(path: path, duration: duration, bpm: 100)
        let beats = Array(stride(from: 0.3, to: duration, by: 0.6))
        report.beats = BeatTrackingResult(beats: beats, downbeats: beats.enumerated().filter { ($0.offset - 1) % 4 == 0 }.map(\.element), bpm: 100)
        return report
    }

    @Test("a part kept as an idea is an idea of its own: the song's grid, the longest section it plays in, its machine; the song untouched")
    func keepPart() throws {
        let (app, directory, song) = try IdeasFixture.app("keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        let groove = try #require(app.song?.versions.first { $0.type == .groove })
        #expect(app.setMachine(SynthMachine.tr909.id, for: groove.partID))
        app.save()
        let before = try #require(app.song)

        let id = try #require(app.keepAsIdea(groove.id))
        #expect(app.song == before && !app.hasUnsavedChanges, "the song stays open as it was")
        let idea = try #require(app.library.song(id))
        #expect(idea.isIdea && app.library.ideaSongs.map(\.id) == [id] && app.library.songs.map(\.id) == [song.id])
        #expect(idea.title == "\(PartLabel.title(of: groove)) from Arrival")
        #expect(idea.tempo == 113 && idea.key == song.key && idea.timeSignature == song.timeSignature && idea.gridChosen == true)
        #expect(idea.sections.count == 1 && idea.sections[0].lengthInBars == 8, "as long as the verse it plays in")
        let kept = try #require(idea.versions.first { $0.type == .groove })
        #expect(kept.kind == groove.kind && kept.partID != groove.partID && kept.parents.isEmpty)
        #expect(idea.sections[0].stitch.contains(part: kept.partID))
        #expect(SongPlayback.machineID(for: kept.partID, in: idea) == SynthMachine.tr909.id, "on the machine it played on")
        let loaded = try LibraryStore(directoryURL: directory).load()
        #expect(loaded.ideaSongs.map(\.id) == [id] && loaded.songs.map(\.id) == [song.id], "a package of its own on disk")
        #expect(app.log.last?.text == "Kept \(PartLabel.title(of: groove)) as an idea")

        // A sound is a setting of its song, not an idea.
        let sound = try #require(app.song?.versions.last { $0.type == .sound })
        #expect(app.keepAsIdea(sound.id) == nil)
        #expect(app.library.ideaSongs.count == 1)
    }

    @Test("a take sung to the hook, kept as an idea, begins on the idea's first bar, its audio in the idea's own package")
    func keepTake() throws {
        let (app, directory, song) = try IdeasFixture.app("keep-take")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        var sections = try #require(app.song?.sections)
        sections.append(Section(name: "Hook", stitch: [], lengthInBars: 4))
        app.arrange(sections)
        app.save()
        let hook = sections[1].id
        let media = try #require(app.store).songStore(for: song.id).addMedia(copying: try Self.tone("take.wav", in: directory))
        // Sung to the hook, which starts on bar 9, after a bar's count-in.
        let clock = TransportClock(tempo: 113, timeSignature: .fourFour)
        let take = Take(section: hook, startBar: 8, input: "Mic", pass: 1, sectionStartBar: 8, tempo: 113, meter: .fourFour)
        let sung = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: 48_000, channelCount: 1, duration: 6,
                                                                   alignmentOffset: clock.seconds(forBar: 7), take: take)),
                               author: .user, operation: Operation.recorded, note: "Take 1, Hook")
        #expect(app.record(sung))
        app.save()

        let id = try #require(app.keepAsIdea(sung.id))
        let idea = try #require(app.library.song(id))
        #expect(idea.sections[0].lengthInBars == 4, "as long as the hook it was sung to")
        let kept = try #require(Guidance.takes(in: idea).first)
        let placed = TakePlacement.placement(of: try #require(Guidance.audio(of: kept)), in: idea, clock: clock)
        #expect(abs(placed.take ?? -1) < 1e-9, "the take begins on the idea's first bar")
        #expect(abs(placed.audio + clock.seconds(forBar: 1)) < 1e-9, "its count-in the bar before")
        #expect(try app.store!.songStore(for: id).hasMedia(media), "its audio in the idea's own package")
        app.openSong(id)
        #expect(app.playback.tracks.contains { $0.version == kept.id && $0.startsAt == 0 })
    }

    @Test("a capture comes in as an idea waiting for its reading, and takes the crate's: tempo, key, first downbeat on a bar line, the bars that hold it")
    func captureRead() async throws {
        let (app, directory, _) = try IdeasFixture.app("capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.tone(CaptureName(section: "Beat", stamp: "20261026-120000").fileName(extension: "wav"), in: directory)
        app.crate.host = StubImportHost(library: try #require(app.store), report: Self.pickupReport(path: file.path, duration: 6))
        guard case .idea(let id) = app.importFromInbox(file) else { Issue.record("not an idea"); return }
        let waiting = try #require(app.library.song(id))
        #expect(waiting.isIdea && waiting.title == "Beat from the phone" && app.library.ideas.isEmpty)
        #expect(waiting.captureAwaitingReading != nil && waiting.tempo == Song.startingTempo)
        #expect(waiting.sections[0].lengthInBars == 3, "six seconds at the starting tempo, until it is read")
        #expect(LibraryIndex(library: app.library, openSong: nil, sounds: LibrarySounds()).facts(.ideaSong(id))?.tempo == nil,
                "the shelf shows no tempo it has not read")

        await app.crate.waitUntilIdle()
        let read = try #require(app.library.song(id))
        let reading = try #require(app.library.records.first?.reading)
        #expect(read.captureAwaitingReading == nil && read.gridChosen == true)
        #expect(read.tempo == ((reading.dominantTempo ?? 0) * 10).rounded() / 10 && abs(read.tempo - 100) < 1)
        #expect(read.key == reading.dominantKey)
        #expect(read.versions.contains { $0.type == .analysis })
        // Placed with its first downbeat on a bar line: the pickup in the bar before.
        let placed = try #require(read.versions.last { $0.type == .audio })
        let offset = try #require(Guidance.audio(of: placed)?.alignmentOffset)
        let bar = 4 * 60 / read.tempo
        let first = reading.bars.first?.start ?? reading.downbeats.first ?? 0
        let downbeat = (first + offset) / bar
        #expect(offset > 0 && abs(downbeat - 1) < 1e-6, "on bar 2: \(downbeat)")
        #expect(PartLabel.title(of: placed) == "Beat from the phone")
        #expect(read.sections[0].lengthInBars == Int(((offset + 6) / bar - 0.02).rounded(.up)))
        #expect(try app.store!.songStore(for: id).load().tempo == read.tempo, "written into its package")
        #expect(app.log.contains { $0.text.hasPrefix("Beat from the phone is read: ") })
        #expect(try app.libraryAudio(id: id.description)?.media == Guidance.audio(of: placed)?.media)

        app.openSong(id)
        #expect(!app.wantsSongSettings, "read, it asks for nothing")
        #expect(app.playback.tracks.contains { abs($0.startsAt - offset) < 1e-6 })
    }

    @Test("a capture opened before it is read asks for a tempo and has the crate read it; a tempo set by hand stands over the reading")
    func captureOpenedEarly() async throws {
        let (app, directory, _) = try IdeasFixture.app("capture-early")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.tone(CaptureName(section: "Beat", stamp: "20261026-120100").fileName(extension: "wav"), in: directory)
        app.crate.host = StubImportHost(library: try #require(app.store), report: Self.pickupReport(path: file.path, duration: 6))
        guard case .idea(let id) = app.importFromInbox(file) else { Issue.record("not an idea"); return }
        app.openSong(id)
        #expect(app.wantsSongSettings, "its settings open for a tempo")
        #expect(app.log.contains { $0.text == "Beat from the phone has no tempo of its own yet" })
        #expect(app.crate.finished.isEmpty && app.crate.waiting.isEmpty, "the crate already on it is not asked twice")
        #expect(app.setTempo(90))
        #expect(app.song?.captureAwaitingReading == nil)
        await app.crate.waitUntilIdle()
        #expect(app.library.records.first?.reading != nil, "the crate reads it all the same")
        #expect(app.song?.tempo == 90, "the tempo set by hand stands")
        #expect(app.song?.versions.contains { $0.type == .analysis } == false)
    }

    @Test("a bare idea opened becomes an idea of its own, once: its audio copied in, a capture read from the crate at once, a written part as long as it is")
    func bareIdeas() throws {
        let (app, directory, _) = try IdeasFixture.app("bare")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(app.store)
        let record = try LibraryFixture.record("Beat from the phone", in: directory, store: store)
        try store.addMedia(copying: store.mediaURL(for: record.media), kind: .idea)
        let info = try AudioFileInfo.read(store.mediaURL(for: record.media))
        let capture = PartVersion(partID: PartID(), kind: .audio(Audio(media: record.media, role: .take, sampleRate: info.sampleRate,
                                                                       channelCount: info.channelCount, duration: info.duration)),
                                  author: .user, operation: Operation.recorded,
                                  note: "Beat from the phone: capture roboto-capture----Beat--1--x.m4a, from the inbox")
        let groove = TransportFixture.grooveVersion()
        var library = app.library
        library.records = [record]
        library.ideas = [capture, groove]
        #expect(app.writeLibrary(library))
        #expect(LibraryActions.primary(for: .idea(capture.id), in: app)?.id == "open", "a double-click opens it")

        let id = try #require(app.openBareIdea(capture.id))
        let idea = try #require(app.song)
        #expect(idea.id == id && idea.isIdea && idea.title == "Beat from the phone")
        #expect(app.library.ideas.map(\.id) == [groove.id] && app.library.ideaSongs.map(\.id) == [id])
        #expect(LibraryIndex(library: app.library, openSong: app.song, sounds: LibrarySounds()).items(on: .ideas).count == 2,
                "listed once, beside the other bare idea")
        #expect(try store.songStore(for: id).hasMedia(record.media))
        let tempo = ((record.reading?.dominantTempo ?? 0) * 10).rounded() / 10
        #expect(idea.captureAwaitingReading == nil && idea.tempo == tempo, "read at once from what the crate has")
        #expect(!app.wantsSongSettings)
        #expect(app.log.contains { $0.text == "Beat from the phone is an idea of its own now" })

        let written = try #require(app.openBareIdea(groove.id))
        let grooveIdea = try #require(app.song)
        #expect(grooveIdea.id == written && app.library.ideas.isEmpty && app.library.ideaSongs.count == 2)
        #expect(grooveIdea.tempo == Song.startingTempo && grooveIdea.captureAwaitingReading == nil)
        #expect(grooveIdea.sections[0].lengthInBars == grooveIdea.bars(holding: grooveIdea.versions[0]))
        let later = try LibraryStore(directoryURL: directory).load()
        #expect(later.ideas.isEmpty && later.ideaSongs.count == 2, "each listed once in a fresh session")
    }

    @Test("the band lists an idea of its own with its grid, and brings it into a song as it is")
    func band() async throws {
        let (app, directory, song) = try IdeasFixture.app("band")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        let groove = try #require(app.song?.versions.first { $0.type == .groove })
        let id = try #require(app.keepAsIdea(groove.id))
        let listed = try await ReadLibraryTool(workspace: AppStateWorkspace(app)).run(.init(shelf: "ideas"))
        let row = try #require(listed.ideas.first { $0.id == id.description })
        #expect(row.title == "\(PartLabel.title(of: groove)) from Arrival" && row.type == "groove")
        #expect(row.tempo == 113 && row.bars == 8 && row.key == song.key.map { "\($0)" })

        app.open(Song.new(title: "Second", tempo: 90))
        let input = try JSONDecoder().decode(AdoptTool.Input.self, from: Data(#"{"kind":"idea","id":"\#(id.description)","stem":"","bars":[]}"#.utf8))
        let adopted = try await AdoptTool(workspace: AppStateWorkspace(app)).run(input)
        let version = try #require(app.song?.versions.first { $0.id.description == adopted.version })
        #expect(version.kind == groove.kind && version.operation == Operation.adopted)
        #expect(app.song?.versions.count == 1)
    }
}

@Suite("Ideas: put in a song", .serialized) @MainActor
struct IdeaPlacingTests {

    /// An idea of its own in the library, holding `versions`, its media copied from `files`.
    static func idea(_ title: String, key: String?, tempo: Double, bars: Int, versions: [PartVersion],
                             files: [MediaRef: URL] = [:], in app: AppState) throws -> Song {
        var idea = Song.newIdea(title: title, key: key.flatMap { Key(parsing: $0) }, tempo: tempo, bars: bars)
        idea.gridChosen = true
        for version in versions {
            try idea.append(version)
            _ = AppState.joinForm(with: version, in: &idea)
        }
        #expect(app.keepIdeaPackage(idea, mediaFrom: nil, files: files))
        return idea
    }

    /// Mono audio at 48 kHz, written where `name` says, and its media reference.
    static func audio(_ lane: [Float], named name: String, in directory: URL) throws -> (url: URL, media: MediaRef) {
        let url = directory.appendingPathComponent(name)
        try BoothAdapter.write([lane], sampleRate: 48_000, to: url)
        return (url, MediaRef(hash: ContentHash(of: try Data(contentsOf: url)), fileExtension: "wav"))
    }

    /// The frequency of a tone, by its zero crossings.
    private static func frequency(_ lane: ArraySlice<Float>, sampleRate: Double) -> Double {
        let samples = Array(lane)
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(samples.count) / sampleRate)
    }

    @Test("an idea's chords and tune move by the keys, at no cost, into the section chosen in place of its chords; their instrument comes; the idea stays as it was")
    func written() async throws {
        let (app, directory, song) = try IdeasFixture.app("place-written")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        let own = TransportFixture.progressionVersion()
        #expect(app.record(own))
        var sections = try #require(app.song?.sections)
        sections.append(Section(name: "Hook", stitch: sections[0].stitch, lengthInBars: 4))
        #expect(app.arrange(sections))
        app.save()
        let hook = sections[1].id

        let chords = TransportFixture.progressionVersion()
        let tune = TransportFixture.melodyVersion()
        let vibes = PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "vibraphone", forPart: chords.partID)),
                                author: .user, operation: Operation.written)
        let idea = try Self.idea("Hum", key: "C major", tempo: 92, bars: 4, versions: [chords, tune, vibes], in: app)

        let shelved = try #require(app.libraryIndex.facts(.ideaSong(idea.id))?.fit, "the Library's Fit column has it")
        #expect(shelved.verdict == .near && shelved.semitones == 2 && shelved.cost == 0, "written: moved at no cost")
        let plan = try #require(app.ideaPlacement(idea.id, at: .section(hook)))
        #expect(plan.pieces.map(\.version.type) == [.progression, .melody], "the sound comes with the chords, not as a part")
        let piece = try #require(plan.pieces.first)
        #expect(piece.move.semitones == 2 && piece.verdict == .near)
        #expect(piece.sentence.contains("up 2 semitones to D major") && piece.sentence.contains("at no cost"), "\(piece.sentence)")
        #expect(piece.replaces == [PartLabel.title(of: own)])
        #expect(plan.sectionBars == 4 && plan.ideaBars == 4 && plan.startBar == 8 && plan.sentences.isEmpty)

        let placed = try await app.place(plan)
        let now = try #require(app.song)
        #expect(placed.count == 2)
        let movedChords = try #require(placed.first { $0.type == .progression })
        let movedTune = try #require(placed.first { $0.type == .melody })
        guard case .progression(let progression) = movedChords.kind, case .melody(let melody) = movedTune.kind else {
            Issue.record("not chords and a tune"); return
        }
        #expect(progression.key == Key(parsing: "D major"))
        #expect(progression.bars[0].chords[0].chord == Chord(.c, .majorSeventh).transposed(by: 2))
        #expect(melody.notes.map(\.pitch.midi) == [74, 76])
        #expect(now.sections[1].stitch.contains(part: movedChords.partID) && now.sections[1].stitch.contains(part: movedTune.partID))
        #expect(!now.sections[1].stitch.contains(part: own.partID), "in place of the Hook's own chords")
        #expect(now.sections[0].stitch.contains(part: own.partID) && !now.sections[0].stitch.contains(part: movedChords.partID),
                "the Verse as it was")
        let seed = try #require(now.seeds.last)
        #expect(seed.kind == .idea(idea.id) && placed.allSatisfy { $0.origin == seed.id }, "each part says the idea it came from")
        #expect(SongPlayback.instrumentID(for: movedChords.partID, in: now) == "vibraphone")
        #expect(PartLabel.title(of: movedChords) == "Chords of Hum", "named by the idea, not by the symbols it moved from")
        #expect(app.library.song(idea.id)?.versions.count == idea.versions.count, "the idea as it was")
        #expect(app.log.contains { $0.text == "Put Hum in the Hook" })
    }

    @Test("a take sung at 92 in A minor comes into a song at 100 in D major shifted and stretched onto its section's first bar, without its count-in, going round to fill the section; its audio the song's own")
    func take() async throws {
        let (app, directory, song) = try IdeasFixture.app("place-take")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        #expect(app.setTempo(100))
        app.save()
        // Three bars at 92: a silent bar of count-in, then two bars of a 220 Hz tone.
        let bar92 = 4 * 60 / 92.0
        let frames = Int(3 * bar92 * 48_000)
        let lane = (0..<frames).map { i -> Float in i < Int(bar92 * 48_000) ? 0 : Float(0.3 * sin(2 * .pi * 220 * Double(i) / 48_000)) }
        let (url, media) = try Self.audio(lane, named: "hum.wav", in: directory)
        var hum = Song.newIdea(title: "Hum", bars: 2)
        let take = Take(section: hum.sections[0].id, startBar: 0, input: "Mic", pass: 1, sectionStartBar: 0, tempo: 92, meter: .fourFour)
        let sung = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: 48_000, channelCount: 1,
                                                                   duration: Double(frames) / 48_000, alignmentOffset: -bar92, take: take)),
                               author: .user, operation: Operation.recorded, note: "Take 1")
        let idea = try Self.idea("Hum", key: "A minor", tempo: 92, bars: 2, versions: [sung], files: [media: url], in: app)
        hum = idea

        let plan = try #require(app.ideaPlacement(hum.id, at: .end))
        let piece = try #require(plan.pieces.first)
        #expect(piece.move.semitones == 2 && abs(piece.move.ratio - 0.92) < 1e-9)
        #expect(piece.sentence == "Take 1 up 2 semitones to B minor, stretched ×0.92 from 92 to 100.")
        #expect(plan.ideaBars == 2 && plan.sectionBars == 2 && plan.startBar == 8)
        #expect(plan.sentences == ["A new section of 2 bars after the Verse, called Hum."])

        let placed = try await app.place(plan)
        let now = try #require(app.song)
        #expect(now.sections.map(\.name) == ["Verse", "Hum"] && now.sections[1].lengthInBars == 2)
        let version = try #require(placed.first)
        let audio = try #require(Guidance.audio(of: version))
        #expect(audio.take?.section == now.sections[1].id && audio.take?.tempo == 100)
        let clock = TransportClock(tempo: 100, timeSignature: .fourFour)
        let at = TakePlacement.placement(of: audio, in: now, clock: clock)
        #expect(abs((at.take ?? 0) - clock.seconds(forBar: 8)) < 1e-9, "on the new section's first bar")
        #expect(abs(audio.duration - 4.8) < 0.01, "exactly two bars at 100")
        #expect(PartLabel.title(of: version) == "Take 1 of Hum")
        let rendered = try BoothAdapter.planar(try app.store!.songStore(for: song.id).mediaURL(for: audio.media))
        #expect(rendered.planar[0].prefix(Int(0.3 * rendered.sampleRate)).contains { abs($0) > 0.1 },
                "it starts singing: the count-in's silence is left out")
        let middle = rendered.planar[0][Int(1.5 * rendered.sampleRate)..<Int(3.5 * rendered.sampleRate)]
        let heard = Self.frequency(middle, sampleRate: rendered.sampleRate)
        #expect(abs(heard - 220 * pow(2, 2 / 12)) < 4, "two semitones up: \(heard) Hz")

        // Into the eight-bar Verse it goes round four times.
        let verse = try #require(app.ideaPlacement(hum.id, at: .section(now.sections[0].id)))
        #expect(verse.sentences == ["The idea is 2 bars and the Verse 8: it goes round four times there."])
        let again = try await app.place(verse)
        #expect(abs((Guidance.audio(of: again[0])?.duration ?? 0) - 19.2) < 0.01)
    }

    @Test("a capture comes with its pickup, silent before it; a move past four semitones is flagged; drums are never shifted")
    func capture() async throws {
        let (app, directory, song) = try IdeasFixture.app("place-capture")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        #expect(app.setTempo(100))
        #expect(app.setKey(parsing: "G# major"))
        app.save()
        // A capture read at 100 in D major, placed with its first downbeat on bar 2 after a pickup.
        let (url, media) = try Self.audio((0..<Int(4.8 * 48_000)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 48_000)) },
                                          named: "beat.wav", in: directory)
        var beat = AppState.captureIdea(title: "Beat from the phone", media: media, sampleRate: 48_000, channelCount: 1, duration: 4.8, note: nil)
        var reading = GuidanceFixture.analysis()
        reading.tempo = [TempoRange(start: 0, end: 4.8, bpm: 100)]
        reading.bars = [SongGraph.TimeRange(start: 0.9, end: 3.3)]
        var drumReading = reading
        reading.instruments = []
        #expect(AppState.read(&beat, reading) != nil)
        let offset = try #require(Guidance.audio(of: beat.versions.last { $0.type == .audio }!)?.alignmentOffset)
        #expect(abs(offset - 1.5) < 1e-9)
        #expect(app.keepIdeaPackage(beat, mediaFrom: nil, files: [media: url]))

        let plan = try #require(app.ideaPlacement(beat.id, at: .end))
        let piece = try #require(plan.pieces.first)
        #expect(piece.move.semitones == -6 && piece.verdict == .far)
        #expect(piece.flags.contains { $0.contains("past 4, the timbre will tell") }, "\(piece.flags)")
        let placed = try await app.place(plan)
        let audio = try #require(Guidance.audio(of: placed[0]))
        let rendered = try BoothAdapter.planar(try app.store!.songStore(for: song.id).mediaURL(for: audio.media))
        let rate = rendered.sampleRate
        #expect(!rendered.planar[0].prefix(Int(0.8 * rate)).contains { abs($0) > 0.02 }, "silence before the pickup")
        #expect(rendered.planar[0][Int(2 * rate)..<Int(2.5 * rate)].contains { abs($0) > 0.1 }, "then the capture")

        // Read as drums most of the way through, it is stretched with its pitch left alone.
        drumReading.instruments = [SongGraph.InstrumentActivity(instrument: .drums, ranges: [SongGraph.TimeRange(start: 0, end: drumReading.duration)])]
        var drums = AppState.captureIdea(title: "Drums from the phone", media: media, sampleRate: 48_000, channelCount: 1, duration: 4.8, note: nil)
        #expect(AppState.read(&drums, drumReading) != nil)
        let open = try #require(app.song)
        let drumPiece = try #require(IdeaPlacing.plan(drums, into: open, at: .end)?.pieces.first)
        #expect(drumPiece.move.semitones == 0 && drumPiece.sentence.hasSuffix("its pitch left alone: it is drums."), "\(drumPiece.sentence)")
    }

    @Test("an idea's words become the new section's stanza; a section with words of its own keeps them")
    func words() async throws {
        let (app, directory, song) = try IdeasFixture.app("place-words")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        let lyric = PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "la la la\nsing it again")), author: .user,
                                operation: Operation.written)
        let idea = try Self.idea("Hum", key: "D major", tempo: 113, bars: 4, versions: [TransportFixture.melodyVersion(), lyric], in: app)

        let plan = try #require(app.ideaPlacement(idea.id, at: .end))
        #expect(plan.words?.comes == true && plan.words?.sentence == "The idea's words become the Hum's.")
        try await app.place(plan)
        let now = try #require(app.song)
        guard case .lyric(let words)? = now.versions.last(where: { $0.type == .lyric })?.kind else { Issue.record("no words"); return }
        let stanza = try #require(words.stanza(forSectionAt: 1, in: now.sections))
        #expect(stanza.label.name == "Hum" && words.lines[stanza.lines].map(\.text) == ["la la la", "sing it again"])

        let again = try #require(app.ideaPlacement(idea.id, at: .section(now.sections[1].id)))
        #expect(again.words?.comes == false && again.words?.sentence.contains("has words of its own") == true)
        try await app.place(again)
        #expect(app.song?.versions.filter { $0.type == .lyric }.count == 1, "its words left as they were")
    }

    @Test("Add to This Song… is on an idea's row with a song open; a drop on a section, past the last or on the bench asks where; with no song open the idea opens")
    func entries() throws {
        let (app, directory, song) = try IdeasFixture.app("place-entries")
        defer { try? FileManager.default.removeItem(at: directory) }
        let idea = try Self.idea("Hum", key: "D major", tempo: 113, bars: 4, versions: [TransportFixture.melodyVersion()], in: app)
        func place() -> LibraryAction? { LibraryActions.actions(for: .ideaSong(idea.id), in: app).first { $0.id == "place" } }
        #expect(place()?.isEnabled == false, "no song to put it in")
        let payload = LibraryDragPayload(kind: .idea, id: idea.id.rawValue, title: idea.title)
        #expect(app.receive(payload, at: .bench))
        #expect(app.song?.id == idea.id && app.placingIdea == nil, "with no song open, it opens")
        #expect(place()?.isEnabled == false, "not into itself")

        app.openSong(song.id)
        #expect(place()?.isEnabled == true)
        let verse = try #require(app.song?.sections.first?.id)
        #expect(app.receive(payload, at: .section(verse)))
        #expect(app.placingIdea?.idea == idea.id && app.placingIdea?.spot == .section(verse))
        #expect(app.receive(payload, at: .afterLastSection))
        #expect(app.placingIdea?.spot == .end)
        #expect(app.receive(payload, at: .ledger))
        #expect(app.placingIdea?.spot == .end)
        #expect(app.song?.versions.count == song.versions.count, "asked, not done")
    }
}

@Suite("Ideas: a song made of them", .serialized) @MainActor
struct SongFromIdeasTests {

    /// A sung idea: two bars of a 220 Hz tone, taken at its tempo, and in its key.
    private static func sung(_ title: String, key: String, tempo: Double, in app: AppState, directory: URL) throws -> Song {
        let bar = 4 * 60 / tempo
        let frames = Int(2 * bar * 48_000)
        let (url, media) = try IdeaPlacingTests.audio((0..<frames).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 48_000)) },
                                                      named: "\(title).wav", in: directory)
        let section = SectionID()
        var take = Take(section: section, startBar: 0, input: "Mic", pass: 1, sectionStartBar: 0, tempo: tempo, meter: .fourFour)
        take.section = section
        let version = PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: 48_000, channelCount: 1,
                                                                      duration: Double(frames) / 48_000, alignmentOffset: 0, take: take)),
                                  author: .user, operation: Operation.recorded, note: "Take 1")
        var idea = Song.newIdea(title: title, key: Key(parsing: key), tempo: tempo, bars: 2)
        idea.sections[0] = Section(id: section, name: Song.ideaSectionName, stitch: [], lengthInBars: 2)
        idea.gridChosen = true
        try idea.append(version)
        #expect(app.keepIdeaPackage(idea, mediaFrom: nil, files: [media: url]))
        return idea
    }

    @Test("the song takes the grid of the idea that would lose most by moving: the sung one, not the written one, whose chords move at no cost")
    func grid() throws {
        let (app, directory, _) = try IdeasFixture.app("from-grid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chords = try IdeaPlacingTests.idea("Changes", key: "C major", tempo: 120, bars: 4,
                                               versions: [TransportFixture.progressionVersion()], in: app)
        let hum = try Self.sung("Hum", key: "A minor", tempo: 92, in: app, directory: directory)
        let grids = SongFromIdeas.grids(for: [chords, hum])
        #expect(grids.first?.idea == hum.id, "taking the chords' grid would stretch the voice; taking the voice's moves the chords for nothing")
        #expect(grids.first?.cost == 0 && (grids.last?.cost ?? 0) > 0)
        #expect(grids.first?.sentences == ["Changes: the changes stays in C major."], "\(grids.first?.sentences ?? [])")
        #expect(SongFromIdeas.line(grids[0]) == "92 bpm in A minor")
        // All written: the first one's, in the order given.
        let tune = try IdeaPlacingTests.idea("Tune", key: "D major", tempo: 100, bars: 4, versions: [TransportFixture.melodyVersion()], in: app)
        #expect(SongFromIdeas.grids(for: [tune, chords]).first?.idea == tune.id)
    }

    @Test("a song is made of the ideas: a section for each row, named after it and as long as it, two in a row playing together, at the chosen grid, opened on Structure; the ideas left as they were")
    func make() async throws {
        let (app, directory, song) = try IdeasFixture.app("from-make")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hum = try Self.sung("Hum", key: "A minor", tempo: 92, in: app, directory: directory)
        let chords = try IdeaPlacingTests.idea("Changes", key: "C major", tempo: 120, bars: 4,
                                               versions: [TransportFixture.progressionVersion()], in: app)
        let groove = try IdeaPlacingTests.idea("Beat", key: nil, tempo: 120, bars: 2, versions: [TransportFixture.grooveVersion()], in: app)
        app.openSong(song.id)

        let id = try await app.makeSong(from: [[chords.id, groove.id], [hum.id]], title: "From Ideas")
        let made = try #require(app.song)
        #expect(made.id == id && made.title == "From Ideas" && !made.isIdea && made.gridChosen == true)
        #expect(made.tempo == 92 && made.key == Key(parsing: "A minor"), "the sung idea's grid")
        #expect(made.sections.map(\.name) == ["Changes", "Hum"] && made.sections.map(\.lengthInBars) == [4, 2])
        let first = made.sections[0]
        let types = first.stitch.compactMap { made.latestVersion(of: $0.part)?.type }
        #expect(Set(types) == [.progression, .groove], "the chords and the beat play together in the first section: \(types)")
        guard case .progression(let moved)? = made.versions.first(where: { $0.type == .progression })?.kind else { Issue.record("no chords"); return }
        #expect(moved.key == Key(parsing: "C major"), "C major is A minor's relative: nothing moves")
        let take = try #require(Guidance.takes(in: made).first.flatMap(Guidance.audio(of:)))
        #expect(take.take?.section == made.sections[1].id)
        #expect(made.seeds.filter { if case .idea = $0.kind { return true }; return false }.count == 3)
        #expect(app.bench.items.last?.kind == .structure, "opened on Structure")
        #expect(app.library.songs.contains { $0.id == id } && !app.library.ideaSongs.contains { $0.id == id })
        #expect(app.library.song(hum.id)?.versions.count == hum.versions.count, "the ideas as they were")
        #expect(app.library.song(song.id) != nil, "the song open before is kept")
        #expect(app.log.contains { $0.text == "Made From Ideas from 3 ideas" })
        #expect(try LibraryStore(directoryURL: directory).load().songs.contains { $0.id == id }, "saved")
    }

    @Test("Make a Song from These is offered for ideas chosen on the shelf, and opens the sheet with them in order")
    func entries() throws {
        let (app, directory, _) = try IdeasFixture.app("from-entries")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try IdeaPlacingTests.idea("A", key: "C major", tempo: 100, bars: 4, versions: [TransportFixture.progressionVersion()], in: app)
        let b = try IdeaPlacingTests.idea("B", key: "C major", tempo: 100, bars: 4, versions: [TransportFixture.melodyVersion()], in: app)
        let actions = LibraryActions.batch([.ideaSong(b.id), .ideaSong(a.id)], in: app, work: LibraryBatchWork(app: app))
        let make = try #require(actions.first { $0.id == "make-song" })
        guard case .run(let run) = make.kind else { Issue.record("not a run"); return }
        run()
        #expect(app.makingSongFromIdeas?.ideas == [b.id, a.id])
        app.askToMakeSong()
        #expect(app.makingSongFromIdeas?.ideas == [])
    }
}

@Suite("Ideas: the band's three tools", .serialized) @MainActor
struct IdeaToolsTests {

    private func run(_ app: AppState, _ tool: String, _ input: [String: Any]) async -> (result: [String: Any], failed: Bool, text: String) {
        let box = WritingFixture.toolbox(AppStateWorkspace(app))
        let data = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let result = await WritingFixture.run(box, tool, String(decoding: data, as: UTF8.self))
        return (WritingFixture.json(result), result.isError, result.content)
    }

    @Test("new_idea opens an idea at the grid asked for, the open song saved, no settings left open for a person")
    func newIdea() async throws {
        let (app, directory, song) = try IdeasFixture.app("tool-new")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.openSong(song.id)
        let made = await run(app, "new_idea", ["title": "Hum", "tempo": 92, "key": "A minor", "meter": "6/8", "bars": 8])
        #expect(!made.failed, "\(made.text)")
        let idea = try #require(app.song)
        #expect(idea.isIdea && idea.title == "Hum" && idea.tempo == 92 && idea.key == Key(parsing: "A minor"))
        #expect(idea.timeSignature == TimeSignature(beatsPerBar: 6, beatUnit: 8) && idea.sections.first?.lengthInBars == 8)
        #expect(made.result["idea"] as? String == idea.id.description && !app.wantsSongSettings)
        let bad = await run(app, "new_idea", ["title": "", "tempo": 0, "key": "H major", "meter": "", "bars": 4])
        #expect(bad.failed && bad.text.contains("not a key"))
    }

    @Test("place_idea puts an idea in a section by name, or a new one, and says what moved; it refuses what it cannot find")
    func place() async throws {
        let (app, directory, song) = try IdeasFixture.app("tool-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let idea = try IdeaPlacingTests.idea("Changes", key: "C major", tempo: 92, bars: 4,
                                             versions: [TransportFixture.progressionVersion(), TransportFixture.melodyVersion()], in: app)
        app.openSong(song.id)
        let placed = await run(app, "place_idea", ["idea": "changes", "section": "Verse", "parts": [String](), "words": true, "replace": true])
        #expect(!placed.failed, "\(placed.text)")
        #expect(placed.result["section"] as? String == "Verse")
        let sentences = placed.result["sentences"] as? [String] ?? []
        #expect(sentences.contains { $0.contains("up 2 semitones to D major") }, "\(sentences)")
        #expect((placed.result["versions"] as? [String])?.count == 2)

        let one = await run(app, "place_idea", ["idea": idea.id.description, "section": "", "parts": ["the tune"], "words": false, "replace": true])
        #expect(!one.failed, "\(one.text)")
        #expect(app.song?.sections.map(\.name) == ["Verse", "Changes"], "a new section after the last")
        #expect((one.result["versions"] as? [String])?.count == 1, "only the part asked for")

        let none = await run(app, "place_idea", ["idea": "Nowhere", "section": "", "parts": [String](), "words": false, "replace": true])
        #expect(none.failed && none.text.contains("Changes"), "the ideas there are")
        let wrong = await run(app, "place_idea", ["idea": "Changes", "section": "Bridge", "parts": [String](), "words": false, "replace": true])
        #expect(wrong.failed && wrong.text.contains("Verse"))

        // With replace false, chords join the section's own rather than taking their place.
        let verse = try #require(app.song?.sections.first)
        let before = verse.stitch.count
        let layered = await run(app, "place_idea", ["idea": "Changes", "section": "Verse", "parts": ["the changes"], "words": false, "replace": false])
        #expect(!layered.failed, "\(layered.text)")
        #expect(app.song?.sections.first?.stitch.count == before + 1, "played together, nothing taken out")
        #expect((layered.result["sentences"] as? [String] ?? []).contains { $0.contains("In the Verse, with ") }, "\(layered.result)")
    }

    @Test("song_from_ideas makes a song of ideas, two joined with + in one section, at the grid of the one that moves the rest least")
    func songFromIdeas() async throws {
        let (app, directory, _) = try IdeasFixture.app("tool-song")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try IdeaPlacingTests.idea("Changes", key: "C major", tempo: 92, bars: 4, versions: [TransportFixture.progressionVersion()], in: app)
        _ = try IdeaPlacingTests.idea("Beat", key: nil, tempo: 120, bars: 2, versions: [TransportFixture.grooveVersion()], in: app)
        _ = try IdeaPlacingTests.idea("Tune", key: "C major", tempo: 92, bars: 4, versions: [TransportFixture.melodyVersion()], in: app)
        let made = await run(app, "song_from_ideas", ["sections": ["Changes + Beat", "Tune"], "grid": "", "title": "Assembled"])
        #expect(!made.failed, "\(made.text)")
        let song = try #require(app.song)
        #expect(song.title == "Assembled" && !song.isIdea && song.tempo == 92 && song.key == Key(parsing: "C major"))
        #expect(made.result["sections"] as? [String] == ["Changes 4", "Tune 4"])
        let bad = await run(app, "song_from_ideas", ["sections": ["Tune"], "grid": "Beat", "title": ""])
        #expect(bad.failed && bad.text.contains("one of the ideas named"))
    }

    @Test("with nothing open and two ideas on the shelf, the band offers to make a song of them; taking it opens the sheet")
    func option() throws {
        let (app, directory, _) = try IdeasFixture.app("tool-option")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try IdeaPlacingTests.idea("A", key: "C major", tempo: 92, bars: 4, versions: [TransportFixture.progressionVersion()], in: app)
        #expect(!app.nextQuestion.options.contains { $0.kind == "songFromIdeas" }, "one idea is not a song")
        let b = try IdeaPlacingTests.idea("B", key: "C major", tempo: 92, bars: 4, versions: [TransportFixture.melodyVersion()], in: app)
        let question = app.nextQuestion
        let option = try #require(question.options.first { $0.kind == "songFromIdeas" })
        #expect(option.title == "Make a song from your ideas")
        app.take(option, from: question)
        #expect(app.makingSongFromIdeas?.ideas == [a.id, b.id])
    }
}

@Suite("Ideas: one heard under another", .serialized) @MainActor
struct IdeaGuideTests {

    @Test("an idea heard with another plays the other's chords under it, moved onto its key, never as its own part, and leaves it behind in a song")
    func guide() async throws {
        let (app, directory, song) = try IdeasFixture.app("guide")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chords = try IdeaPlacingTests.idea("Changes", key: "C major", tempo: 120, bars: 4,
                                               versions: [TransportFixture.progressionVersion()], in: app)
        app.newIdea()
        app.setTitle("Hum")
        app.setKey(Key(parsing: "D major"))
        #expect(app.record(TransportFixture.melodyVersion()))
        #expect(app.guideChoices.map(\.id) == [chords.id])
        #expect(app.hearWith(chords.id))
        let idea = try #require(app.song)
        #expect(idea.guide == chords.id && idea.versions.allSatisfy { $0.type != .progression }, "heard, not kept")
        let heard = try #require(app.playback.segments.flatMap(\.voices).compactMap(\.progression).first, "the guide's chords play under it")
        #expect(heard.key == Key(parsing: "D major") && heard.bars[0].chords[0].chord == Chord(.c, .majorSeventh).transposed(by: 2))
        #expect(app.log.contains { $0.text == "Hearing Changes under Hum" })
        #expect(app.ideaTakePlan()?.segments.flatMap(\.voices).contains { $0.progression != nil } == true, "the Booth sings over it too")
        let read = try await ReadSongTool(workspace: AppStateWorkspace(app)).run(.init())
        #expect(read.note?.contains("Changes is heard under it") == true)
        app.save()
        #expect(try LibraryStore(directoryURL: directory).load().ideaSongs.first { $0.id == idea.id }?.guide == chords.id, "kept with the idea")

        // Into a song, the guide stays behind.
        app.openSong(song.id)
        #expect(!app.hearWith(chords.id), "a song is not heard with an idea")
        let plan = try #require(app.ideaPlacement(idea.id, at: .end))
        #expect(plan.pieces.map(\.version.type) == [.melody])
        try await app.place(plan)
        #expect(app.song?.versions.contains { $0.type == .progression } == false)
        #expect(app.song?.guide == nil)

        // Nothing under it again.
        app.openSong(idea.id)
        #expect(app.hearWith(nil))
        #expect(app.playback.segments.flatMap(\.voices).compactMap(\.progression).isEmpty)
    }

    @Test("a guide's audio is rendered onto the idea and played from its cache, never saved into the idea")
    func guideAudio() async throws {
        let (app, directory, _) = try IdeasFixture.app("guide-audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = Int(2 * (4 * 60 / 100.0) * 48_000)
        let (url, media) = try IdeaPlacingTests.audio((0..<frames).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 48_000)) },
                                                      named: "hum.wav", in: directory)
        var sung = Song.newIdea(title: "Hum", key: Key(parsing: "A minor"), tempo: 100, bars: 2)
        sung.gridChosen = true
        try sung.append(PartVersion(partID: PartID(), kind: .audio(Audio(media: media, role: .take, sampleRate: 48_000, channelCount: 1,
                                                                         duration: Double(frames) / 48_000,
                                                                         take: Take(section: sung.sections[0].id, startBar: 0, pass: 1,
                                                                                    sectionStartBar: 0, tempo: 100))),
                                    author: .user, operation: Operation.recorded, note: "Take 1"))
        #expect(app.keepIdeaPackage(sung, mediaFrom: nil, files: [media: url]))
        app.newIdea()
        app.setTempo(92)
        app.setKey(Key(parsing: "A minor"))
        #expect(app.record(TransportFixture.progressionVersion()))
        #expect(app.hearWith(sung.id))
        await app.guidesSettled()
        let track = try #require(app.playback.tracks.first { app.guideMedia.values.contains($0.url) }, "the hum rendered under it")
        #expect(track.startsAt == 0)
        app.save()
        let idea = try #require(app.song)
        #expect(idea.versions.allSatisfy { $0.type != .audio }, "the guide's audio is not the idea's")
        #expect(try app.store!.songStore(for: idea.id).storedMedia().isEmpty, "nothing written into the idea's package")
    }

    @Test("a song written before ideas could be heard together reads and writes back without a guide")
    func roundTrip() throws {
        var idea = Song.newIdea(title: "Hum")
        let plain = try SongGraphCodec.encode(idea)
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"guide\""))
        idea.guide = SongID()
        let back = try SongGraphCodec.decode(Song.self, from: try SongGraphCodec.encode(idea))
        #expect(back.guide == idea.guide)
    }
}
