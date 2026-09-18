import CoreGraphics
import Foundation

/// What the Compare surface draws at the size it is actually handed.
///
/// Read `SurfaceLayout` first: a surface is drawn in about 907 × 665 at the default window, 1269 ×
/// 665 with the side regions folded, and 640 × 460 at the window's minimum. Every number here is a
/// plain value so `CompareSurfaceTests` can hold it to all three without a window.
///
/// The decisions, in the order they matter:
///
/// * **The reference band is fixed-ish and the rows take the rest.** The thing being judged against
///   has to stay visible and never scrolls off, so it gets a band at the top sized to its content
///   and not a share of the height. What is left goes to the rows.
/// * **Rows grow rather than multiply.** Two candidates in 665 points get a tall row each, with
///   room for the rationale line under the title; four get a shorter one. This is the opposite of
///   the usual table behaviour and is correct here, because the row is a *thing you press to hear
///   something* — the audition target is the row, and a 28-point row is a bad target.
/// * **The feature columns take the width, and there is a floor under them.** Below
///   `minimumColumnWidth` a column cannot hold "+12.5 ms" in Plex Mono at 12 points, so past that
///   the columns stop shrinking and the surface shows fewer of them rather than showing all of them
///   illegibly. `visibleFeatureCount` is that decision, and it is why this is a value and not a
///   stack of `.frame` modifiers.
/// * **The levers keep their size.** Two sliders at 1269 points of width are not more precise than
///   two sliders at 640; they are just longer. They are capped, exactly as the Sound surface caps
///   its own.
public struct CompareLayout: Equatable, Sendable {

    /// A row you can hit without aiming. `Design.Metric.controlHeight` is 36 and a row carries two
    /// lines of text, so it starts above that.
    public static let minimumRowHeight: CGFloat = 52
    /// Past this a row is spending height it has nothing to put in.
    public static let maximumRowHeight: CGFloat = 112
    public static let rowSpacing: CGFloat = 6
    /// Enough for "+12.5 ms" in the numeric face at 12 points, plus the mark beside it.
    public static let minimumColumnWidth: CGFloat = 72
    public static let maximumColumnWidth: CGFloat = 132
    /// The name column: a candidate title, the persona that proposed it, and a play affordance.
    public static let minimumTitleWidth: CGFloat = 168
    public static let maximumTitleWidth: CGFloat = 300
    /// The lever strip. Capped, not stretched.
    public static let leverWidth: CGFloat = 240
    public static let leverHeight: CGFloat = 58

    /// Header, the reference band, the lever strip, the column headings and the footer, plus the
    /// gutters between them. Measured off the view rather than guessed.
    static let chromeHeight: CGFloat = 22 + 76 + 58 + 20 + 26 + 4 * Design.Metric.gutter

    public let size: CGSize
    public let contentSize: CGSize
    public let candidateCount: Int
    public let featureCount: Int
    public let leverCount: Int

    /// The band at the top holding the thing the candidates are judged against.
    public let referenceHeight: CGFloat
    /// The name column.
    public let titleWidth: CGFloat
    /// One feature column.
    public let columnWidth: CGFloat
    /// How many of the feature columns actually fit. Fewer than `featureCount` means the surface
    /// drops the least important ones rather than squeezing every one below legibility.
    public let visibleFeatureCount: Int
    /// One candidate row.
    public let rowHeight: CGFloat
    /// Rows plus the spacing between them.
    public let rowsHeight: CGFloat
    /// The height the rows are actually drawn in.
    public let rowsAreaHeight: CGFloat
    /// True when the rows do not fit and the list scrolls inside its area.
    public let rowsScroll: Bool
    /// True when a row has the height to carry its rationale line under the title.
    public let showsRationale: Bool

    public init(size: CGSize, candidates: Int, features: Int, levers: Int = 2) {
        self.size = size
        candidateCount = clamped(candidates, CompareModel.minimumCandidates, CompareModel.maximumCandidates)
        featureCount = max(0, features)
        leverCount = clamped(levers, 0, CompareModel.maximumLevers)

        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        // The reference band grows a little with the panel — at 665 points it can afford a second
        // line of readings under the title — but never takes a share of the height that the rows
        // need, because the rows are what is being decided between.
        referenceHeight = clamped(content.height * 0.14, 64, 104)

        titleWidth = clamped(content.width * 0.24, Self.minimumTitleWidth, Self.maximumTitleWidth)

        // Fit as many feature columns as will hold a number, then stop.
        let forColumns = max(0, content.width - titleWidth - Design.Metric.gutter)
        let fitting = featureCount > 0
            ? Int((forColumns / Self.minimumColumnWidth).rounded(.down))
            : 0
        visibleFeatureCount = max(featureCount > 0 ? 1 : 0, min(featureCount, fitting))
        columnWidth = visibleFeatureCount > 0
            ? clamped(forColumns / CGFloat(visibleFeatureCount), Self.minimumColumnWidth, Self.maximumColumnWidth)
            : 0

        let free = max(Self.minimumRowHeight, content.height - Self.chromeHeight - referenceHeight)
        let forRows = free - CGFloat(candidateCount - 1) * Self.rowSpacing
        rowHeight = clamped(forRows / CGFloat(candidateCount), Self.minimumRowHeight, Self.maximumRowHeight)
        rowsHeight = CGFloat(candidateCount) * rowHeight + CGFloat(candidateCount - 1) * Self.rowSpacing
        rowsAreaHeight = max(Self.minimumRowHeight, min(rowsHeight, free))
        rowsScroll = rowsHeight > rowsAreaHeight + 0.5
        // Two lines of Plex — a 16-point title and a 12-point rationale — plus the row's own inset.
        showsRationale = rowHeight >= 66
    }

    /// The width the row's cells share, name column included.
    public var rowWidth: CGFloat {
        max(1, titleWidth + CGFloat(visibleFeatureCount) * columnWidth)
    }

    /// The lever strip's width: the levers plus the gutter between them, capped so two sliders at
    /// 1269 points do not become two very long sliders.
    public var leverStripWidth: CGFloat {
        guard leverCount > 0 else { return 0 }
        return CGFloat(leverCount) * Self.leverWidth + CGFloat(leverCount - 1) * Design.Metric.gutter
    }

    /// True when the reference band has room for its readings beside its title rather than under it.
    public var referenceReadingsInline: Bool { contentSize.width >= 800 }
}
