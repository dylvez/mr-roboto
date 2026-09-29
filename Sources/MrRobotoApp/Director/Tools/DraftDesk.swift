import Foundation
import SongGraph

/// What the writing tools remember of the draft before: whether it was kept, and as what.
///
/// A rewrite is the next version of the part it rewrites. The band is asked to name that part,
/// and in the first live run did not: a tune flagged for leaping was written again as a new tune,
/// so the song held both. The tool knows what it last kept, so draft 2 with no parent named,
/// straight after a draft 1 that was kept, is taken as the next version of it. Alternatives are
/// each a draft 1, and stay tunes of their own.
///
/// One desk a toolbox, which is one a session. It holds nothing a song needs: forgetting it costs
/// a duplicate part, never a note.
public actor DraftDesk {
    public enum Last: Equatable, Sendable {
        /// Kept, as this version, which was this draft.
        case kept(VersionID, draft: Int)
        /// Sent back to be written again.
        case sentBack(draft: Int)
    }

    private var last: [String: Last] = [:]

    public init() {}

    public func kept(_ version: VersionID, draft: Int, by tool: String) { last[tool] = .kept(version, draft: draft) }
    public func sentBack(draft: Int, by tool: String) { last[tool] = .sentBack(draft: draft) }

    /// The version this draft rewrites, when the draft before it was kept and no parent was named.
    public func rewritten(by tool: String, draft: Int) -> VersionID? {
        guard draft > 1, case .kept(let version, let before)? = last[tool], before == draft - 1 else { return nil }
        return version
    }
}
