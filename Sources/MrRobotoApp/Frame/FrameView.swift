import SwiftUI

/// The frame's geometry, in one place so the window's minimum size and the regions themselves cannot
/// drift apart.
///
/// **The instrument dominates the screen; everything else is on call.** That sentence is the whole
/// of this file. It replaces the arithmetic the frame used to do, which was: three fixed regions plus
/// a header plus a transport, and the bench gets the remainder. At 1440 the remainder was 610 points
/// — 42% of the window — and the catalog's three-surfaces-stacked rule then cut that into thirds
/// vertically, so the Chop lane was asked to draw a waveform, sixteen pads, the per-slice controls
/// and the re-groove picker in 610 × 253.
///
/// Two things changed. Every flanking region collapses to a strip (`FrameRegion`), so what the frame
/// costs is what you have asked it to cost; and the bench draws the surface you are working in plus
/// anything you pinned, rather than three at once. The three-at-once capability is still there — Gate
/// B's Director needs it to put a Compare and a Check beside a decision — it is simply no longer the
/// default, because Gate A has no Director and you drive exactly one surface at a time.
///
/// Every number here is derived from `Design.Metric`, and every one of them is asserted in
/// `LayoutTests` at the minimum window, at 1440 and at 1728, so a later change cannot quietly take
/// the bench's space back.
public enum FrameLayout {
    public static let librarySidebarWidth = Design.Metric.librarySidebarWidth
    public static let conversationRailWidth = Design.Metric.conversationRailWidth
    public static let partsLedgerWidth = Design.Metric.partsLedgerWidth
    public static let collapsedRegionWidth = Design.Metric.collapsedRegionWidth
    public static let headerHeight = Design.Metric.headerHeight
    public static let transportHeight = Design.Metric.transportHeight

    /// The bench's own header: the surface dock, which is how you move between surfaces now that
    /// only one is drawn at a time.
    public static let dockHeight = Design.Metric.headerHeight

    /// The padding between the bench's edge and a surface, on both axes.
    public static let benchPadding = Design.Metric.gutter
    /// The gap between two surfaces when a pin has split the bench.
    public static let benchSpacing = Design.Metric.gutter

    /// What a surface actually needs, from the design tokens. The window's minimum is built from
    /// this rather than from the sum of the furniture — that inversion is the point.
    public static let surfaceMinimumWidth = Design.Metric.surfaceMinimumWidth
    public static let surfaceMinimumHeight = Design.Metric.surfaceMinimumHeight

    /// The bench at its narrowest: a surface at its minimum, plus the bench's own padding.
    public static var benchMinimumWidth: CGFloat { surfaceMinimumWidth + 2 * benchPadding }

    /// The vertical hairlines between the four columns: library│rail│bench│ledger.
    public static let verticalDividers: CGFloat = 3 * Design.Metric.hairline
    /// The horizontal hairlines under the header and above the transport.
    public static let horizontalDividers: CGFloat = 2 * Design.Metric.hairline

    // MARK: Regions

    /// What a first launch collapses.
    public static var defaultCollapsedRegions: Set<FrameRegion> {
        Set(FrameRegion.allCases.filter(\.isCollapsedByDefault))
    }

    /// Everything that is not the bench, given which regions are put away.
    public static func fixedWidth(collapsed: Set<FrameRegion> = []) -> CGFloat {
        FrameRegion.allCases.reduce(verticalDividers) { total, region in
            total + (collapsed.contains(region) ? collapsedRegionWidth : region.expandedWidth)
        }
    }

    // MARK: Width

    /// What the bench gets at a given window width, never less than its minimum.
    public static func benchWidth(inWindowOfWidth width: CGFloat,
                                  collapsed: Set<FrameRegion> = []) -> CGFloat {
        max(benchMinimumWidth, width - fixedWidth(collapsed: collapsed))
    }

    /// What a surface gets: the bench, less the bench's own padding.
    public static func surfaceWidth(inWindowOfWidth width: CGFloat,
                                    collapsed: Set<FrameRegion> = []) -> CGFloat {
        benchWidth(inWindowOfWidth: width, collapsed: collapsed) - 2 * benchPadding
    }

    /// The fraction of the window the open surface is drawn in. The number the complaint was about:
    /// it was 0.42, and `LayoutTests` now holds it above `minimumSurfaceShare`.
    public static func surfaceShare(inWindowOfWidth width: CGFloat,
                                    collapsed: Set<FrameRegion> = []) -> CGFloat {
        guard width > 0 else { return 0 }
        return surfaceWidth(inWindowOfWidth: width, collapsed: collapsed) / width
    }

    /// The share the default layout owes the instrument at the default window size. Asserted rather
    /// than aspired to.
    public static let minimumSurfaceShare: CGFloat = 0.6

    /// The window size the app opens at, which is what `minimumSurfaceShare` is measured against.
    public static let defaultWindowWidth: CGFloat = 1440
    public static let defaultWindowHeight: CGFloat = 900

    // MARK: Height

    /// The bench column: everything between the header and the transport.
    public static func benchHeight(inWindowOfHeight height: CGFloat) -> CGFloat {
        height - headerHeight - transportHeight - horizontalDividers
    }

    /// The bench's interior, below the dock and inside its padding.
    public static func benchContentHeight(inWindowOfHeight height: CGFloat) -> CGFloat {
        benchHeight(inWindowOfHeight: height) - dockHeight - Design.Metric.hairline - 2 * benchPadding
    }

    /// What one surface is drawn in, when `visibleSurfaces` of them share the bench.
    public static func surfaceHeight(inWindowOfHeight height: CGFloat,
                                     visibleSurfaces: Int = 1) -> CGFloat {
        let count = CGFloat(max(1, visibleSurfaces))
        return (benchContentHeight(inWindowOfHeight: height) - (count - 1) * benchSpacing) / count
    }

    // MARK: The window minimum

    /// The narrowest this window may be, given what is open.
    ///
    /// It is a function of the regions rather than a constant, which is the honest version of a
    /// minimum: with everything put away the floor is a surface at its minimum plus three strips;
    /// asking for a region back asks the window for its width. The old 1246 existed only because
    /// three fixed regions plus a bench added up to it.
    public static func minimumWindowWidth(collapsed: Set<FrameRegion>) -> CGFloat {
        fixedWidth(collapsed: collapsed) + benchMinimumWidth
    }

    /// The floor: every region collapsed, one surface at the width it needs.
    public static var minimumWindowWidth: CGFloat {
        minimumWindowWidth(collapsed: Set(FrameRegion.allCases))
    }

    /// Header, transport, dock, padding, and one surface at the height it needs.
    public static var minimumWindowHeight: CGFloat {
        surfaceMinimumHeight + headerHeight + transportHeight + horizontalDividers
            + dockHeight + Design.Metric.hairline + 2 * benchPadding
    }
}

/// The persistent frame. Library, session rail, bench, parts ledger, transport — these never move,
/// but three of them now fold away. Surfaces come and go inside the bench; everything else is
/// furniture, and furniture is on call.
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
                RegionColumn(region: .library, app: app, badge: libraryBadge) {
                    LibrarySidebar(app: app)
                }
                Hairline(axis: .vertical)
                RegionColumn(region: .rail, app: app, badge: railBadge,
                             isAccented: !app.proposals.isEmpty) {
                    ConversationRail(app: app)
                }
                Hairline(axis: .vertical)
                BenchColumn(app: app, registry: registry)
                    .frame(minWidth: FrameLayout.benchMinimumWidth, maxWidth: .infinity)
                Hairline(axis: .vertical)
                RegionColumn(region: .ledger, app: app, badge: ledgerBadge) {
                    PartsLedger(app: app)
                }
            }
            .frame(maxHeight: .infinity)
            Hairline()
            TransportBar(app: app)
        }
        .background(Design.Palette.paper)
        .foregroundStyle(Design.Palette.ink)
        .frame(minWidth: FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed),
               minHeight: FrameLayout.minimumWindowHeight)
    }

    /// A collapsed region still says how much it is holding, so putting one away is not the same as
    /// forgetting what is in it.
    private var libraryBadge: String {
        let count = app.library.songs.count
        return count == 0 ? "" : "\(count)"
    }

    private var railBadge: String {
        let waiting = app.proposals.count
        return waiting > 0 ? "\(waiting)" : (app.log.isEmpty ? "" : "\(app.log.count)")
    }

    private var ledgerBadge: String {
        let count = app.versions.count
        return count == 0 ? "" : "\(count)"
    }
}
