import AVFAudio
import Foundation
import MusicTheory

// The capability protocols. Each is Sendable and async, takes plain inputs (a file URL or a
// Sendable read-only PCM buffer) and returns a plain-value result from AnalysisResults.swift.
// Providers are registered per capability in `AnalysisProviders`, so swapping the implementation
// behind any of these is a configuration change, not a code change.

/// What an analysis provider can do. The keys of the provider registry and of a report's provenance.
public enum AnalysisCapability: String, CaseIterable, Hashable, Codable, CodingKeyRepresentable, Sendable, CustomStringConvertible {
    case key, beats, structure, loudness, instrumentActivity, pace
    case stemSeparation, onsets, timeStretch

    public var description: String { rawValue }
}

extension Set where Element == AnalysisCapability {
    /// The capabilities Apple's Music Understanding framework provides from one session.
    public static var musicUnderstanding: Set<AnalysisCapability> {
        [.key, .beats, .structure, .loudness, .instrumentActivity, .pace]
    }
}

/// Common base: every provider has a stable name used for registry selection and report provenance.
public protocol AnalysisProvider: Sendable {
    /// Short stable identifier, e.g. "musicUnderstanding", "beatThis", "demucsMLX".
    var providerName: String { get }
}

// MARK: - Whole-track analysers

/// Estimates the key (and key changes) of an audio file.
public protocol KeyEstimator: AnalysisProvider {
    func estimateKey(url: URL) async throws -> KeyEstimate
}

/// Tracks beats and downbeats of an audio file.
public protocol BeatTracker: AnalysisProvider {
    func trackBeats(url: URL) async throws -> BeatTrackingResult
}

/// Finds sections, segments and phrases of an audio file.
public protocol StructureAnalyzer: AnalysisProvider {
    func analyzeStructure(url: URL) async throws -> StructureAnalysis
}

/// Measures integrated, short-term and momentary loudness and peak of an audio file.
public protocol LoudnessMeter: AnalysisProvider {
    func measureLoudness(url: URL) async throws -> LoudnessAnalysis
}

/// Finds where vocals, drums, bass and other instruments are present in an audio file.
public protocol InstrumentActivityAnalyzer: AnalysisProvider {
    func analyzeInstrumentActivity(url: URL) async throws -> InstrumentActivity
}

// MARK: - Stem separation

/// The stems a separation model can produce.
public enum StemName: String, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case vocals, drums, bass, other, piano, guitar

    public var description: String { rawValue }
}

/// A separation model a `StemSeparator` offers.
public struct StemSeparationModel: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Identifier used for selection, e.g. "htdemucs", "htdemucs_6s".
    public var name: String
    public var stems: [StemName]
    public var summary: String

    public init(name: String, stems: [StemName], summary: String = "") {
        self.name = name
        self.stems = stems
        self.summary = summary
    }

    public var description: String { "\(name) (\(stems.map(\.rawValue).joined(separator: ", ")))" }
}

/// Audio to separate: a file on disk or an in-memory buffer.
public enum StemSeparationInput: Sendable {
    case file(URL)
    case buffer(AVReadOnlyAudioPCMBuffer)
}

/// How to separate.
public struct StemSeparationOptions: Sendable {
    /// Model name from `StemSeparator.models`; nil selects the provider's default.
    public var model: String?
    /// Where stem files go when the provider writes files; nil keeps stems in memory only.
    public var outputDirectory: URL?
    /// Which stems to keep; nil keeps all the model produces.
    public var stems: Set<StemName>?

    public init(model: String? = nil, outputDirectory: URL? = nil, stems: Set<StemName>? = nil) {
        self.model = model
        self.outputDirectory = outputDirectory
        self.stems = stems
    }
}

/// One separated stem: in memory, on disk, or both.
public struct Stem: Sendable {
    public var name: StemName
    public var buffer: AVReadOnlyAudioPCMBuffer?
    public var fileURL: URL?

    public init(name: StemName, buffer: AVReadOnlyAudioPCMBuffer? = nil, fileURL: URL? = nil) {
        self.name = name
        self.buffer = buffer
        self.fileURL = fileURL
    }
}

/// The stems from one separation run.
public struct StemSeparationResult: Sendable {
    public var model: String
    public var stems: [Stem]
    /// Seconds the separation took.
    public var wallTime: Double

    public init(model: String, stems: [Stem], wallTime: Double) {
        self.model = model
        self.stems = stems
        self.wallTime = wallTime
    }

    public subscript(name: StemName) -> Stem? { stems.first { $0.name == name } }
    public var names: [StemName] { stems.map(\.name) }
}

/// Progress in 0…1, reported from the provider's own task.
public typealias StemSeparationProgress = @Sendable (Double) -> Void

/// Separates audio into named stems. Cancel by cancelling the calling task; implementations must
/// check `Task.isCancelled` between chunks and throw `CancellationError`.
public protocol StemSeparator: AnalysisProvider {
    /// The models this provider can run, first is the default.
    var models: [StemSeparationModel] { get }

    func separate(_ input: StemSeparationInput, options: StemSeparationOptions, progress: @escaping StemSeparationProgress) async throws -> StemSeparationResult
}

extension StemSeparator {
    public var defaultModel: StemSeparationModel? { models.first }

    public func separate(_ input: StemSeparationInput, options: StemSeparationOptions = StemSeparationOptions()) async throws -> StemSeparationResult {
        try await separate(input, options: options, progress: { _ in })
    }

    public func separate(url: URL, model: String? = nil, progress: @escaping StemSeparationProgress = { _ in }) async throws -> StemSeparationResult {
        try await separate(.file(url), options: StemSeparationOptions(model: model), progress: progress)
    }
}

// MARK: - Signal-level tools

/// Detects note onsets in a buffer. The buffer is mixed to mono by the implementation.
public protocol OnsetDetector: AnalysisProvider {
    func detectOnsets(in buffer: AVReadOnlyAudioPCMBuffer) async throws -> OnsetResult
}

/// Changes duration and pitch of a buffer independently.
public protocol TimeStretcher: AnalysisProvider {
    /// - Parameters:
    ///   - ratio: output duration / input duration (2 = twice as long, 0.5 = half).
    ///   - semitones: pitch shift applied on top of the stretch (0 = keep pitch).
    func stretch(_ buffer: AVReadOnlyAudioPCMBuffer, ratio: Double, pitchShift semitones: Double) async throws -> AVReadOnlyAudioPCMBuffer
}

extension TimeStretcher {
    /// Stretch so that `fromBPM` material plays at `toBPM`, keeping pitch.
    public func stretch(_ buffer: AVReadOnlyAudioPCMBuffer, from fromBPM: Double, to toBPM: Double) async throws -> AVReadOnlyAudioPCMBuffer {
        try await stretch(buffer, ratio: fromBPM / toBPM, pitchShift: 0)
    }
}
