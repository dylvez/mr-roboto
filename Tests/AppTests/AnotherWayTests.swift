import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

// The usual, said: a progression and a tune that pass every other reading and have nothing of
// their own; the same loop as another song; and the two moves that are the way out.

@MainActor
enum AnotherWayFixture {
    static let key = Key(parsing: "D minor")!

    static func sheet(_ text: String, key: Key = key) throws -> Progression { try Progression.parse(text, key: key).get() }

    static func harmony(_ text: String, before: SongsBefore? = nil) throws -> HarmonyObservation {
        var observation = HarmonyObservation.of(try sheet(text), label: "The chords")
        observation.before = before
        return observation
    }

    static func n(_ midi: Int, _ start: Double, _ duration: Double) -> NoteEvent { DevelopFixture.n(midi, start, duration) }

    /// Eight quarter notes and two halves up and down the scale, on the beat, a figure said twice.
    static let plain = Melody(notes: [
        n(62, 0, 1), n(64, 1, 1), n(65, 2, 1), n(67, 3, 1), n(69, 4, 2), n(65, 6, 2),
        n(62, 8, 1), n(64, 9, 1), n(65, 10, 1), n(67, 11, 1), n(67, 12, 2), n(64, 14, 2),
    ], lengthInBars: 4)

    static func reading(_ rule: String, in readings: [PersonaReading]) -> PersonaReading? { readings.first { $0.rule == rule } }

    /// A song the library holds: these chords, and a tune that comes in on this note at this beat.
    static func song(_ title: String, chords: String, opening: (midi: Int, beat: Double)? = nil, key: Key = key,
                     created: Date = Date()) throws -> Song {
        var song = Song(title: title, key: key, tempo: 100, createdAt: created)
        var versions = [PartVersion(partID: PartID(), kind: .progression(try sheet(chords, key: key)), author: .user,
                                    operation: Operation.written, note: chords)]
        if let opening {
            versions.append(PartVersion(partID: PartID(), kind: .melody(Melody(notes: [n(opening.midi, opening.beat, 1), n(opening.midi + 2, opening.beat + 1, 1)],
                                                                             lengthInBars: 2)),
                                        author: .user, operation: Operation.written, note: "Its tune"))
        }
        try song.append(contentsOf: versions)
        return song
    }
}

@Suite("The usual, said: the Harmonist and the Melodist on what has nothing of its own") @MainActor
struct TheUsualTests {

    @Test("four chords from the key, a bar each, root in the bass, from home: flagged, with two ways out")
    func plainLoop() throws {
        let readings = Harmonist().read(try AnotherWayFixture.harmony("Dm7 | Bbmaj7 | Gm7 | A7"))
        let own = try #require(AnotherWayFixture.reading("harmonist.something-of-its-own", in: readings))
        #expect(!own.holds && own.value == 0)
        #expect(own.says.contains("Two ways") && own.says.contains("Bbmaj7/D"), "\(own.says)")
        // Nothing to compare it with: the library reading is not made.
        #expect(AnotherWayFixture.reading("harmonist.not-the-last-song-again", in: readings) == nil)
    }

    @Test("one thing of its own is enough: an inversion, a borrowed chord, a chord held longer")
    func departures() throws {
        for text in ["Dm7 | Bbmaj7/D | Gm7/D | A7/C#", "Dm7 | Bbmaj7 | G7 | A7", "Dm7 | Dm7 | Bbmaj7 Gm7 | A7", "Gm7 | A7 | Dm7 | Bbmaj7"] {
            let observation = try AnotherWayFixture.harmony(text)
            #expect(!observation.departures.isEmpty, "\(text)")
            let own = try #require(AnotherWayFixture.reading("harmonist.something-of-its-own", in: Harmonist().read(observation)))
            #expect(own.holds, "\(text): \(own.says)")
        }
        // The five of a minor key is not a departure: it is the commonest chord outside one.
        #expect(try AnotherWayFixture.harmony("Dm | Gm | A | Dm").departures.isEmpty)
        // Two chords are a vamp, not a loop to call usual.
        #expect(AnotherWayFixture.reading("harmonist.something-of-its-own", in: Harmonist().read(try AnotherWayFixture.harmony("Dm7 | Gm7"))) == nil)
    }

    @Test("the same loop as another song here is named, in any key; a different loop is not")
    func theLastSongAgain() throws {
        // i VI iv V, in A minor: the same roots above its own tonic.
        let other = try AnotherWayFixture.song("First Light", chords: "Am | F | Dm | E", key: Key(parsing: "A minor")!)
        let apart = try AnotherWayFixture.song("Tidewater", chords: "Dm9 | Gm9 | Bbmaj7 | A7")
        let before = SongsBefore.of(Library(songs: [other, apart]), besides: nil)
        #expect(before.entries.count == 2)

        let same = Harmonist().read(try AnotherWayFixture.harmony("Dm7 | Bbmaj7 | Gm7 | A7", before: before))
        let again = try #require(AnotherWayFixture.reading("harmonist.not-the-last-song-again", in: same))
        #expect(!again.holds && again.value == 1 && again.says.contains("First Light") && !again.says.contains("Tidewater"), "\(again.says)")

        let different = Harmonist().read(try AnotherWayFixture.harmony("Dm7 | C | Bbmaj7 | C", before: before))
        #expect(AnotherWayFixture.reading("harmonist.not-the-last-song-again", in: different)?.holds == true)
    }

    @Test("a tune on the beat, in the key, by step: flagged; pushed over a bar line it has something")
    func plainTune() throws {
        let sheet = try AnotherWayFixture.sheet("Dm7 | Bbmaj7 | Gm7 | A7")
        let observation = MelodyObservation.of(AnotherWayFixture.plain, label: "The tune", key: AnotherWayFixture.key, progression: sheet)
        #expect(observation.surprises.isEmpty, "\(observation.surprises)")
        let own = try #require(AnotherWayFixture.reading("melodist.something-of-its-own", in: Melodist().read(observation)))
        #expect(!own.holds && own.says.contains("Two ways"), "\(own.says)")
        #expect(observation.alternatives.count == 2)

        let pushed = try #require(TuneVariation.vary(AnotherWayFixture.plain, as: .pushed, bars: 4, beatsPerBar: 4, key: AnotherWayFixture.key, chords: sheet.spans))
        let after = MelodyObservation.of(pushed, label: "The tune", key: AnotherWayFixture.key, progression: sheet)
        #expect(!after.surprises.isEmpty)
        #expect(AnotherWayFixture.reading("melodist.something-of-its-own", in: Melodist().read(after))?.holds == true)
    }

    @Test("a tune that comes in on the same degree in the same place as another song's is told so")
    func theSameOpening() throws {
        // The fifth, on the "and" of one: A in D minor, E in A minor.
        let other = try AnotherWayFixture.song("Still Water", chords: "Am | F", opening: (76, 0.5), key: Key(parsing: "A minor")!)
        let another = try AnotherWayFixture.song("Arrival", chords: "Dm | C", opening: (69, 0.5))
        let before = SongsBefore.of(Library(songs: [other, another]), besides: nil)
        var observation = MelodyObservation.of(Melody(notes: [AnotherWayFixture.n(69, 4.5, 0.5), AnotherWayFixture.n(72, 5, 1), AnotherWayFixture.n(74, 6, 2)], lengthInBars: 2),
                                               label: "The tune", key: AnotherWayFixture.key)
        observation.before = before
        let again = try #require(AnotherWayFixture.reading("melodist.not-the-same-opening-again", in: Melodist().read(observation)))
        #expect(!again.holds && again.value == 2 && again.says.contains("Still Water") && again.says.contains("Arrival"), "\(again.says)")

        // One other song is a coincidence: there are only so many places to come in.
        observation.before = SongsBefore.of(Library(songs: [other]), besides: nil)
        #expect(AnotherWayFixture.reading("melodist.not-the-same-opening-again", in: Melodist().read(observation))?.holds == true)
        observation.before = SongsBefore.of(Library(songs: [try AnotherWayFixture.song("Arrival", chords: "Am | F", opening: (72, 0), key: Key(parsing: "A minor")!)]), besides: nil)
        #expect(AnotherWayFixture.reading("melodist.not-the-same-opening-again", in: Melodist().read(observation))?.value == 0)
    }

    @Test("the library is read newest first, six back, without the open song, and a line that answers a tune is not the tune")
    func songsBefore() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var songs = try (0..<8).map { i in
            try AnotherWayFixture.song("Song \(i)", chords: "Dm | Gm | A | Dm", opening: (62 + i, 0), created: start.addingTimeInterval(Double(i) * 86_400))
        }
        let open = songs[7]
        let before = SongsBefore.of(Library(songs: songs), besides: open.id)
        #expect(before.entries.map(\.title) == ["Song 6", "Song 5", "Song 4", "Song 3", "Song 2", "Song 1"])
        #expect(before.entries[0].loop == [0, 5, 7, 0] && before.entries[0].opening == SongsBefore.Opening(degree: 6, beat: 0))

        // Developed, a song holds a line that answers its tune, newer than the tune.
        let loop = try DevelopVariedTests.loop()
        let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 0)))
        #expect(development.versions.contains { Develop.isAnswer($0) })
        let developed = try DevelopFixture.developed(loop.song, development)
        #expect(Guidance.melodies(in: developed).last?.partID == loop.tune.partID)
        #expect(Guidance.progressions(in: developed).last?.partID == loop.chords.partID)
        songs = [developed]
        let entry = try #require(SongsBefore.of(Library(songs: songs), besides: nil).entries.first)
        #expect(entry.loop == [0, 8, 5, 7] && entry.opening == SongsBefore.Opening(degree: 7, beat: 0.5))
    }

    @Test("a house that writes the usual on purpose is not told again: the number stays, the flag goes")
    func houseQuiets() throws {
        let readings = Harmonist().read(try AnotherWayFixture.harmony("Dm7 | Bbmaj7 | Gm7 | A7"))
        let plainBook = HouseBook()
        #expect(plainBook.settle(readings, by: Harmonist.bible) == readings, "nothing decided, nothing changed")

        let book = HouseBook(library: [HouseCallRecord(question: "harmonist.oq.say-the-usual", choice: "alternative",
                                                       how: "four chords on purpose", decidedOn: "2026-10-02")])
        #expect(book.quiets("harmonist.something-of-its-own", in: Harmonist.bible))
        #expect(!book.quiets("harmonist.bass-agrees", in: Harmonist.bible), "only the readings about the usual")
        let settled = book.settle(readings, by: Harmonist.bible)
        let own = try #require(AnotherWayFixture.reading("harmonist.something-of-its-own", in: settled))
        #expect(own.holds && own.value == 0 && own.says.hasSuffix("on purpose.") && !own.says.contains("Two ways"), "\(own.says)")
        #expect(zip(settled, readings).allSatisfy { $0.rule == "harmonist.something-of-its-own" || $0 == $1 })
        // The Melodist's question is its own.
        #expect(!book.quiets("melodist.something-of-its-own", in: Melodist.bible))
    }

    @Test("the four rules are in the bibles, each answering to its open question")
    func bibles() {
        for (bible, prefix) in [(Harmonist.bible, "harmonist"), (Melodist.bible, "melodist")] {
            let question = bible.openQuestions.first { $0.id == "\(prefix).oq.say-the-usual" }
            #expect(question != nil)
            for rule in question?.affects ?? [] {
                #expect(bible.rules.contains { $0.id == rule } && HouseBook.quietable.contains(rule), "\(rule)")
            }
            #expect(question?.affects.count == 2)
        }
    }
}

// MARK: - The Director's two

@Suite("Director: reharmonize and vary_tune", .serialized) @MainActor
struct DirectorAnotherWayTests {

    private func rig(developed: Bool = false) throws -> (rig: WritingFixture.Rig, loop: DevelopFixture.Loop) {
        let loop = try DevelopVariedTests.loop()
        let rig = WritingFixture.rig(loop.song)
        if developed { _ = try #require(rig.app.develop()) }
        rig.app.sectionSettle = 0
        return (rig, loop)
    }

    private func chords(_ app: AppState, in section: SongGraph.Section? = nil) -> String {
        guard let song = app.song else { return "" }
        let version = section.flatMap { AnotherWay.lane(of: .progression, in: $0, of: song)?.version } ?? Guidance.progressions(in: song).last
        if case .progression(let sheet)? = version?.kind { return sheet.symbols() }
        return ""
    }

    @Test("the two are appended after compare_section, and the prompt says when")
    func appended() {
        #expect(Array(DirectorTools.names.suffix(5).prefix(2)) == ["reharmonize", "vary_tune"])
        #expect(DirectorPrompt.system.contains("reharmonize") && DirectorPrompt.system.contains("vary_tune"))
    }

    @Test("one move on the song's chords: the next version, the bass moved to follow, the Harmonist's sentence")
    func oneMove() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"bass-line","section":"","variant":0}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["was"] as? String == "Dm7 | Bbmaj7 | Gm7 | A7" && out["chords"] as? String == "Dm7 | Bbmaj7/D | Gm7/D | A7/C#")
        #expect(out["bass"] as? String == "moved to follow" && out["recorded"] as? Bool == true)
        let song = try #require(rig.app.song)
        let now = try #require(Guidance.progressions(in: song).last)
        #expect(now.partID == loop.chords.partID && now.parents == [loop.chords.id] && now.author == .persona("Harmonist")
                && now.operation == Operation.reharmonize, "the same part, said another way")
        let bass = try #require(Guidance.basslines(in: song).last)
        guard case .bassline(let line) = bass.kind else { Issue.record("no bass"); return }
        #expect(bass.partID == loop.bass.partID && line.notes.map(\.pitch.midi) == [38, 38, 38, 38, 38, 38, 37, 37])
        #expect(rig.app.log.contains { $0.source == .persona("Harmonist") })
        #expect((out["detail"] as? String)?.contains("The tune s") == true, "\(out["detail"] ?? "")")

        // A move the sheet gives nothing to work on is refused with the ones that apply.
        let none = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"bass-line","section":"","variant":0}"#)
        #expect(none.isError && none.content.contains("These apply"), "\(none.content)")
        let wild = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"sideways","section":"","variant":0}"#)
        #expect(wild.isError && wild.content.contains("not a move"))
    }

    @Test("in one section: a variation there, with its bass, and the rest of the song as it was")
    func oneSection() async throws {
        let (rig, loop) = try rig(developed: true)
        defer { rig.clean() }
        let before = try #require(rig.app.song)
        let last = try #require(before.sections.last { $0.name == "Verse" })
        let result = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"borrowed","section":"\#(last.id)","variant":0}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["sections"] as? [String] == ["Verse"] && (out["chords"] as? String)?.contains("G7") == true, "\(out)")
        // The bass plays G under Gm7 and under G7: nothing to move, and the answer says it fits.
        #expect(out["bass"] as? String == "already on these chords" && (out["detail"] as? String)?.contains("nothing clashes") == true)
        let song = try #require(rig.app.song)
        let section = try #require(song.sections.first { $0.id == last.id })
        #expect(chords(rig.app, in: section) == "Dm7 | Bbmaj7 | G7 | A7")
        let lane = try #require(AnotherWay.lane(of: .progression, in: section, of: song))
        #expect(song.variation(of: lane.lane.part) == Variation(of: loop.chords.partID, name: "borrowed"))
        #expect(lane.version.operation == Operation.placed && Develop.isHeld(lane.lane, in: song))
        #expect(section.intensity == last.intensity && section.lengthInBars == last.lengthInBars)
        // The song's own chords, and every other section, are as they were.
        #expect(chords(rig.app) == "Dm7 | Bbmaj7 | Gm7 | A7")
        for other in song.sections where other.id != last.id {
            #expect(other.stitch == before.sections.first { $0.id == other.id }?.stitch, "\(other.name)")
        }
        // And it is a change compare_section can play against how the section stood.
        #expect(rig.app.earlierStates(of: last.id).count == 1)

        // It stays where it was put: developed again, and brought down, the verse still plays it.
        _ = try #require(rig.app.develop())
        #expect(chords(rig.app, in: try #require(rig.app.song?.sections.first { $0.id == last.id })) == "Dm7 | Bbmaj7 | G7 | A7")
        _ = await WritingFixture.run(rig.box, "set_intensity", #"{"section":"\#(last.id)","intensity":0.3}"#)
        #expect(chords(rig.app, in: try #require(rig.app.song?.sections.first { $0.id == last.id })) == "Dm7 | Bbmaj7 | G7 | A7")
    }

    @Test("every player on the song's chords follows a move, in the song and in one section, each played its own way")
    func everyPlayerFollows() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        guard case .progression(var held) = loop.chords.kind else { return }
        held.playing = ChordPlaying(.held, .rootless)
        let pad = PartVersion(partID: PartID(), kind: .progression(held), author: .user, operation: Operation.written, note: "Pad: held")
        var sections = try #require(rig.app.song).sections
        for index in sections.indices { sections[index].stitch.append(Lane(part: pad.partID)) }
        #expect(rig.app.keep([pad], arranged: sections))
        #expect(rig.app.record(loop.chords.deriving(loop.chords.kind, by: .user, operation: Operation.written, note: loop.chords.note), joiningForm: false))

        let whole = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"borrowed","section":"","variant":0}"#)
        #expect(!whole.isError, "\(whole.content)")
        var song = try #require(rig.app.song)
        guard case .progression(let padNow)? = song.latestVersion(of: pad.partID)?.kind else { Issue.record("no pad"); return }
        #expect(padNow.symbols() == "Dm7 | Bbmaj7 | G7 | A7" && padNow.playing?.keysPattern == .held, "\(padNow.symbols())")
        #expect(Guidance.progressions(in: song).last?.partID == loop.chords.partID, "the song's chords are still the song's")
        #expect(chords(rig.app) == "Dm7 | Bbmaj7 | G7 | A7")

        let verse = try #require(song.sections.first { $0.name == "Verse" })
        let one = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"tritone","section":"\#(verse.id)","variant":0}"#)
        #expect(!one.isError, "\(one.content)")
        song = try #require(rig.app.song)
        let section = try #require(song.sections.first { $0.id == verse.id })
        let sheets = section.stitch.compactMap { lane -> Progression? in
            if case .progression(let sheet)? = song.version(playing: lane)?.kind { return sheet }
            return nil
        }
        #expect(sheets.count == 2 && sheets[0].bars == sheets[1].bars && sheets[0].symbols().hasSuffix("A7 Eb7"), "\(sheets.map { $0.symbols() })")
        #expect(Set(sheets.map { $0.playing?.keysPattern ?? .held }).count >= 1)
    }

    @Test("no move: a Compare of the ways, each with its bass, and taking a row keeps both")
    func compare() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "reharmonize", #"{"move":"","section":"","variant":0}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        let ways = try #require(out["ways"] as? [[String: Any]])
        #expect(out["opened"] as? Bool == true && out["recorded"] as? Bool == false)
        #expect(ways.count == 8 && ways.filter { $0["on_compare"] as? Bool == true }.count == 4)
        #expect(ways.first?["move"] as? String == "borrowed" && ways.allSatisfy { $0["tune_on_chords"] is Int })
        #expect(chords(rig.app) == "Dm7 | Bbmaj7 | Gm7 | A7", "nothing was written")

        let item = try #require(rig.app.bench.items.first { $0.kind == .compare })
        guard case .compare(let brief)? = rig.app.answer(for: item.id) else { Issue.record("no brief"); return }
        #expect(brief.reference.version == loop.chords.id && brief.candidates.count == 4)
        #expect(brief.candidates.allSatisfy { $0.version?.partID == loop.chords.partID && $0.proposedBy == .harmonist })
        let bassLine = try #require(brief.candidates.first { $0.id == "bass-line" })
        #expect(bassLine.companions.count == 1 && bassLine.companions[0].partID == loop.bass.partID)

        let adapter = CompareAdapter(app: rig.app, service: WiringFixture.silentService(), surface: item.id)
        #expect(await adapter.choose(bassLine))
        #expect(chords(rig.app) == "Dm7 | Bbmaj7/D | Gm7/D | A7/C#")
        let after = try #require(rig.app.song)
        #expect(Guidance.basslines(in: after).last?.id == bassLine.companions[0].id)
    }

    @Test("the tune, pushed, in the second hook only; then the tune itself; then what it has no room for")
    func varyTune() async throws {
        let (rig, loop) = try rig(developed: true)
        defer { rig.clean() }
        let before = try #require(rig.app.song)
        let hook = try #require(before.sections.first { $0.name == "Hook" })
        let result = await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"pushed","section":"\#(hook.id)"}"#)
        #expect(!result.isError, "\(result.content)")
        let song = try #require(rig.app.song)
        let section = try #require(song.sections.first { $0.id == hook.id })
        let lane = try #require(AnotherWay.lane(of: .melody, in: section, of: song))
        #expect(song.variation(of: lane.lane.part)?.of == loop.tune.partID && song.variation(of: lane.lane.part)?.name == "pushed")
        #expect(Guidance.melodies(in: song).last?.id == loop.tune.id, "the tune itself is as it was")
        #expect(section.stitch.count == hook.stitch.count)

        // With no section, it is the tune's next version.
        let everywhere = await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"sequenced","section":""}"#)
        #expect(!everywhere.isError, "\(everywhere.content)")
        let after = try #require(rig.app.song)
        let tune = try #require(Guidance.melodies(in: after).last)
        #expect(tune.partID == loop.tune.partID && tune.parents == [loop.tune.id] && tune.author == .persona("Melodist"))

        let wild = await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"backwards","section":""}"#)
        #expect(wild.isError && wild.content.contains("not a treatment"))
    }

    @Test("a line that answers the tune goes in the section named, under it, and nowhere else")
    func answers() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let nowhere = await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"answers","section":""}"#)
        #expect(nowhere.isError && nowhere.content.contains("no section was named"))
        let result = await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"answers","section":"Hook"}"#)
        #expect(!result.isError, "\(result.content)")
        let song = try #require(rig.app.song)
        let line = try #require(song.versions.last { Develop.isAnswer($0) })
        #expect(line.variation == nil && line.partID != loop.tune.partID)
        let hook = try #require(song.sections.first { $0.name == "Hook" })
        #expect(hook.stitch.contains(part: line.partID))
        #expect(song.sections.filter { $0.name != "Hook" }.allSatisfy { !$0.stitch.contains(part: line.partID) })
        #expect(Guidance.mix(in: song)?.gainDB(for: line.partID, in: hook.id) == Develop.answeringLevel)
        #expect(Guidance.melodies(in: song).last?.id == loop.tune.id, "the song's tune is still the tune")
    }

    @Test("no treatment: a Compare of the ways the tune has room for, and taking one makes it the tune")
    func compareTunes() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let out = WritingFixture.json(await WritingFixture.run(rig.box, "vary_tune", #"{"treatment":"","section":""}"#))
        #expect(out["opened"] as? Bool == true, "\(out)")
        let item = try #require(rig.app.bench.items.first { $0.kind == .compare })
        guard case .compare(let brief)? = rig.app.answer(for: item.id) else { Issue.record("no brief"); return }
        #expect(brief.reference.version == loop.tune.id && (2...4).contains(brief.candidates.count))
        #expect(brief.candidates.allSatisfy { $0.version?.partID == loop.tune.partID && $0.reading(.melodySurprises) != nil })
        let adapter = CompareAdapter(app: rig.app, service: WiringFixture.silentService(), surface: item.id)
        #expect(await adapter.choose(brief.candidates[0]))
        let after = try #require(rig.app.song)
        #expect(Guidance.melodies(in: after).last?.id == brief.candidates[0].version?.id)
    }

    @Test("set_progression answers with the Harmonist's flags, the library in view")
    func setProgression() async throws {
        let other = try AnotherWayFixture.song("First Light", chords: "Am | F | Dm | E", key: Key(parsing: "A minor")!)
        let rig = WritingFixture.rig(library: Library(songs: [other]))
        defer { rig.clean() }
        let out = WritingFixture.json(await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm | Bb | Gm | A","key":"D minor"}"#))
        let flags = try #require(out["flags"] as? [String])
        #expect(flags.contains { $0.contains("Two ways") } && flags.contains { $0.contains("First Light") }, "\(flags)")
    }
}

// MARK: - On the surfaces

@Suite("Another way, on the Chords sheet and the Piano roll") @MainActor
struct AnotherWaySurfaceTests {

    @Test("the sheet offers its moves, one types the line, and the flag it answers goes; ⌘Z puts it back")
    func chords() throws {
        let model = ChordsModel(host: ChordsStub(), key: AnotherWayFixture.key)
        model.autoKeep.delay = nil
        model.text = "Dm7 | Bbmaj7 | Gm7 | A7"
        #expect(model.flags.contains { $0.rule == "harmonist.something-of-its-own" })
        let ways = model.anotherWays
        #expect(ways.map(\.move).prefix(3) == [.borrowed, .bassLine, .secondaryDominant] && ways.count == 8)
        model.use(way: try #require(ways.first { $0.move == .bassLine }))
        #expect(model.text == "Dm7 | Bbmaj7/D | Gm7/D | A7/C#" && model.problem == nil)
        #expect(!model.flags.contains { $0.rule == "harmonist.something-of-its-own" })
        #expect(!model.anotherWays.contains { $0.move == .bassLine }, "said that way already")
        model.undo()
        #expect(model.text == "Dm7 | Bbmaj7 | Gm7 | A7")

        // A typo offers nothing; the library in view and the house's call reach the sheet.
        model.text = "Dm7 | Bbmaj7 | Gm7 | A7x"
        #expect(model.anotherWays.isEmpty)
        model.text = "Dm7 | Bbmaj7 | Gm7 | A7"
        let other = try AnotherWayFixture.song("First Light", chords: "Am | F | Dm | E", key: Key(parsing: "A minor")!)
        model.before = { SongsBefore.of(Library(songs: [other]), besides: nil) }
        model.genreChanged()
        #expect(model.flags.contains { $0.rule == "harmonist.not-the-last-song-again" && $0.says.contains("First Light") })
        model.house = { HouseBook(library: [HouseCallRecord(question: "harmonist.oq.say-the-usual", choice: "alternative", how: "", decidedOn: "2026-10-02")]) }
        model.genreChanged()
        #expect(!model.flags.contains { $0.rule.hasPrefix("harmonist.something") || $0.rule.hasPrefix("harmonist.not-the-last") })
    }

    @Test("the roll offers a tune its treatments, one plays it that way as one edit, and a bass line is offered none")
    func roll() throws {
        let key = AnotherWayFixture.key
        let chords = try AnotherWayFixture.sheet("Dm7 | Bbmaj7 | Gm7 | A7").spans
        let tune = PartVersion(partID: PartID(), kind: .melody(AnotherWayFixture.plain), author: .user, operation: Operation.written, note: "The tune")
        let model = PianoRollModel(host: RollStub(), groove: nil, chords: chords, key: key, tempo: 96, melody: tune)
        model.autoKeep.delay = nil
        #expect(model.mode == .melody && model.readings.contains { $0.rule == "melodist.something-of-its-own" && !$0.holds })
        #expect(model.tuneWays.contains(.pushed) && model.tuneWays.contains(.answered))
        let before = model.notes
        model.play(as: .pushed)
        #expect(model.notes != before && model.notes.count == before.count && model.lengthInBars == 4)
        #expect(model.readings.contains { $0.rule == "melodist.something-of-its-own" && $0.holds })
        model.undo()
        #expect(model.notes == before)
        model.play(as: .answered)
        #expect(model.lengthInBars == 8 && model.notes.count == before.count * 2)

        model.setMode(.bass)
        #expect(model.tuneWays.isEmpty)
    }
}
