import Foundation
import Instrument
import Performance

/// A genre profile held to the bibles' method: every claim marked, cited over inferred, numbers on
/// features a persona measures, and nothing named that the app does not have.
public enum GenreMethod {

    public struct Violation: Hashable, Sendable, CustomStringConvertible {
        public var rule: String
        public var message: String
        public init(_ rule: String, _ message: String) { self.rule = rule; self.message = message }
        public var description: String { "\(rule): \(message)" }
    }

    /// Every feature a shipped persona measures: the only features a genre may put a number on,
    /// because a number on anything else is a number nobody reads.
    public static var features: Set<Feature> {
        Set(Cast.standard.personas.flatMap { $0.bible.vocabulary.map(\.feature) })
    }

    public static let areas: Set<String> = ["groove", "form", "harmony", "bass", "arrangement", "sound", "mix", "melody", "lyrics"]

    /// Every violation; empty means the profile holds.
    public static func lint(_ profile: GenreProfile, feels: FeelLibrary = .standard) -> [Violation] {
        var out: [Violation] = []
        let name = profile.name

        // G1 — identity.
        if profile.id.isEmpty || profile.id != profile.id.lowercased() || profile.id.contains(" ") {
            out.append(Violation("G1", "\"\(profile.id)\" is not a lowercase, hyphenated id"))
        }
        if profile.summary.count < 40 { out.append(Violation("G1", "\(name)'s summary says nothing")) }

        // G2 — evidence: every mark well formed, cited over inferred, something admitted.
        let evidence = profile.evidence
        for mark in evidence where !mark.isWellFormed { out.append(Violation("G2", "\(name) has an empty evidence mark")) }
        let cited = evidence.filter(\.isCited).count, inferred = evidence.count - cited
        if cited <= inferred { out.append(Violation("G2", "\(name): \(inferred) inferred against \(cited) cited")) }
        if inferred == 0 { out.append(Violation("G2", "\(name) marks nothing inferred, which is not credible")) }

        // G3 — ranges: on measured features, once each, in order, the tempo among them.
        let known = features
        var seen = Set<Feature>()
        for range in profile.ranges {
            if !known.contains(range.feature) { out.append(Violation("G3", "\(name) ranges \(range.feature), which no persona measures")) }
            else if !GenreLens.judges(range.feature) { out.append(Violation("G3", "\(name) ranges \(range.feature), which is the same in every genre")) }
            if !seen.insert(range.feature).inserted { out.append(Violation("G3", "\(name) ranges \(range.feature) twice")) }
            if let typical = range.typical, !range.contains(typical) {
                out.append(Violation("G3", "\(name)'s typical \(range.feature) \(typical) is outside its own range"))
            }
            if !range.low.isFinite || !range.high.isFinite { out.append(Violation("G3", "\(name)'s \(range.feature) is not a number")) }
        }
        if profile.tempo == nil { out.append(Violation("G3", "\(name) states no tempo range")) }

        // G4 — nothing named that the app does not have.
        for feel in profile.feels where feels.feel(named: feel) == nil {
            out.append(Violation("G4", "\(name) names the feel \"\(feel)\", which the library does not have"))
        }
        for hand in profile.bassHands where BassLineage(rawValue: hand) == nil {
            out.append(Violation("G4", "\(name) names bass hands \"\(hand)\", which the writer does not have"))
        }
        let machines = Set(SynthMachine.all.map(\.id)), basses = Set(BassVoiceSpec.all.map(\.id))
        let instruments = Set(InstrumentVoiceSpec.all.map(\.id))
        for id in profile.sounds.machines where !machines.contains(id) { out.append(Violation("G4", "\(name) names the machine \"\(id)\"")) }
        for id in profile.sounds.bass where !basses.contains(id) { out.append(Violation("G4", "\(name) names the bass \"\(id)\"")) }
        for id in profile.sounds.instruments where !instruments.contains(id) { out.append(Violation("G4", "\(name) names the instrument \"\(id)\"")) }

        // G5 — enough to be a profile rather than a label.
        if profile.notes.count < 6 { out.append(Violation("G5", "\(name) has \(profile.notes.count) notes")) }
        for note in profile.notes where !areas.contains(note.area) {
            out.append(Violation("G5", "\(name) files a note under \"\(note.area)\""))
        }
        if profile.lineages.count < 2 { out.append(Violation("G5", "\(name) names \(profile.lineages.count) lineages")) }
        if profile.references.count < 3 { out.append(Violation("G5", "\(name) cites \(profile.references.count) records")) }
        for form in [profile.form].compactMap({ $0 }) where form.sections.contains(where: { $0.bars <= 0 }) {
            out.append(Violation("G5", "\(name)'s form has a section with no bars"))
        }
        return out
    }
}
