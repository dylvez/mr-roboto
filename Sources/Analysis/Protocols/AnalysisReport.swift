import Foundation
import MusicTheory

/// Everything the analysis layer knows about one audio file: the aggregate a Song's analysis part
/// is built from. Every field is optional because providers fill it capability by capability;
/// `capabilities` says which were actually run and `provenance` by whom.
public struct AnalysisReport: Hashable, Codable, Sendable {
    /// Path of the analysed file.
    public var sourcePath: String
    /// Duration in seconds, when known.
    public var duration: Double?

    public var key: KeyEstimate?
    public var beats: BeatTrackingResult?
    public var structure: StructureAnalysis?
    public var loudness: LoudnessAnalysis?
    public var instruments: InstrumentActivity?
    /// Pace (a perceived-speed figure) over time, from providers that measure it.
    public var pace: [RangedSample]?

    /// Capabilities that were run for this report.
    public var capabilities: Set<AnalysisCapability>
    /// Which provider produced each capability.
    public var provenance: [AnalysisCapability: String]
    public var analyzedAt: Date
    /// Seconds of analysis wall time, summed over the runs merged into this report.
    public var wallTime: Double
    /// Human-readable caveats: mapping fallbacks, dropped values, anything the numbers do not show.
    public var notes: [String]
    /// A second beat tracker's check of `beats`, when one ran.
    public var beatCheck: BeatCheck?

    public init(sourcePath: String, duration: Double? = nil, key: KeyEstimate? = nil, beats: BeatTrackingResult? = nil,
                structure: StructureAnalysis? = nil, loudness: LoudnessAnalysis? = nil, instruments: InstrumentActivity? = nil,
                pace: [RangedSample]? = nil, capabilities: Set<AnalysisCapability> = [], provenance: [AnalysisCapability: String] = [:],
                analyzedAt: Date = Date(), wallTime: Double = 0, notes: [String] = []) {
        self.sourcePath = sourcePath
        self.duration = duration
        self.key = key
        self.beats = beats
        self.structure = structure
        self.loudness = loudness
        self.instruments = instruments
        self.pace = pace
        self.capabilities = capabilities
        self.provenance = provenance
        self.analyzedAt = analyzedAt
        self.wallTime = wallTime
        self.notes = notes
    }

    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    /// The beat grid, when beats were tracked.
    public var beatGrid: BeatGrid? { beats?.grid }

    /// The dominant key, when a key was estimated.
    public var dominantKey: Key? { key?.dominantKey }

    /// This report with `other`'s results filled in wherever this one has none. Capabilities,
    /// provenance and notes are unioned; wall time is summed.
    public func merging(_ other: AnalysisReport) -> AnalysisReport {
        var merged = self
        if merged.duration == nil { merged.duration = other.duration }
        if merged.key == nil { merged.key = other.key }
        if merged.beats == nil { merged.beats = other.beats }
        if merged.structure == nil { merged.structure = other.structure }
        if merged.loudness == nil { merged.loudness = other.loudness }
        if merged.instruments == nil { merged.instruments = other.instruments }
        if merged.pace == nil { merged.pace = other.pace }
        if merged.beatCheck == nil { merged.beatCheck = other.beatCheck }
        merged.capabilities.formUnion(other.capabilities)
        merged.provenance.merge(other.provenance) { mine, _ in mine }
        merged.wallTime += other.wallTime
        for note in other.notes where !merged.notes.contains(note) { merged.notes.append(note) }
        return merged
    }

    // MARK: JSON

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// Pretty-printed, key-sorted JSON.
    public func jsonData() throws -> Data { try AnalysisReport.encoder.encode(self) }

    public func jsonString() throws -> String { String(decoding: try jsonData(), as: UTF8.self) }

    /// Writes the JSON dump to `url`, creating parent directories.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    public init(jsonData data: Data) throws {
        self = try AnalysisReport.decoder.decode(AnalysisReport.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }

    /// A one-screen summary for logs and CLI output.
    public var summary: String {
        var lines = ["\(sourceURL.lastPathComponent)" + (duration.map { String(format: " (%.1f s)", $0) } ?? "")]
        if let key { lines.append("key: " + (key.dominantKey?.name ?? "unknown") + (key.isStable ? "" : " (\(key.ranges.count) ranges)")) }
        if let beats {
            let bpm = beats.bpm.map { String(format: "%.1f", $0) } ?? "?"
            lines.append("beats: \(beats.beats.count), bars: \(beats.downbeats.count), bpm: \(bpm), meter: \(beats.grid.timeSignature)")
        }
        if let structure { lines.append("structure: \(structure.sections.count) sections, \(structure.segments.count) segments, \(structure.phrases.count) phrases") }
        if let loudness { lines.append(String(format: "loudness: %.1f LUFS integrated, peak %.1f dB", loudness.integrated, loudness.truePeak)) }
        if let instruments {
            lines.append("instruments: " + instruments.instruments.map { String(format: "%@ %.0fs", $0.rawValue, instruments.presentDuration(of: $0)) }.joined(separator: ", "))
        }
        lines.append("providers: " + provenance.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        if wallTime > 0 { lines.append(String(format: "analysis time: %.1f s", wallTime)) }
        for note in notes { lines.append("note: \(note)") }
        return lines.joined(separator: "\n")
    }
}
