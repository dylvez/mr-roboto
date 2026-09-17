import SongGraph
import SwiftUI

/// The header: which song you are in, and the two things you can do to the song as a whole.
/// History is the song graph's own history — every version, newest first — not an invented feed.
struct HeaderBar: View {
    let app: AppState
    @State private var isShowingHistory = false

    var body: some View {
        HStack(spacing: 14) {
            SmallLabel("Song")
            Text(app.song?.title ?? "No song open")
                .font(Design.Typography.ui(17, weight: .medium))
                .foregroundStyle(app.song == nil ? Design.Palette.inkTertiary : Design.Palette.ink)
            if app.hasUnsavedChanges {
                Text("unsaved")
                    .font(Design.Typography.label)
                    .foregroundStyle(Design.Palette.warn)
            }
            Spacer()
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
