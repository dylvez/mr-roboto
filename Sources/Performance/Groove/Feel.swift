import Foundation
import MusicTheory
import SongGraph

// MARK: - Idiom

/// A style tag. Extensible like `DrumVoice`: the statics are the ones the library ships, any string
/// is allowed, because a cast is assembled per project and a persona may well invent a genre.
public struct Idiom: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }

    public static let hipHop = Idiom("hip-hop")
    public static let boomBap = Idiom("boom-bap")
    public static let lofi = Idiom("lo-fi")
    public static let trap = Idiom("trap")
    public static let tripHop = Idiom("trip-hop")
    public static let neoSoul = Idiom("neo-soul")
    public static let soul = Idiom("soul")
    public static let motown = Idiom("motown")
    public static let funk = Idiom("funk")
    public static let house = Idiom("house")
    public static let electronic = Idiom("electronic")
    public static let disco = Idiom("disco")
    public static let breakbeat = Idiom("breakbeat")
    public static let drumAndBass = Idiom("drum-and-bass")
    public static let rock = Idiom("rock")
    public static let pop = Idiom("pop")
    public static let blues = Idiom("blues")
    public static let jazz = Idiom("jazz")
    public static let latin = Idiom("latin")
    public static let reggae = Idiom("reggae")
    public static let country = Idiom("country")
    public static let folk = Idiom("folk")
    public static let ballad = Idiom("ballad")
    public static let musicalTheatre = Idiom("musical-theatre")
    public static let waltz = Idiom("waltz")
    public static let middleEastern = Idiom("middle-eastern")

    public var description: String { rawValue }
}

// MARK: - Provenance

/// Where a feel came from. A product requirement, not decoration: a persona has to be able to say
/// "this is the Motown thing, kick on 1 and 3 under sixteenth hats" and mean something checkable,
/// and a feel with no stated lineage is a feel nobody can argue with.
public struct Provenance: Hashable, Sendable, Codable {
    /// The corpus this came out of: a port, a piece of research, or an original.
    public enum Origin: String, Hashable, Sendable, Codable, CaseIterable {
        /// Ported from the `groove-theory` web sequencer.
        case grooveTheory = "groove-theory"
        /// Ported from The Chorus's accompaniment pattern tables.
        case theChorus = "the-chorus"
        /// Written for this app from sources cited in `references`.
        case researched
        /// Written for this app from nothing but taste.
        case original
    }

    public var origin: Origin
    /// One sentence a persona can say out loud.
    public var summary: String
    /// The file, document or page the pattern came from.
    public var source: String?
    /// Named practitioners, records or machines the feel descends from.
    public var lineage: [String]
    /// URLs backing the tempo, swing and step claims.
    public var references: [String]

    public init(origin: Origin, summary: String, source: String? = nil,
                lineage: [String] = [], references: [String] = []) {
        self.origin = origin
        self.summary = summary
        self.source = source
        self.lineage = lineage
        self.references = references
    }
}

// MARK: - Feel

/// A named groove with everything needed to play it and to explain it.
///
/// The pattern alone is not a feel. A feel is the pattern *plus* the velocities it wants, the swing
/// it wants, how much of a human to put back in, which voices sit off the beat, the tempos it works
/// at, and where it came from — which is why this type carries all of that and `Groove` (the graph
/// payload) carries only what has to be versioned.
public struct Feel: Hashable, Sendable, Codable, Identifiable {
    public var id: String { name }

    public var name: String
    /// Style tags, most specific first. `idioms.first` is the feel's home.
    public var idioms: [Idiom]
    /// Tempos this feel works at, in BPM.
    public var tempoRange: ClosedRange<Double>
    /// The tempo to use when nothing else says otherwise.
    public var suggestedTempo: Double
    public var timeSignature: TimeSignature
    public var groove: Groove
    public var velocities: VelocityMap
    public var humanize: Humanize
    /// Per-voice departures: the pocket.
    public var voices: [DrumVoice: VoiceFeel]
    public var provenance: Provenance

    public init(name: String, idioms: [Idiom], tempoRange: ClosedRange<Double>,
                suggestedTempo: Double? = nil, timeSignature: TimeSignature = .fourFour,
                groove: Groove, velocities: VelocityMap = .standard, humanize: Humanize = .none,
                voices: [DrumVoice: VoiceFeel] = [:], provenance: Provenance) {
        self.name = name
        self.idioms = idioms
        self.tempoRange = tempoRange
        self.suggestedTempo = suggestedTempo ?? (tempoRange.lowerBound + tempoRange.upperBound) / 2
        self.timeSignature = timeSignature
        self.groove = groove
        self.velocities = velocities
        self.humanize = humanize
        self.voices = voices
        self.provenance = provenance
    }

    // MARK: Shape

    public var swing: Swing { Swing(factor: groove.swing) }
    public var stepsPerBar: Int { groove.stepsPerBar }
    public var bars: Int { groove.bars }
    /// Steps per beat: 4 for sixteenths in 4/4, 3 for triplet eighths, 8 for thirty-seconds.
    public var stepsPerBeat: Double { Double(groove.stepsPerBar) / Double(max(1, timeSignature.beatsPerBar)) }
    public var voiceNames: [DrumVoice] { groove.patterns.map(\.voice) }

    /// A timeline at this feel's own suggested tempo.
    public var suggestedTimeline: GrooveTimeline {
        .tempo(suggestedTempo, timeSignature: timeSignature)
    }

    /// A timeline at a stated tempo in this feel's meter.
    public func timeline(at bpm: Double, startingAt offset: Double = 0) -> GrooveTimeline {
        .tempo(bpm, timeSignature: timeSignature, startingAt: offset)
    }

    /// A timeline riding a detected grid, read in this feel's meter.
    public func timeline(on grid: BeatGrid, bar: Int = 0) -> GrooveTimeline {
        .grid(grid, timeSignature: timeSignature, bar: bar)
    }

    /// True when `bpm` is inside this feel's range.
    public func suits(tempo bpm: Double) -> Bool { tempoRange.contains(bpm) }

    /// True when the feel carries `idiom` as a tag.
    public func suits(idiom: Idiom) -> Bool { idioms.contains(idiom) }

    /// The same feel with a different name — how a persona forks a feel it has bent.
    public func renamed(_ newName: String) -> Feel {
        var copy = self
        copy.name = newName
        return copy
    }

    /// The same feel with a different swing, in MPC percent.
    public func swung(percent: Double) -> Feel {
        var copy = self
        copy.groove.swing = Swing(percent: percent).factor
        return copy
    }
}

// MARK: - Validation

/// Something wrong with a feel, found without playing it.
public struct FeelIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        /// A pattern's step count is not `stepsPerBar * bars`.
        case stepCountMismatch
        /// `stepsPerBar` is not a whole number of steps per beat in the feel's meter.
        case meterMismatch
        /// The groove has no patterns, or every step is a rest.
        case silent
        /// The tempo range is empty, non-positive, or does not contain the suggested tempo.
        case tempoRange
        /// `Groove.swing` is outside 0…1.
        case swingOutOfRange
        /// Two feels in a library share a name.
        case duplicateName
        /// No idiom tag, so the feel can never be suggested.
        case untagged
    }

    public var feel: String
    public var kind: Kind
    public var detail: String

    public init(feel: String, kind: Kind, detail: String) {
        self.feel = feel
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(feel): \(kind.rawValue) — \(detail)" }
}

extension Feel {
    /// Everything checkable about a feel without rendering it.
    public func validate() -> [FeelIssue] {
        var issues: [FeelIssue] = []
        let expected = groove.stepsPerBar * groove.bars

        if groove.stepsPerBar <= 0 || groove.bars <= 0 {
            issues.append(FeelIssue(feel: name, kind: .stepCountMismatch,
                                    detail: "stepsPerBar \(groove.stepsPerBar), bars \(groove.bars)"))
        } else if groove.stepsPerBar % timeSignature.beatsPerBar != 0 {
            issues.append(FeelIssue(feel: name, kind: .meterMismatch,
                                    detail: "\(groove.stepsPerBar) steps per bar does not divide into \(timeSignature) "
                                          + "(\(timeSignature.beatsPerBar) beats)"))
        }

        for pattern in groove.patterns where pattern.steps.count != expected {
            issues.append(FeelIssue(feel: name, kind: .stepCountMismatch,
                                    detail: "\(pattern.voice) has \(pattern.steps.count) steps, expected \(expected)"))
        }

        if groove.patterns.isEmpty || groove.patterns.allSatisfy({ $0.steps.allSatisfy { $0 == .rest } }) {
            issues.append(FeelIssue(feel: name, kind: .silent, detail: "no sounding steps"))
        }

        if !(groove.swing >= 0 && groove.swing <= 1) {
            issues.append(FeelIssue(feel: name, kind: .swingOutOfRange, detail: "swing \(groove.swing)"))
        }

        if tempoRange.lowerBound <= 0 || tempoRange.upperBound < tempoRange.lowerBound {
            issues.append(FeelIssue(feel: name, kind: .tempoRange, detail: "\(tempoRange)"))
        } else if !tempoRange.contains(suggestedTempo) {
            issues.append(FeelIssue(feel: name, kind: .tempoRange,
                                    detail: "suggested \(suggestedTempo) outside \(tempoRange)"))
        }

        if idioms.isEmpty {
            issues.append(FeelIssue(feel: name, kind: .untagged, detail: "no idiom tags"))
        }

        return issues
    }
}
