import Analysis
import Foundation
import MusicTheory
import Synchronization

/// Beat This! (Foscarin, Schlüter, Widmer, ISMIR 2024) as a `BeatTracker`, running the `final0`
/// checkpoint's ONNX export on ONNX Runtime's CPU execution provider.
///
/// Pipeline: decode → mono 22 050 Hz → `BeatThisFrontEnd` log-mel (50 fps) → `BeatThisChunking`
/// (1500-frame chunks, 6-frame border, keep-first) through `BeatThisModel` → `BeatThisPostprocessor`
/// (the reference's `dbn=False` peak picking, then the tempo-consistency pass).
///
/// The model file is not bundled. It is loaded lazily, once, from `modelURL`, which defaults to
/// `~/Library/Application Support/MrRoboto/models/beat_this.onnx`; `Bench/python/fetch_models.py`
/// installs it there.
public final class BeatThisTracker: BeatTracker, Sendable {
    public static let name = "beat-this"
    public static let modelFileName = "beat_this.onnx"

    public struct Options: Sendable {
        /// ONNX Runtime's per-op thread count; nil leaves the runtime's default (the physical cores).
        public var intraOpThreads: Int?
        public var chunking = BeatThisChunking()
        public var postprocessor = BeatThisPostprocessor()

        public init(intraOpThreads: Int? = nil) {
            self.intraOpThreads = intraOpThreads
        }
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
        /// Seconds spent decoding and resampling, computing the log-mel, running the model, and in total.
        public var decodeTime: Double
        public var frontEndTime: Double
        public var inferenceTime: Double
        public var wallTime: Double

        public var frameCount: Int { beatLogits.count }
    }

    /// `~/Library/Application Support/MrRoboto/models/beat_this.onnx`
    public static var defaultModelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MrRoboto/models", isDirectory: true).appendingPathComponent(modelFileName)
    }

    public let modelURL: URL
    public let options: Options
    public let frontEnd = BeatThisFrontEnd()
    private let loadedModel = Mutex<BeatThisModel?>(nil)

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

    /// Framewise beat and downbeat logits for a log-mel spectrogram, chunked as the reference does.
    public func frameLogits(of spectrogram: Spectrogram) throws -> (beat: [Float], downbeat: [Float]) {
        let model = try model()
        let chunking = options.chunking
        let chunks = chunking.chunks(frameCount: spectrogram.frameCount)
        var beat: [[Float]] = [], downbeat: [[Float]] = []
        beat.reserveCapacity(chunks.count)
        downbeat.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let prediction = try model.predict(chunking.input(for: chunk, from: spectrogram), frames: chunk.frames)
            beat.append(prediction.beat)
            downbeat.append(prediction.downbeat)
        }
        return (chunking.aggregate(beat, chunks: chunks, frameCount: spectrogram.frameCount),
                chunking.aggregate(downbeat, chunks: chunks, frameCount: spectrogram.frameCount))
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
