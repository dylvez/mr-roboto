import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A song says which part is its tune, and the band reads that part as the tune: the Melodist,
// vary_tune, the line developing answers it with, the melody words are set to. With none marked
// the band takes what it always took, but never chords written as a melody — the trouble in
// Mirror Ball, 1923, where a strummed guitar was read as "a leap of 14 semitones, 16 notes a bar".

@MainActor
enum TuneFixture {
    static let key = Key(parsing: "D major")!

    static func n(_ midi: Int, _ start: Double, _ duration: Double) -> NoteEvent { DevelopFixture.n(midi, start, duration) }

    /// The strings: one note at a time, D5 to A5, seven semitones.
    static let tune = Melody(notes: [n(74, 0, 1), n(76, 1, 1), n(78, 2, 1), n(81, 3, 1), n(78, 4, 1.5), n(76, 6, 0.5), n(74, 6.5, 1)],
                             lengthInBars: 2)
    /// The strings lifted for the hook, and reaching higher: nine semitones.
    static let lifted = Melody(notes: [n(86, 0, 1), n(88, 1, 1), n(90, 2, 1), n(93, 3, 1), n(95, 4, 1.5), n(90, 6, 0.5), n(86, 6.5, 1)],
                               lengthInBars: 2)
    /// A guitar written as chords to give them a rhythm, strummed: four strings a fiftieth of a
    /// beat apart on every eighth, fourteen semitones from top to bottom. Read note by note, every
    /// note of it starts alone.
    static let guitar = strummed([50, 54, 57, 64], every: 0.5, bars: 2)
    /// A clavinet riff: a busy single line, five semitones, sixteen notes that each sound alone.
    static let riff = Melody(notes: (0..<16).map { i in n([62, 65, 67, 65][i % 4], Double(i) * 0.5, 0.4) }, lengthInBars: 2)

    static func strummed(_ chord: [Int], every step: Double, bars: Int) -> Melody {
        strummed(chord, at: Array(stride(from: 0.0, to: Double(bars * 4), by: step)), bars: bars, length: step * 0.8)
    }

    static func strummed(_ chord: [Int], at beats: [Double], bars: Int, length: Double = 0.4) -> Melody {
        Melody(notes: beats.flatMap { beat in
            chord.enumerated().map { string, pitch in n(pitch, beat + Double(string) * 0.02, length) }
        }, lengthInBars: bars)
    }

    struct Built {
        var song: Song
        var drums: PartVersion
        var chords: PartVersion
        var tune: PartVersion
        var guitar: PartVersion
        var lift: PartVersion
        var riff: PartVersion?
    }

    /// Mirror Ball's trouble, small: the strings' tune, then a guitar's chords written after it
    /// and first in every stitch, and with `riff` a clavinet too. The Hook plays the tune lifted;
    /// the Intro plays no tune at all.
    static func song(riff withRiff: Bool = false) throws -> Built {
        var song = Song.new(title: "Mirror", key: key, tempo: 124)
        let drums = PartVersion(partID: PartID(), kind: .groove(DevelopFixture.groove), author: .user, operation: Operation.written, note: "The beat")
        let chords = PartVersion(partID: PartID(), kind: .progression(try Progression.parse("Dmaj7 | Gmaj7", key: key).get()),
                                 author: .user, operation: Operation.written, note: "Dmaj7 Gmaj7")
        let tune = PartVersion(partID: PartID(), kind: .melody(Self.tune), author: .user, operation: Operation.written, note: "Strings, the tune")
        let guitar = PartVersion(partID: PartID(), kind: .melody(Self.guitar), author: .user, operation: Operation.written, note: "Guitar, strummed")
        let lift = tune.varying(.melody(Self.lifted), as: "lift", by: .user, note: "Strings, lifted")
        let riff = withRiff ? PartVersion(partID: PartID(), kind: .melody(Self.riff), author: .user, operation: Operation.written, note: "Clavinet riff") : nil
        try song.append(contentsOf: [drums, chords, tune, guitar, lift] + [riff].compactMap { $0 })
        let band = [guitar.partID] + [riff?.partID].compactMap { $0 } + [drums.partID, chords.partID]
        song.sections = [
            Section(name: "Intro", stitch: [drums, chords].lanes, lengthInBars: 4),
            Section(name: "Verse", stitch: (band + [tune.partID]).lanes, lengthInBars: 8),
            Section(name: "Hook", stitch: (band + [lift.partID]).lanes, lengthInBars: 8),
        ]
        return Built(song: song, drums: drums, chords: chords, tune: tune, guitar: guitar, lift: lift, riff: riff)
    }

    static func section(_ name: String, in song: Song) -> SongGraph.Section? { song.sections.first { $0.name == name } }

    /// The semitones from a melody's lowest note to its highest: which part the Melodist read.
    static func range(_ version: PartVersion?) -> Int? {
        guard case .melody(let melody)? = version?.kind, let low = melody.notes.map(\.pitch.midi).min(),
              let high = melody.notes.map(\.pitch.midi).max() else { return nil }
        return high - low
    }

    static func toolbox(_ workspace: DirectorScratchWorkspace) -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()), workspace: workspace,
                              audition: DirectorSilentAudition())
    }

    static func run(_ box: DirectorToolbox, _ tool: String, _ json: String) async -> ClaudeToolResult {
        await WritingFixture.run(box, tool, json)
    }
}

/// A song as this app wrote it before a song could say which part is its tune: schema 4, the
/// strings' tune kept twice, a guitar's chords written after it, and the tune lifted for the Hook.
let songBeforeTheTuneFixture = """
{
  "artist" : "Vessel",
  "createdAt" : "2026-10-01T09:00:00.000Z",
  "experiments" : [],
  "genre" : "disco",
  "id" : "5A5A5A5A-0000-4000-8000-000000000001",
  "key" : { "mode" : 1, "tonic" : { "accidental" : 0, "letter" : 1 } },
  "schemaVersion" : 4,
  "sections" : [
    { "id" : "33333333-0000-4000-8000-000000000001", "lengthInBars" : 8, "name" : "Verse",
      "stitch" : [ { "part" : "BBBBBBBB-0000-4000-8000-000000000002" }, { "part" : "AAAAAAAA-0000-4000-8000-000000000001" } ] },
    { "id" : "33333333-0000-4000-8000-000000000002", "intensity" : 0.8, "lengthInBars" : 8, "name" : "Hook",
      "stitch" : [ { "part" : "BBBBBBBB-0000-4000-8000-000000000002" }, { "part" : "CCCCCCCC-0000-4000-8000-000000000003" } ] }
  ],
  "seeds" : [],
  "tempo" : 124,
  "timeSignature" : { "beatUnit" : 4, "beatsPerBar" : 4 },
  "title" : "Mirror",
  "versions" : [
    { "author" : { "role" : "user" }, "createdAt" : "2026-10-01T09:01:00.000Z", "id" : "11111111-0000-4000-8000-000000000001",
      "kind" : { "lengthInBars" : 1, "notes" : [ { "duration" : 1, "pitch" : { "midi" : 74 }, "start" : 0, "velocity" : 100 },
                                                 { "duration" : 1, "pitch" : { "midi" : 76 }, "start" : 1, "velocity" : 100 },
                                                 { "duration" : 2, "pitch" : { "midi" : 78 }, "start" : 2, "velocity" : 100 } ], "type" : "melody" },
      "note" : "Strings, the tune", "operation" : "written", "parents" : [], "partID" : "AAAAAAAA-0000-4000-8000-000000000001" },
    { "author" : { "role" : "user" }, "createdAt" : "2026-10-01T09:02:00.000Z", "id" : "11111111-0000-4000-8000-000000000002",
      "kind" : { "lengthInBars" : 1, "notes" : [ { "duration" : 1, "pitch" : { "midi" : 74 }, "start" : 0, "velocity" : 100 },
                                                 { "duration" : 1, "pitch" : { "midi" : 76 }, "start" : 1, "velocity" : 100 },
                                                 { "duration" : 1, "pitch" : { "midi" : 78 }, "start" : 2, "velocity" : 100 },
                                                 { "duration" : 0.5, "pitch" : { "midi" : 81 }, "start" : 3, "velocity" : 96 } ], "type" : "melody" },
      "note" : "Strings, the tune", "operation" : "edit", "parents" : [ "11111111-0000-4000-8000-000000000001" ],
      "partID" : "AAAAAAAA-0000-4000-8000-000000000001" },
    { "author" : { "name" : "Director", "role" : "persona" }, "createdAt" : "2026-10-01T09:03:00.000Z", "id" : "11111111-0000-4000-8000-000000000003",
      "kind" : { "lengthInBars" : 1, "notes" : [ { "duration" : 0.4, "pitch" : { "midi" : 50 }, "start" : 0, "velocity" : 100 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 54 }, "start" : 0.02, "velocity" : 98 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 57 }, "start" : 0.04, "velocity" : 96 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 64 }, "start" : 0.06, "velocity" : 94 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 50 }, "start" : 2, "velocity" : 100 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 54 }, "start" : 2.02, "velocity" : 98 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 57 }, "start" : 2.04, "velocity" : 96 },
                                                 { "duration" : 0.4, "pitch" : { "midi" : 64 }, "start" : 2.06, "velocity" : 94 } ], "type" : "melody" },
      "note" : "Guitar, strummed", "operation" : "written", "parents" : [], "partID" : "BBBBBBBB-0000-4000-8000-000000000002" },
    { "author" : { "name" : "Producer", "role" : "persona" }, "createdAt" : "2026-10-01T09:04:00.000Z", "id" : "11111111-0000-4000-8000-000000000004",
      "kind" : { "lengthInBars" : 1, "notes" : [ { "duration" : 1, "pitch" : { "midi" : 86 }, "start" : 0, "velocity" : 100 },
                                                 { "duration" : 1, "pitch" : { "midi" : 88 }, "start" : 1, "velocity" : 100 },
                                                 { "duration" : 1, "pitch" : { "midi" : 90 }, "start" : 2, "velocity" : 100 },
                                                 { "duration" : 0.5, "pitch" : { "midi" : 93 }, "start" : 3, "velocity" : 96 } ], "type" : "melody" },
      "note" : "Lifted: the tune an octave up", "operation" : "developed", "parents" : [ "11111111-0000-4000-8000-000000000002" ],
      "partID" : "CCCCCCCC-0000-4000-8000-000000000003",
      "variation" : { "name" : "lift", "of" : "AAAAAAAA-0000-4000-8000-000000000001" } }
  ]
}
"""

// MARK: - The mark

@Suite("The song's tune: marked on the part, and a song from before") @MainActor
struct SongTuneMarkTests {

    @Test("a part is marked, not a version: a variation marks the part it varies and is the tune too; only a melody can be")
    func marking() throws {
        let built = try TuneFixture.song()
        var song = built.song
        #expect(song.tune == nil && !song.isTune(built.tune.partID))
        let byVariation = song.markTune(built.lift.partID)
        #expect(byVariation && song.tune == built.tune.partID, "a variation marks the part it varies")
        #expect(song.isTune(built.tune.partID) && song.isTune(built.lift.partID) && !song.isTune(built.guitar.partID))
        let again = song.markTune(built.tune.partID)
        #expect(!again, "marked already: nothing changed")
        let chords = song.markTune(built.chords.partID), stranger = song.markTune(PartID())
        #expect(!chords && !stranger && song.tune == built.tune.partID, "chords, or a part the song does not hold")
        // One tune a song: marking another moves the mark.
        let moved = song.markTune(built.guitar.partID)
        #expect(moved && song.tune == built.guitar.partID && !song.isTune(built.lift.partID))
        let off = song.markTune(nil), offAgain = song.markTune(nil)
        #expect(off && song.tune == nil && !offAgain)

        // It stays the tune through its edits, and the band reads the edit.
        song.markTune(built.tune.partID)
        let edited = built.tune.deriving(.melody(TuneFixture.tune.transposed(by: 2)), by: .user, operation: Operation.edit)
        try song.append(edited)
        #expect(song.tune == built.tune.partID && SongTune.version(in: song)?.id == edited.id)
    }

    @Test("a song saved before the tune could be marked loads unchanged and is written back as it was; marked, the mark goes with it")
    func oldDocumentRoundTrips() throws {
        let data = Data(songBeforeTheTuneFixture.utf8)
        let song = try SongGraphCodec.decodeSong(from: data)
        #expect(song.tune == nil && song.versions.count == 4 && song.sections.count == 2 && song.genre == "disco")
        let strings = PartID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let lift = PartID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!
        #expect(song.variation(of: lift)?.name == "lift")

        // Written back it is the document it was: no key added, none lost, nothing moved.
        let written = try SongGraphCodec.encodeSong(song)
        #expect(!String(decoding: written, as: UTF8.self).contains("\"tune\""))
        #expect(try SongGraphCodec.decode(JSONValue.self, from: written) == SongGraphCodec.decode(JSONValue.self, from: data))
        #expect(try SongGraphCodec.encodeSong(SongGraphCodec.decodeSong(from: written)) == written, "and byte for byte from then on")

        // Nothing marked, the band reads the strings — not the guitar's chords written after them.
        #expect(SongTune.part(of: song) == strings)
        #expect(SongTune.lane(in: song.sections[1], of: song)?.lane.part == lift)

        // Marked through the variation, the part is what is saved, and it comes back.
        var marked = song
        let byVariation = marked.markTune(lift)
        #expect(byVariation)
        let saved = try SongGraphCodec.encodeSong(marked)
        #expect(try SongGraphCodec.decode(JSONValue.self, from: saved)["tune"]?.stringValue == strings.description)
        let reopened = try SongGraphCodec.decodeSong(from: saved)
        #expect(reopened == marked && reopened.tune == strings)
        // Taken off again, the document is the one from before.
        marked.markTune(nil)
        #expect(try SongGraphCodec.encodeSong(marked) == written)
    }

    @Test("the app marks it as the song's setting and says so; a variation marks its part; nil says what the band takes")
    func appMarks() throws {
        let built = try TuneFixture.song()
        let rig = WritingFixture.rig(built.song)
        defer { rig.clean() }
        let app = rig.app
        #expect(app.setTune(built.lift.partID))
        #expect(app.song?.tune == built.tune.partID && app.hasUnsavedChanges)
        #expect(app.log.last?.text == "Strings, the tune is the song's tune")
        #expect(!app.setTune(built.tune.partID) && !app.setTune(built.chords.partID))
        #expect(app.setTune(nil) && app.song?.tune == nil)
        #expect(app.log.last?.text == "No part is marked as the tune" && app.log.last?.detail?.contains("Strings, the tune") == true,
                "\(String(describing: app.log.last?.detail))")
    }
}

// MARK: - With none marked

@Suite("With no tune marked: the band's own choice, never chords") @MainActor
struct SongTuneFallbackTests {

    @Test("chords are onsets of more than one note, mostly: struck together, strummed or rolled; half is not most")
    func chordLike() {
        let n = TuneFixture.n
        #expect(SongTune.isChords(TuneFixture.guitar), "strummed, a fiftieth of a beat a string")
        #expect(SongTune.isChords(TuneFixture.strummed([50, 57, 62], every: 1, bars: 1)))
        #expect(!SongTune.isChords(TuneFixture.tune) && !SongTune.isChords(TuneFixture.riff))
        // A tune with a chord under its first note and its fifth is still a tune.
        #expect(!SongTune.isChords(Melody(notes: [n(62, 0, 1), n(69, 0, 1), n(64, 1, 1), n(66, 2, 1), n(67, 3, 1), n(62, 4, 1), n(69, 4, 1)])))
        // Half the onsets chords is not most of them; one more is.
        let half = Melody(notes: [n(62, 0, 1), n(66, 0, 1), n(64, 1, 1), n(67, 2, 1), n(71, 2, 1), n(69, 3, 1)])
        #expect(!SongTune.isChords(half))
        #expect(SongTune.isChords(Melody(notes: half.notes + [n(74, 3, 1)])))
        // A sixteenth apart is two notes, not a chord: a fast run is a line.
        #expect(!SongTune.isChords(Melody(notes: (0..<16).map { n(60 + $0 % 5, Double($0) * 0.25, 0.25) })))
        #expect(!SongTune.isChords(Melody(notes: [])))
    }

    @Test("the song's tune is the newest line of its own, never the guitar's chords written after it")
    func songLevel() throws {
        let built = try TuneFixture.song()
        // What the band took before: the newest melody, which is the guitar.
        #expect(Guidance.melodies(in: built.song).last?.partID == built.guitar.partID)
        #expect(SongTune.part(of: built.song) == built.tune.partID)
        #expect(SongTune.version(in: built.song)?.id == built.tune.id)
        #expect(SongTune.marked(in: built.song) == nil)

        // Still the newest line: a riff written after the tune is taken for it, as it always was.
        let withRiff = try TuneFixture.song(riff: true)
        #expect(SongTune.part(of: withRiff.song) == withRiff.riff?.partID)

        // Chords and nothing else: no tune at all, rather than the chords.
        var chordsOnly = Song.new(title: "Strum", key: TuneFixture.key, tempo: 110)
        try chordsOnly.append(PartVersion(partID: PartID(), kind: .melody(TuneFixture.guitar), author: .user, operation: Operation.written, note: "Guitar"))
        #expect(SongTune.part(of: chordsOnly) == nil && SongTune.version(in: chordsOnly) == nil)
        // Nor a line that answers the tune, nor a part set aside.
        var song = built.song
        let answer = PartVersion(partID: PartID(), kind: .melody(TuneFixture.riff), author: .user, operation: Operation.developed,
                                 note: Develop.answerNote(to: built.tune))
        try song.append(answer)
        #expect(SongTune.part(of: song) == built.tune.partID)
        song.setAside(built.tune.partID)
        #expect(SongTune.part(of: song) == nil, "the strings set aside, the guitar's chords are still not the tune")
    }

    @Test("in a section, the line with the most notes that sound alone — never chords, which strummed outnumber it")
    func sectionLevel() throws {
        let built = try TuneFixture.song()
        let verse = try #require(TuneFixture.section("Verse", in: built.song))
        let hook = try #require(TuneFixture.section("Hook", in: built.song))
        // Read note by note, the strummed guitar has the most notes that sound alone.
        #expect(SongTune.soundingAlone(TuneFixture.guitar) > SongTune.soundingAlone(TuneFixture.tune))
        #expect(SongTune.lane(in: verse, of: built.song)?.lane.part == built.tune.partID)
        let lifted = try #require(SongTune.lane(in: hook, of: built.song))
        #expect(lifted.lane.part == built.lift.partID && lifted.root == built.tune.partID)
        #expect(ConveneTool.heard(.melody, in: built.song, section: hook)?.id == built.lift.id)
        #expect(SongTune.lane(in: try #require(TuneFixture.section("Intro", in: built.song)), of: built.song) == nil)

        // Of two lines, the busier, as the Melodist always weighed them: the riff, here.
        let withRiff = try TuneFixture.song(riff: true)
        let riffVerse = try #require(TuneFixture.section("Verse", in: withRiff.song))
        #expect(SongTune.lane(in: riffVerse, of: withRiff.song)?.lane.part == withRiff.riff?.partID)
    }
}

// MARK: - The band reads it

@Suite("The marked tune is the one the band reads", .serialized) @MainActor
struct SongTuneBandTests {

    /// The Melodist's reading of the range: which part it read.
    private func melodistRange(_ result: ClaudeToolResult) -> Double? {
        (WritingFixture.json(result)["readings"] as? [[String: Any]])?
            .first { $0["persona"] as? String == "melodist" && $0["rule"] as? String == "melodist.singable-range" }?["value"] as? Double
    }

    private func convene(_ box: DirectorToolbox, section: String) async -> ClaudeToolResult {
        await TuneFixture.run(box, "convene", #"{"question":"is the tune working?","section":"\#(section)","personas":["melodist"]}"#)
    }

    @Test("the Melodist reads the tune marked, its variation where that plays, and the song's where a section has none")
    func melodist() async throws {
        var built = try TuneFixture.song(riff: true)
        let workspace = DirectorScratchWorkspace(song: built.song)
        let box = TuneFixture.toolbox(workspace)
        // Nothing marked: the busiest line in the Hook, the riff — five semitones — and never the guitar's fourteen.
        #expect(melodistRange(await convene(box, section: "Hook")) == 5)

        built.song.markTune(built.tune.partID)
        let marked = DirectorScratchWorkspace(song: built.song)
        let markedBox = TuneFixture.toolbox(marked)
        #expect(melodistRange(await convene(markedBox, section: "Hook")) == Double(TuneFixture.range(built.lift) ?? 0), "the lift, nine")
        #expect(melodistRange(await convene(markedBox, section: "Verse")) == 7)
        #expect(melodistRange(await convene(markedBox, section: "")) == 7)
        let intro = await convene(markedBox, section: "Intro")
        #expect(melodistRange(intro) == 7)
        #expect((WritingFixture.json(intro)["detail"] as? String)?.contains("Intro plays no tune; the Melodist read the song's, Strings, the tune.") == true,
                "\(intro.content)")
    }

    @Test("vary_tune plays the marked tune another way, in its own lane, and leaves the guitar and the riff where they are")
    func varyTune() async throws {
        var built = try TuneFixture.song(riff: true)
        built.song.markTune(built.tune.partID)
        let workspace = DirectorScratchWorkspace(song: built.song)
        let box = TuneFixture.toolbox(workspace)
        let result = await TuneFixture.run(box, "vary_tune", #"{"treatment":"sparse","section":"Verse"}"#)
        #expect(!result.isError, "\(result.content)")
        #expect(WritingFixture.json(result)["tune"] as? String == "Strings, the tune")
        let song = try #require(workspace.song)
        let verse = try #require(TuneFixture.section("Verse", in: song))
        let before = try #require(TuneFixture.section("Verse", in: built.song))
        #expect(verse.stitch.count == before.stitch.count)
        #expect(Array(verse.stitch.prefix(4)) == Array(before.stitch.prefix(4)), "the guitar, the riff, the drums and the chords as they were")
        let varied = try #require(verse.stitch.last?.part)
        #expect(song.variation(of: varied)?.of == built.tune.partID && song.isTune(varied))

        // Nothing marked and no riff, the guitar first in the stitch is still not what it varies.
        let plain = try TuneFixture.song()
        let unmarked = DirectorScratchWorkspace(song: plain.song)
        let again = await TuneFixture.run(TuneFixture.toolbox(unmarked), "vary_tune", #"{"treatment":"sparse","section":"Verse"}"#)
        #expect(!again.isError, "\(again.content)")
        let after = try #require(unmarked.song.flatMap { TuneFixture.section("Verse", in: $0) })
        #expect(after.stitch.first?.part == plain.guitar.partID)
        #expect(unmarked.song?.variation(of: try #require(after.stitch.last?.part))?.of == plain.tune.partID)
    }

    @Test("develop answers the tune, not the guitar first in the stitch, and marks it; put back, the mark goes with the form")
    func develop() async throws {
        var loop = try DevelopVariedTests.loop()
        // Three strums and a rest, every bar: rests long enough for a line to answer in, as the
        // tune has, so only which of the two is the tune decides what is answered.
        let strums = TuneFixture.strummed([50, 53, 57, 62], at: [0, 0.5, 1, 4, 4.5, 5, 8, 8.5, 9, 12, 12.5, 13], bars: 4)
        #expect(SongTune.isChords(strums) && TuneVariation.answers(to: strums, beatsPerBar: 4) != nil)
        let guitar = PartVersion(partID: PartID(), kind: .melody(strums), author: .user, operation: Operation.written, note: "Guitar, strummed")
        try loop.song.append(guitar)
        for index in loop.song.sections.indices { loop.song.sections[index].stitch.insert(Lane(part: guitar.partID), at: 0) }

        let development = try #require(Develop.plan(for: loop.song, harmony: .varied(seed: 0)))
        let answers = try #require(development.versions.first { Develop.isAnswer($0) })
        #expect(answers.note?.hasPrefix("Answers to The tune") == true, "\(answers.note ?? "")")
        #expect(development.tune == loop.tune.partID, "what developing treated as the tune is marked")

        // Marked already, developing leaves the mark be; a line still answers the marked tune.
        var marked = loop.song
        marked.markTune(loop.tune.partID)
        let again = try #require(Develop.plan(for: marked, harmony: .varied(seed: 0)))
        #expect(again.tune == nil)
        #expect(again.versions.first { Develop.isAnswer($0) }?.note?.hasPrefix("Answers to The tune") == true)

        // The app keeps the mark with the arrangement, and takes it off with it.
        let rig = WritingFixture.rig(loop.song)
        defer { rig.clean() }
        _ = try #require(rig.app.develop())
        #expect(rig.app.song?.tune == loop.tune.partID)
        #expect(rig.app.log.last?.detail?.contains("The tune is marked as the song's tune.") == true, "\(rig.app.log.last?.detail ?? "")")
        #expect(rig.app.putBackDevelopment() && rig.app.song?.tune == nil)

        // As does the Director's scratch workspace; and a tune marked since is somebody's, and stays.
        let workspace = DirectorScratchWorkspace(song: loop.song)
        _ = try #require(await workspace.develop(form: nil))
        #expect(workspace.song?.tune == loop.tune.partID)
        workspace.setTune(guitar.partID)
        #expect(workspace.putBackDevelopment() && workspace.song?.tune == guitar.partID)
    }

    @Test("words are set to the song's tune, not the newest melody; a melody named is still the one named")
    func lyricist() async throws {
        let built = try TuneFixture.song()
        let workspace = DirectorScratchWorkspace(song: built.song)
        let box = TuneFixture.toolbox(workspace)
        let words = #"Up in the light\nDown again"#
        for alias in ["tune", "newest"] {
            let out = WritingFixture.json(await TuneFixture.run(box, "write_lyrics", #"{"text":"\#(words)","align_to":"\#(alias)"}"#))
            #expect(out["melody"] as? String == built.tune.id.description, "\(alias): \(out)")
        }
        let named = WritingFixture.json(await TuneFixture.run(box, "write_lyrics", #"{"text":"\#(words)","align_to":"\#(built.guitar.id)"}"#))
        #expect(named["melody"] as? String == built.guitar.id.description)

        // The Lyrics surface says which melody is the tune; the frame's next step sets the words to it.
        let rig = WritingFixture.rig(built.song)
        defer { rig.clean() }
        let choices = LyricsAdapter(app: rig.app).melodies
        #expect(choices.filter(\.isTune).map(\.part) == [built.tune.partID], "\(choices.map(\.title))")
        let unset = Lyricist.lyric(from: "Up in the light")
        #expect(unset.alignedTo == nil)
        #expect(rig.app.record(PartVersion(partID: PartID(), kind: .lyric(unset), author: .user, operation: Operation.written, note: "Words")))
        let proposals = Guidance.allProposals(for: rig.app.song)
        #expect(proposals.contains { $0.title == "Set the words to Strings, the tune" }, "\(proposals.map(\.title))")
    }

    @Test("write_melody marks what it writes; mark_tune moves the mark, takes it off, and refuses what is not a melody")
    func writeAndMark() async throws {
        var built = try TuneFixture.song()
        built.song.markTune(built.tune.partID)
        let workspace = DirectorScratchWorkspace(song: built.song)
        let box = TuneFixture.toolbox(workspace)

        let written = await TuneFixture.run(box, "write_melody",
                                            #"{"notes":"F#5 0 1, E5 1 1, D5 2 2","bars":1,"instrument":"","parent":"","note":"A counter-line","draft":3}"#)
        #expect(!written.isError, "\(written.content)")
        let line = try #require((WritingFixture.json(written)["part"] as? String).flatMap(PartID.init(uuidString:)))
        #expect(workspace.song?.tune == line)
        #expect((WritingFixture.json(written)["detail"] as? String)?.contains("where Strings, the tune was") == true, "\(written.content)")

        // The mark back on the strings, by a version id.
        let back = WritingFixture.json(await TuneFixture.run(box, "mark_tune", #"{"part":"\#(built.tune.id)"}"#))
        #expect(workspace.song?.tune == built.tune.partID)
        #expect(back["marked"] as? Bool == true && back["title"] as? String == "Strings, the tune" && back["was"] as? String == "A counter-line", "\(back)")
        #expect(back["sections"] as? [String] == ["Verse", "Hook"], "the tune, and its lift in the Hook")
        // By a variation's part id, it is the part it varies; again, it is said to be marked already.
        let same = WritingFixture.json(await TuneFixture.run(box, "mark_tune", #"{"part":"\#(built.lift.partID)"}"#))
        #expect((same["detail"] as? String)?.hasPrefix("Strings, the tune was the song's tune already") == true, "\(same)")

        let chords = await TuneFixture.run(box, "mark_tune", #"{"part":"\#(built.chords.id)"}"#)
        #expect(chords.isError && chords.content.contains("not a melody"))
        let nowhere = await TuneFixture.run(box, "mark_tune", #"{"part":"\#(PartID())"}"#)
        #expect(nowhere.isError && nowhere.content.contains("no part"))

        // Taken off, the band reads the newest line of its own that is not chords: the counter-line.
        let off = WritingFixture.json(await TuneFixture.run(box, "mark_tune", #"{"part":""}"#))
        #expect(workspace.song?.tune == nil && off["marked"] as? Bool == false && off["title"] as? String == "A counter-line", "\(off)")
        let read = WritingFixture.json(await TuneFixture.run(box, "read_song", "{}"))
        let tune = try #require(read["tune"] as? [String: Any])
        #expect(tune["title"] as? String == "A counter-line" && tune["marked"] as? Bool == false && tune["part"] as? String == line.description)
    }
}

// MARK: - The Piano roll

/// A host that keeps the mark the way the song does, without the song.
@MainActor
private final class TuneRollHost: PianoRollHosting {
    var marked: PartID?
    var committed: [PartVersion] = []
    func audition(note: Int, velocity: Int, duration: Double, sound: String) async {}
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async {}
    func setInstrument(_ id: String, for part: PartID?) {}
    func stop() async {}
    func commit(_ version: PartVersion) -> Bool { committed.append(version); return true }
    func isTune(_ part: PartID) -> Bool { part == marked }
    func markTune(_ part: PartID?) { marked = part }
}

@Suite("The Piano roll marks the song's tune") @MainActor
struct SongTuneRollTests {

    @Test("a tune is marked as the song's from the roll, and unmarked; a bass line is not offered it")
    func marksAKeptTune() throws {
        let built = try TuneFixture.song()
        let host = TuneRollHost()
        let roll = PianoRollModel(host: host, groove: PianoRollTests.kicking(), key: TuneFixture.key, tempo: 124, melody: built.tune)
        roll.autoKeep.delay = nil
        #expect(roll.mode == .melody && !roll.isTheSongsTune)
        roll.markAsTheSongsTune(true)
        #expect(host.marked == built.tune.partID && roll.isTheSongsTune)
        roll.markAsTheSongsTune(false)
        #expect(host.marked == nil && !roll.isTheSongsTune)

        let bass = PianoRollModel(host: host, groove: PianoRollTests.kicking(), key: TuneFixture.key, tempo: 124)
        bass.markAsTheSongsTune(true)
        #expect(host.marked == nil && !bass.isTheSongsTune)
    }

    @Test("a tune not kept yet is marked at its first keep")
    func marksAFreshTune() {
        let host = TuneRollHost()
        let roll = PianoRollModel(host: host, groove: PianoRollTests.kicking(), key: TuneFixture.key, tempo: 124)
        roll.autoKeep.delay = nil
        roll.startFreshTune()
        roll.addNote(pitch: 74, at: 0, duration: 1)
        roll.addNote(pitch: 76, at: 1, duration: 1)
        roll.markAsTheSongsTune(true)
        #expect(roll.isTheSongsTune && host.marked == nil, "no part to name yet")
        #expect(roll.keepNow())
        #expect(host.marked == host.committed.last?.partID && host.marked != nil && roll.isTheSongsTune)
    }

    @Test("through the app: the roll's host marks the part, and a variation of it is the tune")
    func throughTheApp() throws {
        let built = try TuneFixture.song()
        let rig = WritingFixture.rig(built.song)
        defer { rig.clean() }
        let host = BassAdapter(app: rig.app, service: WiringFixture.silentService())
        let roll = PianoRollModel(host: host, groove: PianoRollTests.kicking(), key: TuneFixture.key, tempo: 124, melody: built.lift)
        roll.markAsTheSongsTune(true)
        #expect(rig.app.song?.tune == built.tune.partID, "the lift marks the strings")
        #expect(host.isTune(built.tune.partID) && roll.isTheSongsTune && !host.isTune(built.guitar.partID))
    }
}
