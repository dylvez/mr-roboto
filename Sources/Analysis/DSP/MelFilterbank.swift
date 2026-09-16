import Accelerate
import Foundation

/// Mel scale variants.
public enum MelScale: Sendable, Equatable {
    /// Slaney's Auditory Toolbox scale: linear below 1 kHz, logarithmic above.
    /// This is librosa's default (`htk=False`) and what torchaudio calls `mel_scale="slaney"`.
    case slaney
    /// HTK scale, `2595 · log10(1 + f / 700)`. torchaudio's default (`mel_scale="htk"`).
    case htk

    public func hzToMel(_ hz: Double) -> Double {
        switch self {
        case .htk:
            return 2595 * log10(1 + hz / 700)
        case .slaney:
            let fSp = 200.0 / 3
            let minLogHz = 1000.0
            let minLogMel = minLogHz / fSp
            let logStep = log(6.4) / 27
            if hz >= minLogHz {
                return minLogMel + log(hz / minLogHz) / logStep
            }
            return hz / fSp
        }
    }

    public func melToHz(_ mel: Double) -> Double {
        switch self {
        case .htk:
            return 700 * (pow(10, mel / 2595) - 1)
        case .slaney:
            let fSp = 200.0 / 3
            let minLogHz = 1000.0
            let minLogMel = minLogHz / fSp
            let logStep = log(6.4) / 27
            if mel >= minLogMel {
                return minLogHz * exp(logStep * (mel - minLogMel))
            }
            return fSp * mel
        }
    }
}

/// Per-filter normalisation of the triangular mel filters.
public enum MelNormalization: Sendable, Equatable {
    /// Raw triangles with unit peak.
    case none
    /// Area normalisation `2 / (f_hi - f_lo)` (librosa `norm="slaney"`), so every filter has
    /// approximately unit area in Hz.
    case slaney
    /// Each filter's weights sum to 1 (madmom `norm_filters=True`), so a band value is the
    /// weighted mean of its bins. Handy when thresholds should live in "bin magnitude" units.
    case unitSum
}

/// Triangular mel filterbank over one-sided STFT bins, built exactly like `librosa.filters.mel`.
///
/// Defaults to the **Slaney** scale with Slaney normalisation because that is what librosa
/// produces by default and what the Beat This! front-end (`torchaudio.MelSpectrogram(...,
/// mel_scale="slaney")`) uses, so log-mel goldens made with the Python bench line up without
/// translation. HTK is available for models trained with torchaudio defaults.
public struct MelFilterbank: Sendable {
    public let sampleRate: Double
    public let nFFT: Int
    public let melCount: Int
    public let binCount: Int
    public let scale: MelScale
    public let normalization: MelNormalization
    /// Row-major `melCount × binCount` weights.
    public let weights: [Float]
    /// Centre frequencies (Hz) of the `melCount` filters.
    public let centerFrequencies: [Double]

    public init(sampleRate: Double,
                nFFT: Int,
                melCount: Int = 128,
                minFrequency: Double = 0,
                maxFrequency: Double? = nil,
                scale: MelScale = .slaney,
                normalization: MelNormalization = .slaney) {
        precondition(melCount > 0 && nFFT > 0)
        self.sampleRate = sampleRate
        self.nFFT = nFFT
        self.melCount = melCount
        self.binCount = nFFT / 2 + 1
        self.scale = scale
        self.normalization = normalization

        let fMax = maxFrequency ?? sampleRate / 2
        let bins = nFFT / 2 + 1
        let fftFreqs = (0..<bins).map { Double($0) * sampleRate / Double(nFFT) }

        // melCount + 2 edge frequencies evenly spaced on the mel scale.
        let minMel = scale.hzToMel(minFrequency)
        let maxMel = scale.hzToMel(fMax)
        let edges = (0..<(melCount + 2)).map { i -> Double in
            let mel = minMel + (maxMel - minMel) * Double(i) / Double(melCount + 1)
            return scale.melToHz(mel)
        }
        self.centerFrequencies = Array(edges[1...melCount])

        var w = [Float](repeating: 0, count: melCount * bins)
        for m in 0..<melCount {
            let lo = edges[m], mid = edges[m + 1], hi = edges[m + 2]
            let lowerWidth = mid - lo
            let upperWidth = hi - mid
            var rowSum = 0.0
            for k in 0..<bins {
                let f = fftFreqs[k]
                let lower = (f - lo) / lowerWidth
                let upper = (hi - f) / upperWidth
                let v = max(0, min(lower, upper))
                w[m * bins + k] = Float(v)
                rowSum += v
            }
            switch normalization {
            case .none:
                break
            case .slaney:
                let enorm = Float(2 / (hi - lo))
                for k in 0..<bins { w[m * bins + k] *= enorm }
            case .unitSum:
                if rowSum > 0 {
                    let inv = Float(1 / rowSum)
                    for k in 0..<bins { w[m * bins + k] *= inv }
                }
            }
        }
        self.weights = w
    }

    /// Applies the filterbank to a magnitude or power spectrogram, giving `melCount` bands per frame.
    public func apply(_ spectrogram: Spectrogram) -> Spectrogram {
        precondition(spectrogram.binCount == binCount, "spectrogram bin count does not match filterbank")
        let frames = spectrogram.frameCount
        var out = [Float](repeating: 0, count: frames * melCount)
        // out[frames × mels] = spec[frames × bins] · weightsᵀ[bins × mels]
        // Use vDSP_mmul with the transposed weight matrix.
        var wT = [Float](repeating: 0, count: binCount * melCount)
        vDSP_mtrans(weights, 1, &wT, 1, vDSP_Length(binCount), vDSP_Length(melCount))
        vDSP_mmul(spectrogram.values, 1, wT, 1, &out, 1,
                  vDSP_Length(frames), vDSP_Length(melCount), vDSP_Length(binCount))
        return Spectrogram(frameCount: frames, binCount: melCount, values: out)
    }

    /// Log-mel spectrogram: `log(max(mel · S, floor))` where `S` is the magnitude (`power: 1`)
    /// or power (`power: 2`) spectrogram of the STFT output.
    public func logMel(of stft: ComplexSpectrogram, power: Int = 2, floor: Float = 1e-10) -> Spectrogram {
        let s = power == 1 ? stft.magnitude() : stft.power()
        return apply(s).log(floor: floor)
    }
}
