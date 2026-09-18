import Foundation

// The shape of a role bible, as data.
//
// The pilot bible — the Bassist — was delivered as research rather than as code, and the thing that
// made it work was not its prose. It was the method: pick two or three *named* practitioners whose
// working methods are documented, build the persona out of what they actually did, and write the
// knowledge down as measurable features and if/then rules with thresholds rather than as adjectives.
// "Plays behind the beat" is a compliment. "Snare 15–25 ms late of the click at 90 BPM, hats on the
// grid" is a rule the app can apply and a test can hold it to.
//
// So a bible here is a value, not a document. Every part of it — the lineages, the listening order,
// the rules, the feature vocabulary, the voice, the refusals, the disagreements, the reference
// tracks, the golden tests, the open questions — is a stored property that a test can walk. Two
// invariants fall out of that and are asserted in `PersonaBibleTests`:
//
//  1. **Every claim is marked.** `Evidence` has exactly two cases, cited and inferred, and there is
//     no third "unmarked" one to fall into. A claim with no URL behind it has to say so out loud.
//  2. **Every rule is applicable.** A rule's threshold names a `Feature`, and every `Feature` in the
//     vocabulary names the engine field it is measured from. A rule that cannot be expressed against
//     the groove engine, the chopper, the classifier or the degradation chain is a rule this app
//     cannot act on, and the test refuses it.

// MARK: - Identity

public struct PersonaID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }

    public static let beatmaker = PersonaID("beatmaker")
    public static let sampler = PersonaID("sampler")
    /// The pilot. Not built here — it was the research that proved the method — but named so the
    /// two bibles below can state how they disagree with it.
    public static let bassist = PersonaID("bassist")

    public var description: String { rawValue }
}

// MARK: - Evidence

/// Where a claim came from. Two cases and no third, so nothing can be asserted without saying
/// whether anybody wrote it down.
public enum Evidence: Hashable, Sendable {
    /// Backed by sources. The strings are URLs, in the order they should be read.
    case cited([String])
    /// Not in the record: derived from something that is, or from the engine's own arithmetic.
    /// The string says *what it was derived from* — never "taste", which is not a reason.
    case inferred(String)

    public static func cited(_ url: String) -> Evidence { .cited([url]) }

    public var isCited: Bool { if case .cited = self { return true }; return false }
    public var isInferred: Bool { !isCited }

    /// The URLs behind a cited claim; empty for an inferred one.
    public var references: [String] {
        if case .cited(let urls) = self { return urls }
        return []
    }

    /// A cited claim with no URL is a claim pretending to have a source.
    public var isWellFormed: Bool {
        switch self {
        case .cited(let urls): return !urls.isEmpty && urls.allSatisfy { $0.hasPrefix("http") }
        case .inferred(let basis): return !basis.isEmpty
        }
    }
}

/// Anything in a bible that asserts something about the world.
public protocol Claiming: Sendable {
    /// The assertion in one sentence, so a test failure reads as the claim rather than as an index.
    var statement: String { get }
    var evidence: Evidence { get }
}

// MARK: - The feature vocabulary

/// A measurable property of a groove or of a source. Extensible like `Idiom` and `DrumVoice`: the
/// statics are what the two shipped bibles use, and any string is legal, because a later persona
/// will measure something these two do not.
public struct Feature: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }
    public var description: String { rawValue }

    // Feel, swing and pocket — the Beatmaker's vocabulary.

    /// Swing in the figure every machine quotes: 50 straight, 66.67 triplet, 75 the MPC maximum.
    public static let swingPercent = Feature("swing.percent")
    /// The snare's constant displacement from its grid line, in milliseconds. Positive is late.
    public static let snareLagMS = Feature("pocket.snare.ms")
    /// The same for the hats. A Dilla-style feel wants this near zero while the snare moves.
    public static let hatLagMS = Feature("pocket.hat.ms")
    public static let kickLagMS = Feature("pocket.kick.ms")
    /// Spread between the earliest and latest voice displacement in a groove, in milliseconds.
    /// This is the number that *is* the drunk feel: one voice moving is a late snare, three voices
    /// moving by different amounts is a bar that leans.
    public static let pocketSpreadMS = Feature("pocket.spread.ms")
    /// Sounding steps at the ghost tier as a fraction of all sounding steps.
    public static let ghostRatio = Feature("ghost.ratio")
    /// How far the ghost tier sits under the normal tier, in dB.
    public static let ghostDepthDB = Feature("ghost.depth.db")
    /// Seeded timing jitter at its widest, in milliseconds.
    public static let humanizeTimingMS = Feature("humanize.timing.ms")
    public static let tempoBPM = Feature("tempo.bpm")
    /// Steps per beat: 4 for sixteenths, 8 for thirty-seconds, 3 for triplet eighths.
    public static let subdivision = Feature("grid.subdivision")
    /// Sounding backbeat hits per bar — how many of 2 and 4 are actually struck.
    public static let backbeatCount = Feature("backbeat.count")

    // Source, chop and degradation — the Sampler's vocabulary.

    /// Slices per bar of source.
    public static let sliceDensity = Feature("chop.density")
    /// Milliseconds a cut sits *after* the transient it was meant to capture. Positive means the
    /// attack was shaved onto the previous pad, which is the one unambiguous chopping mistake.
    public static let attackShaveMS = Feature("chop.shave.ms")
    /// How far a slice start is from the grid line nearest it, in milliseconds.
    public static let gridDeviationMS = Feature("chop.deviation.ms")
    /// Quantiser width in bits. 12 is both the SP-1200 and the MPC60; 24 and up is off.
    public static let bitDepth = Feature("degrade.bits")
    /// The rate the decimator holds to, in Hz.
    public static let holdRateHz = Feature("degrade.rate.hz")
    /// Frequency below which 95% of the source's energy already sits, in Hz.
    public static let bandwidthHz = Feature("source.bandwidth.hz")
    /// Peak level of the quietest sounding slice, in dBFS.
    public static let sliceFloorDB = Feature("source.slice.floor.db")
    /// Loudest slice minus quietest slice of the same class, in dB.
    public static let sliceSpreadDB = Feature("source.slice.spread.db")
    /// Peak pitch deviation of the wow oscillator as a percentage.
    public static let wowPercent = Feature("degrade.wow.percent")
    /// Crackle events per second.
    public static let crackleDensity = Feature("degrade.crackle.hz")
    /// Linear gain into the saturation curve.
    public static let drive = Feature("degrade.drive")
}

/// What a feature *is*, where it is measured from, and how small a change is worth mentioning.
///
/// `engineField` is load-bearing. It names a real property of a real type in `Performance`,
/// `Instrument` or `Analysis`, and `PersonaBibleTests` asserts that every feature a rule thresholds
/// on has one. That is the mechanical form of "a rule that cannot be expressed against those is a
/// rule the app cannot apply".
public struct FeatureDefinition: Claiming, Hashable, Sendable {
    public var feature: Feature
    /// "MPC swing percent", "milliseconds, positive = late".
    public var unit: String
    /// One sentence: what it measures and why anybody cares.
    public var meaning: String
    /// The engine property it is read from: `Groove.swing`, `VoiceFeel.timingOffset`,
    /// `Slice.snapOffset`, `DegradeSettings.bitDepth`.
    public var engineField: String
    /// The smallest change worth marking as a difference. Compare uses this to decide whether two
    /// candidates differ on a feature or merely have different floating-point noise.
    public var noticeable: Double
    public var evidence: Evidence

    public init(_ feature: Feature, unit: String, meaning: String, engineField: String,
                noticeable: Double, evidence: Evidence) {
        self.feature = feature
        self.unit = unit
        self.meaning = meaning
        self.engineField = engineField
        self.noticeable = noticeable
        self.evidence = evidence
    }

    public var statement: String { "\(feature) is \(meaning), read from \(engineField), in \(unit)" }
}

/// One lineage's typical range for one feature. This is the "feature vocabulary with typical ranges
/// per lineage" the method asks for, and the reason a persona can say "that is a trap number in a
/// boom-bap groove" instead of "that feels wrong".
public struct FeatureRange: Claiming, Hashable, Sendable {
    public var feature: Feature
    /// The lineage this range belongs to, by `Lineage.name`.
    public var lineage: String
    public var low: Double
    public var high: Double
    /// Where inside the range this lineage actually lives, when the record says.
    public var typical: Double?
    public var evidence: Evidence

    public init(_ feature: Feature, lineage: String, _ low: Double, _ high: Double,
                typical: Double? = nil, evidence: Evidence) {
        self.feature = feature
        self.lineage = lineage
        self.low = min(low, high)
        self.high = max(low, high)
        self.typical = typical
        self.evidence = evidence
    }

    public func contains(_ value: Double) -> Bool { value >= low && value <= high }

    public var statement: String {
        "\(lineage): \(feature) runs \(format(low))–\(format(high))"
            + (typical.map { ", typically \(format($0))" } ?? "")
    }

    private func format(_ x: Double) -> String { String(format: "%.4g", x) }
}

// MARK: - Lineage

/// A named practitioner, machine or record the persona descends from, and why they were chosen.
///
/// "Why" is not decoration: it is the thing that makes a lineage falsifiable. A lineage picked
/// because the working method is documented can be checked against the documentation; a lineage
/// picked because the music is good cannot be checked against anything.
public struct Lineage: Claiming, Hashable, Sendable, Identifiable {
    public var name: String
    /// The machine or medium the method was worked out on, when one is central to it.
    public var instrument: String?
    /// Roughly when — enough to date the practice, not a biography.
    public var period: String
    /// Why this one and not another: what is documented about how they worked.
    public var why: String
    public var evidence: Evidence

    public var id: String { name }

    public init(_ name: String, instrument: String? = nil, period: String, why: String,
                evidence: Evidence) {
        self.name = name
        self.instrument = instrument
        self.period = period
        self.why = why
        self.evidence = evidence
    }

    public var statement: String { "\(name) (\(period)): \(why)" }
}

// MARK: - Listening

/// What the persona checks first, and in what order. The order is the persona: two personas given
/// the same eight bars notice different things, and which one they notice *first* is what makes
/// them argue.
public struct ListeningPoint: Hashable, Sendable, Identifiable {
    /// 1 is what it hears before anything else.
    public var priority: Int
    /// "Where the snare sits against the hats."
    public var what: String
    /// The features it reads to answer that.
    public var features: [Feature]

    public var id: Int { priority }

    public init(_ priority: Int, _ what: String, features: [Feature]) {
        self.priority = priority
        self.what = what
        self.features = features
    }
}

// MARK: - Rules

/// A threshold with a direction, over one feature. The comparison is the rule's teeth.
public struct Threshold: Hashable, Sendable, CustomStringConvertible {
    public enum Comparison: String, Hashable, Sendable, CaseIterable {
        case atLeast, atMost, between, outside, equalTo
    }

    public var feature: Feature
    public var comparison: Comparison
    public var value: Double
    /// The upper bound for `between` and `outside`.
    public var upper: Double?
    public var unit: String

    public init(_ feature: Feature, _ comparison: Comparison, _ value: Double,
                upper: Double? = nil, unit: String) {
        self.feature = feature
        self.comparison = comparison
        self.value = value
        self.upper = upper
        self.unit = unit
    }

    public static func atLeast(_ feature: Feature, _ value: Double, unit: String) -> Threshold {
        Threshold(feature, .atLeast, value, unit: unit)
    }

    public static func atMost(_ feature: Feature, _ value: Double, unit: String) -> Threshold {
        Threshold(feature, .atMost, value, unit: unit)
    }

    public static func between(_ feature: Feature, _ low: Double, _ high: Double, unit: String) -> Threshold {
        Threshold(feature, .between, low, upper: high, unit: unit)
    }

    public static func outside(_ feature: Feature, _ low: Double, _ high: Double, unit: String) -> Threshold {
        Threshold(feature, .outside, low, upper: high, unit: unit)
    }

    /// Whether a measured value satisfies this threshold.
    public func holds(for measured: Double) -> Bool {
        switch comparison {
        case .atLeast: return measured >= value
        case .atMost: return measured <= value
        case .between: return measured >= value && measured <= (upper ?? value)
        case .outside: return measured < value || measured > (upper ?? value)
        case .equalTo: return abs(measured - value) < 1e-9
        }
    }

    public var description: String {
        let v = String(format: "%.4g", value)
        let u = String(format: "%.4g", upper ?? value)
        switch comparison {
        case .atLeast: return "\(feature) ≥ \(v) \(unit)"
        case .atMost: return "\(feature) ≤ \(v) \(unit)"
        case .between: return "\(feature) in \(v)…\(u) \(unit)"
        case .outside: return "\(feature) outside \(v)…\(u) \(unit)"
        case .equalTo: return "\(feature) = \(v) \(unit)"
        }
    }
}

/// One if/then with a measurable condition.
///
/// `when` and `then` are the sentences the persona says; `threshold` is the arithmetic behind the
/// `when`, and `engineAction` is the arithmetic behind the `then` — the engine property the rule
/// would move, named so a reader can check the rule is not advice the app cannot take.
public struct PersonaRule: Claiming, Hashable, Sendable, Identifiable {
    public var id: String
    /// "The source's own onsets already sit 18 ms behind the sixteenths."
    public var when: String
    /// "Leave the groove straight; the swing is already in the audio."
    public var then: String
    /// The measurable form of `when`. Nil only for a rule that is genuinely categorical
    /// (a meter, a preset name), and `PersonaBibleTests` counts those.
    public var threshold: Threshold?
    /// What the rule would actually move: `Groove.swing`, `VoiceFeel.timingOffset` for `.snare`,
    /// `DegradeSettings.bitDepth`. The proof the rule is applicable.
    public var engineAction: String
    public var evidence: Evidence

    public init(_ id: String, when: String, then: String, threshold: Threshold? = nil,
                engineAction: String, evidence: Evidence) {
        self.id = id
        self.when = when
        self.then = then
        self.threshold = threshold
        self.engineAction = engineAction
        self.evidence = evidence
    }

    public var statement: String { "if \(when) then \(then)" }

    /// The rule as the persona would say it, threshold included.
    public var spoken: String {
        guard let threshold else { return "If \(when), \(then)." }
        return "If \(when) (\(threshold)), \(then)."
    }
}

// MARK: - Voice and refusal

/// How the persona talks. Written down rather than left to a prompt, because "terse" and "warm"
/// produce the same text from a model unless you give it the shape of a sentence.
public struct PersonaVoice: Hashable, Sendable {
    /// One line: the register.
    public var register: String
    /// The shape of a sentence it makes: "measurement, then verdict, then the one thing to try."
    public var sentenceShape: String
    /// Words it uses, because they mean something here.
    public var usesWords: [String]
    /// Words it will not use, because they mean nothing.
    public var avoidsWords: [String]
    /// Three lines it would actually say, for a reader and for a prompt.
    public var examples: [String]

    public init(register: String, sentenceShape: String, usesWords: [String],
                avoidsWords: [String], examples: [String]) {
        self.register = register
        self.sentenceShape = sentenceShape
        self.usesWords = usesWords
        self.avoidsWords = avoidsWords
        self.examples = examples
    }
}

/// Something the persona will not do, and what it offers instead.
///
/// A refusal is not a safety rail. It is the edge of the persona's competence written down: a
/// Beatmaker asked to pick a sample has nothing useful to say, and a persona that answers anyway is
/// a persona nobody can trust on the things it does know.
public struct Refusal: Hashable, Sendable, Identifiable {
    public var id: String
    /// What it will not do.
    public var refuses: String
    /// Why not, in one sentence.
    public var because: String
    /// Who to ask instead, or what to do instead.
    public var instead: String

    public init(_ id: String, refuses: String, because: String, instead: String) {
        self.id = id
        self.refuses = refuses
        self.because = because
        self.instead = instead
    }
}

/// Where this persona and another one pull in opposite directions, and how the argument is settled.
///
/// Every persona in the cast gets an entry, including ones not built yet, because the disagreement
/// is a property of the role rather than of the implementation.
public struct PersonaDisagreement: Hashable, Sendable, Identifiable {
    public var with: PersonaID
    /// What they fight about.
    public var about: String
    /// This persona's position.
    public var position: String
    /// Theirs, stated fairly.
    public var theirs: String
    /// What decides it: a measurement, or a stated rule about who wins.
    public var settledBy: String

    public var id: String { with.rawValue }

    public init(with: PersonaID, about: String, position: String, theirs: String, settledBy: String) {
        self.with = with
        self.about = about
        self.position = position
        self.theirs = theirs
        self.settledBy = settledBy
    }
}

// MARK: - References and tests

/// A record that demonstrates a rule, down to the bars.
///
/// Bars, not "that track" — the whole value of a reference is that two people can put the needle in
/// the same place and hear the same thing.
public struct ReferenceTrack: Claiming, Hashable, Sendable, Identifiable {
    public var title: String
    public var artist: String
    public var release: String?
    public var year: Int?
    /// "bars 1–4", "the intro, first 8 bars", "0:42–0:50".
    public var bars: String
    /// What to listen for there, in one sentence.
    public var listenFor: String
    /// The features it demonstrates.
    public var features: [Feature]
    public var evidence: Evidence

    public var id: String { "\(artist) — \(title) (\(bars))" }

    public init(_ title: String, artist: String, release: String? = nil, year: Int? = nil,
                bars: String, listenFor: String, features: [Feature], evidence: Evidence) {
        self.title = title
        self.artist = artist
        self.release = release
        self.year = year
        self.bars = bars
        self.listenFor = listenFor
        self.features = features
        self.evidence = evidence
    }

    public var statement: String { "\(artist), \"\(title)\", \(bars): \(listenFor)" }
}

/// A golden test as the bible states it, before anybody writes the Swift.
///
/// Carried as data on purpose. The test file asserts each of these *and* asserts that every golden
/// declared here has a test with the matching id, so a golden cannot be written down and quietly
/// left unimplemented.
public struct GoldenTest: Hashable, Sendable, Identifiable {
    public var id: String
    /// What is put in front of the persona.
    public var premise: String
    /// What has to be true of its answer. One sentence, checkable.
    public var passes: String
    /// The rules this exercises.
    public var exercises: [String]

    public init(_ id: String, premise: String, passes: String, exercises: [String] = []) {
        self.id = id
        self.premise = premise
        self.passes = passes
        self.exercises = exercises
    }
}

/// Somewhere the sources disagree, or are silent, and the bible had to choose.
///
/// This is the part of the method most easily skipped and the part that makes the rest usable: a
/// rule with a known-contested basis is a rule you can revisit when better evidence turns up, and
/// a rule that looks equally confident as every other one is not.
public struct OpenQuestion: Claiming, Hashable, Sendable, Identifiable {
    public var id: String
    /// The question.
    public var question: String
    /// What the bible decided to encode, and why that one.
    public var encoded: String
    /// The other reading, stated fairly enough that flipping to it is a small edit.
    public var alternative: String
    /// Which rules would change if the alternative won.
    public var affects: [String]
    public var evidence: Evidence

    public init(_ id: String, question: String, encoded: String, alternative: String,
                affects: [String] = [], evidence: Evidence) {
        self.id = id
        self.question = question
        self.encoded = encoded
        self.alternative = alternative
        self.affects = affects
        self.evidence = evidence
    }

    public var statement: String { question }
}

// MARK: - House calls

/// A decision the user made on one of a bible's open questions — by ear, not by citation.
///
/// Kept apart from `Evidence` on purpose. Evidence says why a claim is *true*; a house call says
/// what this house *plays*, which is a different kind of statement and must never be passed off as
/// the first. So the research a bible encodes stays exactly as written, and a persona reading a
/// part consults the house call to decide what it approves of — saying both: what the record
/// says, and what the house chose.
public struct HouseCall: Hashable, Sendable, Identifiable {
    /// The open question this settles, e.g. `beatmaker.oq.snare-direction`.
    public var question: String
    /// Which reading won: the one the bible encoded, or its stated alternative.
    public enum Choice: String, Hashable, Sendable { case encoded, alternative }
    public var choice: Choice
    /// How it was decided, in a sentence a person would say.
    public var how: String
    public var decidedOn: String

    public var id: String { question }

    public init(question: String, choice: Choice, how: String, decidedOn: String) {
        self.question = question
        self.choice = choice
        self.how = how
        self.decidedOn = decidedOn
    }
}

// MARK: - The bible

/// Everything a persona knows, as data.
public struct PersonaBible: Sendable {
    public var id: PersonaID
    /// What a user calls it: "Beatmaker".
    public var name: String
    /// One sentence: what this persona owns and nothing more.
    public var owns: String
    public var lineages: [Lineage]
    /// In priority order. `listensFor.first` is what it hears before anything else.
    public var listensFor: [ListeningPoint]
    public var vocabulary: [FeatureDefinition]
    public var ranges: [FeatureRange]
    public var rules: [PersonaRule]
    public var voice: PersonaVoice
    public var refusals: [Refusal]
    public var disagreements: [PersonaDisagreement]
    public var references: [ReferenceTrack]
    public var goldens: [GoldenTest]
    public var openQuestions: [OpenQuestion]

    public init(id: PersonaID, name: String, owns: String, lineages: [Lineage],
                listensFor: [ListeningPoint], vocabulary: [FeatureDefinition],
                ranges: [FeatureRange], rules: [PersonaRule], voice: PersonaVoice,
                refusals: [Refusal], disagreements: [PersonaDisagreement],
                references: [ReferenceTrack], goldens: [GoldenTest],
                openQuestions: [OpenQuestion]) {
        self.id = id
        self.name = name
        self.owns = owns
        self.lineages = lineages
        self.listensFor = listensFor.sorted { $0.priority < $1.priority }
        self.vocabulary = vocabulary
        self.ranges = ranges
        self.rules = rules
        self.voice = voice
        self.refusals = refusals
        self.disagreements = disagreements
        self.references = references
        self.goldens = goldens
        self.openQuestions = openQuestions
    }

    // MARK: Lookup

    public func rule(_ id: String) -> PersonaRule? { rules.first { $0.id == id } }
    public func golden(_ id: String) -> GoldenTest? { goldens.first { $0.id == id } }
    public func definition(of feature: Feature) -> FeatureDefinition? {
        vocabulary.first { $0.feature == feature }
    }

    public func range(_ feature: Feature, lineage: String) -> FeatureRange? {
        ranges.first { $0.feature == feature && $0.lineage == lineage }
    }

    public func ranges(for feature: Feature) -> [FeatureRange] {
        ranges.filter { $0.feature == feature }
    }

    public func disagreement(with other: PersonaID) -> PersonaDisagreement? {
        disagreements.first { $0.with == other }
    }

    /// How big a change in `feature` is worth marking. Falls back to zero — every difference is
    /// worth marking — rather than to a guess, for a feature nobody defined.
    public func noticeable(_ feature: Feature) -> Double {
        definition(of: feature)?.noticeable ?? 0
    }

    // MARK: Invariants

    /// Everything in the bible that asserts something, in one list, so a test can walk them all.
    public var claims: [any Claiming] {
        var all: [any Claiming] = []
        all.append(contentsOf: lineages as [any Claiming])
        all.append(contentsOf: vocabulary as [any Claiming])
        all.append(contentsOf: ranges as [any Claiming])
        all.append(contentsOf: rules as [any Claiming])
        all.append(contentsOf: references as [any Claiming])
        all.append(contentsOf: openQuestions as [any Claiming])
        return all
    }

    /// Features a rule thresholds on but the vocabulary never defines. Empty is the invariant.
    public var undefinedThresholdFeatures: [Feature] {
        let defined = Set(vocabulary.map(\.feature))
        return rules.compactMap(\.threshold).map(\.feature).filter { !defined.contains($0) }
    }

    /// Features defined without naming an engine field they are read from. Empty is the invariant:
    /// a feature the engine cannot measure is a feature the app cannot act on.
    public var unmeasurableFeatures: [Feature] {
        vocabulary.filter { $0.engineField.isEmpty }.map(\.feature)
    }

    public var citedClaimCount: Int { claims.filter { $0.evidence.isCited }.count }
    public var inferredClaimCount: Int { claims.filter { $0.evidence.isInferred }.count }

    /// Every URL the bible leans on, deduplicated, in first-mention order.
    public var references_urls: [String] {
        var seen: [String] = []
        for claim in claims {
            for url in claim.evidence.references where !seen.contains(url) { seen.append(url) }
        }
        return seen
    }
}

// MARK: - The persona itself

/// A persona: a bible, plus the one thing a bible cannot be — an opinion about a specific proposal.
///
/// Deliberately not generic over what it reads. The two personas read different things (a groove
/// and a source), so their reading methods are their own and typed; what they share is the bible
/// and the ability to be argued with, which is what the Director and the Compare surface need.
public protocol Persona: Sendable {
    var bible: PersonaBible { get }

    /// What it thinks of a specific idea. This is where a persona earns the name: an idea that
    /// breaks one of its rules comes back refused, with the measurement and something to try
    /// instead, rather than being carried out.
    func consider(_ proposal: PersonaProposal) -> PersonaVerdict
}

extension Persona {
    public var id: PersonaID { bible.id }
    public var name: String { bible.name }
}

// MARK: - Proposals and verdicts

/// An idea put to a persona, in the vocabulary of things this app can actually do.
///
/// Every case names engine parameters rather than intentions, which is the point: "make it swing
/// more" is not a proposal a persona can check, and `setSwing(percent: 72, idiom: .trap, tempo: 142)`
/// is. The Director's job is to turn what a user said into one of these.
public enum PersonaProposal: Hashable, Sendable {
    /// Set the groove's swing, in MPC percent, in a stated idiom at a stated tempo.
    case setSwing(percent: Double, idiom: String, tempo: Double)
    /// Displace one voice by a constant offset, in milliseconds (positive = late), at a tempo.
    case displaceVoice(voice: String, milliseconds: Double, tempo: Double)
    /// Flatten everything onto the grid: no swing, no displacement, no jitter.
    case quantiseHard(idiom: String)
    /// Widen the seeded timing jitter to this many milliseconds at its widest.
    case setHumanizeTiming(milliseconds: Double, tempo: Double)
    /// Strip the ghost notes out of a groove that has this many, as a fraction of its hits.
    case removeGhosts(currentRatio: Double, idiom: String)
    /// Cut this many slices out of one bar.
    case chopDensity(slicesPerBar: Int, sourceTransients: Int)
    /// Move a cut this many milliseconds later than the transient it was taken from.
    case moveCutLate(milliseconds: Double)
    /// Put a named degradation preset on a source whose own bandwidth and noise floor are known.
    case applyDegrade(preset: String, sourceBandwidthHz: Double, sourceNoiseFloorDB: Double)
    /// Stack a second degradation pass on a source that already went through one.
    case stackDegrade(first: String, second: String)
    /// Leave the source alone.
    case leaveAlone(sourceBandwidthHz: Double)
    /// Something outside the persona's competence, named so the refusal can be specific.
    case outOfScope(what: String)
}

/// What a persona thinks of a proposal.
public enum PersonaVerdict: Hashable, Sendable {
    /// Do it. The string is the one line it says while doing it.
    case agree(String)
    /// Do it, but know this. The persona does not block; it marks.
    case agreeWithCaveat(String, caveat: String)
    /// No — with the rule that says no, the measurement that tripped it, and something else to try.
    ///
    /// `counter` is not optional. A persona that refuses without offering an alternative is an
    /// obstacle, and the pilot bible's whole argument is that a role is only useful when it can be
    /// argued with productively.
    case refuse(rule: String, because: String, counter: String)
    /// Not my department.
    case defer_(to: PersonaID, because: String)

    public var isRefusal: Bool { if case .refuse = self { return true }; return false }
    public var isAgreement: Bool {
        switch self {
        case .agree, .agreeWithCaveat: return true
        case .refuse, .defer_: return false
        }
    }

    /// The rule id behind a refusal, for a test that wants to name which rule pushed back.
    public var refusedByRule: String? {
        if case .refuse(let rule, _, _) = self { return rule }
        return nil
    }

    /// The line the persona actually says, whatever the verdict.
    public var spoken: String {
        switch self {
        case .agree(let line): return line
        case .agreeWithCaveat(let line, let caveat): return "\(line) \(caveat)"
        case .refuse(_, let because, let counter): return "\(because) \(counter)"
        case .defer_(let to, let because): return "\(because) Ask the \(to)."
        }
    }
}
