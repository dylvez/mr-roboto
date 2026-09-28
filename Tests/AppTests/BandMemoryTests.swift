import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A band that does not play the same thing twice and remembers across songs: a groove plays its
// feel on a seed of its own, house calls are the library's, and what has been said is counted.

@Suite("The band over time", .serialized) @MainActor
struct BandMemoryTests {

    // MARK: A groove's feel

    @Test("a groove keeps its feel and seed through JSON, and one without a feel writes what it always did")
    func grooveFeelRoundTrip() throws {
        let bare = Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: Array(repeating: .normal, count: 16))])
        let bareJSON = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(!bareJSON.contains("feel"), "a groove from before feels round-trips byte for byte")
        #expect(try JSONDecoder().decode(Groove.self, from: Data(bareJSON.utf8)).feel == nil)

        var felt = bare
        felt.feel = GrooveFeel(name: "Neo-Soul Pocket", seed: GrooveFeel.freshSeed())
        let back = try JSONDecoder().decode(Groove.self, from: JSONEncoder().encode(felt))
        #expect(back == felt)
        #expect(felt.tiled(toBars: 4).feel == felt.feel, "tiling keeps the feel")
    }

    @Test("a stored groove plays in its feel, on its own seed, with its own swing; without one, on the grid")
    func storedOptions() throws {
        let feel = try #require(FeelLibrary.standard.feel(named: "Neo-Soul Pocket"))
        #expect(feel.humanize.isActive && !feel.voices.isEmpty, "the fixture needs a feel with jitter and pocket")
        var groove = feel.groove
        #expect(GrooveRenderOptions.stored(groove) == GrooveRenderOptions(), "no feel named: the grid")

        groove.feel = GrooveFeel(name: feel.name, seed: 12345)
        let options = GrooveRenderOptions.stored(groove)
        #expect(options.humanize.seed == 12345)
        #expect(options.humanize.velocity == feel.humanize.velocity && options.voices == feel.voices)
        #expect(options.swing == nil, "the groove's stored swing wins over the feel's")

        var other = groove
        other.feel?.seed = 54321
        let timeline = GrooveTimeline.tempo(90, timeSignature: .fourFour)
        let a = GrooveRenderer.render(groove, on: timeline, options: .stored(groove))
        let b = GrooveRenderer.render(other, on: timeline, options: .stored(other))
        #expect(a != b, "two seeds, two performances of the same feel")
        #expect(a == GrooveRenderer.render(groove, on: timeline, options: .stored(groove)), "one seed plays the same every time")

        groove.feel = GrooveFeel(name: "No Such Feel", seed: 1)
        #expect(GrooveRenderOptions.stored(groove) == GrooveRenderOptions(), "a feel the library lost plays on the grid")
    }

    @Test("write_groove from a feel keeps the feel with a fresh seed each time; rows by hand keep none")
    func writeGrooveSeeds() async throws {
        let workspace = DirectorScratchWorkspace(song: Song(title: "Sketch", tempo: 92))
        let write = WriteGrooveTool(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace)
        func written() throws -> Groove {
            guard case .groove(let groove)? = Guidance.grooves(in: workspace.song!).last?.kind else { throw Failure.noGroove }
            return groove
        }
        _ = try await write.run(.init(feel: "Neo-Soul Pocket", bars: 2, swing_percent: 0, rows: [], note: "one"))
        let first = try written()
        _ = try await write.run(.init(feel: "Neo-Soul Pocket", bars: 2, swing_percent: 0, rows: [], note: "two"))
        let second = try written()
        #expect(first.feel?.name == "Neo-Soul Pocket" && second.feel?.name == "Neo-Soul Pocket")
        #expect(first.feel?.seed != second.feel?.seed)

        _ = try await write.run(.init(feel: "", bars: 1, swing_percent: 0, rows: ["kick: x...x...x...x..."], note: "four"))
        #expect(try written().feel == nil)
    }

    @Test("the Grid keeps a groove's feel and seed across an edit, and a loaded feel gets a fresh one")
    func gridKeepsTheFeel() throws {
        let feel = try #require(FeelLibrary.standard.feel(named: "Neo-Soul Pocket"))
        var groove = feel.groove
        groove.feel = GrooveFeel(name: feel.name, seed: 777)
        let model = GridModel(host: StubGridHost(), groove: groove)
        #expect(model.groove.feel == groove.feel)
        #expect(model.renderOptions.humanize.seed == 777 && model.renderOptions.voices == feel.voices)
        model.load(feel)
        #expect(model.groove.feel?.name == feel.name && model.groove.feel?.seed != 777)
        #expect(GridModel(host: StubGridHost(), groove: feel.groove).groove.feel == nil, "a groove with no feel gains none")
    }

    // MARK: House calls

    @Test("the book layers what shipped, then the library, then the song")
    func houseBookLayers() {
        let question = "beatmaker.oq.snare-direction"
        #expect(HouseBook().entry(for: question)?.scope == .shipped)
        #expect(HouseBook().entry(for: question)?.call.choice == .alternative)

        let house = [HouseCallRecord(question: question, choice: "encoded", how: "by ear", decidedOn: "2026-09-28")]
        let byHouse = HouseBook(library: house)
        #expect(byHouse.entry(for: question)?.scope == .house && byHouse.entry(for: question)?.call.choice == .encoded)

        let song = [HouseCallRecord(question: question, choice: "alternative", how: "this one", decidedOn: "2026-09-29")]
        let bySong = HouseBook(library: house, song: song)
        #expect(bySong.entry(for: question)?.scope == .song && bySong.entry(for: question)?.call.choice == .alternative)
        #expect(bySong.entries.count == 1)
    }

    @Test("the Beatmaker reads the snare by the calls it is given")
    func beatmakerReadsTheBook() throws {
        let feel = try #require(FeelLibrary.standard.feel(named: "Lo-Fi Hip-Hop"))
        let observation = GrooveObservation(feel)
        func direction(_ beatmaker: Beatmaker) -> Bool? {
            beatmaker.read(observation).first { $0.rule == "beatmaker.snare-direction" }?.holds
        }
        #expect(direction(Beatmaker()) == true, "late, as this house shipped")
        let early = HouseBook(library: [HouseCallRecord(question: "beatmaker.oq.snare-direction", choice: "encoded",
                                                        how: "by ear", decidedOn: "2026-09-28")])
        #expect(direction(Beatmaker(houseCalls: early.calls)) == false, "the library chose early, so a late snare is flagged")
    }

    @Test("a reading on a rule an alternative call affects says so; the bible's reading kept says nothing")
    func houseNote() throws {
        let bible = Peer().bible
        let question = try #require(bible.openQuestions.first { !$0.affects.isEmpty })
        let rule = try #require(question.affects.first)
        #expect(HouseBook().note(on: rule, in: bible) == nil)
        let kept = HouseBook(library: [HouseCallRecord(question: question.id, choice: "encoded", how: "", decidedOn: "2026-09-28")])
        #expect(kept.note(on: rule, in: bible) == nil)
        let other = HouseBook(library: [HouseCallRecord(question: question.id, choice: "alternative", how: "", decidedOn: "2026-09-28")])
        let note = try #require(other.note(on: rule, in: bible))
        #expect(note.hasPrefix("This house plays the other reading") && note.contains(question.alternative))
    }

    @Test("a call on the Cast surface is the library's for every song, and clears the open song's own")
    func recordHouseCall() throws {
        let directory = GuidanceFixture.temporaryDirectory("house-calls")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        try store.save(Library())
        let app = AppState(library: Library(), song: nil, store: store, status: .loaded(directory), transportHost: StubTransportHost())
        app.open(Song(title: "One"))
        let question = "peer.oq.test"
        #expect(app.recordHouseCall(question: question, choice: .alternative, how: "by ear", onlyThisSong: true))
        #expect(app.song?.houseCalls?.first?.question == question && app.library.houseCalls == nil)
        #expect(app.houseBook.entry(for: question)?.scope == .song)

        #expect(app.recordHouseCall(question: question, choice: .encoded, how: "by ear"))
        #expect(app.library.houseCalls?.map(\.question) == [question])
        #expect(app.song?.houseCalls == nil, "the song's exception is cleared by the house's call")
        #expect(app.houseBook.entry(for: question)?.scope == .house)
        #expect(try store.loadDocumentOnly().houseCalls?.first?.choice == "encoded", "written to library.json")

        app.open(Song(title: "Two"))
        #expect(app.houseBook.entry(for: question)?.call.choice == .encoded, "the next song starts from the house's call")
    }

    // MARK: What has been said

    @Test("the log counts each rule once per convening, tells repeats the same history, and names the songs")
    func saidBeforeCounts() {
        let one = SongID(), two = SongID()
        let hook = PersonaReading(rule: "peer.hook-inside-thirty", feature: .hookArrivalSeconds, value: 41, holds: false, says: "late")
        let first = SaidBefore.update([], with: [(.peer, hook), (.peer, hook)], song: one, title: "One", today: "2026-09-01")
        #expect(first.before == [nil, nil], "never said before, and the second in one convening is not a repeat of the first")
        #expect(first.records.count == 1 && first.records[0].times == 1)

        let second = SaidBefore.update(first.records, with: [(.peer, hook)], song: two, title: "Two", today: "2026-09-02")
        let prior = try? #require(second.before[0])
        #expect(prior?.times == 1 && prior?.lastTitle == "One")
        #expect(second.records[0].times == 2 && second.records[0].songs == [one, two])
        #expect(SaidBefore.sentence(prior!, now: two) == "Said once before, about 1 other song; last about \"One\" on 2026-09-01.")
        #expect(SaidBefore.sentence(second.records[0], now: two).contains("about this song and 1 other"))

        let holding = PersonaReading(rule: "peer.hook-inside-thirty", feature: .hookArrivalSeconds, value: 20, holds: true, says: "on time")
        let third = SaidBefore.update(second.records, with: [(.peer, holding)], song: two, title: "Two", today: "2026-09-03")
        #expect(third.before == [nil], "a rule that holds is a different thing to have said")
        #expect(third.records.count == 2)
    }

    @Test("the library keeps its house calls and its log through library.json")
    func libraryRoundTrip() throws {
        let directory = GuidanceFixture.temporaryDirectory("band-memory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        var library = Library()
        library.houseCalls = [HouseCallRecord(question: "q", choice: "alternative", how: "h", decidedOn: "2026-09-28")]
        library.said = [SaidRecord(persona: "peer", rule: "peer.r", holds: false, times: 3, songs: [SongID()], lastTitle: "T", lastSaid: "2026-09-28")]
        try store.save(library)
        let back = try store.load()
        #expect(back.houseCalls == library.houseCalls && back.said == library.said)
        try store.saveDocument(back)
        #expect(try store.loadDocumentOnly().said == library.said)
    }

    private enum Failure: Error { case noGroove }
}
