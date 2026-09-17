import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// Re-grooving a chop onto the grid detected from a record is M1's core move, and a detected grid
/// is not metronomic. These tests use a grid whose beats are deliberately, audibly uneven — up to
/// 900 ms apart and down to 400 — so that anything computing `60 / bpm` instead of asking the grid
/// fails by a wide margin rather than by rounding.
@Suite("Groove timeline")
struct GrooveTimelineTests {

    /// Eight beats, two bars of 4/4, spaced anywhere between 0.4 s and 0.9 s.
    static let unevenBeats: [Double] = [0, 0.7, 1.3, 2.1, 2.5, 3.4, 3.9, 4.8]
    static let unevenGrid = BeatGrid(beats: unevenBeats, bars: [0, 2.5],
                                     bpm: 100, timeSignature: .fourFour)

    @Test("the fixture really is uneven")
    func fixtureIsUneven() {
        let intervals = zip(Self.unevenBeats.dropFirst(), Self.unevenBeats).map { $0 - $1 }
        // 0.4 s to 0.9 s between beats — a 2.25:1 spread, far past anything a tempo could absorb.
        #expect(intervals.min()! < 0.45)
        #expect(intervals.max()! > 0.85)
        #expect(intervals.max()! / intervals.min()! > 2)
    }

    @Test("a groove on a detected grid lands on the grid's own beat times")
    func hitsLandOnDetectedBeats() {
        // Kick on every beat of two bars: sixteen steps per bar, four steps per beat.
        let steps = (0..<32).map { $0 % 4 == 0 ? VelocityTier.accent : .rest }
        let groove = Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: steps),
        ])
        let timeline = GrooveTimeline.grid(Self.unevenGrid)
        let hits = GrooveRenderer.render(groove, on: timeline)

        #expect(hits.count == 8)
        for (index, hit) in hits.enumerated() {
            #expect(abs(hit.time - Self.unevenBeats[index]) < 1e-12,
                    "beat \(index) landed at \(hit.time), grid says \(Self.unevenBeats[index])")
        }

        // The same groove on a metronome would be wrong by more than a hundred milliseconds —
        // this is the assumption the grid case exists to avoid.
        let metronomic = GrooveRenderer.render(groove, on: .tempo(100))
        let worst = zip(hits, metronomic).map { abs($0.time - $1.time) }.max() ?? 0
        #expect(worst > 0.1, "a metronomic render should be visibly wrong on this grid (was \(worst) s)")
    }

    @Test("steps between beats interpolate inside the beat they fall in")
    func stepsInterpolate() {
        let steps = Array(repeating: VelocityTier.normal, count: 16)
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .closedHat, steps: steps),
        ])
        let hits = GrooveRenderer.render(groove, on: .grid(Self.unevenGrid))

        // Beat 0 spans 0 → 0.7, so its four sixteenths are 0.175 apart.
        #expect(abs(hits[1].time - 0.175) < 1e-12)
        #expect(abs(hits[2].time - 0.350) < 1e-12)
        #expect(abs(hits[3].time - 0.525) < 1e-12)
        // Beat 3 spans 2.1 → 2.5, so its sixteenths are 0.1 apart — a different step length in the
        // same bar, which a fixed tempo cannot express.
        #expect(abs(hits[12].time - 2.1) < 1e-12)
        #expect(abs(hits[13].time - 2.2) < 1e-12)
    }

    @Test("swing is measured against the local step length, not an average one")
    func swingUsesLocalStepLength() {
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: Swing(percent: 62).factor, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 16)),
        ])
        let hits = GrooveRenderer.render(groove, on: .grid(Self.unevenGrid))

        // Beat 0 is 0.7 s long → sixteenth 0.175 s; beat 3 is 0.4 s → sixteenth 0.1 s.
        let shiftEarly = hits[1].time - 0.175
        let shiftLate = hits[13].time - 2.2
        #expect(abs(shiftEarly - (2 * 0.175 * 0.62 - 0.175)) < 1e-12)
        #expect(abs(shiftLate - (2 * 0.1 * 0.62 - 0.1)) < 1e-12)
        #expect(shiftEarly > shiftLate, "a longer beat swings by more real time")
    }

    @Test("a groove can start at a bar of the grid")
    func startingAtABar() {
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: (0..<16).map { $0 == 0 ? .accent : .rest }),
        ])
        let timeline = GrooveTimeline.grid(Self.unevenGrid, bar: 1)
        let hits = GrooveRenderer.render(groove, on: timeline)
        #expect(abs(hits[0].time - Self.unevenBeats[4]) < 1e-12)
    }

    @Test("past the end of a grid the last interval carries on")
    func extrapolatesPastTheGrid() {
        let timeline = GrooveTimeline.grid(Self.unevenGrid)
        let lastInterval = Self.unevenBeats[7] - Self.unevenBeats[6]  // 0.9
        #expect(abs(timeline.time(atBeat: 8) - (4.8 + lastInterval)) < 1e-12)
        #expect(abs(timeline.time(atBeat: 10) - (4.8 + 3 * lastInterval)) < 1e-12)
    }

    @Test("beat and time are inverses on both clocks")
    func beatTimeRoundTrip() {
        for timeline in [GrooveTimeline.tempo(97.3), GrooveTimeline.grid(Self.unevenGrid)] {
            for beat in stride(from: 0.0, through: 7.0, by: 0.125) {
                let seconds = timeline.time(atBeat: beat)
                #expect(abs(timeline.beat(atTime: seconds) - beat) < 1e-9,
                        "round trip failed at beat \(beat)")
            }
        }
    }

    @Test("a fixed-tempo timeline is a metronome")
    func fixedTempoIsMetronomic() {
        let timeline = GrooveTimeline.tempo(128, timeSignature: .fourFour, startingAt: 2.5)
        #expect(abs(timeline.time(atBeat: 0) - 2.5) < 1e-12)
        #expect(abs(timeline.time(atBeat: 4) - (2.5 + 4 * 60.0 / 128)) < 1e-12)
        #expect(abs(timeline.beatDuration(atBeat: 3.7) - 60.0 / 128) < 1e-12)
        #expect(abs(timeline.stepDuration(ofStep: 5, stepsPerBar: 16) - 60.0 / 128 / 4) < 1e-12)
    }

    @Test("a 3/4 grid reads three beats to the bar")
    func threeFourOnAGrid() {
        let beats = (0..<9).map { Double($0) * 0.5 }
        let grid = BeatGrid(beats: beats, bars: [0, 1.5, 3.0], bpm: 120, timeSignature: .threeFour)
        let timeline = GrooveTimeline.grid(grid)
        #expect(timeline.beatsPerBar == 3)
        // Twelve steps to a 3/4 bar is four per beat, so step 12 is the second bar.
        #expect(abs(timeline.time(ofStep: 12, stepsPerBar: 12) - 1.5) < 1e-12)
    }
}
