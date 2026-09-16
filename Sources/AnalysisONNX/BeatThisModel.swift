import Foundation
import OnnxRuntimeBindings

/// Failures specific to the Beat This! ONNX provider. Audio and registry failures use `AnalysisError`.
public enum BeatThisError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No model file at the URL. The description says how to install one.
    case modelNotFound(URL)
    /// The file exists but ONNX Runtime could not load it, or it is not the Beat This! export.
    case invalidModel(URL, reason: String)
    /// A run failed or returned an unexpected tensor.
    case inferenceFailed(String)

    public var description: String {
        switch self {
        case .modelNotFound(let url):
            return "Beat This! model not found at \(url.path). Install it with `uv run Bench/python/fetch_models.py` "
                + "(puts beat_this.onnx in ~/Library/Application Support/MrRoboto/models) or pass its URL to BeatThisTracker."
        case .invalidModel(let url, let reason):
            return "Beat This! model at \(url.path) could not be loaded: \(reason)"
        case .inferenceFailed(let reason):
            return "Beat This! inference failed: \(reason)"
        }
    }
}

/// One loaded Beat This! ONNX session on ONNX Runtime's CPU execution provider.
///
/// The export (from `beat_this_cpp`, see `Bench/python/fetch_models.py`) takes `input_spectrogram`
/// `[1, time, 128]` float32 log-mel frames and returns `beat` and `downbeat` `[1, time]` logits, with a
/// dynamic time axis. Runs are serialised with a lock; `ORTSession` itself is thread-safe for `run`, but
/// the Objective-C objects are not `Sendable`, so the class vouches for itself.
public final class BeatThisModel: @unchecked Sendable {
    public static let inputName = "input_spectrogram"
    public static let beatOutputName = "beat"
    public static let downbeatOutputName = "downbeat"
    public static let melCount = 128

    public let url: URL
    private let env: ORTEnv
    private let session: ORTSession
    private let lock = NSLock()

    /// Loads the model at `url`. Throws `BeatThisError.modelNotFound` when the file is absent and
    /// `BeatThisError.invalidModel` when ONNX Runtime rejects it or its signature is not Beat This!'s.
    /// - Parameter intraOpThreads: ONNX Runtime's per-op thread count; nil leaves the runtime's default.
    public init(contentsOf url: URL, intraOpThreads: Int? = nil) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BeatThisError.modelNotFound(url) }
        self.url = url
        do {
            env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            if let intraOpThreads { try options.setIntraOpNumThreads(Int32(intraOpThreads)) }
            session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        } catch {
            throw BeatThisError.invalidModel(url, reason: error.localizedDescription)
        }
        let inputs = (try? session.inputNames()) ?? []
        let outputs = Set((try? session.outputNames()) ?? [])
        guard inputs == [Self.inputName], outputs == [Self.beatOutputName, Self.downbeatOutputName] else {
            throw BeatThisError.invalidModel(url, reason: "expected input [\(Self.inputName)] and outputs [\(Self.beatOutputName), \(Self.downbeatOutputName)], found inputs \(inputs) and outputs \(outputs.sorted())")
        }
    }

    /// Runs one chunk of `frames × 128` log-mel values (frame-major) and returns per-frame logits.
    public func predict(_ chunk: [Float], frames: Int) throws -> (beat: [Float], downbeat: [Float]) {
        precondition(chunk.count == frames * Self.melCount, "chunk must hold frames × 128 values")
        let data = chunk.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
        let outputs: [String: ORTValue]
        do {
            let input = try ORTValue(tensorData: data, elementType: .float,
                                     shape: [1, NSNumber(value: frames), NSNumber(value: Self.melCount)])
            outputs = try lock.withLock {
                try session.run(withInputs: [Self.inputName: input],
                                outputNames: [Self.beatOutputName, Self.downbeatOutputName], runOptions: nil)
            }
        } catch {
            throw BeatThisError.inferenceFailed(error.localizedDescription)
        }
        return (try Self.floats(outputs[Self.beatOutputName], name: Self.beatOutputName, expected: frames),
                try Self.floats(outputs[Self.downbeatOutputName], name: Self.downbeatOutputName, expected: frames))
    }

    private static func floats(_ value: ORTValue?, name: String, expected: Int) throws -> [Float] {
        guard let value else { throw BeatThisError.inferenceFailed("no \(name) output") }
        let data: NSMutableData
        do { data = try value.tensorData() } catch { throw BeatThisError.inferenceFailed(error.localizedDescription) }
        let count = data.length / MemoryLayout<Float>.size
        guard count == expected else { throw BeatThisError.inferenceFailed("\(name) has \(count) values, expected \(expected)") }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.getBytes(buffer.baseAddress!, length: count * MemoryLayout<Float>.size)
            initialized = count
        }
    }
}
