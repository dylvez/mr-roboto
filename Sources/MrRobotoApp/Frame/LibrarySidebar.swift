import AppKit
import SongGraph
import SwiftUI
import UniformTypeIdentifiers

/// What a library row carries when you drag it into the session.
///
/// A surface accepts drops with `.dropDestination(for: LibraryDragPayload.self)` and reads the id.
/// The wire form is a short string (`"mrroboto:song:<uuid>"`) so it survives a plain-text drop and is
/// trivially testable; the frame never interprets it beyond producing it.
public struct LibraryDragPayload: Codable, Sendable, Hashable, Transferable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case song, album, idea, record, sample
    }

    public let kind: Kind
    public let id: UUID
    /// What the row said, so a drop target can label itself before it resolves the id.
    public let title: String

    public init(kind: Kind, id: UUID, title: String) {
        self.kind = kind
        self.id = id
        self.title = title
    }

    public var description: String { "mrroboto:\(kind.rawValue):\(id.uuidString)" }

    /// Parses the wire form. Returns nil for anything else dropped on a surface.
    public init?(_ text: String) {
        let pieces = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "mrroboto",
              let kind = Kind(rawValue: String(pieces[1])),
              let id = UUID(uuidString: String(pieces[2])) else { return nil }
        self.init(kind: kind, id: id, title: "")
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation<Self, String>(exporting: \.description,
                                          importing: { text in
                                              guard let payload = LibraryDragPayload(text) else {
                                                  throw CocoaError(.fileReadCorruptFile)
                                              }
                                              return payload
                                          })
    }
}

extension View {
    /// Accepts library rows dropped here, adopting them into the open song the way `drop` says.
    ///
    /// Off during an offscreen render: `dropDestination` is AppKit-backed, and `ImageRenderer`
    /// draws an AppKit-backed host as one prohibited block — over the whole bench, in this case.
    /// The renders are how this frame is looked at, so the drop target steps aside for them.
    func acceptsLibraryDrops(_ app: AppState, at drop: LibraryDrop) -> some View {
        modifier(LibraryDropTarget(app: app, drop: drop))
    }
}

private struct LibraryDropTarget: ViewModifier {
    let app: AppState
    let drop: LibraryDrop

    func body(content: Content) -> some View {
        if Design.isOffscreenRender {
            content
        } else {
            content.dropDestination(for: LibraryDragPayload.self) { payloads, _ in
                payloads.reduce(false) { app.receive($1, at: drop) || $0 }
            }
        }
    }
}

/// The library, always on screen. Ideas, songs, albums, imported records, samples — everything the
/// session can draw on, and anything in it can be dragged into a surface.
struct LibrarySidebar: View {
    let app: AppState
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SmallLabel("Library")
                Spacer()
                ChipButton(systemImage: "plus.square.on.square", help: "New album",
                           isEnabled: app.store != nil) {
                    if let id = app.createAlbum(title: "New album") { app.openAlbum(id) }
                }
                ChipButton(systemImage: "arrow.clockwise", help: "Re-read the library directory",
                           isEnabled: app.store != nil) {
                    app.reloadLibrary()
                }
                CollapseButton(region: .library, app: app)
            }
            .padding(.horizontal, Design.Metric.inset)
            .frame(height: FrameLayout.headerHeight)

            Hairline()

            if !app.library.isEmpty, !Design.isOffscreenRender {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.Typography.ui(12))
                    .padding(.horizontal, Design.Metric.inset)
                    .padding(.top, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .failed(let url, let reason) = app.libraryStatus {
                        EmptyNote(title: "The library could not be read.",
                                  detail: "\(url.path)\n\(reason)")
                    } else if app.library.isEmpty {
                        emptyState
                    } else {
                        group("Ideas", app.library.ideas.map { idea in
                            Row(payload: LibraryDragPayload(kind: .idea, id: idea.id.rawValue, title: PartLabel.title(of: idea)),
                                title: PartLabel.title(of: idea),
                                detail: idea.note ?? idea.operation,
                                inSong: Self.holds(idea, app.song),
                                adopts: true)
                        })
                        group("Songs", app.library.songs.map { song in
                            Row(payload: LibraryDragPayload(kind: .song, id: song.id.rawValue, title: song.title),
                                title: song.title,
                                detail: songDetail(song),
                                isSelected: app.song?.id == song.id,
                                opens: song.id)
                        })
                        group("Albums", app.library.albums.map { album in
                            Row(payload: LibraryDragPayload(kind: .album, id: album.id.rawValue, title: album.title),
                                title: album.title,
                                detail: "\(album.songs.count) song\(album.songs.count == 1 ? "" : "s")",
                                opensAlbum: album.id)
                        })
                        group("Records", app.library.records.map { record in
                            Row(payload: LibraryDragPayload(kind: .record, id: record.id.rawValue, title: record.title),
                                title: record.title,
                                detail: Self.recordDetail(record),
                                inSong: app.song?.versions.contains { Guidance.audio(of: $0)?.media == record.media } == true,
                                adopts: true, flips: record.id)
                        })
                        group("Samples", app.library.samples.map { entry in
                            Row(payload: LibraryDragPayload(kind: .sample, id: entry.id.rawValue, title: entry.name),
                                title: entry.name,
                                detail: Self.sampleDetail(entry),
                                inSong: app.song?.versions.contains { $0.kind == .sample(entry.sample) } == true,
                                adopts: true)
                        })
                    }
                }
                .padding(.horizontal, Design.Metric.inset)
                .padding(.vertical, 16)
            }
            Spacer(minLength: 0)
        }
        .background(Design.Palette.panelAlt)
    }

    private func songDetail(_ song: Song) -> String {
        var pieces: [String] = []
        if let key = song.key { pieces.append(key.name) }
        pieces.append("\(Int(song.tempo.rounded())) bpm")
        if song.lengthInBars > 0 { pieces.append("\(song.lengthInBars) bars") }
        return pieces.joined(separator: " · ")
    }

    /// "D major · 113 bpm · 78 bars", from the record's own analysis.
    static func recordDetail(_ record: Record) -> String {
        var pieces: [String] = []
        if let version = record.analysis, case .analysis(let analysis) = version.kind {
            if let key = analysis.dominantKey { pieces.append(key.name) }
            if let tempo = analysis.dominantTempo { pieces.append("\(Int(tempo.rounded())) bpm") }
            if !analysis.bars.isEmpty { pieces.append("\(analysis.bars.count) bars") }
        }
        if pieces.isEmpty { pieces.append(record.artist.isEmpty ? record.media.fileExtension.uppercased() : record.artist) }
        return pieces.joined(separator: " · ")
    }

    /// Root, tempo, slices and the chain, from the sample itself.
    static func sampleDetail(_ entry: LibrarySample) -> String {
        var pieces: [String] = []
        if let root = entry.sample.rootPitch { pieces.append("\(root)") }
        if let tempo = entry.sample.detectedTempo { pieces.append("\(Int(tempo.rounded())) bpm") }
        if !entry.sample.slices.isEmpty { pieces.append("\(entry.sample.slices.count) slices") }
        if !entry.sample.degradation.isEmpty { pieces.append(Dust.describe(entry.sample.degradation)) }
        if pieces.isEmpty { pieces.append(entry.tags.joined(separator: " · ")) }
        return pieces.joined(separator: " · ")
    }

    /// Whether the open song already holds this idea's music — the same kind, note for note.
    static func holds(_ idea: PartVersion, _ song: Song?) -> Bool {
        song?.versions.contains { $0.kind == idea.kind } == true
    }

    /// The rows that match the filter, or all of them when there is none.
    private func matching(_ rows: [Row]) -> [Row] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(needle) || $0.detail.lowercased().contains(needle) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtImage("empty-library", width: 150, height: 100)
            EmptyNote(title: "Nothing in the library yet.",
                      detail: "Import a record with File ▸ Import Record…, or drop audio and .roboto song packages into the library folder.")
            if let directory = app.libraryStatus.directory {
                Text(directory.path)
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                FrameButton(title: "Show in Finder", emphasis: .quiet) {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ allRows: [Row]) -> some View {
        let rows = matching(allRows)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let glyph = Self.glyphs[title] {
                    Glyph(name: glyph, symbol: "circle", size: 12)
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                SmallLabel(title)
                Spacer()
                Text("\(rows.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            if rows.isEmpty {
                Text("—")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else {
                ForEach(rows) { RowView(row: $0, app: app) }
            }
        }
    }

    /// Each shelf's glyph, so the library speaks the same visual vocabulary as the path.
    static let glyphs: [String: String] = ["Ideas": "idea", "Songs": "song", "Albums": "album",
                                           "Records": "record", "Samples": "chop"]

    /// One draggable line in the sidebar. Data only — the view is `RowView` — so the row can be
    /// built inside `body` without dragging main-actor isolation into an `Identifiable` conformance.
    struct Row: Identifiable, Sendable {
        let payload: LibraryDragPayload
        let title: String
        var detail: String = ""
        var isSelected: Bool = false
        /// Set for songs: clicking the row opens the song.
        var opens: SongID?
        /// Set for albums: clicking the row opens the Album surface.
        var opensAlbum: AlbumID?
        /// The open song already holds this item's music.
        var inSong: Bool = false
        /// Ideas, samples and records: the row can be adopted into the open song from its menu.
        var adopts: Bool = false
        /// Records: the row can seed a new song.
        var flips: RecordID?

        var id: UUID { payload.id }
    }

    struct RowView: View {
        let row: Row
        let app: AppState
        /// A delete asks once. Nothing in the library could be unmade before this, and the first
        /// way to unmake something must not be a slip of the mouse.
        @State private var isConfirmingDelete = false
        @State private var isRenaming = false
        @State private var newTitle = ""

        var body: some View {
            Button {
                if let id = row.opens { app.openSong(id) } else if let id = row.opensAlbum { app.openAlbum(id) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(row.title)
                            .font(Design.Typography.ui(13, weight: row.isSelected ? .semibold : .regular))
                            .foregroundStyle(row.isSelected ? Design.Palette.accent : Design.Palette.ink)
                            .lineLimit(1)
                        if row.inSong {
                            Circle().fill(Design.Palette.accent).frame(width: 5, height: 5)
                                .help("Already in the open song")
                        }
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(Design.Typography.ui(11, weight: .regular))
                            .foregroundStyle(Design.Palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(row.isSelected ? Design.Palette.accentSoft : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.opens == nil && row.opensAlbum == nil)
            .draggable(row.payload)
            .contextMenu {
                if row.adopts {
                    Button("Adopt into this song") { app.receive(row.payload, at: .bench) }
                        .disabled(app.song == nil)
                }
                if let record = row.flips {
                    Button("Flip again (new song)") { app.flipAgain(record) }
                }
                if let id = row.opens {
                    Button("Open") { app.openSong(id) }
                    Divider()
                    Button("Rename…") { newTitle = row.title; isRenaming = true }
                    Button("Duplicate") { app.duplicateSong(id) }
                    Button("Show in Finder") { app.revealInFinder(song: id) }
                    Divider()
                    Button("Move to Trash…") { isConfirmingDelete = true }
                }
                if let id = row.opensAlbum {
                    Button("Open") { app.openAlbum(id) }
                    Divider()
                    Button("Rename…") { newTitle = row.title; isRenaming = true }
                    Button("Delete Album…") { isConfirmingDelete = true }
                }
                if row.opens == nil, row.opensAlbum == nil {
                    Divider()
                    Button("Remove from Library…") { isConfirmingDelete = true }
                }
            }
            .confirmationDialog(deleteQuestion, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(deleteVerb, role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteDetail)
            }
            .alert("Rename", isPresented: $isRenaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(row.opensAlbum != nil ? "A new name for the album." : "A new name for the song. Its package on disk keeps its file name.")
            }
        }

        // MARK: What a delete does, said before it does it

        private var deleteQuestion: String {
            switch row.payload.kind {
            case .song: return "Move “\(row.title)” to the Trash?"
            case .album: return "Delete the album “\(row.title)”?"
            case .idea: return "Remove the idea “\(row.title)” from the library?"
            case .sample: return "Remove “\(row.title)” from Samples?"
            case .record: return "Remove “\(row.title)” from Records?"
            }
        }

        private var deleteDetail: String {
            switch row.payload.kind {
            case .song: return "The song's package goes to the Trash, where Finder can put it back. It leaves every album it is on."
            case .album: return "Its songs stay in the library; only the order, the targets and the clearances go."
            case .idea: return "Songs that adopted it copied its audio and keep playing."
            case .sample: return "Songs that adopted it copied its audio and keep playing."
            case .record: return "Its audio stays in the library folder, so songs flipped from it still play. Only the row goes."
            }
        }

        private var deleteVerb: String {
            switch row.payload.kind {
            case .song: return "Move to Trash"
            case .album: return "Delete Album"
            case .idea, .sample, .record: return "Remove"
            }
        }

        private func delete() {
            switch row.payload.kind {
            case .song: app.deleteSong(SongID(rawValue: row.payload.id))
            case .album: app.deleteAlbum(AlbumID(rawValue: row.payload.id))
            case .idea: app.removeIdea(VersionID(rawValue: row.payload.id))
            case .sample: app.removeSample(SampleID(rawValue: row.payload.id))
            case .record: app.removeRecord(RecordID(rawValue: row.payload.id))
            }
        }

        private func rename() {
            if let id = row.opens { app.renameSong(id, to: newTitle) }
            else if let id = row.opensAlbum { app.renameAlbum(id, to: newTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
