import MLX

/// AnalysisMLX — Demucs on MLX (see DemucsSeparator.swift). `smoke()` proves MLX links and runs on the GPU.
public enum AnalysisMLXModule {
    public static let version = "0.0.1"

    /// Sums a small array on the default device; a non-trivial MLX evaluation for the scaffold check.
    public static func smoke() -> Float {
        let a = MLXArray(0 ..< 1000).asType(Float.self)
        return (a * 2).sum().item(Float.self)
    }
}
