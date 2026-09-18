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

/// The library, always on screen. Ideas, songs, albums, imported records, samples — everything the
/// session can draw on, and anything in it can be dragged into a surface.
struct LibrarySidebar: View {
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SmallLabel("Library")
                Spacer()
                ChipButton(systemImage: "arrow.clockwise", help: "Re-read the library directory",
                           isEnabled: app.store != nil) {
                    app.reloadLibrary()
                }
                CollapseButton(region: .library, app: app)
            }
            .padding(.horizontal, Design.Metric.inset)
            .frame(height: FrameLayout.headerHeight)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .failed(let url, let reason) = app.libraryStatus {
                        EmptyNote(title: "The library could not be read.",
                                  detail: "\(url.path)\n\(reason)")
                    } else if app.library.isEmpty {
                        emptyState
                    } else {
                        group("Ideas", app.library.ideas.map {
                            Row(payload: LibraryDragPayload(kind: .idea, id: $0.id.rawValue,
                                                            title: $0.type.rawValue.capitalized),
                                title: $0.type.rawValue.capitalized,
                                detail: $0.operation)
                        })
                        group("Songs", app.library.songs.map { song in
                            Row(payload: LibraryDragPayload(kind: .song, id: song.id.rawValue, title: song.title),
                                title: song.title,
                                detail: songDetail(song),
                                isSelected: app.song?.id == song.id,
                                opens: song.id)
                        })
                        group("Albums", app.library.albums.map {
                            Row(payload: LibraryDragPayload(kind: .album, id: $0.id.rawValue, title: $0.title),
                                title: $0.title,
                                detail: "\($0.songs.count) song\($0.songs.count == 1 ? "" : "s")")
                        })
                        group("Records", app.library.records.map {
                            Row(payload: LibraryDragPayload(kind: .record, id: $0.id.rawValue, title: $0.title),
                                title: $0.title,
                                detail: $0.artist.isEmpty ? $0.media.fileExtension.uppercased() : $0.artist)
                        })
                        group("Samples", app.library.samples.map {
                            Row(payload: LibraryDragPayload(kind: .sample, id: $0.id.rawValue, title: $0.name),
                                title: $0.name,
                                detail: $0.tags.joined(separator: " · "))
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
        if !song.sections.isEmpty { pieces.append("\(song.sections.count) sections") }
        return pieces.joined(separator: " · ")
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
    private func group(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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

    /// One draggable line in the sidebar. Data only — the view is `RowView` — so the row can be
    /// built inside `body` without dragging main-actor isolation into an `Identifiable` conformance.
    struct Row: Identifiable, Sendable {
        let payload: LibraryDragPayload
        let title: String
        var detail: String = ""
        var isSelected: Bool = false
        /// Set for songs: the one library row that opens something in Gate A.
        var opens: SongID?

        var id: UUID { payload.id }
    }

    struct RowView: View {
        let row: Row
        let app: AppState

        var body: some View {
            Button {
                if let id = row.opens { app.openSong(id) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(Design.Typography.ui(13, weight: row.isSelected ? .semibold : .regular))
                        .foregroundStyle(row.isSelected ? Design.Palette.accent : Design.Palette.ink)
                        .lineLimit(1)
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
            .disabled(row.opens == nil)
            .draggable(row.payload)
        }
    }
}
