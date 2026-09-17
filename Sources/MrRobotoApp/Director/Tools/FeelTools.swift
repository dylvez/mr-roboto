import Foundation
import MusicTheory
import Performance
import SongGraph

// The feel library, read-only. Two tools rather than one: a list the band can scan cheaply, and a
// description it asks for once it has narrowed the choice — the step grid of twenty-five feels in
// every reply would be most of a context window spent on feels nobody picked.

// MARK: - list_feels

/// What the library has, filtered.
public struct ListFeelsTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var tempo: Double?
        public var idiom: String?
        public var beatsPerBar: Int?
        public var limit: Int?

        enum CodingKeys: String, CodingKey {
            case tempo, idiom, limit
            case beatsPerBar = "beats_per_bar"
        }
    }

    public struct Output: Encodable, Sendable {
        public var count: Int
        public var idioms: [String]
        public var feels: [Feel]

        public struct Feel: Encodable, Sendable {
            public var name: String
            public var idioms: [String]
            public var tempoLow: Double
            public var tempoHigh: Double
            public var suggestedTempo: Double
            public var timeSignature: String
            public var stepsPerBar: Int
            public var bars: Int
            public var swingPercent: Double
            public var voices: [String]
            public var summary: String

            enum CodingKeys: String, CodingKey {
                case name, idioms, bars, voices, summary
                case tempoLow = "tempo_low"
                case tempoHigh = "tempo_high"
                case suggestedTempo = "suggested_tempo"
                case timeSignature = "time_signature"
                case stepsPerBar = "steps_per_bar"
                case swingPercent = "swing_percent"
            }
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "list_feels"
    public var purpose: String {
        "List the grooves the app knows, optionally narrowed by tempo, idiom or metre. Each one "
        + "comes back with its tempo range, its swing and a sentence about where it comes from. "
        + "Use describe_feel for the step grid of the one you choose."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("tempo", Schema.optional(Schema.number("Only feels that suit this tempo, in BPM.", minimum: 20, maximum: 300))),
            ("idiom", Schema.optional(Schema.string("Only feels tagged with this idiom, e.g. \"boom-bap\", \"lo-fi\", \"soul\"."))),
            ("beats_per_bar", Schema.optional(Schema.integer("Only feels in this metre: 4 for 4/4, 3 for 3/4.", minimum: 1, maximum: 16))),
            ("limit", Schema.optional(Schema.integer("How many to return. Defaults to 8.", minimum: 1, maximum: 40))),
        ], required: ["tempo", "idiom", "beats_per_bar", "limit"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = workbench.engines.feels
        let signature = input.beatsPerBar.map { TimeSignature(beatsPerBar: $0) }
        let idiom = input.idiom.map { Idiom($0) }
        var matches = library.feels(idiom: idiom, tempo: input.tempo, timeSignature: signature)
        if matches.isEmpty, input.tempo != nil || idiom != nil {
            // An empty list is a dead end for the model, and the library is small enough that
            // "nothing matched exactly, here is what is nearest" is more use than nothing.
            matches = library.suggest(for: FeelLibrary.Request(tempo: input.tempo, idiom: idiom,
                                                              timeSignature: signature,
                                                              limit: input.limit ?? 8))
        }
        let limited = Array(matches.prefix(max(1, input.limit ?? 8)))
        return Output(count: limited.count,
                      idioms: library.idioms.map(\.rawValue),
                      feels: limited.map(Self.summary(of:)))
    }

    static func summary(of feel: Performance.Feel) -> Output.Feel {
        Output.Feel(name: feel.name,
                    idioms: feel.idioms.map(\.rawValue),
                    tempoLow: feel.tempoRange.lowerBound,
                    tempoHigh: feel.tempoRange.upperBound,
                    suggestedTempo: feel.suggestedTempo,
                    timeSignature: "\(feel.timeSignature)",
                    stepsPerBar: feel.stepsPerBar,
                    bars: feel.bars,
                    swingPercent: (feel.swing.percent * 10).rounded() / 10,
                    voices: feel.voiceNames.map(\.rawValue),
                    summary: feel.provenance.summary)
    }
}

// MARK: - describe_feel

/// One feel, in full: the grid, step by step, voice by voice.
public struct DescribeFeelTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var name: String
    }

    public struct Output: Encodable, Sendable {
        public var name: String
        public var idioms: [String]
        public var suggestedTempo: Double
        public var timeSignature: String
        public var stepsPerBar: Int
        public var bars: Int
        public var swingPercent: Double
        public var origin: String
        public var summary: String
        public var source: String?
        public var patterns: [Pattern]

        /// One voice's line, written out so it can be read at a glance: `.` rest, `g` ghost,
        /// `x` normal, `X` accent.
        public struct Pattern: Encodable, Sendable {
            public var voice: String
            public var steps: String
            public var hits: Int
        }

        enum CodingKeys: String, CodingKey {
            case name, idioms, bars, origin, summary, source, patterns
            case suggestedTempo = "suggested_tempo"
            case timeSignature = "time_signature"
            case stepsPerBar = "steps_per_bar"
            case swingPercent = "swing_percent"
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "describe_feel"
    public var purpose: String {
        "The whole of one feel: every voice's step pattern written out (. rest, g ghost, x normal, "
        + "X accent), its swing, its metre and where it comes from."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("name", Schema.string("The feel's name, exactly as list_feels gave it.")),
        ], required: ["name"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = workbench.engines.feels
        guard let feel = library.feel(named: input.name) else {
            throw DirectorToolFailure(
                tool: name,
                reason: "There is no feel called \"\(input.name)\".",
                suggestion: "Call list_feels to see the names.")
        }
        return Output(name: feel.name,
                      idioms: feel.idioms.map(\.rawValue),
                      suggestedTempo: feel.suggestedTempo,
                      timeSignature: "\(feel.timeSignature)",
                      stepsPerBar: feel.stepsPerBar,
                      bars: feel.bars,
                      swingPercent: (feel.swing.percent * 10).rounded() / 10,
                      origin: feel.provenance.origin.rawValue,
                      summary: feel.provenance.summary,
                      source: feel.provenance.source,
                      patterns: feel.groove.patterns.map { pattern in
                          Output.Pattern(voice: pattern.voice.rawValue,
                                         steps: String(pattern.steps.map(DirectorFeelNotation.character(for:))),
                                         hits: pattern.steps.filter { $0 != .rest }.count)
                      })
    }
}

/// How a step pattern is written down for the model, and read back from it.
public enum DirectorFeelNotation {
    public static func character(for tier: VelocityTier) -> Character {
        switch tier {
        case .rest: "."
        case .ghost: "g"
        case .normal: "x"
        case .accent: "X"
        }
    }

    public static func tier(for character: Character) -> VelocityTier? {
        switch character {
        case ".", "-", "0": .rest
        case "g": .ghost
        case "x": .normal
        case "X": .accent
        default: nil
        }
    }
}
