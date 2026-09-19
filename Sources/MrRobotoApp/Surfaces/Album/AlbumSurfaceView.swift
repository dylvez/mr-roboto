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
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    tracklist
                    readings
                    palette
                    clearances
                }
                cover
            }
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

    private var observation: AlbumObservation { app.observe(album: album) }

    private var summary: String {
        let count = album.songs.count
        var pieces = ["\(count) song\(count == 1 ? "" : "s")"]
        let seconds = observation.runningSeconds
        if seconds > 0 { pieces.append(String(format: "%d:%02d with the gaps", Int(seconds) / 60, Int(seconds) % 60)) }
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
                        Text(Self.detail(of: song) + trackReading(id))
                            .font(Design.Typography.numeric(11))
                            .foregroundStyle(Design.Palette.inkSecondary)
                    } else {
                        Text("A song the library no longer holds")
                            .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                    }
                    Spacer()
                    if index > 0 {
                        AlbumChip(String(format: "gap %.1f s", album.gap(before: id))) {
                            app.setGap(album.gap(before: id) >= 4 ? 0 : album.gap(before: id) + 1, before: id, in: album.id)
                        }
                    }
                    AlbumChip("◀") { app.moveSong(id, in: album.id, to: index - 1) }
                    AlbumChip("▶") { app.moveSong(id, in: album.id, to: index + 1) }
                    AlbumChip("Remove") { app.removeSong(id, from: album.id) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// " · hook at 0:41 · −14.2 LUFS" for a track the album has read or released.
    private func trackReading(_ id: SongID) -> String {
        guard let track = observation.tracks.first(where: { $0.id == id }) else { return "" }
        var pieces: [String] = []
        if let hook = track.hookSeconds { pieces.append("hook at \(StructureModel.clock(hook))") }
        if let lufs = track.releasedLUFS { pieces.append(String(format: "%.1f LUFS", lufs)) }
        return pieces.isEmpty ? "" : " · " + pieces.joined(separator: " · ")
    }

    private var readings: some View {
        let observation = self.observation
        let lines = Producer().read(observation) + Peer().read(observation)
        return VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("The record, read")
            if observation.tracks.count < 2 {
                Text("Two songs and the Producer and the Peer read the order.")
                    .font(Design.Typography.ui(12, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(lines) { reading in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(reading.holds ? Design.Palette.accent : Design.Palette.warn).frame(width: 6, height: 6).padding(.top, 5)
                    Text(reading.says).font(Design.Typography.ui(12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(observation.neighbours, id: \.from) { pair in
                Text(String(format: "%@ → %@: %@ · tempo ×%.2f", pair.from, pair.to,
                            pair.keyDistance.map { $0 == 0 ? "same key" : "\($0) on the circle" } ?? "key unknown", pair.tempoRatio))
                    .font(Design.Typography.numeric(10.5)).foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }

    private var palette: some View {
        let entries = observation.palette
        return VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("Palette")
            if entries.isEmpty {
                Text("Nothing shared yet: sounds, dust and bass voices across the songs land here.")
                    .font(Design.Typography.ui(12, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(entries, id: \.entry) { entry in
                HStack(spacing: 8) {
                    Text(entry.entry).font(Design.Typography.ui(12.5, weight: entry.tracks.count > 1 ? .medium : .regular))
                    Text(entry.tracks.joined(separator: ", ")).font(Design.Typography.numeric(10.5)).foregroundStyle(Design.Palette.inkTertiary)
                }
            }
        }
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("Cover")
            switch album.cover {
            case .drawn(let design):
                CoverView(design: design, title: album.title, artist: album.artist, side: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
                HStack(spacing: 6) {
                    ForEach(CoverDesign.Layout.allCases, id: \.self) { layout in
                        AlbumChip(layout.rawValue, isOn: design.layout == layout) {
                            var next = design
                            next.layout = layout
                            app.setCover(next, for: album.id)
                        }
                    }
                }
            case .image(let media):
                if let store = app.store, let url = try? store.mediaURL(for: media), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                } else {
                    Text("The cover image is missing from the library.").font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                }
            }
            Text("Drop an image here for a cover of your own.").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
        .frame(width: 220, alignment: .topLeading)
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
