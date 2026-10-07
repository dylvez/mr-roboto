import Foundation
import Instrument
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
                    // A take or a controller's Play in still running is kept, then everything saved.
                    activation.onQuit = { [app] in
                        app.finishRunningWork(true)
                        app.keepSurfaceWork()
                        app.saveIfNeeded()
                        app.sessions?.flush()
                    }
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
            Button("New Song") {
                app.open(Song.new(title: MrRobotoApp.untitledName()))
                // A song with nothing in it: the first thing to do is name it and give it a tempo
                // and a key, so the header opens the settings rather than leaving "Untitled, 120,
                // no key" to be discovered later.
                app.wantsSongSettings = true
            }
            .keyboardShortcut("n", modifiers: .command)
            // A song made of records: a blank song, and Sources open on it. The first stem brought
            // in sets its key, its tempo and its form.
            Button("New Song from Records…") {
                app.open(Song.new(title: MrRobotoApp.untitledName()))
                app.openSurface(.sources, title: "Sources")
            }
            .disabled(app.store == nil)
            Button("Song Settings…") { app.wantsSongSettings = true }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .disabled(app.song == nil)
            Button("Close Song") { app.closeSong() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.song == nil)
            // The loop arranged into a song: what the Structure surface's chip and the band's
            // question offer, from anywhere.
            Button(app.isMastering ? "Reading the Master…" : "Develop the Song") { Task { await app.developAndMaster() } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!app.canDevelop || app.isDeveloping || app.isMastering)
            Button("Put the Song Back as It Was") { app.putBackDevelopment() }
                .disabled(!app.canPutBackDevelopment || app.isDeveloping || app.isMastering)
            Divider()
            // Into the crate: any number of files, read and separated in the background, and no
            // song made. A song is started from a record's row, or a stem brought into one.
            Button("Import Records…") { MrRobotoApp.importRecords(app) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(app.store == nil)
            // One file as a song of its own, on the Record surface: the flip.
            Button("Flip a Record…") { MrRobotoApp.importRecord(app) }
            Button("New Mashup…") { app.openSurface(.mashup, title: "Mashup") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(app.store == nil)
            Button("Bring In a Stem…") { app.openSurface(.sources, title: "Sources") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(app.store == nil || app.song == nil)
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
                Button("Master…") { MrRobotoApp.export(app, what: "Exporting the master…") { try await Export.master(app, to: $0).wav } }
                Button("Stems…") { MrRobotoApp.export(app, what: "Exporting the stems…") { try await Export.stems(app, to: $0).first } }
                Button("MIDI…") { MrRobotoApp.export(app, what: "Exporting MIDI…") { try Export.midi(app, to: $0) } }
                Button("Lyrics…") { MrRobotoApp.export(app, what: "Exporting the lyrics…") { try Export.lyrics(app, to: $0) } }
            }
            .disabled(app.song == nil)
            Button("Import Instrument…") {
                if let url = FilePanels.chooseSFZ() { app.importInstrument(from: url) }
            }
            .disabled(app.store == nil)
            Button("Import Drum Kit…") {
                if let url = FilePanels.chooseSFZ(
                    message: "An SFZ drum kit laid out as General MIDI has it: kick on 36, snare on 38, hats on 42 and 46. Its samples are copied into the library and it is listed beside the machines.") {
                    app.importDrumKit(from: url)
                }
            }
            .disabled(app.store == nil)
            Button("Import VCSL Percussion…") {
                if let url = FilePanels.chooseFolder(
                    message: "The Versilian Community Sample Library folder (its sfz branch). Its hand percussion — congas, bongos, shakers, tambourine, claves, woodblock, agogô, cabasa, güiro, triangle, vibraslap, cajón, darbuka, frame drum and slit drum — is copied into the library and every kit plays it. Run again, it adds only what is new and keeps your settings.",
                    prompt: "Bring In") {
                    app.importVCSLPercussion(from: url)
                }
            }
            .disabled(app.store == nil)
            Menu("Recorded Hand Percussion") {
                Toggle("On", isOn: Binding(get: { app.recordedPercussion?.isOn ?? false },
                                           set: { app.setRecordedPercussion($0) }))
                Section("Keep Synthesized On") {
                    ForEach(SynthMachine.all) { machine in
                        Toggle(machine.name, isOn: Binding(
                            get: { app.recordedPercussion?.keepSynthesized.contains(machine.id) ?? false },
                            set: { app.setKeepsSynthesizedPercussion(machine, $0) }))
                    }
                }
                .disabled(app.recordedPercussion?.isOn != true)
            }
            .disabled(app.recordedPercussion == nil)
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

        // Undo and Redo reach the surface in front, which steps back through its own edits. A text
        // field that is being typed in keeps its own: the words undo as words.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { MrRobotoApp.undo(app, redo: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { MrRobotoApp.undo(app, redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            // Replacing the save group took the system's Close with it: ⌘W did nothing, even in the
            // Field Guide's window.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
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

            Button("Play from Section") {
                Task { await app.playFromActiveSection() }
            }
            .keyboardShortcut(.space, modifiers: .shift)
            .disabled(app.song?.sections.isEmpty ?? true)

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
            Toggle("Click", isOn: Binding(get: { app.isClicking }, set: { _ in app.toggleClick() }))
                .keyboardShortcut("k", modifiers: .command)

            Divider()
            // Play in: the controller recorded against the song, no microphone needed.
            let midi = SurfaceWiring.shared.midi(for: app)
            Button(midi.isPlayingIn ? "Stop Playing In" : "Play In from the Controller") {
                Task { if midi.isPlayingIn { await midi.stopPlayIn() } else { await midi.playIn() } }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(midi.mode == .off || app.song == nil)
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
            // The path's next step, from anywhere: what the rail's What next and the dock's Next
            // chip offer, without reaching for either.
            // The band's question's best answer, from anywhere.
            let asked = app.nextQuestion
            Button(asked.options.first.map { "Next: \($0.title)" } ?? "Next Step") {
                if let next = asked.options.first { app.take(next, from: asked) }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(asked.options.isEmpty)
            Button("Forget My Usual Choices") {
                app.nextPreferences.forget()
                app.nextDismissed.removeAll()
            }
            .help("The band's question goes back to the order the work goes in, with nothing learned from what you chose")
            Divider()
            // The whole library on the bench: every shelf, searched, sorted and described.
            Button("Library") { app.showSurface(.library) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Cast…") { app.openSurface(.cast, title: app.song?.title ?? "Cast") }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(app.song == nil)
            Divider()
            // A menu cannot ask, so it leaves a surface holding unkept work open and says so.
            Button("Close All Surfaces") { app.closeAllSurfaces(keepingUnkept: true) }
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
    /// File ▸ Import Records: the open dialog, then each file into the crate. Cancelling brings
    /// nothing in.
    @MainActor
    static func importRecords(_ app: AppState) {
        guard let (files, separating) = FilePanels.chooseRecords() else { return }
        app.importRecords(files, separating: separating)
        app.regions.setCollapsed(false, for: .library)
    }

    /// File ▸ Flip a Record and the empty bench's button: the open dialog, then the Record surface
    /// already importing what was chosen, as a song of its own. Cancelling opens nothing.
    @MainActor
    static func importRecord(_ app: AppState) {
        guard let url = FilePanels.chooseAudio() else { return }
        let id = app.openSurface(.importRecord, title: "Record")
        if let item = app.bench.items.first(where: { $0.id == id }) {
            SurfaceWiring.shared.importModel(for: item, app: app).drop(url)
        }
    }

    /// ⌘Z: the text field being typed in, when there is one; otherwise the surface in front.
    @MainActor
    static func undo(_ app: AppState, redo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
            return
        }
        guard let item = app.bench.active else { return }
        if redo { SurfaceWiring.shared.redo(for: item) } else { SurfaceWiring.shared.undo(for: item) }
    }

    static func untitledName(_ date: Date = Date()) -> String {
        "Untitled, \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Asks where, then exports there with the header saying so; the rail says what happened, and
    /// Finder shows the file.
    /// - Parameter what: "Exporting the master…" — the header's line while it runs.
    @MainActor
    static func export(_ app: AppState, what: String = "Exporting…",
                       _ run: @escaping @MainActor (URL) async throws -> URL?) {
        guard app.busy == nil else {
            app.note(.session, "Still \(app.busy!.lowercased())", detail: "Wait for it to finish before exporting again.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "The folder the files go in."
        if let song = app.song {
            // The song's own folder is suggested but not made: a cancelled dialog used to leave an
            // empty folder behind in ~/Music for every song you thought about exporting.
            let suggested = Export.defaultDirectory(for: song)
            let base = suggested.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            panel.directoryURL = FileManager.default.fileExists(atPath: suggested.path) ? suggested : base
            panel.nameFieldStringValue = suggested.lastPathComponent
        }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { @MainActor in
            do {
                let url = try await app.whileBusy(what) { try await run(directory) }
                if let found = url.flatMap({ $0 }) { NSWorkspace.shared.activateFileViewerSelecting([found]) }
            } catch {
                app.note(.session, "The export failed", detail: "\(error)")
            }
        }
    }
}

enum FieldGuideWindow {
    static let id = "field-guide"
}
