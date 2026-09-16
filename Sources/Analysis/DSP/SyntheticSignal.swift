import Foundation

/// Deterministic test signals shared between the Swift tests and the Python bench
/// (`Bench/python/stft_golden.py` must generate bit-for-bit the same float32 samples).
public enum SyntheticSignal {
    /// Three steady sines plus a train of single-sample clicks.
    ///
    /// Sines: 220 Hz @ 0.25, 587.33 Hz @ 0.18, 2637.02 Hz @ 0.12 (all zero phase).
    /// Clicks: +0.9 impulses at `0.25 + 0.4735 k` seconds for every k with `t < duration`.
    /// Values are computed in Double and cast to Float, exactly like the numpy script.
    public static let clickPeriod = 0.4735
    public static let firstClickTime = 0.25
    public static let sineFrequencies: [Double] = [220.0, 587.33, 2637.02]
    public static let sineAmplitudes: [Double] = [0.25, 0.18, 0.12]
    public static let clickAmplitude = 0.9

    public static func sinesAndClicks(sampleRate: Double = 44100, duration: Double = 4) -> (samples: [Float], clickTimes: [Double]) {
        let n = Int((sampleRate * duration).rounded())
        var x = [Double](repeating: 0, count: n)
        for (f, a) in zip(sineFrequencies, sineAmplitudes) {
            let w = 2 * Double.pi * f / sampleRate
            for i in 0..<n { x[i] += a * sin(w * Double(i)) }
        }
        var clicks: [Double] = []
        var k = 0
        while true {
            let t = firstClickTime + clickPeriod * Double(k)
            if t >= duration { break }
            let idx = Int((t * sampleRate).rounded())
            x[idx] += clickAmplitude
            clicks.append(Double(idx) / sampleRate)
            k += 1
        }
        return (x.map { Float($0) }, clicks)
    }
}
