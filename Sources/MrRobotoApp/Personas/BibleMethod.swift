import Foundation

/// The method, as a function.
///
/// `PersonaBibleTests` states nineteen invariants a bible has to hold — cited over inferred, ten
/// rules with thresholds on defined features, lineages with reasons, refusals with alternatives,
/// disagreements with everyone, references that name bars, goldens that execute, open questions
/// with both readings. Those are properties of a value, and a bible that arrives as a document at
/// runtime has to be held to them too. So they are written once here, as named violations, and
/// the tests call this rather than repeating it.
public enum BibleMethod {

    /// One thing a bible gets wrong: which of the method's rules (M1…M6, in the spec's numbering)
    /// and what, precisely.
    public struct Violation: Hashable, Sendable, CustomStringConvertible {
        public var rule: String
        public var message: String
        public init(_ rule: String, _ message: String) { self.rule = rule; self.message = message }
        public var description: String { "\(rule): \(message)" }
    }

    /// The engine names a rule's action may name. Every one is a real module or type in this
    /// package; a rule that acts on nothing here is advice the app cannot take.
    public static let engineNames = ["Performance.", "Instrument.", "SongGraph.", "Analysis.", "MusicTheory.",
                                     "SourceMeasurement", "AlbumObservation.", "refuse", "clamp", "the "]

    /// Every violation, in the order the method states its rules. Empty means the bible holds.
    ///
    /// - Parameter cast: the personas this bible has to be able to disagree with. Defaults to the
    ///   shipped roster.
    public static func lint(_ bible: PersonaBible, cast: [PersonaID] = PersonaID.roster) -> [Violation] {
        var out: [Violation] = []
        let name = bible.name.isEmpty ? bible.id.rawValue : bible.name

        // M1 — cited over inferred, every mark well formed.
        if bible.claims.isEmpty { out.append(Violation("M1", "\(name) claims nothing")) }
        for claim in bible.claims where !claim.evidence.isWellFormed {
            out.append(Violation("M1", "\"\(claim.statement)\" is marked but its mark is empty"))
        }
        let cited = bible.citedClaimCount, inferred = bible.inferredClaimCount
        if cited <= inferred { out.append(Violation("M1", "\(inferred) inferred against \(cited) cited — a bible of guesses")) }
        if inferred == 0 { out.append(Violation("M1", "nothing is marked inferred, which is not credible")) }
        for url in bible.references_urls where !url.hasPrefix("https://") && !url.hasPrefix("http://") {
            out.append(Violation("M1", "\"\(url)\" is not a reference anyone can follow"))
        }

        // M2 — rules: ten or more, most with thresholds on defined, measurable features, ids namespaced.
        if bible.rules.count < 10 { out.append(Violation("M2", "\(bible.rules.count) rules is a sketch")) }
        let withThreshold = bible.rules.filter { $0.threshold != nil }
        if withThreshold.count * 2 <= bible.rules.count { out.append(Violation("M2", "fewer than half the rules are measurable")) }
        for feature in bible.undefinedThresholdFeatures {
            out.append(Violation("M2", "a rule thresholds on \(feature), which the vocabulary does not define"))
        }
        for feature in bible.unmeasurableFeatures {
            out.append(Violation("M2", "\(feature) names no engine field it is read from"))
        }
        for rule in bible.rules {
            if rule.engineAction.isEmpty { out.append(Violation("M2", "rule \(rule.id) names no engine action")) }
            else if !engineNames.contains(where: { rule.engineAction.contains($0) }) {
                out.append(Violation("M2", "rule \(rule.id) acts on \(rule.engineAction), which is nothing in the engines"))
            }
            if !rule.id.hasPrefix(bible.id.rawValue + ".") { out.append(Violation("M2", "\(rule.id) is not namespaced to \(bible.id)")) }
        }
        if Set(bible.rules.map(\.id)).count != bible.rules.count { out.append(Violation("M2", "rule ids repeat")) }

        // M3 — lineages: three or four, each with a reason; ranges belong to them, two or more each.
        if bible.lineages.count < 3 || bible.lineages.count > 4 {
            out.append(Violation("M3", "\(bible.lineages.count) lineages; the method wants three or four"))
        }
        for lineage in bible.lineages {
            if lineage.why.count <= 80 { out.append(Violation("M3", "\(lineage.name): \"why\" is too short to be a reason")) }
            if lineage.period.isEmpty { out.append(Violation("M3", "\(lineage.name) has no period")) }
        }
        let lineageNames = Set(bible.lineages.map(\.name))
        for range in bible.ranges {
            if !lineageNames.contains(range.lineage) { out.append(Violation("M3", "a range for an unknown lineage \"\(range.lineage)\"")) }
            if range.low > range.high { out.append(Violation("M3", "\(range.lineage)/\(range.feature): low above high")) }
            if let typical = range.typical, !range.contains(typical) {
                out.append(Violation("M3", "\(range.lineage)/\(range.feature): typical \(typical) is outside \(range.low)…\(range.high)"))
            }
        }
        for lineage in bible.lineages where bible.ranges.filter({ $0.lineage == lineage.name }).count < 2 {
            out.append(Violation("M3", "\(lineage.name) has fewer than two ranges — not a lineage with a sound"))
        }
        // Listening: ordered from one thing, over defined features.
        if bible.listensFor.count < 4 { out.append(Violation("M3", "it listens for \(bible.listensFor.count) things; four or more is a persona")) }
        if bible.listensFor.first?.priority != 1 { out.append(Violation("M3", "it does not start listening from one thing")) }
        if Set(bible.listensFor.map(\.priority)).count != bible.listensFor.count { out.append(Violation("M3", "listening priorities repeat")) }
        let defined = Set(bible.vocabulary.map(\.feature))
        for point in bible.listensFor {
            if point.features.isEmpty { out.append(Violation("M3", "\"\(point.what)\" reads nothing")) }
            for feature in point.features where !defined.contains(feature) {
                out.append(Violation("M3", "it listens for \(feature), which the vocabulary does not define"))
            }
        }

        // M4 — voice, refusals with alternatives, a disagreement with everyone.
        if bible.voice.examples.count < 3 { out.append(Violation("M4", "fewer than three example lines")) }
        if bible.voice.usesWords.isEmpty || bible.voice.avoidsWords.isEmpty { out.append(Violation("M4", "the voice does not say which words it uses and avoids")) }
        if bible.refusals.count < 3 { out.append(Violation("M4", "\(bible.refusals.count) refusals; three or more is a role with edges")) }
        for refusal in bible.refusals {
            if refusal.because.isEmpty { out.append(Violation("M4", "\(refusal.id) refuses without a reason")) }
            if refusal.instead.isEmpty { out.append(Violation("M4", "\(refusal.id) refuses without offering anything")) }
        }
        for other in cast where other != bible.id {
            guard let disagreement = bible.disagreement(with: other) else {
                out.append(Violation("M4", "nothing to say about the \(other)"))
                continue
            }
            if disagreement.settledBy.isEmpty { out.append(Violation("M4", "v \(other): no way to settle it")) }
            if disagreement.theirs.isEmpty { out.append(Violation("M4", "v \(other): the other side is not stated")) }
        }

        // M5 — references name bars; goldens are five or more, one pushes back, each executes.
        if bible.references.count < 4 { out.append(Violation("M5", "\(bible.references.count) references; four or more")) }
        for reference in bible.references {
            if reference.bars.isEmpty { out.append(Violation("M5", "\(reference.id): no bars — nobody can put the needle on it")) }
            if reference.listenFor.count <= 40 { out.append(Violation("M5", "\(reference.id): \"listen for\" points at nothing")) }
            if reference.features.isEmpty { out.append(Violation("M5", "\(reference.id) demonstrates no feature")) }
        }
        if bible.goldens.count < 5 { out.append(Violation("M5", "\(bible.goldens.count) goldens; five or more")) }
        if Set(bible.goldens.map(\.id)).count != bible.goldens.count { out.append(Violation("M5", "golden ids repeat")) }
        let ruleIDs = Set(bible.rules.map(\.id))
        for golden in bible.goldens {
            if golden.premise.isEmpty { out.append(Violation("M5", "\(golden.id) has no premise")) }
            if golden.passes.count <= 30 { out.append(Violation("M5", "\(golden.id): the pass criterion is not checkable")) }
            for rule in golden.exercises where !ruleIDs.contains(rule) { out.append(Violation("M5", "\(golden.id) exercises unknown rule \(rule)")) }
            if (golden.proposal == nil) != (golden.expects == nil) {
                out.append(Violation("M5", "\(golden.id) has a proposal without an expected verdict, or the reverse"))
            }
            if case .refuse(let rule)? = golden.expects, !ruleIDs.contains(rule) {
                out.append(Violation("M5", "\(golden.id) expects a refusal by unknown rule \(rule)"))
            }
        }
        // Goldens execute: a proposal the persona can be asked, and the verdict's shape. A golden
        // about a reading rather than a proposal stays prose, but they cannot be the majority.
        let executable = bible.goldens.filter { $0.proposal != nil && $0.expects != nil }.count
        if executable * 2 < bible.goldens.count {
            out.append(Violation("M5", "\(executable) of \(bible.goldens.count) goldens execute; at least half must carry a proposal and a verdict"))
        }
        if !bible.goldens.contains(where: { $0.id.hasSuffix("pushes-back") }) { out.append(Violation("M5", "no golden proves it pushes back")) }

        // M6 — open questions with both readings.
        if bible.openQuestions.count < 4 { out.append(Violation("M6", "\(bible.openQuestions.count) open questions is suspiciously confident")) }
        for question in bible.openQuestions {
            if question.encoded.isEmpty { out.append(Violation("M6", "\(question.id) does not say what it encoded")) }
            if question.alternative.count <= 60 { out.append(Violation("M6", "\(question.id): the alternative is not stated fairly enough to switch to")) }
            for rule in question.affects where !ruleIDs.contains(rule) { out.append(Violation("M6", "\(question.id) affects unknown rule \(rule)")) }
        }
        return out
    }
}

extension PersonaID {
    /// The roles the app knows, in the order they joined. A bible has to be able to disagree with
    /// every one of them but itself.
    public static let roster: [PersonaID] = [.beatmaker, .sampler, .bassist, .producer, .engineer, .peer, .lyricist]
}
