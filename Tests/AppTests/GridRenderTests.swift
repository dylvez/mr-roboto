import AppKit
import Foundation
import Instrument
import Performance
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// The Grid on its own, rendered offscreen at the three sizes a surface is drawn in, for looking at
// rather than asserting on. Off by default, like `FrameRenderTests`:
//
//     MRROBOTO_RENDER=/path/to/dir swift test --filter GridRender
//
// Four states: empty, one painted bar with the Beatmaker under it, four bars (which scroll
// sideways below the default window's width), and a row the machine has no sound for.

@Suite("Grid render", .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil,
                               "set MRROBOTO_RENDER to a directory to write the renders"))
@MainActor
struct GridRenderTests {

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] ?? NSTemporaryDirectory())
    }

    /// Drawn through an `NSHostingView` in an offscreen window rather than `ImageRenderer`, which
    /// draws a scroll view as nothing — and a long grid's steps are in one.
    private func write(_ model: GridModel, name: String) throws {
        let names = ["minimum", "standard", "wide"]
        for (size, label) in zip(SurfaceGeometry.all, names) {
            let host = NSHostingView(rootView: GridSurfaceView(model: model)
                .frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("grid-\(name)-\(label).png"))
            window.contentView = nil
        }
    }

    private func painted() -> GridModel {
        let model = GridModel(host: StubGridHost())
        model.autoKeep.delay = nil
        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .kick, step: 10)
        model.set(.normal, voice: .snare, step: 4)
        model.set(.normal, voice: .snare, step: 12)
        for step in stride(from: 0, to: 16, by: 2) { model.set(.normal, voice: .closedHat, step: step) }
        model.set(.ghost, voice: .snare, step: 7)
        return model
    }

    @Test("empty, painted, four bars, and a silent row")
    func states() throws {
        FontRegistration.registerBundledFonts()

        try write(GridModel(host: StubGridHost()), name: "empty")

        try write(painted(), name: "painted")

        let long = painted()
        long.setBars(4)
        long.set(.accent, voice: .snare, step: 3 * 16 + 14)
        try write(long, name: "four-bars")

        let silent = painted()
        silent.addVoice(.perc)
        silent.set(.normal, voice: .perc, step: 6)
        silent.setBars(2)
        try write(silent, name: "perc-two-bars")
    }
}
