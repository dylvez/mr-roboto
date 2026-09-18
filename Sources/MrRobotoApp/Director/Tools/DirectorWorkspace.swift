import Foundation
import SongGraph

// The seam between the Director and the app's own state.
//
// `AppState` is the frame's, not the Director's, and the Director must not be the reason it grows
// a method. So the tools talk to this protocol instead, which names exactly the six things they
// need; `AppState` already has all six, so its conformance below is empty.
//
// What this protocol deliberately does not have, and what the Director will need later:
//   - opening a surface (`openSurface(_:title:bound:)`) — B3's job, when the Director starts
//     choosing a surface rather than filling one.
//   - the shared audio engine (`engine()`), for auditioning through the real rig rather than
//     through the `DirectorAudition` seam below.
//   - `director: [Proposal]`, the array the conversation rail already renders.
// None of those are added here, because adding them means editing `AppState`.

/// Everything the tool layer reads from, and writes to, in the running app.
@MainActor
public protocol DirectorWorkspace: AnyObject, Sendable {
    /// The open song, or nil when nothing is open.
    var song: Song? { get }
    /// The library as last read from disk.
    var library: Library { get }
    /// Where media is written. Nil in tests and previews, and the tools say so rather than crash.
    var store: LibraryStore? { get }

    func version(_ id: VersionID) -> PartVersion?

    /// Appends a version to the open song. False when there is no song to append to.
    @discardableResult
    func record(_ version: PartVersion) -> Bool

    /// Replaces the open song's sections. False when there is no song.
    @discardableResult
    func arrange(_ sections: [Section]) -> Bool

    /// A line in the conversation rail.
    func note(_ text: String, detail: String?)
}

/// `AppState` seen through the six things the Director needs.
///
/// A one-line `extension AppState: DirectorWorkspace {}` would do — `AppState` already has every
/// member — but it would be a retroactive `Sendable` conformance declared outside the file that
/// owns the class, which Swift 6 warns about and a future language mode makes an error. An adapter
/// costs six forwarding lines and says out loud what the Director is allowed to touch.
@MainActor
public final class AppStateWorkspace: DirectorWorkspace {
    private let app: AppState

    public init(_ app: AppState) { self.app = app }

    public var song: Song? { app.song }
    public var library: Library { app.library }
    public var store: LibraryStore? { app.store }

    public func version(_ id: VersionID) -> PartVersion? { app.version(id) }

    @discardableResult
    public func record(_ version: PartVersion) -> Bool { app.record(version) }

    @discardableResult
    public func arrange(_ sections: [Section]) -> Bool { app.arrange(sections) }

    public func note(_ text: String, detail: String?) { app.note(.session, text, detail: detail) }
}

/// Something that can make a noise. Kept separate from the workspace because on this machine —
/// and on any CI box — there is no output device, and the honest answer is a sentence rather than
/// a thrown error.
@MainActor
public protocol DirectorAudition: AnyObject, Sendable {
    /// Plays a rendered performance. Returns what happened, for the tool's own result.
    func audition(_ request: DirectorAuditionRequest) async -> DirectorAuditionOutcome
}

/// What to play. Small structured data, like everything else here: the performance is on the
/// workbench, and this names it.
public struct DirectorAuditionRequest: Sendable, Equatable {
    /// A workbench handle: a groove, or a chop played across its pads.
    public var handle: String
    public var bars: Int
    public var tempo: Double

    public init(handle: String, bars: Int, tempo: Double) {
        self.handle = handle
        self.bars = bars
        self.tempo = tempo
    }
}

/// Whether it played, and what to say if it did not.
public struct DirectorAuditionOutcome: Sendable, Equatable, Codable {
    public var played: Bool
    public var detail: String

    public init(played: Bool, detail: String) {
        self.played = played
        self.detail = detail
    }

    /// The answer on a machine with no audio device, which is most automated ones.
    public static let silent = DirectorAuditionOutcome(
        played: false,
        detail: "There is no audio output on this machine, so nothing was played. Everything else about the groove is still true.")
}

/// A workspace with nothing behind it: a song held in memory, no library directory, notes kept in
/// an array. Tests use this, and so does anything that wants the tool layer without the frame.
@MainActor
public final class DirectorScratchWorkspace: DirectorWorkspace {
    public private(set) var song: Song?
    public private(set) var library: Library
    public let store: LibraryStore?
    /// Every line the tools wrote, in order.
    public private(set) var notes: [(text: String, detail: String?)] = []

    public init(song: Song? = nil, library: Library = Library(), store: LibraryStore? = nil) {
        self.song = song
        self.library = library
        self.store = store
    }

    public func version(_ id: VersionID) -> PartVersion? {
        song?.version(id) ?? library.ideas.first { $0.id == id }
    }

    @discardableResult
    public func record(_ version: PartVersion) -> Bool {
        guard var current = song else { return false }
        do {
            try current.append(version)
            song = current
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func arrange(_ sections: [Section]) -> Bool {
        guard song != nil else { return false }
        song?.sections = sections
        return true
    }

    public func note(_ text: String, detail: String?) {
        notes.append((text, detail))
    }
}
