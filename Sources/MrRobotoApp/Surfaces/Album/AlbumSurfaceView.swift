import AppKit
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

    // MARK: What the body and the tests both read

    /// The songs the Add song menu offers: every library song not yet on the album, and the open
    /// song if it is not saved yet — `addSong` takes either.
    static func addable(to album: Album, from library: Library, open: Song?) -> [Song] {
        var songs = library.songs
        if let open, !songs.contains(where: { $0.id == open.id }) { songs.append(open) }
        return songs.filter { !album.songs.contains($0.id) }
    }

    /// The range `setGap` keeps a gap to, so the field and the stepper agree with the library.
    static let gapRange: ClosedRange<Double> = 0...30

    /// Seconds from what was typed into a gap field: "3", "3.5", "3,5" or "2 s". Nil when it is
    /// not a number, so the field goes back to what the album holds rather than writing 0.
    static func gapSeconds(parsing text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return max(gapRange.lowerBound, min(gapRange.upperBound, value))
    }

    /// The four states in words. The Import surface's picker shows the raw values — "notRequired"
    /// — and these are the readable ones, so these are the ones kept.
    static func label(_ status: ClearanceStatus) -> String {
        switch status {
        case .uncleared: return "Uncleared"
        case .pending: return "Pending"
        case .cleared: return "Cleared"
        case .notRequired: return "Not required"
        }
    }

    /// What each state means for the record, on the chip's tooltip.
    static func help(_ status: ClearanceStatus) -> String {
        switch status {
        case .uncleared: return "Uncleared: nobody has asked the rights holder. A release still goes out, with the source listed as uncleared in album.json."
        case .pending: return "Pending: the rights holder has been asked and has not answered yet."
        case .cleared: return "Cleared: the rights holder agreed, in writing you can find again."
        case .notRequired: return "Not required: your own recording, public domain, or a licence that already covers it."
        }
    }
}

private struct AlbumBody: View {
    let album: Album
    let app: AppState
    /// The release started from this surface, if one was: its progress and what stopped it.
    @State private var release = AlbumReleaseModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            releaseLine
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    tracklist
                    notes
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
        .modifier(CoverDropTarget(album: album, app: app))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Album title", text: Binding(get: { album.title }, set: { app.renameAlbum(album.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(Design.Typography.prose(16, weight: .medium))
                .frame(maxWidth: 320)
                .help("The album's title, renamed as you type. It names the release folder and the cover.")
            Text(summary)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            Text(String(format: "%.0f LUFS · %.0f dBTP", album.targets.integratedLUFS, album.targets.truePeakDBTP))
                .font(Design.Typography.numeric(11))
                .foregroundStyle(Design.Palette.inkTertiary)
                .help("Delivery targets: the integrated loudness every track is trimmed to and the true-peak ceiling it is limited at. The Master surface reads a song against these; a release cuts every track to them.")
            // The same release the Director's `release` tool makes, from the surface that shows
            // the record. It used to be the Director's alone.
            FrameButton(title: release.isReleasing ? "Releasing…" : "Release…", emphasis: .accent,
                        isEnabled: !release.isReleasing && !album.songs.isEmpty) {
                Task { await release.release(album.id, app: app) }
            }
            .help(releaseHelp)
            .accessibilityLabel("Release the album")
        }
    }

    private var releaseHelp: String {
        guard !album.songs.isEmpty else { return "Nothing to release: the album has no songs." }
        return String(format: "Every track bounced through its own mix, trimmed to %.0f LUFS and limited at %.0f dBTP, written as numbered 24-bit WAVs with cover.png and album.json to %@. Shown in Finder when it is done.",
                      album.targets.integratedLUFS, album.targets.truePeakDBTP, AlbumReleaseModel.folder(for: album, app: app).path)
    }

    /// What the release is doing, or what stopped it — on the surface, under the button that
    /// started it, not only in the rail.
    @ViewBuilder
    private var releaseLine: some View {
        if let line = release.progressLine {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Design.Palette.accent)
                Text(line).font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
            }
        } else if let failure = release.failure {
            Text(failure)
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if let folder = release.folder {
            HStack(spacing: 8) {
                Text("Released to \(folder.path).")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") { release.reveal() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(11.5, weight: .medium))
                    .foregroundStyle(Design.Palette.accent)
                    .help("Open the release folder in Finder")
            }
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
            HStack(spacing: 10) {
                AlbumLabel("Tracks")
                Spacer()
                addSong
            }
            if album.songs.isEmpty {
                Text("No songs yet. Add one from the menu, or drag songs in from the library.")
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(Array(album.songs.enumerated()), id: \.element) { index, id in
                let title = song(for: id)?.title ?? "this track"
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
                        .help("Open \(song.title)")
                        Text(Self.detail(of: song) + trackReading(id))
                            .font(Design.Typography.numeric(11))
                            .foregroundStyle(Design.Palette.inkSecondary)
                    } else {
                        Text("A song the library no longer holds")
                            .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                    }
                    Spacer()
                    if index > 0 {
                        GapField(seconds: album.gap(before: id)) { app.setGap($0, before: id, in: album.id) }
                    }
                    // A vertical list moves up and down. It used to say ◀ ▶.
                    ChipButton(systemImage: "chevron.up", help: "Move \(title) up one place", isEnabled: index > 0) {
                        app.moveSong(id, in: album.id, to: index - 1)
                    }
                    .accessibilityLabel("Move \(title) up")
                    ChipButton(systemImage: "chevron.down", help: "Move \(title) down one place", isEnabled: index < album.songs.count - 1) {
                        app.moveSong(id, in: album.id, to: index + 1)
                    }
                    .accessibilityLabel("Move \(title) down")
                    AlbumChip("Remove") { app.removeSong(id, from: album.id) }
                        .help("Take \(title) off the album. The song stays in the library.")
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// A menu of the library's songs not yet on the album, beside the drag that used to be the
    /// only way in. Off in offscreen renders like every AppKit-backed control: a menu draws as a
    /// block there, so a chip that does nothing stands where it would be.
    @ViewBuilder
    private var addSong: some View {
        if Design.isOffscreenRender {
            AlbumChip("Add song…") {}
        } else {
            let addable = AlbumSurfaceView.addable(to: album, from: app.library, open: app.song)
            Menu {
                if addable.isEmpty {
                    Text(app.library.songs.isEmpty ? "The library has no songs yet." : "Every song in the library is on this album.")
                }
                ForEach(addable) { song in
                    Button(song.title) { app.addSong(song.id, to: album.id) }
                }
            } label: {
                AlbumChipLabel("Add song…")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Put a library song on the album, last. Dragging one in from the library does the same.")
            .accessibilityLabel("Add a song to the album")
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

    /// The liner notes. `setNotes` had no caller: the notes went out in album.json and nothing
    /// on the surface could write them.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumLabel("Liner notes")
            CommittingField(prompt: "What the record is about, in the house's words.", value: album.notes, lines: 2...6) {
                app.setNotes($0, for: album.id)
            }
            .frame(maxWidth: 520)
            .help("Liner notes. Kept when you press Return or leave the field; a release writes them into album.json.")
            .accessibilityLabel("Liner notes")
        }
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
                        .help("The \(layout.rawValue) layout for the drawn cover")
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
            Button("Choose an Image…") {
                if let url = FilePanels.chooseImage() { app.setCover(imageAt: url, for: album.id) }
            }
            .font(Design.Typography.ui(12))
            .help("An image of your own as the cover, copied into the library")
            Text("Or drop an image here for a cover of your own.").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
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
                        AlbumChip(AlbumSurfaceView.label(status), isOn: clearance.status == status) {
                            app.setClearance(status, forSource: clearance.source, record: clearance.record, media: clearance.media, in: album.id)
                        }
                        .help(AlbumSurfaceView.help(status))
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Fields that commit

/// A text field that writes to the library when you press Return or leave it, not on every
/// keystroke: an album edit is a `library.json` write, and a sentence typed in one go should be one.
private struct CommittingField: View {
    let prompt: String
    let value: String
    var lines: ClosedRange<Int> = 1...1
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lines)
            .textFieldStyle(.roundedBorder)
            .font(Design.Typography.ui(12.5, weight: .regular))
            .focused($focused)
            .onSubmit(commitText)
            .onChange(of: focused) { _, now in if !now { commitText() } }
            .onAppear { text = value }
            // A change from elsewhere — the Director, another surface — shows, unless you are
            // mid-sentence in it.
            .onChange(of: value) { _, now in if !focused { text = now } }
    }

    private func commitText() {
        guard text != value else { return }
        commit(text)
    }
}

/// The gap before a track, in seconds: typed, or stepped by half a second. Commits when you press
/// Return or leave the field, so a half-typed "3." is not written to the library as 3. The chip
/// this replaces cycled 0 → 4 s in whole seconds on each click and said nothing about it.
private struct GapField: View {
    let seconds: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("gap")
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.numeric(11))
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .focused($focused)
                .onSubmit(commitText)
                .onChange(of: focused) { _, now in if !now { commitText() } }
                .help("Seconds of silence before this track, 0 to 30. Type a number and press Return.")
                .accessibilityLabel("Gap before this track, in seconds")
            Text("s")
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
            if !Design.isOffscreenRender {
                Stepper("", value: Binding(get: { seconds }, set: { commit(max(AlbumSurfaceView.gapRange.lowerBound, min(AlbumSurfaceView.gapRange.upperBound, $0))) }),
                        in: AlbumSurfaceView.gapRange, step: 0.5)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Half a second more or less of silence before this track")
                    .accessibilityLabel("Gap before this track")
            }
        }
        .onAppear { text = Self.format(seconds) }
        .onChange(of: seconds) { _, now in if !focused { text = Self.format(now) } }
    }

    private func commitText() {
        if let parsed = AlbumSurfaceView.gapSeconds(parsing: text) {
            if parsed != seconds { commit(parsed) }
            text = Self.format(parsed)
        } else {
            text = Self.format(seconds)
        }
    }

    private static func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }
}

// MARK: - Chips

/// The chip's face, on its own so a `Menu` can wear it as well as a `Button`.
private struct AlbumChipLabel: View {
    let title: String
    var isOn = false
    init(_ title: String, isOn: Bool = false) { self.title = title; self.isOn = isOn }

    var body: some View {
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
}

private struct AlbumChip: View {
    let title: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, isOn: Bool = false, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

    var body: some View {
        Button(action: action) { AlbumChipLabel(title, isOn: isOn) }
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

/// An image file dropped on the album is its cover. Off in offscreen renders, like every drop target.
private struct CoverDropTarget: ViewModifier {
    let album: Album
    let app: AppState

    func body(content: Content) -> some View {
        if Design.isOffscreenRender {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { ["png", "jpg", "jpeg", "heic", "tiff"].contains($0.pathExtension.lowercased()) }) else { return false }
                return app.setCover(imageAt: url, for: album.id)
            }
        }
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
