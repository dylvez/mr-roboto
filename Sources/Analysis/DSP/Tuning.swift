import Accelerate
import Foundation

/// How far a recording sits from concert pitch (A = 440 Hz).
///
/// A 78 was cut and is played back at a speed nobody wrote down, and the piano in the room was
/// tuned to whatever it was tuned to, so an old record lands between the keys: its key reads as C
/// and every note of it is a quarter of a semitone flat. Moved by whole semitones it stays that far
/// out against a band at concert pitch, and against the next record, which is out by its own amount.
///
/// The reading is taken from the record's strongest partials across the whole of it. Notes of a
/// tempered scale come back to the same frequencies again and again, so the long-term spectrum has
/// peaks a semitone apart, and the one offset that puts the most of them on the scale is the
/// record's. Noise and drums have no such peaks and give no reading.
public enum Tuning {

    public struct Reading: Hashable, Sendable {
        /// Cents above concert pitch (below when negative), within a quarter tone either way.
        public var cents: Double
        /// How much of the weight of its partials sits on the scale at that offset, 0…1.
        public var confidence: Double

        public init(cents: Double, confidence: Double) {
            self.cents = cents
            self.confidence = confidence
        }
    }

    /// Blocks of about a third of a second: bins under 3 Hz apart, so a partial at 200 Hz is placed
    /// within a few cents once its peak is interpolated.
    static let size = 16_384
    /// Partials are read where pitched instruments and voices are strongest and bins are fine enough.
    static let band = 130.0...2_000.0
    static let partials = 150
    /// A peak under this share of the strongest is not counted (−26 dB).
    static let sideLobe = 0.05
    /// Under this the partials do not agree on a scale: noise, drums, speech.
    public static let leastConfidence = 0.25

    /// The reading for a signal, or nil when it is too short or not pitched enough to say.
    public static func read(_ mono: [Float], sampleRate: Double) -> Reading? {
        guard sampleRate > 0, mono.count >= size * 2 else { return nil }
        let spectrum = meanSpectrum(mono)
        let binHz = sampleRate / Double(size)
        let low = max(2, Int((band.lowerBound / binHz).rounded(.up)))
        let high = min(spectrum.count - 2, Int(band.upperBound / binHz))
        guard high > low + 8 else { return nil }

        // Local peaks, each placed between its bins by the parabola through its log magnitudes.
        var peaks: [(midi: Double, weight: Double)] = []
        for bin in low...high where spectrum[bin] > spectrum[bin - 1] && spectrum[bin] >= spectrum[bin + 1] && spectrum[bin] > 0 {
            let a = log(Double(max(spectrum[bin - 1], 1e-12))), b = log(Double(spectrum[bin])), c = log(Double(max(spectrum[bin + 1], 1e-12)))
            let bend = a - 2 * b + c
            let shift = bend < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / bend)) : 0
            let hz = (Double(bin) + shift) * binHz
            peaks.append((69 + 12 * log2(hz / 440), Double(spectrum[bin])))
        }
        peaks.sort { $0.weight > $1.weight }
        // Only partials, not the ripple beside one: a window's side lobes stand 30 dB under its peak.
        let least = (peaks.first?.weight ?? 0) * sideLobe
        peaks = Array(peaks.prefix(partials).filter { $0.weight >= least })
        let total = peaks.reduce(0) { $0 + $1.weight }
        guard peaks.count >= 8, total > 0 else { return nil }

        // The offset that puts the most weight on the scale: each partial counts for the cosine of
        // how far it is from a tempered note once the offset is taken off.
        func score(_ cents: Double) -> Double {
            peaks.reduce(0) { $0 + $1.weight * cos(2 * .pi * ($1.midi - cents / 100)) } / total
        }
        var best = -50.0, bestScore = -Double.infinity
        for step in -50..<50 {
            let value = score(Double(step))
            if value > bestScore { (best, bestScore) = (Double(step), value) }
        }
        let before = score(best - 1), after = score(best + 1)
        let bend = before - 2 * bestScore + after
        var cents = best + (bend < 0 ? max(-0.5, min(0.5, 0.5 * (before - after) / bend)) : 0)
        if cents >= 50 { cents -= 100 }
        if cents < -50 { cents += 100 }
        guard bestScore >= leastConfidence else { return nil }
        return Reading(cents: (cents * 10).rounded() / 10, confidence: min(1, bestScore))
    }

    /// The magnitude spectrum averaged over half-overlapped Hann blocks of the whole signal.
    static func meanSpectrum(_ mono: [Float]) -> [Float] {
        let half = size / 2
        let window = STFT.periodicHann(size)
        var sum = [Float](repeating: 0, count: half)
        let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }
        var windowed = [Float](repeating: 0, count: size)
        var evens = [Float](repeating: 0, count: half), odds = [Float](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var blocks = 0
        mono.withUnsafeBufferPointer { signal in
            var start = 0
            while start + size <= mono.count {
                vDSP_vmul(signal.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(size))
                for index in 0..<half {
                    evens[index] = windowed[2 * index]
                    odds[index] = windowed[2 * index + 1]
                }
                vDSP_DFT_Execute(setup, evens, odds, &real, &imaginary)
                real.withUnsafeMutableBufferPointer { r in
                    imaginary.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                vDSP_vadd(sum, 1, magnitudes, 1, &sum, 1, vDSP_Length(half))
                blocks += 1
                start += half
            }
        }
        guard blocks > 0 else { return sum }
        var scale = 1 / Float(blocks)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(half))
        return sum
    }
}
