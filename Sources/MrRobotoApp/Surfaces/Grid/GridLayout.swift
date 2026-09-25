import CoreGraphics
import Foundation

/// What the step grid draws at the size it is actually handed.
///
/// The grid had two constants in it — a 26-point row and a 78-point label column — and 16 steps
/// sharing whatever width was left. In 665 points of bench that put five voice rows in the top
/// quarter of the panel and left the rest empty, which reads as "the grid is small" rather than as
/// "the grid is five voices".
///
/// So both axes are spent on the grid itself: the steps take the width, the voice rows take the
/// height, and the two are computed rather than assumed. The levers above it (swing, ghost) and the
/// pickers below (tempo, machine, feel) keep their sizes — they are controls, and a wider slider is
/// not a more precise one past the point where a pixel is a value.
///
/// A step never goes below `minimumStepWidth`. Once the grid sets its own length, four bars of
/// sixteenths share the width of one, and at eight bars an equal share is four points — a cell you
/// cannot hit. Past the point where the steps would go under the floor they keep the floor and
/// scroll sideways instead, with the voice names pinned at the left.
public struct GridLayout: Equatable, Sendable {

    public static let minimumRowHeight: CGFloat = 22
    public static let maximumRowHeight: CGFloat = 52
    /// The narrowest a step is drawn. The grid scrolls rather than go under it.
    public static let minimumStepWidth: CGFloat = 16
    public static let rowSpacing: CGFloat = 3
    public static let stepSpacing: CGFloat = 2
    /// Tall enough for the bar numbers over the steps and, in the label column, the "+ Voice" menu.
    public static let rulerHeight: CGFloat = 18
    /// Room under the rows for a horizontal scroller when the steps scroll, so a scroller that
    /// takes space (a mouse attached, or "always show") does not sit over the last voice's cells.
    public static let scrollerAllowance: CGFloat = 12
    /// The one line the notes under the grid are sure of: the Beatmaker's heading, or the
    /// provenance line. They take whatever else the panel has spare.
    public static let notesMinimumHeight: CGFloat = 18
    /// The empty grid's picture is shown only when the notes have this much room for it.
    static let emptyArtHeight: CGFloat = 90

    /// The pickers — brush, tempo, machine, feel, clear — are about 770 points of controls that do
    /// not get better narrower. Below this they go to two rows rather than run off the panel's edge,
    /// and the brush's gesture caption moves into its tooltip to pay for the second row.
    static let pickersSingleRowWidth: CGFloat = 780
    /// The picker row with its brush caption wrapped to three lines, measured from a render.
    static let pickersOneRowHeight: CGFloat = 84
    /// Two rows of labelled controls and the spacing between them, no caption.
    static let pickersTwoRowHeight: CGFloat = 92
    /// The header is a chip tall: the undo and redo chips and the length menu sit in it.
    static let headerHeight: CGFloat = Design.Metric.chipHeight
    /// Swing and ghost: a label, a slider, and the detent row under swing.
    static let leversHeight: CGFloat = 62

    public let size: CGSize
    public let contentSize: CGSize
    public let voiceCount: Int
    public let stepCount: Int

    /// The voice-name column. Grows a little with the panel so a long voice name is not truncated
    /// at 1269 points of width to save 40 of them.
    public let labelWidth: CGFloat
    /// One step cell's width: an equal share of what is left of the row, or the floor.
    public let stepWidth: CGFloat
    /// True when the steps at `stepWidth` are wider than the room beside the label column, and so
    /// scroll sideways under a pinned label column.
    public let stepsScroll: Bool
    /// One voice's row.
    public let rowHeight: CGFloat
    /// Ruler plus rows plus the spacing between them, and the scroller's room when the steps scroll.
    public let gridHeight: CGFloat
    /// True when the rows do not fit the panel and the grid scrolls inside its area.
    public let gridScrolls: Bool
    /// The height the grid is actually drawn in.
    public let gridAreaHeight: CGFloat
    /// True when the panel is too narrow for the pickers in one row.
    public let pickersWrap: Bool

    /// Header, the two levers, the pickers and the first line of the notes under the grid, plus
    /// the gutters between the five blocks: everything that is not the grid. Measured from the
    /// view, not guessed, and it depends on the width because the pickers do.
    public var chromeHeight: CGFloat { Self.chromeHeight(pickersWrap: pickersWrap) }

    static func chromeHeight(pickersWrap: Bool) -> CGFloat {
        headerHeight + leversHeight + (pickersWrap ? pickersTwoRowHeight : pickersOneRowHeight)
            + notesMinimumHeight + 4 * Design.Metric.gutter
    }

    public init(size: CGSize, voices: Int, steps: Int) {
        self.size = size
        voiceCount = max(1, voices)
        stepCount = max(1, steps)
        let content = SurfaceGeometry.content(of: size)
        contentSize = content
        pickersWrap = content.width < Self.pickersSingleRowWidth
        let chrome = Self.chromeHeight(pickersWrap: pickersWrap)

        labelWidth = clamped(content.width * 0.09, 78, 130)
        let forSteps = content.width - labelWidth - CGFloat(stepCount) * Self.stepSpacing
        let share = forSteps / CGFloat(stepCount)
        stepWidth = max(Self.minimumStepWidth, share)
        stepsScroll = share < Self.minimumStepWidth - 0.001

        let scroller = stepsScroll ? Self.scrollerAllowance : 0
        let free = max(Self.minimumRowHeight, content.height - chrome)
        let forRows = free - Self.rulerHeight - scroller - CGFloat(voiceCount - 1) * Self.rowSpacing
        rowHeight = clamped(forRows / CGFloat(voiceCount), Self.minimumRowHeight, Self.maximumRowHeight)

        gridHeight = Self.rulerHeight + CGFloat(voiceCount) * rowHeight
            + CGFloat(voiceCount - 1) * Self.rowSpacing + scroller
        gridAreaHeight = max(Self.rulerHeight + Self.minimumRowHeight, min(gridHeight, free))
        gridScrolls = gridHeight > gridAreaHeight + 0.5
    }

    // MARK: The steps, as positions

    /// From one step's leading edge to the next.
    public var stepPitch: CGFloat { stepWidth + Self.stepSpacing }

    /// Every step, cell and spacing, end to end: the width the scrolled content is drawn at.
    public var stepsContentWidth: CGFloat {
        CGFloat(stepCount) * stepWidth + CGFloat(stepCount - 1) * Self.stepSpacing
    }

    /// Where a step's cell begins, measured from the first step's leading edge.
    public func x(ofStep step: Int) -> CGFloat { CGFloat(step) * stepPitch }

    /// Where a bar line is drawn before `step`: in the spacing between it and the step before, so
    /// the line never covers a cell.
    public func barLineX(beforeStep step: Int) -> CGFloat { x(ofStep: step) - Self.stepSpacing }

    /// The step under a point on the row, measured the same way. The spacing after a cell belongs
    /// to that cell, so there is no dead strip between two steps for a drag to fall through.
    public func step(atX x: CGFloat) -> Int? {
        guard x >= 0 else { return nil }
        let index = Int(x / stepPitch)
        return index < stepCount ? index : nil
    }

    // MARK: Under the grid

    /// The height left under the grid for the notes — the Beatmaker's reading, the empty grid's
    /// note, the feel's provenance — once everything else has its size.
    public var notesHeight: CGFloat {
        max(Self.notesMinimumHeight,
            contentSize.height - (chromeHeight - Self.notesMinimumHeight) - gridAreaHeight)
    }

    /// Whether the empty grid's note has room for its picture. At the window minimum it says the
    /// same thing in words alone.
    public var showsEmptyArt: Bool { notesHeight >= Self.emptyArtHeight }
}
