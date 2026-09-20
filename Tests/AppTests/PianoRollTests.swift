import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// B3 and B4: the Chords and Piano roll surfaces, driven through stub hosts. What is asserted is
// the contract every surface honours — binds to parts, plays on touch, an edit is a new version —
// plus the two things these surfaces add: the writer's levers, and the Bassist's readings on the
// surface.

@MainActor
final class RollStub: PianoRollHosting {
    var auditioned: [(note: Int, duration: Double, sound: String)] = []
    var played: [Bassline] = []
    var committed: [PartVersion] = []
    var refuses = false

    func audition(note: Int, velocity: Int, duration: Double, sound: String) async {
        auditioned.append((note, duration, sound))
    }
    func play(_ bassline: Bassline, tempo: Double, timeSignature: TimeSignature) async { played.append(bassline) }
    var melodyAuditioned: [(note: Int, instrument: String)] = []
    var melodiesPlayed: [(notes: [NoteEvent], instrument: String)] = []
    var instrument = InstrumentVoiceSpec.rhodes.id
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async {
        melodyAuditioned.append((note, instrument))
    }
    func playMelody(_ notes: [NoteEvent], tempo: Double, timeSignature: TimeSignature, instrument: String) async {
        melodiesPlayed.append((notes, instrument))
    }
    func setInstrument(_ id: String) { instrument = id }
    func stop() async {}
    func commit(_ version: PartVersion) async -> Bool {
        if refuses { return false }
        committed.append(version)
        return true
    }
}

@MainActor
final class ChordsStub: ChordsHosting {
    var auditioned: [[Int]] = []
    var committed: [PartVersion] = []
    var instrument = InstrumentVoiceSpec.rhodes.id
    func audition(pitches: [Int], duration: Double) async { auditioned.append(pitches) }
    func setInstrument(_ id: String) { instrument = id }
    func commit(_ version: PartVersion) async -> Bool { committed.append(version); return true }
}

@Suite("Piano roll") @MainActor
struct PianoRollTests {

    static let key = Key(tonic: NoteName(.d), mode: .aeolian)

    static func groove() -> (PartVersion, Groove) {
        let built = GuidanceFixture.grooved()
        let version = built.groove!
        guard case .groove(let g) = version.kind else { fatalError() }
        return (version, g)
    }

    /// A groove with a kick, since the fixture's groove is silent.
    static func kicking() -> Groove {
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : .rest })
        }
        return Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            line(.kick, "x-----x---------x-----x---------"),
            line(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-"),
        ])
    }

    @Test("opened on a groove, it writes a line under it and the Bassist reads it")
    func writesUnderAGroove() {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), grooveVersion: VersionID(), key: Self.key, tempo: 92)
        #expect(!model.notes.isEmpty)
        #expect(model.sound == "finger")
        #expect(!model.isHandEdited)
        #expect(model.usesDefaultChords)
        #expect(!model.readings.isEmpty)
        #expect(model.readings.contains { $0.rule == "bassist.lag-budget" && $0.holds })
        #expect(model.kickBeats == [0, 1.5, 4, 5.5])
        #expect(model.title.hasPrefix("Palladino line"))
    }

    @Test("the levers re-run the writer; the sound picker does not")
    func levers() {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        let written = model.notes
        model.setLag(60)
        #expect(model.lagMS == 60)
        #expect(model.notes != written)
        #expect(model.observation.map { (55...65).contains($0.medianKickOffsetMS) } == true)

        model.setLineage(.programmed)
        #expect(model.sound == "sub")
        #expect(model.lagMS == 0)
        #expect(model.observation?.isSub == true)

        let before = model.notes
        model.setSound("finger")
        #expect(model.notes == before, "a sound change keeps the notes")
        #expect(model.sound == "finger")
        model.setSound("theremin")
        #expect(model.sound == "finger", "an unknown sound is ignored")

        model.setLag(200)
        #expect(model.lagMS == Bassist.lagCeilingMS, "the lever stops at the bible's ceiling")
    }

    @Test("a hand edit is a hand edit: it auditions, refreshes the readings, and marks the line")
    func editing() async throws {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        let count = model.notes.count
        model.addNote(pitch: 38, at: 2.6)
        #expect(model.notes.count == count + 1)
        #expect(model.isHandEdited)
        #expect(model.notes.contains { $0.pitch.midi == 38 && $0.start == 2.5 }, "snapped to the sixteenth")
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.auditioned.last?.note == 38)

        let index = model.notes.firstIndex { $0.pitch.midi == 38 }!
        model.moveNote(at: index, toStart: 3.1, pitch: 40)
        #expect(model.notes[index].start == 3.0)
        #expect(model.notes[index].pitch.midi == 40)
        model.resizeNote(at: index, toDuration: 1.3)
        #expect(model.notes[index].duration == 1.25)
        model.deleteNote(at: index)
        #expect(model.notes.count == count)
        #expect(!model.readings.isEmpty)
    }

    @Test("a commit is a new version: rooted on the groove when new, derived when opened on a line")
    func commits() async throws {
        let stub = RollStub()
        let (grooveVersion, groove) = Self.groove()
        let model = PianoRollModel(host: stub, groove: groove, grooveVersion: grooveVersion.id, key: Self.key, tempo: 92)
        let first = model.commit()
        #expect(first.type == .bassline)
        #expect(first.parents == [grooveVersion.id])
        #expect(first.operation == Operation.written)
        #expect(first.note?.contains("Palladino") == true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.committed.map(\.id) == [first.id])

        // Opened on that line: edits derive from it.
        let editor = PianoRollModel(host: stub, groove: groove, grooveVersion: grooveVersion.id, key: Self.key,
                                    tempo: 92, bassline: first)
        #expect(editor.isHandEdited, "an opened line is treated as the user's, not the writer's")
        #expect(editor.notes == model.notes)
        editor.addNote(pitch: 40, at: 1)
        let second = editor.commit()
        #expect(second.parents == [first.id])
        #expect(second.partID == first.partID)
        #expect(second.operation == Operation.edit)
        #expect(editor.surface.bound.first == first.id)
    }

    @Test("a host that refuses the version is reported, not ignored")
    func refused() async throws {
        let stub = RollStub()
        stub.refuses = true
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        model.commit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.lastError != nil)
    }

    @Test("without a groove there is nothing to write under, and it says so instead of inventing one")
    func noGroove() {
        let model = PianoRollModel(host: RollStub(), groove: nil, key: Self.key, tempo: 92)
        #expect(model.notes.isEmpty)
        #expect(model.readings.isEmpty)
        #expect(model.observation == nil)
    }

    @Test("play line hands the whole line to the host")
    func play() async throws {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        model.playLine()
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.played.first == model.bassline)
    }
}

@Suite("Chords") @MainActor
struct ChordsTests {

    @Test("symbols parse the way a lead sheet writes them", arguments: [
        ("Dm7", Chord(.d, .minorSeventh)), ("G7", Chord(.g, .dominantSeventh)), ("Cmaj7", Chord(.c, .majorSeventh)),
        ("Ebm11", nil), ("Bbmaj7", Chord(.aSharp, .majorSeventh)), ("F#m7b5", Chord(.fSharp, .halfDiminishedSeventh)),
        ("C/E", Chord(root: .c, quality: .major, inversion: 1)), ("Am", Chord(.a, .minor)), ("E", Chord(.e, .major)),
        ("H7", nil), ("Cmaj9", nil),
    ] as [(String, Chord?)])
    func parsing(symbol: String, expected: Chord?) {
        #expect(Chord(parsing: symbol) == expected, "\(symbol)")
    }

    @Test("every symbol the module can spell round-trips")
    func roundTrip() {
        for quality in ChordQuality.allCases {
            for root in PitchClass.allCases {
                let chord = Chord(root, quality)
                #expect(Chord(parsing: chord.symbol()) == chord, "\(chord.symbol())")
                #expect(Chord(parsing: chord.symbol(preferring: .flats)) == chord, "\(chord.symbol(preferring: .flats))")
            }
        }
    }

    @Test("a typed line becomes bars, and back")
    func progression() throws {
        let key = Key(tonic: NoteName(.c))
        let parsed = try Progression.parse("Dm7 G7 | Cmaj7 | | Am7", key: key).get()
        #expect(parsed.bars.count == 3)
        #expect(parsed.bars[0].chords.map(\.beats) == [2, 2])
        #expect(parsed.bars[1].chords.map(\.beats) == [4])
        #expect(parsed.symbols() == "Dm7 G7 | Cmaj7 | Am7")
        #expect(parsed.spans.count == 4)
        if case .failure(let error) = Progression.parse("Dm7 | Xyz", key: key) {
            #expect(error.symbol == "Xyz")
        } else { Issue.record("a bad symbol should fail the whole line") }
    }

    @Test("the surface: empty is the key's I–IV–V–I, typing parses live, a bar plays, a commit is a version")
    func surface() async throws {
        let stub = ChordsStub()
        let model = ChordsModel(host: stub, key: Key(tonic: NoteName(.d), mode: .aeolian))
        #expect(model.isDefault)
        #expect(model.progression?.bars.count == 4)
        #expect(model.problem == nil)

        model.text = "Dm7 G7 | Cmaj7"
        #expect(!model.isDefault)
        #expect(model.progression?.bars.count == 2)
        #expect(model.numeral(of: Chord(.d, .minorSeventh)) == "i7")

        model.text = "Dm7 | Pq"
        #expect(model.problem?.contains("Pq") == true)
        #expect(model.commit() == nil, "a line with a typo is not kept")

        model.text = "Dm7 G7 | Cmaj7"
        model.audition(Chord(.g, .dominantSeventh))
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.auditioned.first == [55, 59, 62, 65])

        let version = try #require(model.commit())
        #expect(version.type == .progression)
        #expect(version.note?.contains("Dm7 G7 | Cmaj7") == true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(stub.committed.count == 1)

        // Reopened on it, the text is the progression's own symbols and edits derive.
        let editor = ChordsModel(host: stub, key: Key(tonic: NoteName(.c)), progression: version)
        #expect(editor.text == "Dm7 G7 | Cmaj7")
        #expect(editor.key == Key(tonic: NoteName(.d), mode: .aeolian), "the progression's key wins over the song's")
        editor.text = "Dm7 G7 | Cmaj7 | Am7"
        let second = try #require(editor.commit())
        #expect(second.parents == [version.id])
        #expect(second.operation == Operation.edit)
    }
}

// The melody mode: the same grid writing a different part, on the pitched instrument.

@Suite("Piano roll: melody mode") @MainActor
struct PianoRollMelodyTests {

    private func roll() -> (PianoRollModel, RollStub) {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: nil, key: PianoRollTests.key, tempo: 92)
        return (model, stub)
    }

    @Test("switching to melody changes what it commits, what sounds it, and who reads it")
    func theMode() async {
        let (model, stub) = roll()
        #expect(model.mode == .bass && model.writesFromLevers)
        model.addNote(pitch: 72, at: 0)
        model.addNote(pitch: 76, at: 1)
        // The audition is fired into a task; let it run before reading what it did.
        await Task.yield()
        #expect(!stub.auditioned.isEmpty && stub.melodyAuditioned.isEmpty, "a bass note goes to the bass")

        model.setMode(.melody)
        #expect(!model.writesFromLevers, "nothing in the app writes a tune")
        #expect(model.readings.isEmpty, "the Bassist does not read a melody")
        model.addNote(pitch: 79, at: 2)
        await Task.yield()
        #expect(stub.melodyAuditioned.last?.note == 79, "a melody note goes to the instrument")
        #expect(stub.melodyAuditioned.last?.instrument == InstrumentVoiceSpec.rhodes.id)

        model.playLine()
        await Task.yield()
        #expect(stub.melodiesPlayed.count == 1 && stub.melodiesPlayed[0].notes.count == 3)

        let version = model.commit()
        guard case .melody(let melody) = version.kind else {
            Issue.record("committed \(version.type) rather than a melody")
            return
        }
        #expect(melody.notes.count == 3 && version.note?.contains("Melody, 3 notes on the Rhodes") == true)
    }

    @Test("the instrument is the song's: choosing one tells the host, and an unknown preset is ignored")
    func theInstrument() async {
        let (model, stub) = roll()
        model.setMode(.melody)
        model.setInstrument(InstrumentVoiceSpec.warmPad.id)
        #expect(model.instrument == "pad" && stub.instrument == "pad")
        model.setInstrument("no-such-instrument")
        #expect(model.instrument == "pad", "an unknown preset changes nothing")
        let version = model.commit()
        #expect(version.note?.contains("Warm Pad") == true, "\(version.note ?? "")")
    }

    @Test("back to bass: it commits a bass line again and the Bassist reads it")
    func backToBass() {
        let (model, _) = roll()
        model.addNote(pitch: 40, at: 0)
        model.setMode(.melody)
        model.setMode(.bass)
        #expect(model.writesFromLevers)
        let version = model.commit()
        #expect(version.type == .bassline)
    }
}
