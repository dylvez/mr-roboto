import Analysis
import Foundation

/// The Engineer's numbers off a bounce: loudness as ITU-R BS.1770 states it, peak, crest,
/// spectral tilt, bandwidth, and the low end of one buffer against another.
///
/// Pure functions over planar floats. The loudness is the real thing — K-weighting (a high shelf
/// at 1681.97 Hz and a high-pass at 38.14 Hz, coefficients derived for the buffer's own sample
/// rate and equal to the standard's table at 48 kHz), 400 ms blocks at a 100 ms hop, the −70 LKFS
/// absolute gate and the −10 LU relative gate — so the number is the one a delivery spec means.
/// The peak is the sample peak, not the oversampled true peak, and it is named that way.
public enum MixMeter {

    /// One biquad, direct form I.
    struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        func filter(_ x: [Float]) -> [Float] {
            var y = [Float](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let x0 = Double(x[i])
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                y[i] = Float(y0)
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
            return y
        }

        /// RBJ high shelf.
        static func highShelf(sampleRate: Double, f0: Double, q: Double, gainDB: Double) -> Biquad {
            let a = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * f0 / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let sqa = 2 * sqrt(a) * alpha
            let b0 = a * ((a + 1) + (a - 1) * cosw + sqa)
            let b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            let b2 = a * ((a + 1) + (a - 1) * cosw - sqa)
            let a0 = (a + 1) - (a - 1) * cosw + sqa
            let a1 = 2 * ((a - 1) - (a + 1) * cosw)
            let a2 = (a + 1) - (a - 1) * cosw - sqa
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }

        /// RBJ high-pass.
        static func highPass(sampleRate: Double, f0: Double, q: Double) -> Biquad {
            let w0 = 2 * Double.pi * f0 / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let b0 = (1 + cosw) / 2, b1 = -(1 + cosw), b2 = (1 + cosw) / 2
            let a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }
    }

    /// The two K-weighting stages for a sample rate (BS.1770-4, Annex 1). The shelf is the
    /// standard's own analogue prototype, bilinear-transformed — not an RBJ shelf, which lands a
    /// few thousandths off the published 48 kHz table.
    static func kWeighting(sampleRate: Double) -> (shelf: Biquad, highPass: Biquad) {
        let f0 = 1681.974450955533, q = 0.7071752369554196, gainDB = 3.999843853973347
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0,
                           a2: (1 - k / q + k * k) / a0)
        return (shelf, Biquad.highPass(sampleRate: sampleRate, f0: 38.13547087602444, q: 0.5003270373238773))
    }

    /// Integrated loudness in LKFS/LUFS, gated as the standard says. `-.infinity` for silence.
    public static func integratedLoudness(_ planar: [[Float]], sampleRate: Double) -> Double {
        guard let frames = planar.first?.count, frames > 0, sampleRate > 0 else { return -.infinity }
        let (shelf, highPass) = kWeighting(sampleRate: sampleRate)
        let weighted = planar.map { highPass.filter(shelf.filter($0)) }
        let block = Int(0.4 * sampleRate), hop = Int(0.1 * sampleRate)
        guard block > 0, hop > 0 else { return -.infinity }
        // Mean square per block, summed over channels (weights of 1 for L/R/mono).
        var blocks: [Double] = []
        var start = 0
        while start + block <= frames {
            var sum = 0.0
            for channel in weighted {
                var acc = 0.0
                for i in start..<(start + block) { let v = Double(channel[i]); acc += v * v }
                sum += acc / Double(block)
            }
            blocks.append(sum)
            start += hop
        }
        if blocks.isEmpty {
            var sum = 0.0
            for channel in weighted { sum += channel.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frames) }
            blocks = [sum]
        }
        func lkfs(_ ms: Double) -> Double { ms > 0 ? -0.691 + 10 * log10(ms) : -.infinity }
        let absolute = blocks.filter { lkfs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relativeGate = lkfs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lkfs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return lkfs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Sample peak in dBFS, over every channel.
    public static func samplePeakDB(_ planar: [[Float]]) -> Double {
        let peak = planar.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    /// RMS over every channel, in dBFS.
    public static func rmsDB(_ planar: [[Float]]) -> Double {
        let frames = planar.reduce(0) { $0 + $1.count }
        guard frames > 0 else { return -.infinity }
        let sum = planar.reduce(0.0) { acc, channel in acc + channel.reduce(0.0) { $0 + Double($1) * Double($1) } }
        let ms = sum / Double(frames)
        return ms > 0 ? 10 * log10(ms) : -.infinity
    }

    /// Peak over RMS, in dB: how much the transients stand above the body.
    public static func crestDB(_ planar: [[Float]]) -> Double {
        let peak = samplePeakDB(planar), rms = rmsDB(planar)
        return peak.isFinite && rms.isFinite ? peak - rms : 0
    }

    /// Energy in dB inside a band, from an STFT of the mono sum. `-.infinity` for nothing there.
    public static func bandEnergyDB(_ planar: [[Float]], sampleRate: Double, lowHz: Double, highHz: Double) -> Double {
        let spectrum = powerSpectrum(planar, sampleRate: sampleRate)
        guard !spectrum.isEmpty else { return -.infinity }
        let binHz = sampleRate / Double(2 * (spectrum.count - 1))
        var sum = 0.0
        for (bin, power) in spectrum.enumerated() {
            let hz = Double(bin) * binHz
            if hz >= lowHz && hz < highHz { sum += power }
        }
        return sum > 0 ? 10 * log10(sum) : -.infinity
    }

    /// High band over low band: positive is bright, negative is dark. Bands: under 200, over 2 kHz.
    public static func tiltDB(_ planar: [[Float]], sampleRate: Double) -> Double {
        let low = bandEnergyDB(planar, sampleRate: sampleRate, lowHz: 20, highHz: 200)
        let high = bandEnergyDB(planar, sampleRate: sampleRate, lowHz: 2_000, highHz: min(20_000, sampleRate / 2))
        return low.isFinite && high.isFinite ? high - low : 0
    }

    /// The frequency below which 99% of the energy sits: where the top end stops.
    public static func bandwidthHz(_ planar: [[Float]], sampleRate: Double) -> Double {
        let spectrum = powerSpectrum(planar, sampleRate: sampleRate)
        let total = spectrum.reduce(0, +)
        guard total > 0 else { return 0 }
        let binHz = sampleRate / Double(2 * (spectrum.count - 1))
        var acc = 0.0
        for (bin, power) in spectrum.enumerated() {
            acc += power
            if acc >= 0.99 * total { return Double(bin) * binHz }
        }
        return sampleRate / 2
    }

    /// Mean power per bin over the whole buffer, mono-summed.
    static func powerSpectrum(_ planar: [[Float]], sampleRate: Double) -> [Double] {
        guard let frames = planar.first?.count, frames > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        for channel in planar { for i in 0..<min(frames, channel.count) { mono[i] += channel[i] / Float(planar.count) } }
        let nFFT = 4096
        let stft = STFT(nFFT: nFFT, hop: nFFT / 2)
        let padded = mono.count < nFFT ? mono + [Float](repeating: 0, count: nFFT - mono.count) : mono
        let power = stft.forward(padded).power()
        guard power.frameCount > 0 else { return [] }
        var out = [Double](repeating: 0, count: power.binCount)
        for frame in 0..<power.frameCount {
            for bin in 0..<power.binCount { out[bin] += Double(power[frame, bin]) }
        }
        return out.map { $0 / Double(power.frameCount) }
    }
}
