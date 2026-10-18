import Foundation
import Testing

@testable import Analysis

/// A take pulled onto its key: a voice sung flat lands on its note, vibrato survives the natural
/// setting and not the hard one, the take keeps its length and its timing, and a note already in
/// tune is left where it was.
@Suite("Pitch correction")
struct PitchCorrectionTests {
    private static let rate = 48_000.0
    private static let cMajor: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    /// A voice-like tone: a fundamental and falling harmonics, its pitch `cents` off A4 with a
    /// vibrato `vibratoCents` deep at 5.5 Hz, from `start` for `seconds`.
    private func voice(cents: Double, vibratoCents: Double = 0, seconds: Double = 1.6, start: Double = 0.2) -> [Float] {
        let frames = Int((seconds + start + 0.2) * Self.rate)
        var out = [Float](repeating: 0, count: frames)
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / Self.rate
            guard t >= start, t < start + seconds else { continue }
            let c = cents + vibratoCents * sin(2 * .pi * 5.5 * t)
            let hz = 440 * pow(2, c / 1200)
            phase += hz / Self.rate
            let envelope = min(1, (t - start) / 0.02) * min(1, (start + seconds - t) / 0.02)
            var x = 0.0
            for h in 1...6 { x += sin(2 * .pi * phase * Double(h)) / Double(h * h) }
            out[i] = Float(0.3 * envelope * x)
        }
        return out
    }

    /// The tracked pitch's mean distance from A4, in cents, over the middle of the note.
    private func centsFromA(_ signal: [Float]) -> Double {
        let frames = PitchTracker().track(signal, sampleRate: Self.rate).filter { $0.time > 0.6 && $0.time < 1.4 }.compactMap(\.midi)
        return frames.map { ($0 - 69) * 100 }.reduce(0, +) / Double(max(1, frames.count))
    }

    private func spread(_ signal: [Float]) -> Double {
        let frames = PitchTracker().track(signal, sampleRate: Self.rate).filter { $0.time > 0.6 && $0.time < 1.4 }.compactMap(\.midi)
        guard let low = frames.min(), let high = frames.max() else { return 0 }
        return (high - low) * 100
    }

    @Test("A voice 40 cents flat lands within ten cents of its note at every strength")
    func flatVoiceLands() throws {
        let take = voice(cents: -40)
        for strength in PitchCorrection.Strength.allCases {
            let result = try PitchCorrection.correct([take], sampleRate: Self.rate, pitchClasses: Self.cMajor, strength: strength)
            #expect(result.planar[0].count == take.count)
            let off = centsFromA(result.planar[0])
            #expect(abs(off) < 10, "\(strength): \(off) cents from A")
            #expect(result.centsAfter < result.centsBefore)
        }
    }

    @Test("Natural keeps the vibrato; hard irons it flat")
    func vibrato() throws {
        let take = voice(cents: -30, vibratoCents: 35)
        let natural = try PitchCorrection.correct([take], sampleRate: Self.rate, pitchClasses: Self.cMajor, strength: .natural)
        let hard = try PitchCorrection.correct([take], sampleRate: Self.rate, pitchClasses: Self.cMajor, strength: .hard)
        let sung = spread(take), kept = spread(natural.planar[0]), ironed = spread(hard.planar[0])
        #expect(kept > 0.6 * sung, "natural keeps \(kept) of \(sung) cents of swing")
        #expect(ironed < 0.6 * kept, "hard leaves \(ironed) against natural's \(kept)")
    }

    @Test("A note in tune is left in tune, and the take's onset stays where it was sung")
    func inTuneAndInTime() throws {
        let take = voice(cents: 0, start: 0.5)
        let result = try PitchCorrection.correct([take], sampleRate: Self.rate, pitchClasses: Self.cMajor, strength: .tight)
        #expect(abs(centsFromA(result.planar[0])) < 6)
        #expect(result.largestShift < 0.1)
        func onset(_ x: [Float]) -> Int { x.firstIndex { abs($0) > 0.05 } ?? 0 }
        #expect(abs(onset(result.planar[0]) - onset(take)) < Int(0.01 * Self.rate), "onset moved \(onset(result.planar[0]) - onset(take)) samples")
    }

    @Test("Notes outside the key are taken to the nearest one in it")
    func nearestInKey() {
        // A♯ is not in C major: A or B, whichever is nearer.
        #expect(PitchCorrection.nearest(70.3, in: Self.cMajor) == 71)
        #expect(PitchCorrection.nearest(69.7, in: Self.cMajor) == 69)
        #expect(PitchCorrection.nearest(64.4, in: Self.cMajor) == 64)
    }
}
