import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// What the Check surface needs from whatever is hosting it.
//
// Same shape as the Gate A surfaces' hosts: a small protocol the surface names instead of naming
// `AppState`, so the surface is buildable before the Director lands and testable afterwards with no
// audio device. Four capabilities.

/// What the Check surface needs from its host.
///
/// The protocol is shaped around the catalog's fourth rule — **flags, never fixes**. Note what is
/// *not* here: there is no call a critic can make. `apply` takes an `EngineChange` and is only ever
/// reached from `CheckModel.apply(_:)`, which is only ever reached from a button. A finding arrives
/// on this surface having changed nothing, and leaves having changed nothing unless somebody
/// pressed a fix.
///
/// The two audition calls are separate on purpose. Hearing the problem and hearing what a fix would
/// sound like are different questions, and a surface that only offered the first would be asking you
/// to choose between two fixes you have not heard.
@MainActor
public protocol CheckHosting: AnyObject {
    /// Play the stretch of audio the finding is about, as it currently is.
    func auditionProblem(_ finding: Finding) async

    /// Play the same stretch as it would be with `fix` applied — **without applying it**. A host
    /// that cannot preview a particular change should play the problem instead and say so through
    /// `canPreview(_:)`; silently playing the unfixed version would be a lie.
    func auditionFix(_ fix: Fix, of finding: Finding) async

    /// Whether this host can render a preview of that change. Defaults to true.
    func canPreview(_ fix: Fix) -> Bool

    func stopAudition()

    /// Apply the change and say what happened. The only call on this surface that alters anything,
    /// and it exists at the end of a chain that starts with a click.
    func apply(_ fix: Fix, of finding: Finding) async -> CheckOutcome
}

extension CheckHosting {
    public func canPreview(_ fix: Fix) -> Bool { true }
}

/// What came back from applying a fix.
///
/// Three cases, and the middle one is why this is an enum rather than a `Bool`. A fix that was
/// applied and did not resolve the finding is the interesting outcome — it means the critic's own
/// measurement is still tripping, and the surface has to say so rather than closing the card and
/// letting the user believe it is dealt with.
public enum CheckOutcome: Hashable, Sendable {
    /// Applied, and the critic no longer fires.
    case resolved
    /// Applied, and the critic still fires — with what it now measures.
    case stillFires(Measurement)
    /// Not applied. The string is the host's reason, shown verbatim.
    case refused(String)

    public var didResolve: Bool { self == .resolved }

    public var wasApplied: Bool {
        switch self {
        case .resolved, .stillFires: return true
        case .refused: return false
        }
    }

    /// One line for the card.
    public var spoken: String {
        switch self {
        case .resolved: return "Fixed. The check no longer fires."
        case .stillFires(let measurement):
            return "Applied, but the check still fires: \(measurement)."
        case .refused(let reason): return reason
        }
    }
}
