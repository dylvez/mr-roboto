import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// What the Compare surface needs from whatever is hosting it, and the values it compares.
//
// The same shape the Gate A surfaces use and for the same reason: the Director and its workspace are
// being built alongside this file, and a surface that named `AppState` would be unbuildable until
// they land and untestable without an audio device afterwards. Four capabilities, no more.

/// What the Compare surface needs from its host.
///
/// The whole protocol exists to keep one promise: **every candidate auditions in place, with no
/// round trip.** The host owns the engine; the surface owns nothing that makes sound. Pressing a
/// row plays that row, moving a lever re-plays whatever is already playing with the lever's new
/// value, and neither of those goes anywhere near an agent.
@MainActor
public protocol CompareHosting: AnyObject {
    /// Play a candidate, now, with the levers where they currently sit.
    ///
    /// The levers are passed rather than read, so a host has no state to keep in step with the
    /// surface and a test can assert on exactly what was played.
    func audition(_ candidate: CompareCandidate, levers: [CompareLever: Double]) async

    /// Play the thing the candidates are being judged against, under the same levers.
    ///
    /// Separate from `audition(_:levers:)` because the reference is not a candidate and must not be
    /// selectable as one — the commonest way a comparison surface goes wrong is letting you choose
    /// the thing you were comparing to.
    func auditionReference(_ reference: CompareReference, levers: [CompareLever: Double]) async

    /// Silence anything this surface has playing.
    func stopAudition()

    /// Take the winner. Returns `false` when the host refused it, so the surface can keep the
    /// selection rather than pretending a version was made.
    @discardableResult
    func choose(_ candidate: CompareCandidate) async -> Bool
}

// MARK: - What is being compared

/// One measured number, ready to print in a column.
public struct CompareReading: Hashable, Sendable {
    public var feature: Feature
    public var value: Double
    public var unit: String

    public init(_ feature: Feature, _ value: Double, unit: String) {
        self.feature = feature
        self.value = value
        self.unit = unit
    }

    /// What the cell shows: the number, then the unit.
    public var text: String {
        // A whole number is said whole: "2 parts", not "2.00 parts".
        if value == value.rounded() { return String(format: "%.0f %@", value, unit) }
        let magnitude = abs(value)
        let digits = magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, unit)
    }
}

/// The thing the candidates are judged against, which stays visible at the top.
///
/// Not optional and not a candidate. A Compare with nothing at the top is a list, and a list does
/// not tell you whether any of the options is actually better than what you already have.
public struct CompareReference: Identifiable, Sendable {
    public var id: String
    /// "Bar 9 of Arrival, as it is."
    public var title: String
    /// One line on what this is: "the version on the bench", "the source break".
    public var kind: String
    public var readings: [Feature: CompareReading]
    /// The version this is, when it is one.
    public var version: VersionID?
    /// A whole section as it stands, when that is what the candidates are judged against.
    public var state: SectionState?

    public init(id: String = "reference", title: String, kind: String,
                readings: [CompareReading] = [], version: VersionID? = nil, state: SectionState? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.readings = Dictionary(readings.map { ($0.feature, $0) }, uniquingKeysWith: { _, b in b })
        self.version = version
        self.state = state
    }

    public func reading(_ feature: Feature) -> CompareReading? { readings[feature] }
}

/// One row.
public struct CompareCandidate: Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Who proposed it. Printed on the row, because "the Beatmaker's" and "the Sampler's" answers to
    /// the same question should be visibly different answers rather than anonymous options.
    public var proposedBy: PersonaID?
    /// One line: why this one exists. The persona's own sentence.
    public var rationale: String
    public var readings: [Feature: CompareReading]
    /// What choosing this would commit. Nil for a candidate that is only an audition.
    public var version: PartVersion?
    /// What the critics said about *this* candidate. Surfaced on the row as a count; the finding
    /// itself opens in a Check.
    public var findings: [Finding]
    /// A whole section as it stood, when the row is one: every lane at the version it played and
    /// every strip at its level. Played through the mix, and taking it puts the section back.
    public var state: SectionState?

    public init(id: String, title: String, proposedBy: PersonaID? = nil, rationale: String = "",
                readings: [CompareReading] = [], version: PartVersion? = nil,
                findings: [Finding] = [], state: SectionState? = nil) {
        self.id = id
        self.title = title
        self.proposedBy = proposedBy
        self.rationale = rationale
        self.readings = Dictionary(readings.map { ($0.feature, $0) }, uniquingKeysWith: { _, b in b })
        self.version = version
        self.findings = findings
        self.state = state
    }

    public func reading(_ feature: Feature) -> CompareReading? { readings[feature] }

    /// Warnings only. A note is worth showing on the Check card and not worth a mark on a row.
    public var warnings: [Finding] { findings.filter { $0.severity == .warn } }
}

// MARK: - The two levers

/// A control that runs locally against the engine, applied to every row at once.
///
/// **At most two**, from the surface's own contract, and `CompareModel` enforces it rather than
/// trusting a caller. The reason for the cap is not tidiness: a comparison with five knobs is not a
/// comparison, it is a second editor, and the question the surface exists to answer — which of these
/// is better — stops being askable once the candidates can be edited into each other.
///
/// The reason a lever applies to *every* row rather than to the selected one is the same: a lever
/// that only moved one candidate would make the comparison unfair, which is the one thing this
/// surface cannot be.
public enum CompareLever: String, CaseIterable, Sendable, Identifiable {
    /// BPM. Re-times every candidate on the spot; the groove engine adopts it on the next pass.
    case tempo
    /// MPC swing percent, applied on top of every candidate's own.
    case swing
    /// Ghost velocity as a fraction of normal.
    case ghostLevel
    /// The degradation chain's dry/wet, 0…1.
    case degradeMix
    /// How far a bass line sits behind the kick, in milliseconds; negative is ahead. Shifts every
    /// onset of a bass-line candidate on the spot; does nothing to a groove or a chop.
    case lag

    public var id: String { rawValue }

    /// What the lever is called above it.
    public var label: String {
        switch self {
        case .tempo: return "Tempo"
        case .swing: return "Swing"
        case .ghostLevel: return "Ghost level"
        case .degradeMix: return "Chain"
        case .lag: return "Behind the kick"
        }
    }

    public var unit: String {
        switch self {
        case .tempo: return "bpm"
        case .swing: return "%"
        case .ghostLevel, .degradeMix: return ""
        case .lag: return "ms"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .tempo: return 60...180
        case .swing: return Swing.minimumPercent...Swing.maximumPercent
        case .ghostLevel, .degradeMix: return 0...1
        case .lag: return -25...90
        }
    }

    public var defaultValue: Double {
        switch self {
        case .tempo: return 90
        case .swing: return Swing.minimumPercent
        case .ghostLevel: return 0.45
        case .degradeMix: return 1
        case .lag: return 40
        }
    }

    /// The engine property this moves, named so a host has no guessing to do.
    public var engineField: String {
        switch self {
        case .tempo: return "Performance.GrooveTimeline's tempo"
        case .swing: return "SongGraph.Groove.swing, via Performance.Swing(percent:)"
        case .ghostLevel: return "Performance.VelocityMap.ghost against .normal"
        case .degradeMix: return "Instrument.DegradeSettings.mix"
        case .lag: return "SongGraph.NoteEvent.start of every bass note, shifted by the lag at the tempo"
        }
    }

    public func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

// MARK: - A difference

/// One feature, on one candidate, against the reference — and whether the gap is big enough to say
/// out loud.
///
/// `noticeable` comes from a persona's own feature vocabulary (`PersonaBible.noticeable`), which is
/// the point: what counts as a difference in swing is a fact about hearing, not about the surface,
/// and the bible is where this app writes those down. A 2 ms difference in a snare's placement is
/// marked as *same* because Frane's detection threshold is 10 ms, and that judgement lives in one
/// place rather than in every view that draws an arrow.
public struct CompareDifference: Hashable, Sendable, Identifiable {
    public enum Direction: String, Hashable, Sendable {
        case same, higher, lower
    }

    public var feature: Feature
    public var reference: Double
    public var candidate: Double
    public var unit: String
    /// The smallest change worth marking, from the persona's vocabulary.
    public var noticeable: Double

    public var id: String { feature.rawValue }

    public init(feature: Feature, reference: Double, candidate: Double, unit: String,
                noticeable: Double) {
        self.feature = feature
        self.reference = reference
        self.candidate = candidate
        self.unit = unit
        self.noticeable = max(0, noticeable)
    }

    public var delta: Double { candidate - reference }

    /// True when the gap is at least as big as the smallest change anybody would hear. With no
    /// stated threshold every difference counts, which is the safe direction to fail in: an
    /// undefined feature over-reports rather than hiding a change.
    public var matters: Bool {
        guard noticeable > 0 else { return delta != 0 }
        return abs(delta) >= noticeable
    }

    public var direction: Direction {
        guard matters else { return .same }
        return delta > 0 ? .higher : .lower
    }

    /// What the mark says: "+12 ms", "−4 %", or nothing when it does not matter.
    public var text: String {
        guard matters else { return "—" }
        let magnitude = abs(delta)
        let digits = magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2)
        let sign = delta > 0 ? "+" : "−"
        return String(format: "%@%.\(digits)f %@", sign, magnitude, unit)
    }
}
