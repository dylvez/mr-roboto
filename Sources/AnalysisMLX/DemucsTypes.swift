import AVFoundation
import Analysis
import Foundation

// MARK: - Stems and models

// `StemName` comes from the Analysis target (Sources/Analysis/Protocols/AnalysisProtocols.swift).

/// The Demucs checkpoints this package knows how to run. Raw values are the upstream Demucs model names
/// and double as the weight file basenames on Hugging Face (`<name>.safetensors`, `<name>_config.json`).
public enum DemucsModel: String, CaseIterable, Sendable, Codable {
    /// Hybrid Transformer Demucs, 4 stems, single model. The default and by far the fastest.
    case htdemucs
    /// 6-stem variant (adds guitar and piano).
    case htdemucs_6s
    /// Fine-tuned bag of four HTDemucs models: better quality, ~4x the time and weights of `htdemucs`.
    case htdemucs_ft

    public static let `default` = DemucsModel.htdemucs

    public var stems: [StemName] {
        switch self {
        case .htdemucs, .htdemucs_ft: [.drums, .bass, .other, .vocals]
        case .htdemucs_6s: [.drums, .bass, .other, .vocals, .guitar, .piano]
        }
    }

    /// Files that must be present in the model's weights directory.
    public var weightFileNames: [String] { ["\(rawValue).safetensors", "\(rawValue)_config.json"] }

    /// Size of the safetensors file on Hugging Face (`iky1e/demucs-mlx`), for download progress and UI.
    public var approximateWeightBytes: Int64 {
        switch self {
        case .htdemucs: 168_005_865
        case .htdemucs_6s: 109_726_583
        case .htdemucs_ft: 672_024_519
        }
    }

    /// Number of sub-models run per chunk (a "bag"). Time and activation memory scale with this.
    public var subModelCount: Int { self == .htdemucs_ft ? 4 : 1 }

    /// Training segment length in seconds (the upstream config's `segment`, 39/5 for all HTDemucs variants).
    /// Chunked inference uses this as the window unless overridden.
    public var defaultSegmentSeconds: Double { 7.8 }

    public var sampleRate: Double { 44_100 }

    /// One line for pickers.
    public var summary: String {
        switch self {
        case .htdemucs: "Hybrid Transformer Demucs, 4 stems. Default; fastest."
        case .htdemucs_6s: "6 stems: adds guitar and piano."
        case .htdemucs_ft: "Fine-tuned bag of 4 models; best quality, ~4x slower."
        }
    }

    /// The Analysis-facing description of this model.
    public var separationModel: StemSeparationModel {
        StemSeparationModel(name: rawValue, stems: stems, summary: summary)
    }
}

// MARK: - Progress

public struct SeparationProgress: Sendable, CustomStringConvertible {
    public enum Phase: String, Sendable {
        /// Fetching weights into the models directory (first use of a model only).
        case downloadingWeights
        /// Reading safetensors and building the MLX graph.
        case loadingModel
        /// Running chunked inference.
        case separating
        /// Writing stem files.
        case writing
    }

    public let phase: Phase
    /// Progress within `phase`, 0...1.
    public let fraction: Double
    /// Human-readable detail (e.g. the library's current stage or the file being downloaded).
    public let stage: String
    /// Only reported for `.separating`, once enough batches have run to extrapolate.
    public let estimatedTimeRemaining: TimeInterval?

    public init(phase: Phase, fraction: Double, stage: String, estimatedTimeRemaining: TimeInterval? = nil) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.stage = stage
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }

    /// Phases collapsed onto one 0...1 scale for the `StemSeparator` protocol's single-number progress.
    public var overallFraction: Double {
        switch phase {
        case .downloadingWeights: 0.10 * fraction
        case .loadingModel: 0.10 + 0.05 * fraction
        case .separating: 0.15 + 0.82 * fraction
        case .writing: 0.97 + 0.03 * fraction
        }
    }

    public var description: String {
        let pct = Int((fraction * 100).rounded())
        if let eta = estimatedTimeRemaining {
            return "\(phase.rawValue) \(pct)% \(stage) (eta \(Int(eta.rounded()))s)"
        }
        return "\(phase.rawValue) \(pct)% \(stage)"
    }
}

public typealias SeparationProgressHandler = @Sendable (SeparationProgress) -> Void

// MARK: - Protocol
//
// `DemucsSeparator` conforms to `Analysis.StemSeparator` (see DemucsSeparator.swift). The local
// `StemSeparating` protocol that task 3.1 started with was deleted once that protocol landed.

// MARK: - Errors

public enum DemucsSeparatorError: Error, LocalizedError, Sendable {
    case inputNotFound(URL)
    case unknownModel(String)
    case emptyInput
    case unsupportedBuffer(String)
    case weightsDownloadFailed(model: DemucsModel, file: String, reason: String)
    case weightsIncomplete(model: DemucsModel, directory: URL)
    case modelLoadFailed(model: DemucsModel, reason: String)
    case separationFailed(reason: String)
    case missingStem(StemName)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url): "Audio file not found: \(url.path)"
        case .unknownModel(let name): "Unknown Demucs model '\(name)'; expected one of \(DemucsModel.allCases.map(\.rawValue))"
        case .emptyInput: "Input audio has no frames."
        case .unsupportedBuffer(let why): "Unsupported AVAudioPCMBuffer: \(why)"
        case .weightsDownloadFailed(let m, let f, let why): "Downloading \(f) for \(m.rawValue) failed: \(why)"
        case .weightsIncomplete(let m, let dir): "Weights for \(m.rawValue) incomplete in \(dir.path)"
        case .modelLoadFailed(let m, let why): "Loading \(m.rawValue) failed: \(why)"
        case .separationFailed(let why): "Separation failed: \(why)"
        case .missingStem(let s): "Model output lacked stem \(s.rawValue)"
        }
    }
}
