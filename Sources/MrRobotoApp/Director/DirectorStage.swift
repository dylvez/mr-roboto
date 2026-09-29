import Foundation
import SongGraph

// The second seam between the Director and the app.
//
// `DirectorWorkspace` is what the *tools* read and write: the song, the library, the store. It was
// deliberately written without the three things B3 needs, and its own comment says which — opening a
// surface, the proposals array, and the engine — because adding them then would have meant editing
// `AppState` for a Director that did not exist yet.
//
// This is that second seam, now that it does. It names four things and no more: what kind of part a
// version is, whether the frame could open an action, how to open one, and how to say a line in the
// rail. Everything the Director needs to choose a surface and nothing it could use to reach past the
// frame into a surface's own state.

/// What the Director must know about the frame to choose a surface it can actually open.
@MainActor
public protocol DirectorStage: AnyObject, Sendable {

    /// What kind of part a version is, or nil when the open song does not hold it.
    ///
    /// This is how rule 1 is checked. "Answer in the notation the question is about" is only
    /// meaningful if the frame can say what notation a version is in.
    func partType(of id: VersionID) -> PartType?

    /// The frame's own gate, unchanged. Gate A filters its derived proposals through this; the
    /// Director's choices go through the same one rather than through a copy written for them.
    func canPerform(_ action: SurfaceAction) -> Bool

    /// Opens a validated choice and returns the surface it landed on, or nil if the frame declined.
    ///
    /// Opening happens *during* the turn rather than after it. A Compare that appears twenty
    /// seconds after you pressed return is a Compare you waited twenty seconds for; a Chop lane that
    /// appears the moment the bar is cut is the instrument answering while it works. The bench holds
    /// one surface of each kind, so a second Grid turns the first rather than piling up beside it;
    /// how many one answer may open is the pad's rule (`DirectorStagePad.maximumOpens`).
    @discardableResult
    func open(_ choice: DirectorSurfaceChoice) -> SurfaceID?

    /// How many surfaces are on the bench right now.
    var openSurfaceCount: Int { get }

    /// One line in the conversation rail, attributed.
    func say(_ source: SessionEntry.Source, _ text: String, detail: String?)

    /// Replaces what the rail offers. Emptied at the start of a turn so a stale proposal from the
    /// last answer is never clickable beside a new one.
    func setProposals(_ proposals: [Proposal])
}

// MARK: - The real one

/// `AppState` seen through the five things the Director needs to choose a surface.
///
/// An adapter rather than a conformance, for the same reason `AppStateWorkspace` is one: a
/// retroactive `Sendable` conformance declared outside the file that owns the class is a Swift 6
/// warning and a future error. Five forwarding lines, and the list of them is the list of what the
/// Director is allowed to do to the frame.
@MainActor
public final class AppStateStage: DirectorStage {
    private let app: AppState

    public init(_ app: AppState) { self.app = app }

    public func partType(of id: VersionID) -> PartType? { app.version(id)?.type }

    public func canPerform(_ action: SurfaceAction) -> Bool { app.canPerform(action) }

    @discardableResult
    public func open(_ choice: DirectorSurfaceChoice) -> SurfaceID? {
        // The levers ride on the action, so this is the same call the rail makes when you press a
        // proposal — one path to the bench, not two.
        app.perform(choice.action)
    }

    public var openSurfaceCount: Int { app.bench.items.count }

    public func say(_ source: SessionEntry.Source, _ text: String, detail: String?) {
        app.note(source, text, detail: detail)
    }

    public func setProposals(_ proposals: [Proposal]) { app.director = proposals }
}

// MARK: - What one turn chose

/// The choices and proposals of the turn in flight.
///
/// An actor because the tool loop runs every call in a turn concurrently: two `open_surface` calls
/// in one round would otherwise race on the same array. It is also where rule 3 is counted: one
/// answer opens three surfaces at most, because a fourth is an answer nobody reads to the end of.
public actor DirectorStagePad {
    /// What this turn opened, in the order it opened them.
    public private(set) var opened: [DirectorSurfaceChoice] = []
    /// What this turn offered.
    public private(set) var proposals: [DirectorProposal] = []

    public init() {}

    /// How many surfaces one answer may open: three is evidence beside a choice; more is an
    /// answer that should have been said in words.
    public static let maximumOpens = 3

    /// Starts a turn. Called before the first request, never during one.
    /// Told as each surface lands, so the rail can show it arriving rather than at the end.
    private var onOpen: (@Sendable (DirectorSurfaceChoice) -> Void)?

    public func begin(onOpen: (@Sendable (DirectorSurfaceChoice) -> Void)? = nil) {
        opened = []
        proposals = []
        self.onOpen = onOpen
    }

    /// Records an opened surface, or says why this turn may not open another.
    public func record(_ choice: DirectorSurfaceChoice) throws {
        guard opened.count < Self.maximumOpens else {
            throw DirectorChoiceProblem(
                "This answer has already opened \(opened.count) surfaces, which is as many as one answer opens.",
                suggestion: "Say the rest in words, or propose it instead of opening it.")
        }
        opened.append(choice)
        onOpen?(choice)
    }

    public func record(_ proposal: DirectorProposal) {
        proposals.append(proposal)
    }

    /// Everything the rail should offer after this turn.
    public var offeredProposals: [Proposal] { proposals.map(\.proposal) }
}
