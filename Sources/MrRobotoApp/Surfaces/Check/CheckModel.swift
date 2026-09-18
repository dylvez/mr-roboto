import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// MARK: - Surface identity

/// The Check surface's entry in the catalog. The second answer surface: a Check with no finding is
/// not a surface either.
public struct CheckSurface: Surface {
    public let id: SurfaceID
    public nonisolated static var kind: SurfaceKind { .check }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Check") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

// MARK: - The model

/// The Check surface's model: **one** finding, who found it, the bar, why, two fixes, and a way to
/// hear the problem.
///
/// ## One finding
///
/// Not a list. A queue of findings is a to-do list, and a to-do list is read by skimming; the whole
/// point of a check card is that you hear the thing, understand the one sentence, and make one
/// decision. Where several findings exist the frame opens several Checks, or reopens this one — the
/// bench already has rules for how many surfaces are drawn at once, and they are better rules than
/// a "3 of 7" counter would be.
///
/// ## Flags, never fixes
///
/// The critic that made this finding has already run, has already returned, and has changed nothing.
/// The only thing on this surface that alters anything is `apply(_:)`, and it takes a `Fix` that the
/// user pressed. There is no path from a `Finding` to a mutation that does not go through a click.
///
/// ## Applying one resolves it
///
/// `apply` asks the host what happened and records it. `.resolved` marks the finding resolved and
/// the card goes quiet; `.stillFires` says so and leaves the card open with the new measurement,
/// which is the honest outcome and the one a `Bool` return would have hidden. Either way the
/// finding itself is never mutated: it is a record of what a critic measured at a moment, and
/// rewriting it would destroy the only evidence the user has.
@MainActor
@Observable
public final class CheckModel {

    // MARK: Identity

    public let surfaceID: SurfaceID

    public var surface: CheckSurface {
        CheckSurface(id: surfaceID, bound: bound, title: title)
    }

    /// The version this finding is about, when it is about one.
    public let bound: [VersionID]

    /// "Slice 7's cut" — short enough for a bench chip, specific enough to tell two Checks apart.
    public var title: String {
        "\(finding.criticName): \(finding.subject.named)"
    }

    // MARK: The finding

    /// Never mutated. A finding is a record of a measurement at a moment.
    public let finding: Finding

    /// Who found it, as the card prints it: "the Sampler's transient check".
    public var attribution: String {
        "the \(finding.persona.rawValue.capitalized)'s \(finding.criticName.lowercased())"
    }

    /// The bar, as the card prints it under the headline.
    public var where_: String { finding.locus.spoken }

    /// The two fixes, in the order they should be offered.
    public var fixes: [Fix] { finding.fixes }

    // MARK: State

    /// The fix that resolved this, once one has. Nil while the finding is live.
    public private(set) var resolvedBy: Fix.ID?
    /// What the last `apply` returned. Shown verbatim on the card.
    public private(set) var lastOutcome: CheckOutcome?
    /// What is sounding: nil, `problemID`, or a fix's id.
    public private(set) var playingID: String?
    /// Set when the user said the finding is fine as it is. A dismissal is not a resolution and is
    /// kept apart from one, because "I heard it and I want it" and "I fixed it" are different facts
    /// about the part and the version note should be able to say which.
    public private(set) var isDismissed = false
    public private(set) var lastError: String?
    /// Every fix applied here, oldest first. The card's own history, and what a version note reads.
    public private(set) var applied: [Fix] = []

    /// The id `playingID` takes while the problem itself is sounding.
    public nonisolated static let problemID = "problem"

    public var isResolved: Bool { resolvedBy != nil }
    /// True while the finding still wants a decision.
    public var isOpen: Bool { !isResolved && !isDismissed }

    // MARK: Collaborators

    private weak var host: (any CheckHosting)?

    // MARK: Init

    public init(id: SurfaceID = SurfaceID(), finding: Finding, bound: [VersionID] = [],
                host: (any CheckHosting)? = nil) {
        surfaceID = id
        self.finding = finding
        self.bound = bound
        self.host = host
    }

    public func adopt(_ host: any CheckHosting) {
        self.host = host
    }

    // MARK: Hearing it

    /// Plays the stretch the finding is about, as it currently is. The card's first control, because
    /// a finding you have not heard is a finding you have to take on trust.
    public func hearProblem() {
        playingID = CheckModel.problemID
        let finding = self.finding
        Task { [host] in await host?.auditionProblem(finding) }
    }

    /// Plays what a fix would sound like, without applying it.
    public func hear(_ fix: Fix) {
        guard finding.fix(fix.id) != nil else {
            lastError = "check: \(fix.id) is not one of this finding's fixes"
            return
        }
        lastError = nil
        playingID = fix.id
        let finding = self.finding
        Task { [host] in await host?.auditionFix(fix, of: finding) }
    }

    /// Whether the host can preview this fix. A card that cannot preview says so on the button
    /// rather than playing the unfixed audio and letting you think that is the fix.
    public func canPreview(_ fix: Fix) -> Bool {
        host?.canPreview(fix) ?? false
    }

    public func stop() {
        playingID = nil
        Task { [host] in host?.stopAudition() }
    }

    public func isPlaying(_ id: String) -> Bool { playingID == id }
    public var isPlayingProblem: Bool { playingID == CheckModel.problemID }

    // MARK: Acting on it

    /// Applies a fix. The only call on this surface that changes anything, and it is only ever
    /// reached from a button.
    @discardableResult
    public func apply(_ fix: Fix) async -> CheckOutcome {
        guard finding.fix(fix.id) != nil else {
            let outcome = CheckOutcome.refused("check: \(fix.id) is not one of this finding's fixes")
            lastOutcome = outcome
            lastError = outcome.spoken
            return outcome
        }
        guard let host else {
            let outcome = CheckOutcome.refused("check: no host to apply through")
            lastOutcome = outcome
            lastError = outcome.spoken
            return outcome
        }
        let outcome = await host.apply(fix, of: finding)
        lastOutcome = outcome
        if outcome.wasApplied {
            applied.append(fix)
            lastError = nil
        } else {
            lastError = outcome.spoken
        }
        if outcome.didResolve {
            resolvedBy = fix.id
            playingID = nil
        }
        return outcome
    }

    /// "I hear it and I want it." Records the decision without pretending anything was fixed.
    public func dismiss() {
        isDismissed = true
        lastError = nil
    }

    /// Puts a dismissed card back in play. Nothing about a dismissal is destructive.
    public func reopen() {
        isDismissed = false
    }

    // MARK: What it carries out

    /// The line a version note gets when a fix was applied from here: the check, the place, the
    /// measurement, and which fix. The provenance of a correction, in one sentence, so the graph
    /// remembers that a critic was involved rather than only that a number moved.
    public var versionNote: String {
        var parts = ["\(finding.criticName) at \(finding.subject.named)"]
        parts.append(finding.measurement.description)
        if let resolvedBy, let fix = finding.fix(resolvedBy) {
            parts.append("fixed by \(fix.title.lowercased())")
        } else if isDismissed {
            parts.append("heard and kept")
        }
        return parts.joined(separator: ", ")
    }

    /// The mark the Chop lane would draw for this finding. The lane already carries `marks` and has
    /// never written one; this is the only thing that hands it any.
    public var mark: ChopLaneMark { finding.mark }
}
