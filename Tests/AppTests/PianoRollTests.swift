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
    var instrumentParts: [PartID?] = []
    func setInstrument(_ id: String, for part: PartID?) { instrument = id; instrumentParts.append(part) }
    func stop() async {}
    func commit(_ version: PartVersion) -> Bool {
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
    var instrumentParts: [PartID?] = []
    func setInstrument(_ id: String, for part: PartID?) { instrument = id; instrumentParts.append(part) }
    func commit(_ version: PartVersion) -> Bool { committed.append(version); return true }
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

    @Test("a hand-edited line holds the levers: they move, the notes stay, until the explicit rewrite")
    func leversHeldOverHandEdits() {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        #expect(!model.leversAreHeld, "a written line is the writer's to rewrite")
        model.addNote(pitch: 38, at: 2.5)
        let edited = model.notes
        #expect(model.leversAreHeld)

        model.setLag(60)
        #expect(model.lagMS == 60, "the lever moves")
        #expect(model.notes == edited, "the notes do not")
        model.setDensity(0.9)
        model.setEarlyAlternation(true)
        model.rewrite()
        model.setLineage(.programmed)
        #expect(model.notes == edited, "no lever, and not Rewrite, writes over a hand edit")
        #expect(model.isHandEdited)
        #expect(model.sound == "sub", "the lineage's sound still follows: a sound change keeps the notes")

        model.writeOverHandEdits()
        #expect(!model.isHandEdited)
        #expect(!model.leversAreHeld)
        #expect(model.notes != edited, "the explicit step is the one thing that rewrites")
        let written = model.notes
        model.setLag(20)
        #expect(model.notes != written, "and the levers write live again")

        // Opened on a line, the levers are held from the start: that line is the user's.
        let editor = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92, bassline: model.commit())
        #expect(editor.leversAreHeld)
        let opened = editor.notes
        editor.setDensity(0.1)
        #expect(editor.notes == opened)

        // Without a groove there is nothing the levers could write, so nothing is held either.
        let bare = PianoRollModel(host: stub, groove: nil, key: Self.key, tempo: 92)
        bare.addNote(pitch: 40, at: 0)
        #expect(!bare.leversAreHeld)
    }

    @Test("click selects, Delete removes the selection, Escape clears it")
    func selection() {
        let model = PianoRollModel(host: RollStub(), groove: Self.kicking(), key: Self.key, tempo: 92)
        let count = model.notes.count
        #expect(model.selectedNote == nil)
        model.select(0)
        #expect(model.selectedNote == 0)
        model.select(999)
        #expect(model.selectedNote == nil, "an index the list does not have selects nothing")
        model.select(1)
        model.clearSelection()
        #expect(model.selectedNote == nil)
        model.deleteSelectedNote()
        #expect(model.notes.count == count, "nothing selected, nothing removed")

        model.addNote(pitch: 45, at: 3)
        #expect(model.selectedNote.map { model.notes[$0].pitch.midi } == 45, "a new note is the selection, one Delete from undone")
        model.deleteSelectedNote()
        #expect(model.notes.count == count)
        #expect(model.selectedNote == nil)

        model.select(0)
        model.writeOverHandEdits()
        #expect(model.selectedNote == nil, "a rewrite replaces the list, so an index into it means nothing")
    }

    @Test("the keep control follows the notes: nothing to keep after a keep, something again after an edit")
    func unkeptChanges() async throws {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92)
        model.autoKeep.delay = nil
        #expect(!model.hasUnkeptChanges, "the writer's draft is a proposal: opening the roll writes nothing into the song")
        #expect(model.keepLine == .untouched)
        model.useThisLine()
        let first = try #require(model.versions.last)
        #expect(!model.hasUnkeptChanges)
        #expect(model.lastKept?.id == first.id)

        model.setSound("sub")
        #expect(model.hasUnkeptChanges, "the sound is on the part, so it counts")
        model.setSound("finger")
        #expect(!model.hasUnkeptChanges)

        model.addNote(pitch: 40, at: 1)
        #expect(model.hasUnkeptChanges)
        let second = model.commit()
        #expect(!model.hasUnkeptChanges)
        #expect(model.lastKept?.id == second.id)

        // Opened on a line: nothing to keep until it is touched. A mode switch is not a touch —
        // the notes are the bass line's until something is done to them — but an edit there is,
        // and what it makes is a tune: a different part from the bass line it was opened on.
        let editor = PianoRollModel(host: stub, groove: Self.kicking(), key: Self.key, tempo: 92, bassline: first)
        editor.autoKeep.delay = nil
        #expect(!editor.hasUnkeptChanges)
        editor.setMode(.melody)
        #expect(!editor.hasUnkeptChanges, "switching is not writing a tune")
        editor.addNote(pitch: 62, at: 2)
        #expect(editor.hasUnkeptChanges, "a melody is a different part from the bass line it was opened on")
        editor.undo()
        editor.setMode(.bass)
        #expect(!editor.hasUnkeptChanges)

        // A refused keep leaves no version behind, and says so at once.
        stub.refuses = true
        editor.addNote(pitch: 41, at: 0)
        _ = editor.commit()
        #expect(editor.lastError != nil)
        #expect(editor.versions.isEmpty, "a refused version is not a version")
        #expect(editor.lastKept == nil)
        #expect(editor.hasUnkeptChanges)
        if case .refused = editor.keepLine {} else { Issue.record("the status line says the song refused it") }
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

    @Test("the key is typed: a key it reads moves the bars; one it does not leaves the key alone and says so")
    func keyField() {
        let model = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)))
        #expect(model.progression?.key == Key(tonic: NoteName(.c)))

        #expect(model.setKey(parsing: "F# minor"))
        let fSharpMinor = Key(tonic: NoteName(.f, .sharp), mode: .aeolian)
        #expect(model.key == fSharpMinor)
        #expect(model.keyProblem == nil)
        #expect(model.progression?.key == fSharpMinor, "the default bars follow the key")
        #expect(model.progression?.bars.first?.chords.first?.chord.root == .fSharp)

        #expect(!model.setKey(parsing: "H major"))
        #expect(model.keyProblem?.contains("Not a key") == true)
        #expect(model.key == fSharpMinor, "a line that does not read leaves the key alone")
        #expect(model.progression?.key == fSharpMinor)

        #expect(!model.setKey(parsing: "   "))
        #expect(model.keyProblem != nil)

        #expect(model.setKey(parsing: "Bb"))
        #expect(model.key == Key(tonic: NoteName(.b, .flat)), "a tonic alone is its major")
        #expect(model.keyProblem == nil, "a good line clears the problem")
        #expect(model.setKey(parsing: "E dorian"))
        #expect(model.key.mode == .dorian)
    }

    @Test("a typo leaves the last bars on screen but marks them stale, and there is nothing to keep")
    func staleBars() {
        let model = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)))
        model.text = "Dm7 G7 | Cmaj7"
        #expect(!model.barsAreStale)
        #expect(model.hasUnkeptChanges)

        model.text = "Dm7 G7 | Cmaj7 | Xz"
        #expect(model.barsAreStale)
        #expect(model.progression?.bars.count == 2, "the last line that read is still there")
        #expect(!model.hasUnkeptChanges, "a line with a typo has nothing to keep")

        model.text = "Dm7 G7 | Cmaj7 | Am7"
        #expect(!model.barsAreStale)
        #expect(model.progression?.bars.count == 3)
    }

    @Test("the keep control follows the bars: nothing to keep after a keep, something again after a change")
    func unkeptChanges() throws {
        let stub = ChordsStub()
        let model = ChordsModel(host: stub, key: Key(tonic: NoteName(.c)))
        model.autoKeep.delay = nil
        #expect(!model.hasUnkeptChanges, "the empty sheet's I–IV–V–I is a suggestion until something is typed")
        model.useTheseChords()
        let first = try #require(model.versions.last)
        #expect(!model.hasUnkeptChanges)
        #expect(model.lastKept?.id == first.id)

        model.text = "Dm7 G7 | Cmaj7"
        #expect(model.hasUnkeptChanges)
        model.text = ""
        #expect(!model.hasUnkeptChanges, "back to the kept bars")
        model.setKey(Key(tonic: NoteName(.d), mode: .aeolian))
        #expect(model.hasUnkeptChanges, "the key is part of the progression")

        let editor = ChordsModel(host: stub, key: Key(tonic: NoteName(.c)), progression: first)
        #expect(!editor.hasUnkeptChanges, "opened on a version: nothing to keep until it is touched")
        editor.text = "Am7 | Fmaj7"
        #expect(editor.hasUnkeptChanges)
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
        #expect(model.readingPersona == "Melodist")
        #expect(model.readings.allSatisfy { $0.rule.hasPrefix("melodist.") }, "the Melodist reads a melody, not the Bassist")
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
