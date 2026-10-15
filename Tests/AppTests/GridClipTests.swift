import AppKit
import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// A bar or a row lifted off the grid and put down again. The grid has no selection; its units
// are the bar and the row, lifted from a bar number or a voice's name, through the pasteboard so
// they cross grids and songs, and as text so they read anywhere else.

@MainActor
@Suite("Grid clip: a bar or a row lifted off the grid and put down again")
struct GridClipTests {

    private func grid(bars: Int = 4, stepsPerBar: Int = 16) -> GridModel {
        GridModel(host: StubGridHost(), groove: GridModel.emptyGroove(stepsPerBar: stepsPerBar, bars: bars))
    }

    /// `X---x---o---x---`, spaces ignored, as tiers.
    private func pattern(_ text: String) -> [VelocityTier] {
        text.compactMap { $0 == " " ? nil : GridClip.tier(for: $0) }
    }

    private func hits(_ model: GridModel, _ voice: DrumVoice) -> [Int] {
        (0..<model.stepCount).filter { model.tier(voice, step: $0) != .rest }
    }

    @Test("The readable form says every tier of every bar, and comes back as the clip it was")
    func textRoundTrip() {
        let clip = GridClip(stepsPerBar: 16, bars: 2, rows: [
            GroovePattern(voice: .kick, steps: pattern("X---x---o---x--- X-------x---x-o-")),
            GroovePattern(voice: .closedHat, steps: pattern("x-x-x-x-x-x-x-x- x-x-x-x-x-x-x-x-")),
            GroovePattern(voice: .guiroLong, steps: pattern("x--------------- x---------------")),
        ])
        let text = clip.text
        #expect(text.contains("kick: X---x---o---x--- | X-------x---x-o-"))
        #expect(text.contains("closed hat: x-x-x-x-x-x-x-x- | x-x-x-x-x-x-x-x-"))
        #expect(text.contains("güiro, long: x--------------- | x---------------"))
        #expect(GridClip(text: text) == clip)

        // Typed by hand: dots for rests, a voice spelled as the graph spells it, a short row.
        let typed = GridClip(text: "closedHat: x.x.x.x.x.x.x.x.\nkick: X.......X\n")
        #expect(typed?.stepsPerBar == 16)
        #expect(typed?.bars == 1)
        #expect(typed?.rows.map(\.voice) == [.closedHat, .kick])
        #expect(typed?.rows.last?.steps == pattern("X-------X-------"))
        #expect(GridClip(text: "nothing here") == nil)
        #expect(GridClip(text: "nobody: x---") == nil)
    }

    @Test("A bar lifted off every row goes down in another bar, as one step of ⌘Z; the same bar again is no edit")
    func barToBar() throws {
        let model = grid(bars: 4)
        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .kick, step: 8)
        model.set(.ghost, voice: .snare, step: 4)
        let clip = try #require(model.clip(bar: 0))
        #expect(clip.bars == 1)
        #expect(clip.stepsPerBar == 16)
        #expect(clip.rows.map(\.voice) == model.voices)
        #expect(clip.rows[0].steps == pattern("X-------x-------"))
        #expect(model.clip(bar: 4) == nil)

        model.paste(clip, intoBar: 2)
        #expect(model.tier(.kick, step: 32) == .accent)
        #expect(model.tier(.kick, step: 40) == .normal)
        #expect(model.tier(.snare, step: 36) == .ghost)
        #expect(hits(model, .kick) == [0, 8, 32, 40], "bars 2 and 4 untouched")
        model.undo()
        #expect(hits(model, .kick) == [0, 8])
        #expect(model.canRedo)
        // Putting down what is already there changes nothing, and leaves the redo where it was.
        model.paste(clip, intoBar: 0)
        #expect(model.canRedo)
    }

    @Test("A two-bar clip put down in the last bar gives up its second; a voice the grid has no row for gets one")
    func clipped() {
        let model = grid(bars: 2)
        let clip = GridClip(stepsPerBar: 16, bars: 2, rows: [
            GroovePattern(voice: .kick, steps: pattern("x--------------- X---------------")),
            GroovePattern(voice: .shaker, steps: pattern("x-x-x-x-x-x-x-x- x-x-x-x-x-x-x-x-")),
        ])
        #expect(!model.voices.contains(.shaker))
        model.paste(clip, intoBar: 1)
        #expect(model.voices.last == .shaker)
        #expect(model.bars == 2)
        #expect(hits(model, .kick) == [16])
        #expect(model.tier(.kick, step: 16) == .normal, "the clip's first bar, not its second")
        #expect(hits(model, .shaker) == Array(stride(from: 16, to: 32, by: 2)))
        model.undo()
        #expect(!model.voices.contains(.shaker))
        #expect(hits(model, .kick).isEmpty)
    }

    @Test("A row lifted off the grid goes down on another row, repeated to the grid's length or cut at its end")
    func rowToRow() throws {
        let model = grid(bars: 2)
        for step in stride(from: 0, to: 16, by: 2) { model.set(.normal, voice: .closedHat, step: step) }
        let row = try #require(model.clip(row: .closedHat))
        #expect(row.bars == 2)
        #expect(row.rows.map(\.voice) == [.closedHat])
        #expect(model.clip(row: .shaker) == nil)
        model.paste(row, ontoRow: .openHat)
        #expect(hits(model, .openHat) == hits(model, .closedHat))

        // A one-bar clip on a two-bar grid repeats, bar by bar.
        let short = GridClip(stepsPerBar: 16, bars: 1, rows: [GroovePattern(voice: .clap, steps: pattern("----x-------x---"))])
        model.paste(short, ontoRow: .snare)
        #expect(hits(model, .snare) == [4, 12, 20, 28])

        // A longer clip is cut at the grid's end.
        let long = GridClip(stepsPerBar: 16, bars: 4, rows: [
            GroovePattern(voice: .kick, steps: pattern(String(repeating: "x---------------", count: 3) + "X---------------")),
        ])
        model.paste(long, ontoRow: .kick)
        #expect(hits(model, .kick) == [0, 16])
        #expect(model.tier(.kick, step: 16) == .normal)

        // A bar on a row: its row of the same voice, else its first.
        let bar = GridClip(stepsPerBar: 16, bars: 1, rows: [
            GroovePattern(voice: .kick, steps: pattern("x---------------")),
            GroovePattern(voice: .snare, steps: pattern("--------x-------")),
        ])
        model.paste(bar, ontoRow: .snare)
        #expect(hits(model, .snare) == [8, 24])
        model.paste(bar, ontoRow: .clap)
        #expect(hits(model, .clap) == [0, 16])
        model.undo()
        #expect(hits(model, .clap).isEmpty)
    }

    @Test("Clearing a bar clears that bar of every row and nothing else, and ⌘Z puts it back")
    func clearBar() {
        let model = grid(bars: 2)
        for voice in model.voices {
            model.set(.normal, voice: voice, step: 0)
            model.set(.normal, voice: voice, step: 16)
        }
        model.clear(bar: 0)
        for voice in model.voices { #expect(hits(model, voice) == [16], "\(voice)") }
        model.undo()
        for voice in model.voices { #expect(hits(model, voice) == [0, 16], "\(voice)") }
        // Nothing in the bar, nothing to undo for it.
        model.clear(bar: 0)
        model.clear(bar: 0)
        model.undo()
        for voice in model.voices { #expect(hits(model, voice) == [0, 16]) }
    }

    @Test("Across kinds of grid every hit lands on its nearest step: eighths on triplets are eight hits, a shuffle keeps its lilt")
    func acrossGrids() {
        let eighths = GridClip(stepsPerBar: 16, bars: 1, rows: [
            GroovePattern(voice: .closedHat, steps: pattern("x-x-x-x-x-x-x-x-")),
        ])
        let triplets = grid(bars: 1, stepsPerBar: 12)
        triplets.paste(eighths, ontoRow: .closedHat)
        #expect(hits(triplets, .closedHat) == [0, 2, 3, 5, 6, 8, 9, 11])

        let shuffle = GridClip(stepsPerBar: 12, bars: 1, rows: [
            GroovePattern(voice: .closedHat, steps: pattern("x-xx-xx-xx-x")),
        ])
        let straight = grid(bars: 1)
        straight.paste(shuffle, ontoRow: .closedHat)
        #expect(hits(straight, .closedHat) == [0, 3, 4, 7, 8, 11, 12, 15])

        // Two hits on one step leave the louder; a bar's last hit stays in its bar.
        let dense = GridClip(stepsPerBar: 16, bars: 2, rows: [
            GroovePattern(voice: .kick, steps: pattern("xX-------------x x---------------")),
        ])
        let quarters = grid(bars: 2, stepsPerBar: 4)
        quarters.paste(dense, intoBar: 0)
        #expect(hits(quarters, .kick) == [0, 3, 4])
        #expect(quarters.tier(.kick, step: 0) == .accent)

        // The same grid comes back as it was.
        #expect(GridModel.resampled(pattern("x-X-o---"), from: 8, to: 8) == pattern("x-X-o---"))
    }

    @Test("Copied to the pasteboard, a bar comes back as itself, reads as text for anything else, and text typed by hand pastes")
    func pasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("mrroboto.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = grid(bars: 2)
        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .snare, step: 4)
        #expect(!model.canPaste(from: board))

        model.copy(bar: 0, to: board)
        #expect(model.canPaste(from: board))
        #expect(GridClip.read(from: board) == model.clip(bar: 0))
        let text = try #require(board.string(forType: .string))
        #expect(text.hasPrefix("kick: X---------------\nsnare: ----x-----------"))
        model.paste(intoBar: 1, from: board)
        #expect(model.tier(.kick, step: 16) == .accent)
        #expect(model.tier(.snare, step: 20) == .normal)

        board.clearContents()
        board.setString("clap: ----x-------x---", forType: .string)
        model.paste(ontoRow: .clap, from: board)
        #expect(hits(model, .clap) == [4, 12, 20, 28])

        model.copy(row: .clap, to: board)
        let row = try #require(GridClip.read(from: board))
        #expect(row.bars == 2)
        #expect(row.rows.map(\.voice) == [.clap])

        board.clearContents()
        board.setString("not a pattern", forType: .string)
        #expect(!model.canPaste(from: board))
        model.paste(intoBar: 0, from: board)
        #expect(model.tier(.kick, step: 0) == .accent, "nothing to put down, nothing changed")
    }
}
