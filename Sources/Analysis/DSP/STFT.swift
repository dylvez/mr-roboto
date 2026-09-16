import Accelerate
import Foundation

/// Short-time Fourier transform on Accelerate/vDSP, following the **PyTorch convention**:
///
/// - `center = true`: the signal is padded by `nFFT / 2` samples on each side using reflect
///   padding, so frame `t` is centred on sample `t * hop`.
/// - Periodic Hann window (`torch.hann_window(nFFT)`), no normalisation.
/// - One-sided output: `nFFT / 2 + 1` bins.
/// - Frame count: `1 + signal.count / hop`.
///
/// Values are a value-type configuration only; every call creates and destroys its own vDSP
/// setup, so the type is `Sendable` and can be used from any isolation domain.
///
/// `nFFT` must be `f * 2^n` with `f ∈ {1, 3, 5, 15}` and `2^n >= 16` (vDSP's real-DFT length
/// rule); powers of two are the normal choice.
public struct STFT: Sendable {
    public enum Window: Sendable, Equatable {
        /// Periodic Hann, `0.5 - 0.5 cos(2πn / N)`. Matches `torch.hann_window(N)`.
        case hann
        /// Caller-supplied window of length `nFFT`.
        case custom([Float])
    }

    public let nFFT: Int
    public let hop: Int
    public let window: [Float]

    /// Number of one-sided frequency bins, `nFFT / 2 + 1`.
    public var binCount: Int { nFFT / 2 + 1 }

    public init(nFFT: Int = 2048, hop: Int = 512, window: Window = .hann) {
        precondition(nFFT >= 16 && nFFT % 2 == 0, "nFFT must be an even length >= 16")
        precondition(hop > 0, "hop must be positive")
        self.nFFT = nFFT
        self.hop = hop
        switch window {
        case .hann:
            self.window = STFT.periodicHann(nFFT)
        case .custom(let w):
            precondition(w.count == nFFT, "custom window must have nFFT samples")
            self.window = w
        }
    }

    public static func periodicHann(_ n: Int) -> [Float] {
        (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }

    /// Frame count for a signal of `length` samples, as in `torch.stft(center=True)`.
    public func frameCount(forLength length: Int) -> Int {
        1 + length / hop
    }

    /// Time in seconds of the centre of `frame`.
    public func frameTime(_ frame: Int, sampleRate: Double) -> Double {
        Double(frame * hop) / sampleRate
    }

    // MARK: Forward

    public func forward(_ signal: [Float]) -> ComplexSpectrogram {
        let half = nFFT / 2
        precondition(signal.count > half, "signal must be longer than nFFT / 2 for reflect padding")
        let padded = STFT.reflectPad(signal, by: half)
        let frames = frameCount(forLength: signal.count)
        let bins = binCount

        var real = [Float](repeating: 0, count: frames * bins)
        var imag = [Float](repeating: 0, count: frames * bins)

        let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }

        var windowed = [Float](repeating: 0, count: nFFT)
        var splitR = [Float](repeating: 0, count: half)
        var splitI = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)

        padded.withUnsafeBufferPointer { p in
            for t in 0..<frames {
                let start = t * hop
                // windowed = padded[start ..< start + nFFT] * window
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(nFFT))
                // Even/odd de-interleave into split-complex form.
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        splitR.withUnsafeMutableBufferPointer { r in
                            splitI.withUnsafeMutableBufferPointer { i in
                                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                    }
                }
                vDSP_DFT_Execute(setup, splitR, splitI, &outR, &outI)
                // vDSP's real DFT is scaled by 2 and packs Nyquist into imag[0].
                let base = t * bins
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var scale: Float = 0.5
                        vDSP_vsmul(outR, 1, &scale, rp.baseAddress! + base, 1, vDSP_Length(half))
                        vDSP_vsmul(outI, 1, &scale, ip.baseAddress! + base, 1, vDSP_Length(half))
                        rp[base + half] = outI[0] * 0.5
                        ip[base] = 0
                        ip[base + half] = 0
                    }
                }
            }
        }
        return ComplexSpectrogram(frameCount: frames, binCount: bins, real: real, imag: imag)
    }

    // MARK: Inverse

    /// Inverse STFT by windowed overlap-add with window-sum-square normalisation, as in
    /// `torch.istft(center=True)`. The centre padding is removed; the result has `length`
    /// samples if given, otherwise `hop * (frameCount - 1)`.
    public func inverse(_ spectrogram: ComplexSpectrogram, length: Int? = nil) -> [Float] {
        precondition(spectrogram.binCount == binCount, "spectrogram bin count does not match nFFT")
        let half = nFFT / 2
        let frames = spectrogram.frameCount
        let bins = binCount
        let paddedLength = nFFT + hop * (frames - 1)

        var output = [Float](repeating: 0, count: paddedLength)
        var windowSumSquare = [Float](repeating: 0, count: paddedLength)
        var windowSquared = [Float](repeating: 0, count: nFFT)
        vDSP_vsq(window, 1, &windowSquared, 1, vDSP_Length(nFFT))

        let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE)!
        defer { vDSP_DFT_DestroySetup(setup) }

        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: nFFT)
        // Inverse of a mathematically-scaled spectrum returns N * x.
        var invScale = 1 / Float(nFFT)

        spectrogram.real.withUnsafeBufferPointer { rp in
            spectrogram.imag.withUnsafeBufferPointer { ip in
                for t in 0..<frames {
                    let base = t * bins
                    inR.withUnsafeMutableBufferPointer { r in
                        r.baseAddress!.update(from: rp.baseAddress! + base, count: half)
                    }
                    inI.withUnsafeMutableBufferPointer { i in
                        i.baseAddress!.update(from: ip.baseAddress! + base, count: half)
                    }
                    inI[0] = rp[base + half]  // pack Nyquist
                    vDSP_DFT_Execute(setup, inR, inI, &outR, &outI)
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                            outR.withUnsafeMutableBufferPointer { r in
                                outI.withUnsafeMutableBufferPointer { i in
                                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                                    vDSP_ztoc(&split, 1, c, 2, vDSP_Length(half))
                                }
                            }
                        }
                    }
                    vDSP_vsmul(frame, 1, &invScale, &frame, 1, vDSP_Length(nFFT))
                    vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nFFT))
                    let start = t * hop
                    output.withUnsafeMutableBufferPointer { op in
                        vDSP_vadd(op.baseAddress! + start, 1, frame, 1, op.baseAddress! + start, 1, vDSP_Length(nFFT))
                    }
                    windowSumSquare.withUnsafeMutableBufferPointer { wp in
                        vDSP_vadd(wp.baseAddress! + start, 1, windowSquared, 1, wp.baseAddress! + start, 1, vDSP_Length(nFFT))
                    }
                }
            }
        }

        // Normalise where the window envelope is non-negligible (torch uses > tiny).
        for i in 0..<paddedLength where windowSumSquare[i] > 1e-11 {
            output[i] /= windowSumSquare[i]
        }

        let outLength = length ?? (paddedLength - 2 * half)
        let end = min(half + outLength, paddedLength)
        var result = Array(output[half..<end])
        if result.count < outLength {
            result.append(contentsOf: repeatElement(0, count: outLength - result.count))
        }
        return result
    }

    // MARK: Helpers

    /// Reflect padding without repeating the edge sample (`numpy`/`torch` "reflect" mode).
    static func reflectPad(_ x: [Float], by pad: Int) -> [Float] {
        let n = x.count
        precondition(pad < n, "reflect padding requires pad < signal length")
        var out = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<pad { out[i] = x[pad - i] }
        out.withUnsafeMutableBufferPointer { p in
            x.withUnsafeBufferPointer { xp in
                (p.baseAddress! + pad).update(from: xp.baseAddress!, count: n)
            }
        }
        for j in 0..<pad { out[n + pad + j] = x[n - 2 - j] }
        return out
    }
}

/// Complex STFT output stored as separate real and imaginary planes, frame-major
/// (`index = frame * binCount + bin`).
public struct ComplexSpectrogram: Sendable {
    public let frameCount: Int
    public let binCount: Int
    public var real: [Float]
    public var imag: [Float]

    public init(frameCount: Int, binCount: Int, real: [Float], imag: [Float]) {
        precondition(real.count == frameCount * binCount && imag.count == real.count)
        self.frameCount = frameCount
        self.binCount = binCount
        self.real = real
        self.imag = imag
    }

    public subscript(frame: Int, bin: Int) -> (real: Float, imag: Float) {
        let i = frame * binCount + bin
        return (real[i], imag[i])
    }

    /// `|X|` per bin.
    public func magnitude() -> Spectrogram {
        var out = [Float](repeating: 0, count: real.count)
        real.withUnsafeBufferPointer { rp in
            imag.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(real.count))
            }
        }
        return Spectrogram(frameCount: frameCount, binCount: binCount, values: out)
    }

    /// `|X|²` per bin.
    public func power() -> Spectrogram {
        var out = [Float](repeating: 0, count: real.count)
        real.withUnsafeBufferPointer { rp in
            imag.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                vDSP_zvmags(&split, 1, &out, 1, vDSP_Length(real.count))
            }
        }
        return Spectrogram(frameCount: frameCount, binCount: binCount, values: out)
    }
}

/// A real-valued time–frequency matrix (magnitude, power, mel, log-mel, ...), frame-major.
public struct Spectrogram: Sendable {
    public let frameCount: Int
    public let binCount: Int
    public var values: [Float]

    public init(frameCount: Int, binCount: Int, values: [Float]) {
        precondition(values.count == frameCount * binCount)
        self.frameCount = frameCount
        self.binCount = binCount
        self.values = values
    }

    public subscript(frame: Int, bin: Int) -> Float {
        get { values[frame * binCount + bin] }
        set { values[frame * binCount + bin] = newValue }
    }

    public func frame(_ t: Int) -> ArraySlice<Float> {
        values[(t * binCount)..<((t + 1) * binCount)]
    }

    /// `log(max(x, floor))` element-wise (natural log). `floor` defaults to 1e-10 as in
    /// librosa's `power_to_db` `amin`.
    public func log(floor: Float = 1e-10) -> Spectrogram {
        var out = values
        var lo = floor
        var hi = Float.greatestFiniteMagnitude
        vDSP_vclip(values, 1, &lo, &hi, &out, 1, vDSP_Length(values.count))
        var n = Int32(out.count)
        vvlogf(&out, out, &n)
        return Spectrogram(frameCount: frameCount, binCount: binCount, values: out)
    }

    /// `log(1 + scale * x)` element-wise (natural log). The SuperFlux/madmom style of
    /// compression: no floor parameter, level-dependent in a way that suits onset detection.
    public func log1p(scale: Float = 1) -> Spectrogram {
        var out = [Float](repeating: 0, count: values.count)
        var s = scale
        var one: Float = 1
        vDSP_vsmsa(values, 1, &s, &one, &out, 1, vDSP_Length(values.count))
        var n = Int32(out.count)
        vvlogf(&out, out, &n)
        return Spectrogram(frameCount: frameCount, binCount: binCount, values: out)
    }
}
