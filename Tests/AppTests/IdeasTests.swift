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
