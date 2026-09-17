import CoreGraphics
import Foundation
import Testing

@testable import MrRobotoApp

// Do the surfaces use the room they have?
//
// The frame was rebuilt so that one surface fills the bench — 907 × 665 at the default window, 1269
// wide with the side regions folded, 640 × 460 at the window minimum — and every surface in the
// catalog had been authored when a surface got about 610 × 253. They sized themselves to their
// content and top-aligned, leaving a third of a very expensive panel blank.
//
// `LayoutTests` asserts that the *frame* hands a surface those three sizes. These assert what each
// surface does with them, which is a different question and the one that was unanswered. Every
// number below is read off a plain value (`ChopLaneLayout` and friends) rather than off a rendered
// view, so the assertions are about the decision rather than about SwiftUI.
//
// The shape of each test is the same on purpose: **the number has to change between the geometries**.
// A layout that quietly went back to a constant would still be "sensible" at one size; it is the
// difference between 640 and 1269 that says the surface is reading its own width.

/// The three sizes, named once.
private enum Geometry {
    static let minimum = SurfaceGeometry.minimum
    static let standard = SurfaceGeometry.standard
    static let wide = SurfaceGeometry.wide
}

@Suite("Fill: the three geometries a surface is actually drawn in")
struct FillGeometryTests {

    @Test("They are the frame's own numbers, not a copy of them")
    func geometriesComeFromTheFrame() {
        #expect(Geometry.minimum == CGSize(width: 640, height: 460))
        #expect(Geometry.standard == CGSize(width: 907, height: 665))
        #expect(Geometry.wide == CGSize(width: 1269, height: 665))

        // And they are derived, so a change to `Design.Metric` or to the regions moves them.
        #expect(Geometry.minimum.width == Design.Metric.surfaceMinimumWidth)
        #expect(Geometry.standard.height
                    == FrameLayout.surfaceHeight(inWindowOfHeight: FrameLayout.defaultWindowHeight,
                                                 visibleSurfaces: 1))
        #expect(SurfaceGeometry.all.count == 3)
    }

    @Test("The old surface — 610 × 253 — is smaller than any of them on both axes")
    func theOldSurfaceWasSmaller() {
        for size in SurfaceGeometry.all {
            #expect(size.width > 610)
            #expect(size.height > 253)
        }
    }
}

// MARK: - Chop lane

@Suite("Fill: the Chop lane's plate takes the height and its pads take the width")
struct FillChopLaneTests {

    /// Sixteen slices is what a chopped bar of drums actually produces, and the number the pad grid
    /// was designed around.
    private func layout(_ size: CGSize, slices: Int = 16) -> ChopLaneLayout {
        ChopLaneLayout(size: size, sliceCount: slices)
    }

    @Test("The plate is not a constant: 140 at the window minimum, 303 at the default window")
    func plateGrows() {
        let tight = layout(Geometry.minimum)
        let standard = layout(Geometry.standard)
        let wide = layout(Geometry.wide)

        #expect(tight.plateHeight == ChopLaneLayout.minimumPlateHeight)
        #expect(standard.plateHeight > tight.plateHeight)
        // The old fixed `minHeight: 168` is the thing this replaces: at the default window the plate
        // is now most of a marker drag's worth of waveform rather than a strip.
        #expect(standard.plateHeight > 168 * 1.7)
        #expect(standard.plateHeight == 303)

        // Folding the side regions is width, not height, so the plate is unchanged — and that is
        // right. A wider plate is a longer bar, not a taller one.
        #expect(wide.plateHeight == standard.plateHeight)
        for size in SurfaceGeometry.all {
            #expect(layout(size).plateHeight <= ChopLaneLayout.maximumPlateHeight)
        }
    }

    @Test("The pad grid's columns come from the real width: 5, 8, 11")
    func padColumnsFollowWidth() {
        #expect(layout(Geometry.minimum).padColumns == 5)
        #expect(layout(Geometry.standard).padColumns == 8)
        #expect(layout(Geometry.wide).padColumns == 11)

        // Strictly increasing, which is the property a fixed column count cannot have.
        let columns = SurfaceGeometry.all.map { layout($0).padColumns }
        #expect(zip(columns, columns.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("A pad is never a sliver and never a poster, and the row is filled exactly")
    func padsStayWithinBounds() {
        for size in SurfaceGeometry.all {
            let layout = self.layout(size)
            #expect(layout.padWidth >= ChopLaneLayout.minimumPadWidth)
            #expect(layout.padWidth <= ChopLaneLayout.maximumPadWidth)
            #expect(layout.padHeight >= ChopLaneLayout.minimumPadHeight)
            #expect(layout.padHeight <= ChopLaneLayout.maximumPadHeight)

            // The columns share the content width with nothing left over: that is the whole
            // difference from `.adaptive(minimum:)`, which left a ragged gutter.
            let spanned = CGFloat(layout.padColumns) * layout.padWidth
                + CGFloat(layout.padColumns - 1) * ChopLaneLayout.padSpacing
            #expect(abs(spanned - layout.contentSize.width) < 0.001)
        }
    }

    @Test("Sixteen slices are four rows at the minimum and two once there is width")
    func rowsFollowColumns() {
        #expect(layout(Geometry.minimum).padRows == 4)
        #expect(layout(Geometry.standard).padRows == 2)
        #expect(layout(Geometry.wide).padRows == 2)
    }

    @Test("Only the window minimum scrolls its pads, and the plate keeps its floor when it does")
    func scrollingIsTheHonestAnswerAtTheMinimum() {
        let tight = layout(Geometry.minimum)
        #expect(tight.padsScroll)
        #expect(tight.plateHeight == ChopLaneLayout.minimumPlateHeight)

        #expect(layout(Geometry.standard).padsScroll == false)
        #expect(layout(Geometry.wide).padsScroll == false)
    }

    @Test("A lane with few slices still lays out: one row, and the plate takes the rest")
    func fewSlices() {
        let four = layout(Geometry.standard, slices: 4)
        #expect(four.padRows == 1)
        #expect(four.padsScroll == false)
        #expect(four.plateHeight > layout(Geometry.standard).plateHeight)

        // And nothing is asked of a lane with no slices at all.
        let none = layout(Geometry.standard, slices: 0)
        #expect(none.padRows == 1)
        #expect(none.plateHeight > 0)
    }
}

// MARK: - Record

@Suite("Fill: the Record surface's waveform and stem lanes expand")
struct FillImportTests {

    private func layout(_ size: CGSize, lanes: Int = 5) -> ImportLayout {
        ImportLayout(size: size, sectionLanes: lanes)
    }

    @Test("The waveform is a third of the panel rather than a fixed 132 points")
    func waveformGrows() {
        let tight = layout(Geometry.minimum)
        let standard = layout(Geometry.standard)

        #expect(tight.waveformHeight == ImportLayout.minimumWaveformHeight)
        #expect(standard.waveformHeight > tight.waveformHeight)
        #expect(standard.waveformHeight > 180)
        for size in SurfaceGeometry.all {
            #expect(layout(size).waveformHeight <= ImportLayout.maximumWaveformHeight)
        }
    }

    @Test("Four stem lanes in a tall panel are readable rather than four 28-point slivers")
    func stemLanesGrow() {
        let tight = layout(Geometry.minimum)
        let standard = layout(Geometry.standard)

        #expect(tight.stemLaneHeight >= ImportLayout.minimumStemLaneHeight)
        #expect(standard.stemLaneHeight > tight.stemLaneHeight)
        #expect(standard.stemLaneHeight > Design.Metric.chipHeight * 1.5)
        #expect(standard.stemBarHeight < standard.stemLaneHeight)

        // Four of them plus the waveform still leave room for everything else in the panel.
        let stems = 4 * standard.stemLaneHeight + standard.waveformHeight
        #expect(stems < standard.contentSize.height)
    }

    @Test("The lane label column follows the width, so a stem name is not truncated at 1269")
    func laneLabelsFollowWidth() {
        let widths = SurfaceGeometry.all.map { layout($0).laneLabelWidth }
        #expect(widths[0] < widths[2])
        #expect(widths[2] > 100)
        #expect(widths.allSatisfy { $0 >= 70 && $0 <= 130 })
    }

    @Test("The sections strip grows with the number of lanes and with the panel")
    func sectionStrip() {
        let one = layout(Geometry.standard, lanes: 1)
        let five = layout(Geometry.standard, lanes: 5)
        #expect(five.sectionStripHeight > one.sectionStripHeight)
        #expect(five.sectionStripHeight == 5 * five.sectionLaneHeight)
        #expect(layout(Geometry.standard).sectionLaneHeight
                    >= layout(Geometry.minimum).sectionLaneHeight)
    }

    @Test("An empty Record fills the panel with its drop target rather than a 220-point box")
    func dropWellFills() {
        for size in SurfaceGeometry.all {
            let layout = self.layout(size)
            #expect(layout.dropWellHeight >= 220)
            #expect(layout.dropWellHeight <= layout.contentSize.height)
        }
        #expect(layout(Geometry.standard).dropWellHeight > layout(Geometry.minimum).dropWellHeight)
    }
}

// MARK: - Grid

@Suite("Fill: the step grid uses the width for steps and the height for voices")
struct FillGridTests {

    /// What `GridModel.emptyGroove()` opens on: five voices, sixteen steps.
    private func layout(_ size: CGSize, voices: Int = 5, steps: Int = 16) -> GridLayout {
        GridLayout(size: size, voices: voices, steps: steps)
    }

    @Test("A step's width follows the panel: 31, 48, 68 points")
    func stepsTakeTheWidth() {
        let widths = SurfaceGeometry.all.map { layout($0).stepWidth }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 < $1 })
        #expect(widths[0] > GridLayout.minimumStepWidth)
        #expect(widths[2] > widths[0] * 2)

        // The row is filled: label column plus steps plus their spacing is the content width.
        for size in SurfaceGeometry.all {
            let layout = self.layout(size)
            let spanned = layout.labelWidth + CGFloat(layout.stepCount) * layout.stepWidth
                + CGFloat(layout.stepCount) * GridLayout.stepSpacing
            #expect(abs(spanned - layout.contentSize.width) < 0.001)
        }
    }

    @Test("A voice row is not 26 points forever: it takes the height the panel has")
    func voiceRowsTakeTheHeight() {
        let tight = layout(Geometry.minimum)
        let standard = layout(Geometry.standard)

        #expect(standard.rowHeight > tight.rowHeight)
        #expect(standard.rowHeight == GridLayout.maximumRowHeight)
        #expect(tight.rowHeight >= GridLayout.minimumRowHeight)
        // The old constant. At the default window a row is now twice it.
        #expect(standard.rowHeight >= 26 * 2)
    }

    @Test("The grid fits the panel it is drawn in at every geometry")
    func gridFits() {
        for size in SurfaceGeometry.all {
            let layout = self.layout(size)
            #expect(layout.gridAreaHeight <= layout.contentSize.height)
            #expect(layout.gridScrolls == false, "five voices should fit at \(size)")
            #expect(layout.gridHeight
                        == GridLayout.rulerHeight + CGFloat(layout.voiceCount) * layout.rowHeight
                        + CGFloat(layout.voiceCount - 1) * GridLayout.rowSpacing)
        }
    }

    @Test("A grid with many voices shrinks its rows before it scrolls them")
    func manyVoices() {
        let twelve = layout(Geometry.standard, voices: 12)
        let five = layout(Geometry.standard, voices: 5)
        #expect(twelve.rowHeight < five.rowHeight)
        #expect(twelve.rowHeight >= GridLayout.minimumRowHeight)
    }

    @Test("Thirty-two steps are narrower than sixteen, and never below the floor")
    func moreStepsAreNarrower() {
        let sixteen = layout(Geometry.standard, steps: 16)
        let thirtyTwo = layout(Geometry.standard, steps: 32)
        #expect(thirtyTwo.stepWidth < sixteen.stepWidth)
        #expect(thirtyTwo.stepWidth >= GridLayout.minimumStepWidth)
    }
}

// MARK: - Sound

@Suite("Fill: Sound spends the room on what it is editing, not on longer sliders")
struct FillSoundTests {

    private func layout(_ size: CGSize) -> SoundLayout { SoundLayout(size: size) }

    @Test("The voice readout appears once there is height for it, and not before")
    func readoutEarnsItsPlace() {
        #expect(layout(Geometry.minimum).showsVoiceReadout == false)
        #expect(layout(Geometry.standard).showsVoiceReadout)
        #expect(layout(Geometry.wide).showsVoiceReadout)

        let standard = layout(Geometry.standard)
        #expect(standard.readoutHeight > 80)
        #expect(standard.readoutNameSize > 20, "the voice should be named at a size you can read")
        #expect(standard.readoutValueSize > 14, "a real unit set at 11 points is a footnote")
        #expect(standard.readoutHeight < standard.contentSize.height / 4,
                "the readout is a banner, not the panel")

        let tight = layout(Geometry.minimum)
        #expect(tight.readoutHeight == 0)
        #expect(tight.readoutNameSize == 0)
    }

    @Test("The A/B is two chips in a corner only when there is nowhere better for it")
    func monitorSwitchMovesIntoTheReadout() {
        #expect(layout(Geometry.minimum).showsLargeMonitorSwitch == false)
        #expect(layout(Geometry.standard).showsLargeMonitorSwitch)
        #expect(layout(Geometry.wide).showsLargeMonitorSwitch)
    }

    @Test("The sliders are capped. This is the point of the whole surface's answer.")
    func controlsDoNotStretch() {
        for size in SurfaceGeometry.all {
            let layout = self.layout(size)
            #expect(layout.controlWidth <= SoundLayout.maximumControlWidth)
            #expect(layout.controlWidth >= SoundLayout.minimumControlWidth)
            // A control never spans the panel: at 1269 points that would be the ugliness.
            #expect(layout.controlWidth < layout.contentSize.width)
        }
        #expect(layout(Geometry.wide).controlWidth == SoundLayout.maximumControlWidth)
    }

    @Test("Columns follow the width: one prominent lever, then two; two quiet columns, then three")
    func columnsFollowWidth() {
        #expect(layout(Geometry.minimum).prominentColumns == 1)
        #expect(layout(Geometry.standard).prominentColumns == 2)
        #expect(layout(Geometry.wide).prominentColumns == 2)

        #expect(layout(Geometry.minimum).quietColumns == 2)
        #expect(layout(Geometry.standard).quietColumns == 2)
        #expect(layout(Geometry.wide).quietColumns == 3)
    }

    @Test("What a control is really wired to is drawn rather than hidden in a tooltip, given room")
    func unitsComeOutOfTheTooltip() {
        #expect(layout(Geometry.minimum).showsInlineUnits == false)
        #expect(layout(Geometry.standard).showsInlineUnits)
        #expect(layout(Geometry.wide).showsInlineUnits)
    }

    @Test("Nine chain controls in three columns still fit the panel")
    func theChainFits() {
        let wide = layout(Geometry.wide)
        let rows = (9 + wide.quietColumns - 1) / wide.quietColumns
        #expect(rows == 3)
        // Row: a label line, a slider, and the units line, plus the grid's own spacing.
        let estimate = CGFloat(rows) * (16 + 20 + 14 + 12)
        #expect(estimate + wide.readoutHeight < wide.contentSize.height)
    }
}

// MARK: - Across all four

@Suite("Fill: nothing stretches into ugliness")
struct FillRestraintTests {

    @Test("Every surface has something that changes between the minimum and the default window")
    func everySurfaceReadsItsOwnSize() {
        let tight = Geometry.minimum
        let standard = Geometry.standard

        #expect(ChopLaneLayout(size: tight, sliceCount: 16).plateHeight
                    != ChopLaneLayout(size: standard, sliceCount: 16).plateHeight)
        #expect(ImportLayout(size: tight).waveformHeight != ImportLayout(size: standard).waveformHeight)
        #expect(GridLayout(size: tight, voices: 5, steps: 16).rowHeight
                    != GridLayout(size: standard, voices: 5, steps: 16).rowHeight)
        #expect(SoundLayout(size: tight).showsVoiceReadout
                    != SoundLayout(size: standard).showsVoiceReadout)
    }

    @Test("Every surface has something that changes between the default window and a folded one")
    func everySurfaceReadsItsOwnWidth() {
        let standard = Geometry.standard
        let wide = Geometry.wide

        #expect(ChopLaneLayout(size: standard, sliceCount: 16).padColumns
                    != ChopLaneLayout(size: wide, sliceCount: 16).padColumns)
        #expect(ImportLayout(size: standard).laneLabelWidth != ImportLayout(size: wide).laneLabelWidth)
        #expect(GridLayout(size: standard, voices: 5, steps: 16).stepWidth
                    != GridLayout(size: wide, voices: 5, steps: 16).stepWidth)
        #expect(SoundLayout(size: standard).quietColumns != SoundLayout(size: wide).quietColumns)
    }

    @Test("A silly size does not produce a silly layout")
    func degenerateSizes() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 10, height: 10),
                     CGSize(width: 4_000, height: 4_000)] {
            let chop = ChopLaneLayout(size: size, sliceCount: 16)
            #expect(chop.plateHeight >= ChopLaneLayout.minimumPlateHeight)
            #expect(chop.plateHeight <= ChopLaneLayout.maximumPlateHeight)
            #expect(chop.padColumns >= 3)
            #expect(chop.padHeight >= ChopLaneLayout.minimumPadHeight)

            let grid = GridLayout(size: size, voices: 5, steps: 16)
            #expect(grid.rowHeight >= GridLayout.minimumRowHeight)
            #expect(grid.rowHeight <= GridLayout.maximumRowHeight)
            #expect(grid.stepWidth >= GridLayout.minimumStepWidth)

            let record = ImportLayout(size: size)
            #expect(record.waveformHeight >= ImportLayout.minimumWaveformHeight)
            #expect(record.stemLaneHeight >= ImportLayout.minimumStemLaneHeight)

            let sound = SoundLayout(size: size)
            #expect(sound.controlWidth >= SoundLayout.minimumControlWidth)
            #expect(sound.controlWidth <= SoundLayout.maximumControlWidth)
            #expect(sound.quietColumns >= 2)
        }
    }
}
