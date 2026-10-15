import Foundation
import Testing

@testable import MrRobotoApp

// The lane looked at closer. A long line scrolled at a floor of 28 points a beat — a sixteenth
// seven points wide, grabbable and no more — and the line doubled to eight or sixteen bars is the
// one that then wants varying bar by bar. So the lane shows a few bars across its width and scrolls
// the rest: never narrower than the whole line, and never an edit.

@Suite("Piano roll zoom: the lane looked at closer, never narrower than the whole line") @MainActor
struct PianoRollZoomTests {

    /// What the roll draws a tune in: C4 to C6, 25 rows.
    private static let tune = 60...84

    private func lane(beats: Double, beatsAcross: Double?, width: CGFloat = 1000) -> NoteLaneLayout {
        NoteLaneLayout(size: CGSize(width: width, height: 300), rows: Self.tune.count, beats: beats, beatsAcross: beatsAcross)
    }

    private func roll(bars: Int) -> PianoRollModel {
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 92)
        model.setLength(bars)
        return model
    }

    // MARK: The layout

    @Test("Sixteen bars at four across: a beat is a sixteenth of the lane, and the rest scrolls")
    func fourAcross() {
        let four = lane(beats: 64, beatsAcross: 16)
        #expect(abs(four.beatWidth - four.visibleWidth / 16) < 0.001)
        #expect(abs(four.gridWidth - four.beatWidth * 64) < 0.001)
        #expect(four.scrolls)
        #expect(four.beatWidth > NoteLaneLayout.minimumBeatWidth)
        // One bar across: a beat is a quarter of the lane.
        let one = lane(beats: 64, beatsAcross: 4)
        #expect(abs(one.beatWidth - one.visibleWidth / 4) < 0.001)
        #expect(one.beatWidth > four.beatWidth)
    }

    @Test("Closer is never a narrower beat than the whole line, and a level wider than the line is the line")
    func neverNarrowerThanFit() {
        for size in SurfaceGeometry.all {
            let width = SurfaceGeometry.content(of: size).width
            for bars in [1, 2, 4, 8, 16] {
                let beats = Double(bars * 4)
                let fit = lane(beats: beats, beatsAcross: nil, width: width)
                for level in PianoRollModel.zoomLevels {
                    let zoomed = lane(beats: beats, beatsAcross: Double(level * 4), width: width)
                    #expect(zoomed.beatWidth >= fit.beatWidth - 0.001, "\(level) across of \(bars) bars at \(size)")
                    #expect(zoomed.beatWidth >= NoteLaneLayout.minimumBeatWidth)
                    #expect(zoomed.rowHeight == fit.rowHeight, "zoom is across, not down")
                    if level >= bars {
                        #expect(zoomed == fit, "\(level) across of \(bars) bars is the whole line")
                    }
                }
            }
        }
    }

    @Test("Two bars at one across fill the lane with a bar, and scroll for the other")
    func shortLineCloser() {
        let fit = lane(beats: 8, beatsAcross: nil)
        #expect(!fit.scrolls)
        let closer = lane(beats: 8, beatsAcross: 4)
        #expect(closer.scrolls)
        #expect(abs(closer.beatWidth - closer.visibleWidth / 4) < 0.001)
        #expect(abs(closer.gridWidth - 2 * closer.visibleWidth) < 0.001)
    }

    // MARK: The steps

    @Test("From the whole line, closer steps to eight, four, two and one bars across and stops; wider steps back to the whole line")
    func steps() {
        let model = roll(bars: 16)
        #expect(model.barsAcross == nil)
        #expect(model.beatsAcross == nil)
        #expect(model.canZoomIn)
        #expect(!model.canZoomOut)
        var seen: [Int?] = []
        while model.canZoomIn { model.zoomIn(); seen.append(model.barsAcross) }
        #expect(seen == [8, 4, 2, 1])
        model.zoomIn()
        #expect(model.barsAcross == 1, "nothing closer than a bar")
        #expect(model.beatsAcross == 4)
        seen = []
        while model.canZoomOut { model.zoomOut(); seen.append(model.barsAcross) }
        #expect(seen == [2, 4, 8, nil])
        model.zoomIn()
        model.zoomIn()
        #expect(model.beatsAcross == 16)
        model.zoomToFit()
        #expect(model.barsAcross == nil)
        #expect(!model.canZoomOut)
    }

    @Test("A short line skips the levels that would show all of it: two bars go straight to one, and a bar has nowhere closer")
    func shortLines() {
        let two = roll(bars: 2)
        #expect(two.canZoomIn)
        two.zoomIn()
        #expect(two.barsAcross == 1)
        #expect(!two.canZoomIn)
        two.zoomOut()
        #expect(two.barsAcross == nil)

        let one = roll(bars: 1)
        #expect(!one.canZoomIn)
        #expect(!one.canZoomOut)
        one.zoomIn()
        #expect(one.barsAcross == nil)
    }

    @Test("A line shortened under its level is the whole line; lengthened again, it is looked at as it was")
    func lengthChanges() {
        let model = roll(bars: 16)
        model.zoomIn()
        model.zoomIn()
        #expect(model.barsAcross == 4)
        model.setLength(2)
        #expect(model.barsAcross == nil, "two bars at four across is the whole line")
        #expect(!model.canZoomOut)
        #expect(model.canZoomIn, "and a bar across is still closer")
        model.setLength(8)
        #expect(model.barsAcross == 4)
    }

    @Test("Zoom is not an edit: ⌘Z after a zoom takes back the length, not the zoom")
    func notAnEdit() {
        let model = roll(bars: 8)
        let unkept = model.hasUnkeptChanges
        #expect(model.canUndo, "the length was an edit")
        model.zoomIn()
        #expect(model.hasUnkeptChanges == unkept)
        model.undo()
        #expect(model.lengthInBars != 8, "the step taken back was the length")
    }
}
