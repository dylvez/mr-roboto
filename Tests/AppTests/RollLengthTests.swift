import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The ceiling lifted: a line in the Piano roll has a length of its own, not the groove's. A
// four-bar tune over a one-bar groove, its last bar a breath, is kept with the breath; the writer
// writes eight bars over one when asked; the kick is drawn — and read — under every bar.

@Suite("Piano roll: a line's own length") @MainActor
struct PianoRollLengthTests {

    static let key = Key(tonic: NoteName(.d), mode: .aeolian)

    /// One bar: kick on 1 and the and of 2.
    static func oneBar() -> Groove {
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : .rest })
        }
        return Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            line(.kick, "x-----x---------"),
            line(.closedHat, "x-x-x-x-x-x-x-x-"),
        ])
    }

    /// One bar's kick, read across four.
    static let fourBarsOfKick: [Double] = [0, 1.5, 4, 5.5, 8, 9.5, 12, 13.5]

    @AudioActor
    static func loopBars(_ melody: Melody, tempo: Double) -> Int {
        KeysPlayer(sampler: VoiceSampler(cache: SampleCache()), melody: melody, timeline: .tempo(tempo)).barsPerLoop
    }

    @AudioActor
    static func loopBars(_ line: Bassline, tempo: Double) -> Int {
        BasslinePlayer(sampler: VoiceSampler(cache: SampleCache()), bassline: line, timeline: .tempo(tempo)).barsPerLoop
    }

    @Test("a four-bar tune over a one-bar groove keeps its trailing rest bar: kept, played and exported")
    func aTuneKeepsItsRest() async throws {
        let stub = RollStub()
        var song = Song(title: "Arrival", tempo: 92)
        let grooveVersion = PartVersion(partID: PartID(), kind: .groove(Self.oneBar()), author: .user,
                                        operation: Operation.written, note: "Kick")
        let opened = PartVersion(partID: PartID(),
                                 kind: .melody(Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1)])),
                                 author: .user, operation: Operation.written, note: "Tune")
        try song.append(grooveVersion)
        try song.append(opened)

        let model = PianoRollModel(host: stub, groove: Self.oneBar(), grooveVersion: grooveVersion.id, key: Self.key,
                                   tempo: 92, melody: opened)
        model.autoKeep.delay = nil
        #expect(model.mode == .melody)
        #expect(model.lengthInBars == 1, "a tune with no stated length opens as long as the groove and its notes")
        #expect(!model.hasUnkeptChanges, "opening is not an edit")

        model.setLength(4)
        #expect(model.lengthInBars == 4 && model.totalBeats == 16)
        #expect(model.kickBeats == Self.fourBarsOfKick, "the one-bar kick under all four bars")
        model.addNote(pitch: 74, at: 4)
        model.addNote(pitch: 76, at: 8)
        #expect(model.notes.map(\.start) == [0, 4, 8], "notes in bars one to three, bar four a rest")
        #expect(model.hasUnkeptChanges)

        // Kept: the length is on the part.
        #expect(model.keepNow())
        let kept = try #require(stub.committed.last)
        guard case .melody(let tune) = kept.kind else { Issue.record("kept \(kept.type)"); return }
        #expect(tune.lengthInBars == 4)
        #expect(tune.lengthInBeats == 8.5, "the notes stop in bar three…")
        #expect(kept.parents == [opened.id])
        #expect(!model.hasUnkeptChanges)

        // Played: …and the loop is four bars, not three.
        #expect(await Self.loopBars(tune, tempo: 92) == 4)
        #expect(await Self.loopBars(Melody(notes: tune.notes), tempo: 92) == 3, "without the length it would lose the rest")

        // Exported: over an eight-bar section the second pass starts at bar five.
        try song.append(kept)
        song.sections = [Section(name: "Verse", stitch: [Lane(part: grooveVersion.partID), Lane(part: kept.partID)],
                                 lengthInBars: 8)]
        let file = MIDIExport.file(for: song)
        let melodyTrack = try #require(file.tracks.first { $0.notes.first?.channel == 1 })
        #expect(melodyTrack.notes.map(\.start) == [0, 4, 8, 16, 20, 24].map { $0 * 480 },
                "\(melodyTrack.notes.map(\.start))")
    }

    @Test("Double copies the line into the bars after it; shortening drops what is past the end; both undo")
    func doubleAndShorten() {
        let model = PianoRollModel(host: RollStub(), groove: nil, key: Self.key, tempo: 92)
        model.autoKeep.delay = nil
        model.addNote(pitch: 40, at: 0)
        model.addNote(pitch: 43, at: 2, duration: 1)
        #expect(model.lengthInBars == 1)
        #expect(model.canDouble)

        model.double()
        #expect(model.lengthInBars == 2)
        #expect(model.notes.map(\.start) == [0, 2, 4, 6])
        #expect(model.notes.map(\.pitch.midi) == [40, 43, 40, 43])
        #expect(model.isHandEdited)
        #expect(model.hasUnkeptChanges)

        model.undo()
        #expect(model.lengthInBars == 1, "the length is part of what ⌘Z steps back through")
        #expect(model.notes.map(\.start) == [0, 2])
        model.redo()
        #expect(model.lengthInBars == 2 && model.notes.count == 4)

        // A note ringing over the bar line, then back to one bar.
        model.addNote(pitch: 45, at: 3.5, duration: 1)
        model.setLength(1)
        #expect(model.lengthInBars == 1)
        #expect(model.notes.map(\.start) == [0, 2, 3.5], "the second bar's notes are gone")
        #expect(model.notes.last?.duration == 0.5, "and the one ringing over the end is cut at it")
        model.undo()
        #expect(model.lengthInBars == 2 && model.notes.count == 5, "shortening is undone, notes and all")
        #expect(model.notes.first { $0.start == 3.5 }?.duration == 1)

        // Double stops at the longest line the roll makes.
        model.setLength(16)
        #expect(!model.canDouble)
        model.double()
        #expect(model.lengthInBars == 16)
        model.setLength(40)
        #expect(model.lengthInBars == PianoRollModel.longestLine)
    }

    @Test("Tighten puts a played line on the sixteenths, folds notes that land together, and undoes")
    func tightenAPlayedLine() {
        // As a controller leaves it: 20 ms late at 92, held a little short, and one note played twice.
        let played = Melody(notes: [
            NoteEvent(pitch: Pitch(midi: 67), start: 0.03, duration: 0.93, velocity: 90),
            NoteEvent(pitch: Pitch(midi: 70), start: 1.97, duration: 0.4, velocity: 70),
            NoteEvent(pitch: Pitch(midi: 70), start: 2.04, duration: 0.3, velocity: 100),
            NoteEvent(pitch: Pitch(midi: 72), start: 3.9, duration: 0.02, velocity: 80),
        ], lengthInBars: 1)
        let opened = PartVersion(partID: PartID(), kind: .melody(played), author: .user, operation: Operation.played, note: "Played")
        let model = PianoRollModel(host: RollStub(), groove: nil, key: Self.key, tempo: 92, melody: opened)
        model.autoKeep.delay = nil
        #expect(model.canTighten)

        model.tighten()
        #expect(model.notes.map(\.start) == [0, 2, 3.75])
        #expect(model.notes.map(\.pitch.midi) == [67, 70, 72])
        #expect(model.notes.map(\.duration) == [1, 0.25, 0.25], "ends on the grid too, and never shorter than a sixteenth")
        #expect(model.notes[1].velocity == 100, "the two that landed together are the louder one")
        #expect(!model.canTighten)
        #expect(model.hasUnkeptChanges)

        model.undo()
        #expect(model.notes.count == 4 && model.notes[0].start == 0.03, "⌘Z puts the feel back")
    }

    @Test("Tighten leaves a played bass line the lever's lag behind the grid, and never touches the writer's line")
    func tightenABassLine() throws {
        let played = Bassline(notes: [
            NoteEvent(pitch: Pitch(midi: 38), start: 0.02, duration: 0.9, velocity: 96),
            NoteEvent(pitch: Pitch(midi: 41), start: 1.1, duration: 0.3, velocity: 90),
        ], sound: "finger", key: Self.key, lengthInBars: 1)
        let opened = PartVersion(partID: PartID(), kind: .bassline(played), author: .user, operation: Operation.played, note: "Played")
        let model = PianoRollModel(host: RollStub(), groove: Self.oneBar(), key: Self.key, tempo: 92, bassline: opened)
        model.autoKeep.delay = nil
        let lag = model.lagMS / 1000 * 92 / 60
        #expect(lag > 0)
        #expect(model.canTighten)
        model.tighten()
        #expect(model.notes.count == 2)
        #expect(abs(model.notes[0].start - lag) < 1e-9 && abs(model.notes[1].start - (1 + lag)) < 1e-9, "behind the sixteenth by the lever")
        #expect(abs(model.notes[0].end - 1) < 1e-9 && abs(model.notes[1].end - 1.5) < 1e-9, "the ends on the grid")
        #expect(!model.canTighten, "tight is tight: a second press would move nothing")

        let written = PianoRollModel(host: RollStub(), groove: Self.oneBar(), key: Self.key, tempo: 92)
        #expect(!written.notes.isEmpty && !written.isHandEdited)
        #expect(!written.canTighten, "the writer's line sits where the levers put it")
    }

    @Test("notes can be placed, moved and resized anywhere in the length, and no further")
    func editingAcrossTheLength() {
        let model = PianoRollModel(host: RollStub(), groove: Self.oneBar(), key: Self.key, tempo: 92)
        model.autoKeep.delay = nil
        model.setLength(8)
        model.addNote(pitch: 40, at: 30)
        guard let index = model.selectedNote else { Issue.record("the new note is the selection"); return }
        #expect(model.notes[index].start == 30, "bar eight of a line over a one-bar groove")
        model.moveNote(at: index, toStart: 21, pitch: 41)
        #expect(model.notes[index].start == 21 && model.notes[index].pitch.midi == 41, "bar six is reachable")
        model.moveNote(at: index, toStart: 40, pitch: 41)
        #expect(model.notes[index].start == 31.5, "clamped to the line's end, not the groove's")
        model.resizeNote(at: index, toDuration: 4)
        #expect(model.notes[index].duration == 0.5)
        model.addNote(pitch: 40, at: 99)
        #expect(model.notes.allSatisfy { $0.start < 32 })
    }

    @Test("lengthened, the writer's line is written over the whole length against the kick repeated")
    func theWriterWritesTheLength() throws {
        let stub = RollStub()
        let model = PianoRollModel(host: stub, groove: Self.oneBar(), grooveVersion: VersionID(), key: Self.key, tempo: 92)
        model.autoKeep.delay = nil
        #expect(model.lengthInBars == 1)
        #expect(model.notes.allSatisfy { $0.start < 4 })

        model.setLength(4)
        #expect(!model.isHandEdited, "still the writer's line")
        #expect(model.notes.contains { $0.start >= 12 }, "the writer wrote bar four")
        #expect(model.kickBeats == Self.fourBarsOfKick)
        let observation = try #require(model.observation)
        #expect(observation.bars == 4, "the Bassist reads the groove repeated to the line, not one bar of it")
        #expect(observation.downbeatCoverage == 1, "every bar's downbeat is there")

        let version = model.commit()
        guard case .bassline(let line) = version.kind else { Issue.record("kept \(version.type)"); return }
        #expect(line.lengthInBars == 4)
        #expect(version.note?.contains("4 bars") == true, "\(version.note ?? "")")

        // Programmed over eight: the line is the kick, in every bar.
        model.setLineage(.programmed)
        model.setLength(8)
        #expect(model.notes.count == 16, "two kicks a bar for eight bars")

        // A hand-edited line is the person's: lengthening leaves the new bars empty.
        model.addNote(pitch: 30, at: 1)
        let edited = model.notes
        model.setLength(16)
        #expect(model.notes == edited)
        #expect(model.lengthInBars == 16)
    }

    @Test("a bound line opens at the length it states, else its notes' — the length the song loops it at — and is not an edit")
    func openingLengths() throws {
        let stub = RollStub()
        let stated = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1)],
                                                                            sound: "finger", lengthInBars: 8)),
                                 author: .user, operation: Operation.written)
        let model = PianoRollModel(host: stub, groove: Self.oneBar(), key: Self.key, tempo: 92, bassline: stated)
        model.autoKeep.delay = nil
        #expect(model.lengthInBars == 8)
        #expect(model.kickBeats.count == 16)
        #expect(!model.hasUnkeptChanges)

        let reaching = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 5, duration: 1)], sound: "finger")
        let untold = PartVersion(partID: PartID(), kind: .bassline(reaching), author: .user, operation: Operation.written)
        let underOne = PianoRollModel(host: stub, groove: Self.oneBar(), key: Self.key, tempo: 92, bassline: untold)
        underOne.autoKeep.delay = nil
        #expect(underOne.lengthInBars == 2, "the notes reach bar two")
        #expect(!underOne.hasUnkeptChanges, "a line with no stated length is not changed by being opened")
        let fourBarGroove = Self.oneBar().tiled(toBars: 4)
        let underFour = PianoRollModel(host: stub, groove: fourBarGroove, key: Self.key, tempo: 92, bassline: untold)
        #expect(underFour.lengthInBars == reaching.loopBars(beatsPerBar: 4) && underFour.lengthInBars == 2,
                "what the song loops it at, not the groove's four: a nudge must not keep two silent bars")

        // Setting it is an edit, and what is kept states it.
        underOne.setLength(4)
        #expect(underOne.hasUnkeptChanges)
        let kept = underOne.commit()
        guard case .bassline(let line) = kept.kind else { Issue.record("kept \(kept.type)"); return }
        #expect(line.lengthInBars == 4)
    }

    @Test("a kept bass line with its length loops at it, trailing rest and all")
    func aBassLineLoopsAtItsLength() async throws {
        let model = PianoRollModel(host: RollStub(), groove: nil, key: Self.key, tempo: 92)
        model.autoKeep.delay = nil
        model.addNote(pitch: 38, at: 0)
        model.setLength(2)
        let version = model.commit()
        guard case .bassline(let line) = version.kind else { Issue.record("kept \(version.type)"); return }
        #expect(line.lengthInBars == 2)
        #expect(await Self.loopBars(line, tempo: 92) == 2, "bar two is a rest and still a bar")
    }
}

// The Harmonist on the Chords surface: its reading of the bars, under them, refreshed as you type.

@MainActor
final class BassedChordsStub: ChordsHosting {
    var instrument = InstrumentVoiceSpec.rhodes.id
    var bassline: Bassline?
    func audition(pitches: [Int], duration: Double) async {}
    func setInstrument(_ id: String, for part: PartID?) {}
    func commit(_ version: PartVersion) -> Bool { true }
}

@Suite("Chords: the Harmonist reads the bars") @MainActor
struct ChordsHarmonistTests {

    @Test("the bars are read as they parse; a typo keeps the last reading; one chord is flagged first")
    func readsAsItParses() {
        let model = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)))
        #expect(!model.readings.isEmpty, "the suggested I–IV–V–I is read too")

        model.text = "Dm7 G7 | Cmaj7 | Am7"
        #expect(model.readings.contains { $0.rule == "harmonist.enough-chords" && $0.holds })
        #expect(model.readings.contains { $0.rule == "harmonist.voice-leading" })
        let read = model.readings

        model.text = "Dm7 G7 | Xz"
        #expect(model.barsAreStale)
        #expect(model.readings == read, "the reading is of the bars on screen, the last that read")

        model.text = "C"
        #expect(model.flags.contains { $0.rule == "harmonist.enough-chords" })
        #expect(model.orderedReadings.first?.holds == false, "a flag is said first")
    }

    @Test("a bass line that disagrees with the chords is named on the surface, first")
    func theBassDisagrees() throws {
        let stub = BassedChordsStub()
        // E under Dm7 and under G7: a note of neither.
        stub.bassline = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 2),
                                         NoteEvent(pitch: Pitch(midi: 40), start: 4, duration: 2)], sound: "finger")
        let model = ChordsModel(host: stub, key: Key(tonic: NoteName(.c)))
        model.text = "Dm7 | G7"
        let clash = try #require(model.readings.first { $0.rule == "harmonist.bass-agrees" })
        #expect(!clash.holds)
        #expect(model.orderedReadings.first.map { !$0.holds } == true)
        #expect(model.orderedReadings.count == model.readings.count)

        // A bass on the roots agrees.
        stub.bassline = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 2),
                                         NoteEvent(pitch: Pitch(midi: 43), start: 4, duration: 2)], sound: "finger")
        model.text = "Dm7 | G7 "
        #expect(model.readings.first { $0.rule == "harmonist.bass-agrees" }?.holds == true)
    }
}
