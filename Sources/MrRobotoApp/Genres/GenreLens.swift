import Foundation
import SongGraph

/// A persona's reading, re-judged in the song's genre.
///
/// The persona still reads the song in its own units and still says its own sentence; what changes
/// is where the line is drawn. A rule's threshold on a feature the genre has a range for is moved to
/// the genre's range — only the side the rule draws: "the hook inside thirty seconds" keeps its
/// ceiling and takes the genre's (forty-five in a house record that spends its first bars on the
/// DJ's mix), and a hook that arrives early is still no fault. The reading then says both numbers,
/// so nobody mistakes the genre's norm for the bible's research, or the other way round.
///
/// Rules that name a condition rather than a norm ("the kick rings past 400 ms, so the 808 is the
/// bass") are left alone: that is physics, not style.
public struct GenreLens: Sendable, Equatable {
    public let profile: GenreProfile

    public init(_ profile: GenreProfile) { self.profile = profile }

    /// The features a genre may move: style. A machine's reach (the MPC's swing lever stops at
    /// sixteenths), a converter's ceiling, how a sample was cut, how many moves an engineer makes
    /// at once — those are the same in every genre, and a profile's number on them is not a norm
    /// but a misreading of what the feature is.
    public static func judges(_ feature: Feature) -> Bool {
        let name = feature.rawValue
        let styles = ["tempo.", "swing.", "pocket.", "ghost.", "humanize.", "form.", "harmony.", "melody.", "lyric.", "bass."]
        let mix: Set<Feature> = [.integratedLUFS, .crestDB, .tiltDB, .mixBandwidthHz, .lowEndSeparationDB, .masterTargetLUFS]
        return (styles.contains { name.hasPrefix($0) } && !name.hasPrefix("form.album.")) || mix.contains(feature)
    }

    /// The rule's threshold with the genre's range standing in for the side it draws. Nil when the
    /// genre says nothing about the feature, or the rule is not one a genre can move.
    public func threshold(for rule: PersonaRule) -> Threshold? {
        guard rule.firesWhen == .thresholdFails, let threshold = rule.threshold, Self.judges(threshold.feature),
              let range = profile.range(threshold.feature) else { return nil }
        switch threshold.comparison {
        case .atMost: return .atMost(threshold.feature, range.high, unit: threshold.unit)
        case .atLeast: return .atLeast(threshold.feature, range.low, unit: threshold.unit)
        case .between: return .between(threshold.feature, range.low, range.high, unit: threshold.unit)
        case .outside, .equalTo: return nil
        }
    }

    /// What the genre allows on a moved threshold, said as a listener would: "at most 45 seconds",
    /// "118–128 BPM".
    func allows(_ threshold: Threshold, _ range: GenreRange) -> String {
        func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.3g", x) }
        let unit = range.unit.isEmpty ? threshold.unit : range.unit
        switch threshold.comparison {
        case .atMost: return "up to \(f(threshold.value)) \(unit)"
        case .atLeast: return "at least \(f(threshold.value)) \(unit)"
        default: return range.span
        }
    }

    /// Every reading, each re-judged where the genre has a say.
    public func apply(_ readings: [PersonaReading], bible: PersonaBible) -> [PersonaReading] {
        readings.map { apply($0, bible: bible) }
    }

    public func apply(_ reading: PersonaReading, bible: PersonaBible) -> PersonaReading {
        guard let rule = bible.rules.first(where: { $0.id == reading.rule }),
              rule.threshold?.feature == reading.feature,
              let moved = threshold(for: rule), let range = profile.range(reading.feature) else { return reading }
        let holds = moved.holds(for: reading.value)
        var out = reading
        out.genre = profile.id
        out.holds = holds
        let allowed = allows(moved, range)
        switch (reading.holds, holds) {
        case (false, true): out.says = "\(reading.says) In \(profile.name) that is normal (\(allowed)), so it stands."
        case (true, false): out.says = "\(reading.says) But \(profile.name) wants \(allowed)."
        case (false, false): out.says = "\(reading.says) \(profile.name) wants \(allowed) too."
        case (true, true): out.genre = nil
        }
        return out
    }

    /// A refusal the genre would not make, turned into agreement with the refusal kept as the
    /// caveat. Agreement and deferral pass through: the genre loosens a line, it does not add one
    /// the persona never drew.
    public func apply(_ verdict: PersonaVerdict, to proposal: PersonaProposal, bible: PersonaBible) -> PersonaVerdict {
        guard case .refuse(let id, let because, _) = verdict,
              let rule = bible.rules.first(where: { $0.id == id }), let moved = threshold(for: rule),
              let range = profile.range(moved.feature),
              let value = ProposalMeasures.of(proposal).values[moved.feature], moved.holds(for: value) else { return verdict }
        return .agreeWithCaveat("In \(profile.name) that is normal: \(moved.feature) \(String(format: "%.4g", value)) against \(allows(moved, range)).",
                                caveat: "Outside \(profile.name) the \(bible.name) would refuse: \(because)")
    }
}

extension GenreLens {
    /// The lens for a song, when its genre is known.
    public static func of(_ song: Song?, in book: GenreBook = .standard) -> GenreLens? {
        book.genre(of: song).map { GenreLens($0.profile) }
    }
}

extension GenreLens {
    /// Readings re-judged by a lens when there is one, as they were when there is not.
    public static func judge(_ readings: [PersonaReading], by bible: PersonaBible, in lens: GenreLens?) -> [PersonaReading] {
        lens.map { $0.apply(readings, bible: bible) } ?? readings
    }

    /// A verdict re-judged by a lens when there is one.
    public static func judge(_ verdict: PersonaVerdict, on proposal: PersonaProposal, by bible: PersonaBible,
                             in lens: GenreLens?) -> PersonaVerdict {
        lens.map { $0.apply(verdict, to: proposal, bible: bible) } ?? verdict
    }
}
