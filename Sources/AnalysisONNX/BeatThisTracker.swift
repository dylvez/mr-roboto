import Analysis
import Foundation
import MusicTheory
import Synchronization

/// Beat This! (Foscarin, Schlüter, Widmer, ISMIR 2024) as a `BeatTracker`, running the `final0`
/// checkpoint's ONNX export on ONNX Runtime's CPU execution provider, and, when `Options.coreMLModelURL`
/// names an installed one, its Core ML conversion on the GPU for full-length chunks.
///
/// Pipeline: decode → mono 22 050 Hz → `BeatThisFrontEnd` log-mel (50 fps) → `BeatThisChunking`
/// (1500-frame chunks, 6-frame border, keep-first) through `BeatThisCoreMLModel` or `BeatThisModel` →
/// `BeatThisPostprocessor` (the reference's `dbn=False` peak picking, then the tempo-consistency pass).
///
/// The model files are not bundled. Each is loaded lazily, once, when a chunk first needs it:
/// `modelURL` defaults to `~/Library/Application Support/MrRoboto/models/beat_this.onnx`, which
/// `Bench/python/fetch_models.py` installs, and `defaultCoreMLModelURL` is `beat_this_1500.mlmodelc`
/// beside it, which `Bench/python/convert_beat_this_coreml.py` installs. Without the Core ML model,
/// or if Core ML will not load or run it, every chunk runs on ONNX Runtime.
public final class BeatThisTracker: BeatTracker, Sendable {
    public static let name = "beat-this"
    public static let modelFileName = "beat_this.onnx"
    public static let coreMLModelFileName = "beat_this_1500.mlmodelc"

    public struct Options: Sendable {
        /// ONNX Runtime's per-op thread count; nil leaves the runtime's default (the physical cores).
        public var intraOpThreads: Int?
        public var chunking = BeatThisChunking()
        public var postprocessor = BeatThisPostprocessor()
        /// The Core ML model for full-length chunks; nil runs every chunk on ONNX Runtime.
        public var coreMLModelURL: URL?

        public init(intraOpThreads: Int? = nil, coreMLModelURL: URL? = nil) {
            self.intraOpThreads = intraOpThreads
            self.coreMLModelURL = coreMLModelURL
        }

        /// What the app runs: the installed Core ML model where it applies, ONNX Runtime elsewhere.
        public static var installed: Options { Options(coreMLModelURL: BeatThisTracker.defaultCoreMLModelURL) }
    }

    /// One run's result with what the stages produced along the way, for tests and diagnostics.
    public struct Report: Sendable {
        public var result: BeatTrackingResult
        /// Beats the tempo-consistency pass removed.
        public var rejectedBeats: [Double]
        /// The model's framewise logits at 50 fps, after chunk aggregation.
        public var beatLogits: [Float]
        public var downbeatLogits: [Float]
        public var chunkCount: Int
        /// How many of them ran on Core ML; the rest ran on ONNX Runtime.
        public var coreMLChunkCount: Int
        /// Seconds spent decoding and resampling, computing the log-mel, running the model, and in total.
        public var decodeTime: Double
        public var frontEndTime: Double
        public var inferenceTime: Double
        public var wallTime: Double

        public var frameCount: Int { beatLogits.count }
    }

    /// `~/Library/Application Support/MrRoboto/models/beat_this.onnx`
    public static var defaultModelURL: URL { modelsDirectory.appendingPathComponent(modelFileName) }

    /// `~/Library/Application Support/MrRoboto/models/beat_this_1500.mlmodelc`
    public static var defaultCoreMLModelURL: URL { modelsDirectory.appendingPathComponent(coreMLModelFileName, isDirectory: true) }

    private static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MrRoboto/models", isDirectory: true)
    }

    public let modelURL: URL
    public let options: Options
    public let frontEnd = BeatThisFrontEnd()
    private let loadedModel = Mutex<BeatThisModel?>(nil)
    private let loadedCoreMLModel = Mutex<CoreMLSlot>(.notLoaded)

    private enum CoreMLSlot {
        case notLoaded
        case loaded(BeatThisCoreMLModel)
        case unavailable(String)
    }

    /// - Parameter modelURL: where `beat_this.onnx` is; nil means `defaultModelURL`.
    public init(modelURL: URL? = nil, options: Options = Options()) {
        self.modelURL = modelURL ?? Self.defaultModelURL
        self.options = options
    }

    public var providerName: String { Self.name }

    /// True when a file exists at `modelURL` (it may still fail to load).
    public var isModelInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// The loaded session, loading it on first use. Throws `BeatThisError` when it is missing or invalid.
    public func model() throws -> BeatThisModel {
        try loadedModel.withLock { slot in
            if let model = slot { return model }
            let model = try BeatThisModel(contentsOf: modelURL, intraOpThreads: options.intraOpThreads)
            slot = model
            return model
        }
    }

    /// The Core ML model, loading it on first use; nil when none is asked for, it is not installed, or
    /// Core ML would not load or run it (`coreMLUnavailableReason` says which).
    public func coreMLModel() -> BeatThisCoreMLModel? {
        loadedCoreMLModel.withLock { slot in
            switch slot {
            case .loaded(let model): return model
            case .unavailable: return nil
            case .notLoaded:
                guard let url = options.coreMLModelURL else {
                    slot = .unavailable("no Core ML model asked for")
                    return nil
                }
                do {
                    let model = try BeatThisCoreMLModel(contentsOf: url)
                    slot = .loaded(model)
                    return model
                } catch {
                    slot = .unavailable(String(describing: error))
                    return nil
                }
            }
        }
    }

    /// Why full-length chunks run on ONNX Runtime rather than Core ML; nil when Core ML is in use or not yet tried.
    public var coreMLUnavailableReason: String? {
        loadedCoreMLModel.withLock { slot in
            if case .unavailable(let reason) = slot { return reason }
            return nil
        }
    }

    // MARK: BeatTracker

    public func trackBeats(url: URL) async throws -> BeatTrackingResult {
        try await analyze(url: url).result
    }

    /// The full pipeline on a file, off the caller's executor.
    public func analyze(url: URL) async throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AnalysisError.fileNotFound(url) }
        return try await Task.detached(priority: .userInitiated) { [self] in try analyzeFile(url) }.value
    }

    /// The full pipeline on mono samples at any rate, synchronously.
    public func analyze(samples: [Float], sampleRate: Double) throws -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        let at22k = try BeatThisFrontEnd.resampled(samples, from: sampleRate)
        return try analyze(samples22k: at22k, decodeTime: (clock.now - start).seconds, start: start)
    }

    /// Framewise beat and downbeat logits for a log-mel spectrogram, chunked as the reference does, and
    /// how many chunks ran on Core ML.
    public func frameLogits(of spectrogram: Spectrogram) throws -> (beat: [Float], downbeat: [Float], coreMLChunks: Int) {
        let chunking = options.chunking
        let chunks = chunking.chunks(frameCount: spectrogram.frameCount)
        var beat: [[Float]] = [], downbeat: [[Float]] = []
        beat.reserveCapacity(chunks.count)
        downbeat.reserveCapacity(chunks.count)
        var coreMLChunks = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let input = chunking.input(for: chunk, from: spectrogram)
            var prediction: (beat: [Float], downbeat: [Float])?
            if chunk.frames == BeatThisCoreMLModel.frames, let coreML = coreMLModel() {
                do {
                    prediction = try coreML.predict(input)
                    coreMLChunks += 1
                } catch {
                    loadedCoreMLModel.withLock { $0 = .unavailable(String(describing: error)) }
                }
            }
            let chosen = try prediction ?? model().predict(input, frames: chunk.frames)
            beat.append(chosen.beat)
            downbeat.append(chosen.downbeat)
        }
        return (chunking.aggregate(beat, chunks: chunks, frameCount: spectrogram.frameCount),
                chunking.aggregate(downbeat, chunks: chunks, frameCount: spectrogram.frameCount),
                coreMLChunks)
    }

    // MARK: Internals

    private func analyzeFile(_ url: URL) throws -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        let samples: [Float]
        do {
            samples = try frontEnd.samples(fileAt: url)
        } catch {
            throw AnalysisError.unsupportedAsset(url, reason: String(describing: error))
        }
        return try analyze(samples22k: samples, decodeTime: (clock.now - start).seconds, start: start)
    }

    private func analyze(samples22k: [Float], decodeTime: Double, start: ContinuousClock.Instant) throws -> Report {
        let clock = ContinuousClock()
        let frontEndStart = clock.now
        let spectrogram = frontEnd.logMel(samples: samples22k)
        let frontEndTime = (clock.now - frontEndStart).seconds

        let inferenceStart = clock.now
        let logits = try frameLogits(of: spectrogram)
        let inferenceTime = (clock.now - inferenceStart).seconds

        let output = options.postprocessor.process(beatLogits: logits.beat, downbeatLogits: logits.downbeat)
        let result = BeatTrackingResult(beats: output.beats, downbeats: output.downbeats, bpm: output.bpm, confidence: output.confidence)
        return Report(result: result, rejectedBeats: output.rejectedBeats,
                      beatLogits: logits.beat, downbeatLogits: logits.downbeat,
                      chunkCount: options.chunking.chunks(frameCount: spectrogram.frameCount).count,
                      coreMLChunkCount: logits.coreMLChunks,
                      decodeTime: decodeTime, frontEndTime: frontEndTime, inferenceTime: inferenceTime,
                      wallTime: (clock.now - start).seconds)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
