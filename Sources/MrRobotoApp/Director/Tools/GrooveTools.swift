import Foundation
import MusicTheory
import Performance
import SongGraph

// Putting the chop on the feel, and then moving it around: swing, velocity, and listening to it.

/// Everything it takes to produce one re-groove. Kept alongside the result so an adjustment is the
/// same run with one number changed rather than an edit to a list of hits.
public struct DirectorGroovePlan: Sendable, Equatable {
    public var chop: String
    public var feel: String
    public var tempo: Double
    public var bars: Int
    /// Overrides the feel's own swing when set, 50…75.
    public var swingPercent: Double?
    public var velocityScale: Double
    public var overlap: Regroove.Overlap
    public var rotate: Bool
    public var timeSignature: TimeSignature

    public init(chop: String, feel: String, tempo: Double, bars: Int,
                swingPercent: Double? = nil, velocityScale: Double = 1,
                overlap: Regroove.Overlap = .ring, rotate: Bool = true,
                timeSignature: TimeSignature = .fourFour) {
        self.chop = chop
        self.feel = feel
        self.tempo = tempo
        self.bars = bars
        self.swingPercent = swingPercent
        self.velocityScale = velocityScale
        self.overlap = overlap
        self.rotate = rotate
        self.timeSignature = timeSignature
    }
}

/// Runs a plan. The one place the re-groove engine is called, so the three tools that produce a
/// groove cannot drift apart.
public enum DirectorRegroove {
    public static func perform(_ plan: DirectorGroovePlan,
                               workbench: DirectorWorkbench,
                               tool: String) async throws -> RegroovePerformance {
        let stored = try await workbench.chop(plan.chop)
        guard !stored.classifications.isEmpty else {
            throw DirectorToolFailure(
                tool: tool,
                reason: "\(plan.chop) has not been classified, so its slices have no voices to land on.",
                suggestion: "Call classify_slices on it first.")
        }
        let library = workbench.engines.feels
        guard var feel = library.feel(named: plan.feel) else {
            throw DirectorToolFailure(tool: tool, reason: "There is no feel called \"\(plan.feel)\".",
                                      suggestion: "Call list_feels to see the names.")
        }
        if let percent = plan.swingPercent { feel = feel.swung(percent: percent) }

        let bars = max(1, plan.bars)
        let grid = BeatGrid.regular(bpm: plan.tempo, timeSignature: plan.timeSignature,
                                    bars: bars * max(1, feel.bars))
        let policy = Regroove.Policy(overlap: plan.overlap, rotate: plan.rotate,
                                     velocityScale: plan.velocityScale)
        do {
            return try Regroove(policy: policy).perform(ChopMap.pads(stored.chop, name: plan.feel),
                                                        classifications: stored.classifications,
                                                        groove: feel.groove, grid: grid,
                                                        startBar: 0, repeats: bars)
        } catch {
            throw DirectorToolFailure(tool: tool, reason: "The re-groove failed: \(error)")
        }
    }

    /// What a performance looks like from outside: counts and voices, never hits.
    public static func summary(_ performance: RegroovePerformance,
                               handle: String, plan: DirectorGroovePlan) -> GrooveSummary {
        var byVoice: [String: Int] = [:]
        for placement in performance.placements { byVoice[placement.voice.rawValue, default: 0] += 1 }
        return GrooveSummary(
            groove: handle,
            feel: plan.feel,
            tempo: plan.tempo,
            bars: plan.bars,
            swingPercent: (((plan.swingPercent ?? 50) * 10).rounded()) / 10,
            velocityScale: (plan.velocityScale * 100).rounded() / 100,
            durationSeconds: (performance.duration * 100).rounded() / 100,
            placements: performance.placements.count,
            unplacedSteps: performance.unplacedSteps,
            overruns: performance.placements.filter(\.overruns).count,
            substituted: performance.substitutedClasses.map(\.rawValue).sorted(),
            hitsByVoice: byVoice)
    }
}

/// The shape every groove-producing tool answers with.
public struct GrooveSummary: Encodable, Sendable {
    public var groove: String
    public var feel: String
    public var tempo: Double
    public var bars: Int
    public var swingPercent: Double
    public var velocityScale: Double
    public var durationSeconds: Double
    public var placements: Int
    public var unplacedSteps: Int
    public var overruns: Int
    public var substituted: [String]
    public var hitsByVoice: [String: Int]

    enum CodingKeys: String, CodingKey {
        case groove, feel, tempo, bars, placements, overruns, substituted
        case swingPercent = "swing_percent"
        case velocityScale = "velocity_scale"
        case durationSeconds = "duration_seconds"
        case unplacedSteps = "unplaced_steps"
        case hitsByVoice = "hits_by_voice"
    }
}

// MARK: - regroove_chop

/// Lays a chop's slices onto a feel's grid.
public struct RegrooveChopTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var chop: String
        public var feel: String
        public var tempo: Double?
        public var bars: Int?
        public var overlap: String?
        public var rotate: Bool?
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "regroove_chop"
    public var purpose: String {
        "Play a classified chop's slices through a feel: each step of the feel's pattern takes a "
        + "slice of the matching kind. Returns a groove handle, how many steps found a slice and "
        + "how many did not."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("chop", Schema.string("A chop handle that classify_slices has been run on.")),
            ("feel", Schema.string("A feel name from list_feels.")),
            ("tempo", Schema.optional(Schema.number("Tempo in BPM. Defaults to the feel's suggested tempo.", minimum: 20, maximum: 300))),
            ("bars", Schema.optional(Schema.integer("How many bars to lay down. Defaults to 2.", minimum: 1, maximum: 32))),
            ("overlap", Schema.optional(Schema.string("What happens when a slice is longer than its step: ring lets it ring on, stretch_to_fit squeezes it. Defaults to ring.",
                                                      enum: ["ring", "stretch_to_fit"]))),
            ("rotate", Schema.optional(Schema.boolean("Cycle through the slices of a kind rather than reusing the first. Defaults to true."))),
        ], required: ["chop", "feel", "tempo", "bars", "overlap", "rotate"])
    }

    public func run(_ input: Input) async throws -> GrooveSummary {
        let library = workbench.engines.feels
        guard let feel = library.feel(named: input.feel) else {
            throw DirectorToolFailure(tool: name, reason: "There is no feel called \"\(input.feel)\".",
                                      suggestion: "Call list_feels to see the names.")
        }
        let overlap: Regroove.Overlap
        switch input.overlap {
        case nil, "ring": overlap = .ring
        case "stretch_to_fit": overlap = .stretchToFit
        case let other?:
            throw DirectorToolFailure(tool: name, reason: "\"\(other)\" is not an overlap mode.",
                                      suggestion: "Use \"ring\" or \"stretch_to_fit\".")
        }
        let plan = DirectorGroovePlan(chop: input.chop, feel: feel.name,
                                      tempo: input.tempo ?? feel.suggestedTempo,
                                      bars: input.bars ?? 2,
                                      swingPercent: nil,
                                      velocityScale: 1,
                                      overlap: overlap,
                                      rotate: input.rotate ?? true,
                                      timeSignature: feel.timeSignature)
        let performance = try await DirectorRegroove.perform(plan, workbench: workbench, tool: name)
        let handle = await workbench.store(performance, plan: plan)
        var summary = DirectorRegroove.summary(performance, handle: handle, plan: plan)
        // With no override, the swing on show is the feel's own rather than a straight 50.
        summary.swingPercent = (feel.swing.percent * 10).rounded() / 10
        return summary
    }
}

// MARK: - set_swing

/// Moves the off-beats.
public struct SetSwingTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var groove: String
        public var percent: Double
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "set_swing"
    public var purpose: String {
        "Set how far the off-beats of a groove are pushed late, as a percentage: 50 is straight, "
        + "66.7 is triplet, 75 is the far end. Re-runs the re-groove with the new value and "
        + "replaces the groove in place."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("groove", Schema.string("A groove handle from regroove_chop.")),
            ("percent", Schema.number("Where the off-beat lands, 50 (straight) to 75.", minimum: 50, maximum: 75)),
        ], required: ["groove", "percent"])
    }

    public func run(_ input: Input) async throws -> GrooveSummary {
        let stored = try await workbench.groove(input.groove)
        var plan = stored.plan
        // Clamped rather than refused: `Swing` clamps too, and a model that asks for 80 means
        // "as far as it goes", which is 75.
        plan.swingPercent = Swing(percent: input.percent).percent
        let performance = try await DirectorRegroove.perform(plan, workbench: workbench, tool: name)
        try await workbench.replace(performance, plan: plan, at: input.groove)
        return DirectorRegroove.summary(performance, handle: input.groove, plan: plan)
    }
}

// MARK: - set_velocity

/// Makes the whole thing harder or softer.
public struct SetVelocityTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var groove: String
        public var scale: Double
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "set_velocity"
    public var purpose: String {
        "Scale how hard a groove is played. 1 is the feel as written; 0.7 backs it off, 1.2 leans "
        + "on it. The shape — which steps are ghosts and which are accents — belongs to the feel "
        + "and is not changed by this."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("groove", Schema.string("A groove handle from regroove_chop.")),
            ("scale", Schema.number("Multiplier on every hit's velocity, 0.2 to 1.5.", minimum: 0.2, maximum: 1.5)),
        ], required: ["groove", "scale"])
    }

    public func run(_ input: Input) async throws -> GrooveSummary {
        let stored = try await workbench.groove(input.groove)
        var plan = stored.plan
        plan.velocityScale = min(1.5, max(0.2, input.scale))
        let performance = try await DirectorRegroove.perform(plan, workbench: workbench, tool: name)
        try await workbench.replace(performance, plan: plan, at: input.groove)
        return DirectorRegroove.summary(performance, handle: input.groove, plan: plan)
    }
}

// MARK: - audition

/// Plays it.
public struct AuditionTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var groove: String
        public var bars: Int?
    }

    public struct Output: Encodable, Sendable {
        public var played: Bool
        public var detail: String
        public var bars: Int
        public var tempo: Double
    }

    let workbench: DirectorWorkbench
    let audition: (any DirectorAudition)?

    public init(workbench: DirectorWorkbench, audition: (any DirectorAudition)?) {
        self.workbench = workbench
        self.audition = audition
    }

    public let name = "audition"
    public var purpose: String {
        "Play a groove out loud for the user. Says honestly whether it actually made a sound — on "
        + "a machine with no audio device it did not, and the groove is no less real for that."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("groove", Schema.string("A groove handle from regroove_chop.")),
            ("bars", Schema.optional(Schema.integer("How many bars to play. Defaults to the whole groove.", minimum: 1, maximum: 32))),
        ], required: ["groove", "bars"])
    }

    public func run(_ input: Input) async throws -> Output {
        // A version id from read_song is not a handle. It used to fail as "there is no groove
        // called 969F04C7-…, nothing of that kind has been made yet", about a groove in the song.
        if UUID(uuidString: input.groove) != nil {
            throw DirectorToolFailure(
                tool: name,
                reason: "\(input.groove) is a version in the song, and audition plays a groove handle from regroove_chop.",
                suggestion: "The song's own parts are heard on the transport, by the user, and in compare_section. Say what to listen for instead.")
        }
        let stored = try await workbench.groove(input.groove)
        let bars = input.bars.map { min($0, stored.plan.bars) } ?? stored.plan.bars
        guard let audition else {
            return Output(played: false, detail: DirectorAuditionOutcome.silent.detail,
                          bars: bars, tempo: stored.plan.tempo)
        }
        let request = DirectorAuditionRequest(handle: input.groove, bars: bars, tempo: stored.plan.tempo)
        let outcome = await audition.audition(request)
        return Output(played: outcome.played, detail: outcome.detail,
                      bars: bars, tempo: stored.plan.tempo)
    }
}
