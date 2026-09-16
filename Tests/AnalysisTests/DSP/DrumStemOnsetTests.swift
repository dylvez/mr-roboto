import Foundation
import Testing
@testable import Analysis

/// Integration: SuperFlux onsets on the real Demucs drum stem vs the Beat This! beat list.
/// Beats are a subset of drum onsets (and are quantised to Beat This!'s 20 ms frame grid), so
/// the meaningful number is recall of beats by onsets, not precision.
@Suite("Drum stem onsets vs beats", .serialized)
struct DrumStemOnsetTests {
    static let toleranceSeconds = 0.020
    static let target = 0.85
    /// Beats where the drum stem is quieter than this around the beat carry no drum hit to find.
    static let activeFloorDBFS: Float = -45

    /// Beats whose ±50 ms window in `samples` has RMS above `activeFloorDBFS`.
    static func activeBeats(_ beats: [Double], samples: [Float], sampleRate: Double) -> [Double] {
        let half = Int(0.05 * sampleRate)
        return beats.filter { b in
            let c = Int(b * sampleRate)
            let lo = max(0, c - half), hi = min(samples.count, c + half)
            guard hi > lo else { return false }
            var acc: Float = 0
            for i in lo..<hi { acc += samples[i] * samples[i] }
            let rms = (acc / Float(hi - lo)).squareRoot()
            return 20 * log10(max(rms, 1e-9)) > activeFloorDBFS
        }
    }

    static func coverage(beats: [Double], onsets: [Double], tolerance: Double) -> Double {
        guard !beats.isEmpty else { return 0 }
        var hits = 0
        var j = 0
        for b in beats {
            while j + 1 < onsets.count && onsets[j] < b - tolerance { j += 1 }
            var found = false
            var k = j
            while k < onsets.count && onsets[k] <= b + tolerance {
                if abs(onsets[k] - b) <= tolerance { found = true; break }
                k += 1
            }
            if found { hits += 1 }
        }
        return Double(hits) / Double(beats.count)
    }

    static func loadStem() throws -> (samples: [Float], beats: BeatGolden) {
        try #require(DSPFixtures.exists(DSPFixtures.arrivalDrums), "drum stem fixture missing; skipping")
        try #require(DSPFixtures.exists(DSPFixtures.arrivalBeats), "beats.json fixture missing; skipping")
        let samples = try Resampler().monoSamples(fromFileAt: DSPFixtures.arrivalDrums)
        return (samples, try BeatGolden.load())
    }

    @Test("fraction of beats with an onset within 20 ms")
    func beatCoverage() throws {
        let (samples, golden) = try Self.loadStem()
        let detector = SpectralFluxOnsetDetector()
        let onsets = detector.onsets(in: samples, sampleRate: 44100)
        let cov20 = Self.coverage(beats: golden.beats, onsets: onsets, tolerance: Self.toleranceSeconds)
        let cov30 = Self.coverage(beats: golden.beats, onsets: onsets, tolerance: 0.030)
        let cov50 = Self.coverage(beats: golden.beats, onsets: onsets, tolerance: 0.050)
        let downbeatCov = Self.coverage(beats: golden.downbeats, onsets: onsets, tolerance: Self.toleranceSeconds)
        let duration = Double(samples.count) / 44100
        print("""
            Arrival drums: \(onsets.count) onsets in \(String(format: "%.1f", duration)) s \
            (\(String(format: "%.2f", Double(onsets.count) / duration)) / s), \(golden.beats.count) beats
              beats with an onset within 20 ms: \(String(format: "%.3f", cov20))
              beats with an onset within 30 ms: \(String(format: "%.3f", cov30))
              beats with an onset within 50 ms: \(String(format: "%.3f", cov50))
              downbeats with an onset within 20 ms: \(String(format: "%.3f", downbeatCov))
            """)
        let uncovered = golden.beats.filter { b in !onsets.contains { abs($0 - b) <= 0.05 } }
        print("  beats with no onset within 50 ms (\(uncovered.count)): " +
              uncovered.map { String(format: "%.2f", $0) }.joined(separator: " "))
        // Signed offset (onset - beat) for beats matched within 50 ms: is the residual a bias?
        let offsets = golden.beats.compactMap { b -> Double? in
            guard let o = onsets.min(by: { abs($0 - b) < abs($1 - b) }), abs(o - b) <= 0.05 else { return nil }
            return o - b
        }.sorted()
        if !offsets.isEmpty {
            let mean = offsets.reduce(0, +) / Double(offsets.count)
            let median = offsets[offsets.count / 2]
            let sd = (offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(offsets.count)).squareRoot()
            print(String(format: "  onset - beat for matched beats: mean %+.1f ms, median %+.1f ms, sd %.1f ms (beats are on a 20 ms grid)",
                         mean * 1000, median * 1000, sd * 1000))
        }
        #expect(!onsets.isEmpty)
        // The acceptance metric excludes beats where the drums are silent (breakdowns, the outro):
        // there is no hit to find there, so counting them measures the arrangement, not the detector.
        let active = Self.activeBeats(golden.beats, samples: samples, sampleRate: 44100)
        let activeCov20 = Self.coverage(beats: active, onsets: onsets, tolerance: Self.toleranceSeconds)
        print("  beats with drums present (RMS > \(Self.activeFloorDBFS) dBFS in ±50 ms): \(active.count) of \(golden.beats.count)")
        print("  of those, with an onset within 20 ms: \(String(format: "%.3f", activeCov20))  (target > \(Self.target))")
        #expect(active.count > golden.beats.count / 2)
        #expect(activeCov20 > Self.target)
    }

    /// Parameter sweep for tuning defaults. Enabled only with `DSP_TUNE=1` in the environment:
    /// `DSP_TUNE=1 swift test --filter tuningSweep`.
    @Test("tuning sweep", .enabled(if: ProcessInfo.processInfo.environment["DSP_TUNE"] != nil))
    func tuningSweep() throws {
        let (samples, golden) = try Self.loadStem()
        let (clickSignal, clicks) = SyntheticSignal.sinesAndClicks()
        print("lambda\tthresh\tonsets/s\tcov20\tcov30\tclicks(found/extra/worst ms)")
        for lambda: Float in [100, 1000, 10000, 32768] {
            for threshold: Float in [2, 4, 6, 8, 12, 16] {
                var d = SpectralFluxOnsetDetector()
                d.logCompression = lambda
                d.threshold = threshold
                let onsets = d.onsets(in: samples, sampleRate: 44100)
                let cov20 = Self.coverage(beats: golden.beats, onsets: onsets, tolerance: 0.02)
                let cov30 = Self.coverage(beats: golden.beats, onsets: onsets, tolerance: 0.03)
                let rate = Double(onsets.count) / (Double(samples.count) / 44100)
                let clickOnsets = d.onsets(in: clickSignal, sampleRate: 44100)
                var worst = 0.0, found = 0
                for c in clicks {
                    let e = clickOnsets.map { abs($0 - c) }.min() ?? .infinity
                    if e < 0.005 { found += 1 }
                    worst = max(worst, e)
                }
                print(String(format: "%.0f\t%.0f\t%.2f\t%.3f\t%.3f\t%d/%d/%.1f", lambda, threshold, rate, cov20, cov30,
                             found, clickOnsets.count - found, worst * 1000))
            }
        }
    }
}
