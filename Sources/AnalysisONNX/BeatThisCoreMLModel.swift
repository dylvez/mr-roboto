import CoreML
import Foundation

/// Beat This! converted to Core ML at a fixed 1500-frame input, in float16, run on the GPU.
///
/// `Bench/python/convert_beat_this_coreml.py` converts `final0` from its PyTorch source, checks it
/// picks the same beats and downbeats as PyTorch, and installs it compiled (`.mlmodelc`) beside
/// `beat_this.onnx`. On an M5 it runs a chunk in about 75 ms against ONNX Runtime's 350 ms on the
/// CPU. It takes only full chunks, which is every chunk of a piece longer than 30 s; shorter pieces
/// stay on `BeatThisModel`.
///
/// Not the Neural Engine: its compiler does not finish this model (still compiling after two hours).
///
/// Predictions are serialised with a lock; `MLModel` is not `Sendable`, so the class vouches for itself.
public final class BeatThisCoreMLModel: @unchecked Sendable {
    public static let frames = BeatThisChunking.defaultChunkFrames

    public let url: URL
    private let model: MLModel
    private let lock = NSLock()

    /// Loads the compiled model at `url` for the CPU and GPU. Throws `BeatThisError.modelNotFound` when
    /// the file is absent and `BeatThisError.invalidModel` when Core ML rejects it or its signature is
    /// not Beat This!'s at 1500 frames.
    public init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BeatThisError.modelNotFound(url) }
        self.url = url
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw BeatThisError.invalidModel(url, reason: error.localizedDescription)
        }
        let description = model.modelDescription
        let input = description.inputDescriptionsByName[BeatThisModel.inputName]?.multiArrayConstraint
        let outputs = Set(description.outputDescriptionsByName.keys)
        guard input?.shape == [1, Self.frames, BeatThisModel.melCount].map(NSNumber.init(value:)),
              outputs == [BeatThisModel.beatOutputName, BeatThisModel.downbeatOutputName] else {
            throw BeatThisError.invalidModel(url, reason: "expected input \(BeatThisModel.inputName) [1, \(Self.frames), \(BeatThisModel.melCount)] "
                + "and outputs [\(BeatThisModel.beatOutputName), \(BeatThisModel.downbeatOutputName)], found input "
                + "\(input.map { "\($0.shape)" } ?? "none") and outputs \(outputs.sorted())")
        }
    }

    /// Runs one 1500-frame chunk of log-mel values (frame-major) and returns per-frame logits.
    public func predict(_ chunk: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
        precondition(chunk.count == Self.frames * BeatThisModel.melCount, "chunk must hold 1500 × 128 values")
        let output: MLFeatureProvider
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.frames), NSNumber(value: BeatThisModel.melCount)], dataType: .float32)
            input.withUnsafeMutableBytes { bytes, _ in
                chunk.withUnsafeBytes { bytes.copyMemory(from: $0) }
            }
            let features = try MLDictionaryFeatureProvider(dictionary: [BeatThisModel.inputName: MLFeatureValue(multiArray: input)])
            output = try lock.withLock { try model.prediction(from: features) }
        } catch {
            throw BeatThisError.inferenceFailed(error.localizedDescription)
        }
        return (try Self.floats(output, BeatThisModel.beatOutputName), try Self.floats(output, BeatThisModel.downbeatOutputName))
    }

    private static func floats(_ output: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let array = output.featureValue(for: name)?.multiArrayValue else { throw BeatThisError.inferenceFailed("no \(name) output") }
        guard array.count == frames else { throw BeatThisError.inferenceFailed("\(name) has \(array.count) values, expected \(frames)") }
        // Read through the array's own strides and type: Core ML may hand back padded or float16 storage.
        let last = array.strides.last?.intValue ?? 1
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { buffer in (0..<frames).map { buffer[$0 * last] } }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in (0..<frames).map { Float(buffer[$0 * last]) } }
        default:
            return (0..<frames).map { array[$0].floatValue }
        }
    }
}
