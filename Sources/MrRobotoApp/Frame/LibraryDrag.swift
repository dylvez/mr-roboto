import AppKit
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
    /// Accepts library rows dropped here — dragged out of the Library surface — adopting them into
    /// the open song the way `drop` says.
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
