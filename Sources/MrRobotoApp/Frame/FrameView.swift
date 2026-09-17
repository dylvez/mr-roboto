import SwiftUI

/// The frame's fixed geometry, in one place so the window's minimum size and the regions themselves
/// cannot drift apart. The widths come from `Design.Metric`; only the bench is elastic.
public enum FrameLayout {
    public static let librarySidebarWidth = Design.Metric.librarySidebarWidth
    public static let conversationRailWidth = Design.Metric.conversationRailWidth
    public static let partsLedgerWidth = Design.Metric.partsLedgerWidth
    public static let headerHeight = Design.Metric.headerHeight
    public static let transportHeight = Design.Metric.transportHeight

    /// The narrowest a surface may be drawn. Below this a chop lane stops being readable.
    public static let benchMinimumWidth: CGFloat = 380

    /// Everything that never changes width.
    public static var fixedWidth: CGFloat {
        librarySidebarWidth + conversationRailWidth + partsLedgerWidth
    }

    /// What the bench gets at a given window width, never less than its minimum.
    public static func benchWidth(inWindowOfWidth width: CGFloat) -> CGFloat {
        max(benchMinimumWidth, width - fixedWidth - 2 * Design.Metric.gutter)
    }

    /// The window minimum: every fixed region at full width plus a readable bench.
    public static var minimumWindowWidth: CGFloat {
        fixedWidth + benchMinimumWidth + 2 * Design.Metric.gutter
    }

    /// Header and transport plus enough bench for three stacked surfaces to be worth opening.
    public static var minimumWindowHeight: CGFloat { headerHeight + transportHeight + 620 }
}

/// The persistent frame. Library sidebar, conversation rail, bench, parts ledger, transport — these
/// never move. Surfaces come and go inside the bench; everything else is furniture.
///
/// The body is deliberately thin: every decision it makes is a value on `AppState` or a constant in
/// `FrameLayout`, both of which are tested directly.
struct FrameView: View {
    @Bindable var app: AppState
    var registry: SurfaceRegistry = .shared

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(app: app)
            Hairline()
            HStack(spacing: 0) {
                LibrarySidebar(app: app)
                    .frame(width: FrameLayout.librarySidebarWidth)
                Hairline(axis: .vertical)
                ConversationRail(app: app)
                    .frame(width: FrameLayout.conversationRailWidth)
                Hairline(axis: .vertical)
                BenchColumn(app: app, registry: registry)
                    .frame(minWidth: FrameLayout.benchMinimumWidth, maxWidth: .infinity)
                PartsLedger(app: app)
                    .frame(width: FrameLayout.partsLedgerWidth)
            }
            .frame(maxHeight: .infinity)
            Hairline()
            TransportBar(app: app)
        }
        .background(Design.Palette.paper)
        .foregroundStyle(Design.Palette.ink)
        .frame(minWidth: FrameLayout.minimumWindowWidth, minHeight: FrameLayout.minimumWindowHeight)
    }
}
