import Foundation

// MARK: - Deterministic noise
//
// Every stochastic element in a synthesized voice comes from here, seeded from the voice's spec.
// That is what makes `DrumSynthesizer.render` a pure function of (spec, velocity, sampleRate) and
// therefore what makes an offline bounce reproducible: the same kit re-rendered on another machine,
// or after a round trip through `kit.json`, produces byte-identical WAVs.

/// A seeded uniform generator. `xorshift64*` — fixed-width `UInt64` arithmetic only, so it produces
/// the same stream on every architecture and every Swift version. Never seed it from time or from
/// `SystemRandomNumberGenerator`.
public struct SeededRandom: Sendable {
    private var state: UInt64

    /// Seeds the generator. A zero seed is replaced (xorshift is stuck at zero).
    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// The next raw 64-bit word.
    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        // 53 significant bits, the most a Double holds exactly.
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform white noise in [-1, 1).
    public mutating func bipolar() -> Double { unit() * 2 - 1 }
}

// MARK: - Biquad

/// A direct-form-I biquad in Double. Double because several of these run in series at very high Q
/// on signals that ring for most of a second, and Float accumulates audible error there.
///
/// Coefficients follow Robert Bristow-Johnson's Audio EQ Cookbook.
/// <https://webaudio.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html>
public struct Biquad: Sendable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public init() {}

    public mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    /// Constant-skirt-gain band-pass (peak gain = Q), the shape a resonant analog band-pass has.
    public static func bandPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        var f = Biquad()
        let (w0, alpha) = Biquad.common(frequency: frequency, q: q, sampleRate: sampleRate)
        let a0 = 1 + alpha
        f.b0 = (q * alpha) / a0
        f.b1 = 0
        f.b2 = -(q * alpha) / a0
        f.a1 = (-2 * cos(w0)) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    /// Unity-peak-gain band-pass — the right choice when the band-pass is shaping tone rather than
    /// adding resonant gain, because the peak stays at 0 dB however high Q goes.
    public static func bandPassUnity(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        var f = Biquad()
        let (w0, alpha) = Biquad.common(frequency: frequency, q: q, sampleRate: sampleRate)
        let a0 = 1 + alpha
        f.b0 = alpha / a0
        f.b1 = 0
        f.b2 = -alpha / a0
        f.a1 = (-2 * cos(w0)) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    public static func lowPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        var f = Biquad()
        let (w0, alpha) = Biquad.common(frequency: frequency, q: q, sampleRate: sampleRate)
        let a0 = 1 + alpha
        let c = cos(w0)
        f.b0 = ((1 - c) / 2) / a0
        f.b1 = (1 - c) / a0
        f.b2 = f.b0
        f.a1 = (-2 * c) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    public static func highPass(frequency: Double, q: Double = 0.7071, sampleRate: Double) -> Biquad {
        var f = Biquad()
        let (w0, alpha) = Biquad.common(frequency: frequency, q: q, sampleRate: sampleRate)
        let a0 = 1 + alpha
        let c = cos(w0)
        f.b0 = ((1 + c) / 2) / a0
        f.b1 = -(1 + c) / a0
        f.b2 = f.b0
        f.a1 = (-2 * c) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    private static func common(frequency: Double, q: Double, sampleRate: Double) -> (w0: Double, alpha: Double) {
        // Clamp below Nyquist: a kit can be rendered at any rate, and a 16 kHz cymbal band at a
        // 22.05 kHz "vintage sampler" rate would otherwise produce NaN coefficients.
        let f = min(max(frequency, 1), sampleRate * 0.49)
        let w0 = 2 * Double.pi * f / sampleRate
        return (w0, sin(w0) / (2 * max(q, 0.05)))
    }
}

// MARK: - Envelopes

/// Envelope shapes shared by the voices. All times are seconds; all return linear gain.
public enum SynthEnvelope {
    /// Exponential decay reaching -60 dB at `t60`. Analog drum envelopes are RC discharges, so this
    /// — not a linear ramp — is the honest shape.
    @inline(__always)
    public static func exponential(t: Double, t60: Double) -> Double {
        guard t60 > 0 else { return t <= 0 ? 1 : 0 }
        // ln(1000) = 6.907755…: the exponent that takes amplitude to one thousandth, i.e. -60 dB.
        return exp(-6.907_755_278_982_137 * t / t60)
    }

    /// Exponential decay with a short linear attack, so nothing starts on a discontinuity. An
    /// instantaneous step is a click the hardware does not make: the trigger pulse has a rise time.
    @inline(__always)
    public static func percussive(t: Double, attack: Double, t60: Double) -> Double {
        if t < 0 { return 0 }
        if attack > 0, t < attack { return (t / attack) * exponential(t: 0, t60: t60) }
        return exponential(t: t - attack, t60: t60)
    }

    /// The time in seconds at which `exponential` reaches `dB` below its peak.
    public static func time(toDecayBy dB: Double, t60: Double) -> Double {
        t60 * dB / 60
    }

    /// A raised-cosine fade over the last `seconds` of a buffer, so a voice that is truncated at its
    /// tail does not end on a step. Applied by the synthesizer to every voice.
    public static func applyFadeOut(_ samples: inout [Float], seconds: Double, sampleRate: Double) {
        let n = min(samples.count, max(1, Int(seconds * sampleRate)))
        guard n > 1 else { return }
        let start = samples.count - n
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            samples[start + i] *= Float(0.5 * (1 + cos(Double.pi * x)))
        }
    }
}

// MARK: - Knob interpolation

public enum SynthInterpolation {
    /// A decay knob's T60 from a SHORT/MID/LONG triple, geometric within each half. Roland publishes
    /// decay as three points per voice, and the middle one is generally *not* the geometric mean of
    /// the outer two — the 808 bass drum's 50/300/800 ms is the clearest case — so interpolating
    /// through two points would put the detent in the wrong place.
    ///
    /// `middle <= 0` falls back to a single geometric sweep between the two ends.
    public static func decay(_ knob: Double, shortest: Double, middle: Double, longest: Double) -> Double {
        let lo = Swift.max(shortest, 1e-5)
        let hi = Swift.max(longest, lo)
        let k = Swift.min(Swift.max(knob, 0), 1)
        guard middle > 0 else { return lo * pow(hi / lo, k) }
        let mid = Swift.min(Swift.max(middle, lo), hi)
        if k <= 0.5 { return lo * pow(mid / lo, k * 2) }
        return mid * pow(hi / mid, (k - 0.5) * 2)
    }
}

// MARK: - Oscillators

/// A phase accumulator that can be frequency-modulated per sample — the pitch envelope of a kick or
/// tom is exactly that. Keeping the phase rather than evaluating `sin(2πft)` is what lets the
/// frequency change without the waveform jumping.
public struct PhaseOscillator: Sendable {
    public private(set) var phase: Double

    public init(phase: Double = 0) { self.phase = phase }

    /// Advances by `frequency` Hz and returns the new phase in radians, wrapped to [0, 2π).
    public mutating func advance(frequency: Double, sampleRate: Double) -> Double {
        phase += 2 * Double.pi * frequency / sampleRate
        if phase >= 2 * Double.pi { phase -= 2 * Double.pi * (phase / (2 * Double.pi)).rounded(.down) }
        return phase
    }

    public mutating func sine(frequency: Double, sampleRate: Double) -> Double {
        sin(advance(frequency: frequency, sampleRate: sampleRate))
    }

    /// A hard square, which is what the 808's hi-hat oscillators actually produce. Deliberately not
    /// band-limited: the aliasing of six squares summed and then band-passed is part of the metallic
    /// character, and the hardware's own square edges are far faster than 48 kHz can represent.
    /// The band-pass that follows removes most of what would fold audibly.
    public mutating func square(frequency: Double, sampleRate: Double) -> Double {
        advance(frequency: frequency, sampleRate: sampleRate) < Double.pi ? 1 : -1
    }
}

// MARK: - Saturation

public enum SynthShaper {
    /// Soft asymmetric saturation. Analog drum voices run into transistor stages that compress the
    /// peak and add low-order harmonics; a pure sine kick sounds thin next to hardware for exactly
    /// this reason. `drive` of 0 is a no-op.
    @inline(__always)
    public static func saturate(_ x: Double, drive: Double) -> Double {
        guard drive > 0 else { return x }
        let g = 1 + drive * 6
        return tanh(g * x) / tanh(g)
    }
}

// MARK: - Bit reduction / decimation
//
// Used only by the `.linn` preset, which models a machine whose voices were 8-bit companded samples
// played back at a fixed, per-voice rate rather than analog circuits.

public enum SynthDegrade {
    /// µ-law companding at `bits`, the coding the first-generation sampled drum machines used to get
    /// usable dynamic range out of 8-bit ROM. µ = 255 is the standard telephony constant.
    /// <https://en.wikipedia.org/wiki/G.711>
    public static func compand(_ x: Double, bits: Int) -> Double {
        guard bits > 0, bits < 24 else { return x }
        let mu = 255.0
        let s = x < 0 ? -1.0 : 1.0
        let a = min(1.0, abs(x))
        let encoded = s * log(1 + mu * a) / log(1 + mu)
        let levels = Double((1 << (bits - 1)) - 1)
        let quantized = (encoded * levels).rounded() / levels
        let q = abs(quantized)
        return (quantized < 0 ? -1.0 : 1.0) * (pow(1 + mu, q) - 1) / mu
    }

    /// Sample-and-hold decimation to `rate`, with **no anti-alias filter in front of it**: content
    /// above `rate / 2` folds down into the baseband, and that folding is the sound of a machine
    /// that clocked 8-bit ROM out at a low fixed rate.
    ///
    /// There *is* a reconstruction low-pass after it, at `0.42 × rate`, because the hardware had
    /// one — the DAC fed an analog filter before the VCA. Without it the sample-and-hold's images
    /// sit above the audio band and dominate any spectral measurement, which is neither what the
    /// machine did nor what it sounded like.
    public static func decimate(_ samples: [Float], from sampleRate: Double, to rate: Double) -> [Float] {
        guard rate > 0, rate < sampleRate else { return samples }
        let step = sampleRate / rate
        var out = samples
        var held: Float = 0
        var nextChange = 0.0
        for i in samples.indices {
            if Double(i) >= nextChange {
                held = samples[i]
                nextChange += step
            }
            out[i] = held
        }
        // Two poles of reconstruction filter, matching a simple analog output stage.
        var a = Biquad.lowPass(frequency: rate * 0.42, sampleRate: sampleRate)
        var b = Biquad.lowPass(frequency: rate * 0.42, sampleRate: sampleRate)
        for i in out.indices { out[i] = Float(b.process(a.process(Double(out[i])))) }
        return out
    }
}

// MARK: - Measurement helpers
//
// Public because the tests measure exactly what the spec comments claim, and because a future
// "re-render after a parameter change" UI wants the same numbers to show.

public enum SynthMeasure {
    /// Peak absolute value.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { Swift.max($0, abs($1)) }
    }

    /// Time in seconds from the peak to the point where a 5 ms RMS envelope has fallen `dB` below
    /// it and stays there. Returns the buffer length when it never does.
    public static func decayTime(_ samples: [Float], toDB dB: Double, sampleRate: Double) -> Double {
        let window = Swift.max(1, Int(0.005 * sampleRate))
        var envelope = [Double](repeating: 0, count: samples.count)
        var sum = 0.0
        for i in samples.indices {
            sum += Double(samples[i]) * Double(samples[i])
            if i >= window { sum -= Double(samples[i - window]) * Double(samples[i - window]) }
            envelope[i] = (sum / Double(Swift.min(i + 1, window))).squareRoot()
        }
        guard let peakValue = envelope.max(), peakValue > 0,
              let peakIndex = envelope.firstIndex(of: peakValue) else { return 0 }
        let target = peakValue * pow(10, -dB / 20)
        for i in peakIndex..<envelope.count where envelope[i] <= target {
            // Require it to stay below, so a zero crossing inside the window does not end the measurement.
            let ahead = Swift.min(envelope.count, i + window)
            if envelope[i..<ahead].allSatisfy({ $0 <= target }) {
                return Double(i - peakIndex) / sampleRate
            }
        }
        return Double(envelope.count - peakIndex) / sampleRate
    }

    /// Magnitude of a single-bin DFT, normalised by window length.
    public static func magnitude(_ samples: [Float], at frequency: Double,
                                 in range: Range<Int>, sampleRate: Double) -> Double {
        guard !range.isEmpty else { return 0 }
        var re = 0.0, im = 0.0
        for i in range where i >= 0 && i < samples.count {
            let phase = 2 * Double.pi * frequency * Double(i - range.lowerBound) / sampleRate
            re += Double(samples[i]) * cos(phase)
            im -= Double(samples[i]) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(range.count)
    }

    /// The frequency of the largest DFT magnitude in `band`, resolved to `resolution` Hz.
    public static func dominantFrequency(_ samples: [Float], in range: Range<Int>,
                                         band: ClosedRange<Double>, sampleRate: Double,
                                         resolution: Double = 1) -> Double {
        var best = band.lowerBound
        var bestMagnitude = -1.0
        var f = band.lowerBound
        while f <= band.upperBound {
            let m = magnitude(samples, at: f, in: range, sampleRate: sampleRate)
            if m > bestMagnitude { bestMagnitude = m; best = f }
            f += resolution
        }
        return best
    }

    /// Spectral centroid in hertz over `range`, from a direct DFT on a Hann window.
    public static func spectralCentroid(_ samples: [Float], in range: Range<Int>,
                                        sampleRate: Double, bins: Int = 512) -> Double {
        guard !range.isEmpty else { return 0 }
        let n = range.count
        var windowed = [Double](repeating: 0, count: n)
        for (j, i) in range.enumerated() where i >= 0 && i < samples.count {
            windowed[j] = Double(samples[i]) * (0.5 - 0.5 * cos(2 * Double.pi * Double(j) / Double(n - 1)))
        }
        var weighted = 0.0, total = 0.0
        let top = sampleRate / 2
        for k in 1...bins {
            let f = top * Double(k) / Double(bins)
            var re = 0.0, im = 0.0
            for j in 0..<n {
                let phase = 2 * Double.pi * f * Double(j) / sampleRate
                re += windowed[j] * cos(phase)
                im -= windowed[j] * sin(phase)
            }
            let m = (re * re + im * im).squareRoot()
            weighted += f * m
            total += m
        }
        return total > 0 ? weighted / total : 0
    }

    /// Counts transients in a signal: rises in a short-window RMS envelope that follow a real dip.
    ///
    /// The criterion is hysteresis, not peak picking: a new transient is counted when the envelope
    /// climbs `riseRatio` above the lowest point since the last one *and* clears `floorFraction` of
    /// the loudest point in the buffer; the detector re-arms only once the envelope has fallen to
    /// `dropRatio` of that transient's own peak. Without the re-arm condition the fluctuation of
    /// band-passed noise counts as a dozen onsets.
    ///
    /// `Analysis.SpectralFluxOnsetDetector` would be the better tool, but `Instrument` does not
    /// depend on `Analysis` and A3 is not the task that should add that edge.
    public static func transientCount(_ samples: [Float], sampleRate: Double,
                                      windowSeconds: Double = 0.005,
                                      riseRatio: Double = 2.0,
                                      dropRatio: Double = 0.5,
                                      floorFraction: Double = 0.1) -> Int {
        let window = Swift.max(1, Int(windowSeconds * sampleRate))
        var envelope = [Double](repeating: 0, count: samples.count)
        var sum = 0.0
        for i in samples.indices {
            sum += Double(samples[i]) * Double(samples[i])
            if i >= window { sum -= Double(samples[i - window]) * Double(samples[i - window]) }
            envelope[i] = (sum / Double(Swift.min(i + 1, window))).squareRoot()
        }
        guard let top = envelope.max(), top > 0 else { return 0 }
        let floor = top * floorFraction

        var count = 0
        var armed = true
        var trough = Double.greatestFiniteMagnitude
        var peak = 0.0
        for value in envelope {
            if armed {
                trough = Swift.min(trough, value)
                if value > floor, value > trough * riseRatio {
                    count += 1
                    armed = false
                    peak = value
                }
            } else {
                peak = Swift.max(peak, value)
                if value < peak * dropRatio {
                    armed = true
                    trough = value
                }
            }
        }
        return count
    }
}
