import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The voicing dial on the Chords sheet: a chord chosen and turned an inversion at a time, the note
// under it chosen, and the dial on the chord keys turning every chord struck.

private struct NoDevice: Error {}

@Suite("Chord turns: the dial on the sheet and on the chord keys", .serialized) @MainActor
struct ChordTurnTests {

    private func sheet(_ line: String = "Dm7 | G7 | Cmaj7 | Am7", key: Key = Key(tonic: NoteName(.c))) -> (ChordsModel, ChordsStub) {
        let stub = ChordsStub()
        let model = ChordsModel(host: stub, key: key)
        model.autoKeep.delay = nil
        model.text = line
        return (model, stub)
    }

    @Test("a chord chosen and turned up is heard turned, kept with its turn, and ⌘Z puts it back")
    func turnAChord() throws {
        let (model, stub) = sheet()
        model.setVoicing(.led)
        let before = model.voiced(chordAt: 1)
        model.select(chordAt: 1)
        #expect(model.selected?.index == 1 && model.selected?.span.chord == Chord(.g, .dominantSeventh))
        model.turn(chordAt: 1, by: 1)
        #expect(model.lift(ofChordAt: 1) == 1)
        #expect(model.progression?.spans.map(\.lift) == [nil, 1, nil, nil])
        #expect(model.voiced(chordAt: 1) == Voicing.lifted(before, by: 1))
        #expect(model.text == "Dm7 | G7 | Cmaj7 | Am7", "the line is the chords; the turn is beside it")
        #expect(model.keepNow())
        guard case .progression(let kept) = try #require(stub.committed.last).kind else { Issue.record("not a progression"); return }
        #expect(kept.spans[1].lift == 1)

        // A sheet opened on what was kept turns it the same way.
        let reopened = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)),
                                   progression: try #require(stub.committed.last))
        #expect(reopened.lift(ofChordAt: 1) == 1 && reopened.progression?.spans[1].lift == 1)

        model.undo()
        #expect(model.lift(ofChordAt: 1) == 0 && model.progression?.spans.allSatisfy { $0.lift == nil } == true)
        model.redo()
        #expect(model.lift(ofChordAt: 1) == 1)
        // Turned back to nothing is no turn at all.
        model.turn(chordAt: 1, by: -1)
        #expect(model.lifts.isEmpty && model.progression?.spans[1].lift == nil)
        // The dial stops where a turn stops meaning anything.
        for _ in 0..<20 { model.turn(chordAt: 0, by: -1) }
        #expect(model.lift(ofChordAt: 0) == ChordKeyboard.lifts.lowerBound)
    }

    @Test("the bass under a chord is one of its own notes, written as the chord over it; the turns stay where they were")
    func bassUnder() throws {
        let (model, _) = sheet("C F | G | C")
        model.turn(chordAt: 2, by: 1)
        model.setBass(.a, forChordAt: 1)
        #expect(model.text == "C F/A | G | C")
        #expect(model.progression?.chords[1] == Chord(.f, .major).inverted(1))
        #expect(model.progression?.chords[1].bass == .a, "what the bass player reads")
        #expect(model.lift(ofChordAt: 2) == 1)
        model.setBass(.d, forChordAt: 2)
        #expect(model.text == "C F/A | G/D | C")
        model.setBass(.c, forChordAt: 0)
        #expect(model.text == "C F/A | G/D | C", "the root under a chord already on its root changes nothing")
        model.setBass(.e, forChordAt: 9)
        #expect(model.text == "C F/A | G/D | C", "no chord there")
        model.undo()
        #expect(model.text == "C F/A | G | C")
        // On the suggestion, the bass is written into a line of its own chords.
        let (blank, _) = sheet("")
        #expect(blank.isDefault)
        blank.setBass(.e, forChordAt: 0)
        #expect(blank.text.hasPrefix("Cmaj7/E | "), "\(blank.text)")
    }

    @Test("the dial on the chord keys turns every chord struck, and Record writes each with its turn; C and C♯ below middle C turn it")
    func dialOnTheKeys() throws {
        let directory = WiringFixture.temporaryDirectory("chord-turn")
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let suite = "chord-turn-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: directory)
        let control = MIDIControl(app: app, service: service, defaults: defaults)
        let (model, _) = sheet("")
        control.mode = .chords
        control.beginTake(into: model, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
        func play(_ note: Int) {
            control.handle(MIDIEvent(kind: .noteOn(note: note, velocity: 90), channel: 0, hostTime: 0, source: "Launchkey"))
            control.handle(MIDIEvent(kind: .noteOff(note: note), channel: 0, hostTime: 0, source: "Launchkey"))
        }
        play(60)
        let plain = try #require(control.chordKeys.last?.voiced)
        play(49)                      // C♯ below the split: up a step
        #expect(control.chordKeys.lift == 1)
        play(60)
        #expect(control.chordKeys.last?.voiced == Voicing.lifted(plain, by: 1) && control.chordKeys.last?.lift == 1)
        play(48); play(48)            // C below the split: down two
        #expect(control.chordKeys.lift == -1)
        play(65)
        #expect(model.text == "C | C | F")
        #expect(model.progression?.spans.map(\.lift) == [nil, 1, -1])
        #expect(model.takeLine == "F, turned down 1", "\(model.takeLine ?? "")")
        model.undo()
        #expect(model.text == "C | C" && model.progression?.spans.map(\.lift) == [nil, 1], "⌘Z takes the chord and its turn")
        control.finishTake(at: nil)
    }
}
