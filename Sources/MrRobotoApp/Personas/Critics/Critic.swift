import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The checks that make a persona trustworthy.
//
// A persona that only ever proposes is a persona you have to audit by ear every time. A critic is
// the persona checking its own work before you see it: the chop that cut a transient, the re-groove
// fighting the source's own swing, the two slices that will flam, the levels that will not survive
// the mix.
//
// Three rules hold for everything in this directory, and the tests hold them to all three.
//
// **Pure functions over the engines' own data.** A critic takes a value and returns findings. No
// model, no audio device, no engine, no disk, no clock. `Critic.review` on every critic here is a
// plain function of its input, which is what makes a finding reproducible and a test cheap.
//
// **Flags, never fixes.** From the catalog's fourth rule. A critic *names* two fixes and describes
// each as an `EngineChange`, and nothing in this directory applies one. Applying is the Check
// surface's business, on a user's click, through its host. There is deliberately no code path from
// a `Finding` to a mutation.
//
// **A finding names the place, says why in one sentence, and offers exactly two fixes.** Not one,
// which is an instruction, and not five, which is a menu. `Finding.init` takes `first` and `second`,
// so "exactly two" is a type rule rather than a convention.

// MARK: - Identity

public struct CriticID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }
    public var description: String { rawValue }

    public static let transientCut = CriticID("chop.transient-cut")
    public static let sliceLevel = CriticID("chop.level")
    public static let degradeStack = CriticID("chop.degrade-stack")
    public static let swingClash = CriticID("groove.swing-clash")
    public static let sliceClash = CriticID("groove.slice-clash")
}

// MARK: - Where a finding is

/// What the finding is about. The Check surface draws a different pointer for each.
public enum FindingSubject: Hashable, Sendable {
    /// One slice of a chop, by index.
    case slice(Int)
    /// One step of a groove.
    case step(bar: Int, step: Int, voice: String)
    /// A whole bar.
    case bar(Int)
    /// The source as a whole — a chain over it, a level across it.
    case source

    /// The phrase a headline uses: "slice 7", "bar 3, step 12 (snare)".
    public var named: String {
        switch self {
        case .slice(let index): return "slice \(index)"
        case .step(let bar, let step, let voice): return "bar \(bar + 1), step \(step + 1) (\(voice))"
        case .bar(let bar): return "bar \(bar + 1)"
        case .source: return "the source"
        }
    }

    public var sliceIndex: Int? { if case .slice(let i) = self { return i }; return nil }
}

/// Where in time, so the finding can be *heard*. The Check surface's "hear the problem" button is
/// nothing more than playing this range.
public struct Locus: Hashable, Sendable {
    /// Bar of the part, 0-based. Nil when the finding is not about a position in a bar.
    public var bar: Int?
    /// Beat within that bar, 0-based and fractional: 1.5 is the *and* of two.
    public var beat: Double?
    /// Seconds from the start of whatever the finding is about, for playback.
    public var start: Double
    public var end: Double

    public init(bar: Int? = nil, beat: Double? = nil, start: Double = 0, end: Double = 0) {
        self.bar = bar
        self.beat = beat
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    /// "bar 3, beat 2½" — what the Check card prints under the headline.
    public var spoken: String {
        guard let bar else { return String(format: "%.3g–%.3g s", start, end) }
        guard let beat else { return "bar \(bar + 1)" }
        let whole = Int(beat.rounded(.down))
        let fraction = beat - Double(whole)
        let half = abs(fraction - 0.5) < 0.05 ? "½" : (fraction > 0.05 ? String(format: "+%.2f", fraction) : "")
        return "bar \(bar + 1), beat \(whole + 1)\(half)"
    }
}

// MARK: - The number behind a finding

/// What was measured, what the threshold was, and therefore why the finding fired.
///
/// Carried rather than baked into the prose so the Check surface can show the arithmetic and a test
/// can assert on it without string matching.
public struct Measurement: Hashable, Sendable, CustomStringConvertible {
    public var feature: Feature
    public var measured: Double
    public var threshold: Threshold
    /// "ms", "dB", "%".
    public var unit: String

    public init(_ feature: Feature, measured: Double, threshold: Threshold, unit: String) {
        self.feature = feature
        self.measured = measured
        self.threshold = threshold
        self.unit = unit
    }

    /// True when the measurement is on the wrong side of the threshold — which is the only state a
    /// finding should ever be constructed in.
    public var trips: Bool { !threshold.holds(for: measured) }

    public var description: String {
        String(format: "%.4g %@ (want %@)", measured, unit, threshold.description)
    }
}

// MARK: - Fixes

/// An engine change a fix would make, as data.
///
/// Data rather than a closure for two reasons: a fix has to survive being shown, compared, logged
/// into a version note and asserted on in a test; and a closure in a finding would be a fix that
/// could apply itself, which is the thing the catalog forbids.
public enum EngineChange: Hashable, Sendable {
    /// Move a slice's start, in seconds. Negative is earlier.
    case moveSliceStart(slice: Int, by: Double)
    /// Set the groove's swing, in MPC percent.
    case setSwing(percent: Double)
    /// Set one voice's constant displacement, in milliseconds (positive = late).
    case setVoiceLag(voice: String, milliseconds: Double)
    /// Switch how an overrunning slice is handled: `Regroove.Overlap`'s raw value.
    case setOverlap(String)
    /// Trim or lift one slice, in dB.
    case setSliceGain(slice: Int, dB: Double)
    /// Force a slice's class, so the re-groove stops sending it to the wrong voice.
    case reclassifySlice(slice: Int, as: String)
    /// Take a slice out of the rotation.
    case dropSlice(Int)
    /// Swap the degradation preset. `nil` is the clean chain.
    case setDegradePreset(String?)
    /// Move the chain's dry/wet.
    case setDegradeMix(Double)
    /// Re-chop with a different snap tolerance, in seconds.
    case setSnapTolerance(Double)
    /// Deliberately nothing: the fix is to accept it, and the detail says why that is defensible.
    case accept
}

/// One of the two ways out of a finding.
public struct Fix: Identifiable, Hashable, Sendable {
    public var id: String
    /// The imperative, short enough for a button: "Move the cut 9 ms earlier".
    public var title: String
    /// One sentence on what it costs. A fix with no cost is usually a fix that does not work.
    public var detail: String
    public var change: EngineChange

    public init(_ id: String, title: String, detail: String, change: EngineChange) {
        self.id = id
        self.title = title
        self.detail = detail
        self.change = change
    }
}

// MARK: - The finding

public struct Finding: Identifiable, Hashable, Sendable {

    public enum Severity: String, Hashable, Sendable, CaseIterable, Comparable {
        /// Worth knowing; the record is full of deliberate versions of this.
        case note
        /// Will be heard as a mistake by somebody who did not make it.
        case warn

        public static func < (a: Severity, b: Severity) -> Bool {
            a == .note && b == .warn
        }
    }

    public let id: UUID
    /// Which check found it.
    public var critic: CriticID
    /// What that check is called on screen: "Transient check".
    public var criticName: String
    /// Which persona owns the check. The Check surface prints this as "who found it".
    public var persona: PersonaID
    public var subject: FindingSubject
    public var locus: Locus
    /// Names the bar or the slice. One line.
    public var headline: String
    /// Why, in one sentence. Enforced by review, not by the type — but every finding here is one
    /// sentence, and `CriticTests` checks it.
    public var why: String
    public var severity: Severity
    public var measurement: Measurement
    /// Exactly two, in the order they should be offered: the one that fixes the cause first, the
    /// one that accepts the cause and works around it second.
    public let fixes: [Fix]

    public init(id: UUID = UUID(), critic: CriticID, criticName: String, persona: PersonaID,
                subject: FindingSubject, locus: Locus, headline: String, why: String,
                severity: Severity = .warn, measurement: Measurement,
                first: Fix, second: Fix) {
        self.id = id
        self.critic = critic
        self.criticName = criticName
        self.persona = persona
        self.subject = subject
        self.locus = locus
        self.headline = headline
        self.why = why
        self.severity = severity
        self.measurement = measurement
        fixes = [first, second]
    }

    public func fix(_ id: Fix.ID) -> Fix? { fixes.first { $0.id == id } }

    /// The finding as a `ChopLaneMark`, which is the seam the Chop lane already carries and never
    /// writes itself. This is the only bridge from a critic to a surface, and it copies — it does
    /// not let the lane reach back into the finding.
    public var mark: ChopLaneMark {
        ChopLaneMark(sliceIndex: subject.sliceIndex, start: locus.start, end: locus.end,
                     summary: headline, severity: severity == .warn ? .warn : .note)
    }
}

// MARK: - The critics themselves

/// What every critic is, whatever it reads.
public protocol Critic: Sendable {
    var id: CriticID { get }
    /// What the Check card calls it.
    var name: String { get }
    /// The persona whose standard this enforces.
    var persona: PersonaID { get }
    /// One sentence: what it checks, and the threshold it checks against.
    var checks: String { get }
}

/// Everything a chop critic is handed. A value — no engine, no host, no audio device.
public struct ChopReview: Sendable {
    /// What the chop is called, for a headline.
    public var label: String
    public var chop: Chop
    public var classifications: [SliceClassification]
    /// Mono of the source, for the critics that have to look at the waveform. Empty is legal; a
    /// critic that needs it says so by returning nothing.
    public var signal: [Float]
    /// The transients the detector found, in seconds from frame 0. Empty means "not detected" and
    /// is not the same as "none there", so the transient critic falls back to `snapOffset`.
    public var detectedOnsets: [Double]
    /// The chain currently over the source.
    public var degrade: DegradeSettings?
    /// The observation, so a critic does not recompute what the persona already measured.
    public var observation: SourceObservation
    /// The velocity map the chop will be played at, which is what decides whether a quiet slice
    /// survives. `.standard` when nobody has said.
    public var velocities: VelocityMap

    public init(label: String, chop: Chop, classifications: [SliceClassification] = [],
                signal: [Float] = [], detectedOnsets: [Double] = [],
                degrade: DegradeSettings? = nil, velocities: VelocityMap = .standard,
                observation: SourceObservation? = nil) {
        self.label = label
        self.chop = chop
        self.classifications = classifications
        self.signal = signal
        self.detectedOnsets = detectedOnsets
        self.degrade = degrade
        self.velocities = velocities
        self.observation = observation ?? SourceObservation(label: label, chop: chop,
                                                            classifications: classifications,
                                                            degrade: degrade)
    }
}

public protocol ChopCritic: Critic {
    func review(_ input: ChopReview) -> [Finding]
}

/// Where one slice landed, as a critic reads it.
///
/// A mirror of `Performance.SlicePlacement`, carrying only the fields a critic uses, and it exists
/// for exactly one reason: `SlicePlacement`'s memberwise initialiser is internal to `Performance`,
/// so a test cannot build one and a critic that took them directly would only be testable by
/// running a whole re-groove. The conversion is one initialiser and it is lossless for everything
/// below. (If `SlicePlacement` ever gains a public `init`, this type collapses into a typealias.)
public struct PlacedSlice: Hashable, Sendable {
    public var sliceIndex: Int
    public var voice: DrumVoice
    public var bar: Int
    public var step: Int
    /// Transport seconds.
    public var time: Double
    public var velocity: Int
    /// Seconds until the next hit on this voice.
    public var available: Double
    /// The slice's own length, in seconds.
    public var naturalDuration: Double
    /// Set when the slice was stretched to fit; a stretched slice cannot overrun by definition.
    public var stretchRatio: Double?

    public init(sliceIndex: Int, voice: DrumVoice, bar: Int, step: Int, time: Double,
                velocity: Int, available: Double, naturalDuration: Double,
                stretchRatio: Double? = nil) {
        self.sliceIndex = sliceIndex
        self.voice = voice
        self.bar = bar
        self.step = step
        self.time = time
        self.velocity = velocity
        self.available = available
        self.naturalDuration = naturalDuration
        self.stretchRatio = stretchRatio
    }

    public init(_ placement: SlicePlacement) {
        self.init(sliceIndex: placement.sliceIndex, voice: placement.voice, bar: placement.bar,
                  step: placement.step, time: placement.time, velocity: placement.velocity,
                  available: placement.available, naturalDuration: placement.naturalDuration,
                  stretchRatio: placement.stretchRatio)
    }

    /// True when the slice is longer than the room the feel gives it — `SlicePlacement.overruns`.
    public var overruns: Bool { naturalDuration > available + 1e-9 }
}

/// Everything a groove critic is handed.
public struct GrooveReview: Sendable {
    public var label: String
    public var observation: GrooveObservation
    /// Where each slice landed, when the groove is a chop re-grooved. Empty for a synthesized
    /// pattern, and the placement critics then have nothing to say — which is correct.
    public var placements: [PlacedSlice]
    /// Centroid per slice index, so two placements can be asked whether they are the same drum.
    public var sliceCentroid: [Int: Double]
    /// The swing the *source* audio already carries, in MPC percent, when it was measured.
    public var sourceSwingPercent: Double?
    /// How many onsets that estimate rests on. Below `SourceSwing.minimumOnsets` it is not used.
    public var sourceSwingSupport: Int

    public init(label: String, observation: GrooveObservation,
                placements: [PlacedSlice] = [], sliceCentroid: [Int: Double] = [:],
                sourceSwingPercent: Double? = nil, sourceSwingSupport: Int = 0) {
        self.label = label
        self.observation = observation
        self.placements = placements
        self.sliceCentroid = sliceCentroid
        self.sourceSwingPercent = sourceSwingPercent
        self.sourceSwingSupport = sourceSwingSupport
    }

    /// The same review over a real `RegroovePerformance`'s placements.
    public init(label: String, observation: GrooveObservation,
                performance: RegroovePerformance,
                sourceSwingPercent: Double? = nil, sourceSwingSupport: Int = 0) {
        self.init(label: label, observation: observation,
                  placements: performance.placements.map(PlacedSlice.init),
                  sliceCentroid: Dictionary(performance.classifications.map {
                      ($0.sliceIndex, $0.centroid)
                  }, uniquingKeysWith: { _, b in b }),
                  sourceSwingPercent: sourceSwingPercent,
                  sourceSwingSupport: sourceSwingSupport)
    }
}

public protocol GrooveCritic: Critic {
    func review(_ input: GrooveReview) -> [Finding]
}

// MARK: - The board

/// Every critic the app ships, and the two calls that run them.
///
/// A value rather than a singleton, for the same reason `FeelLibrary` is: a project that has muted
/// one check holds its own board, and the shipped set stays diffable code.
public struct CriticBoard: Sendable {
    public var chopCritics: [any ChopCritic]
    public var grooveCritics: [any GrooveCritic]

    public init(chopCritics: [any ChopCritic] = [], grooveCritics: [any GrooveCritic] = []) {
        self.chopCritics = chopCritics
        self.grooveCritics = grooveCritics
    }

    /// Everything the app ships. Order is the order findings come back in when two critics fire on
    /// the same material, so it is the order a Check queue presents them: the cause before the
    /// consequence — a shaved attack before the level it produced.
    public static let standard = CriticBoard(
        chopCritics: [TransientCutCritic(), SliceLevelCritic(), DegradeStackCritic()],
        grooveCritics: [SwingClashCritic(), SliceClashCritic()])

    public var all: [any Critic] { (chopCritics as [any Critic]) + (grooveCritics as [any Critic]) }

    /// Findings over a chop, worst first, then by position so the order is stable.
    public func review(_ input: ChopReview) -> [Finding] {
        CriticBoard.ordered(chopCritics.flatMap { $0.review(input) })
    }

    /// Findings over a groove.
    public func review(_ input: GrooveReview) -> [Finding] {
        CriticBoard.ordered(grooveCritics.flatMap { $0.review(input) })
    }

    /// Warnings before notes, then earliest first. A stable sort, so two findings at the same
    /// instant keep the board's own order and a test can assert on the list.
    static func ordered(_ findings: [Finding]) -> [Finding] {
        findings.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            if a.element.locus.start != b.element.locus.start {
                return a.element.locus.start < b.element.locus.start
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    public func critic(_ id: CriticID) -> (any Critic)? { all.first { $0.id == id } }
}
