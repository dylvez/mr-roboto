import AppKit
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Several notes at once on the Piano roll. A click picked out one note, and Delete removed it;
// now a box over empty space or a shift-click picks out a set, and the set moves and goes
// together, is laid again right after itself with ⌘D, and goes to the pasteboard and comes back
// from it — in the roll's own form for the roll, and as words for anyone else.

@Suite("Piano roll selection: several notes moved, removed, laid again and pasted together") @MainActor
struct PianoRollSelectionTests {

    /// A tune of four notes in bar 1 — C4 on the first beat, E4 on the second, G4 on the and of
    /// three, C5 on four for a whole beat — on a line of `bars`, nothing selected.
    private func tune(bars: Int = 2) -> PianoRollModel {
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        model.autoKeep.delay = nil
        model.startFreshTune()
        model.setLength(bars)
        model.addNote(pitch: 60, at: 0)
        model.addNote(pitch: 64, at: 1)
        model.addNote(pitch: 67, at: 2.5)
        model.addNote(pitch: 72, at: 3, duration: 1)
        model.clearSelection()
        return model
    }

    /// The writer's bass line under the kicking groove: notes behind the kick, off the grid.
    private func lagged() -> PianoRollModel {
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        model.autoKeep.delay = nil
        return model
    }

    // MARK: Picking out

    @Test("A click is one note, shift-click adds and removes, and the box takes what it covers — any part of a note, on a pitch in its rows")
    func clicksAndTheBox() {
        let model = tune()
        #expect(model.notes.map(\.pitch.midi) == [60, 64, 67, 72])
        model.select(1)
        #expect(model.selectedNotes == [1])
        #expect(model.selectedNote == 1)
        model.toggle(3)
        #expect(model.selectedNotes == [1, 3])
        #expect(model.selectedNote == nil, "several is not one")
        model.toggle(1)
        #expect(model.selectedNotes == [3])
        model.toggle(99)
        #expect(model.selectedNotes == [3], "a note the list does not have cannot join")
        model.select(0)
        #expect(model.selectedNotes == [0], "a plain click is that note alone")
        model.select(nil)
        #expect(model.selectedNotes.isEmpty)

        // Beats 0.75 to 2.75 over C4 to G4: E4 (1 to 1.5) and G4 (2.5 to 3) are in it; C4 ended at
        // 0.5, and C5 is above the rows.
        model.select(beats: 0.75...2.75, pitches: 60...67)
        #expect(model.selectedNotes == [1, 2])
        // A note that starts before the box and rings into it is covered.
        model.select(beats: 0.25...0.3, pitches: 60...60)
        #expect(model.selectedNotes == [0])
        // With shift held, the box adds to what was selected.
        model.select(beats: 2.6...3.5, pitches: 60...72, over: [0])
        #expect(model.selectedNotes == [0, 2, 3])
        // The rows hold: only G4 lies between F4 and A♯4.
        model.select(beats: 0...4, pitches: 65...70)
        #expect(model.selectedNotes == [2])
        // Over nothing, the box clears.
        model.select(beats: 1.6...2.4, pitches: 60...72)
        #expect(model.selectedNotes.isEmpty)

        model.selectAll()
        #expect(model.selectedNotes == Set(0..<4))
        #expect(model.selectionSpan == 0...4)
        #expect(model.selection.map(\.pitch.midi) == [60, 64, 67, 72], "in the order they sound")
        model.clearSelection()
        #expect(model.selectedNotes.isEmpty)
        #expect(model.selectionSpan == nil)
    }

    @Test("A new note is the selection, and the selection is dropped with the list it indexes")
    func selectionFollowsTheList() {
        let model = tune()
        model.selectAll()
        model.addNote(pitch: 62, at: 0.5)
        #expect(model.selection.map(\.pitch.midi) == [62], "the click's note alone")
        model.selectAll()
        model.deleteNote(at: 1)
        #expect(model.selectedNotes == [0, 1, 2, 3], "the rest stay selected, past the gap")
        model.undo()
        #expect(model.selectedNotes.isEmpty, "⌘Z replaces the list, and an index into it means nothing")
        model.selectAll()
        model.setLength(1)
        #expect(model.selectedNotes.isEmpty)
    }

    // MARK: Moving and removing together

    @Test("A drag on any selected note moves them all by the same snapped amount, from where the drag began, held inside the line as a group, as one step of ⌘Z")
    func groupMove() {
        let model = tune()
        model.select(beats: 0...1.5, pitches: 60...64)
        #expect(model.selectedNotes == [0, 1])
        let before = model.notes
        model.beginMove()
        model.moveSelection(by: 1.1, semitones: 1)
        #expect(model.notes[0].start == 1 && model.notes[0].pitch.midi == 61, "snapped to the sixteenth")
        #expect(model.notes[1].start == 2 && model.notes[1].pitch.midi == 65)
        // Each frame is the whole translation from where the drag began, not a step from the last.
        model.moveSelection(by: 4.4, semitones: 2)
        #expect(model.notes[0].start == 4.5 && model.notes[1].start == 5.5)
        #expect(model.notes[0].pitch.midi == 62 && model.notes[1].pitch.midi == 66)
        // Back past the start: the earliest note reaches it and the set stops there.
        model.moveSelection(by: -3, semitones: 0)
        #expect(model.notes[0].start == 0 && model.notes[1].start == 1)
        #expect(model.notes[0].pitch.midi == 60)
        // Past the end: the latest note reaches it.
        model.moveSelection(by: 100, semitones: 0)
        #expect(model.notes[1].end == 8 && model.notes[0].start == 6.5)
        // Past the keyboard: the highest note reaches its top.
        model.moveSelection(by: 0, semitones: 200)
        #expect(model.notes[1].pitch.midi == 127 && model.notes[0].pitch.midi == 123)
        model.endMove()
        #expect(model.notes[2] == before[2] && model.notes[3] == before[3], "the others stay")
        #expect(model.isHandEdited)
        model.undo()
        #expect(model.notes == before, "one step of ⌘Z takes back the whole drag")
        model.redo()
        #expect(model.notes[1].pitch.midi == 127)
    }

    @Test("A drag that moves nothing leaves nothing to undo, and a drag with nothing selected does nothing")
    func idleDrags() {
        let model = tune()
        model.select(0)
        let before = model.notes
        model.beginMove()
        model.moveSelection(by: 0.1, semitones: 0)
        model.endMove()
        #expect(model.notes == before)
        model.undo()
        #expect(model.notes.isEmpty, "the step taken back was the notes being drawn, not the drag")
        model.redo()
        #expect(model.notes == before)
        model.clearSelection()
        model.moveSelection(by: 2, semitones: 2)
        model.endMove()
        #expect(model.notes == before)
    }

    @Test("The shift is the same for every note, so a line behind the kick keeps its lag — at the start of the line too")
    func lagKeeps() {
        let model = lagged()
        let before = model.notes
        let fractions = before.map { $0.start - $0.start.rounded(.down) }
        #expect(fractions.contains { $0 > 0.01 && abs($0 - 0.5) > 0.01 }, "the writer's line sits behind the grid")
        // Bar 1's notes, with bar 2 to move into.
        model.select(beats: 0...3.99, pitches: 0...127)
        let picked = model.selectedNotes.sorted()
        #expect(picked.count >= 2 && picked.count < before.count)
        model.moveSelection(by: 1, semitones: 0)
        for index in picked {
            #expect(abs(model.notes[index].start - (before[index].start + 1)) < 1e-9)
        }
        for index in model.notes.indices where !picked.contains(index) {
            #expect(model.notes[index] == before[index], "the rest stay")
        }
        // Dragged back past the start, the set stops at the last sixteenth that keeps its first
        // note in the line, rather than snapping that note onto the grid and losing the lag.
        model.moveSelection(by: -5, semitones: 0)
        let earliest = picked.map { before[$0].start }.min() ?? 0
        #expect(earliest > 0.01 && earliest < 0.25, "the first note sits just behind the first beat")
        for index in picked {
            #expect(abs(model.notes[index].start - before[index].start) < 1e-9, "nowhere earlier on the grid keeps it in the line")
        }
        model.endMove()
    }

    @Test("Delete removes the selection as one step of ⌘Z, by its old name too")
    func groupDelete() {
        let model = tune()
        model.select(beats: 0.75...3.5, pitches: 60...72)
        #expect(model.selectedNotes == [1, 2, 3])
        let before = model.notes
        model.deleteSelection()
        #expect(model.notes.map(\.pitch.midi) == [60])
        #expect(model.selectedNotes.isEmpty)
        model.undo()
        #expect(model.notes == before)
        model.deleteSelectedNote()
        #expect(model.notes == before, "nothing selected, nothing removed")
        model.selectAll()
        model.deleteSelectedNote()
        #expect(model.notes.isEmpty)
    }

    // MARK: Laid again

    @Test("⌘D lays the selection again right after itself, on the beat; the copies are the selection, and the line grows to hold a third")
    func duplicate() {
        let model = tune()
        #expect(!model.canDuplicate, "nothing selected")
        model.selectAll()
        #expect(model.canDuplicate)
        model.duplicateSelection()
        #expect(model.notes.count == 8)
        #expect(model.lengthInBars == 2, "bar 2 held them already")
        #expect(model.selection.map(\.start) == [4, 5, 6.5, 7])
        #expect(model.selection.map(\.pitch.midi) == [60, 64, 67, 72])
        #expect(model.selection.map(\.duration) == [0.5, 0.5, 0.5, 1])
        model.duplicateSelection()
        #expect(model.lengthInBars == 3, "grown by a bar to hold the third")
        #expect(model.selection.map(\.start) == [8, 9, 10.5, 11])
        #expect(model.notes.count == 12)
        model.undo()
        #expect(model.notes.count == 8 && model.lengthInBars == 2, "one step of ⌘Z")
        model.undo()
        #expect(model.notes.count == 4)
    }

    @Test("The copies go on by whole beats — the fewest that put them after the last note's end — and a note ringing a hair over the beat counts as ending on it")
    func duplicateOffsets() {
        let model = tune()
        model.select(2)
        model.duplicateSelection()
        #expect(model.selection.map(\.start) == [3.5], "half a beat long: laid a beat on")
        let short = tune()
        short.select(beats: 0.75...3, pitches: 60...67)
        #expect(short.selectedNotes == [1, 2], "E4 at 1, G4 to 3")
        short.duplicateSelection()
        #expect(short.selection.map(\.start) == [3, 4.5], "two beats long: laid two beats on, each note in its place in the beat")

        let ringing = tune()
        ringing.addNote(pitch: 62, at: 4, duration: 1.1)
        ringing.duplicateSelection()
        #expect(ringing.selection.map(\.start) == [5], "a tenth of a beat over the beat is on it")
        ringing.addNote(pitch: 62, at: 6, duration: 1.2)
        ringing.duplicateSelection()
        #expect(ringing.selection.map(\.start) == [8], "a fifth is not")

        // The writer's lagged bar lands a bar on, lag and all.
        let line = lagged()
        line.select(beats: 0...4, pitches: 0...127)
        let picked = line.selection
        line.duplicateSelection()
        #expect(line.selection.count == picked.count)
        for (copy, original) in zip(line.selection, picked) {
            #expect(abs(copy.start - (original.start + 4)) < 1e-9)
            #expect(copy.pitch == original.pitch && copy.velocity == original.velocity)
        }
    }

    @Test("Copies past the longest line are not made, one ringing over it is cut there, and ⌘D is greyed with nowhere to go")
    func duplicateClipped() {
        let model = tune(bars: 16)
        model.addNote(pitch: 60, at: 60, duration: 2)
        model.duplicateSelection()
        #expect(model.selection.map(\.start) == [62])
        #expect(!model.canDuplicate, "the next copy would start at the end")
        model.duplicateSelection()
        #expect(model.notes.filter { $0.start >= 62 }.count == 1)
        #expect(model.lengthInBars == 16)

        model.addNote(pitch: 62, at: 61, duration: 2)
        model.duplicateSelection()
        #expect(model.selection.map(\.start) == [63])
        #expect(model.selection.map(\.duration) == [1], "cut at the end of the longest line")

        let grows = tune(bars: 15)
        grows.addNote(pitch: 60, at: 59, duration: 1)
        grows.duplicateSelection()
        #expect(grows.lengthInBars == 16 && grows.selection.map(\.start) == [60])
    }

    // MARK: The pasteboard

    @Test("The clip comes back as it went: through its own type, and through the words when they are all there is")
    func clipRoundTrip() throws {
        let model = tune()
        model.select(beats: 0.75...3.5, pitches: 60...72)
        let clip = try #require(model.clipOfSelection)
        #expect(clip.notes.map(\.start) == [0, 1.5, 2], "from the beat the first note sits in")
        #expect(clip.notes.map(\.pitch.midi) == [64, 67, 72])
        #expect(clip.beatsPerBar == 4)
        #expect(clip.lengthInBeats == 3)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        clip.write(to: pasteboard)
        #expect(pasteboard.types?.contains(NoteClip.pasteboardType) == true)
        #expect(pasteboard.types?.contains(.string) == true)
        #expect(NoteClip(reading: pasteboard) == clip)
        #expect(NoteClip.isOn(pasteboard))

        let words = try #require(pasteboard.string(forType: .string))
        #expect(words.hasPrefix("Notes from the Piano roll, 4 beats a bar\n"))
        #expect(words.contains("E4\tbar 1, beat 1\t0.5 beats\tvelocity 100"))
        #expect(words.contains("G4\tbar 1, beat 2.5\t0.5 beats\tvelocity 100"))
        #expect(words.contains("C5\tbar 1, beat 3\t1 beat\tvelocity 100"))
        #expect(NoteClip(text: words) == clip)
        pasteboard.clearContents()
        pasteboard.setString(words, forType: .string)
        #expect(NoteClip(reading: pasteboard) == clip, "the words alone paste")

        // Words a person wrote: spaces for tabs, a flat, no velocity, a remark among them.
        let typed = """
            3 beats a bar
            Db3  bar 2, beat 1   0.75 beats
            -- the answer --
            F3 bar 2, beat 2.5 1 beat velocity 48
            """
        let read = try #require(NoteClip(text: typed))
        #expect(read.beatsPerBar == 3)
        #expect(read.notes.map(\.start) == [3, 4.5])
        #expect(read.notes.map(\.pitch.midi) == [49, 53])
        #expect(read.notes.map(\.duration) == [0.75, 1])
        #expect(read.notes.map(\.velocity) == [100, 48])
        #expect(NoteClip(text: "nothing to play here") == nil)
        pasteboard.clearContents()
        pasteboard.setString("nothing to play here", forType: .string)
        #expect(!NoteClip.isOn(pasteboard))
    }

    @Test("A lagged line's clip keeps the lag to four decimals in words and exactly in its own type")
    func laggedClip() throws {
        let model = lagged()
        model.select(beats: 4...8, pitches: 0...127)
        let clip = try #require(model.clipOfSelection)
        let picked = model.selection
        #expect(abs(clip.notes[0].start - (picked[0].start - 4)) < 1e-9, "from beat 5, the beat the first sits in")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        clip.write(to: pasteboard)
        #expect(NoteClip(reading: pasteboard) == clip)
        let words = try #require(NoteClip(text: clip.text))
        for (word, note) in zip(words.notes, clip.notes) {
            #expect(abs(word.start - note.start) < 0.0001 && abs(word.duration - note.duration) < 0.0001)
            #expect(word.pitch == note.pitch && word.velocity == note.velocity)
        }
    }

    @Test("⌘V lands on the beat the lane was last clicked, the pasted notes are the selection, and the next paste lands after them")
    func pasteLanding() {
        let model = tune()
        let clip = NoteClip(notes: [NoteEvent(pitch: Pitch(midi: 62), start: 0, duration: 0.5),
                                    NoteEvent(pitch: Pitch(midi: 65), start: 1.5, duration: 0.5, velocity: 40)], beatsPerBar: 4)
        model.placeCaret(at: 4.6)
        #expect(model.pasteLanding == 5, "snapped to the beat")
        #expect(model.canPaste)
        model.paste(clip)
        #expect(model.selection.map(\.start) == [5, 6.5])
        #expect(model.selection.map(\.velocity) == [100, 40])
        #expect(model.notes.count == 6 && model.lengthInBars == 2)
        #expect(model.caret == 7, "past what was pasted")
        model.paste(clip)
        #expect(model.selection.map(\.start) == [7, 8.5])
        #expect(model.lengthInBars == 3, "grown to hold it")
        model.undo()
        #expect(model.notes.count == 6 && model.lengthInBars == 2, "one step of ⌘Z")
        #expect(model.isHandEdited)
    }

    @Test("Never clicked, a paste lands right after the line's last note, on the beat; on an empty line, on its first beat")
    func pasteAfterTheLine() {
        let written = lagged()
        #expect(written.caret == nil)
        let last = written.notes.map(\.end).max() ?? 0
        let landing = written.pasteLanding
        #expect(landing == landing.rounded() && landing >= last - 0.125 && landing <= last.rounded(.up))

        let empty = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        empty.autoKeep.delay = nil
        empty.startFreshTune()
        #expect(empty.notes.isEmpty && empty.pasteLanding == 0)
        empty.paste(NoteClip(notes: [NoteEvent(pitch: Pitch(midi: 60), start: 0.5, duration: 0.5)], beatsPerBar: 4))
        #expect(empty.notes.map(\.start) == [0.5])
        #expect(empty.selectedNotes == [0])
    }

    @Test("A paste is cut to the longest line, and there is no pasting past it")
    func pasteClipped() {
        let model = tune(bars: 16)
        let clip = NoteClip(notes: [NoteEvent(pitch: Pitch(midi: 62), start: 0, duration: 2),
                                    NoteEvent(pitch: Pitch(midi: 65), start: 1.5, duration: 0.5)], beatsPerBar: 4)
        model.placeCaret(at: 63)
        model.paste(clip)
        #expect(model.selection.map(\.start) == [63], "the second would start at the end")
        #expect(model.selection.map(\.duration) == [1], "cut there")
        #expect(model.lengthInBars == 16)
        model.placeCaret(at: 64)
        #expect(!model.canPaste)
        let count = model.notes.count
        model.paste(clip)
        #expect(model.notes.count == count)
    }
}
