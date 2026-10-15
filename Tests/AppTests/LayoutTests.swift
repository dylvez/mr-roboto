import AppKit
import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// The frame's geometry, in numbers — Studio's, the default theme's. Cool Neutral's padded bench and
// taller bars gave 973 × 665 at the default window and a minimum of 811 × 695. A window's height
// here is its content's: Studio's header is the window's own toolbar, which AppKit draws above it.
//
// The complaint these tests exist to keep answered: at the default 1440-point window the bench — the
// only place work happens — was 610 points, 42% of the width, and the three-stacked rule then cut it
// to 253 points of height. A Chop lane draws a waveform with draggable markers, sixteen pads with a
// classification on each, the per-slice controls and the re-groove picker; 610 × 253 is not a cramped
// surface, it is an unusable one.
//
// So every number below is asserted rather than described. A later change that takes the space back
// has to walk past a failing test that says what the number used to be and why.

/// The frame as it was, so the assertions below can say what changed and by how much.
private enum Before {
    /// 220 + 380 + 230, all three fixed.
    static let fixedWidth: CGFloat = 830
    /// The band's column, slimmed from 380 to 340 when it came to open from the first launch.
    static let railSlimmedBy: CGFloat = 40
    /// The bench at the old default window.
    static let benchWidthAt1440: CGFloat = 610
    /// Three surfaces stacked in 760 points of bench.
    static let surfaceHeightAt900: CGFloat = 253
    /// The old window minimum: the furniture plus a 380-point bench.
    static let minimumWindowWidth: CGFloat = 1246
}

// MARK: - Width

@Suite("Layout: width")
struct LayoutWidthTests {

    @Test("At the default window the open surface gets 1054 of 1440 points — 73%, not 42% — with the band open")
    func defaultWindow() {
        let collapsed = FrameLayout.defaultCollapsedRegions
        let width = FrameLayout.defaultWindowWidth

        // The band open (340), the parts as a strip (44), two hairlines. The library had a strip of
        // its own as well, until the Library surface took over all it did.
        #expect(FrameLayout.fixedWidth(collapsed: collapsed) == 386)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: width, collapsed: collapsed) == 1054)
        // Studio draws the surface edge to edge, so the bench's padding is the surface's too.
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: width, collapsed: collapsed) == 1054)

        let share = FrameLayout.surfaceShare(inWindowOfWidth: width, collapsed: collapsed)
        #expect(share > FrameLayout.minimumSurfaceShare)
        #expect(abs(share - 0.7319) < 0.001)

        // The point of the whole exercise, said as a comparison rather than as a constant.
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: width, collapsed: collapsed)
                    > Before.benchWidthAt1440 * 1.4)
    }

    @Test("The share the default layout owes the instrument holds at every window size worth having")
    func shareHoldsEverywhere() {
        let collapsed = FrameLayout.defaultCollapsedRegions
        for width in [FrameLayout.defaultWindowWidth, 1512, 1728, 1920, 2560] as [CGFloat] {
            #expect(FrameLayout.surfaceShare(inWindowOfWidth: width, collapsed: collapsed)
                        > FrameLayout.minimumSurfaceShare,
                    "the instrument fell below its share at \(width)")
        }
        // Below the default window the promise is not a share but a size: the surface keeps the
        // points the tokens say it needs, and the window cannot be dragged narrower than that.
        let floor = FrameLayout.minimumWindowWidth(collapsed: collapsed)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: floor, collapsed: collapsed)
                    == Design.Metric.surfaceMinimumWidth)
    }

    @Test("Every region open, every region away: the two ends of the same window")
    func bothEnds() {
        let none: Set<FrameRegion> = []
        let all = Set(FrameRegion.allCases)

        // Two hairlines between three columns are part of the arithmetic, not rounding. The
        // furniture was 830 with the library's column; the band slimmed by 40, and the library
        // went to the bench.
        #expect(FrameLayout.fixedWidth(collapsed: none) == CGFloat(340 + 230 + 2))
        #expect(FrameLayout.fixedWidth(collapsed: none) < Before.fixedWidth - Before.railSlimmedBy - 200)
        #expect(FrameLayout.fixedWidth(collapsed: all) == CGFloat(2 * 44 + 2))

        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1440, collapsed: all) == 1350)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1440, collapsed: all) == 1350)

        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: none) == 1156)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: none) == 1156)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: FrameLayout.defaultCollapsedRegions) == 1342)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: FrameLayout.defaultCollapsedRegions) == 1342)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: all) == 1638)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: all) == 1638)

        // Both open in a 1440 window: 572 of furniture leaves the bench 868, and the window minimum
        // with both open is 1212. With the library's column it was 647, and 1433.
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1440, collapsed: none) == 868)
        #expect(FrameLayout.minimumWindowWidth(collapsed: none) == 1212)
    }

    @Test("Folding a region hands every one of its points to the bench, and nothing else moves")
    func foldingIsExact() {
        // A window wide enough that nothing is against the bench's floor, so the arithmetic shows.
        for region in FrameRegion.allCases {
            let open = FrameLayout.benchWidth(inWindowOfWidth: 1920, collapsed: [])
            let away = FrameLayout.benchWidth(inWindowOfWidth: 1920, collapsed: [region])
            #expect(away - open == region.expandedWidth - FrameLayout.collapsedRegionWidth,
                    "folding \(region.title) did not hand the bench its width")
        }
    }

    @Test("The bench never goes below what a surface needs, whatever the window does")
    func benchFloor() {
        #expect(FrameLayout.benchMinimumWidth == Design.Metric.surfaceMinimumWidth + 2 * Design.Metric.benchPadding)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 200, collapsed: []) == FrameLayout.benchMinimumWidth)
    }
}

// MARK: - Height

@Suite("Layout: height")
struct LayoutHeightTests {

    @Test("One surface fills the bench: 798 points of height at the default window, not 253")
    func oneSurfaceFills() {
        let height = FrameLayout.defaultWindowHeight
        // Studio draws no header of its own (the toolbar is the header), and its dock (44) and
        // transport (56) are smaller than Cool's 56 and 84.
        #expect(FrameLayout.benchHeight(inWindowOfHeight: height) == 843)
        #expect(FrameLayout.benchContentHeight(inWindowOfHeight: height) == 798)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 1) == 798)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 1)
                    > Before.surfaceHeightAt900 * 2.5)
    }

    @Test("A pinned second surface halves the height; Gate B's three still divide it evenly")
    func splitting() {
        let height = FrameLayout.defaultWindowHeight
        // Two surfaces share a single hairline in Studio rather than an 18-point gutter.
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 2) == 398.5)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 3) == 265.333_333_333_333_3)
        // Nothing is asked for below one: a bench with nothing in it still measures its one slot.
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 0)
                    == FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 1))
    }
}

// MARK: - The window minimum

@Suite("Layout: the window minimum")
struct LayoutMinimumTests {

    @Test("The minimum is what a surface needs, not what the furniture costs")
    func minimumIsTheSurface() {
        // 640, two 44-point strips and two hairlines: in Studio the bench has no padding of its own.
        #expect(FrameLayout.minimumWindowWidth == 730)
        #expect(FrameLayout.minimumWindowHeight == 562)

        // At the floor, a surface is drawn at exactly the size the tokens say it needs.
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: FrameLayout.minimumWindowWidth,
                                         collapsed: Set(FrameRegion.allCases))
                    == Design.Metric.surfaceMinimumWidth)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: FrameLayout.minimumWindowHeight,
                                          visibleSurfaces: 1)
                    == Design.Metric.surfaceMinimumHeight)

        // The old minimum existed only because three fixed regions plus a bench added up to it.
        #expect(FrameLayout.minimumWindowWidth < Before.minimumWindowWidth - 400)
    }

    @Test("Asking for a region back asks the window for its width, rather than crushing the bench")
    func minimumFollowsTheRegions() {
        #expect(FrameLayout.minimumWindowWidth(collapsed: Set(FrameRegion.allCases)) == 730)
        #expect(FrameLayout.minimumWindowWidth(collapsed: FrameLayout.defaultCollapsedRegions) == 1026)
        #expect(FrameLayout.minimumWindowWidth(collapsed: []) == 1212)

        // Whatever is open, the minimum window still draws a full-size surface.
        for collapsed in [Set(FrameRegion.allCases), FrameLayout.defaultCollapsedRegions, []] {
            let minimum = FrameLayout.minimumWindowWidth(collapsed: collapsed)
            #expect(FrameLayout.surfaceWidth(inWindowOfWidth: minimum, collapsed: collapsed)
                        == Design.Metric.surfaceMinimumWidth)
        }
    }

    @Test("The default window is comfortably above the minimum it implies")
    func defaultClearsIt() {
        #expect(FrameLayout.defaultWindowWidth
                    > FrameLayout.minimumWindowWidth(collapsed: FrameLayout.defaultCollapsedRegions))
        #expect(FrameLayout.defaultWindowHeight > FrameLayout.minimumWindowHeight)
    }
}

// MARK: - Collapsing

@Suite("Layout: collapsing the regions") @MainActor
struct LayoutRegionTests {

    /// A scratch preferences domain, so a test never writes the app's own.
    private func scratch(_ label: String = #function) -> (UserDefaults, () -> Void) {
        let name = "MrRobotoLayoutTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { UserDefaults.standard.removePersistentDomain(forName: name) })
    }

    @Test("First launch: the band is open, asking; the parts are a strip")
    func firstLaunchDefaults() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }
        let regions = RegionVisibility(defaults: defaults)

        #expect(regions.isCollapsed(.rail) == false)
        #expect(regions.isCollapsed(.ledger) == true)
        #expect(regions.fixedWidth == CGFloat(340 + 44))
        #expect(FrameLayout.defaultCollapsedRegions == [.ledger])
        // The library is a surface, not a region: there is no column for it to fold.
        #expect(FrameRegion.allCases == [.rail, .ledger])
    }

    @Test("A layout remembered from before the band opened by default is put back to the new defaults once, then kept")
    func newDefaultsAppliedOnce() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }
        // The old defaults, remembered, and no layout version: an install from before. The
        // library's own key is left over from when it had a column, and is ignored.
        defaults.set(false, forKey: "frame.region.library.collapsed")
        defaults.set(true, forKey: FrameRegion.rail.defaultsKey)
        defaults.set(false, forKey: FrameRegion.ledger.defaultsKey)
        let upgraded = RegionVisibility(defaults: defaults)
        #expect(upgraded.collapsed == [.ledger])

        // What you fold after that is yours.
        upgraded.setCollapsed(false, for: .ledger)
        #expect(RegionVisibility(defaults: defaults).collapsed == [])
    }

    @Test("Collapse and expand round-trip, and every region can be put away")
    func roundTrip() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }
        let regions = RegionVisibility(defaults: defaults)

        for region in FrameRegion.allCases {
            let before = regions.isCollapsed(region)
            regions.toggle(region)
            #expect(regions.isCollapsed(region) == !before)
            #expect(regions.width(of: region)
                        == (regions.isCollapsed(region) ? FrameLayout.collapsedRegionWidth : region.expandedWidth))
            regions.toggle(region)
            #expect(regions.isCollapsed(region) == before)
            #expect(regions.width(of: region) == (before ? FrameLayout.collapsedRegionWidth : region.expandedWidth))
        }
    }

    @Test("What you collapsed is still collapsed next launch")
    func persists() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }

        let first = RegionVisibility(defaults: defaults)
        first.setCollapsed(true, for: .ledger)
        first.setCollapsed(false, for: .rail)

        // A second object over the same preferences is what the next launch sees.
        let next = RegionVisibility(defaults: defaults)
        #expect(next.isCollapsed(.ledger) == true)
        #expect(next.isCollapsed(.rail) == false)
        #expect(next.collapsed == [.ledger])
        #expect(next.fixedWidth == CGFloat(340 + 44))
    }

    @Test("Each region has its own shortcut and its own preferences key")
    func shortcutsAreDistinct() {
        #expect(Set(FrameRegion.allCases.map(\.shortcut)).count == FrameRegion.allCases.count)
        #expect(Set(FrameRegion.allCases.map(\.defaultsKey)).count == FrameRegion.allCases.count)
        #expect(FrameRegion.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

// MARK: - One surface at a time

@Suite("Layout: one surface fills the bench") @MainActor
struct LayoutBenchTests {

    private func state() -> AppState {
        AppState(library: Library(), song: FrameFixture.song(), transportHost: StubTransportHost(),
                 regions: RegionVisibility(defaults: UserDefaults(suiteName: "MrRobotoLayoutBench.\(UUID())")!))
    }

    @Test("Two surfaces open, one drawn: the bench is not divided by surfaces you are not using")
    func oneFills() {
        let app = state()
        let first = app.openSurface(.grid, title: "one")
        let second = app.openSurface(.chords, title: "two")

        #expect(app.bench.items.count == 2)
        #expect(app.bench.activeID == second)
        #expect(app.bench.visible.map(\.id) == [second])
        #expect(app.bound(for: first).isEmpty == true)  // still open, still bound, simply not drawn
        #expect(app.bench.items.contains { $0.id == first })
    }

    @Test("Pinning a second surface splits the bench; unpinning restores the fill")
    func pinningSplits() {
        let app = state()
        let first = app.openSurface(.grid, title: "one")
        app.setPinned(true, for: first)
        let second = app.openSurface(.chopLane, title: "two")

        #expect(app.bench.visible.map(\.id) == [first, second])
        #expect(app.bench.visible.count == Design.maximumVisibleSurfaces)

        app.setPinned(false, for: first)
        #expect(app.bench.visible.map(\.id) == [second])

        // And pinning the one you are in changes nothing about what is drawn.
        app.setPinned(true, for: second)
        #expect(app.bench.visible.map(\.id) == [second])
    }

    @Test("Three pins and the surface you are in: what you are working in keeps its place")
    func pinsNeverEvictTheActive() {
        let app = state()
        let first = app.openSurface(.grid, title: "one")
        let second = app.openSurface(.chords, title: "two")
        app.setPinned(true, for: first)
        app.setPinned(true, for: second)
        let third = app.openSurface(.chopLane, title: "three")

        #expect(app.bench.items.count == 3)
        #expect(app.bench.visible.count == Design.maximumVisibleSurfaces)
        #expect(app.bench.visible.last?.id == third)
        #expect(app.bench.visible.contains { $0.id == second })
    }

    @Test("The dock brings an open surface forward rather than opening a second one")
    func dockSwitches() {
        let app = state()
        let grid = app.openSurface(.grid, title: "one")
        let chords = app.openSurface(.chords, title: "two")
        let opened = app.log.count

        app.showSurface(.grid)

        #expect(app.bench.items.count == 2)
        #expect(app.bench.activeID == grid)
        #expect(app.bench.visible.map(\.id) == [grid])
        #expect(app.log.count == opened, "bringing a surface forward is not an event")

        app.showSurface(.chords)
        #expect(app.bench.activeID == chords)
    }

    @Test("One of each kind: a second bar opens in the Chop lane that is open, and its chip finds it")
    func oneOfEachKind() {
        let app = state()
        let first = app.openSurface(.chopLane, title: "bar 5")
        let chords = app.openSurface(.chords, title: "chords")
        let second = app.openSurface(.chopLane, title: "bar 9")
        #expect(second == first && app.bench.activeID == first)
        #expect(app.bench.items.count == 2)
        #expect(app.bench.items.first { $0.id == first }?.title == "bar 9")

        app.showSurface(.chords)
        #expect(app.bench.activeID == chords)
        app.showSurface(.chopLane)
        #expect(app.bench.activeID == first)
    }

    @Test("Closing what you are working in falls back to what is still open")
    func closingFallsBack() {
        let app = state()
        let first = app.openSurface(.grid, title: "one")
        let second = app.openSurface(.chords, title: "two")

        app.closeSurface(second)
        #expect(app.bench.activeID == first)
        #expect(app.bench.visible.map(\.id) == [first])

        app.closeSurface(first)
        #expect(app.bench.activeID == nil)
        #expect(app.bench.visible.isEmpty)
    }

    @Test("A surface that learns its title later does not steal the bench")
    func retitleDoesNotFocus() {
        let app = state()
        let first = app.openSurface(.chopLane, title: "loading")
        let second = app.openSurface(.grid, title: "two")

        app.retitleSurface(first, to: "Bar 5 of Arrival")

        #expect(app.bench.activeID == second)
        #expect(app.bench.items.first { $0.id == first }?.title == "Bar 5 of Arrival")
    }

    @Test("Two at once is pinning's, and only pinning's")
    func twoAtOnce() {
        #expect(Design.maximumVisibleSurfaces == 2)
    }
}

// MARK: - Proposals with the rail collapsed

@Suite("Layout: the next step survives a collapsed rail") @MainActor
struct LayoutProposalTests {

    private func app(_ song: Song, in directory: URL, railCollapsed: Bool) -> AppState {
        let defaults = UserDefaults(suiteName: "MrRobotoLayoutProposals.\(UUID())")!
        let regions = RegionVisibility(defaults: defaults)
        regions.setCollapsed(railCollapsed, for: .rail)
        let state = AppState(library: Library(), song: nil,
                             store: LibraryStore(directoryURL: directory),
                             status: .empty(directory), transportHost: StubTransportHost(),
                             regions: regions)
        state.open(song)
        return state
    }

    @Test("With the rail folded away the leading proposal moves into the bench dock, and works")
    func proposalsReachable() throws {
        let directory = GuidanceFixture.temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = GuidanceFixture.separated()
        let app = self.app(built.song, in: directory, railCollapsed: true)

        let leading = try #require(app.proposals.first)
        #expect(leading.title == "Chop a bar of the drums")

        let inTheDock = try #require(app.dockProposal)
        #expect(inTheDock.id == leading.id)

        // Reachable means it works when pressed, not that it is listed.
        let surface = app.perform(inTheDock.action)
        #expect(surface != nil)
        #expect(app.bench.active?.kind == .chopLane)
        #expect(app.bench.visible.map(\.id) == [surface])
    }

    @Test("With the rail open the dock stays a shelf: the rail is showing them")
    func notDuplicated() {
        let directory = GuidanceFixture.temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = self.app(GuidanceFixture.separated().song, in: directory, railCollapsed: false)

        #expect(app.proposals.isEmpty == false)
        #expect(app.dockProposal == nil)
    }

    @Test("Nothing to propose, nothing in the dock — a collapsed rail never invents a step")
    func honestWhenEmpty() {
        let directory = GuidanceFixture.temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = self.app(GuidanceFixture.emptySong(), in: directory, railCollapsed: true)

        #expect(app.proposals.isEmpty)
        #expect(app.dockProposal == nil)
    }

    @Test("A collapsed region still says what it is holding")
    func stripsCarryTheirCount() {
        let directory = GuidanceFixture.temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = self.app(GuidanceFixture.separated().song, in: directory, railCollapsed: true)

        // What the three strips put on screen: a count worth the 44 points it costs.
        #expect(app.versions.count > 0)
        #expect(app.log.isEmpty == false)
        #expect(app.proposals.count > 0)
    }
}

// MARK: - Every column fits between the header and the transport

@Suite("Layout: the columns fit the window's minimum") @MainActor
struct LayoutColumnFitTests {

    /// How tall a column draws when offered `height`: more than it was offered is a column that
    /// pushes the frame past the window, and the window crops the header and the transport.
    private func drawn<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        return try #require(renderer.nsImage).size.height
    }

    @Test("At the minimum height with every region open, each column takes the height it is given and no more")
    func columnsFit() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = GuidanceFixture.temporaryDirectory("layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = GuidanceFixture.separated().song
        // Each column is drawn on its own, so whether a region is folded away does not enter into
        // it, and nothing here writes a preference.
        let app = AppState(library: Library(songs: [song]), song: nil, store: LibraryStore(directoryURL: directory),
                           status: .loaded(directory), transportHost: StubTransportHost())
        app.open(song)

        let column = FrameLayout.benchHeight(inWindowOfHeight: FrameLayout.minimumWindowHeight)
        // The band's question card was a fixed 410 points, its default dragged height: with the
        // column's header, the conversation and the composer the rail drew 678 points in 553, and
        // the window cut the header and the transport off. The card now gives way first.
        #expect(try drawn(ConversationRail(app: app), width: FrameLayout.conversationRailWidth, height: column) == column)
        #expect(try drawn(PartsLedger(app: app), width: FrameLayout.partsLedgerWidth, height: column) == column)
        #expect(try drawn(BenchColumn(app: app, registry: .shared), width: FrameLayout.benchMinimumWidth, height: column) == column)
        app.perform(SurfaceAction(surface: .library, title: "Library"))
        #expect(try drawn(BenchColumn(app: app, registry: .shared), width: FrameLayout.benchMinimumWidth, height: column) == column)
    }
}
