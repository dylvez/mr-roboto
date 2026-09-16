import Accelerate
import Analysis
import AVFAudio
import Foundation

/// The Beat This! input representation, replicated from `beat_this/preprocessing.py` (`LogMelSpect`):
/// mono audio at 22 050 Hz → `torchaudio.transforms.MelSpectrogram(n_fft=1024, hop_length=441, f_min=30,
/// f_max=11000, n_mels=128, mel_scale="slaney", normalized="frame_length", power=1)` → `log1p(1000 · mel)`.
/// Frames are 20 ms apart (50 fps) and centred on `frame * hop` (reflect padding).
///
/// The Analysis `STFT` follows the PyTorch convention (centre, reflect, periodic Hann, one-sided) and
/// `MelFilterbank` builds the same triangles as torchaudio's `melscale_fbanks`, so both are used as
/// they are. The Beat This! specifics are the frame-length normalisation (magnitude ÷ √1024), the
/// *unnormalised* filters (torchaudio's default `norm=None`, not librosa's Slaney area norm, so the
/// filterbank is built with `normalization: .none`) and the `log1p` compression.
public struct BeatThisFrontEnd: Sendable {
    public static let sampleRate: Double = 22050
    public static let nFFT = 1024
    public static let hop = 441
    public static let melCount = 128
    public static let minFrequency: Double = 30
    public static let maxFrequency: Double = 11000
    public static let logMultiplier: Float = 1000
    /// Frames per second of the model's input and output: `sampleRate / hop` = 50.
    public static let framesPerSecond: Double = sampleRate / Double(hop)

    public let stft: STFT
    public let filterbank: MelFilterbank

    public init() {
        stft = STFT(nFFT: Self.nFFT, hop: Self.hop, window: .hann)
        filterbank = MelFilterbank(sampleRate: Self.sampleRate, nFFT: Self.nFFT, melCount: Self.melCount,
                                   minFrequency: Self.minFrequency, maxFrequency: Self.maxFrequency,
                                   scale: .slaney, normalization: .none)
    }

    /// Seconds at the centre of (possibly fractional) frame `frame`.
    public static func time(ofFrame frame: Double) -> Double { frame / framesPerSecond }

    /// Reads the file, downmixes to mono and resamples to 22 050 Hz.
    public func samples(fileAt url: URL) throws -> [Float] {
        try Resampler(targetSampleRate: Self.sampleRate).monoSamples(fromFileAt: url)
    }

    /// Log-mel spectrogram (`frames × 128`) of mono samples already at 22 050 Hz.
    public func logMel(samples: [Float]) -> Spectrogram {
        // torch.stft's reflect padding needs more than nFFT / 2 samples; pad silence for tiny inputs.
        var signal = samples
        let minimum = Self.nFFT / 2 + 1
        if signal.count < minimum { signal.append(contentsOf: repeatElement(0, count: minimum - signal.count)) }

        var magnitude = stft.forward(signal).magnitude()
        // normalized="frame_length": the spectrum is divided by sqrt(n_fft).
        var scale = 1 / Float(Self.nFFT).squareRoot()
        vDSP_vsmul(magnitude.values, 1, &scale, &magnitude.values, 1, vDSP_Length(magnitude.values.count))
        return filterbank.apply(magnitude).log1p(scale: Self.logMultiplier)
    }

    /// Log-mel spectrogram of mono samples at any rate (resampled first when needed).
    public func logMel(samples: [Float], sampleRate: Double) throws -> Spectrogram {
        logMel(samples: try Self.resampled(samples, from: sampleRate))
    }

    /// Mono samples at `sampleRate` converted to 22 050 Hz with the Analysis `Resampler`.
    public static func resampled(_ samples: [Float], from sampleRate: Double) throws -> [Float] {
        guard sampleRate != Self.sampleRate else { return samples }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw Resampler.Error.converterUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return try Resampler(targetSampleRate: Self.sampleRate).monoSamples(from: buffer)
    }

    /// Log-mel spectrogram of an audio file.
    public func logMel(fileAt url: URL) throws -> Spectrogram {
        logMel(samples: try samples(fileAt: url))
    }
}
