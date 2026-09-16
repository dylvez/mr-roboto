import AVFoundation
import Analysis
import DemucsMLX
import Foundation
import MLX

/// Demucs source separation, in-process on MLX, via the `demucs-mlx-swift` package (kylehowells, MIT).
///
/// Weights: on first use of a model the two files it needs are downloaded from Hugging Face
/// (`iky1e/demucs-mlx`, the same repo the library's own downloader uses) into
/// `~/Library/Application Support/MrRoboto/models/<model>/`. The library is always handed that directory
/// explicitly, so its own resolver (env var, `~/.cache/demucs-mlx-swift-models`, Hub snapshot into the
/// Hugging Face cache) is never exercised. If the library's cache already holds a model (e.g. from running
/// its CLI), `WeightsStore` uses it rather than downloading a second copy.
///
/// Memory: inference is chunked by the library (overlap-add over `segmentSeconds` windows, `batchSize`
/// windows per MLX graph), so activation memory is bounded by the window, not the song. Before each run
/// `MLX.Memory.cacheLimit` is set to `Options.mlxCacheLimitBytes` so MLX's allocator does not hoard freed
/// buffers; the cache is dropped afterwards. With the defaults a 4-minute song peaks well under 2 GB.
///
/// Threading: the library runs the model on its own serial queue and delivers progress/completion on the
/// main queue, so the process must be servicing the main queue (any app, an async CLI, or a test host).
public final class DemucsSeparator: @unchecked Sendable {

    // MARK: Options

    public struct Options: Sendable {
        /// Window length for chunked inference. `nil` = the model's training segment (7.8 s).
        /// Longer windows raise memory roughly linearly and do not improve quality.
        public var segmentSeconds: Double? = nil
        /// Overlap between windows, in [0, 1). Upstream default 0.25.
        public var overlap: Double = 0.25
        /// Windows per MLX graph. 1 is the memory-lean choice and, per the library's benchmarks, also fastest
        /// once the cache limit is in play.
        public var batchSize: Int = 1
        /// Random-shift test-time augmentation. `<= 1` = none (deterministic). `n >= 2` averages n shifted
        /// passes (n times slower, marginally better).
        public var shifts: Int = 1
        /// Seed for `shifts >= 2`.
        public var seed: Int? = 0
        /// `MLX.Memory.cacheLimit` applied before inference. Smaller = less retained GPU memory, slightly slower.
        public var mlxCacheLimitBytes: Int = 512 << 20
        /// Drop MLX's buffer cache when a separation finishes.
        public var clearMLXCacheAfterSeparation: Bool = true
        /// Sample format for stems written to disk.
        public var fileFormat: StemFileFormat = .wavInt16

        public init() {}

        var libraryParameters: DemucsSeparationParameters {
            DemucsSeparationParameters(
                shifts: shifts,
                overlap: Float(overlap),
                split: true,
                segmentSeconds: segmentSeconds,
                batchSize: batchSize,
                seed: seed
            )
        }
    }

    public enum StemFileFormat: Sendable {
        case wavInt16
        case wavFloat32
    }

    public let weights: WeightsStore
    public let options: Options
    private let modelStore = ModelStore()

    public init(weights: WeightsStore = WeightsStore(), options: Options = Options()) {
        self.weights = weights
        self.options = options
    }

    // MARK: Model lifecycle

    /// Download (if needed) and load a model so the first `separate` is not charged for it.
    public func prepare(_ model: DemucsModel, progress: SeparationProgressHandler? = nil) async throws {
        _ = try await loadedModel(model, progress: progress)
    }

    /// Release all loaded models (weights on the GPU) and drop MLX's buffer cache.
    public func unloadModels() async {
        await modelStore.unloadAll()
        Memory.clearCache()
    }

    private func loadedModel(_ model: DemucsModel, progress: SeparationProgressHandler?) async throws -> DemucsMLX.DemucsSeparator {
        let dir = try await weights.ensure(model, progress: progress)
        try Task.checkCancellation()
        progress?(SeparationProgress(phase: .loadingModel, fraction: 0, stage: "Loading \(model.rawValue)"))
        let lib = try await modelStore.separator(for: model, weightsDirectory: dir, parameters: options.libraryParameters)
        progress?(SeparationProgress(phase: .loadingModel, fraction: 1, stage: "Loaded \(model.rawValue)"))
        return lib
    }

    // MARK: Typed API

    public func separate(
        url: URL,
        model: DemucsModel = .default,
        outputDirectory: URL,
        progress: SeparationProgressHandler? = nil
    ) async throws -> [StemName: URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DemucsSeparatorError.inputNotFound(url) }
        let audio: DemucsAudio
        do { audio = try AudioIO.loadAudio(from: url) } catch { throw DemucsSeparatorError.separationFailed(reason: "\(error)") }
        guard audio.frameCount > 0 else { throw DemucsSeparatorError.emptyInput }

        let stems = try await separate(audio: audio, model: model, progress: progress)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var written: [StemName: URL] = [:]
        let names = model.stems
        for (i, name) in names.enumerated() {
            try Task.checkCancellation()
            guard let stem = stems[name] else { throw DemucsSeparatorError.missingStem(name) }
            let target = outputDirectory.appendingPathComponent("\(name.rawValue).wav")
            progress?(SeparationProgress(phase: .writing, fraction: Double(i) / Double(names.count), stage: target.lastPathComponent))
            try StemWAV.write(stem, to: target, format: options.fileFormat)
            written[name] = target
        }
        progress?(SeparationProgress(phase: .writing, fraction: 1, stage: "Done"))
        return written
    }

    public func separate(
        buffer: AVAudioPCMBuffer,
        model: DemucsModel = .default,
        progress: SeparationProgressHandler? = nil
    ) async throws -> [StemName: AVAudioPCMBuffer] {
        let audio = try StemWAV.demucsAudio(from: buffer)
        let stems = try await separate(audio: audio, model: model, progress: progress)
        var out: [StemName: AVAudioPCMBuffer] = [:]
        for name in model.stems {
            guard let stem = stems[name] else { throw DemucsSeparatorError.missingStem(name) }
            out[name] = try StemWAV.pcmBuffer(from: stem)
        }
        return out
    }

    /// Core path: sendable in, sendable out. Stems come back as 44.1 kHz stereo channel-major float arrays.
    public func separate(
        audio: DemucsAudio,
        model: DemucsModel = .default,
        progress: SeparationProgressHandler? = nil
    ) async throws -> [StemName: DemucsAudio] {
        try Task.checkCancellation()
        let lib = try await loadedModel(model, progress: progress)
        try Task.checkCancellation()
        // The library resamples with linear interpolation (no anti-aliasing). Do it properly here so
        // 48 kHz sources reach the model the way the Python pipeline (soxr via librosa) sees them.
        let audio = try StemWAV.resampled(audio, to: Int(model.sampleRate))
        try Task.checkCancellation()

        // Bound the allocator's free-list before we start; it is global to the process.
        Memory.cacheLimit = options.mlxCacheLimitBytes
        defer { if options.clearMLXCacheAfterSeparation { Memory.clearCache() } }

        let token = DemucsCancelToken()
        let libraryProgress: (@Sendable (DemucsSeparationProgress) -> Void)? = progress.map { handler in
            let forward: @Sendable (DemucsSeparationProgress) -> Void = { p in
                handler(SeparationProgress(
                    phase: .separating,
                    fraction: Double(p.fraction),
                    stage: p.stage,
                    estimatedTimeRemaining: p.estimatedTimeRemaining))
            }
            return forward
        }
        let result: DemucsSeparationResult
        do {
            result = try await withTaskCancellationHandler {
                try await Self.run(lib, audio: audio, token: token, progress: libraryProgress)
            } onCancel: {
                token.cancel()
            }
        } catch DemucsError.cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw DemucsSeparatorError.separationFailed(reason: "\(error)")
        }
        try Task.checkCancellation()

        var stems: [StemName: DemucsAudio] = [:]
        for (key, value) in result.stems {
            if let name = StemName(rawValue: key) { stems[name] = value }
        }
        return stems
    }
}

// MARK: - Analysis.StemSeparator conformance

extension DemucsSeparator: StemSeparator {
    public var providerName: String { "demucsMLX" }

    /// First is the default (`htdemucs`).
    public var models: [StemSeparationModel] { DemucsModel.allCases.map(\.separationModel) }

    public func separate(
        _ input: StemSeparationInput,
        options: StemSeparationOptions,
        progress: @escaping StemSeparationProgress
    ) async throws -> StemSeparationResult {
        let model: DemucsModel
        if let name = options.model {
            guard let m = DemucsModel(rawValue: name) else { throw DemucsSeparatorError.unknownModel(name) }
            model = m
        } else {
            model = .default
        }
        let start = ContinuousClock.now

        let audio: DemucsAudio
        switch input {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw DemucsSeparatorError.inputNotFound(url) }
            do { audio = try AudioIO.loadAudio(from: url) } catch { throw DemucsSeparatorError.separationFailed(reason: "\(error)") }
        case .buffer(let readOnly):
            audio = try StemWAV.demucsAudio(from: AVAudioPCMBuffer(copying: readOnly))
        }
        guard audio.frameCount > 0 else { throw DemucsSeparatorError.emptyInput }

        let phased: SeparationProgressHandler = { p in progress(p.overallFraction) }
        let separated = try await separate(audio: audio, model: model, progress: phased)

        if let dir = options.outputDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var stems: [Stem] = []
        let wanted = model.stems.filter { options.stems?.contains($0) ?? true }
        for (i, name) in wanted.enumerated() {
            try Task.checkCancellation()
            guard let a = separated[name] else { throw DemucsSeparatorError.missingStem(name) }
            var stem = Stem(name: name)
            if let dir = options.outputDirectory {
                let url = dir.appendingPathComponent("\(name.rawValue).wav")
                phased(SeparationProgress(phase: .writing, fraction: Double(i) / Double(wanted.count), stage: url.lastPathComponent))
                try StemWAV.write(a, to: url, format: self.options.fileFormat)
                stem.fileURL = url
            }
            stem.buffer = AVReadOnlyAudioPCMBuffer(copying: try StemWAV.pcmBuffer(from: a))
            stems.append(stem)
        }
        phased(SeparationProgress(phase: .writing, fraction: 1, stage: "Done"))
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return StemSeparationResult(model: model.rawValue, stems: stems, wallTime: seconds)
    }
}

extension DemucsSeparator {
    /// Bridges the library's closure API (completion on the main queue) to async.
    fileprivate static func run(
        _ lib: DemucsMLX.DemucsSeparator,
        audio: DemucsAudio,
        token: DemucsCancelToken,
        progress: (@Sendable (DemucsSeparationProgress) -> Void)?
    ) async throws -> DemucsSeparationResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DemucsSeparationResult, Error>) in
            let completion: @Sendable (Result<DemucsSeparationResult, Error>) -> Void = { result in
                cont.resume(with: result)
            }
            lib.separate(audio: audio, cancelToken: token, interpolateProgress: true, progress: progress, completion: completion)
        }
    }
}

// MARK: - Model cache

/// Loaded library separators, one per model. Loading is synchronous inside the library (safetensors →
/// MLX graph, ~1 s for htdemucs); doing it on this actor keeps it off the caller's thread and serializes
/// concurrent first-use requests for the same model.
private actor ModelStore {
    private var loaded: [DemucsModel: DemucsMLX.DemucsSeparator] = [:]

    func separator(
        for model: DemucsModel,
        weightsDirectory: URL,
        parameters: DemucsSeparationParameters
    ) throws -> DemucsMLX.DemucsSeparator {
        if let existing = loaded[model] {
            try existing.updateParameters(parameters)
            return existing
        }
        do {
            let s = try DemucsMLX.DemucsSeparator(modelName: model.rawValue, parameters: parameters, modelDirectory: weightsDirectory)
            loaded[model] = s
            return s
        } catch {
            throw DemucsSeparatorError.modelLoadFailed(model: model, reason: "\(error)")
        }
    }

    func unloadAll() { loaded.removeAll() }
}

// MARK: - Weights

/// Where model weights live and how they get there.
public struct WeightsStore: Sendable {
    /// `~/Library/Application Support/MrRoboto/models`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MrRoboto/models", isDirectory: true)
    }

    public static let defaultRepo = "iky1e/demucs-mlx"

    public let directory: URL
    /// Hugging Face repo id holding `<model>.safetensors` and `<model>_config.json` at its root.
    public let repo: String

    public init(directory: URL = WeightsStore.defaultDirectory, repo: String = WeightsStore.defaultRepo) {
        self.directory = directory
        self.repo = repo
    }

    public func directory(for model: DemucsModel) -> URL {
        directory.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    public func isInstalled(_ model: DemucsModel) -> Bool {
        Self.hasAllFiles(model, in: directory(for: model))
    }

    /// Directories the library's own resolver would consult; honored so a model fetched by its CLI is reused.
    static func libraryCacheDirectories(for model: DemucsModel) -> [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DEMUCS_MLX_SWIFT_MODEL_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent(model.rawValue, isDirectory: true))
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(caches.appendingPathComponent("demucs-mlx-swift-models/\(model.rawValue)", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/demucs-mlx-swift-models/\(model.rawValue)", isDirectory: true))
        return dirs
    }

    static func hasAllFiles(_ model: DemucsModel, in dir: URL) -> Bool {
        model.weightFileNames.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Returns a directory containing the model's files, downloading them if no local copy exists.
    public func ensure(_ model: DemucsModel, progress: SeparationProgressHandler? = nil) async throws -> URL {
        let own = directory(for: model)
        if Self.hasAllFiles(model, in: own) { return own }
        if let cached = Self.libraryCacheDirectories(for: model).first(where: { Self.hasAllFiles(model, in: $0) }) {
            return cached
        }
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        for file in model.weightFileNames {
            let target = own.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try await download(file: file, model: model, to: target, progress: progress)
        }
        guard Self.hasAllFiles(model, in: own) else { throw DemucsSeparatorError.weightsIncomplete(model: model, directory: own) }
        return own
    }

    private func download(file: String, model: DemucsModel, to target: URL, progress: SeparationProgressHandler?) async throws {
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)") else {
            throw DemucsSeparatorError.weightsDownloadFailed(model: model, file: file, reason: "bad URL")
        }
        let tmp = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DemucsSeparatorError.weightsDownloadFailed(
                    model: model, file: file, reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let expected = response.expectedContentLength > 0 ? response.expectedContentLength
                : (file.hasSuffix(".safetensors") ? model.approximateWeightBytes : 0)
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
                throw DemucsSeparatorError.weightsDownloadFailed(model: model, file: file, reason: "cannot create \(tmp.path)")
            }
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            var chunk = [UInt8]()
            chunk.reserveCapacity(1 << 20)
            var received: Int64 = 0
            func flush() throws {
                guard !chunk.isEmpty else { return }
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                let frac = expected > 0 ? Double(received) / Double(expected) : 0
                progress?(SeparationProgress(phase: .downloadingWeights, fraction: frac,
                                             stage: "\(file) \(received >> 20) MB"))
            }
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 1 << 20 { try flush() }
            }
            try flush()
            try handle.close()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
        } catch let e as DemucsSeparatorError {
            try? FileManager.default.removeItem(at: tmp)
            throw e
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw DemucsSeparatorError.weightsDownloadFailed(model: model, file: file, reason: "\(error)")
        }
    }
}

// MARK: - Chunk planning

/// The overlap-add schedule the library uses for a given input; exposed for memory budgeting and tests.
/// Mirrors `SeparationEngine.separateNoShift` in demucs-mlx-swift exactly.
public struct ChunkPlan: Sendable, Equatable {
    public let frames: Int
    public let segmentFrames: Int
    public let strideFrames: Int
    /// Start frame of every window. A short clip (at most two windows' worth) is one window of `frames`.
    public let offsets: [Int]
    public let batchSize: Int

    public var windowCount: Int { offsets.count }
    public var batchCount: Int { (offsets.count + batchSize - 1) / batchSize }
    public var isSingleWindow: Bool { offsets.count == 1 && segmentFrames >= frames }

    public init(
        frames: Int,
        sampleRate: Int = 44_100,
        segmentSeconds: Double = DemucsModel.default.defaultSegmentSeconds,
        overlap: Double = 0.25,
        batchSize: Int = 1
    ) {
        self.frames = frames
        self.batchSize = max(1, batchSize)
        let segment = max(1, Int(segmentSeconds * Double(sampleRate)))
        let stride = max(1, Int(Float(segment) * (1.0 - Float(overlap))))
        self.strideFrames = stride
        if frames <= segment + stride {
            // Library fast path: a single un-windowed pass over the whole clip.
            self.segmentFrames = max(frames, 0)
            self.offsets = [0]
        } else {
            self.segmentFrames = segment
            var offs: [Int] = []
            var offset = 0
            while offset < frames {
                offs.append(offset)
                offset += stride
            }
            self.offsets = offs
        }
    }

    public init(frames: Int, model: DemucsModel, options: DemucsSeparator.Options) {
        self.init(
            frames: frames,
            sampleRate: Int(model.sampleRate),
            segmentSeconds: options.segmentSeconds ?? model.defaultSegmentSeconds,
            overlap: options.overlap,
            batchSize: options.batchSize)
    }

    /// Float32 bytes for one batch's input plus output (`stems x channels x segment`), the floor for
    /// activation memory. The transformer's activations are several times this; the library's own
    /// benchmark puts htdemucs at ~1.2 GB peak process memory with batch 1.
    public func batchIOBytes(stems: Int = 4, channels: Int = 2) -> Int {
        batchSize * segmentFrames * channels * (1 + stems) * MemoryLayout<Float>.size
    }
}

// MARK: - Audio plumbing

enum StemWAV {
    static func demucsAudio(from buffer: AVAudioPCMBuffer) throws -> DemucsAudio {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0 else { throw DemucsSeparatorError.unsupportedBuffer("zero channels") }
        guard frames > 0 else { throw DemucsSeparatorError.emptyInput }
        var channelMajor = [Float](repeating: 0, count: channels * frames)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { throw DemucsSeparatorError.unsupportedBuffer("no float data") }
            if format.isInterleaved {
                let src = data[0]
                for t in 0..<frames {
                    for c in 0..<channels { channelMajor[c * frames + t] = src[t * channels + c] }
                }
            } else {
                for c in 0..<channels {
                    channelMajor.withUnsafeMutableBufferPointer { dst in
                        (dst.baseAddress! + c * frames).update(from: data[c], count: frames)
                    }
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { throw DemucsSeparatorError.unsupportedBuffer("no int16 data") }
            let scale = 1 / Float(Int16.max)
            for c in 0..<channels {
                for t in 0..<frames {
                    let v = format.isInterleaved ? data[0][t * channels + c] : data[c][t]
                    channelMajor[c * frames + t] = Float(v) * scale
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { throw DemucsSeparatorError.unsupportedBuffer("no int32 data") }
            let scale = 1 / Float(Int32.max)
            for c in 0..<channels {
                for t in 0..<frames {
                    let v = format.isInterleaved ? data[0][t * channels + c] : data[c][t]
                    channelMajor[c * frames + t] = Float(v) * scale
                }
            }
        default:
            throw DemucsSeparatorError.unsupportedBuffer("common format \(format.commonFormat.rawValue)")
        }
        return try DemucsAudio(channelMajor: channelMajor, channels: channels, sampleRate: Int(format.sampleRate))
    }

    static func pcmBuffer(from audio: DemucsAudio) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate),
                                         channels: AVAudioChannelCount(audio.channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frameCount)),
              let dst = buffer.floatChannelData
        else { throw DemucsSeparatorError.unsupportedBuffer("cannot allocate output buffer") }
        let frames = audio.frameCount
        audio.channelMajorSamples.withUnsafeBufferPointer { src in
            for c in 0..<audio.channels {
                dst[c].update(from: src.baseAddress! + c * frames, count: frames)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Sample-rate conversion with AVAudioConverter's mastering-quality algorithm. Pass-through when rates match.
    static func resampled(_ audio: DemucsAudio, to rate: Int) throws -> DemucsAudio {
        guard audio.sampleRate != rate else { return audio }
        let channels = AVAudioChannelCount(audio.channels)
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: channels),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw DemucsSeparatorError.unsupportedBuffer("cannot build resampler \(audio.sampleRate) -> \(rate) Hz") }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let input = try pcmBuffer(from: audio)
        var supplied = false
        let feed: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }

        let chunkFrames: AVAudioFrameCount = 1 << 16
        var perChannel = [[Float]](repeating: [], count: audio.channels)
        let expected = Int((Double(audio.frameCount) * Double(rate) / Double(audio.sampleRate)).rounded())
        for c in 0..<audio.channels { perChannel[c].reserveCapacity(expected + Int(chunkFrames)) }
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
                throw DemucsSeparatorError.unsupportedBuffer("cannot allocate resampler chunk")
            }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error, withInputFrom: feed)
            if status == .error { throw DemucsSeparatorError.unsupportedBuffer("resampling failed: \(error?.localizedDescription ?? "unknown")") }
            let n = Int(chunk.frameLength)
            if n > 0, let data = chunk.floatChannelData {
                for c in 0..<audio.channels { perChannel[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n)) }
            }
            if status == .endOfStream || (status == .inputRanDry && n == 0) || n == 0 { break }
        }
        let frames = perChannel[0].count
        var channelMajor = [Float]()
        channelMajor.reserveCapacity(frames * audio.channels)
        for c in 0..<audio.channels { channelMajor.append(contentsOf: perChannel[c]) }
        return try DemucsAudio(channelMajor: channelMajor, channels: audio.channels, sampleRate: rate)
    }

    static func write(_ audio: DemucsAudio, to url: URL, format: DemucsSeparator.StemFileFormat) throws {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(audio.sampleRate),
            AVNumberOfChannelsKey: audio.channels,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        switch format {
        case .wavInt16:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        case .wavFloat32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        }
        try? FileManager.default.removeItem(at: url)
        let buffer = try pcmBuffer(from: audio)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        try file.close()
    }
}
