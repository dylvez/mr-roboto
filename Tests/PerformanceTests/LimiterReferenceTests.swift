import Foundation
import Testing

@testable import Performance

// The limiter's lookahead and the true-peak envelope were rewritten to run in linear time: the
// limiter slides its minimum on a ring, the envelope convolves with Accelerate. These hold them to
// the straightforward algorithms they replaced, sample for sample.

@Suite("Limiter and true peak, against their reference algorithms")
struct LimiterReferenceTests {
    private let rate = 48_000.0

    /// Two seconds of loud noise with bursts: peaks everywhere, over the ceiling often.
    private func signal(seed: UInt64) -> [[Float]] {
        var state = seed
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
        }
        return (0..<2).map { _ in
            (0..<Int(rate * 2)).map { i in next() * (i % 9_600 < 800 ? 1.4 : 0.5) }
        }
    }

    /// The true-peak envelope as the scalar loop computed it.
    private func referenceEnvelope(_ planar: [[Float]]) -> [Float] {
        let taps = 48, factor = 4
        var kernel = [Float](repeating: 0, count: taps)
        let centre = Double(taps - 1) / 2
        for i in 0..<taps {
            let x = Double(i) - centre
            let sinc = x == 0 ? 1.0 : sin(.pi * x / Double(factor)) / (.pi * x / Double(factor))
            kernel[i] = Float(sinc * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1))))
        }
        for phase in 0..<factor {
            var sum: Float = 0
            var j = phase
            while j < taps { sum += kernel[j]; j += factor }
            j = phase
            while j < taps { kernel[j] /= sum; j += factor }
        }
        let frames = planar[0].count
        var envelope = [Float](repeating: 0, count: frames)
        for lane in planar {
            for n in 0..<frames {
                var peak: Float = 0
                for phase in 0..<factor {
                    var acc: Float = 0
                    var j = phase, m = n
                    while j < taps, m >= 0 { acc += kernel[j] * lane[m]; j += factor; m -= 1 }
                    peak = max(peak, abs(acc))
                }
                let at = max(0, n - (taps - 1) / (2 * factor))
                envelope[at] = max(envelope[at], peak)
            }
        }
        return envelope
    }

    @Test("the true-peak envelope is the scalar one's, to rounding")
    func envelope() {
        let planar = signal(seed: 7)
        let fast = MixMeter.truePeakEnvelope(planar)
        let slow = referenceEnvelope(planar)
        #expect(fast.count == slow.count)
        let worst = zip(fast, slow).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-5, "largest difference \(worst)")
    }

    @Test("integrated loudness is the scalar reading's, to a hundredth of a LU")
    func loudness() {
        let planar = signal(seed: 23)
        let (shelf, highPass) = MixMeter.kWeighting(sampleRate: rate)
        let weighted = planar.map { highPass.filter(shelf.filter($0)) }
        let block = Int(0.4 * rate), hop = Int(0.1 * rate)
        var blocks: [Double] = []
        var start = 0
        while start + block <= weighted[0].count {
            var sum = 0.0
            for channel in weighted {
                var acc = 0.0
                for i in start..<(start + block) { acc += Double(channel[i]) * Double(channel[i]) }
                sum += acc / Double(block)
            }
            blocks.append(sum)
            start += hop
        }
        func lkfs(_ ms: Double) -> Double { -0.691 + 10 * log10(ms) }
        let absolute = blocks.filter { lkfs($0) > -70 }
        let gate = lkfs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lkfs($0) > gate }
        let reference = lkfs(gated.reduce(0, +) / Double(gated.count))
        #expect(abs(MixMeter.integratedLoudness(planar, sampleRate: rate) - reference) < 0.01)
    }

    @Test("the limiter's sliding minimum is the scanned one's, exactly")
    func limiter() {
        let planar = signal(seed: 11)
        let ceilingDBTP = -1.0
        let limited = Limiter.apply(planar, sampleRate: rate, ceilingDBTP: ceilingDBTP)
        // The reference: the same gain computed with the minimum scanned at every frame.
        let frames = planar[0].count
        let ceiling = Float(pow(10, (ceilingDBTP - Limiter.headroomDB) / 20))
        let look = max(1, Int(Limiter.lookahead * rate))
        let release = Float(exp(-1 / (Limiter.release * rate)))
        let peaks = MixMeter.truePeakEnvelope(planar)
        var needed = [Float](repeating: 1, count: frames)
        for i in 0..<frames {
            var peak = peaks[i]
            for lane in planar { peak = max(peak, abs(lane[i])) }
            if peak > ceiling { needed[i] = ceiling / peak }
        }
        var envelope: Float = 1
        var expected = planar
        for i in 0..<frames {
            var minimum: Float = 1
            for k in 0...look where i + k < frames { minimum = min(minimum, needed[i + k]) }
            if minimum < envelope { envelope = minimum } else { envelope = minimum + (envelope - minimum) * release }
            for c in 0..<expected.count { expected[c][i] = planar[c][i] * envelope }
        }
        #expect(limited == expected)
    }
}
