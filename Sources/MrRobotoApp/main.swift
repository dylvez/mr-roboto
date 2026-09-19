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
                .onAppear {
                    activation.opener = { [app] url in app.openPackage(at: url) }
                    activation.onQuit = { [app] in app.saveIfNeeded(); app.sessions?.flush() }
                }
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
            Button("Show Session Logs in Finder") { app.revealSessions() }
                .disabled(app.sessions == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Song") { app.open(Song(title: MrRobotoApp.untitledName())) }
                .keyboardShortcut("n", modifiers: .command)
            // The dialog first: cancelling it opens nothing, and choosing a file opens the Record
            // surface already importing it. The surface's own well still takes a drop.
            Button("Import Record…") { MrRobotoApp.importRecord(app) }
                .keyboardShortcut("i", modifiers: .command)
            Button("New Mashup…") { app.openSurface(.mashup, title: "Mashup") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.store == nil)
            Button("New Album") {
                if let id = app.createAlbum(title: "New album") { app.openAlbum(id) }
            }
            .disabled(app.store == nil)
            Button("Import MIDI…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.midi]
                panel.message = "A Standard MIDI File: drum tracks become grooves, bass and melody tracks lines, chords a progression."
                if panel.runModal() == .OK, let url = panel.url { app.importMIDI(from: url) }
            }
            .disabled(app.song == nil)
            Menu("Export") {
                Button("Master…") { MrRobotoApp.export(app) { try await Export.master(app, to: $0).wav } }
                Button("Stems…") { MrRobotoApp.export(app) { try await Export.stems(app, to: $0).first } }
                Button("MIDI…") { MrRobotoApp.export(app) { try Export.midi(app, to: $0) } }
            }
            .disabled(app.song == nil)
            Button("Import Voice…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText, .text]
                panel.message = "A markdown file of the house's lyrics, or plain text with a title line per block."
                if panel.runModal() == .OK, let url = panel.url { app.importVoice(from: url) }
            }
            .disabled(app.store == nil)
            Button("Lyrics…") { app.perform(Guidance.dockAction(for: .lyrics, in: app.song)) }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(app.song == nil)
            Button("Booth…") { app.perform(Guidance.dockAction(for: .booth, in: app.song)) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(app.song == nil)
            Button("Takes…") { app.perform(Guidance.dockAction(for: .takes, in: app.song)) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.song == nil)
            Button("Mixer…") { app.perform(Guidance.dockAction(for: .mixer, in: app.song)) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(app.song == nil)
            Button("Master…") { app.perform(Guidance.dockAction(for: .master, in: app.song)) }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(app.song == nil)
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
                Task { await SurfaceWiring.shared.player(for: app).spaceBar() }
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Play the Surface in Front") {
                guard let item = app.bench.active ?? app.bench.items.last,
                      let audition = SurfaceWiring.shared.audition(for: item, app: app) else { return }
                let player = SurfaceWiring.shared.player(for: app)
                if player.isPlaying(audition.id) { player.stop() } else { Task { await audition.play(player) } }
            }
            .keyboardShortcut(.space, modifiers: .option)
            .disabled(app.bench.items.isEmpty)
            Button("Stop") {
                Task {
                    await SurfaceWiring.shared.player(for: app).stopSounding()
                    await app.stopTransport()
                }
            }
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
            Button("Cast…") { app.openSurface(.cast, title: app.song?.title ?? "Cast") }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(app.song == nil)
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
    /// File ▸ Import Record and the empty bench's button: the open dialog, then the Record surface
    /// already importing what was chosen. Cancelling opens nothing.
    @MainActor
    static func importRecord(_ app: AppState) {
        guard let url = FilePanels.chooseAudio() else { return }
        let id = app.openSurface(.importRecord, title: "Record")
        if let item = app.bench.items.first(where: { $0.id == id }) {
            SurfaceWiring.shared.importModel(for: item, app: app).drop(url)
        }
    }

    static func untitledName(_ date: Date = Date()) -> String {
        "Untitled, \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Asks where, then exports there; the rail says what happened.
    @MainActor
    static func export(_ app: AppState, _ run: @escaping @MainActor (URL) async throws -> URL?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "The folder the files go in."
        if let song = app.song {
            let suggested = Export.defaultDirectory(for: song)
            try? FileManager.default.createDirectory(at: suggested, withIntermediateDirectories: true)
            panel.directoryURL = suggested
        }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { @MainActor in
            do {
                if let url = try await run(directory) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                app.note(.session, "The export failed", detail: "\(error)")
            }
        }
    }
}

enum FieldGuideWindow {
    static let id = "field-guide"
}
