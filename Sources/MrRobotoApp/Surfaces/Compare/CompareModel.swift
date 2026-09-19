import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// MARK: - Surface identity

/// The Compare surface's entry in the catalog.
///
/// One of the two answer surfaces: you do not pick it off a shelf, because a Compare with nothing to
/// compare is not a surface, it is an empty promise. The Director opens it with the candidates
/// already in it.
public struct CompareSurface: Surface {
    public let id: SurfaceID
    public nonisolated static var kind: SurfaceKind { .compare }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Compare") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

/// What went wrong, in the surface's own words.
public enum CompareError: Error, CustomStringConvertible, Equatable {
    case notEnoughCandidates(Int)
    case tooManyCandidates(Int)
    case tooManyLevers(Int)
    case unknownCandidate(String)

    public var description: String {
        switch self {
        case .notEnoughCandidates(let n):
            return "compare: \(n) candidate\(n == 1 ? "" : "s") — a comparison needs at least two"
        case .tooManyCandidates(let n):
            return "compare: \(n) candidates — four is the most a row-wise comparison stays readable at"
        case .tooManyLevers(let n):
            return "compare: \(n) levers — the surface takes at most two"
        case .unknownCandidate(let id):
            return "compare: no candidate called \(id)"
        }
    }
}

// MARK: - The model

/// The Compare surface's model: two to four candidates as rows, the thing they are judged against
/// at the top, the differences marked, and at most two levers.
///
/// ## What this surface is for
///
/// Choosing, not editing. Everything about it is bent towards one question — *is any of these better
/// than what I already have* — and the four constraints in its contract are all defences of that
/// question:
///
/// * **The reference stays visible.** It is a stored property, not a candidate, and there is no code
///   path that selects it. A comparison against a remembered original is not a comparison.
/// * **Two to four rows.** Below two there is nothing to compare; above four the rows stop being
///   scannable at the sizes a surface is actually drawn in and the eye starts comparing pairs
///   instead of the set. `init` refuses both, rather than trusting whatever filled it.
/// * **Differences are marked, not left to be read.** Every cell knows its own reference value and
///   whether the gap is bigger than the smallest change anybody would hear — and that threshold
///   comes from a persona's feature vocabulary rather than from this file.
/// * **At most two levers, applied to every row.** A lever that moved one candidate would make the
///   comparison unfair; five levers would make it a second editor. Both are refused in `init`.
///
/// ## Plays on touch
///
/// Selecting a row plays it. Moving a lever re-plays whatever is already playing, immediately, with
/// the lever's new value — no agent, no round trip, no rebuild. That is the Komma lesson applied to
/// the surface that most needs it: the whole value of a Compare is in the first five seconds of each
/// row, and a comparison you have to imagine is not one.
@MainActor
@Observable
public final class CompareModel {

    // MARK: Identity

    public let surfaceID: SurfaceID

    public var surface: CompareSurface {
        CompareSurface(id: surfaceID, bound: boundVersions, title: title)
    }

    /// "Three feels for bar 9" — what the question was, not what the answers are.
    public private(set) var title: String

    /// Versions this comparison touches: the reference's, plus every candidate that carries one.
    public var boundVersions: [VersionID] {
        var ids: [VersionID] = []
        if let reference = reference.version { ids.append(reference) }
        ids.append(contentsOf: candidates.compactMap { $0.version?.id })
        return ids
    }

    // MARK: What is being compared

    /// Always visible, never selectable.
    public private(set) var reference: CompareReference

    /// Two to four, in the order they are drawn.
    public private(set) var candidates: [CompareCandidate]

    /// The columns: what the candidates are judged on, in the order a persona listens for them.
    public private(set) var features: [Feature]

    /// Where the "smallest change worth marking" figures come from. A bible rather than a constant,
    /// because what counts as a difference in swing is a fact about hearing that this app already
    /// writes down in exactly one place.
    public var vocabulary: PersonaBible

    // MARK: The levers

    public private(set) var levers: [CompareLever]
    public private(set) var leverValues: [CompareLever: Double]

    // MARK: State

    /// The row the user has picked. Nil until they pick one; never the reference.
    public private(set) var selectedID: CompareCandidate.ID?
    /// What is sounding. Nil for silence; `referenceID` while the reference is playing.
    public private(set) var playingID: String?
    /// The candidate committed by `choose`, once a host has taken it.
    public private(set) var chosenID: CompareCandidate.ID?
    public private(set) var lastError: String?

    /// The id `playingID` takes while the reference is sounding.
    public nonisolated static let referenceID = "reference"

    // MARK: Collaborators

    private weak var host: (any CompareHosting)?

    // MARK: Init

    /// - Throws: `CompareError` when the shape of the comparison breaks the contract. Throwing
    ///   rather than clamping on purpose: a Director that filled a Compare with one candidate has
    ///   made a mistake, and silently drawing a one-row table would hide it.
    public init(id: SurfaceID = SurfaceID(), title: String,
                reference: CompareReference, candidates: [CompareCandidate],
                features: [Feature], levers: [CompareLever] = [],
                vocabulary: PersonaBible = Beatmaker.bible,
                host: (any CompareHosting)? = nil) throws {
        guard candidates.count >= CompareModel.minimumCandidates else {
            throw CompareError.notEnoughCandidates(candidates.count)
        }
        guard candidates.count <= CompareModel.maximumCandidates else {
            throw CompareError.tooManyCandidates(candidates.count)
        }
        guard levers.count <= CompareModel.maximumLevers else {
            throw CompareError.tooManyLevers(levers.count)
        }
        surfaceID = id
        self.title = title
        self.reference = reference
        self.candidates = candidates
        self.features = features
        self.levers = levers
        self.vocabulary = vocabulary
        self.host = host
        leverValues = Dictionary(uniqueKeysWithValues: levers.map { ($0, $0.defaultValue) })
    }

    /// Below this there is nothing to compare.
    public nonisolated static let minimumCandidates = 2
    /// Above this the rows stop being scannable at 640 points of width.
    public nonisolated static let maximumCandidates = 4
    /// The surface's own contract.
    public nonisolated static let maximumLevers = 2

    public func adopt(_ host: any CompareHosting) {
        self.host = host
    }

    // MARK: Reading

    public func candidate(_ id: CompareCandidate.ID) -> CompareCandidate? {
        candidates.first { $0.id == id }
    }

    public var selected: CompareCandidate? { selectedID.flatMap(candidate) }

    /// Every feature's difference between one candidate and the reference, in column order.
    ///
    /// A feature the reference does not carry is skipped rather than compared against zero: "this
    /// candidate has a swing and the thing it is replacing does not" is a real situation and
    /// printing "+58%" for it would be a lie about the size of the change.
    public func differences(for id: CompareCandidate.ID) -> [CompareDifference] {
        guard let candidate = candidate(id) else { return [] }
        return features.compactMap { feature in
            guard let mine = candidate.reading(feature),
                  let theirs = reference.reading(feature) else { return nil }
            return CompareDifference(feature: feature,
                                     reference: theirs.value,
                                     candidate: mine.value,
                                     unit: mine.unit,
                                     noticeable: vocabulary.noticeable(feature))
        }
    }

    /// The difference on one feature, or nil when either side does not carry it.
    public func difference(_ feature: Feature, for id: CompareCandidate.ID) -> CompareDifference? {
        differences(for: id).first { $0.feature == feature }
    }

    /// True when this candidate differs from the reference on anything that would be heard.
    ///
    /// The test the surface exists to pass: two rows that read the same are two rows that should not
    /// both be here.
    public func differs(_ id: CompareCandidate.ID) -> Bool {
        differences(for: id).contains { $0.matters }
    }

    /// Candidates that are indistinguishable from the reference on every compared feature. A
    /// Director that produced one of these has offered a choice that is not a choice, and the
    /// surface says so rather than drawing it as if it were.
    ///
    /// A candidate that shares no measured feature with the reference — two personas' readings
    /// against a section, say — is not "the same"; it is uncompared, and it is left out here.
    public var indistinguishable: [CompareCandidate] {
        candidates.filter { !differences(for: $0.id).isEmpty && !differs($0.id) }
    }

    /// Warnings across every candidate, so the header can say "two of these have findings".
    public var findingCount: Int {
        candidates.reduce(0) { $0 + $1.warnings.count }
    }

    // MARK: Choosing

    /// Picks a row and plays it. Selecting *is* auditioning — this is the surface where that matters
    /// most, because a row you have not heard is a row you cannot judge.
    public func select(_ id: CompareCandidate.ID) {
        guard candidate(id) != nil else {
            lastError = CompareError.unknownCandidate(id).description
            return
        }
        lastError = nil
        selectedID = id
        audition(id)
    }

    /// Commits the selected candidate. The only thing on this surface that leaves it.
    @discardableResult
    public func choose(_ id: CompareCandidate.ID) async -> Bool {
        guard let candidate = candidate(id) else {
            lastError = CompareError.unknownCandidate(id).description
            return false
        }
        guard let host else {
            lastError = "compare: no host to commit through"
            return false
        }
        let taken = await host.choose(candidate)
        if taken {
            chosenID = id
            selectedID = id
            lastError = nil
        } else {
            lastError = "compare: the host would not take \(candidate.title)"
        }
        return taken
    }

    // MARK: Playing

    /// Plays one candidate under the current levers.
    public func audition(_ id: CompareCandidate.ID) {
        guard let candidate = candidate(id) else {
            lastError = CompareError.unknownCandidate(id).description
            return
        }
        playingID = id
        let levers = leverValues
        Task { [host] in await host?.audition(candidate, levers: levers) }
    }

    /// Plays the reference. Never selects it.
    public func auditionReference() {
        playingID = CompareModel.referenceID
        let levers = leverValues
        let reference = self.reference
        Task { [host] in await host?.auditionReference(reference, levers: levers) }
    }

    public func stop() {
        playingID = nil
        Task { [host] in host?.stopAudition() }
    }

    public func isPlaying(_ id: CompareCandidate.ID) -> Bool { playingID == id }
    public var isPlayingReference: Bool { playingID == CompareModel.referenceID }

    // MARK: Levers

    public func value(of lever: CompareLever) -> Double {
        leverValues[lever] ?? lever.defaultValue
    }

    /// Moves a lever and re-plays whatever is sounding, immediately, with the new value.
    ///
    /// This is "two speeds" in three lines: the lever runs locally against the engine at engine
    /// speed, and the agent is not involved. Nothing is committed, nothing is rebuilt, and if
    /// nothing is playing then nothing is played — moving a lever on a silent surface should not
    /// start noise.
    public func setLever(_ lever: CompareLever, to value: Double) {
        guard levers.contains(lever) else { return }
        leverValues[lever] = lever.clamp(value)
        guard let playing = playingID else { return }
        if playing == CompareModel.referenceID {
            auditionReference()
        } else {
            audition(playing)
        }
    }

    /// Puts every lever back where it started, without touching what is playing.
    public func resetLevers() {
        for lever in levers { leverValues[lever] = lever.defaultValue }
        if let playing = playingID {
            if playing == CompareModel.referenceID { auditionReference() } else { audition(playing) }
        }
    }

    // MARK: Editing the comparison

    /// Replaces a candidate in place — what a re-audition after a lever move commits, and what the
    /// Director does when a critic's fix produced a better version of one row.
    public func replace(_ candidate: CompareCandidate) {
        guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        candidates[index] = candidate
    }

    /// Attaches critic findings to the rows they belong to. The Compare surface never runs a critic
    /// and never acts on a finding; it shows that one exists and lets a Check open on it.
    public func attach(_ findings: [Finding], to id: CompareCandidate.ID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].findings = findings
    }

    public func rename(_ newTitle: String) { title = newTitle }
}
