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
        // Before anything renders: the app ships IBM Plex Sans and IBM Plex Mono rather than hoping
        // the machine has them. Any face that will not register says so on stderr and in the log.
        FontRegistration.registerBundledFonts()
        SurfaceRegistry.registerSurfaces()
    }

    var body: some Scene {
        WindowGroup {
            FrameView(app: app)
                .onAppear { activation.opener = { [app] url in app.openPackage(at: url) } }
                // The floor: every region folded away, one surface at the size it needs. `FrameView`
                // raises it to whatever the regions you have open actually require, so asking for a
                // region back asks the window for its width rather than crushing the instrument.
                .frame(minWidth: FrameLayout.minimumWindowWidth, minHeight: FrameLayout.minimumWindowHeight)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: FrameLayout.defaultWindowWidth, height: FrameLayout.defaultWindowHeight)
        .commands { FrameCommands(app: app) }

        // Help ▸ Mr. Roboto Field Guide. A window of its own so it can sit beside the work.
        Window("Field Guide", id: FieldGuideWindow.id) {
            FieldGuideView()
        }
        .defaultSize(width: 620, height: 720)
    }
}

/// The menu bar. The standard groups (about, services, window, help) come from SwiftUI; these are the
/// ones that mean something in Gate A. Space is the transport, as it is in every instrument.
struct FrameCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Mr. Roboto Field Guide") { openWindow(id: FieldGuideWindow.id) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Button("Show Every Primer Again") { app.primers.resetAll() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Song") { app.open(Song(title: MrRobotoApp.untitledName())) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Import Record…") { app.openSurface(.importRecord, title: "Record") }
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

        // The three visual directions, live. Switching repaints every body that reads a token and
        // touches nothing else — the bench, the loaded song and the transport are not disturbed —
        // and the choice is remembered in UserDefaults for the next launch.
        //
        // In the standard View menu rather than a menu of its own: this is how a window looks, not a
        // thing the instrument does.
        CommandGroup(after: .toolbar) {
            Divider()
            // The three flanking regions, foldable. ⌥⌘1/2/3, left to right as they sit on screen:
            // the instrument dominates the window and these are on call.
            ForEach(FrameRegion.allCases) { region in
                Toggle("Show \(region.title)", isOn: Binding(
                    get: { !app.regions.isCollapsed(region) },
                    set: { app.regions.setCollapsed(!$0, for: region) }))
                .keyboardShortcut(KeyEquivalent(region.shortcut), modifiers: [.command, .option])
            }
            Divider()
            ForEach(Design.Theme.allCases) { theme in
                Toggle(theme.displayName, isOn: Binding(
                    get: { Design.theme == theme },
                    set: { if $0 { Design.select(theme) } }))
                .keyboardShortcut(KeyEquivalent(Character("\(themeShortcutNumber(theme))")),
                                  modifiers: [.command, .control])
            }
            Divider()
        }

        CommandMenu("Surfaces") {
            // The same call the bench dock makes, so the menu and the chips cannot drift: a surface
            // picked by name opens on the most useful thing the song has for it.
            ForEach(Array(SurfaceKind.gateA.enumerated()), id: \.element) { index, kind in
                Button(kind.rawValue) {
                    app.perform(Guidance.dockAction(for: kind, in: app.song))
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

/// ⌃⌘1/2/3. Plain ⌘1–3 already belong to the Surfaces menu, and these are pressed far less often.
private func themeShortcutNumber(_ theme: Design.Theme) -> Int {
    (Design.Theme.allCases.firstIndex(of: theme) ?? 0) + 1
}

extension MrRobotoApp {
    /// "Untitled, Sept 17" — the same shape the mockups use.
    static func untitledName(_ date: Date = Date()) -> String {
        "Untitled, \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

enum FieldGuideWindow {
    static let id = "field-guide"
}
