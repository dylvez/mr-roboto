import Foundation
import Testing
@testable import Analysis

@Suite("STFT")
struct STFTTests {
    @Test("frame count and window follow the torch convention")
    func convention() {
        let stft = STFT(nFFT: 2048, hop: 512)
        #expect(stft.binCount == 1025)
        #expect(stft.frameCount(forLength: 176400) == 345)  // 1 + 176400 // 512
        #expect(stft.window[0] == 0)
        #expect(abs(Double(stft.window[1024]) - 1) < 1e-6)
        // Periodic (not symmetric): w[1] == w[N-1] and the window never reaches 1 at N-1.
        #expect(stft.window[1] == stft.window[2047])
    }

    @Test("reflect padding mirrors without repeating the edge")
    func reflectPad() {
        let padded = STFT.reflectPad([0, 1, 2, 3, 4], by: 2)
        #expect(padded == [2, 1, 0, 1, 2, 3, 4, 3, 2])
    }

    @Test("forward + inverse reconstructs within 1e-4 RMS at 4x Hann overlap")
    func roundTrip() {
        var rng = LCG(seed: 0xDEADBEEF)
        let n = 44100
        var x = (0..<n).map { _ in rng.next() * 0.5 }
        for i in 0..<n { x[i] += 0.4 * Float(sin(2 * Double.pi * 441 * Double(i) / 44100)) }
        let stft = STFT(nFFT: 2048, hop: 512)
        let spec = stft.forward(x)
        #expect(spec.frameCount == stft.frameCount(forLength: n))
        let y = stft.inverse(spec, length: n)
        #expect(y.count == n)
        let err = rms(zip(x, y).map { $0 - $1 })
        print("STFT round trip RMS error: \(err) (signal RMS \(rms(x)))")
        #expect(err < 1e-4)
        // Default length (no `length` argument) is hop * (frames - 1), as torch.istft.
        #expect(stft.inverse(spec).count == 512 * (spec.frameCount - 1))
    }

    @Test("magnitude matches torch.stft golden within 1e-3 relative error (first 20 frames)")
    func parityWithGolden() throws {
        try #require(DSPFixtures.exists(DSPFixtures.stftGolden),
                     "run `cd Bench/python && uv run stft_golden.py` to create the golden")
        let golden = try STFTGolden.load()
        let (signal, clicks) = SyntheticSignal.sinesAndClicks(sampleRate: golden.sampleRate, duration: golden.duration)

        // The Swift signal must be the same signal the Python script transformed.
        #expect(signal.count == golden.signalLength)
        #expect(clicks == golden.clickTimes)
        for (a, b) in zip(signal.prefix(8), golden.signalHead) { #expect(a == b) }
        let sum = signal.reduce(0.0) { $0 + Double($1) }
        let absSum = signal.reduce(0.0) { $0 + Double(abs($1)) }
        #expect(abs(sum - golden.signalSum) < 1e-3)
        #expect(abs(absSum - golden.signalAbsSum) < 1e-2)

        let stft = STFT(nFFT: golden.nFft, hop: golden.hop)
        let mag = stft.forward(signal).magnitude()
        #expect(mag.frameCount == golden.totalFrames)
        #expect(mag.binCount == golden.bins)

        let framesToCheck = min(20, golden.frames)
        var worstRelative = 0.0        // |a-b| / |b| over bins that carry energy (>= 1e-3 * frame peak)
        var worstNormalized = 0.0      // |a-b| / frame peak over all bins
        var worstRelativeAll = 0.0     // |a-b| / |b| over every bin, informational
        for t in 0..<framesToCheck {
            let ref = golden.magnitudes[t]
            let peak = Double(ref.max() ?? 1)
            for k in 0..<golden.bins {
                let a = Double(mag[t, k]), b = Double(ref[k])
                let diff = abs(a - b)
                worstNormalized = max(worstNormalized, diff / peak)
                if b > 0 { worstRelativeAll = max(worstRelativeAll, diff / b) }
                if b >= 1e-3 * peak { worstRelative = max(worstRelative, diff / b) }
            }
        }
        print("""
            STFT parity vs \(golden.generator), frames 0..<\(framesToCheck):
              max relative error (bins >= 1e-3 x frame peak): \(worstRelative)
              max error normalised to frame peak:            \(worstNormalized)
              max relative error over every bin:             \(worstRelativeAll)
            """)
        #expect(worstRelative < 1e-3)
        #expect(worstNormalized < 1e-4)
    }
}

@Suite("Mel filterbank")
struct MelFilterbankTests {
    @Test("scale conversions round-trip and hit known anchors")
    func scales() {
        #expect(abs(MelScale.slaney.hzToMel(1000) - 15) < 1e-12)
        #expect(abs(MelScale.htk.hzToMel(1000) - 1000) < 0.1)  // 2595·log10(1 + 1000/700) = 999.985
        for f in [0.0, 30, 440, 999, 1000, 1001, 4000, 17000, 22050] {
            for s in [MelScale.slaney, .htk] {
                #expect(abs(s.melToHz(s.hzToMel(f)) - f) < 1e-6 * max(1, f))
            }
        }
    }

    @Test("filters are triangles that tile the range; unit-sum rows sum to one")
    func shapes() {
        let bank = MelFilterbank(sampleRate: 44100, nFFT: 2048, melCount: 40, minFrequency: 30,
                                 maxFrequency: 17000, scale: .slaney, normalization: .unitSum)
        #expect(bank.weights.count == 40 * 1025)
        for m in 0..<40 {
            let row = bank.weights[(m * 1025)..<((m + 1) * 1025)]
            #expect(abs(row.reduce(0, +) - 1) < 1e-4)
            #expect(row.allSatisfy { $0 >= 0 })
        }
        #expect(bank.centerFrequencies == bank.centerFrequencies.sorted())
        #expect(bank.centerFrequencies.first! > 30 && bank.centerFrequencies.last! < 17000)

        // Slaney normalisation: each filter integrates to ~1 over Hz (area = 2/(hi-lo) * width/2).
        let slaney = MelFilterbank(sampleRate: 44100, nFFT: 2048, melCount: 40, normalization: .slaney)
        let binHz = 44100.0 / 2048
        for m in 5..<40 {  // skip the lowest bands, which are only a few bins wide
            let row = slaney.weights[(m * 1025)..<((m + 1) * 1025)]
            let area = Double(row.reduce(0, +)) * binHz
            #expect(abs(area - 1) < 0.1, "band \(m) area \(area)")
        }
    }

    @Test("log-mel of a sine peaks in the band containing it")
    func logMelOfSine() {
        let sr = 44100.0, f = 1000.0
        let x = (0..<44100).map { Float(0.5 * sin(2 * Double.pi * f * Double($0) / sr)) }
        let stft = STFT(nFFT: 2048, hop: 512)
        let bank = MelFilterbank(sampleRate: sr, nFFT: 2048, melCount: 64)
        let logMel = bank.logMel(of: stft.forward(x), power: 2)
        #expect(logMel.frameCount == stft.frameCount(forLength: x.count))
        #expect(logMel.binCount == 64)
        let frame = Array(logMel.frame(20))
        let peakBand = frame.indices.max { frame[$0] < frame[$1] }!
        let peakHz = bank.centerFrequencies[peakBand]
        #expect(abs(peakHz - f) < 100, "peak band centre \(peakHz) Hz")
    }
}
