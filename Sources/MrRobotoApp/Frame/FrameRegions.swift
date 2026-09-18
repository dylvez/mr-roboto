import Observation
import SwiftUI

/// The three regions that flank the bench, and whether each one is currently open.
///
/// They were fixed because the mockups that drew them were drawn for Gate B, where an AI Director
/// fills the rail and opens panels beside your work. In Gate A the rail is inert, the library is how
/// you open a song and then stops being interesting, and only the parts ledger is wanted while you
/// work. Paying 830 points for all three, always, left the instrument with 42% of the window.
///
/// So each one collapses to a strip. Collapsing never hides information outright: a collapsed region
/// keeps its name and its count on the strip, and the strip is the control that brings it back.
public enum FrameRegion: String, CaseIterable, Sendable, Identifiable {
    case library
    case rail
    case ledger

    public var id: String { rawValue }

    /// What the strip and the View menu call it.
    public var title: String {
        switch self {
        case .library: return "Library"
        case .rail: return "Band"
        case .ledger: return "Parts"
        }
    }

    /// The width it is drawn at when it is open.
    public var expandedWidth: CGFloat {
        switch self {
        case .library: return Design.Metric.librarySidebarWidth
        case .rail: return Design.Metric.conversationRailWidth
        case .ledger: return Design.Metric.partsLedgerWidth
        }
    }

    /// ⌥⌘1/2/3, left to right as the regions sit on screen. ⌘1–4 are the surfaces and ⌃⌘1–3 the
    /// themes; these are pressed about as often as the themes are.
    public var shortcut: Character {
        switch self {
        case .library: return "1"
        case .rail: return "2"
        case .ledger: return "3"
        }
    }

    /// Where the choice is remembered between launches.
    public var defaultsKey: String { "frame.region.\(rawValue).collapsed" }

    /// What a first launch opens with, and the reasoning is the same in all three cases: does this
    /// region earn its width while you are working?
    ///
    /// - The **library** does, at the start: with nothing open it is the only way in, and its rows
    ///   are what a first launch is for. It is one keystroke from gone once a song is open.
    /// - The **rail** does not. In Gate A it is a session log and an inert composer; the one part of
    ///   it that is worth interrupting you — the next step — follows you into the bench dock when it
    ///   is collapsed, so nothing is lost by starting it closed.
    /// - The **ledger** does: it is the song's parts, each row a verb, and it is how you move between
    ///   them while the work is happening.
    public var isCollapsedByDefault: Bool {
        switch self {
        case .library: return false
        case .rail: return true
        case .ledger: return false
        }
    }
}

/// Which regions are collapsed, remembered across launches.
///
/// Observable, so collapsing repaints the frame and nothing else; `UserDefaults` is injected so a
/// test can round-trip the persistence without touching the app's own preferences.
@MainActor
@Observable
public final class RegionVisibility {
    public private(set) var collapsed: Set<FrameRegion>

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored: Set<FrameRegion> = []
        for region in FrameRegion.allCases {
            let value = defaults.object(forKey: region.defaultsKey) as? Bool ?? region.isCollapsedByDefault
            if value { restored.insert(region) }
        }
        collapsed = restored
    }

    public func isCollapsed(_ region: FrameRegion) -> Bool { collapsed.contains(region) }

    public func setCollapsed(_ isCollapsed: Bool, for region: FrameRegion) {
        if isCollapsed { collapsed.insert(region) } else { collapsed.remove(region) }
        defaults.set(isCollapsed, forKey: region.defaultsKey)
    }

    public func toggle(_ region: FrameRegion) {
        setCollapsed(!isCollapsed(region), for: region)
    }

    /// The width this region occupies right now — its own width, or a strip.
    public func width(of region: FrameRegion) -> CGFloat {
        isCollapsed(region) ? Design.Metric.collapsedRegionWidth : region.expandedWidth
    }

    /// Everything that is not the bench, at the moment.
    public var fixedWidth: CGFloat {
        FrameRegion.allCases.reduce(0) { $0 + width(of: $1) }
    }
}

// MARK: - Views

/// A collapsed region: its name down the strip, its count, and the control that brings it back.
///
/// The whole strip is the button, so there is no aiming at a four-point chevron, and the name is
/// still readable — a collapsed region says what it is rather than becoming an anonymous margin.
struct CollapsedStrip: View {
    let region: FrameRegion
    /// The one number the region would have shown: songs in the library, lines in the session,
    /// parts in the ledger. Empty when there is nothing to count.
    var badge: String = ""
    /// Set when the strip is holding something you would want to know about — proposals waiting in a
    /// collapsed rail. Drawn in the accent, which is the frame's one way of saying "here".
    var isAccented: Bool = false
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            VStack(spacing: 10) {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .rotationEffect(.degrees(180))
                if !badge.isEmpty {
                    Text(badge)
                        .font(Design.Typography.numeric(10.5))
                        .foregroundStyle(isAccented ? Design.Palette.accent : Design.Palette.inkSecondary)
                }
                Text(region.title.uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.4)
                    .foregroundStyle(isAccented ? Design.Palette.accent : Design.Palette.inkSecondary)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    // A rotation does not change a view's layout bounds, so the strip reserves the
                    // height the turned label actually occupies rather than its unrotated 12 points.
                    .frame(width: Design.Metric.collapsedRegionWidth, height: 120)
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Design.Palette.panelAlt)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(region.title) (⌥⌘\(region.shortcut))")
    }
}

/// The control in an open region's header that puts it away. Every region has one in the same place.
struct CollapseButton: View {
    let region: FrameRegion
    let app: AppState

    var body: some View {
        ChipButton(systemImage: region == .ledger ? "chevron.right" : "chevron.left",
                   help: "Hide \(region.title) (⌥⌘\(region.shortcut))") {
            app.regions.setCollapsed(true, for: region)
        }
    }
}

/// One flanking region: the strip or the thing itself, at whichever width that is.
///
/// The width is applied here rather than in each region's own body, so there is exactly one place
/// that decides what a region costs and `FrameLayout` can be asserted against it.
struct RegionColumn<Content: View>: View {
    let region: FrameRegion
    let app: AppState
    var badge: String = ""
    var isAccented: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if app.regions.isCollapsed(region) {
                CollapsedStrip(region: region, badge: badge, isAccented: isAccented) {
                    app.regions.setCollapsed(false, for: region)
                }
            } else {
                content()
            }
        }
        .frame(width: app.regions.width(of: region))
    }
}
