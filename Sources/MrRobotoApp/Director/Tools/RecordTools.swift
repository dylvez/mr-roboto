import Analysis
import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph

// The first three things that happen to a record: it comes in, it gets read, and its bars get
// named. Then, when the band wants only the drums, it gets separated.

// MARK: - import_record

/// Brings an audio file into the session.
public struct ImportRecordTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var path: String
    }

    public struct Output: Encodable, Sendable {
        public var audio: String
        public var name: String
        public var durationSeconds: Double
        public var sampleRate: Double
        public var channels: Int
        /// The content hash it was stored under, when this session has a library to store it in.
        public var media: String?
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case audio, name, channels, media, note
            case durationSeconds = "duration_seconds"
            case sampleRate = "sample_rate"
        }
    }

    let workbench: DirectorWorkbench
    let workspace: any DirectorWorkspace

    public init(workbench: DirectorWorkbench, workspace: any DirectorWorkspace) {
        self.workbench = workbench
        self.workspace = workspace
    }

    public let name = "import_record"
    public var purpose: String {
        "Read an audio file from disk into the session and, when there is a library, store it by "
        + "content hash. Returns an audio handle every later tool refers to."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("path", Schema.string("Absolute path to an audio file the user named.")),
        ], required: ["path"])
    }

    public func run(_ input: Input) async throws -> Output {
        let url = URL(fileURLWithPath: input.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DirectorToolFailure(tool: name, reason: "There is no file at \(url.path).")
        }
        let handle: String
        do {
            handle = try await workbench.loadAudio(at: url)
        } catch let failure as DirectorToolFailure {
            throw failure
        } catch {
            throw DirectorToolFailure(tool: name, reason: "\(url.lastPathComponent) could not be read: \(error)")
        }
        let loaded = try await workbench.audio(handle)

        // Storing is a separate question from reading, and a session with no library directory is
        // a legitimate session — the tool says the handle is good and the store is not.
        var media: String?
        var note: String?
        if let store = await workspace.store {
            do {
                let ref = try store.addMedia(copying: url, kind: .record)
                await workbench.setMedia(ref, for: handle)
                media = ref.hash.short
            } catch {
                note = "It was read but not stored: \(error)"
            }
        } else {
            note = "This session has no library directory, so nothing was written to disk."
        }

        return Output(audio: handle,
                      name: url.deletingPathExtension().lastPathComponent,
                      durationSeconds: (loaded.duration * 1000).rounded() / 1000,
                      sampleRate: loaded.sampleRate,
                      channels: loaded.channelCount,
                      media: media,
                      note: note)
    }
}

// MARK: - analyse_record

/// Key, tempo, sections, loudness. What the record is, before anyone decides what to do with it.
public struct AnalyseRecordTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var audio: String
    }

    public struct Output: Encodable, Sendable {
        public var audio: String
        public var durationSeconds: Double
        public var key: String?
        public var tempo: Double?
        public var timeSignature: String?
        public var barCount: Int
        public var beatCount: Int
        public var sections: [Section]
        public var loudnessLUFS: Double?
        public var analysers: [String]
        public var notes: [String]

        public struct Section: Encodable, Sendable {
            public var index: Int
            public var startSeconds: Double
            public var endSeconds: Double
            enum CodingKeys: String, CodingKey {
                case index
                case startSeconds = "start_seconds"
                case endSeconds = "end_seconds"
            }
        }

        enum CodingKeys: String, CodingKey {
            case audio, key, tempo, sections, analysers, notes
            case durationSeconds = "duration_seconds"
            case timeSignature = "time_signature"
            case barCount = "bar_count"
            case beatCount = "beat_count"
            case loudnessLUFS = "loudness_lufs"
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "analyse_record"
    public var purpose: String {
        "Run whole-track analysis on an imported record: key, tempo, beat grid, sections and "
        + "loudness. The result is kept, so list_bars and chop_bar can use it afterwards."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("audio", Schema.string("An audio handle from import_record.")),
        ], required: ["audio"])
    }

    public func run(_ input: Input) async throws -> Output {
        let loaded = try await workbench.audio(input.audio)
        let providers = workbench.engines.providers
        let report: AnalysisReport
        do {
            report = try await providers.analyze(url: loaded.url)
        } catch {
            throw DirectorToolFailure(tool: name, reason: "\(loaded.url.lastPathComponent) could not be analysed: \(error)")
        }
        await workbench.store(report, for: input.audio)

        let grid = report.beatGrid
        return Output(audio: input.audio,
                      durationSeconds: (loaded.duration * 1000).rounded() / 1000,
                      key: report.dominantKey.map { "\($0)" },
                      tempo: (report.beats?.bpm).map { ($0 * 10).rounded() / 10 },
                      timeSignature: grid.map { "\($0.timeSignature)" },
                      barCount: grid?.barCount ?? 0,
                      beatCount: grid?.beatCount ?? 0,
                      sections: (report.structure?.sections ?? []).enumerated().map { index, range in
                          Output.Section(index: index,
                                         startSeconds: (range.start * 100).rounded() / 100,
                                         endSeconds: (range.end * 100).rounded() / 100)
                      },
                      loudnessLUFS: (report.loudness?.integrated).map { ($0 * 10).rounded() / 10 },
                      analysers: report.provenance.values.sorted().reduce(into: [String]()) {
                          if !$0.contains($1) { $0.append($1) }
                      },
                      notes: report.notes)
    }
}

// MARK: - list_bars

/// Where the bars are. The tool that turns "the bar after the turnaround" into a number.
public struct ListBarsTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var audio: String
        public var fromBar: Int?
        public var count: Int?

        enum CodingKeys: String, CodingKey {
            case audio
            case fromBar = "from_bar"
            case count
        }
    }

    public struct Output: Encodable, Sendable {
        public var audio: String
        public var barCount: Int
        public var tempo: Double?
        public var bars: [Bar]

        public struct Bar: Encodable, Sendable {
            public var index: Int
            public var startSeconds: Double
            public var endSeconds: Double
            enum CodingKeys: String, CodingKey {
                case index
                case startSeconds = "start_seconds"
                case endSeconds = "end_seconds"
            }
        }

        enum CodingKeys: String, CodingKey {
            case audio, tempo, bars
            case barCount = "bar_count"
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "list_bars"
    public var purpose: String {
        "List the bars of an analysed record with their start and end times, so a bar can be "
        + "chosen by number. Defaults to the first sixteen; ask for a window with from_bar and count."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("audio", Schema.string("An audio handle that analyse_record has already been run on.")),
            ("from_bar", Schema.optional(Schema.integer("First bar to list, zero-based. Defaults to 0.", minimum: 0))),
            ("count", Schema.optional(Schema.integer("How many bars to list. Defaults to 16.", minimum: 1, maximum: 128))),
        ], required: ["audio", "from_bar", "count"])
    }

    public func run(_ input: Input) async throws -> Output {
        let report = try await workbench.analysis(input.audio)
        guard let grid = report.beatGrid, grid.barCount > 0 else {
            throw DirectorToolFailure(tool: name,
                                      reason: "The analysis of \(input.audio) found no bars.",
                                      suggestion: "Chop by divisions instead, or pick a span in seconds.")
        }
        let start = max(0, input.fromBar ?? 0)
        let limit = min(input.count ?? 16, 128)
        let end = min(grid.barCount, start + limit)
        guard start < grid.barCount else {
            throw DirectorToolFailure(tool: name,
                                      reason: "Bar \(start) is past the end; this record has \(grid.barCount) bars.")
        }
        let bars = (start..<end).compactMap { index -> Output.Bar? in
            guard let bounds = grid.bounds(ofBar: index) else { return nil }
            return Output.Bar(index: index,
                              startSeconds: (bounds.start * 100).rounded() / 100,
                              endSeconds: (bounds.end * 100).rounded() / 100)
        }
        return Output(audio: input.audio, barCount: grid.barCount,
                      tempo: grid.bpm.map { ($0 * 10).rounded() / 10 }, bars: bars)
    }
}

// MARK: - separate_stems

/// Pulls the drums out from under everything else.
public struct SeparateStemsTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var audio: String
        public var stems: [String]?
    }

    public struct Output: Encodable, Sendable {
        public var model: String
        public var seconds: Double
        public var stems: [Stem]

        public struct Stem: Encodable, Sendable {
            public var name: String
            public var audio: String
            public var durationSeconds: Double
            enum CodingKeys: String, CodingKey {
                case name, audio
                case durationSeconds = "duration_seconds"
            }
        }
    }

    let workbench: DirectorWorkbench

    public init(workbench: DirectorWorkbench) { self.workbench = workbench }

    public let name = "separate_stems"
    public var purpose: String {
        "Separate a record into stems (vocals, drums, bass, other). Each stem comes back as its "
        + "own audio handle, so a bar can be chopped out of the drums alone. Slow: about a minute "
        + "for a three-minute record."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("audio", Schema.string("An audio handle from import_record.")),
            ("stems", Schema.optional(Schema.array("Which stems to keep. All of them when null.",
                                                   of: Schema.string("A stem name.",
                                                                     enum: StemName.allCases.map(\.rawValue))))),
        ], required: ["audio", "stems"])
    }

    public func run(_ input: Input) async throws -> Output {
        let loaded = try await workbench.audio(input.audio)
        guard let separator = workbench.engines.separator else {
            throw DirectorToolFailure(
                tool: name,
                reason: "This build has no separation model loaded, so nothing can be separated.",
                suggestion: "Chop the whole record instead, or ask the user to separate it on the Import surface.")
        }
        let wanted = input.stems.map { Set($0.compactMap(StemName.init(rawValue:))) }
        let result: StemSeparationResult
        do {
            result = try await separator.separate(.file(loaded.url),
                                                  options: StemSeparationOptions(stems: wanted))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DirectorToolFailure(tool: name, reason: "Separation failed: \(error)")
        }

        var stems: [Output.Stem] = []
        for stem in result.stems {
            guard let handle = try await adopt(stem, sampleRate: loaded.sampleRate) else { continue }
            let audio = try await workbench.audio(handle)
            stems.append(Output.Stem(name: stem.name.rawValue, audio: handle,
                                     durationSeconds: (audio.duration * 100).rounded() / 100))
        }
        guard !stems.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "The separator returned no usable stems.")
        }
        return Output(model: result.model, seconds: (result.wallTime * 10).rounded() / 10, stems: stems)
    }

    /// A stem arrives as a buffer, a file, or both. Either is adopted onto the workbench; neither
    /// is an error the model can do anything about, so an unusable stem is skipped rather than
    /// failing the whole separation.
    private func adopt(_ stem: Stem, sampleRate: Double) async throws -> String? {
        if let url = stem.fileURL {
            return try? await workbench.loadAudio(at: url)
        }
        guard let buffer = stem.buffer else { return nil }
        let planar = Self.planar(of: buffer)
        guard !planar.isEmpty else { return nil }
        return await workbench.adopt(planar: planar,
                                     sampleRate: buffer.format.sampleRate,
                                     url: URL(fileURLWithPath: "/dev/null/\(stem.name.rawValue)"))
    }

    /// A read-only buffer's samples, channel by channel. Separators in this app produce float32
    /// deinterleaved buffers; anything else is skipped rather than silently misread.
    private static func planar(of buffer: AVReadOnlyAudioPCMBuffer) -> [[Float]] {
        let mutable = AVAudioPCMBuffer(copying: buffer)
        let frames = Int(mutable.frameLength)
        guard frames > 0, let data = mutable.floatChannelData else { return [] }
        return (0..<Int(mutable.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frames))
        }
    }
}
