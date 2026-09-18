import Foundation
import Instrument

/// A proposal, measured: the features it moves and their values, plus the lineage it names, when
/// it names one. One table from `PersonaProposal` to feature–value pairs, so any bible can be
/// asked about any proposal in its own vocabulary.
public struct ProposalMeasures: Hashable, Sendable {
    public var values: [Feature: Double]
    /// The lineage the proposal is in, when it says — a bible's own range for that lineage stands
    /// in for a rule's general threshold.
    public var lineage: String?

    public init(values: [Feature: Double] = [:], lineage: String? = nil) {
        self.values = values
        self.lineage = lineage
    }

    public static func of(_ proposal: PersonaProposal) -> ProposalMeasures {
        switch proposal {
        case .setSwing(let percent, _, let tempo):
            return ProposalMeasures(values: [.swingPercent: percent, .tempoBPM: tempo])
        case .displaceVoice(let voice, let milliseconds, let tempo):
            let feature: Feature
            switch voice.lowercased() {
            case "snare": feature = .snareLagMS
            case "kick": feature = .kickLagMS
            default: feature = .hatLagMS
            }
            return ProposalMeasures(values: [feature: milliseconds, .pocketSpreadMS: abs(milliseconds), .tempoBPM: tempo])
        case .quantiseHard:
            return ProposalMeasures(values: [.swingPercent: 50, .humanizeTimingMS: 0, .pocketSpreadMS: 0, .ghostRatio: 0])
        case .setHumanizeTiming(let milliseconds, let tempo):
            return ProposalMeasures(values: [.humanizeTimingMS: milliseconds, .tempoBPM: tempo])
        case .removeGhosts:
            return ProposalMeasures(values: [.ghostRatio: 0])
        case .chopDensity(let slicesPerBar, _):
            return ProposalMeasures(values: [.sliceDensity: Double(slicesPerBar)])
        case .moveCutLate(let milliseconds):
            return ProposalMeasures(values: [.attackShaveMS: milliseconds])
        case .applyDegrade(let preset, let bandwidth, _):
            var values: [Feature: Double] = [:]
            if let named = DegradeSettings.Preset(rawValue: preset) {
                let settings = DegradeSettings(preset: named)
                values[.bitDepth] = settings.bitDepth
                values[.holdRateHz] = settings.targetSampleRate
                // Hz of the source above the chain's corner: negative when the corner is above it.
                values[.bandwidthHz] = settings.highCut > 0 ? settings.highCut - bandwidth : -bandwidth
            }
            return ProposalMeasures(values: values)
        case .stackDegrade:
            return ProposalMeasures(values: [.bitDepth: 2 * DegradeSettings.bitDepthOff])
        case .leaveAlone(let bandwidth):
            return ProposalMeasures(values: [.bandwidthHz: -bandwidth])
        case .writeBassline(let lineage, let lagMS, let tempo, let hatLagMS, let kickLagMS, let kickDecaySeconds, let sound):
            return ProposalMeasures(values: [.bassKickOffsetMS: lagMS, .bassMaxOffsetMS: abs(lagMS), .tempoBPM: tempo,
                                             .referenceLagMS: max(abs(hatLagMS), abs(kickLagMS)),
                                             .kickDecaySeconds: kickDecaySeconds, .bassIsSub: sound == "sub" ? 1 : 0],
                                    lineage: lineage)
        case .pushBassAhead(let milliseconds, _):
            return ProposalMeasures(values: [.bassKickOffsetMS: -abs(milliseconds), .bassMaxOffsetMS: abs(milliseconds)])
        case .sustainUnder808(let sound, let kickDecaySeconds):
            return ProposalMeasures(values: [.kickDecaySeconds: kickDecaySeconds, .bassIsSub: sound == "sub" ? 1 : 0])
        case .transposeSample(_, let semitones):
            return ProposalMeasures(values: [.transposeSemitones: Double(abs(semitones))])
        case .mergeSources(let drumSources, _):
            return ProposalMeasures(values: [.drumSources: Double(drumSources)])
        case .addPart(let partsInSong, let orphaned):
            return ProposalMeasures(values: [.partsPerSong: Double(partsInSong + 1), .orphanedParts: Double(orphaned)])
        case .setReference(let bars):
            return ProposalMeasures(values: [.referenceBars: Double(bars)])
        case .placeHook(let atSeconds):
            return ProposalMeasures(values: [.hookArrivalSeconds: atSeconds])
        case .shapeForm(let sections, let turns, let minutes):
            return ProposalMeasures(values: [.sectionCount: Double(sections), .formTurns: Double(turns), .formMinutes: minutes])
        case .writeLine(let syllables, let patternMatch):
            return ProposalMeasures(values: [.syllablesPerLine: Double(syllables), .patternMatch: patternMatch])
        case .rhymeLine(let perfectRate):
            return ProposalMeasures(values: [.perfectRhymeRate: perfectRate])
        case .reuseImage(let songs):
            return ProposalMeasures(values: [.imageReuse: Double(songs)])
        case .setLoudness(let lufs, let peak):
            return ProposalMeasures(values: [.integratedLUFS: lufs, .peakDBFS: peak])
        case .balanceLowEnd(let separation):
            return ProposalMeasures(values: [.lowEndSeparationDB: separation])
        case .squashDrums(let crest):
            return ProposalMeasures(values: [.crestDB: crest])
        case .outOfScope:
            return ProposalMeasures()
        }
    }
}

/// A bible, run: the generic `consider` for a persona that arrived as a document.
///
/// Every rule with a threshold on a feature the proposal moves is checked, in the bible's order.
/// A rule whose precondition (`applies`) does not hold is skipped. A tripped rule is a refusal
/// with the rule's own words as the reason and its *then* as the counter. A value inside the
/// feature's *noticeable* band of a threshold is a caveat. Nothing tripped is agreement. A
/// proposal that moves no feature the bible defines is deferred to whoever owns those features.
///
/// A lineage's own range for a feature stands in for a rule's threshold when the proposal names
/// that lineage: that is what the ranges are for — Thundercat's ten milliseconds is not a
/// Palladino lag budget failing, it is a different player.
public enum RuleEngine {

    public static func consider(_ bible: PersonaBible, _ proposal: PersonaProposal) -> PersonaVerdict {
        let measures = ProposalMeasures.of(proposal)
        let defined = Set(bible.vocabulary.map(\.feature))
        let moved = Set(measures.values.keys)
        // Somebody else's department: the features moved belong to another role, or this bible
        // measures none of them.
        let owners = Set(moved.compactMap { PersonaID.owner(of: $0) })
        if !owners.isEmpty, !owners.contains(bible.id), let owner = PersonaID.owner(of: moved) {
            return .defer_(to: owner, because: "Nothing the \(bible.name) measures is in that.")
        }
        guard !moved.intersection(defined).isEmpty else {
            let owner = PersonaID.owner(of: moved) ?? .beatmaker
            return .defer_(to: owner == bible.id ? .beatmaker : owner,
                           because: "Nothing the \(bible.name) measures is in that.")
        }

        var caveats: [String] = []
        for rule in bible.rules {
            guard var threshold = rule.threshold, let value = measures.values[threshold.feature] else { continue }
            if let applies = rule.applies {
                guard let gate = measures.values[applies.feature], applies.holds(for: gate) else { continue }
            }
            // The lineage's range, when the proposal names one and the bible has it.
            if let lineage = measures.lineage,
               let range = bible.ranges(for: threshold.feature).first(where: { lineageMatches($0.lineage, lineage) }) {
                threshold = .between(threshold.feature, range.low, range.high, unit: threshold.unit)
            }
            let holds = threshold.holds(for: value)
            let fires = rule.firesWhen == .thresholdFails ? !holds : holds
            let unit = threshold.unit
            if fires {
                return .refuse(
                    rule: rule.id,
                    because: "\(capitalised(rule.when)): \(threshold.feature) is \(format(value)) \(unit) against \(threshold).",
                    counter: capitalised(rule.then) + ".")
            }
            // Within one noticeable step of tripping: a caveat, not a refusal. For a rule that
            // fires when its threshold holds, the room is measured from the outside.
            let noticeable = bible.noticeable(threshold.feature)
            let room = rule.firesWhen == .thresholdFails ? margin(value, inside: threshold) : -margin(value, inside: threshold)
            // Exactly on the edge is inside, not close: a count of zero against "at most zero" holds.
            if noticeable > 0, room > 0, room < noticeable {
                caveats.append("\(capitalised(rule.when)) is close — \(threshold.feature) is \(format(value)) \(unit) against \(threshold).")
            }
        }
        if let first = caveats.first {
            return .agreeWithCaveat("Nothing in the \(bible.name)'s rules objects.", caveat: first)
        }
        return .agree("Nothing in the \(bible.name)'s rules objects: " + moved.intersection(defined).sorted { $0.rawValue < $1.rawValue }
            .map { "\($0) \(format(measures.values[$0] ?? 0))" }.joined(separator: ", ") + ".")
    }

    /// How far a value that satisfies a threshold sits from the edge where it would stop
    /// satisfying it, in the feature's own unit. The room it has before the rule fires.
    static func margin(_ value: Double, inside threshold: Threshold) -> Double {
        let upper = threshold.upper ?? threshold.value
        switch threshold.comparison {
        case .atLeast: return value - threshold.value
        case .atMost: return threshold.value - value
        case .equalTo: return abs(value - threshold.value)
        case .between: return min(value - threshold.value, upper - value)
        case .outside: return value < threshold.value ? threshold.value - value : value - upper
        }
    }

    static func lineageMatches(_ declared: String, _ named: String) -> Bool {
        declared.lowercased().contains(named.lowercased()) || named.lowercased().contains(declared.lowercased())
    }

    private static func format(_ x: Double) -> String { String(format: "%.4g", x) }
    private static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

extension PersonaID {
    /// Who owns a feature, by its family: the pocket and the swing are the Beatmaker's, the chop
    /// and the chain the Sampler's, the low end the Bassist's.
    public static func owner(of feature: Feature) -> PersonaID? {
        let name = feature.rawValue
        for prefix in ["pocket.", "swing.", "ghost.", "humanize.", "grid.", "backbeat."] where name.hasPrefix(prefix) { return .beatmaker }
        for prefix in ["chop.", "source.", "degrade.", "merge."] where name.hasPrefix(prefix) { return .sampler }
        for prefix in ["bass.", "kick.", "reference."] where name.hasPrefix(prefix) { return .bassist }
        for prefix in ["song."] where name.hasPrefix(prefix) { return .producer }
        for prefix in ["form."] where name.hasPrefix(prefix) { return .peer }
        for prefix in ["mix."] where name.hasPrefix(prefix) { return .engineer }
        for prefix in ["lyric."] where name.hasPrefix(prefix) { return .lyricist }
        return nil
    }

    /// The owner of most of a set of features.
    public static func owner(of features: Set<Feature>) -> PersonaID? {
        var tally: [PersonaID: Int] = [:]
        for feature in features { if let owner = owner(of: feature) { tally[owner, default: 0] += 1 } }
        return tally.max { $0.value < $1.value }?.key
    }
}

/// A persona that is nothing but its bible: what a document becomes when it gets a seat.
public struct DocumentPersona: Persona {
    public var bible: PersonaBible

    public init(bible: PersonaBible) { self.bible = bible }

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(bible, proposal)
    }
}
