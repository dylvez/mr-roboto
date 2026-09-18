import Foundation
import Performance
import SongGraph

// What an answer surface holds that the song graph does not.
//
// The four Gate A surfaces are built entirely out of the binding: a Grid opened on a groove version
// *is* that groove, and nothing else is needed to draw it. The two answer surfaces are not like
// that, and neither of them can be, for the same reason both exist:
//
//  * a **Compare** is a question — "is any of these better than what I already have" — and the
//    question is not in the graph. The candidates are versions, but which one is the reference, what
//    features they are being judged on, who proposed each one and why, and what the levers move are
//    all properties of the *comparison*, made by whoever asked it.
//  * a **Check** is a measurement. A `Finding` carries the critic, the persona, the locus, the
//    arithmetic and the two fixes; a version id carries none of that.
//
// So both are filed here, beside `AppState.bindings` and `AppState.surfaceLevers`, which already
// hold the two other things `BenchItem` deliberately does not carry. The lifetime is the bench's
// own: an answer is forgotten exactly when its surface is closed or retired.

/// The content of an answer surface.
public enum SurfaceAnswer: Sendable {

    /// A comparison somebody asked: the reference, the candidates, and what they are judged on.
    case compare(CompareBrief)

    /// One critic's finding, whole — the measurement, the locus and the two fixes.
    case check(Finding)

    /// A Check the Director opened with a sentence rather than with a critic behind it.
    ///
    /// `open_surface` takes `finding` as prose, because the model is saying what *it* noticed and no
    /// critic ran. That is a real thing to show and a different thing from a `Finding`, so it is a
    /// different case: the card draws the sentence and does not print arithmetic nobody measured or
    /// offer fixes nobody wrote. Inventing a `Measurement` here to reuse the critic's card would be
    /// the app lying about where a number came from.
    case stated(String)
}

/// Everything the Compare surface needs that the binding cannot say.
///
/// `PersonaDirecting.openCompare` takes exactly these five, so the conformer files what it was
/// handed rather than reconstructing it, and `SurfaceWiring` builds the model from one value.
public struct CompareBrief: Sendable {
    /// "Three feels for bar 9" — the question, not the answers.
    public var title: String
    public var reference: CompareReference
    public var candidates: [CompareCandidate]
    public var features: [Feature]
    public var levers: [CompareLever]
    /// Where "the smallest change worth marking" comes from. The persona whose question this is.
    public var vocabulary: PersonaBible

    public init(title: String, reference: CompareReference, candidates: [CompareCandidate],
                features: [Feature], levers: [CompareLever] = [],
                vocabulary: PersonaBible = Beatmaker.bible) {
        self.title = title
        self.reference = reference
        self.candidates = candidates
        self.features = features
        self.levers = levers
        self.vocabulary = vocabulary
    }

    /// What the frame binds the surface to, reference first — the same order `DirectorFill` produces
    /// and the same one `SurfaceWiring` reads back when no brief was filed.
    public var bound: [VersionID] {
        var ids: [VersionID] = []
        if let reference = reference.version { ids.append(reference) }
        ids.append(contentsOf: candidates.compactMap { $0.version?.id })
        return ids
    }
}
