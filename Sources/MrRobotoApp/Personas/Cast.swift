import Foundation
import SongGraph

/// The personas the app ships, and the one call a Director needs to put a question to all of them.
///
/// A value rather than a singleton, for the same reason `FeelLibrary` and `CriticBoard` are: a
/// project with a different cast holds its own, and the shipped one stays diffable code.
///
/// ## What this is for
///
/// The Director's job is to turn what a user said into a `PersonaProposal` and to open a surface
/// with the answer. `ask` is the whole of the personas' side of that: it puts one proposal to every
/// persona and returns what each said, so a Director that has produced a bad idea gets a refusal
/// with a counter rather than a silent failure, and a Director that has produced a question outside
/// everybody's competence gets two deferrals and knows to say so.
///
/// Nothing here knows the Director exists, and nothing here is async. A persona's opinion is a pure
/// function of a proposal.
public struct Cast: Sendable {
    public var personas: [any Persona]

    public init(_ personas: [any Persona]) {
        self.personas = personas
    }

    /// Everything the app ships. Order is the order answers come back in.
    public static let standard = Cast([Beatmaker(), Sampler(), Bassist(), Producer(), Engineer(), Peer(), Lyricist()])

    public func persona(_ id: PersonaID) -> (any Persona)? {
        personas.first { $0.bible.id == id }
    }

    /// The personas in the room for a song: this cast filtered by the song's own list. A song with
    /// no list, or an empty one, has everyone.
    public func inRoom(for song: Song?) -> Cast {
        guard let ids = song?.cast, !ids.isEmpty else { return self }
        return Cast(personas.filter { ids.contains($0.bible.id.rawValue) })
    }

    public var ids: [PersonaID] { personas.map(\.bible.id) }

    /// This cast with a document-only persona added for every bible that is not already a member.
    public func adding(_ bibles: [PersonaBible]) -> Cast {
        var out = personas
        for bible in bibles where !out.contains(where: { $0.bible.id == bible.id }) {
            out.append(DocumentPersona(bible: bible))
        }
        return Cast(out)
    }

    public var bibles: [PersonaBible] { personas.map(\.bible) }

    /// What each persona thinks of one proposal, in cast order.
    public func ask(_ proposal: PersonaProposal) -> [(persona: PersonaID, verdict: PersonaVerdict)] {
        personas.map { ($0.bible.id, $0.consider(proposal)) }
    }

    /// The persona whose competence a proposal falls in: the one that does not defer it.
    ///
    /// Nil when everybody deferred, which is a real answer and the one a Director most needs — it
    /// means the question was not one this cast can take, and the honest reply is to say so rather
    /// than to pick whoever answered first.
    public func owner(of proposal: PersonaProposal) -> PersonaID? {
        ask(proposal).first { verdict in
            if case .defer_ = verdict.verdict { return false }
            return true
        }?.persona
    }

    /// Refusals only. What a Director has to surface before acting.
    public func objections(to proposal: PersonaProposal)
        -> [(persona: PersonaID, verdict: PersonaVerdict)] {
        ask(proposal).filter { $0.verdict.isRefusal }
    }
}

// MARK: - What the Director owes the personas

/// What a Director must be able to do with a persona's answer.
///
/// Declared here rather than in `Director/` because it is the personas' side of the seam: this is
/// the shape the cast expects to be driven through, and it is deliberately four calls with no
/// model, no network and no async in the reading half.
///
/// **This protocol has no conformer yet.** The Director orchestrator is being built alongside these
/// files, and nothing here names it. When it lands, conforming to this is the whole integration:
/// `Cast.standard` and `CriticBoard.standard` supply the answers, and the Director supplies the
/// surfaces they are drawn on.
public protocol PersonaDirecting: Sendable {
    /// Turn what a user said into a proposal the cast can check. The one genuinely model-shaped
    /// step, and the only place a string becomes a decision.
    func proposal(for utterance: String) async throws -> PersonaProposal

    /// Open a Compare with these candidates. Returns the surface's id so the Director can pin it.
    @MainActor
    func openCompare(title: String, reference: CompareReference,
                     candidates: [CompareCandidate], features: [Feature],
                     levers: [CompareLever]) throws -> SurfaceID

    /// Open a Check on one finding. One finding per surface, by the surface's own contract.
    @MainActor
    func openCheck(_ finding: Finding) -> SurfaceID

    /// Draw a critic's findings as marks on whatever surface they belong to, without acting on
    /// them. The catalog's "flags, never fixes" rule, at the seam where it is easiest to break.
    @MainActor
    func mark(_ findings: [Finding], on surface: SurfaceID)
}
