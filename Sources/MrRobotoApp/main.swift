import Foundation
import SongGraph
import SwiftUI

/// Mr. Roboto. An executable rather than an .app bundle while Gate A is being built: everything
/// stays inside the package and `make check` covers it.
@main
struct MrRobotoApp: App {
    /// The one `AppState` in the process. Surfaces are handed this object, never a copy.
    @State private var app = AppState.live()

    /// Without this the window is created and never shown — see `ActivationDelegate`.
    @NSApplicationDelegateAdaptor(ActivationDelegate.self) private var activation

    init() {
        // Before anything renders: the app ships Newsreader and Karla rather than hoping the
        // machine has them. Any face that will not register says so on stderr and in the log.
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerGateASurfaces()
    }

    var body: some Scene {
        WindowGroup {
            FrameView(app: app)
                .frame(minWidth: FrameLayout.minimumWindowWidth, minHeight: FrameLayout.minimumWindowHeight)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands { FrameCommands(app: app) }
    }
}

/// The menu bar. The standard groups (about, services, window, help) come from SwiftUI; these are the
/// ones that mean something in Gate A. Space is the transport, as it is in every instrument.
struct FrameCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Song") { app.open(Song(title: MrRobotoApp.untitledName())) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Import Record…") { app.openSurface(.importRecord, title: "Import") }
                .keyboardShortcut("i", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.song == nil || app.store == nil)
            Button("Reload Library") { app.reloadLibrary() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.store == nil)
        }

        CommandMenu("Transport") {
            Button(app.transport.isPlaying ? "Stop" : "Play") {
                Task { await app.toggleTransport() }
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Stop") { Task { await app.stopTransport() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(app.transport == .stopped)

            Toggle("Loop", isOn: Binding(get: { app.isLooping }, set: { _ in app.toggleLoop() }))
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandMenu("Surfaces") {
            ForEach(Array(SurfaceKind.gateA.enumerated()), id: \.element) { index, kind in
                Button(kind.rawValue) {
                    app.openSurface(kind, title: app.song?.title ?? "Untitled")
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Close All Surfaces") {
                for item in app.bench.items { app.closeSurface(item.id) }
            }
            .disabled(app.bench.items.isEmpty)
        }
    }
}

extension MrRobotoApp {
    /// "Untitled, Sept 17" — the same shape the mockups use.
    static func untitledName(_ date: Date = Date()) -> String {
        "Untitled, \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
