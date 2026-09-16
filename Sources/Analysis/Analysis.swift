import MusicTheory
/// Analysis — the M0 analysis layer.
///
/// - `Protocols/`: capability protocols (`KeyEstimator`, `BeatTracker`, `StructureAnalyzer`,
///   `LoudnessMeter`, `InstrumentActivityAnalyzer`, `StemSeparator`, `OnsetDetector`,
///   `TimeStretcher`), their plain-value result types, `BeatGrid` and the `AnalysisReport` aggregate.
/// - `Providers/`: `AnalysisProviders` (the capability → implementation registry),
///   `MusicUnderstandingProvider` (Apple's framework behind the five whole-track capabilities)
///   and `BeatComparison` (F-measure scoring against goldens).
/// - `DSP/`: STFT, spectral flux and other signal building blocks.
public enum AnalysisModule {
    public static let version = "0.1.0"
}
