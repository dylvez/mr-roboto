import CoreGraphics
import Foundation

/// What the Chop lane draws at the size it is actually handed.
///
/// The lane is the surface that most wanted the room, and it wants it in two different currencies:
///
/// * **Height goes to the plate.** A slice marker is dragged on the waveform, and the precision of
///   that drag is bounded by how much of the waveform you can see. In 168 points — the old fixed
///   minimum — a ghost note is three pixels of ink. So the plate takes everything the pads do not
///   need, up to `maximumPlateHeight`, past which a waveform is merely tall.
/// * **Width goes to the pad grid's column count.** The old grid was `.adaptive(minimum: 104)`,
///   which is a fixed rule wearing an adaptive coat: it packed as many 104-point pads as fit and
///   left a ragged gutter. Here the columns are derived from the real width and the pads then share
///   it exactly, so sixteen slices are four rows at the window minimum and two at 1269.
///
/// Nothing here stretches. The levers, the inspector and the header keep the heights they were
/// designed at; only the plate and the pads move, because they are the only two things in the lane
/// whose size buys you anything.
public struct ChopLaneLayout: Equatable, Sendable {

    // MARK: The bounds a lane grows inside

    /// Below this a waveform is a line, not a thing you can put a marker on. It was the old fixed
    /// `minHeight` and is now only the floor.
    public static let minimumPlateHeight: CGFloat = 140
    /// Past this a taller waveform buys nothing: the marker is already sub-pixel accurate and the
    /// pads are what you are reaching for next.
    public static let maximumPlateHeight: CGFloat = 420

    /// A pad has to fit a slice number, a classification and a confidence bar.
    public static let minimumPadWidth: CGFloat = 96
    /// Past this a pad is a poster. An extra column is always the better answer.
    public static let maximumPadWidth: CGFloat = 168
    public static let minimumPadHeight: CGFloat = 62
    public static let maximumPadHeight: CGFloat = 92
    public static let padSpacing: CGFloat = 8

    /// How many rows of pads the lane budgets height for before it lets the grid scroll. Four rows
    /// is a 4×4 pad bank, which is the shape the surface is named after.
    public static let budgetedPadRows = 4

    // MARK: The chrome, at the heights it was designed at

    static let headerHeight: CGFloat = 22
    static let leverHeight: CGFloat = 74
    static let inspectorHeight: CGFloat = 26

    // MARK: What was asked

    public let size: CGSize
    public let sliceCount: Int

    // MARK: What it draws

    /// The lane's interior, inside `Design.Metric.inset`.
    public let contentSize: CGSize
    /// The waveform plate. This is the number the whole exercise is about.
    public let plateHeight: CGFloat
    /// Columns in the pad grid, from the real width.
    public let padColumns: Int
    /// Rows the slices actually occupy at that column count.
    public let padRows: Int
    /// One pad's width, sharing `contentSize.width` exactly.
    public let padWidth: CGFloat
    public let padHeight: CGFloat
    /// The height the pad grid is drawn in. Shorter than the grid needs at the window minimum,
    /// which is what `padsScroll` says out loud.
    public let padAreaHeight: CGFloat
    /// True when the slices do not fit the budgeted rows and the grid scrolls inside its area.
    public let padsScroll: Bool

    public init(size: CGSize, sliceCount: Int) {
        self.size = size
        self.sliceCount = max(0, sliceCount)
        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        // Columns: as many minimum-width pads as the real width holds, then widened to fill it. If
        // that would make a pad a poster, take another column instead.
        var columns = Int(((content.width + Self.padSpacing)
                           / (Self.minimumPadWidth + Self.padSpacing)).rounded(.down))
        columns = clamped(columns, 3, 16)
        var width = Self.padWidth(in: content.width, columns: columns)
        while width > Self.maximumPadWidth, columns < 16 {
            columns += 1
            width = Self.padWidth(in: content.width, columns: columns)
        }
        padColumns = columns
        padWidth = width

        let rows = max(1, Int((Double(self.sliceCount) / Double(columns)).rounded(.up)))
        padRows = rows

        // Five blocks down the lane — header, plate, pads, levers, inspector — so four gutters.
        let gutter = Design.Metric.gutter
        let chrome = Self.headerHeight + Self.leverHeight + Self.inspectorHeight + 4 * gutter
        let free = max(0, content.height - chrome)

        // The pads ask for what they need at their natural height, capped at a 4×4 bank; the plate
        // takes the rest. When the two do not both fit — which is what 460 points of window means —
        // the plate holds its floor and the pad grid is the thing that scrolls.
        let budgetedRows = min(rows, Self.budgetedPadRows)
        let naturalPads = CGFloat(budgetedRows) * Self.minimumPadHeight
            + CGFloat(budgetedRows - 1) * Self.padSpacing
        plateHeight = clamped(free - naturalPads, Self.minimumPlateHeight, Self.maximumPlateHeight)
        let available = max(Self.minimumPadHeight, free - plateHeight)

        // Anything the plate could not use (it is capped) goes back to the pads, so a very tall
        // bench makes the pads bigger rather than leaving a hole under them. What is over after
        // *that* is left to the panel's own trailing space rather than to a stretched pad.
        let perRow = (available - CGFloat(rows - 1) * Self.padSpacing) / CGFloat(rows)
        padHeight = clamped(perRow, Self.minimumPadHeight, Self.maximumPadHeight)
        let grid = CGFloat(rows) * padHeight + CGFloat(rows - 1) * Self.padSpacing
        padAreaHeight = min(available, grid)
        padsScroll = grid > padAreaHeight + 0.5
    }

    private static func padWidth(in width: CGFloat, columns: Int) -> CGFloat {
        let columns = CGFloat(max(1, columns))
        return max(1, (width - (columns - 1) * padSpacing) / columns)
    }

    /// The height the pad grid would like, whether or not it gets it.
    public var padGridHeight: CGFloat {
        CGFloat(padRows) * padHeight + CGFloat(padRows - 1) * Self.padSpacing
    }
}
