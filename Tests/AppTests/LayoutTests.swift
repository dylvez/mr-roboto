import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// The frame's geometry, in numbers.
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

    @Test("At the default window the open surface gets 973 of 1440 points — 68%, not 42% — with the band open")
    func defaultWindow() {
        let collapsed = FrameLayout.defaultCollapsedRegions
        let width = FrameLayout.defaultWindowWidth

        // The band open (340), the library and the parts as strips (44 each), three hairlines.
        #expect(FrameLayout.fixedWidth(collapsed: collapsed) == 431)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: width, collapsed: collapsed) == 1009)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: width, collapsed: collapsed) == 973)

        let share = FrameLayout.surfaceShare(inWindowOfWidth: width, collapsed: collapsed)
        #expect(share > FrameLayout.minimumSurfaceShare)
        #expect(abs(share - 0.6757) < 0.001)

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

        // Three hairlines between four columns are part of the arithmetic, not rounding.
        #expect(FrameLayout.fixedWidth(collapsed: none) == Before.fixedWidth - Before.railSlimmedBy + 3)
        #expect(FrameLayout.fixedWidth(collapsed: all) == CGFloat(3 * 44 + 3))

        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1440, collapsed: all) == 1305)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1440, collapsed: all) == 1269)

        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: none) == 935)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: none) == 899)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: FrameLayout.defaultCollapsedRegions) == 1297)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: FrameLayout.defaultCollapsedRegions) == 1261)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1728, collapsed: all) == 1593)
        #expect(FrameLayout.surfaceWidth(inWindowOfWidth: 1728, collapsed: all) == 1557)

        // All three open in a 1440 window is a layout that does not fit: 793 of furniture leaves 647,
        // which is less than a surface and its padding need. The bench holds its floor and the window
        // minimum — the thing that actually stops you getting here — is 1469.
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 1440, collapsed: none) == FrameLayout.benchMinimumWidth)
        #expect(FrameLayout.minimumWindowWidth(collapsed: none) == 1469)
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
        #expect(FrameLayout.benchMinimumWidth == Design.Metric.surfaceMinimumWidth + 2 * Design.Metric.gutter)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 200, collapsed: []) == FrameLayout.benchMinimumWidth)
    }
}

// MARK: - Height

@Suite("Layout: height")
struct LayoutHeightTests {

    @Test("One surface fills the bench: 665 points of height at the default window, not 253")
    func oneSurfaceFills() {
        let height = FrameLayout.defaultWindowHeight
        #expect(FrameLayout.benchHeight(inWindowOfHeight: height) == 758)
        #expect(FrameLayout.benchContentHeight(inWindowOfHeight: height) == 665)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 1) == 665)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 1)
                    > Before.surfaceHeightAt900 * 2.5)
    }

    @Test("A pinned second surface halves the height; Gate B's three still divide it evenly")
    func splitting() {
        let height = FrameLayout.defaultWindowHeight
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 2) == 323.5)
        #expect(FrameLayout.surfaceHeight(inWindowOfHeight: height, visibleSurfaces: 3) == 209.666_666_666_666_66)
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
        // 640 + 36 of bench padding + three 44-point strips + three hairlines.
        #expect(FrameLayout.minimumWindowWidth == 811)
        #expect(FrameLayout.minimumWindowHeight == 695)

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
        #expect(FrameLayout.minimumWindowWidth(collapsed: Set(FrameRegion.allCases)) == 811)
        #expect(FrameLayout.minimumWindowWidth(collapsed: FrameLayout.defaultCollapsedRegions) == 1107)
        #expect(FrameLayout.minimumWindowWidth(collapsed: []) == 1469)

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

    @Test("First launch: the band is open, asking; the library and the parts are strips")
    func firstLaunchDefaults() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }
        let regions = RegionVisibility(defaults: defaults)

        #expect(regions.isCollapsed(.library) == true)
        #expect(regions.isCollapsed(.rail) == false)
        #expect(regions.isCollapsed(.ledger) == true)
        #expect(regions.fixedWidth == CGFloat(44 + 340 + 44))
        #expect(FrameLayout.defaultCollapsedRegions == [.library, .ledger])
    }

    @Test("A layout remembered from before the band opened by default is put back to the new defaults once, then kept")
    func newDefaultsAppliedOnce() {
        let (defaults, cleanUp) = scratch()
        defer { cleanUp() }
        // The old defaults, remembered, and no layout version: an install from before.
        defaults.set(false, forKey: FrameRegion.library.defaultsKey)
        defaults.set(true, forKey: FrameRegion.rail.defaultsKey)
        defaults.set(false, forKey: FrameRegion.ledger.defaultsKey)
        let upgraded = RegionVisibility(defaults: defaults)
        #expect(upgraded.collapsed == [.library, .ledger])

        // What you fold after that is yours.
        upgraded.setCollapsed(false, for: .ledger)
        #expect(RegionVisibility(defaults: defaults).collapsed == [.library])
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
        first.setCollapsed(true, for: .library)
        first.setCollapsed(true, for: .ledger)
        first.setCollapsed(false, for: .rail)

        // A second object over the same preferences is what the next launch sees.
        let next = RegionVisibility(defaults: defaults)
        #expect(next.isCollapsed(.library) == true)
        #expect(next.isCollapsed(.ledger) == true)
        #expect(next.isCollapsed(.rail) == false)
        #expect(next.collapsed == [.library, .ledger])
        #expect(next.fixedWidth == CGFloat(44 + 340 + 44))
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
        let second = app.openSurface(.sound, title: "two")

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
        let second = app.openSurface(.sound, title: "two")
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
        let sound = app.openSurface(.sound, title: "two")
        let opened = app.log.count

        app.showSurface(.grid)

        #expect(app.bench.items.count == 2)
        #expect(app.bench.activeID == grid)
        #expect(app.bench.visible.map(\.id) == [grid])
        #expect(app.log.count == opened, "bringing a surface forward is not an event")

        app.showSurface(.sound)
        #expect(app.bench.activeID == sound)
    }

    @Test("One of each kind: a second bar opens in the Chop lane that is open, and its chip finds it")
    func oneOfEachKind() {
        let app = state()
        let first = app.openSurface(.chopLane, title: "bar 5")
        let sound = app.openSurface(.sound, title: "kit")
        let second = app.openSurface(.chopLane, title: "bar 9")
        #expect(second == first && app.bench.activeID == first)
        #expect(app.bench.items.count == 2)
        #expect(app.bench.items.first { $0.id == first }?.title == "bar 9")

        app.showSurface(.sound)
        #expect(app.bench.activeID == sound)
        app.showSurface(.chopLane)
        #expect(app.bench.activeID == first)
    }

    @Test("Closing what you are working in falls back to what is still open")
    func closingFallsBack() {
        let app = state()
        let first = app.openSurface(.grid, title: "one")
        let second = app.openSurface(.sound, title: "two")

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
