import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

@Suite("Regroove")
struct RegrooveTests {
    static let sr: Double = 48_000

    /// Four slices: a kick, a snare, a hat and a mid sine that also reads as a kick — a plausible
    /// four-slice chop of a bar.
    static func fourSliceChop() -> (signal: [Float], map: ChopMap, classes: [SliceClassification]) {
        let sounds: [[Float]] = [
            ChopFixtures.kick(sr),
            ChopFixtures.snare(sr),
            ChopFixtures.hat(sr),
            ChopFixtures.decayingSine(sampleRate: sr, frequency: 320, duration: 0.25, decay: 12),
        ]
        let signal = ChopFixtures.place(sounds.enumerated().map { (Double($0.offset) * 0.5, $0.element) },
                                        length: 2, sampleRate: sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: sr, divisions: 4)
        return (signal, ChopMap.pads(chop, name: "Four"), SliceClassifier().classify(chop, in: signal))
    }

    /// The step times a 4/4 groove should land on, computed independently of `StepTimeline`.
    static func expectedTimes(bpm: Double, stepsPerBar: Int, swing: Double,
                              bars: Int) -> [Int: Double] {
        let beat = 60 / bpm
        let step = beat * 4 / Double(stepsPerBar)
        var times: [Int: Double] = [:]
        for absolute in 0..<(stepsPerBar * bars) {
            var t = Double(absolute) * step
            if absolute % 2 == 1 { t += swing * step / 3 }
            times[absolute] = t
        }
        return times
    }

    // MARK: Timing

    @Test("hits land on the feel's step times within a millisecond")
    func hitsLandOnTheFeelsSteps() throws {
        let (_, map, classes) = Self.fourSliceChop()
        let groove = ChopFixtures.boomBap(swing: 0.25)
        let grid = BeatGrid.regular(bpm: 84, bars: 4)
        let performance = try Regroove().perform(map, classifications: classes,
                                                 groove: groove, grid: grid)

        let expected = Self.expectedTimes(bpm: 84, stepsPerBar: 16, swing: 0.25, bars: 1)
        #expect(!performance.placements.isEmpty)
        for placement in performance.placements {
            let want = try #require(expected[placement.step])
            #expect(abs(placement.time - want) < 0.001,
                    "\(placement.voice) step \(placement.step) at \(placement.time) s, expected \(want) s")
        }
        // The hits carry the same times, because they are the same events.
        #expect(performance.hits.count == performance.placements.count)
        for (hit, placement) in zip(performance.hits, performance.placements) {
            #expect(abs(hit.time - placement.time) < 1e-9)
        }
        #expect(performance.unplacedSteps == 0)
    }

    @Test("every non-rest step of the feel gets a hit")
    func everyStepIsPlayed() throws {
        let (_, map, classes) = Self.fourSliceChop()
        let groove = ChopFixtures.boomBap(swing: 0)
        let expected = groove.patterns.reduce(0) { $0 + $1.steps.filter { $0 != .rest }.count }
        let performance = try Regroove().perform(map, classifications: classes, groove: groove,
                                                 grid: BeatGrid.regular(bpm: 90, bars: 4))

        #expect(performance.hits.count == expected)
    }

    @Test("swing moves the off-steps and leaves the on-steps alone")
    func swingMovesOffSteps() throws {
        let (_, map, classes) = Self.fourSliceChop()
        let grid = BeatGrid.regular(bpm: 90, bars: 2)
        let straight = try Regroove().perform(map, classifications: classes,
                                              groove: ChopFixtures.boomBap(swing: 0), grid: grid)
        let swung = try Regroove().perform(map, classifications: classes,
                                           groove: ChopFixtures.boomBap(swing: 1), grid: grid)
        let step = 60.0 / 90 / 4

        for (a, b) in zip(straight.placements, swung.placements) {
            #expect(a.step == b.step)
            if a.step % 2 == 0 {
                #expect(abs(a.time - b.time) < 1e-9)
            } else {
                #expect(abs((b.time - a.time) - step / 3) < 1e-6)
            }
        }
    }

    @Test("an uneven grid bends the feel with it")
    func unevenGridBendsTheFeel() throws {
        let (_, map, classes) = Self.fourSliceChop()
        // Beat 2 is late; every step inside beat 1 should stretch to match.
        let grid = BeatGrid(beats: [0, 0.8, 1.4, 2.0, 2.6], bars: [0], bpm: 100)
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: (0..<16).map { $0 % 4 == 0 ? .accent : .rest }),
        ])
        let performance = try Regroove().perform(map, classifications: classes, groove: groove,
                                                 grid: grid)

        #expect(performance.placements.map { ($0.time * 100).rounded() / 100 } == [0, 0.8, 1.4, 2.0])
    }

    // MARK: Mapping

    @Test("classification decides which slice plays which voice")
    func classificationDrivesPlacement() throws {
        let (_, map, classes) = Self.fourSliceChop()
        #expect(classes.map(\.kind) == [.kick, .snare, .hat, .kick])

        let performance = try Regroove().perform(map, classifications: classes,
                                                 groove: ChopFixtures.boomBap(),
                                                 grid: BeatGrid.regular(bpm: 90, bars: 2))
        for placement in performance.placements {
            switch placement.voice {
            case .kick: #expect([0, 3].contains(placement.sliceIndex))
            case .snare: #expect(placement.sliceIndex == 1)
            case .closedHat: #expect(placement.sliceIndex == 2)
            default: Issue.record("unexpected voice \(placement.voice)")
            }
        }
    }

    @Test("two slices of a class alternate rather than one being used twice")
    func rotationAlternates() throws {
        let (_, map, classes) = Self.fourSliceChop()
        let performance = try Regroove().perform(map, classifications: classes,
                                                 groove: ChopFixtures.boomBap(),
                                                 grid: BeatGrid.regular(bpm: 90, bars: 2))
        let kicks = performance.placements.filter { $0.voice == .kick }.map(\.sliceIndex)

        #expect(kicks.count >= 2)
        #expect(Set(kicks).count == 2, "both kick-like slices should get used, got \(kicks)")
    }

    @Test("turning rotation off plays the loudest slice of the class every time")
    func withoutRotation() throws {
        let (_, map, classes) = Self.fourSliceChop()
        var policy = Regroove.Policy()
        policy.rotate = false
        let performance = try Regroove(policy: policy).perform(
            map, classifications: classes, groove: ChopFixtures.boomBap(),
            grid: BeatGrid.regular(bpm: 90, bars: 2))
        let kicks = Set(performance.placements.filter { $0.voice == .kick }.map(\.sliceIndex))

        #expect(kicks.count == 1)
    }

    @Test("a policy override sends a slice somewhere else entirely")
    func policyOverride() throws {
        let (_, map, classes) = Self.fourSliceChop()
        var policy = Regroove.Policy()
        policy.overrides = [2: .kick]   // the hat is to be played as a kick
        let performance = try Regroove(policy: policy).perform(
            map, classifications: classes, groove: ChopFixtures.boomBap(),
            grid: BeatGrid.regular(bpm: 90, bars: 2))

        let kicks = Set(performance.placements.filter { $0.voice == .kick }.map(\.sliceIndex))
        #expect(kicks.contains(2))
        #expect(performance.classifications[2].isOverride)
        #expect(performance.classifications[2].kind == .kick)
        // Nothing reads as a hat any more, so the hat steps are filled by substitution rather than
        // going silent — and the performance says so.
        #expect(performance.substitutedClasses.contains(.hat))
    }

    @Test("a feel asking for a voice no slice can serve is counted, not faked")
    func unservableVoicesAreCounted() throws {
        let (_, map, classes) = Self.fourSliceChop()
        var policy = Regroove.Policy()
        policy.fallback = nil
        policy.voices = [.kick: [.kick], .snare: [.snare], .hat: [.closedHat]]
        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            GroovePattern(voice: DrumVoice("cowbell"), steps: (0..<16).map { $0 % 4 == 0 ? .accent : .rest }),
        ])
        let performance = try Regroove(policy: policy).perform(
            map, classifications: classes, groove: groove, grid: BeatGrid.regular(bpm: 90, bars: 2))

        #expect(performance.hits.isEmpty)
        #expect(performance.unplacedSteps == 4)
    }

    @Test("a chop with no hat in it still plays a feel full of hats")
    func substitutionFillsAnEmptyClass() throws {
        let sounds: [[Float]] = [ChopFixtures.kick(Self.sr), ChopFixtures.snare(Self.sr)]
        let signal = ChopFixtures.place(sounds.enumerated().map { (Double($0.offset) * 0.5, $0.element) },
                                        length: 1, sampleRate: Self.sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 2)
        let classes = SliceClassifier().classify(chop, in: signal)
        #expect(!classes.contains { $0.kind == .hat })

        let map = ChopMap.pads(chop, name: "No hat")
        let groove = ChopFixtures.boomBap(swing: 0)
        let filled = try Regroove().perform(map, classifications: classes, groove: groove,
                                            grid: BeatGrid.regular(bpm: 90, bars: 2))
        #expect(filled.substitutedClasses == [.hat])
        #expect(filled.unplacedSteps == 0)
        #expect(filled.placements.contains { $0.voice == .closedHat })
        // Both slices are close enough to be worth rotating, and the brightest one goes first.
        let hatSlices = filled.placements.filter { $0.voice == .closedHat }.map(\.sliceIndex)
        #expect(Set(hatSlices) == [0, 1])
        #expect(hatSlices.first == 1, "the brightest slice should lead the substituted rotation")

        var strict = Regroove.Policy()
        strict.substitute = false
        let silent = try Regroove(policy: strict).perform(map, classifications: classes,
                                                          groove: groove,
                                                          grid: BeatGrid.regular(bpm: 90, bars: 2))
        #expect(silent.substitutedClasses.isEmpty)
        #expect(silent.unplacedSteps == 16)
        #expect(!silent.placements.contains { $0.voice == .closedHat })
    }

    // MARK: Overrun

    @Test("ring lets a long slice play past its step; stretch makes it fit")
    func ringOrStretch() throws {
        let (signal, map, classes) = Self.fourSliceChop()
        // Half-second slices on a 16th grid at 90 bpm: every slice overruns its step.
        let grid = BeatGrid.regular(bpm: 90, bars: 2)
        let groove = ChopFixtures.boomBap(swing: 0)

        let ringing = try Regroove().perform(map, classifications: classes, groove: groove, grid: grid)
        #expect(ringing.placements.contains { $0.overruns })
        #expect(ringing.placements.allSatisfy { $0.stretchRatio == nil })
        #expect(ringing.map.mappings.count == map.mappings.count)

        var policy = Regroove.Policy()
        policy.overlap = .stretchToFit
        let fitted = try Regroove(policy: policy).perform(map, classifications: classes,
                                                          groove: groove, grid: grid)
        let stretched = fitted.placements.filter { $0.stretchRatio != nil }
        #expect(!stretched.isEmpty)
        for placement in stretched {
            let ratio = try #require(placement.stretchRatio)
            #expect(abs(ratio - placement.available / placement.naturalDuration) < 1e-5)
            #expect(ratio < 1, "fitting a long slice into a short step should shorten it")
        }
        // The stretched pads are new pads on the same map, and the map that comes back is the one
        // to render — the input map is untouched.
        #expect(fitted.map.mappings.count > map.mappings.count)
        #expect(fitted.map.sampleFileName == map.sampleFileName)

        // And the map it hands back really does render: one file, more zones.
        let cache = SliceStretch()
        let kit = try fitted.map.render(source: [signal], stretch: cache)
        #expect(kit.manifest.samplePaths.count == 1)
        #expect(kit.manifest.zones.count == fitted.map.mappings.count)
        #expect(cache.stretchCount <= stretched.count,
                "one stretch per distinct (slice, ratio), not one per hit")
    }

    // MARK: End to end

    @Test("the regrooved performance actually makes sound in the right places")
    func regroovedPerformanceRenders() throws {
        let (signal, map, classes) = Self.fourSliceChop()
        let grid = BeatGrid.regular(bpm: 90, bars: 2)
        let performance = try Regroove().perform(map, classifications: classes,
                                                 groove: ChopFixtures.boomBap(swing: 0), grid: grid)
        let kit = try performance.map.render(source: [signal])
        let rendered = try ChopRender.render(kit, hits: performance.hits,
                                             seconds: performance.duration + 0.5, sampleRate: Self.sr)

        #expect(ChopSignal.peak(rendered) > 0.1)
        // Something happens on the downbeat and on the backbeat, and the backbeat is the snare.
        let step = 60.0 / 90 / 4
        for placement in performance.placements where placement.voice == .snare {
            let frame = Int(placement.time * Self.sr)
            let window = frame..<min(rendered.count, frame + Int(0.05 * Self.sr))
            #expect(ChopSignal.rms(rendered[window]) > 0.01,
                    "nothing at the snare on step \(placement.step)")
        }
        // And nothing before the first hit.
        let firstFrame = Int((performance.placements.first?.time ?? 0) * Self.sr)
        if firstFrame > 32 { #expect(ChopSignal.peak(Array(rendered[0..<(firstFrame - 16)])) < 1e-6) }
        #expect(step > 0)
    }

    @Test("repeats lay the feel down back to back")
    func repeatsExtendTheFeel() throws {
        let (_, map, classes) = Self.fourSliceChop()
        let grid = BeatGrid.regular(bpm: 90, bars: 6)
        let one = try Regroove().perform(map, classifications: classes,
                                         groove: ChopFixtures.boomBap(swing: 0), grid: grid)
        let two = try Regroove().perform(map, classifications: classes,
                                         groove: ChopFixtures.boomBap(swing: 0), grid: grid, repeats: 2)

        #expect(two.hits.count == one.hits.count * 2)
        #expect(abs(two.duration - one.duration * 2) < 1e-6)
        let bar = 4 * 60.0 / 90
        #expect(abs((two.placements.last?.time ?? 0) - ((one.placements.last?.time ?? 0) + bar)) < 1e-6)
    }
}
