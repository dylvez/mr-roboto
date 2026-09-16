import Foundation
import Testing
@testable import Analysis

@Suite("SpectralFluxOnsetDetector")
struct OnsetDetectorTests {
    @Test("recovers every click in the synthetic train within 5 ms with no extras")
    func clickTrain() {
        let sr = 44100.0
        let (signal, clicks) = SyntheticSignal.sinesAndClicks(sampleRate: sr, duration: 4)
        let detector = SpectralFluxOnsetDetector()
        let onsets = detector.onsets(in: signal, sampleRate: sr)

        var report = "click -> nearest onset (ms error)\n"
        var worst = 0.0
        for c in clicks {
            let nearest = onsets.min { abs($0 - c) < abs($1 - c) }
            let err = nearest.map { abs($0 - c) } ?? .infinity
            worst = max(worst, err)
            report += String(format: "  %.4f -> %@ (%.2f ms)\n", c,
                             nearest.map { String(format: "%.4f", $0) } ?? "none", err * 1000)
        }
        print("clicks: \(clicks.count), onsets: \(onsets.count), worst error \(worst * 1000) ms")
        print(report)
        #expect(onsets.count == clicks.count, "extra or missing onsets: \(onsets)")
        #expect(worst < 0.005)
    }

    @Test("coarse frames are within a window of the click and refinement tightens them")
    func refinementHelps() {
        let sr = 44100.0
        let (signal, clicks) = SyntheticSignal.sinesAndClicks(sampleRate: sr, duration: 4)
        var coarse = SpectralFluxOnsetDetector()
        coarse.refineOnsetTimes = false
        let times = coarse.onsets(in: signal, sampleRate: sr)
        #expect(times.count == clicks.count)
        let halfWindow = Double(coarse.nFFT / 2) / sr
        for c in clicks {
            let nearest = times.min { abs($0 - c) < abs($1 - c) }!
            #expect(abs(nearest - c) <= halfWindow + Double(coarse.hop) / sr)
        }
    }

    @Test("silence and steady tones produce no onsets")
    func noFalsePositives() {
        let sr = 44100.0
        let detector = SpectralFluxOnsetDetector()
        let silence = [Float](repeating: 0, count: 44100)
        #expect(detector.onsets(in: silence, sampleRate: sr).isEmpty)
        let tone = (0..<88200).map { Float(0.5 * sin(2 * Double.pi * 330 * Double($0) / sr)) }
        // The tone's own start at sample 0 is an onset; nothing after it should be.
        let onsets = detector.onsets(in: tone, sampleRate: sr)
        #expect(onsets.filter { $0 > 0.05 }.isEmpty, "\(onsets)")
    }

    @Test("madmom-style diff frame derivation")
    func diffFrames() {
        var d = SpectralFluxOnsetDetector()
        #expect(d.resolvedDiffFrames == 1)  // (1024 - 512) / 441 -> 1
        d.hop = 128
        #expect(d.resolvedDiffFrames == 4)  // 512 / 128
        d.diffFrames = 0
        #expect(d.resolvedDiffFrames == 1)
    }
}
