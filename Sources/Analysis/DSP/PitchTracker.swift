import Accelerate
import Foundation

// M5 R6: a monophonic pitch tracker for takes.
//
// YIN (de Cheveigné & Kawahara, 2002) with the cumulative-mean-normalised difference function and
// parabolic refinement of the lag, 10 ms hop, and a voicing confidence of 1 − d'(τ). No model,
// no download, deterministic: the same code on the Mac and later on the phone. A note segmenter
// turns the frame track into notes with a median pitch and a cents offset from equal temperament.

public struct PitchFrame: Hashable, Sendable {
    /// Seconds from the start of the signal.
    public var time: Double
    /// Hz, or nil when unvoiced.
    public var frequency: Double?
    /// 0…1: how sure the tracker is that the frame is periodic at this frequency.
    public var confidence: Double

    public var midi: Double? { frequency.map { 69 + 12 * log2($0 / 440) } }
}

/// One sung note: a run of voiced frames within a semitone of each other.
public struct TrackedNote: Hashable, Sendable {
    public var start: Double
    public var end: Double
    /// The median of the frames' MIDI pitch, fractional.
    public var midi: Double
    /// The nearest equal-tempered note.
    public var nearest: Int { Int(midi.rounded()) }
    /// Cents from the nearest note: +31 is sharp.
    public var cents: Double { (midi - Double(nearest)) * 100 }
    public var duration: Double { end - start }
    public var frequency: Double { 440 * pow(2, (midi - 69) / 12) }
}

public struct PitchTracker: Sendable {
    /// Frames per second: the hop.
    public var hopSeconds: Double = 0.010
    /// The analysis window; long enough for 60 Hz at 48 kHz.
    public var windowSeconds: Double = 0.040
    public var minimumFrequency: Double = 60
    public var maximumFrequency: Double = 1_200
    /// YIN's absolute threshold on d'(τ): the first dip under it wins.
    public var threshold: Double = 0.15
    /// Frames quieter than this (RMS, dBFS) are unvoiced whatever the period says.
    public var silenceDB: Double = -50

    public init() {}

    /// The frame track of a mono signal.
    public func track(_ signal: [Float], sampleRate: Double) -> [PitchFrame] {
        let hop = max(1, Int(hopSeconds * sampleRate))
        let window = max(64, Int(windowSeconds * sampleRate))
        let minLag = max(2, Int(sampleRate / maximumFrequency))
        let maxLag = min(window / 2, Int(sampleRate / minimumFrequency))
        guard signal.count >= window, maxLag > minLag else { return [] }
        var frames: [PitchFrame] = []
        var start = 0
        var difference = [Double](repeating: 0, count: maxLag + 1)
        var cumulative = [Double](repeating: 0, count: maxLag + 1)
        while start + window <= signal.count {
            let time = Double(start + window / 2) / sampleRate
            let frame = signal[start..<(start + window)]
            var energy: Float = 0
            frame.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &energy, vDSP_Length(window)) }
            let rms = 20 * log10(Double(sqrt(energy)) + 1e-12)
            if rms < silenceDB {
                frames.append(PitchFrame(time: time, frequency: nil, confidence: 0))
                start += hop
                continue
            }
            // d(τ) = Σ (x[n] − x[n+τ])² over the half window, for τ in 1…maxLag.
            let half = window / 2
            frame.withUnsafeBufferPointer { x in
                let base = x.baseAddress!
                for tau in 1...maxLag {
                    var sum: Float = 0
                    // (x[n] - x[n+τ]) with vDSP: subtract, then sum of squares.
                    var diff = [Float](repeating: 0, count: half)
                    vDSP_vsub(base + tau, 1, base, 1, &diff, 1, vDSP_Length(half))
                    vDSP_svesq(diff, 1, &sum, vDSP_Length(half))
                    difference[tau] = Double(sum)
                }
            }
            // Cumulative mean normalisation: d'(τ) = d(τ) / ((1/τ) Σ_{j≤τ} d(j)); d'(0) = 1.
            cumulative[0] = 1
            var running = 0.0
            for tau in 1...maxLag {
                running += difference[tau]
                cumulative[tau] = running > 0 ? difference[tau] * Double(tau) / running : 1
            }
            // The first dip under the threshold, taken at its local minimum; else the global minimum.
            var lag = -1
            var tau = minLag
            while tau <= maxLag {
                if cumulative[tau] < threshold {
                    while tau + 1 <= maxLag, cumulative[tau + 1] < cumulative[tau] { tau += 1 }
                    lag = tau
                    break
                }
                tau += 1
            }
            if lag < 0 {
                var best = minLag
                for t in minLag...maxLag where cumulative[t] < cumulative[best] { best = t }
                lag = best
            }
            let dip = cumulative[lag]
            let confidence = max(0, min(1, 1 - dip))
            guard dip < 0.5 else {
                frames.append(PitchFrame(time: time, frequency: nil, confidence: confidence))
                start += hop
                continue
            }
            // Parabolic refinement around the lag.
            var refined = Double(lag)
            if lag > minLag, lag < maxLag {
                let a = cumulative[lag - 1], b = cumulative[lag], c = cumulative[lag + 1]
                let denominator = a - 2 * b + c
                if abs(denominator) > 1e-12 { refined += 0.5 * (a - c) / denominator }
            }
            frames.append(PitchFrame(time: time, frequency: sampleRate / refined, confidence: confidence))
            start += hop
        }
        return frames
    }

    /// Notes from a track: runs of voiced frames within a semitone of the run's running median,
    /// at least `minimumDuration` long.
    public func notes(in frames: [PitchFrame], minimumDuration: Double = 0.06) -> [TrackedNote] {
        var notes: [TrackedNote] = []
        var run: [PitchFrame] = []
        func flush() {
            defer { run.removeAll() }
            guard let first = run.first, let last = run.last else { return }
            // A frame's time is its window's centre: the note began about half a window before
            // the first voiced frame and ended about half a window after the last.
            let start = max(0, first.time - windowSeconds / 2)
            let end = last.time + windowSeconds / 2
            guard end - start >= minimumDuration else { return }
            let midis = run.compactMap(\.midi).sorted()
            guard !midis.isEmpty else { return }
            let median = midis.count % 2 == 1 ? midis[midis.count / 2] : (midis[midis.count / 2 - 1] + midis[midis.count / 2]) / 2
            notes.append(TrackedNote(start: start, end: end, midi: median))
        }
        for frame in frames {
            guard let midi = frame.midi, frame.confidence >= 0.5 else { flush(); continue }
            if let anchor = run.last?.midi, abs(midi - runMedian(run) ) > 0.7, abs(midi - anchor) > 0.7 {
                flush()
            }
            run.append(frame)
        }
        flush()
        return notes
    }

    private func runMedian(_ run: [PitchFrame]) -> Double {
        let midis = run.compactMap(\.midi).sorted()
        guard !midis.isEmpty else { return 0 }
        return midis[midis.count / 2]
    }
}
