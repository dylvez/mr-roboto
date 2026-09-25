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

    // MARK: Growing the window to fit

    /// The frame a window should take so that its content is at least `minimum` wide and tall,
    /// on a screen of `visible` (the screen less the menu bar and the Dock). Nil when the window
    /// already fits and nothing has to move.
    ///
    /// The window grows to the right and down, keeps its origin where the screen allows, and is
    /// pushed left or up when growing would run it off the edge — the way a person would drag it.
    /// It never grows past the screen: a frame wider than the display is clipped again on the far
    /// side, which is the state this exists to end.
    public static func fittedFrame(for window: CGRect, minimum: CGSize, visible: CGRect) -> CGRect? {
        let width = max(window.width, min(minimum.width, visible.width))
        let height = max(window.height, min(minimum.height, visible.height))
        guard width > window.width || height > window.height else { return nil }
        var x = window.minX
        var y = window.minY
        // Cocoa's y grows upward: a window that grows taller keeps its top where it was.
        y -= height - window.height
        if x + width > visible.maxX { x = visible.maxX - width }
        if y < visible.minY { y = visible.minY }
        x = max(visible.minX, x)
        y = min(y, visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Grows the window when the frame's minimum outgrows it — a region opened, a first launch on a
/// remembered size that no longer fits — and leaves it alone otherwise.
///
/// An `NSViewRepresentable` because that is the honest way to reach the window from inside SwiftUI:
/// the view is invisible, sits behind the frame, and asks its window for a size once it is in one.
private struct WindowFitter: NSViewRepresentable {
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let minimum = CGSize(width: minimumWidth, height: minimumHeight)
        // On the next turn of the loop: the window is attached after the view is, and a size asked
        // for during a layout pass is a size asked for too early.
        DispatchQueue.main.async {
            guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            guard let fitted = FrameLayout.fittedFrame(for: window.frame, minimum: minimum, visible: visible) else { return }
            window.setFrame(fitted, display: true, animate: false)
        }
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
        let minimumWidth = FrameLayout.minimumWindowWidth(collapsed: app.regions.collapsed)
        VStack(spacing: 0) {
            HeaderBar(app: app)
            Hairline()
            HStack(spacing: 0) {
                RegionColumn(region: .library, app: app, badge: libraryBadge) {
                    LibrarySidebar(app: app)
                }
                Hairline(axis: .vertical)
                RegionColumn(region: .rail, app: app, badge: railBadge,
                             isAccented: !app.proposals.isEmpty || app.unseenSessionNotes > 0,
                             isWarning: app.unseenSessionNotes > 0) {
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
        .frame(minWidth: minimumWidth, minHeight: FrameLayout.minimumWindowHeight)
        // "Asking for a region back asks the window for its width" — but SwiftUI only raises the
        // window's *minimum*; it does not grow a window that is already smaller than it. With
        // all three regions open at the default 1440 the frame was 1509 wide, centred, and cut
        // off on both sides: "RARY" for LIBRARY, the Save button half gone. This grows the window.
        .background(WindowFitter(minimumWidth: minimumWidth, minimumHeight: FrameLayout.minimumWindowHeight))
        .onChange(of: app.regions.isCollapsed(.rail)) { _, collapsed in
            // The rail opened: its lines have been looked at.
            if !collapsed { app.markRailSeen() }
        }
    }

    /// A collapsed region still says how much it is holding, so putting one away is not the same as
    /// forgetting what is in it.
    private var libraryBadge: String {
        let count = app.library.songs.count
        return count == 0 ? "" : "\(count)"
    }

    /// Lines the app wrote while the rail was folded come first: a failed save is worth more than a
    /// count of suggestions. Then the suggestions, then the length of the log.
    private var railBadge: String {
        if app.unseenSessionNotes > 0 { return "\(app.unseenSessionNotes)" }
        let waiting = app.proposals.count
        return waiting > 0 ? "\(waiting)" : (app.log.isEmpty ? "" : "\(app.log.count)")
    }

    private var ledgerBadge: String {
        let count = app.versions.count
        return count == 0 ? "" : "\(count)"
    }
}
