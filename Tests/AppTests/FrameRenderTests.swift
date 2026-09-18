import AppKit
import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// Renders the frame offscreen to PNG, for looking at rather than asserting on. Off by default:
//
//     MRROBOTO_RENDER=/path/to/dir swift test --filter FrameRender
//
// It exists because the assistant working on this app cannot screenshot the running window, and a
// layout change nobody has looked at is a layout change nobody has checked.

@Suite("Frame render", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil,
                                "set MRROBOTO_RENDER to a directory to write the renders"))
@MainActor
struct FrameRenderTests {

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] ?? NSTemporaryDirectory())
    }

    private func write<V: View>(_ view: V, size: CGSize, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func app(_ song: Song) -> AppState {
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let dir = GuidanceFixture.temporaryDirectory("render")
        let app = AppState(library: Library(songs: [song]), song: nil, store: LibraryStore(directoryURL: dir),
                           status: .loaded(dir), transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        app.open(song)
        return app
    }

    @Test("the frame with a dusty chop on the bench, wide and narrow")
    func dustyChop() throws {
        FontRegistration.registerBundledFonts()
        var built = GuidanceFixture.chopped()
        let dusty = try #require(Dust.version(dirtying: built.sample!, through: [Dust.pass(.sp1200, mix: 0.6)],
                                              by: .persona("Director")))
        try built.song.append(dusty)
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .chopLane, title: "Bar 5 of Arrival", bound: [built.sample!.id]))

        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-1440")
        try write(FrameView(app: app), size: CGSize(width: 1100, height: 800), name: "frame-1100")
        try write(FieldGuideView(), size: CGSize(width: 620, height: 900), name: "field-guide")
    }

    @Test("the app icon, at 1024 and at Dock sizes")
    func icon() throws {
        try write(AppIconArt(), size: CGSize(width: 512, height: 512), name: "app-icon-1024")
        try write(HStack(spacing: 24) {
            ForEach([16.0, 32, 64, 128], id: \.self) { AppIconArt().frame(width: $0, height: $0) }
        }.padding(20).background(Color(white: 0.93)), size: CGSize(width: 340, height: 170), name: "app-icon-sizes")
    }

    @Test("a real Grid and Sound on the bench, with glyphs and bands")
    func realSurfaces() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.grooved()
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .grid, title: "New groove"))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-grid")
        app.perform(SurfaceAction(surface: .sound, title: "Motown, 120", bound: [built.groove!.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-sound")
    }

    @Test("the Piano roll and the Chords surfaces on the bench")
    func m2Surfaces() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = GuidanceFixture.grooved()
        let app = app(built.song)
        app.perform(SurfaceAction(surface: .pianoRoll, title: "Bass under Motown, 120", bound: [built.groove!.id]))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-roll")
        app.perform(SurfaceAction(surface: .chords, title: "Chords"))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-chords")
    }

    @Test("the Structure surface on the bench, with a form kept")
    func structure() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let built = FormFixture.build()
        let app = app(built.song)
        app.arrange([Section(name: "Intro", stitch: [built.groove], lengthInBars: 4),
                     Section(name: "Verse", stitch: [built.groove, built.bass], lengthInBars: 16),
                     Section(name: "Hook", stitch: [built.groove, built.bass], lengthInBars: 8)])
        app.perform(SurfaceAction(surface: .structure, title: built.song.title))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-structure")
    }

    @Test("the library with an idea, a sample, a record and an album; the Album surface open")
    func library() throws {
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
        let directory = LibraryFixture.directory("render")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory),
                           transportHost: StubTransportHost(), regions: RegionVisibility(defaults: defaults),
                           primers: PrimerStore(defaults: defaults))
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (song, groove, chop) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)
        #expect(app.keepAsIdea(groove) != nil)
        #expect(app.saveToSamples(chop) != nil)
        app.arrange([Section(name: "Verse", stitch: [groove, chop], lengthInBars: 16), Section(name: "Hook", stitch: [groove], lengthInBars: 8)])
        app.save()
        let album = try #require(app.createAlbum(title: "Interior Season", artist: "Vessel"))
        #expect(app.addSong(song.id, to: album))
        app.openAlbum(album)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-library")
    }

    @Test("first launch: nothing open")
    func firstLaunch() throws {
        FontRegistration.registerBundledFonts()
        let defaults = UserDefaults(suiteName: "mrroboto.render.\(UUID().uuidString)")!
        let app = AppState(library: Library(), transportHost: StubTransportHost(),
                           regions: RegionVisibility(defaults: defaults), primers: PrimerStore(defaults: defaults))
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-empty")
    }

    @Test("a fresh import: the path says separate the stems")
    func freshImport() throws {
        FontRegistration.registerBundledFonts()
        let app = app(GuidanceFixture.imported().song)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-import")
    }
}
