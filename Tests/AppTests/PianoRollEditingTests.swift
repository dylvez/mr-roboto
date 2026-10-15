import Foundation
import Testing

@testable import MrRobotoApp

// Editing a note by hand: where a drag lengthens it rather than moving it, and what Delete has to
// remove. The right edge used to be the last eight points of every note, which on a long line at
// the floor was most of an eighth, so most drags lengthened it and a drag up or down did nothing.

@Suite("Piano roll editing: the right edge and the Delete key") @MainActor
struct PianoRollEditingTests {

    @Test("A note under twenty points wide has no edge to catch; wider, the edge is its trailing third, at most eight points")
    func resizeHandle() {
        for width in [6, 7, 14, 19.9] as [CGFloat] {
            #expect(NoteLaneLayout.resizeHandle(forNoteWidth: width) == 0, "\(width) points moves from anywhere")
        }
        #expect(abs(NoteLaneLayout.resizeHandle(forNoteWidth: 20) - 20 / 3) < 0.001)
        #expect(NoteLaneLayout.resizeHandle(forNoteWidth: 24) == 8)
        #expect(NoteLaneLayout.resizeHandle(forNoteWidth: 100) == 8)
        // At the floor an eighth is fourteen points: no edge. Four bars across a 1440 window makes
        // it 40: an edge of eight.
        let floor = NoteLaneLayout.minimumBeatWidth / 2 - 1
        #expect(NoteLaneLayout.resizeHandle(forNoteWidth: floor) == 0)
        #expect(NoteLaneLayout.resizeHandle(forNoteWidth: 40) == 8)
    }

    @Test("Delete has something to remove only while a note is selected, and the menu's route removes it")
    func canDelete() {
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        #expect(!model.notes.isEmpty)
        #expect(!model.canDelete)
        model.select(0)
        #expect(model.canDelete)
        let count = model.notes.count
        let deleter: any DeletesItsSelection = model
        deleter.deleteSelection()
        #expect(model.notes.count == count - 1)
        #expect(!model.canDelete)
        model.undo()
        #expect(model.notes.count == count)
    }
}
