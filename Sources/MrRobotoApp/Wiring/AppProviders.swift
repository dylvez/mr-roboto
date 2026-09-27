import Analysis
import AnalysisMLX
import AnalysisONNX

// The analysis the app runs on, in one place.
//
// `m0` builds its registry in `makeProviders()`: Music Understanding for the whole-track readings,
// Demucs on MLX for stems. The app used to build that registry once, inside `LiveImportHost`, and
// the band got `DirectorEngines()` — whose separator defaults to nil — so `separate_stems` answered
// "no separation model loaded" in a build that had one and a machine that had the weights. Both
// halves of the app now ask here.

extension AnalysisProviders {
    /// The registry the running app uses, built the way `m0` builds its own.
    public static func app() -> AnalysisProviders {
        var registry = AnalysisProviders.makeDefault()
        registry.register(AppSeparation.demucs, for: [.stemSeparation])
        // Beat This!, beside Music Understanding rather than instead of it: the import runs it as a
        // second opinion on the beat grid, and as the grid when Music Understanding finds none.
        registry.registerONNXProviders()
        return registry
    }
}

/// The app's one stem separator.
///
/// One rather than one per caller because the loaded model lives inside the instance: an Import
/// surface and the band each holding their own would each load htdemucs onto the GPU.
///
/// Holding it costs nothing. `DemucsSeparator.init` records a weights directory and makes an empty
/// model cache; the weights are downloaded (if absent) and loaded on the first `separate`, which is
/// a user dropping a file with separation on or the band calling `separate_stems` — never launch.
/// A `static let` is built on first touch besides.
enum AppSeparation {
    static let demucs = DemucsSeparator()
}

extension DirectorEngines {
    /// The engines the running app's band works on: the app's registry, and the stem separator it
    /// selects — nil only if the registry has none, in which case `separate_stems` says so.
    public static func app(providers: AnalysisProviders = .app()) -> DirectorEngines {
        DirectorEngines(providers: providers, separator: try? providers.stemSeparator())
    }
}
