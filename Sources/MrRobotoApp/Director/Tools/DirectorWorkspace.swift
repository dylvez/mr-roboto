import Foundation
import Performance
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

    /// Brings a library item into the open song as a version. Nil, with a line in the rail, when
    /// it cannot be.
    @discardableResult
    func adopt(_ payload: LibraryDragPayload) -> VersionID?

    /// Carries a merge move out on a version: audio rendered into the song's package, a written
    /// part moved by arithmetic, recorded as a version derived from the original. An untouched move
    /// returns the version itself.
    func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion

    /// A line in the conversation rail.
    func note(_ text: String, detail: String?)

    // M4: the room.

    /// Who the song has in the room. Empty means everyone.
    var castIDs: [PersonaID] { get }
    /// Sets the song's cast. False when there is no song.
    @discardableResult
    func setCast(_ ids: [PersonaID]) -> Bool
    /// The house voice the Lyricist reads against.
    var voice: LyricCorpus { get }
    /// A line in the rail in a persona's own name.
    func speak(_ persona: String, _ text: String, detail: String?)
    /// A section of the song bounced offline and metered, for the Engineer. Nil when this
    /// workspace has nothing to render with.
    func bounce(section: SectionID?) async throws -> MixObservation?
    /// Opens a Compare of two personas' readings that disagree. Returns the surface's title, or
    /// nil when this workspace has no bench.
    func openDisagreement(_ card: DisagreementCard) -> String?
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

    @discardableResult
    public func adopt(_ payload: LibraryDragPayload) -> VersionID? { app.adopt(payload) }

    public func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion {
        try await MergeAdapter(app: app, service: SurfaceWiring.shared.service(for: app)).render(version, move: move)
    }

    public func note(_ text: String, detail: String?) { app.note(.session, text, detail: detail) }

    public var castIDs: [PersonaID] { (app.song?.cast ?? []).map { PersonaID($0) } }

    @discardableResult
    public func setCast(_ ids: [PersonaID]) -> Bool { app.setCast(ids) }

    public var voice: LyricCorpus { app.voice }

    public func speak(_ persona: String, _ text: String, detail: String?) { app.note(.persona(persona), text, detail: detail) }

    public func bounce(section: SectionID?) async throws -> MixObservation? {
        let plan = app.playback
        guard plan.isPlayable else { return nil }
        let stems = try await SectionBounce.render(plan, section: section, kitsDirectory: AuditionService.defaultKitsDirectory)
        return stems.observation
    }

    public func openDisagreement(_ card: DisagreementCard) -> String? {
        let id = app.openSurface(.compare, title: card.title, bound: card.reference.map { [$0] } ?? [])
        app.file(.compare(card.brief), for: id)
        return card.title
    }
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

    /// Nothing behind it: an idea can be adopted from the library it was given, a sample or a
    /// record cannot (there is no package to copy media into).
    @discardableResult
    public func adopt(_ payload: LibraryDragPayload) -> VersionID? {
        guard song != nil, payload.kind == .idea,
              let idea = library.ideas.first(where: { $0.id.rawValue == payload.id }) else { return nil }
        let version = PartVersion(partID: PartID(), kind: idea.kind, author: idea.author,
                                  operation: Operation.adopted, note: "from idea: \(idea.note ?? "")")
        return record(version) ? version.id : nil
    }

    /// Written parts move by arithmetic here; audio needs a package, which this workspace has not.
    public func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion {
        guard move.movesPitch || move.movesTime else { return version }
        let moved: PartKind
        switch version.kind {
        case .bassline(let line): moved = .bassline(MergeRender.bassline(line, move: move))
        case .progression(let p): moved = .progression(MergeRender.progression(p, move: move))
        case .groove: return version
        default: throw DirectorToolFailure(tool: "merge", reason: "This workspace has nowhere to render audio into.")
        }
        let derived = version.deriving(moved, by: .user, operation: Operation.merge, note: move.sentence)
        return record(derived) ? derived : version
    }

    public func note(_ text: String, detail: String?) {
        notes.append((text, detail))
    }

    public var castIDs: [PersonaID] { (song?.cast ?? []).map { PersonaID($0) } }

    @discardableResult
    public func setCast(_ ids: [PersonaID]) -> Bool {
        guard song != nil else { return false }
        song?.cast = ids.isEmpty ? nil : ids.map(\.rawValue)
        return true
    }

    public var voice: LyricCorpus { LyricCorpus(library.voice ?? []) }

    /// Every line a persona spoke, in order.
    public private(set) var spoken: [(persona: String, text: String, detail: String?)] = []

    public func speak(_ persona: String, _ text: String, detail: String?) { spoken.append((persona, text, detail)) }

    /// Nothing to render with.
    public func bounce(section: SectionID?) async throws -> MixObservation? { nil }

    /// Every card a convening opened.
    public private(set) var disagreements: [DisagreementCard] = []

    public func openDisagreement(_ card: DisagreementCard) -> String? {
        disagreements.append(card)
        return card.title
    }
}
