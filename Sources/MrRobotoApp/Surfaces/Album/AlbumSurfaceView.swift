import SongGraph
import SwiftUI

/// The album: its songs in order, the targets it is delivered to, and the clearance state of every
/// record its samples came from. Reads the library through the app on every render, so it is
/// never stale; every change goes through `AppState`'s album calls and back to `library.json`.
struct AlbumSurfaceView: View {
    let surfaceID: SurfaceID
    let app: AppState

    var body: some View {
        if let album = app.album(for: surfaceID) {
            AlbumBody(album: album, app: app)
        } else {
            EmptyNote(title: "This album is gone from the library.",
                      detail: "It was removed or the library was reloaded from a copy without it.")
                .padding(Design.Metric.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Design.Palette.panel)
        }
    }
}

private struct AlbumBody: View {
    let album: Album
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            tracklist
            clearances
            Spacer(minLength: 0)
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        .modifier(SongDropTarget(album: album, app: app))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("Album title", text: Binding(get: { album.title }, set: { app.renameAlbum(album.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(Design.Typography.prose(16, weight: .medium))
                .frame(maxWidth: 320)
            Text(summary)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            Text(String(format: "%.0f LUFS · %.0f dBTP", album.targets.integratedLUFS, album.targets.truePeakDBTP))
                .font(Design.Typography.numeric(11))
                .foregroundStyle(Design.Palette.inkTertiary)
                .help("Delivery targets: integrated loudness and true-peak ceiling. Mastering arrives with M7.")
        }
    }

    private var summary: String {
        let count = album.songs.count
        let bars = album.songs.compactMap { song(for: $0)?.lengthInBars }.reduce(0, +)
        var pieces = ["\(count) song\(count == 1 ? "" : "s")"]
        if bars > 0 { pieces.append("\(bars) bars arranged") }
        return pieces.joined(separator: " · ")
    }

    private func song(for id: SongID) -> Song? { app.song?.id == id ? app.song : app.library.song(id) }

    private var tracklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("Tracks")
            if album.songs.isEmpty {
                Text("No songs yet. Drag songs in from the library.")
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(Array(album.songs.enumerated()), id: \.element) { index, id in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(Design.Typography.numeric(11))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .frame(width: 18, alignment: .trailing)
                    if let song = song(for: id) {
                        Button { app.openSong(id) } label: {
                            Text(song.title).font(Design.Typography.ui(13.5, weight: .medium)).foregroundStyle(Design.Palette.ink)
                        }
                        .buttonStyle(.plain)
                        Text(Self.detail(of: song))
                            .font(Design.Typography.numeric(11))
                            .foregroundStyle(Design.Palette.inkSecondary)
                    } else {
                        Text("A song the library no longer holds")
                            .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                    }
                    Spacer()
                    AlbumChip("◀") { app.moveSong(id, in: album.id, to: index - 1) }
                    AlbumChip("▶") { app.moveSong(id, in: album.id, to: index + 1) }
                    AlbumChip("Remove") { app.removeSong(id, from: album.id) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    static func detail(of song: Song) -> String {
        var pieces: [String] = []
        if let key = song.key { pieces.append(key.name) }
        pieces.append("\(Int(song.tempo.rounded())) bpm")
        if song.lengthInBars > 0 {
            let seconds = Double(song.lengthInBars * song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
            pieces.append("\(song.lengthInBars) bars · \(StructureModel.clock(seconds))")
        }
        return pieces.joined(separator: " · ")
    }

    private var clearances: some View {
        let sources = app.sources(of: album)
        return VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("Clearances")
            if sources.isEmpty {
                Text("No sampled sources across these songs.")
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, clearance in
                HStack(spacing: 10) {
                    Text(clearance.source)
                        .font(Design.Typography.ui(13))
                        .foregroundStyle(Design.Palette.ink)
                        .lineLimit(1)
                    Spacer()
                    ForEach(ClearanceStatus.allCases, id: \.self) { status in
                        AlbumChip(Self.label(status), isOn: clearance.status == status) {
                            app.setClearance(status, forSource: clearance.source, record: clearance.record, in: album.id)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    static func label(_ status: ClearanceStatus) -> String {
        switch status {
        case .uncleared: return "Uncleared"
        case .pending: return "Pending"
        case .cleared: return "Cleared"
        case .notRequired: return "Not required"
        }
    }
}

private struct AlbumChip: View {
    let title: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, isOn: Bool = false, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct AlbumLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}

/// Songs dropped on the album join its sequence. Off in offscreen renders, like every drop target.
private struct SongDropTarget: ViewModifier {
    let album: Album
    let app: AppState

    func body(content: Content) -> some View {
        if Design.isOffscreenRender {
            content
        } else {
            content.dropDestination(for: LibraryDragPayload.self) { payloads, _ in
                var took = false
                for payload in payloads where payload.kind == .song {
                    took = app.addSong(SongID(rawValue: payload.id), to: album.id) || took
                }
                return took
            }
        }
    }
}
