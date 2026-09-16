import Accelerate
import Foundation

/// SuperFlux-style onset detector (Böck & Widmer 2013) on Accelerate.
///
/// Pipeline:
/// 1. STFT (PyTorch convention, periodic Hann) → magnitude → mel filterbank (unit-sum filters,
///    so band values are in single-bin magnitude units) → `log(1 + λ·x)`.
/// 2. Maximum filter across frequency (`maxFilterBands` wide) applied to the frame
///    `diffFrames` earlier, which suppresses vibrato / pitch-glide false positives.
/// 3. Half-wave rectified positive difference summed across bands → onset detection function.
/// 4. Peak picking: a frame is an onset when it is the maximum of `[-preMax, +postMax]` and
///    exceeds the local mean over `[-preAverage, +postAverage]` by `threshold`; onsets closer
///    than `minimumInterOnsetInterval` to the previous one are dropped (madmom semantics).
///    Peaks in the final `nFFT / 2` samples are discarded: reflect padding mirrors the tail
///    of the signal, which reads as a transient.
/// 5. Optional time-domain refinement: log-compressed spectral flux places the coarse peak
///    up to half a window *early* for impulsive material, so each coarse onset is re-located
///    with a short-window (`refinementFFT`/`refinementHop`) linear spectral flux inside the
///    coarse frame's span. This gives ~1 ms precision on clicks instead of ~10–20 ms.
///
/// Defaults are tuned for 44.1 kHz drum material (see the onset tests): 2048/441 gives the
/// 100 fps SuperFlux frame rate.
public struct SpectralFluxOnsetDetector: Sendable {
    public var nFFT: Int = 2048
    /// Hop in samples; 441 = 100 frames/s at 44.1 kHz.
    public var hop: Int = 441
    public var melCount: Int = 128
    public var minFrequency: Double = 30
    public var maxFrequency: Double = 17000
    /// λ in `log(1 + λ·x)`; x is a unit-sum mel band of the magnitude spectrum for float audio
    /// in [-1, 1]. 1000 puts the compression knee at −60 dBFS per bin.
    public var logCompression: Float = 1000
    /// Width (in bands) of the maximum filter across frequency. SuperFlux uses 3.
    public var maxFilterBands: Int = 3
    /// Temporal offset (frames) for the difference. `nil` derives it from the window like
    /// madmom (`max(1, round((nFFT/2 − first sample where window > 0.5) / hop))`).
    public var diffFrames: Int? = nil
    /// δ added to the local mean of the detection function (units: nats summed over bands).
    /// On the Arrival drum stem 4–6 all give ~0.82 beat coverage with no false positives on
    /// the synthetic click train; 5 is the middle of that clean region.
    public var threshold: Float = 5
    public var preMax: Double = 0.01
    public var postMax: Double = 0.05
    public var preAverage: Double = 0.15
    public var postAverage: Double = 0
    /// Minimum time between reported onsets (seconds).
    public var minimumInterOnsetInterval: Double = 0.03
    public var refineOnsetTimes: Bool = true
    public var refinementFFT: Int = 256
    public var refinementHop: Int = 32

    public init() {}

    // MARK: Public API

    /// Onset times in seconds, ascending.
    public func onsets(in signal: [Float], sampleRate: Double) -> [Double] {
        guard signal.count > nFFT else { return [] }
        let odf = detectionFunction(in: signal, sampleRate: sampleRate)
        // Reflect padding mirrors the tail of the signal, which puts a derivative kink (a fake
        // transient) in the last half window. Nothing in the final nFFT/2 samples is trustworthy.
        let lastValidFrame = (signal.count - nFFT / 2) / hop
        let frames = peakFrames(in: odf, sampleRate: sampleRate).filter { $0 <= lastValidFrame }
        let coarse = frames.map { Double($0 * hop) / sampleRate }
        guard refineOnsetTimes else { return coarse }
        let refined = frames.map { refine(frame: $0, in: signal, sampleRate: sampleRate) }
        // Refinement can move neighbours onto the same attack; re-apply the IOI constraint.
        var out: [Double] = []
        for t in refined.sorted() {
            if let last = out.last, t - last < minimumInterOnsetInterval { continue }
            out.append(t)
        }
        return out
    }

    /// The SuperFlux onset detection function, one value per hop.
    public func detectionFunction(in signal: [Float], sampleRate: Double) -> [Float] {
        let stft = STFT(nFFT: nFFT, hop: hop)
        let bank = MelFilterbank(sampleRate: sampleRate, nFFT: nFFT, melCount: melCount,
                                 minFrequency: minFrequency, maxFrequency: maxFrequency,
                                 scale: .slaney, normalization: .unitSum)
        let spec = bank.apply(stft.forward(signal).magnitude()).log1p(scale: logCompression)
        return SpectralFluxOnsetDetector.superFlux(spec, maxFilterBands: maxFilterBands,
                                                    diffFrames: resolvedDiffFrames)
    }

    /// Frame indices of picked peaks in a detection function sampled every `hop` samples.
    public func peakFrames(in odf: [Float], sampleRate: Double) -> [Int] {
        let fps = sampleRate / Double(hop)
        let preMaxF = Int((preMax * fps).rounded())
        let postMaxF = Int((postMax * fps).rounded())
        let preAvgF = Int((preAverage * fps).rounded())
        let postAvgF = Int((postAverage * fps).rounded())
        let combineF = minimumInterOnsetInterval * fps
        let n = odf.count
        var picked: [Int] = []
        var lastPick = -Double.infinity
        for i in 0..<n {
            let v = odf[i]
            guard v > 0 else { continue }
            // Local maximum over [i - preMax, i + postMax].
            let lo = max(0, i - preMaxF), hi = min(n - 1, i + postMaxF)
            var isMax = true
            for j in lo...hi where odf[j] > v { isMax = false; break }
            guard isMax else { continue }
            // Adaptive threshold: local mean over [i - preAvg, i + postAvg] + δ.
            let alo = max(0, i - preAvgF), ahi = min(n - 1, i + postAvgF)
            var sum: Float = 0
            for j in alo...ahi { sum += odf[j] }
            let mean = sum / Float(ahi - alo + 1)
            guard v >= mean + threshold else { continue }
            guard Double(i) - lastPick >= combineF else { continue }
            picked.append(i)
            lastPick = Double(i)
        }
        return picked
    }

    public var resolvedDiffFrames: Int {
        if let d = diffFrames { return max(1, d) }
        let window = STFT.periodicHann(nFFT)
        let first = window.firstIndex { $0 > 0.5 } ?? nFFT / 2
        let diffSamples = Double(nFFT / 2 - first)
        return max(1, Int((diffSamples / Double(hop)).rounded()))
    }

    // MARK: Internals

    /// Positive difference of `spec` against the frequency-max-filtered frame `diffFrames`
    /// earlier, summed across bands. Frames without a predecessor yield 0.
    static func superFlux(_ spec: Spectrogram, maxFilterBands: Int, diffFrames: Int) -> [Float] {
        let frames = spec.frameCount, bands = spec.binCount
        let radius = max(0, (maxFilterBands - 1) / 2)
        var odf = [Float](repeating: 0, count: frames)
        var maxed = [Float](repeating: 0, count: bands)
        var diff = [Float](repeating: 0, count: bands)
        spec.values.withUnsafeBufferPointer { p in
            for t in diffFrames..<frames {
                let prev = p.baseAddress! + (t - diffFrames) * bands
                let cur = p.baseAddress! + t * bands
                // Maximum filter across frequency on the earlier frame.
                for k in 0..<bands {
                    var m = prev[k]
                    let lo = max(0, k - radius), hi = min(bands - 1, k + radius)
                    for j in lo...hi where prev[j] > m { m = prev[j] }
                    maxed[k] = m
                }
                vDSP_vsub(maxed, 1, cur, 1, &diff, 1, vDSP_Length(bands))  // cur - maxed
                var zero: Float = 0
                var inf = Float.greatestFiniteMagnitude
                vDSP_vclip(diff, 1, &zero, &inf, &diff, 1, vDSP_Length(bands))
                var s: Float = 0
                vDSP_sve(diff, 1, &s, vDSP_Length(bands))
                odf[t] = s
            }
        }
        return odf
    }

    /// Re-locate a coarse onset frame using a fine-grained linear spectral flux over the span
    /// of samples that the coarse frame (and its successor) could see.
    func refine(frame: Int, in signal: [Float], sampleRate: Double) -> Double {
        let center = frame * hop
        let start = max(0, center - nFFT / 2)
        let end = min(signal.count, center + nFFT / 2 + hop)
        guard end - start > refinementFFT else { return Double(center) / sampleRate }
        let fine = STFT(nFFT: refinementFFT, hop: refinementHop)
        let mag = fine.forward(Array(signal[start..<end])).magnitude()
        let bins = mag.binCount
        var best = 0, bestFlux: Float = -1
        var diff = [Float](repeating: 0, count: bins)
        mag.values.withUnsafeBufferPointer { p in
            for t in 1..<mag.frameCount {
                vDSP_vsub(p.baseAddress! + (t - 1) * bins, 1, p.baseAddress! + t * bins, 1, &diff, 1, vDSP_Length(bins))
                var zero: Float = 0
                var inf = Float.greatestFiniteMagnitude
                vDSP_vclip(diff, 1, &zero, &inf, &diff, 1, vDSP_Length(bins))
                var s: Float = 0
                vDSP_sve(diff, 1, &s, vDSP_Length(bins))
                if s > bestFlux { bestFlux = s; best = t }
            }
        }
        return Double(start + best * refinementHop) / sampleRate
    }
}
