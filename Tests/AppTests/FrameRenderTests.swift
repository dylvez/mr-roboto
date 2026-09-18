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

    @Test("a fresh import: the path says separate the stems")
    func freshImport() throws {
        FontRegistration.registerBundledFonts()
        let app = app(GuidanceFixture.imported().song)
        try write(FrameView(app: app), size: CGSize(width: 1440, height: 900), name: "frame-import")
    }
}
