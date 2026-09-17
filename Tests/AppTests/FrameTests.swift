import AppKit
import AudioEngine
import Foundation
import MusicTheory
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

/// The frame is SwiftUI, which is not worth asserting on directly. What is worth asserting is
/// everything the views read: the bench's rule, `AppState`'s transitions, the registry's fallback,
/// and the fixed geometry the window minimum depends on. The view bodies are thin enough that if
/// these hold, the frame holds.

// MARK: - Fixtures

@MainActor
enum FrameFixture {
    static func song(title: String = "Arrival") -> Song {
        var song = Song(title: title, artist: "Vessel", key: Key(parsing: "D major"), tempo: 113,
                        sections: [Section(name: "Intro", stitch: [], lengthInBars: 4),
                                   Section(name: "Verse", stitch: [], lengthInBars: 16)])
        try? song.append(melody())
        return song
    }

    static func melody(partID: PartID = PartID()) -> PartVersion {
        PartVersion(partID: partID, kind: .melody(Melody(notes: [])), author: .user, operation: Operation.hummed,
                    note: "8 bars")
    }

    static func state(song: Song? = nil, library: Library = Library()) -> AppState {
        AppState(library: library, song: song, transportHost: StubTransportHost())
    }
}

/// Audio that never touches an audio device: this shell has none, and neither does CI.
@MainActor
final class StubTransportHost: TransportHost {
    var started: [TransportClock] = []
    var stopped = 0
    var failure: Error?

    func engine() async throws -> Engine {
        if let failure { throw failure }
        throw EngineError.notRunning
    }

    func start(clock: TransportClock) async throws {
        if let failure { throw failure }
        started.append(clock)
    }

    func stop() async { stopped += 1 }
}

struct NoAudioDevice: Error, CustomStringConvertible {
    var description: String { "no audio device" }
}

// MARK: - Bench

@Suite("Bench") @MainActor
struct BenchTests {
    private func item(_ title: String, kind: SurfaceKind = .grid, pinned: Bool = false,
                      openedAt: Date = Date()) -> BenchItem {
        BenchItem(id: SurfaceID(), kind: kind, title: title, isPinned: pinned, openedAt: openedAt)
    }

    @Test("Holds at most three surfaces")
    func capacity() {
        let bench = Bench()
        for index in 0..<5 {
            bench.open(item("s\(index)", openedAt: Date(timeIntervalSinceReferenceDate: Double(index))))
        }
        #expect(bench.items.count == Design.maximumOpenSurfaces)
    }

    @Test("Opening into a full bench retires the oldest unpinned surface")
    func retiresOldestUnpinned() {
        let bench = Bench()
        let oldest = item("oldest", openedAt: Date(timeIntervalSinceReferenceDate: 0))
        let middle = item("middle", openedAt: Date(timeIntervalSinceReferenceDate: 1))
        let newest = item("newest", openedAt: Date(timeIntervalSinceReferenceDate: 2))
        for one in [oldest, middle, newest] { bench.open(one) }

        let retired = bench.open(item("fourth", openedAt: Date(timeIntervalSinceReferenceDate: 3)))

        #expect(retired?.id == oldest.id)
        #expect(bench.items.map(\.title) == ["middle", "newest", "fourth"])
    }

    @Test("A pinned surface is not retired while an unpinned one is available")
    func pinnedSurvives() {
        let bench = Bench()
        let pinned = item("pinned", pinned: true, openedAt: Date(timeIntervalSinceReferenceDate: 0))
        let unpinned = item("unpinned", openedAt: Date(timeIntervalSinceReferenceDate: 1))
        let third = item("third", openedAt: Date(timeIntervalSinceReferenceDate: 2))
        for one in [pinned, unpinned, third] { bench.open(one) }

        let retired = bench.open(item("fourth", openedAt: Date(timeIntervalSinceReferenceDate: 3)))

        #expect(retired?.id == unpinned.id)
        #expect(bench.items.contains { $0.id == pinned.id })
    }

    @Test("With everything pinned the bench still answers, retiring the oldest pin")
    func allPinned() {
        let bench = Bench()
        let first = item("first", pinned: true, openedAt: Date(timeIntervalSinceReferenceDate: 0))
        let second = item("second", pinned: true, openedAt: Date(timeIntervalSinceReferenceDate: 1))
        let third = item("third", pinned: true, openedAt: Date(timeIntervalSinceReferenceDate: 2))
        for one in [first, second, third] { bench.open(one) }

        let retired = bench.open(item("fourth", openedAt: Date(timeIntervalSinceReferenceDate: 3)))

        // Refusing to answer would be worse than dropping a pin; the oldest one gives way.
        #expect(retired?.id == first.id)
        #expect(bench.items.count == Design.maximumOpenSurfaces)
        #expect(bench.items.map(\.title) == ["second", "third", "fourth"])
    }

    @Test("Reopening the same surface id replaces it in place and retires nothing")
    func reopenInPlace() {
        let bench = Bench()
        let one = item("one")
        bench.open(one)
        let retired = bench.open(BenchItem(id: one.id, kind: .sound, title: "one, again"))

        #expect(retired == nil)
        #expect(bench.items.count == 1)
        #expect(bench.items[0].title == "one, again")
    }

    @Test("Close and pin address a surface by id")
    func closeAndPin() {
        let bench = Bench()
        let one = item("one")
        let two = item("two")
        bench.open(one)
        bench.open(two)

        bench.setPinned(true, for: two.id)
        #expect(bench.items.first { $0.id == two.id }?.isPinned == true)

        bench.close(one.id)
        #expect(bench.items.map(\.id) == [two.id])

        bench.close(one.id)  // closing something already gone is a no-op, not a crash
        #expect(bench.items.count == 1)
    }
}

// MARK: - AppState

@Suite("AppState") @MainActor
struct AppStateTests {
    @Test("A fresh state has no song, no selection and an empty rail")
    func empty() {
        let app = FrameFixture.state()
        #expect(app.song == nil)
        #expect(app.selectedVersion == nil)
        #expect(app.log.isEmpty)
        #expect(app.bench.items.isEmpty)
        #expect(app.transport == .stopped)
        #expect(app.libraryStatus == .unset)
    }

    @Test("Opening a song selects its newest version, lights its first section and logs it")
    func openSong() {
        let song = FrameFixture.song()
        var library = Library()
        library.upsert(song)
        let app = FrameFixture.state(library: library)

        app.openSong(song.id)

        #expect(app.song?.id == song.id)
        #expect(app.selectedVersion == song.versions.last?.id)
        #expect(app.activeSection == song.sections.first?.id)
        #expect(app.log.last?.text == "Opened Arrival")
        #expect(app.hasUnsavedChanges == false)
    }

    @Test("Opening a song the library does not hold changes nothing and says so")
    func openMissingSong() {
        let app = FrameFixture.state()
        app.openSong(SongID())

        #expect(app.song == nil)
        #expect(app.log.last?.source == .session)
    }

    @Test("Opening a song clears the bench, since surfaces are bound to the old song")
    func openSongClearsBench() {
        let app = FrameFixture.state(song: FrameFixture.song())
        let surface = app.openSurface(.grid, title: "Bar 9", bound: [app.selectedVersion!])
        #expect(app.bound(for: surface).count == 1)

        app.open(FrameFixture.song(title: "Second"))

        #expect(app.bench.items.isEmpty)
        #expect(app.bound(for: surface).isEmpty)
    }

    @Test("Selecting a version accents it and logs it once")
    func select() {
        let song = FrameFixture.song()
        let app = FrameFixture.state(song: song)
        let version = song.versions[0]

        app.select(nil)
        let before = app.log.count
        app.select(version.id)
        app.select(version.id)  // selecting what is already selected is not an event

        #expect(app.selectedVersion == version.id)
        #expect(app.log.count == before + 1)
    }

    @Test("Recording appends a version, selects it, marks the song dirty and logs provenance")
    func record() {
        let song = FrameFixture.song()
        let app = FrameFixture.state(song: song)
        let parent = song.versions[0]
        let derived = parent.deriving(.melody(Melody(notes: [])), by: .persona("Bassist"),
                                      operation: Operation.harmonize)

        #expect(app.record(derived))

        #expect(app.song?.versions.count == 2)
        #expect(app.selectedVersion == derived.id)
        #expect(app.hasUnsavedChanges)
        #expect(app.versionNumber(of: derived.id) == 2)
        #expect(app.provenanceLine(for: derived).contains("harmonize"))
        #expect(app.provenanceLine(for: derived).contains("Bassist"))
        #expect(app.provenanceLine(for: derived).contains("from v1"))
    }

    @Test("Recording the same version twice is refused, not appended")
    func recordDuplicate() {
        let song = FrameFixture.song()
        let app = FrameFixture.state(song: song)
        let again = song.versions[0]

        #expect(app.record(again) == false)
        #expect(app.song?.versions.count == 1)
        #expect(app.log.last?.source == .session)
    }

    @Test("Recording with no song open fails honestly")
    func recordWithoutSong() {
        let app = FrameFixture.state()
        #expect(app.record(FrameFixture.melody()) == false)
        #expect(app.log.last?.source == .session)
    }

    @Test("Opening a surface stores its bindings and logs; closing forgets them")
    func surfaces() {
        let song = FrameFixture.song()
        let app = FrameFixture.state(song: song)
        let version = song.versions[0].id

        let id = app.openSurface(.chopLane, title: "Bar 9", bound: [version])

        #expect(app.bench.items.count == 1)
        #expect(app.bound(for: id) == [version])
        #expect(app.log.last?.text == "Opened Chop lane")

        app.setPinned(true, for: id)
        #expect(app.bench.items[0].isPinned)

        app.closeSurface(id)
        #expect(app.bench.items.isEmpty)
        #expect(app.bound(for: id).isEmpty)
    }

    @Test("A surface retired to make room is reported in the rail")
    func retirementIsLogged() {
        let app = FrameFixture.state(song: FrameFixture.song())
        for index in 0..<Design.maximumOpenSurfaces {
            app.openSurface(.grid, title: "surface \(index)")
        }
        app.openSurface(.sound, title: "one more")

        #expect(app.bench.items.count == Design.maximumOpenSurfaces)
        #expect(app.log.contains { $0.source == .session && $0.text.hasPrefix("Closed Grid") })
    }

    @Test("Notes land in the rail in order, attributed")
    func rail() {
        let app = FrameFixture.state()
        app.note("Kept the C♯", detail: "bar 2")
        app.note(.session, "Library is empty")

        #expect(app.log.map(\.source) == [.you, .session])
        #expect(app.log[0].detail == "bar 2")
    }

    @Test("The clock follows the open song, and 120 4/4 with nothing open")
    func clock() {
        #expect(FrameFixture.state().clock.tempo == 120)
        let app = FrameFixture.state(song: FrameFixture.song())
        #expect(app.clock.tempo == 113)
        #expect(app.clock.timeSignature == .fourFour)
    }

    @Test("Play and stop move the transport and reach the host")
    func transport() async {
        let host = StubTransportHost()
        let app = AppState(song: FrameFixture.song(), transportHost: host)

        await app.toggleTransport()
        #expect(app.transport == .playing)
        #expect(host.started.count == 1)
        #expect(host.started[0].tempo == 113)

        await app.toggleTransport()
        #expect(app.transport == .stopped)
        #expect(host.stopped == 1)
    }

    @Test("A machine with no audio device lands in unavailable, not in playing")
    func transportFailure() async {
        let host = StubTransportHost()
        host.failure = NoAudioDevice()
        let app = AppState(song: FrameFixture.song(), transportHost: host)

        await app.startTransport()

        #expect(app.transport == .unavailable("no audio device"))
        #expect(app.log.last?.source == .session)
        #expect(app.transport.isPlaying == false)
    }

    @Test("Loop is a frame flag and is logged")
    func loop() {
        let app = FrameFixture.state()
        #expect(app.isLooping == false)
        app.toggleLoop()
        #expect(app.isLooping)
        #expect(app.log.last?.text == "Loop on")
    }

    @Test("Setting the active section only reports a real change")
    func sections() {
        let song = FrameFixture.song()
        let app = FrameFixture.state(song: song)
        let before = app.log.count

        app.setActiveSection(song.sections[1].id)
        app.setActiveSection(song.sections[1].id)

        #expect(app.activeSection == song.sections[1].id)
        #expect(app.log.count == before + 1)
        #expect(app.log.last?.text == "Moved to Verse")
    }

    @Test("Save with no store open says so rather than failing silently")
    func saveWithoutStore() {
        let app = FrameFixture.state(song: FrameFixture.song())
        app.save()
        #expect(app.log.last?.source == .session)
    }

    @Test("Save writes the song into the library directory and the library reads back")
    func saveAndReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MrRobotoAppTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LibraryStore(directoryURL: directory)
        let app = AppState(song: FrameFixture.song(), store: store, transportHost: StubTransportHost())

        app.save()

        #expect(app.hasUnsavedChanges == false)
        #expect(store.exists)

        let reopened = AppState(store: store, transportHost: StubTransportHost())
        reopened.reloadLibrary()

        #expect(reopened.library.songs.map(\.title) == ["Arrival"])
        #expect(reopened.libraryStatus == .loaded(store.directoryURL))
    }

    @Test("An empty directory is an empty library, not a failure")
    func emptyLibraryDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MrRobotoAppTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LibraryStore(directoryURL: directory)
        let app = AppState(store: store, transportHost: StubTransportHost())
        app.reloadLibrary()

        #expect(app.libraryStatus == .empty(store.directoryURL))
        #expect(app.library.isEmpty)
        #expect(app.library.songs.isEmpty)
    }
}

// MARK: - Surface registry

@Suite("Surface registry") @MainActor
struct SurfaceRegistryTests {
    private func item(_ kind: SurfaceKind) -> BenchItem {
        BenchItem(id: SurfaceID(), kind: kind, title: "test")
    }

    @Test("A kind with no registered builder resolves to the placeholder instead of crashing")
    func unregisteredKindIsPlaceholder() {
        let registry = SurfaceRegistry()
        let app = FrameFixture.state()

        for kind in SurfaceKind.allCases {
            #expect(registry.hasBuilder(for: kind) == false)
            #expect(registry.resolve(item(kind), app: app).isPlaceholder)
        }
        #expect(registry.registeredKinds.isEmpty)
    }

    @Test("Registering is one call, and the registered kind resolves to its view")
    func registration() {
        let registry = SurfaceRegistry()
        let app = FrameFixture.state()
        registry.register(.grid) { item, _ in Text(item.title) }

        #expect(registry.hasBuilder(for: .grid))
        #expect(registry.resolve(item(.grid), app: app).isPlaceholder == false)
        #expect(registry.registeredKinds == [.grid])
        // Every other kind still falls back.
        #expect(registry.resolve(item(.sound), app: app).isPlaceholder)
    }

    @Test("Last registration for a kind wins, and unregistering restores the placeholder")
    func reregistration() {
        let registry = SurfaceRegistry()
        let app = FrameFixture.state()
        registry.register(.sound) { _, _ in Text("first") }
        registry.register(.sound) { _, _ in Text("second") }
        #expect(registry.hasBuilder(for: .sound))

        registry.unregister(.sound)
        #expect(registry.resolve(item(.sound), app: app).isPlaceholder)
    }
}

// MARK: - Layout

@Suite("Frame layout")
struct FrameLayoutTests {
    @Test("The fixed regions are the approved widths, from the design metrics")
    func fixedWidths() {
        #expect(FrameLayout.librarySidebarWidth == 220)
        #expect(FrameLayout.conversationRailWidth == 380)
        #expect(FrameLayout.partsLedgerWidth == 230)
        #expect(FrameLayout.headerHeight == 56)
        #expect(FrameLayout.transportHeight == 84)
        #expect(FrameLayout.fixedWidth == 830)
    }

    @Test("The window minimum leaves the bench at least its minimum width")
    func windowMinimum() {
        #expect(FrameLayout.benchWidth(inWindowOfWidth: FrameLayout.minimumWindowWidth) == FrameLayout.benchMinimumWidth)
        #expect(FrameLayout.minimumWindowWidth > FrameLayout.fixedWidth + FrameLayout.benchMinimumWidth)
        #expect(FrameLayout.minimumWindowHeight > FrameLayout.headerHeight + FrameLayout.transportHeight)
    }

    @Test("The bench takes every point the fixed regions do not, and never goes below its minimum")
    func benchIsTheElasticOne() {
        let wide = FrameLayout.benchWidth(inWindowOfWidth: 1920)
        #expect(wide == 1920 - FrameLayout.fixedWidth - 2 * Design.Metric.gutter)
        #expect(FrameLayout.benchWidth(inWindowOfWidth: 200) == FrameLayout.benchMinimumWidth)
    }

    @Test("Section blocks are proportional to bars, floored and capped so the strip stays usable")
    func sectionBlocks() {
        #expect(TransportBar.blockWidth(bars: 16) == 80)
        #expect(TransportBar.blockWidth(bars: 1) == 24)
        #expect(TransportBar.blockWidth(bars: 64) == 120)
        #expect(TransportBar.blockWidth(bars: 8) < TransportBar.blockWidth(bars: 16))
    }
}

// MARK: - Library drag payload

@Suite("Library drag payload")
struct LibraryDragPayloadTests {
    @Test("A payload round-trips through its wire form")
    func roundTrip() {
        let id = UUID()
        let payload = LibraryDragPayload(kind: .record, id: id, title: "Arrival")
        let parsed = LibraryDragPayload(payload.description)

        #expect(parsed?.kind == .record)
        #expect(parsed?.id == id)
    }

    @Test("Anything else dropped on a surface parses to nil rather than a wrong id")
    func rejectsOtherText() {
        #expect(LibraryDragPayload("/Users/dylan/a-file.wav") == nil)
        #expect(LibraryDragPayload("mrroboto:song:not-a-uuid") == nil)
        #expect(LibraryDragPayload("mrroboto:planet:\(UUID().uuidString)") == nil)
    }
}

// MARK: - Light and dark

/// The frame cannot be screenshotted from this shell, so the appearance check is made where it is
/// decidable: every token the frame paints resolves to a different colour in the two appearances, and
/// paper/ink keep their polarity. A token defined in only one theme cannot pass this.
@Suite("Appearances") @MainActor
struct AppearanceTests {
    private func resolve(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.black
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    @Test("Every token the frame paints is defined in both appearances")
    func bothAppearances() {
        let tokens: [(String, Color)] = [
            ("paper", Design.Palette.paper), ("panel", Design.Palette.panel),
            ("panelAlt", Design.Palette.panelAlt), ("ink", Design.Palette.ink),
            ("inkSecondary", Design.Palette.inkSecondary), ("inkTertiary", Design.Palette.inkTertiary),
            ("line", Design.Palette.line), ("lineStrong", Design.Palette.lineStrong),
            ("accent", Design.Palette.accent), ("accentSoft", Design.Palette.accentSoft),
            ("warn", Design.Palette.warn),
        ]
        for (name, color) in tokens {
            let light = resolve(color, .aqua)
            let dark = resolve(color, .darkAqua)
            #expect(light != dark, "\(name) is the same colour in both appearances")
        }
    }

    @Test("Paper stays behind ink in both appearances")
    func polarity() {
        #expect(luminance(resolve(Design.Palette.paper, .aqua)) > luminance(resolve(Design.Palette.ink, .aqua)))
        #expect(luminance(resolve(Design.Palette.paper, .darkAqua)) < luminance(resolve(Design.Palette.ink, .darkAqua)))
        // The accent has to read against paper in both, not only in light.
        #expect(abs(luminance(resolve(Design.Palette.accent, .aqua)) - luminance(resolve(Design.Palette.paper, .aqua))) > 0.2)
        #expect(abs(luminance(resolve(Design.Palette.accent, .darkAqua)) - luminance(resolve(Design.Palette.paper, .darkAqua))) > 0.2)
    }
}

// MARK: - Surfaces that learn their own title

@Suite("Open surfaces") @MainActor
struct OpenSurfaceTests {
    @Test("Retitling keeps the surface in place, pinned and un-retired, and is not an event")
    func retitle() {
        let app = AppState(song: FrameFixture.song(), transportHost: StubTransportHost())
        let id = app.openSurface(.importRecord, title: "Import")
        app.setPinned(true, for: id)
        let entries = app.log.count

        app.retitleSurface(id, to: "Arrival.wav")

        #expect(app.bench.items.count == 1)
        #expect(app.bench.items[0].title == "Arrival.wav")
        #expect(app.bench.items[0].isPinned)
        #expect(app.log.count == entries)
    }

    @Test("Rebinding only touches surfaces that are open")
    func rebind() {
        let song = FrameFixture.song()
        let app = AppState(song: song, transportHost: StubTransportHost())
        let id = app.openSurface(.grid, title: "Grid")
        let gone = SurfaceID()

        app.rebindSurface(id, to: [song.versions[0].id])
        app.rebindSurface(gone, to: [song.versions[0].id])

        #expect(app.bound(for: id) == [song.versions[0].id])
        #expect(app.bound(for: gone).isEmpty)
    }
}
