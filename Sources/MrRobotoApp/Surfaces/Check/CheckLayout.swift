import CoreGraphics
import Foundation

/// What the Check surface draws at the size it is actually handed.
///
/// This is the surface with the *least* to show and the most room to show it in, which is a real
/// design problem rather than a happy one. A check card is one headline, one sentence, a
/// measurement, a play control and two fixes — about eight lines of content — and it is handed 907 ×
/// 665 at the default window. Stretching those eight lines across 665 points would be worse than
/// the panel being small.
///
/// So the room is spent on three things, in this order:
///
/// 1. **A type size you read rather than scan.** The headline grows from 17 points at the window
///    minimum to 22 at the default window, and the reason sentence from 13 to 15.5. This is the one
///    surface in the catalog where the content is prose and the prose is the point.
/// 2. **The two fixes become cards side by side rather than a stacked list.** Past
///    `sideBySideWidth` there is room for two fix cards next to each other, which is the layout the
///    decision actually wants: two options you weigh against each other, not a first choice and a
///    second one. Below it they stack.
/// 3. **A measurement panel that shows the arithmetic.** At the window minimum the finding shows its
///    number; with room it shows the number, the threshold, and the critic's own sentence about what
///    it checks. That is `showsArithmetic`.
///
/// What the room is *not* spent on: the card is centred in a column of at most `maximumCardWidth`
/// and does not grow past it. A 1233-point line of prose is unreadable, and the surface having
/// margins is not the surface wasting space.
public struct CheckLayout: Equatable, Sendable {

    /// Past this a line of prose is too long to track back to the start of.
    public static let maximumCardWidth: CGFloat = 720
    /// Below this two fix cards cannot both hold a title and a sentence.
    public static let sideBySideWidth: CGFloat = 620
    public static let minimumFixHeight: CGFloat = 96
    public static let maximumFixHeight: CGFloat = 168
    /// The hear-it control. Big, because it is the first thing anybody should press.
    public static let hearHeight: CGFloat = 44

    public let size: CGSize
    public let contentSize: CGSize

    /// The column the card is drawn in, centred.
    public let cardWidth: CGFloat
    /// The headline's point size.
    public let headlineSize: CGFloat
    /// The reason sentence's point size.
    public let reasonSize: CGFloat
    /// True when the two fixes sit beside each other rather than stacked.
    public let fixesSideBySide: Bool
    /// One fix card's width.
    public let fixWidth: CGFloat
    /// One fix card's height.
    public let fixHeight: CGFloat
    /// True when the measurement panel shows the threshold and the critic's sentence, not just the
    /// number.
    public let showsArithmetic: Bool
    /// Room left under the fixes, which the outcome line and the dismiss control sit in.
    public let footerHeight: CGFloat

    /// Header, the attribution line, the locus line, the hear control, and the gutters between them
    /// and the fixes. What the card costs before the measurement panel and the fixes.
    public static let baseChromeHeight: CGFloat = 22 + 18 + 18 + hearHeight + 4 * Design.Metric.gutter
    /// The measurement panel, when it is shown, plus its own gutter.
    public static let arithmeticHeight: CGFloat = 52 + Design.Metric.gutter
    /// Reserved for the outcome line and the keep-it control under the fixes. A constant rather
    /// than a share: it is one line of text at every size.
    public static let footerReserve: CGFloat = 28

    /// What the card costs above the fixes at this size.
    public var chromeHeight: CGFloat {
        Self.baseChromeHeight + (showsArithmetic ? Self.arithmeticHeight : 0)
    }

    public init(size: CGSize) {
        self.size = size
        let content = SurfaceGeometry.content(of: size)
        contentSize = content

        cardWidth = min(content.width, Self.maximumCardWidth)
        // The two anchors are the geometries the surface is actually drawn in: 17 points at the
        // window minimum's 604 of content, 22 at the default window's 871, and no further. A
        // headline is read once; it can afford the size, and it cannot afford to be a poster.
        let span = (content.width - 604) / 267
        headlineSize = clamped(17 + span * 5, 17, 22)
        reasonSize = clamped(13 + span * 2.5, 13, 15.5)

        fixesSideBySide = cardWidth >= Self.sideBySideWidth
        fixWidth = fixesSideBySide
            ? (cardWidth - Design.Metric.gutter) / 2
            : cardWidth

        // The arithmetic needs a second line under the number and a third for the critic's own
        // sentence, so it is the first thing to go when the panel is short.
        showsArithmetic = content.height >= 520 && cardWidth >= 560
        let chrome = Self.baseChromeHeight + (showsArithmetic ? Self.arithmeticHeight : 0)

        // Stacked fixes cost twice the height, so the per-card height comes out of what is left
        // rather than being a constant. This is the whole reason the arithmetic panel is
        // conditional: at the window minimum the two fix cards need the room it would have taken.
        let rows: CGFloat = fixesSideBySide ? 1 : 2
        let free = max(Self.minimumFixHeight, content.height - chrome - Self.footerReserve)
        let forFixes = (free - (rows - 1) * Design.Metric.gutter) / rows
        fixHeight = clamped(forFixes, Self.minimumFixHeight, Self.maximumFixHeight)

        let used = fixHeight * rows + (rows - 1) * Design.Metric.gutter
        footerHeight = max(Self.footerReserve, content.height - chrome - used)
    }

    /// The horizontal inset that centres the card in the panel.
    public var cardInset: CGFloat {
        max(0, (contentSize.width - cardWidth) / 2)
    }
}
