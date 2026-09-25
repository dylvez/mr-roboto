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
public struct GridLayout: Equatable, Sendable {

    public static let minimumRowHeight: CGFloat = 22
    public static let maximumRowHeight: CGFloat = 52
    public static let minimumStepWidth: CGFloat = 16
    public static let rowSpacing: CGFloat = 3
    public static let stepSpacing: CGFloat = 2
    public static let rulerHeight: CGFloat = 14

    /// Header, the two levers, the picker row (its brush caption included) and the provenance
    /// line, plus the gutters between them. Measured from the view, not guessed: these are the
    /// blocks that are not the grid.
    static let chromeHeight: CGFloat = 22 + 72 + 62 + 18 + 4 * Design.Metric.gutter

    public let size: CGSize
    public let contentSize: CGSize
    public let voiceCount: Int
    public let stepCount: Int

    /// The voice-name column. Grows a little with the panel so a long voice name is not truncated
    /// at 1269 points of width to save 40 of them.
    public let labelWidth: CGFloat
    /// One step cell's width, sharing what is left of the row exactly.
    public let stepWidth: CGFloat
    /// One voice's row.
    public let rowHeight: CGFloat
    /// Ruler plus rows plus the spacing between them.
    public let gridHeight: CGFloat
    /// True when the rows do not fit the panel and the grid scrolls inside its area.
    public let gridScrolls: Bool
    /// The height the grid is actually drawn in.
    public let gridAreaHeight: CGFloat

    public init(size: CGSize, voices: Int, steps: Int) {
        self.size = size
        voiceCount = max(1, voices)
        stepCount = max(1, steps)
        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        labelWidth = clamped(content.width * 0.09, 78, 130)
        let forSteps = content.width - labelWidth - CGFloat(stepCount) * Self.stepSpacing
        stepWidth = max(Self.minimumStepWidth, forSteps / CGFloat(stepCount))

        let free = max(Self.minimumRowHeight, content.height - Self.chromeHeight)
        let forRows = free - Self.rulerHeight - CGFloat(voiceCount - 1) * Self.rowSpacing
        rowHeight = clamped(forRows / CGFloat(voiceCount), Self.minimumRowHeight, Self.maximumRowHeight)

        gridHeight = Self.rulerHeight + CGFloat(voiceCount) * rowHeight
            + CGFloat(voiceCount - 1) * Self.rowSpacing
        gridAreaHeight = max(Self.rulerHeight + Self.minimumRowHeight, min(gridHeight, free))
        gridScrolls = gridHeight > gridAreaHeight + 0.5
    }

    /// What the grid's own row is wide, label column included. The step cells are drawn with
    /// `maxWidth: .infinity`, so this is the number they divide rather than one each cell is given.
    public var stepAreaWidth: CGFloat {
        max(1, contentSize.width - labelWidth)
    }
}
