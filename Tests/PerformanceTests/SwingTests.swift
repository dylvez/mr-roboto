import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// Swing is the one number in this module a listener would notice being wrong by a millisecond, so
/// every expectation here is computed from the *definition* — the odd sixteenth lands at
/// `percent/100` of the eighth-note pair — and never from `Swing`'s own arithmetic.
@Suite("Swing")
struct SwingTests {

    /// Milliseconds an odd sixteenth moves at `percent` swing and `bpm`, from first principles:
    /// the pair spans two sixteenths, the odd one should land `percent`% of the way through it,
    /// and straight would have been halfway.
    static func expectedShiftMilliseconds(percent: Double, bpm: Double) -> Double {
        let sixteenth = 60.0 / bpm / 4.0
        let pair = 2 * sixteenth
        let swungPosition = pair * (percent / 100)
        return (swungPosition - sixteenth) * 1000
    }

    static let percents: [Double] = [54, 58, 62, 66]
    static let tempos: [Double] = [90, 108, 135]

    @Test("odd sixteenths shift by the expected milliseconds",
          arguments: [54.0, 58, 62, 66], [90.0, 108, 135])
    func oddSixteenthShift(percent: Double, bpm: Double) {
        let expected = Self.expectedShiftMilliseconds(percent: percent, bpm: bpm)
        let swing = Swing(percent: percent)
        let timeline = GrooveTimeline.tempo(bpm)

        // One bar of sixteenths on the closed hat: every step sounds, so every step is measurable.
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: swing.factor, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 16)),
        ])
        let hits = GrooveRenderer.render(groove, on: timeline)
        #expect(hits.count == 16)

        let sixteenth = 60.0 / bpm / 4.0
        for (step, hit) in hits.enumerated() {
            let straight = Double(step) * sixteenth
            let shift = (hit.time - straight) * 1000
            if step % 2 == 0 {
                #expect(abs(shift) < 1e-9, "even step \(step) must not move")
            } else {
                #expect(abs(shift - expected) < 1e-9,
                        "step \(step) at \(percent)% / \(bpm) BPM: \(shift) ms, expected \(expected) ms")
            }
        }
    }

    /// The figures a producer would quote, spelled out so a regression is legible in the diff
    /// rather than hidden inside a formula that matches the implementation.
    @Test("the shift figures in milliseconds")
    func namedFigures() {
        // 90 BPM: one sixteenth is 166.667 ms.
        #expect(abs(Self.expectedShiftMilliseconds(percent: 54, bpm: 90) - 13.3333) < 1e-3)
        #expect(abs(Self.expectedShiftMilliseconds(percent: 58, bpm: 90) - 26.6667) < 1e-3)
        #expect(abs(Self.expectedShiftMilliseconds(percent: 62, bpm: 90) - 40.0) < 1e-3)
        #expect(abs(Self.expectedShiftMilliseconds(percent: 66, bpm: 90) - 53.3333) < 1e-3)
        // 108 BPM: 138.889 ms.
        #expect(abs(Self.expectedShiftMilliseconds(percent: 54, bpm: 108) - 11.1111) < 1e-3)
        #expect(abs(Self.expectedShiftMilliseconds(percent: 66, bpm: 108) - 44.4444) < 1e-3)
        // 135 BPM: 111.111 ms.
        #expect(abs(Self.expectedShiftMilliseconds(percent: 54, bpm: 135) - 8.8889) < 1e-3)
        #expect(abs(Self.expectedShiftMilliseconds(percent: 66, bpm: 135) - 35.5556) < 1e-3)
    }

    @Test("percent and factor are the same knob")
    func percentFactorMapping() {
        #expect(Swing(percent: 50).factor == 0)
        #expect(abs(Swing(percent: 75).factor - 1) < 1e-12)
        #expect(abs(Swing(percent: 66.6667).factor - 0.666668) < 1e-5)
        #expect(abs(Swing(factor: 0.5).percent - 62.5) < 1e-12)
        for percent in stride(from: 50.0, through: 75.0, by: 0.5) {
            #expect(abs(Swing(percent: percent).percent - percent) < 1e-9)
        }
        // Out of range clamps to what a machine offers rather than inventing a note value.
        #expect(Swing(percent: 20).percent == 50)
        #expect(Swing(percent: 99).percent == 75)
        #expect(Swing(factor: 4).factor == 1)
        #expect(Swing(factor: -1).factor == 0)
    }

    /// Triplet swing puts the odd sixteenth exactly on the second eighth-note triplet.
    @Test("triplet swing lands on the triplet")
    func tripletLandsOnTriplet() {
        let bpm = 120.0
        let beat = 60.0 / bpm
        let timeline = GrooveTimeline.tempo(bpm)
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: Swing.triplet.factor, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 16)),
        ])
        let hits = GrooveRenderer.render(groove, on: timeline)
        // Step 1 should sit two thirds of the way through the first eighth note, i.e. on the
        // second note of an eighth-note triplet: beat/3.
        #expect(abs(hits[1].time - beat / 3) < 1e-9)
        #expect(abs(hits[3].time - (beat / 2 + beat / 3)) < 1e-9)
    }

    /// Swing is relative to the groove's own step grid: a thirty-second groove swings
    /// thirty-seconds, not sixteenths.
    @Test("swing follows the step resolution")
    func swingFollowsResolution() {
        let bpm = 120.0
        let thirtySecond = 60.0 / bpm / 8.0
        let groove = Groove(stepsPerBar: 32, bars: 1, swing: Swing(percent: 62).factor, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 32)),
        ])
        let hits = GrooveRenderer.render(groove, on: .tempo(bpm))
        let shift = hits[1].time - thirtySecond
        let expected = (2 * thirtySecond) * 0.62 - thirtySecond
        #expect(abs(shift - expected) < 1e-12)
    }
}
