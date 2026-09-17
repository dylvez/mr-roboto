import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph

// Cutting a bar up, and saying what each piece is.

// MARK: - chop_bar

/// Cuts a span of a record into slices.
public struct ChopBarTool: DirectorTool {
    /// How to decide where the cuts go.
    public enum Method: String, Decodable, Sendable, CaseIterable {
        /// Where the transients are, snapped to the grid when one is near.
        case onsets
        /// On the beat grid, at `division` per beat.
        case grid
        /// Into `division` equal pieces, ignoring the grid entirely.
        case divisions
    }

    public struct Input: Decodable, Sendable {
        public var audio: String
        public var bar: Int?
        public var startSeconds: Double?
        public var endSeconds: Double?
        public var method: Method?
        public var division: Int?

        enum CodingKeys: String, CodingKey {
            case audio, bar, method, division
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    public struct Output: Encodable, Sendable {
        public var chop: String
        public var audio: String
        public var bar: Int?
        public var startSeconds: Double
        public var durationSeconds: Double
        public var sliceCount: Int
        public var slices: [Slice]

        public struct Slice: Encodable, Sendable {
            public var index: Int
            public var startSeconds: Double
            public var durationSeconds: Double
            public var origin: String
            public var peakDB: Double
            enum CodingKeys: String, CodingKey {
                case index, origin
                case startSeconds = "start_seconds"
                case durationSeconds = "duration_seconds"
                case peakDB = "peak_db"
            }
        }

        enum CodingKeys: String, CodingKey {
            case chop, audio, bar, slices
            case startSeconds = "start_seconds"
            case durationSeconds = "duration_seconds"
            case sliceCount = "slice_count"
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "chop_bar"
    public var purpose: String {
        "Cut one bar — or any span in seconds — of a record into slices, at its transients or on "
        + "its grid. Returns a chop handle and the slices, which classify_slices and regroove_chop "
        + "then work on."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("audio", Schema.string("An audio handle. Chopping the drums stem gives cleaner slices than the full mix.")),
            ("bar", Schema.optional(Schema.integer("Bar to cut, zero-based, as list_bars numbers them. Needs analyse_record first.", minimum: 0))),
            ("start_seconds", Schema.optional(Schema.number("Start of the span, when naming one directly instead of a bar.", minimum: 0))),
            ("end_seconds", Schema.optional(Schema.number("End of the span.", minimum: 0))),
            ("method", Schema.optional(Schema.string("Where the cuts go. Defaults to onsets.",
                                                     enum: Method.allCases.map(\.rawValue)))),
            ("division", Schema.optional(Schema.integer("Grid divisions per beat for grid, or the number of equal pieces for divisions. Defaults to 4.", minimum: 1, maximum: 32))),
        ], required: ["audio", "bar", "start_seconds", "end_seconds", "method", "division"])
    }

    public func run(_ input: Input) async throws -> Output {
        let source = try await workbench.audio(input.audio)
        let grid = await workbench.hasAnalysis(input.audio) ? try? await workbench.analysis(input.audio).beatGrid : nil
        let span = try Self.span(input, grid: grid, duration: source.duration, tool: name)

        // The bar becomes its own audio on the workbench. That is what keeps the later steps
        // honest: a chop's frame ranges index the excerpt it was cut from, and rendering it into a
        // kit needs exactly those frames and no others.
        let first = max(0, Int((span.start * source.sampleRate).rounded()))
        let last = min(source.frameCount, Int((span.end * source.sampleRate).rounded()))
        guard last - first > 32 else {
            throw DirectorToolFailure(tool: name,
                                      reason: String(format: "That span is %.3f s long, which holds no audio.", span.end - span.start))
        }
        let excerpt = source.planar.map { Array($0[first..<last]) }
        let handle = await workbench.adopt(planar: excerpt, sampleRate: source.sampleRate,
                                           url: source.url, media: source.media)
        let mono = try await workbench.audio(handle).mono

        let chopper = workbench.engines.chopper
        let division = max(1, input.division ?? 4)
        let offset = Double(first) / source.sampleRate
        let chop: Chop
        switch input.method ?? .onsets {
        case .onsets:
            chop = chopper.sliceByOnsets(mono, sampleRate: source.sampleRate,
                                         snappingTo: grid, division: division,
                                         sourceOffset: offset, detectedTempo: grid?.bpm)
        case .grid:
            guard let grid else {
                throw DirectorToolFailure(tool: name,
                                          reason: "There is no beat grid for \(input.audio).",
                                          suggestion: "Run analyse_record first, or use method \"divisions\".")
            }
            chop = chopper.sliceByGrid(mono, sampleRate: source.sampleRate, grid: grid,
                                       division: division, sourceOffset: offset)
        case .divisions:
            chop = chopper.sliceByDivisions(mono, sampleRate: source.sampleRate,
                                            divisions: division, sourceOffset: offset,
                                            detectedTempo: grid?.bpm)
        }
        guard !chop.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "Nothing was found to cut in that span.",
                                      suggestion: "Try method \"divisions\" to cut it evenly.")
        }

        let id = await workbench.store(chop, audio: handle, sourceOffset: offset, bar: input.bar)
        return Output(chop: id, audio: handle, bar: input.bar,
                      startSeconds: (offset * 100).rounded() / 100,
                      durationSeconds: (chop.duration * 1000).rounded() / 1000,
                      sliceCount: chop.count,
                      slices: chop.slices.map { slice in
                          Output.Slice(index: slice.index,
                                       startSeconds: (slice.startSeconds * 1000).rounded() / 1000,
                                       durationSeconds: (slice.duration * 1000).rounded() / 1000,
                                       origin: slice.origin.rawValue,
                                       peakDB: (slice.peakDB * 10).rounded() / 10)
                      })
    }

    /// Which span of the record to cut, from whichever of the three ways the model asked.
    static func span(_ input: Input, grid: BeatGrid?, duration: Double, tool: String) throws -> (start: Double, end: Double) {
        if let bar = input.bar {
            guard let grid, let bounds = grid.bounds(ofBar: bar) else {
                throw DirectorToolFailure(tool: tool,
                                          reason: "Bar \(bar) is not in the analysis of this record.",
                                          suggestion: "Run analyse_record and list_bars first, or give a span in seconds.")
            }
            return (bounds.start, min(bounds.end, duration))
        }
        if let start = input.startSeconds, let end = input.endSeconds {
            guard end > start else {
                throw DirectorToolFailure(tool: tool, reason: "end_seconds must be after start_seconds.")
            }
            return (max(0, start), min(end, duration))
        }
        throw DirectorToolFailure(tool: tool,
                                  reason: "Nothing said which part of the record to cut.",
                                  suggestion: "Give a bar, or both start_seconds and end_seconds.")
    }
}

// MARK: - classify_slices

/// Says which slice is the kick, which the snare, and which the hat.
public struct ClassifySlicesTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var chop: String
        public var overrides: [Override]?

        public struct Override: Decodable, Sendable {
            public var slice: Int
            public var kind: String
        }
    }

    public struct Output: Encodable, Sendable {
        public var chop: String
        public var counts: [String: Int]
        public var slices: [Slice]

        public struct Slice: Encodable, Sendable {
            public var index: Int
            public var kind: String
            public var confidence: Double
            public var centroidHz: Double
            public var durationSeconds: Double
            public var isOverride: Bool
            enum CodingKeys: String, CodingKey {
                case index, kind, confidence
                case centroidHz = "centroid_hz"
                case durationSeconds = "duration_seconds"
                case isOverride = "is_override"
            }
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "classify_slices"
    public var purpose: String {
        "Decide what each slice of a chop is — kick, snare or hat — from its brightness and its "
        + "length, with a confidence for each. regroove_chop needs this before it can place slices "
        + "on a feel's voices. Pass overrides to correct one the classifier got wrong."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("chop", Schema.string("A chop handle from chop_bar.")),
            ("overrides", Schema.optional(Schema.array(
                "Slices whose kind you are setting by hand, overruling the classifier.",
                of: Schema.object([
                    ("slice", Schema.integer("The slice index.", minimum: 0)),
                    ("kind", Schema.string("What it actually is.", enum: SliceClass.allCases.map(\.rawValue))),
                ], required: ["slice", "kind"])))),
        ], required: ["chop", "overrides"])
    }

    public func run(_ input: Input) async throws -> Output {
        let stored = try await workbench.chop(input.chop)
        let mono = try await workbench.audio(stored.audio).mono

        var overrides: [Int: SliceClass] = [:]
        for override in input.overrides ?? [] {
            guard let kind = SliceClass(rawValue: override.kind) else {
                throw DirectorToolFailure(
                    tool: name,
                    reason: "\"\(override.kind)\" is not a slice kind.",
                    suggestion: "Use one of: \(SliceClass.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard override.slice >= 0, override.slice < stored.chop.count else {
                throw DirectorToolFailure(tool: name,
                                          reason: "Slice \(override.slice) is not in \(input.chop), which has \(stored.chop.count).")
            }
            overrides[override.slice] = kind
        }

        let classifier = workbench.engines.classifier
        let classifications = classifier.classify(stored.chop, in: mono, overrides: overrides)
        try await workbench.setClassifications(classifications, for: input.chop)

        var counts: [String: Int] = [:]
        for kind in SliceClass.allCases { counts[kind.rawValue] = 0 }
        for classification in classifications { counts[classification.kind.rawValue, default: 0] += 1 }

        return Output(chop: input.chop, counts: counts,
                      slices: classifications.map { item in
                          Output.Slice(index: item.sliceIndex,
                                       kind: item.kind.rawValue,
                                       confidence: (item.confidence * 100).rounded() / 100,
                                       centroidHz: item.centroid.rounded(),
                                       durationSeconds: (item.duration * 1000).rounded() / 1000,
                                       isOverride: item.isOverride)
                      })
    }
}
