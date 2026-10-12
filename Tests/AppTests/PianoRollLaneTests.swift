import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MrRobotoApp

// The lane drawn, not its arithmetic (that is `FillNoteLaneTests`). On a short bench the lane used
// to take whatever height it was handed, and a tune's lowest rows went under the kick lane: C4's
// name was set below "kick". The lane now keeps the register's floor, and the surface scrolls its
// work rather than grow past the bench.

@Suite("Piano roll lane: a short bench scrolls the work rather than put the register under the kicks") @MainActor
struct PianoRollLaneTests {

    /// How tall a view draws when offered `height`, measured as `LayoutColumnFitTests` measures a column.
    private func drawn<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        return try #require(renderer.nsImage).size.height
    }

    /// A tune from C4 to C6 over a kick, the register the roll draws a melody in.
    private func tune() -> PianoRollModel {
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        model.setMode(.melody)
        while !model.notes.isEmpty { model.deleteNote(at: 0) }
        model.addNote(pitch: 60, at: 0)
        model.addNote(pitch: 84, at: 1)
        return model
    }

    @Test("Offered less than its register needs, the lane keeps its floor, so C4 is drawn above the kicks")
    func laneKeepsItsFloor() throws {
        FontRegistration.registerBundledFonts()
        let model = tune()
        #expect(model.register == 60...84)
        let floor = NoteLaneLayout.minimumHeight(rows: model.register.count)
        // 196 is about what the old 220-point floor left the lane once its caption had a line.
        for height in [120, 196, 240] as [CGFloat] {
            #expect(try drawn(NoteLane(model: model), width: 640, height: height) >= floor)
            #expect(try drawn(NoteLane(model: model, fills: false), width: 640, height: height) >= floor)
        }
        // With room it takes the room.
        #expect(try drawn(NoteLane(model: model), width: 640, height: 600) == 600)
    }

    @Test("On a short bench the surface takes the height it is given and no more: its work scrolls inside it")
    func surfaceFitsTheBench() throws {
        FontRegistration.registerBundledFonts()
        let model = tune()
        for height in [300, 395, 460, 560] as [CGFloat] {
            #expect(try drawn(PianoRollSurfaceView(model: model), width: 640, height: height) == height)
        }
    }
}
