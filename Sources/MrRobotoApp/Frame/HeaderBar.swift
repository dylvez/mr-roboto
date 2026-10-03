import SongGraph
import SwiftUI

/// The header: which song you are in, and the two things you can do to the song as a whole.
/// History is the song graph's own history — every version, newest first — not an invented feed.
struct HeaderBar: View {
    @Bindable var app: AppState
    @State private var isShowingHistory = false
    @State private var isShowingSettings = false

    var body: some View {
        HStack(spacing: 14) {
            // The app's own mark, then a rule, then the song you are in.
            HStack(spacing: 8) {
                AppIconArt()
                    .frame(width: 34, height: 34)
                Wordmark(size: 16)
            }
            .accessibilityElement(children: .combine)
            Rectangle()
                .fill(Design.Palette.lineStrong)
                .frame(width: Design.Metric.hairline, height: 22)
            SmallLabel("Song")
            // The title is the way into the song's settings: press it to rename the song or set
            // its tempo, key and meter. Before this the title was a label, and a song made with
            // File ▸ New Song kept "Untitled, Sept 17" at 120 with no key for as long as it lived.
            Button {
                isShowingSettings.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(app.song?.title ?? "No song open")
                        .font(Design.Typography.ui(17, weight: .medium))
                        .foregroundStyle(app.song == nil ? Design.Palette.inkTertiary : Design.Palette.ink)
                        .lineLimit(1)
                    if app.song != nil {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Design.Palette.inkTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(app.song == nil)
            .help("Rename the song, or set its tempo, key and meter (⌘⇧,)")
            .accessibilityLabel(app.song.map { "Song: \($0.title). Settings" } ?? "No song open")
            .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
                SongSettingsPopover(app: app)
            }
            .onChange(of: app.wantsSongSettings) { _, wants in
                // File ▸ New Song and the menu item ask for the settings; the header opens them.
                guard wants else { return }
                app.wantsSongSettings = false
                if app.song != nil { isShowingSettings = true }
            }
            if app.hasUnsavedChanges {
                Text("unsaved")
                    .font(Design.Typography.label)
                    .foregroundStyle(Design.Palette.warn)
                    .help("Saved on its own a few seconds after the last change, and on ⌘S.")
            }
            Spacer(minLength: 16)
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
                    .foregroundStyle(Design.Palette.warn)
                    .help(failure)
            }
            FrameButton(title: "History", emphasis: .quiet, isEnabled: app.song != nil) {
                isShowingHistory.toggle()
            }
            .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                HistoryList(app: app)
            }
            FrameButton(title: "Save", emphasis: app.hasUnsavedChanges ? .accent : .outlined,
                        isEnabled: app.song != nil && app.store != nil) {
                app.save()
            }
        }
        .padding(.horizontal, 28)
        .frame(height: FrameLayout.headerHeight)
        .background(Design.Palette.paper)
    }
}

/// Every version in the song, newest first, with the operation that made it. The song graph is
/// append-only, so this is the whole history — nothing is reconstructed.
private struct HistoryList: View {
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
