import Analysis
import Foundation

/// AnalysisONNX — analysis providers that run ONNX models on ONNX Runtime (CPU execution provider).
///
/// - `BeatThisTracker`: Beat This! beats and downbeats, registered as "beat-this".
/// - `BeatThisFrontEnd`, `BeatThisChunking`, `BeatThisPostprocessor`: its stages, each a port of the
///   corresponding piece of the Python package, reusable and testable on their own.
/// - `BeatThisModel`: the ONNX Runtime session behind it.
///
/// Model files are not bundled; see `Bench/python/fetch_models.py`.
public enum AnalysisONNXModule {
    public static let version = "0.1.0"
}

extension AnalysisProviders {
    /// Registers this module's providers: `BeatThisTracker` as "beat-this" for beats.
    ///
    /// Selection is left alone: on a registry that already has a beat tracker selected (the default
    /// registry's Music Understanding) this only adds a choice; `select("beat-this", for: .beats)` switches
    /// to it. On a registry with nothing selected for beats, the registry's rule makes it the selection.
    /// - Parameter beatThisModelURL: where `beat_this.onnx` is; nil means `BeatThisTracker.defaultModelURL`.
    public mutating func registerONNXProviders(beatThisModelURL: URL? = nil, beatThisOptions: BeatThisTracker.Options = BeatThisTracker.Options()) {
        let tracker = BeatThisTracker(modelURL: beatThisModelURL, options: beatThisOptions)
        register(tracker, for: [.beats])
    }

    /// `makeDefault()` plus this module's providers; Music Understanding stays selected for everything.
    public static func makeDefaultWithONNX(beatThisModelURL: URL? = nil) -> AnalysisProviders {
        var providers = makeDefault()
        providers.registerONNXProviders(beatThisModelURL: beatThisModelURL)
        return providers
    }
}
