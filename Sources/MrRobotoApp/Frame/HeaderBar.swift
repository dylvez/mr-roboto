import SongGraph
import SwiftUI

/// Every version in the song, newest first, with the operation that made it. The song graph is
/// append-only, so this is the whole history — nothing is reconstructed.
struct HistoryList: View {
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SmallLabel("History")
                .padding(.horizontal, Design.Metric.inset)
                .padding(.top, 14)
                .padding(.bottom, 8)
            if app.versions.isEmpty {
                EmptyNote(title: "Nothing recorded yet.",
                          detail: "Versions appear here as surfaces hand work back.")
                    .padding(.horizontal, Design.Metric.inset)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(app.versions.reversed()) { version in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(version.type.rawValue.capitalized)
                                        .font(Design.Typography.ui(13.5, weight: .medium))
                                    Spacer()
                                    Text(app.versionNumber(of: version.id).map { "v\($0)" } ?? "")
                                        .font(Design.Typography.numeric(11))
                                        .foregroundStyle(Design.Palette.inkSecondary)
                                }
                                Text(app.provenanceLine(for: version))
                                    .font(Design.Typography.ui(11.5, weight: .regular))
                                    .foregroundStyle(Design.Palette.inkSecondary)
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(Design.Typography.numeric(10.5))
                                    .foregroundStyle(Design.Palette.inkTertiary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, Design.Metric.inset)
                            Hairline()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 300)
        .background(Design.Palette.panel)
    }
}

/// What the song as a whole is waiting on — the band or a save at work, the crate reading and
/// separating records, a save that failed — said where the song's title is, in the middle of the
/// window's toolbar.
struct HeaderStatus: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let busy = app.busy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Design.Palette.accent)
                    Text(busy)
                        .font(Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(1)
                }
                .help("Working. The rail says what happened when it is done.")
            }
            // The crate's work runs beside anything else, so it has a line of its own.
            if let crate = app.crate.line {
                HStack(spacing: 6) {
                    if Design.isOffscreenRender {
                        // A render draws AppKit's progress views as a prohibited block.
                        Circle().fill(Design.Palette.accent).frame(width: 6, height: 6)
                    } else if let fraction = app.crate.step?.fraction, app.crate.running?.kind == .separate {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                            .tint(Design.Palette.accent)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Design.Palette.accent)
                    }
                    Text(crate)
                        .font(Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(1)
                }
                .help("The crate, reading and separating records in the background. Close what you like; it carries on.")
            }
            if let failure = app.lastSaveError {
                // A save that failed in a folded rail is a save you believe happened. Said here,
                // beside the button that failed.
                Text("Save failed")
                    .font(Design.Typography.label)
                    .foregroundStyle(Design.Palette.danger)
                    .help(failure)
            }
        }
    }
}

/// The window's own chrome: the song in the window's title, with "Edited" under it while it is
/// unsaved, and History and Save in the toolbar, the way a Mac document window does; the title's
/// menu has the song's settings.
struct WindowChrome: ViewModifier {
    let app: AppState
    @State private var isShowingHistory = false

    private var isIdea: Bool { app.song?.isIdea == true }

    /// Under the title: "Idea" when an idea is open, so it is never taken for a song, and "Edited"
    /// while it is unsaved.
    static func subtitle(isIdea: Bool, edited: Bool) -> String {
        [isIdea ? "Idea" : nil, edited ? "Edited" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle(app.song?.title ?? "Mr. Roboto")
            .navigationSubtitle(Self.subtitle(isIdea: app.song?.isIdea == true, edited: app.hasUnsavedChanges))
            .toolbarTitleMenu {
                Button(isIdea ? "Idea Settings…" : "Song Settings…") { app.wantsSongSettings = true }
                    .disabled(app.song == nil)
                Button("History") { isShowingHistory = true }
                    .disabled(app.song == nil)
                Divider()
                Button(isIdea ? "Close Idea" : "Close Song") { app.closeSong() }
                    .disabled(app.song == nil)
            }
            .toolbar {
                // Only while there is something to say: an empty status item still draws its
                // divider in the middle of the toolbar.
                if app.busy != nil || app.crate.line != nil || app.lastSaveError != nil {
                    ToolbarItem(placement: .status) {
                        HeaderStatus(app: app)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        app.isShowingPalette.toggle()
                    } label: {
                        Label("Command Palette", systemImage: "command")
                    }
                    .help("Go to a surface or a song, or do anything, by typing (⇧⌘P)")
                    Button {
                        isShowingHistory.toggle()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .help("Every version in the song, newest first")
                    .disabled(app.song == nil)
                    .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                        HistoryList(app: app)
                    }
                    SaveButton(app: app)
                }
            }
            .containerBackground(Design.Palette.paper, for: .window)
    }
}

/// Save, in the toolbar: the one prominent control while the song has unsaved work, a plain one
/// once it is saved — autosave is a few seconds behind, so most of the time it is quiet.
private struct SaveButton: View {
    let app: AppState

    var body: some View {
        if app.hasUnsavedChanges {
            Button("Save") { app.save() }
                .buttonStyle(.glassProminent)
                .disabled(app.song == nil || app.store == nil)
                .help("Save the song now (⌘S). It saves itself a few seconds after the last change.")
        } else {
            Button("Save") { app.save() }
                .disabled(app.song == nil || app.store == nil)
                .help("Saved. It saves itself a few seconds after the last change.")
        }
    }
}
