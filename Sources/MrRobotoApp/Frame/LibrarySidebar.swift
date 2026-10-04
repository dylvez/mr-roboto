import AppKit
import Performance
import SongGraph
import SwiftUI
import UniformTypeIdentifiers

/// What a library row carries when you drag it into the session.
///
/// A surface accepts drops with `.dropDestination(for: LibraryDragPayload.self)` and reads the id.
/// The wire form is a short string (`"mrroboto:song:<uuid>"`, and for a record's stem
/// `"mrroboto:stem:<record uuid>:vocals"`) so it survives a plain-text drop and is trivially
/// testable; the frame never interprets it beyond producing it.
public struct LibraryDragPayload: Codable, Sendable, Hashable, Transferable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case song, album, idea, record, sample
        /// One stem of a record in the crate: `id` is the record's.
        case stem
    }

    public let kind: Kind
    public let id: UUID
    /// What the row said, so a drop target can label itself before it resolves the id.
    public let title: String
    /// For a stem: which one.
    public let stem: String?

    public init(kind: Kind, id: UUID, title: String, stem: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.stem = stem
    }

    public var description: String {
        let head = "mrroboto:\(kind.rawValue):\(id.uuidString)"
        return stem.map { "\(head):\($0)" } ?? head
    }

    /// Parses the wire form. Returns nil for anything else dropped on a surface.
    public init?(_ text: String) {
        let pieces = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard pieces.count >= 3, pieces[0] == "mrroboto",
              let kind = Kind(rawValue: String(pieces[1])),
              let id = UUID(uuidString: String(pieces[2])) else { return nil }
        let stem = pieces.count == 4 ? String(pieces[3]) : nil
        guard (kind == .stem) == (stem?.isEmpty == false) else { return nil }
        self.init(kind: kind, id: id, title: "", stem: stem)
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
                        recordsGroup
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

    /// "D major · 113 bpm · 78 bars · 4 stems", from the record's own analysis. Without the stems
    /// where the row marks them itself.
    static func recordDetail(_ record: Record, stems showsStems: Bool = true) -> String {
        var pieces: [String] = []
        if let analysis = record.reading {
            if let key = analysis.dominantKey { pieces.append(key.name) }
            if let tempo = analysis.dominantTempo { pieces.append("\(Int(tempo.rounded())) bpm") }
            if !analysis.bars.isEmpty { pieces.append("\(analysis.bars.count) bars") }
            // Only a record far enough off pitch to be moved when it is fitted.
            if let cents = record.tuning, abs(cents) >= SourceFitting.leastCents {
                pieces.append("\(Int(abs(cents).rounded()))¢ \(cents > 0 ? "sharp" : "flat")")
            }
        }
        if showsStems, let stems = record.stems { pieces.append("\(stems.count) stem\(stems.count == 1 ? "" : "s")") }
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
                      detail: "Bring records into the crate with File ▸ Import Records…, or start a song from nothing with File ▸ New Song. Audio dropped into the Mr. Roboto Inbox folder — in iCloud Drive, or in Music — arrives here as an idea.")
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

    /// The crate: each record with its readings and what is being done to it, opening to its stems
    /// and the chops saved from it.
    @ViewBuilder
    private var recordsGroup: some View {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let records = app.library.records.filter { record in
            needle.isEmpty || record.title.lowercased().contains(needle) || Self.recordDetail(record).lowercased().contains(needle)
        }
        VStack(alignment: .leading, spacing: 6) {
            groupHeader("Records", count: records.count)
            if records.isEmpty {
                Text("—")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else {
                ForEach(records) { RecordRowView(record: $0, app: app) }
            }
        }
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            if let glyph = Self.glyphs[title] {
                Glyph(name: glyph, symbol: "circle", size: 12)
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            SmallLabel(title)
            Spacer()
            Text("\(count)")
                .font(Design.Typography.numeric(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ allRows: [Row]) -> some View {
        let rows = matching(allRows)
        VStack(alignment: .leading, spacing: 6) {
            groupHeader(title, count: rows.count)
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
        /// Ideas and samples: the row can be adopted into the open song from its menu.
        var adopts: Bool = false

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
            case .stem: return ""
            }
        }

        private var deleteDetail: String {
            switch row.payload.kind {
            case .song: return "The song's package goes to the Trash, where Finder can put it back. It leaves every album it is on."
            case .album: return "Its songs stay in the library; only the order, the targets and the clearances go."
            case .idea: return "Songs that adopted it copied its audio and keep playing."
            case .sample: return "Songs that adopted it copied its audio and keep playing."
            case .record: return "Its audio and its stems stay in the library folder, so songs made from it still play. Only the row goes."
            case .stem: return ""
            }
        }

        private var deleteVerb: String {
            switch row.payload.kind {
            case .song: return "Move to Trash"
            case .album: return "Delete Album"
            case .idea, .sample, .record, .stem: return "Remove"
            }
        }

        private func delete() {
            switch row.payload.kind {
            case .song: app.deleteSong(SongID(rawValue: row.payload.id))
            case .album: app.deleteAlbum(AlbumID(rawValue: row.payload.id))
            case .idea: app.removeIdea(VersionID(rawValue: row.payload.id))
            case .sample: app.removeSample(SampleID(rawValue: row.payload.id))
            case .record: app.removeRecord(RecordID(rawValue: row.payload.id))
            case .stem: break
            }
        }

        private func rename() {
            if let id = row.opens { app.renameSong(id, to: newTitle) }
            else if let id = row.opensAlbum { app.renameAlbum(id, to: newTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

/// A record on the shelf. Its line says what it is, or what the crate is doing to it; opened, its
/// stems — each with how much of the record it is and where in it it plays — and the chops saved
/// from it, each dragged onto the song or a Structure section.
struct RecordRowView: View {
    let record: Record
    let app: AppState
    @State private var isOpen: Bool
    @State private var isConfirmingDelete = false
    @State private var isRenaming = false
    @State private var newTitle = ""

    init(record: Record, app: AppState, startsOpen: Bool = false) {
        self.record = record
        self.app = app
        _isOpen = State(initialValue: startsOpen)
    }

    private var chops: [LibrarySample] {
        app.library.samples.filter { ($0.sample.sourceRecord ?? app.library.record(forMedia: $0.sample.media)?.id) == record.id }
    }
    private var stems: [RecordStem] { (record.stems ?? []).sorted { RecordStems.order($0.name) < RecordStems.order($1.name) } }
    private var opens: Bool { !stems.isEmpty || !chops.isEmpty }
    private var inSong: Bool {
        let media = Set([record.media] + stems.map(\.media))
        return app.song?.versions.contains { version in
            Guidance.audio(of: version).map { media.contains($0.media) || ($0.fit.map { media.contains($0.media) } ?? false) } ?? false
        } == true
    }
    private var line: String {
        if let status = app.crate.status(of: record.id) { return status }
        if let failure = app.crate.failures[record.id] { return failure }
        if record.reading == nil { return "not read yet" }
        return LibrarySidebar.recordDetail(record, stems: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 2) {
                Button { isOpen.toggle() } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(opens ? Design.Palette.inkSecondary : Design.Palette.line)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!opens)
                .accessibilityLabel(isOpen ? "Close \(record.title)" : "Open \(record.title)'s stems and chops")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(record.title)
                            .font(Design.Typography.ui(13))
                            .foregroundStyle(Design.Palette.ink)
                            .lineLimit(1)
                        if let count = record.stems?.count {
                            Glyph(name: "stems", symbol: "line.3.horizontal.decrease", size: 10)
                                .foregroundStyle(Design.Palette.inkTertiary)
                                .help("Separated: \(count) stem\(count == 1 ? "" : "s"), kept with the record")
                        }
                        if inSong {
                            Circle().fill(Design.Palette.accent).frame(width: 5, height: 5)
                                .help("The open song takes from it")
                        }
                    }
                    Text(line)
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(app.crate.failures[record.id] != nil ? Design.Palette.warn : Design.Palette.inkSecondary)
                        .lineLimit(1)
                        .help(app.crate.failures[record.id] ?? record.grid.map { "Its grid: \($0.description)." } ?? "")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if opens { isOpen.toggle() } }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 8)
            .draggable(LibraryDragPayload(kind: .record, id: record.id.rawValue, title: record.title))
            .contextMenu { menu }

            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(stems, id: \.name) { stem in
                        StemRow(stem: stem, record: record)
                            .draggable(LibraryDragPayload(kind: .stem, id: record.id.rawValue, title: Sources.label(stem: stem.name, of: record.title), stem: stem.name))
                            .contextMenu {
                                Button("Add to This Song…") { app.askForSource(AskedSource(origin: .record(record.id), stem: stem.name)) }
                                    .disabled(app.song == nil)
                            }
                    }
                    ForEach(chops) { chop in
                        HStack(spacing: 5) {
                            Glyph(name: "chop", symbol: "circle", size: 10).foregroundStyle(Design.Palette.inkTertiary)
                            Text(chop.name).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkSecondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .draggable(LibraryDragPayload(kind: .sample, id: chop.id.rawValue, title: chop.name))
                        .contextMenu {
                            Button("Adopt into This Song") { app.receive(LibraryDragPayload(kind: .sample, id: chop.id.rawValue, title: chop.name), at: .bench) }
                                .disabled(app.song == nil)
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 4)
            }
        }
        .confirmationDialog("Remove “\(record.title)” from Records?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { app.removeRecord(record.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its audio and its stems stay in the library folder, so songs made from it still play. Only the row goes.")
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { app.renameRecord(record.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new name for the record. Sources already fitted from it keep the name they were fitted under.")
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Start a Song from It") { app.flipAgain(record.id) }
            .disabled(record.reading == nil)
        Button("Add to This Song…") { app.askForSource(AskedSource(origin: .record(record.id))) }
            .disabled(app.song == nil || record.reading == nil)
        Button("Adopt the Record into This Song") { app.receive(LibraryDragPayload(kind: .record, id: record.id.rawValue, title: record.title), at: .bench) }
            .disabled(app.song == nil)
        Divider()
        if record.stems == nil {
            let holders = app.songsHoldingStems(of: record.id)
            if let holder = holders.first {
                Button("Keep \(holder.title)'s Stems with It") { app.gatherStems(of: record.id, from: holder.id) }
                    .disabled(app.crate.isQueued(.gather, for: record.id))
            }
            Button("Separate Its Stems") { app.separateRecord(record.id) }
                .disabled(app.crate.isQueued(.separate, for: record.id))
        } else {
            Button("Separate Its Stems Again") { app.separateRecord(record.id) }
                .disabled(app.crate.isQueued(.separate, for: record.id))
        }
        Button(record.reading == nil ? "Read It" : "Read It Again") { app.analyseRecord(record.id) }
            .disabled(app.crate.isQueued(.analyse, for: record.id))
        if record.readingAsRead != nil {
            Menu("Its Grid") {
                ForEach(GridMove.allCases, id: \.self) { move in
                    if move == .secondTracker, app.refusal(of: move, for: record.id) == .noSecondTracker(record.title) {
                        Button("Listen with the Second Tracker") { app.listenForSecondTracker(record.id) }
                            .disabled(app.crate.isQueued(.listen, for: record.id))
                    } else {
                        Button(gridTitle(move)) { app.correctGridAsked(record.id, move) }
                            .disabled(app.refusal(of: move, for: record.id) != nil)
                    }
                }
            }
        }
        if app.crate.status(of: record.id) != nil {
            Button("Stop") { app.crate.cancel(record.id) }
        }
        Divider()
        Button("Rename…") { newTitle = app.suggestedName(for: record.id); isRenaming = true }
        Button("Remove from Library…") { isConfirmingDelete = true }
    }

    /// The menu's words for a correction, with what it would make of the tempo.
    private func gridTitle(_ move: GridMove) -> String {
        if move == .secondTracker, record.grid?.secondTracker == true { return "The First Tracker's Grid" }
        guard move != .asRead, let now = record.reading?.dominantTempo, let read = record.readingAsRead else { return move.title }
        let next = move.applied(to: record.grid, beatsPerBar: Sources.beatsPerBar(in: record.reading ?? read))
        guard let then = read.regridded(next).dominantTempo, abs(then - now) > 0.05 else { return move.title }
        return String(format: "%@ (%.1f → %.1f bpm)", move.title, now, then)
    }
}

/// One stem of a record: its name, how much of the record it is, and where in it it plays.
private struct StemRow: View {
    let stem: RecordStem
    let record: Record

    var body: some View {
        HStack(spacing: 6) {
            Text(stem.name.capitalized)
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.ink)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
            // Fainter the less of the record it is: a stem 30 dB down draws a quarter as dark.
            StemPresence(levels: stem.barLevels ?? [], strength: stem.relativeDB.map { max(0.25, min(1, 1 + $0 / 40)) } ?? 1)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
            Text(stem.relativeDB.map { String(format: "%+.0f", $0) } ?? (stem.lufs == nil ? "—" : ""))
                .font(Design.Typography.numeric(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stem.name) stem of \(record.title), \(stem.relativeDB.map { String(format: "%.0f dB against the record", $0) } ?? "level unknown")")
    }

    private var help: String {
        var pieces = ["Drag onto the song or a section to bring it in through Sources."]
        if let relative = stem.relativeDB {
            pieces.append(String(format: "%.1f dB against the whole record%@.", relative,
                                 relative > -3 ? ": nearly all of it" : relative < -18 ? ": hardly there" : ""))
        }
        if let first = stem.barLevels.flatMap(RecordStems.firstPlayedBar) { pieces.append("It comes in at bar \(first + 1).") }
        return pieces.joined(separator: " ")
    }
}

/// A stem's level bar by bar: one tick per bar, taller where it is louder, absent where it rests.
private struct StemPresence: View {
    let levels: [Double]
    var strength: Double = 1

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else {
                context.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)), with: .color(Design.Palette.line))
                return
            }
            let loudest = max(-60, levels.max() ?? -60)
            let width = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                // The top 36 dB below its loudest bar, so a quiet stem still draws its shape.
                let share = max(0, min(1, (level - (loudest - 36)) / 36))
                guard share > 0.02 else { continue }
                let height = max(1, size.height * CGFloat(share))
                let rect = CGRect(x: CGFloat(index) * width, y: size.height - height, width: max(0.8, width - 0.4), height: height)
                context.fill(Path(rect), with: .color(Design.Palette.inkSecondary.opacity(strength)))
            }
        }
        .accessibilityHidden(true)
    }
}
