import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

@Suite("Groove renderer")
struct GrooveRendererTests {

    /// Kick on every beat, snare on 2 and 4, hats on every sixteenth — one bar, nothing clever.
    static func basicGroove(swing: Double = 0) -> Groove {
        Groove(stepsPerBar: 16, bars: 1, swing: swing, patterns: [
            GroovePattern(voice: .closedHat, steps: (0..<16).map { $0 % 4 == 0 ? .accent : .normal }),
            GroovePattern(voice: .snare, steps: (0..<16).map { $0 == 4 || $0 == 12 ? .accent : .rest }),
            GroovePattern(voice: .kick, steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest }),
        ])
    }

    // MARK: Velocity tiers

    @Test("velocity tiers map to their configured velocities")
    func velocityTiers() {
        let groove = Groove(stepsPerBar: 4, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .snare, steps: [.accent, .normal, .ghost, .rest]),
        ])

        let standard = GrooveRenderer.render(groove, on: .tempo(120))
        #expect(standard.map(\.velocity) == [120, 90, 40])
        #expect(standard.count == 3, "a rest must not produce a hit")

        let custom = VelocityMap(ghost: 22, normal: 77, accent: 111)
        let mapped = GrooveRenderer.render(groove, on: .tempo(120),
                                           options: GrooveRenderOptions(velocities: custom))
        #expect(mapped.map(\.velocity) == [111, 77, 22])

        // The tier vocabulary's own figures are the default, so a groove means something with no map.
        #expect(VelocityMap.standard.velocity(for: .accent) == VelocityTier.accent.velocity)
        #expect(VelocityMap.standard.velocity(for: .normal) == VelocityTier.normal.velocity)
        #expect(VelocityMap.standard.velocity(for: .ghost) == VelocityTier.ghost.velocity)
        #expect(VelocityMap.standard.velocity(for: .rest) == 0)
    }

    @Test("a voice's velocity scale applies before humanizing and clamps to MIDI")
    func voiceVelocityScale() {
        let groove = Groove(stepsPerBar: 4, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .snare, steps: [.accent, .ghost, .rest, .rest]),
        ])
        let options = GrooveRenderOptions(voices: [.snare: VoiceFeel(velocityScale: 0.5)])
        let hits = GrooveRenderer.render(groove, on: .tempo(120), options: options)
        #expect(hits.map(\.velocity) == [60, 20])

        let loud = GrooveRenderOptions(voices: [.snare: VoiceFeel(velocityScale: 4)])
        let clipped = GrooveRenderer.render(groove, on: .tempo(120), options: loud)
        #expect(clipped.allSatisfy { $0.velocity <= 127 })
        #expect(clipped[0].velocity == 127)
    }

    // MARK: Humanize

    @Test("humanize is seeded: two renders are identical")
    func humanizeIsReproducible() {
        let groove = Self.basicGroove(swing: Swing(percent: 58).factor)
        let options = GrooveRenderOptions(humanize: Humanize(velocity: 0.22, timing: 0.12, seed: 0xDECAFBAD),
                                          repeats: 4)
        let first = GrooveRenderer.render(groove, on: .tempo(93), options: options)
        let second = GrooveRenderer.render(groove, on: .tempo(93), options: options)

        #expect(!first.isEmpty)
        #expect(first == second, "same seed, same render — a bounce must be bit-identical")
        // `Hit` is Hashable on every field, but be explicit about the two that matter.
        for (a, b) in zip(first, second) {
            #expect(a.time.bitPattern == b.time.bitPattern)
            #expect(a.velocity == b.velocity)
        }

        // And it is actually doing something.
        let straight = GrooveRenderer.render(groove, on: .tempo(93),
                                             options: GrooveRenderOptions(repeats: 4))
        #expect(first != straight)
    }

    @Test("a different seed gives a different performance")
    func seedChangesPerformance() {
        let groove = Self.basicGroove()
        let a = GrooveRenderer.render(groove, on: .tempo(90),
                                      options: GrooveRenderOptions(humanize: Humanize(velocity: 0.2, timing: 0.1, seed: 1)))
        let b = GrooveRenderer.render(groove, on: .tempo(90),
                                      options: GrooveRenderOptions(humanize: Humanize(velocity: 0.2, timing: 0.1, seed: 2)))
        #expect(a != b)
        #expect(a.count == b.count)
    }

    /// Jitter is addressed by step, not drawn from a stream, so rendering in chunks must equal
    /// rendering in one pass — the property that lets the player schedule with look-ahead.
    @Test("jitter does not depend on how many hits came before it")
    func jitterIsAddressed() {
        let groove = Self.basicGroove()
        let humanize = Humanize(velocity: 0.2, timing: 0.1, seed: 0xA11CE)
        let whole = GrooveRenderer.render(groove, on: .tempo(96),
                                          options: GrooveRenderOptions(humanize: humanize, repeats: 1))

        // The same bar rendered with a voice removed: the remaining voices must be untouched.
        var thinner = groove
        thinner.patterns.removeAll { $0.voice == .closedHat }
        let partial = GrooveRenderer.render(thinner, on: .tempo(96),
                                            options: GrooveRenderOptions(humanize: humanize, repeats: 1))
        let wholeKicks = whole.filter { $0.voice == .kick }
        let partialKicks = partial.filter { $0.voice == .kick }
        #expect(wholeKicks == partialKicks)
    }

    @Test("humanize amounts stay inside their stated bounds")
    func humanizeBounds() {
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 16)),
        ])
        let amount = 0.18
        let humanize = Humanize(velocity: amount, timing: 0.1, onBeatScale: 0.3, seed: 7)
        let bpm = 90.0
        let sixteenth = 60.0 / bpm / 4
        let hits = GrooveRenderer.render(groove, on: .tempo(bpm),
                                         options: GrooveRenderOptions(humanize: humanize))
        for (step, hit) in hits.enumerated() {
            let scale = step % 4 == 0 ? 0.3 : 1.0
            let straight = Double(step) * sixteenth
            #expect(abs(hit.time - straight) <= 0.1 * scale * sixteenth + 1e-12)
            #expect(abs(Double(hit.velocity) - 90) <= amount * scale * 127 + 1)
        }
    }

    // MARK: Per-voice feel

    @Test("a voice can stay straight while the groove swings")
    func voiceCanStayStraight() {
        let bpm = 90.0
        let sixteenth = 60.0 / bpm / 4
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: Swing(percent: 66).factor, patterns: [
            GroovePattern(voice: .closedHat, steps: Array(repeating: .normal, count: 16)),
            GroovePattern(voice: .snare, steps: Array(repeating: .normal, count: 16)),
        ])
        let options = GrooveRenderOptions(voices: [.closedHat: VoiceFeel(swing: .straight)])
        let hits = GrooveRenderer.render(groove, on: .tempo(bpm), options: options)
        let hats = hits.filter { $0.voice == .closedHat }
        let snares = hits.filter { $0.voice == .snare }

        #expect(abs(hats[1].time - sixteenth) < 1e-12, "hats stay on the grid")
        let expectedSnare = sixteenth + (2 * sixteenth * 0.66 - sixteenth)
        #expect(abs(snares[1].time - expectedSnare) < 1e-12, "the snare is swung")
    }

    @Test("a voice's timing offset is a fraction of a step, so it scales with tempo")
    func voiceTimingOffsetScales() {
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .snare, steps: (0..<16).map { $0 == 4 ? .accent : .rest }),
        ])
        let options = GrooveRenderOptions(voices: [.snare: VoiceFeel(timingOffset: 0.1)])
        for bpm in [80.0, 120, 160] {
            let sixteenth = 60.0 / bpm / 4
            let hits = GrooveRenderer.render(groove, on: .tempo(bpm), options: options)
            #expect(abs(hits[0].time - (4 * sixteenth + 0.1 * sixteenth)) < 1e-12)
        }
    }

    // MARK: Repeats and ordering

    @Test("repeats lay the groove down end to end")
    func repeatsAreContiguous() {
        let groove = Self.basicGroove()
        let bpm = 100.0
        let bar = 60.0 / bpm * 4
        let hits = GrooveRenderer.render(groove, on: .tempo(bpm), options: GrooveRenderOptions(repeats: 3))
        let single = GrooveRenderer.render(groove, on: .tempo(bpm))
        #expect(hits.count == single.count * 3)
        #expect(hits.map(\.time) == hits.map(\.time).sorted())
        #expect(abs((hits.last!.time - single.last!.time) - 2 * bar) < 1e-9)
    }

    @Test("hits come out in a stable order at the same instant")
    func stableOrdering() {
        let groove = Groove(stepsPerBar: 4, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: [.normal, .rest, .rest, .rest]),
            GroovePattern(voice: .snare, steps: [.normal, .rest, .rest, .rest]),
            GroovePattern(voice: .clap, steps: [.normal, .rest, .rest, .rest]),
        ])
        for _ in 0..<8 {
            let hits = GrooveRenderer.render(groove, on: .tempo(120))
            #expect(hits.map { $0.voice?.rawValue } == ["kick", "snare", "clap"])
        }
    }
}
