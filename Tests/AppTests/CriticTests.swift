import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Every critic gets two tests: a case that has to trigger it, and a case that must not.
//
// The second is the one that matters. A critic that fires on everything is noise, and noise on a
// surface that interrupts you is worse than no critic at all — so for each check there is a piece of
// material that is deliberately close to the line and deliberately on the right side of it.
//
// All of it runs on values: a `Chop` off this app's own chopper, a `SlicePlacement` off its own
// re-groover, and a `DegradeSettings` off its own presets. No engine, no device, no model.

// MARK: - Fixtures

private enum CriticFixtures {

    static let rate = ChopLaneFixtures.sampleRate

    /// A slice, hand-built, so a test can put a cut exactly where it wants one.
    static func slice(_ index: Int, start: Double, end: Double, origin: SliceOrigin = .onset,
                      peak: Float = 0.5, snapOffset: Double = 0) -> Slice {
        Slice(index: index,
              start: Int(start * rate), end: Int(end * rate), sampleRate: rate,
              origin: origin, peak: peak, rms: peak * 0.4, snapOffset: snapOffset)
    }

    static func chop(_ slices: [Slice], tempo: Double? = 90) -> Chop {
        Chop(slices: slices, sampleRate: rate,
             sourceFrameCount: slices.map(\.end).max() ?? 0,
             detectedTempo: tempo)
    }

    static func classification(_ index: Int, _ kind: SliceClass, centroid: Double,
                               peak: Float) -> SliceClassification {
        SliceClassification(sliceIndex: index, kind: kind, centroid: centroid,
                            duration: 0.16, effectiveDuration: 0.1, peak: peak, rms: peak * 0.4,
                            confidence: 0.7)
    }

    /// A real chop of the fixture bar, off the real chopper.
    static func realChop(snapping: Bool = true) -> (Chop, [Float], [SliceClassification], [Double]) {
        let signal = ChopLaneFixtures.cleanBar()
        let chopper = Chopper()
        let onsets = chopper.detector.onsets(in: signal, sampleRate: rate)
        let chop = chopper.slice(atOnsets: onsets, signal: signal, sampleRate: rate,
                                 snappingTo: snapping ? ChopLaneFixtures.grid : nil,
                                 division: 4, detectedTempo: ChopLaneFixtures.bpm)
        return (chop, signal, SliceClassifier().classify(chop, in: signal), onsets)
    }

    static func placement(_ index: Int, voice: DrumVoice, bar: Int = 0, step: Int,
                          time: Double, velocity: Int = 100,
                          available: Double, natural: Double) -> PlacedSlice {
        PlacedSlice(sliceIndex: index, voice: voice, bar: bar, step: step, time: time,
                    velocity: velocity, available: available, naturalDuration: natural)
    }

    /// A groove observation to hang a groove review on.
    static func observation(swing: Double = 50, tempo: Double = 90) -> GrooveObservation {
        GrooveObservation(label: "fixture",
                          groove: Groove(stepsPerBar: 16, bars: 1, swing: Swing(percent: swing).factor,
                                         patterns: [GroovePattern(voice: .snare,
                                                                  steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest })]),
                          options: GrooveRenderOptions(swing: Swing(percent: swing)),
                          tempo: tempo)
    }
}

// MARK: - The transient check

@Suite("Critic: a cut that shaves a transient")
struct CriticTransientTests {

    private let critic = TransientCutCritic()

    @Test("It fires on a marker snapped 9 ms past its transient")
    func triggers() throws {
        // The direction is what makes this a fault: the marker moved *later* than the onset, so the
        // attack's front is stranded on the previous pad.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.5, origin: .onset),
                      CriticFixtures.slice(1, start: 0.5, end: 1.0, origin: .snapped,
                                           snapOffset: 0.009)]
        let review = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices))
        let findings = critic.review(review)

        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.critic == .transientCut)
        #expect(finding.persona == .sampler)
        #expect(finding.subject == .slice(1))
        #expect(finding.severity == .warn)
        #expect(finding.headline.contains("9.0 ms"))
        // A finding names the slice, says why in one sentence, and offers exactly two fixes.
        #expect(finding.fixes.count == 2)
        #expect(finding.why.split(separator: ".").count == 1)
        #expect(finding.measurement.trips)
        #expect(abs(finding.measurement.measured - 9) < 0.001)
        // The first fix undoes this cut; the second fixes the cause for the whole chop.
        #expect(finding.fixes[0].change == .moveSliceStart(slice: 1, by: -0.009))
        #expect(finding.fixes[1].change == .setSnapTolerance(0))
        // And it can be heard: the locus spans the shave.
        #expect(finding.locus.duration > 0)
    }

    @Test("It does not fire on a marker snapped 9 ms EARLIER than its transient")
    func doesNotTriggerOnAnEarlyCut() {
        // The same magnitude, the other direction. An early cut picks up a fraction of the previous
        // hit's tail and keeps the whole attack, which is why `Chopper` only searches backwards —
        // a critic that fired on this would be arguing with the engine's own design.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.5, origin: .onset),
                      CriticFixtures.slice(1, start: 0.5, end: 1.0, origin: .snapped,
                                           snapOffset: -0.009)]
        let findings = critic.review(ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices)))
        #expect(findings.isEmpty)
    }

    @Test("It does not fire inside the declick's own working range")
    func doesNotTriggerUnderTwoMilliseconds() {
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.5, origin: .snapped, snapOffset: 0.0015)]
        #expect(critic.review(ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices))).isEmpty)
    }

    @Test("Working from onsets rather than snap offsets finds the same thing")
    func fallsBackToOnsets() throws {
        // No snap offsets at all — a hand-placed marker, or a chop reloaded from a version. The
        // transient is at 0.500 and the cut is at 0.512.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.5, origin: .onset),
                      CriticFixtures.slice(1, start: 0.512, end: 1.0, origin: .onset)]
        let review = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                                detectedOnsets: [0, 0.5])
        let findings = critic.review(review)
        let finding = try #require(findings.first)
        #expect(abs(finding.measurement.measured - 12) < 0.5)
    }

    @Test("A real chop off this app's own chopper is clean")
    func theRealChopperIsClean() {
        // The bar the fixtures cut is played to the grid, so nothing should have had to move far
        // enough to shave an attack. This is the regression guard: a change to `Chopper` that
        // started snapping markers past their transients would fail here.
        let (chop, signal, classifications, onsets) = CriticFixtures.realChop()
        let review = ChopReview(label: "Bar 1", chop: chop, classifications: classifications,
                                signal: signal, detectedOnsets: onsets)
        let findings = critic.review(review)
        for finding in findings {
            Issue.record("the fixture bar produced \(finding.headline)")
        }
        #expect(findings.isEmpty)
    }
}

// MARK: - The level check

@Suite("Critic: levels that will not survive the mix")
struct CriticLevelTests {

    private let critic = SliceLevelCritic()

    @Test("It fires when one class spans more than the velocity map's own range")
    func triggersOnSpread() throws {
        // Two snares 20 dB apart, played through `.wide`, whose own range is 14.5 dB. The rotation
        // will alternate them and the feel's tiers stop meaning anything.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.2, peak: 0.9),
                      CriticFixtures.slice(1, start: 0.2, end: 0.4, peak: 0.09)]
        let classifications = [CriticFixtures.classification(0, .snare, centroid: 2800, peak: 0.9),
                               CriticFixtures.classification(1, .snare, centroid: 2900, peak: 0.09)]
        let review = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                                classifications: classifications, velocities: .wide)
        let findings = critic.review(review).filter { $0.measurement.feature == .sliceSpreadDB }

        let finding = try #require(findings.first)
        #expect(finding.persona == .sampler)
        #expect(finding.fixes.count == 2)
        #expect(finding.headline.contains("snare"))
        #expect(finding.measurement.measured > SliceLevelCritic.dynamicRangeDB(.wide))
        // The threshold is derived from the map rather than typed in.
        #expect(abs(SliceLevelCritic.dynamicRangeDB(.wide) - 20 * log10(127.0 / 24.0)) < 0.001)
    }

    @Test("It does not fire on a spread the velocity map can still reorder")
    func doesNotTriggerInsideTheRange() {
        // 6 dB apart, well inside `.wide`'s 14.5 dB — a break with a hard snare and a softer one is
        // the normal case and is not a finding.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.2, peak: 0.8),
                      CriticFixtures.slice(1, start: 0.2, end: 0.4, peak: 0.4)]
        let classifications = [CriticFixtures.classification(0, .snare, centroid: 2800, peak: 0.8),
                               CriticFixtures.classification(1, .snare, centroid: 2900, peak: 0.4)]
        let review = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                                classifications: classifications, velocities: .wide)
        #expect(critic.review(review).isEmpty)
    }

    @Test("It fires on a slice clipping into the chain's drive, and not on the same slice dry")
    func triggersOnClipping() throws {
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.2, peak: 0.999)]
        let hot = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                             classifications: [CriticFixtures.classification(0, .kick,
                                                                            centroid: 120, peak: 0.999)],
                             degrade: DegradeSettings(preset: .sp1200))
        let findings = critic.review(hot)
        let finding = try #require(findings.first)
        #expect(finding.headline.contains("drive"))
        if case .setSliceGain(let slice, let dB) = finding.fixes[0].change {
            #expect(slice == 0)
            // Trims to below the ceiling: the slice's own peak plus the preset's 1.40 of drive.
            #expect(dB < -(20 * log10(1.40)))
        } else {
            Issue.record("the first fix should trim the slice, not \(finding.fixes[0].change)")
        }
        #expect(finding.fixes[1].change == .setDegradeMix(0))

        // Same slice with no chain over it: nothing to clip into.
        let dry = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                             classifications: [CriticFixtures.classification(0, .kick,
                                                                            centroid: 120, peak: 0.999)])
        #expect(critic.review(dry).isEmpty)
    }

    @Test("It fires on a slice inside the source's own noise floor")
    func triggersOnTheFloor() throws {
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.2, peak: 0.8),
                      CriticFixtures.slice(1, start: 0.2, end: 0.4, peak: 0.0015)]
        let classifications = [CriticFixtures.classification(0, .kick, centroid: 120, peak: 0.8),
                               CriticFixtures.classification(1, .hat, centroid: 9000, peak: 0.0015)]
        // −56 dBFS floor; slice 1 peaks at about −56.5, which is under it.
        let review = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                                classifications: classifications,
                                observation: SourceObservation(label: "Bar 1",
                                                               chop: CriticFixtures.chop(slices),
                                                               classifications: classifications,
                                                               noiseFloorDB: -56))
        let findings = critic.review(review).filter { $0.headline.contains("noise floor") }
        let finding = try #require(findings.first)
        #expect(finding.subject == .slice(1))
        #expect(finding.fixes.count == 2)

        // With a quieter floor the same slice is a real, if soft, hit.
        let quiet = ChopReview(label: "Bar 1", chop: CriticFixtures.chop(slices),
                               classifications: classifications,
                               observation: SourceObservation(label: "Bar 1",
                                                              chop: CriticFixtures.chop(slices),
                                                              classifications: classifications,
                                                              noiseFloorDB: -90))
        #expect(critic.review(quiet).filter { $0.headline.contains("noise floor") }.isEmpty)
    }
}

// MARK: - The chain check

@Suite("Critic: a chain with nothing left to take")
struct CriticChainTests {

    private let critic = DegradeStackCritic()

    private func review(bandwidth: Double?, degrade: DegradeSettings?,
                        prior: [String] = []) -> ChopReview {
        let chop = CriticFixtures.chop([CriticFixtures.slice(0, start: 0, end: 1)])
        return ChopReview(label: "Break", chop: chop, degrade: degrade,
                          observation: SourceObservation(label: "Break", chop: chop,
                                                         bandwidthHz: bandwidth,
                                                         degrade: degrade,
                                                         priorDegrades: prior))
    }

    @Test("It fires when the chain's corner is above the source's own rolloff")
    func triggersOnADeadCorner() throws {
        // Cassette's corner is 14 kHz; this source stops at 9.
        let findings = critic.review(review(bandwidth: 9_000,
                                            degrade: DegradeSettings(preset: .cassette)))
        let finding = try #require(findings.first)
        #expect(finding.subject == .source)
        #expect(finding.severity == .note)   // worth knowing, not a mistake
        #expect(finding.headline.contains("14000"))
        #expect(finding.fixes.count == 2)
        #expect(finding.fixes[0].change == .setDegradePreset(nil))
    }

    @Test("It does not fire on a source with a top end left")
    func doesNotTriggerOnABrightSource() {
        #expect(critic.review(review(bandwidth: 18_000,
                                     degrade: DegradeSettings(preset: .cassette))).isEmpty)
        // Nor with no chain at all.
        #expect(critic.review(review(bandwidth: 9_000, degrade: nil)).isEmpty)
        // Nor on the clean preset, which is bypass.
        #expect(critic.review(review(bandwidth: 9_000,
                                     degrade: DegradeSettings(preset: .clean))).isEmpty)
    }

    @Test("It fires on a second quantiser over a source that already has one")
    func triggersOnStacking() throws {
        let findings = critic.review(review(bandwidth: 20_000,
                                            degrade: DegradeSettings(preset: .sp1200),
                                            prior: ["mpc60"]))
        let finding = try #require(findings.first { $0.measurement.feature == .bitDepth })
        #expect(finding.severity == .warn)
        #expect(finding.why.contains("12-bit"))
        #expect(finding.fixes.count == 2)
    }

    @Test("It does not fire when the second pass has no quantiser in it")
    func doesNotTriggerOnANonLossySecondPass() {
        // The cassette preset is transport and magnetics — no converter. Stacking that over an
        // SP-1200 source is exactly the fix the stacking finding recommends, so it must not itself
        // be a finding.
        let findings = critic.review(review(bandwidth: 20_000,
                                            degrade: DegradeSettings(preset: .cassette),
                                            prior: ["sp1200"]))
        #expect(findings.filter { $0.measurement.feature == .bitDepth }.isEmpty)
    }
}

// MARK: - The swing check

@Suite("Critic: a re-groove that fights the source's own swing")
struct CriticSwingTests {

    private let critic = SwingClashCritic()

    @Test("SourceSwing reads a swung source back as the percentage that made it")
    func measuringSwing() {
        // Onsets laid down at exactly 62% of each eighth-note pair, on a 90 BPM grid.
        let grid = BeatGrid.regular(bpm: 90, timeSignature: .fourFour, bars: 2)
        let beat = 60.0 / 90.0
        var onsets: [Double] = []
        for index in 0..<8 {
            let beatStart = grid.beats[index]
            for pair in [0.0, 0.5] {
                onsets.append(beatStart + (pair + 0.62 * 0.5) * beat)
            }
        }
        let estimate = SourceSwing.estimate(onsets: onsets, grid: grid)
        #expect(estimate.isUsable)
        #expect(abs(estimate.percent - 62) < 0.5)

        // A straight source reads as straight — 50% is outside the candidate window, so a straight
        // source simply produces no candidates rather than a wrong answer.
        let straight = (0..<16).map { grid.beats[$0 / 2] + Double($0 % 2) * beat * 0.5 }
        #expect(!SourceSwing.estimate(onsets: straight, grid: grid).isUsable)
    }

    @Test("It fires when the groove swings a source that is already swung")
    func triggers() throws {
        // Source at 54%, groove at 66.67% — 42 ms against 13 ms at 90 BPM, a 29 ms disagreement.
        let review = GrooveReview(label: "Bar 1",
                                  observation: CriticFixtures.observation(swing: Swing.tripletPercent),
                                  sourceSwingPercent: 54, sourceSwingSupport: 12)
        let finding = try #require(critic.review(review).first)
        #expect(finding.persona == .beatmaker)
        #expect(finding.headline.contains("further"))
        #expect(finding.fixes.count == 2)
        #expect(finding.fixes[0].change == .setSwing(percent: 54))
        #expect(finding.fixes[1].change == .setSwing(percent: Swing.minimumPercent))
        #expect(finding.measurement.trips)
    }

    @Test("It fires the other way too, when the grid flattens a swung source")
    func triggersOnFlattening() throws {
        let review = GrooveReview(label: "Bar 1",
                                  observation: CriticFixtures.observation(swing: 50),
                                  sourceSwingPercent: 62, sourceSwingSupport: 14)
        let finding = try #require(critic.review(review).first)
        #expect(finding.headline.contains("straightens"))
        // And the second fix is a different kind of answer: re-cut rather than re-swing.
        #expect(finding.fixes[1].change == .setSnapTolerance(0))
    }

    @Test("It does not fire inside the perceptual threshold")
    func doesNotTriggerUnderTenMilliseconds() {
        // 56% against 54% at 90 BPM is 6.7 ms — under Frane's 10 ms detection threshold.
        let close = GrooveReview(label: "Bar 1",
                                 observation: CriticFixtures.observation(swing: 56),
                                 sourceSwingPercent: 54, sourceSwingSupport: 12)
        #expect(critic.review(close).isEmpty)
        // The same percentage gap at a faster tempo is smaller still, which is the whole reason the
        // threshold is in milliseconds.
        let fast = GrooveReview(label: "Bar 1",
                                observation: CriticFixtures.observation(swing: 56, tempo: 140),
                                sourceSwingPercent: 54, sourceSwingSupport: 12)
        #expect(critic.review(fast).isEmpty)
    }

    @Test("It says nothing when the estimate rests on too few onsets")
    func doesNotTriggerWithoutSupport() {
        let thin = GrooveReview(label: "Bar 1",
                                observation: CriticFixtures.observation(swing: Swing.tripletPercent),
                                sourceSwingPercent: 54, sourceSwingSupport: 3)
        #expect(critic.review(thin).isEmpty)
        // And nothing at all when nobody measured the source.
        let unmeasured = GrooveReview(label: "Bar 1",
                                      observation: CriticFixtures.observation(swing: Swing.tripletPercent))
        #expect(critic.review(unmeasured).isEmpty)
    }
}

// MARK: - The clash check

@Suite("Critic: slices that clash")
struct CriticClashTests {

    private let critic = SliceClashCritic()

    @Test("It fires on a slice ringing twice past the room the feel gives it")
    func triggersOnAnOverrun() throws {
        let placements = [
            CriticFixtures.placement(0, voice: .kick, step: 0, time: 0,
                                     available: 0.2, natural: 0.55),
        ]
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: placements)
        let finding = try #require(critic.review(review).first)
        #expect(finding.persona == .beatmaker)
        #expect(finding.headline.contains("2.8×") || finding.headline.contains("rings"))
        #expect(finding.fixes.count == 2)
        #expect(finding.fixes[0].change == .setOverlap(Regroove.Overlap.stretchToFit.rawValue))
        // It names the bar and the step, not just the slice.
        #expect(finding.subject == .step(bar: 0, step: 0, voice: "kick"))
        #expect(finding.locus.bar == 0)
    }

    @Test("It does not fire on the thickness a ringing pad is supposed to have")
    func doesNotTriggerOnOrdinaryRing() {
        // Half again as long as its room. An MPC lets this ring and that ring is the sound; a critic
        // that flagged it would be flagging the idiom.
        let placements = [
            CriticFixtures.placement(0, voice: .kick, step: 0, time: 0,
                                     available: 0.2, natural: 0.3),
        ]
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: placements)
        #expect(critic.review(review).isEmpty)
    }

    @Test("It does not fire on a slice that was stretched to fit")
    func doesNotTriggerOnAStretchedSlice() {
        var placement = CriticFixtures.placement(0, voice: .kick, step: 0, time: 0,
                                                 available: 0.2, natural: 0.55)
        placement.stretchRatio = 0.36
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: [placement])
        #expect(critic.review(review).isEmpty)
    }

    @Test("It fires on two hits of the same drum inside the flam window")
    func triggersOnAFlam() throws {
        let placements = [
            CriticFixtures.placement(0, voice: .snare, step: 4, time: 0.500,
                                     available: 0.4, natural: 0.15),
            CriticFixtures.placement(1, voice: .clap, step: 4, time: 0.512,
                                     available: 0.4, natural: 0.15),
        ]
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: placements,
                                  sliceCentroid: [0: 2800, 1: 2900])
        let finding = try #require(critic.review(review).first { $0.headline.contains("apart") })
        #expect(finding.headline.contains("12 ms"))
        #expect(finding.fixes.count == 2)
        #expect(finding.fixes[0].change == .dropSlice(1))
    }

    @Test("It does not fire when the two hits are different drums")
    func doesNotTriggerOnTwoDifferentDrums() {
        // A kick and a hat 12 ms apart is a normal, deliberate thing — three octaves between the
        // centroids, so nobody hears it as one hit played badly.
        let placements = [
            CriticFixtures.placement(0, voice: .kick, step: 4, time: 0.500,
                                     available: 0.4, natural: 0.15),
            CriticFixtures.placement(1, voice: .closedHat, step: 4, time: 0.512,
                                     available: 0.4, natural: 0.05),
        ]
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: placements,
                                  sliceCentroid: [0: 120, 1: 9000])
        #expect(critic.review(review).isEmpty)
    }

    @Test("It does not fire on two ghost notes, which are a drag rather than a mistake")
    func doesNotTriggerOnGhosts() {
        let placements = [
            CriticFixtures.placement(0, voice: .snare, step: 4, time: 0.500,
                                     velocity: VelocityTier.ghost.velocity,
                                     available: 0.4, natural: 0.15),
            CriticFixtures.placement(1, voice: .rim, step: 4, time: 0.512,
                                     velocity: VelocityTier.ghost.velocity,
                                     available: 0.4, natural: 0.15),
        ]
        let review = GrooveReview(label: "Bar 1", observation: CriticFixtures.observation(),
                                  placements: placements,
                                  sliceCentroid: [0: 2800, 1: 2900])
        #expect(critic.review(review).isEmpty)
    }
}

// MARK: - The board, and the contract every finding keeps

@Suite("Critic: the board")
struct CriticBoardTests {

    @Test("The shipped board holds every critic, each owned by a persona and each saying what it checks")
    func theBoardIsComplete() {
        let board = CriticBoard.standard
        #expect(board.all.count == 12)
        #expect(Set(board.all.map(\.id)).count == 12)
        #expect(board.critic(.transientCut) != nil)
        #expect(board.critic(.swingClash) != nil)
        for critic in board.all {
            #expect(!critic.name.isEmpty)
            #expect(critic.checks.count > 30)
        }
    }

    @Test("Findings come back worst first, then earliest first")
    func orderIsStable() {
        let note = makeFinding(severity: .note, start: 0.1)
        let earlyWarn = makeFinding(severity: .warn, start: 0.5)
        let lateWarn = makeFinding(severity: .warn, start: 0.9)
        let ordered = CriticBoard.ordered([note, lateWarn, earlyWarn])
        #expect(ordered.map(\.locus.start) == [0.5, 0.9, 0.1])
    }

    @Test("Every finding a critic can make offers exactly two fixes and names its place")
    func everyFindingKeepsTheContract() {
        // Material chosen to trip several checks at once, so the contract is tested against real
        // findings rather than against hand-built ones.
        let slices = [CriticFixtures.slice(0, start: 0, end: 0.2, peak: 0.999),
                      CriticFixtures.slice(1, start: 0.2, end: 0.4, origin: .snapped,
                                           peak: 0.05, snapOffset: 0.011)]
        let classifications = [CriticFixtures.classification(0, .snare, centroid: 2800, peak: 0.999),
                               CriticFixtures.classification(1, .snare, centroid: 2900, peak: 0.05)]
        let chop = CriticFixtures.chop(slices)
        let review = ChopReview(label: "Bar 1", chop: chop, classifications: classifications,
                                degrade: DegradeSettings(preset: .sp1200), velocities: .wide,
                                observation: SourceObservation(label: "Bar 1", chop: chop,
                                                               classifications: classifications,
                                                               bandwidthHz: 9_000,
                                                               noiseFloorDB: -70,
                                                               degrade: DegradeSettings(preset: .sp1200),
                                                               priorDegrades: ["mpc60"]))
        let findings = CriticBoard.standard.review(review)
        #expect(findings.count >= 3)
        for finding in findings {
            #expect(finding.fixes.count == 2, "\(finding.critic) offered \(finding.fixes.count) fixes")
            #expect(Set(finding.fixes.map(\.id)).count == 2)
            #expect(!finding.headline.isEmpty)
            #expect(!finding.subject.named.isEmpty)
            // One sentence, which is the rule. Counted by sentence breaks rather than by full
            // stops, because a measurement in a reason carries decimal points.
            #expect(finding.why.hasSuffix("."), "\(finding.critic): the reason does not end")
            #expect(!finding.why.contains(". "),
                    "\(finding.critic): \"\(finding.why)\" is more than one sentence")
            // Every fix says what it costs.
            for fix in finding.fixes {
                #expect(!fix.title.isEmpty)
                #expect(fix.detail.count > 30, "\(fix.id) does not say what it costs")
            }
            // And it can become a mark on the Chop lane without anything else being built.
            #expect(finding.mark.summary == finding.headline)
        }
    }

    @Test("A critic is a pure function: the same review twice gives the same findings")
    func criticsArePure() {
        let (chop, signal, classifications, onsets) = CriticFixtures.realChop()
        let review = ChopReview(label: "Bar 1", chop: chop, classifications: classifications,
                                signal: signal, detectedOnsets: onsets,
                                degrade: DegradeSettings(preset: .vinyl))
        let first = CriticBoard.standard.review(review)
        let second = CriticBoard.standard.review(review)
        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { $0.headline == $1.headline })
        #expect(zip(first, second).allSatisfy { $0.measurement == $1.measurement })
    }

    private func makeFinding(severity: Finding.Severity, start: Double) -> Finding {
        Finding(critic: .sliceLevel, criticName: "Level check", persona: .sampler,
                subject: .source, locus: Locus(start: start, end: start + 0.1),
                headline: "h", why: "w.", severity: severity,
                measurement: Measurement(.sliceFloorDB, measured: 0,
                                         threshold: .atMost(.sliceFloorDB, -1, unit: "dB"),
                                         unit: "dB"),
                first: Fix("a", title: "a", detail: "a", change: .accept),
                second: Fix("b", title: "b", detail: "b", change: .accept))
    }
}

// MARK: - The merge critics

@Suite("Critics: the merge")
struct MergeCriticTests {

    private func review(_ semitones: Int, drums: [Bool] = [true, false], uncleared: [Bool] = [false, false]) -> MergeReview {
        MergeReview(label: "Horns + Bass line", fragments: [
            MergeReview.Fragment(label: "Horns", semitones: semitones, isSample: true, isDrums: drums[0], source: "Vessel – Arrival", uncleared: uncleared[0]),
            MergeReview.Fragment(label: "Bass line", semitones: -5, isSample: false, isDrums: drums[1], source: nil, uncleared: uncleared[1]),
        ], seconds: 10.4)
    }

    @Test("It fires on a sample moved past four semitones, offers the sample's own key first, and not on a written part")
    func tooFar() {
        let findings = TooFarTransposedCritic().review(review(-5))
        #expect(findings.count == 1)
        let finding = try! #require(findings.first)
        #expect(finding.critic == .tooFarTransposed)
        #expect(finding.persona == .sampler)
        #expect(finding.headline == "Horns moves 5 semitones down")
        #expect(finding.severity == .note, "five is flagged, not warned")
        #expect(finding.measurement.trips)
        #expect(finding.fixes[0].title.contains("own key"))
        if case .setTranspose(let label, let semitones) = finding.fixes[0].change { #expect(label == "Horns" && semitones == 0) } else { Issue.record("wrong fix") }
        #expect(finding.fixes[1].change == .accept)
        #expect(finding.locus.end == 10.4)
        #expect(TooFarTransposedCritic().review(review(9)).first?.severity == .warn, "past seven it warns")
        #expect(TooFarTransposedCritic().review(review(4)).isEmpty)
        #expect(TooFarTransposedCritic().review(review(-3)).isEmpty)
    }

    @Test("It fires on two fragments with drums and names both; one is fine")
    func twoDrums() {
        let findings = TwoDrumSourcesCritic().review(review(0, drums: [true, true]))
        #expect(findings.count == 1)
        #expect(findings[0].critic == .twoDrumSources)
        #expect(findings[0].headline == "Horns and Bass line both carry drums")
        #expect(findings[0].measurement.measured == 2)
        if case .dropFragment(let label) = findings[0].fixes[0].change { #expect(label == "Bass line") } else { Issue.record("wrong fix") }
        #expect(TwoDrumSourcesCritic().review(review(0)).isEmpty)
        let board = CriticBoard.standard.review(review(6, drums: [true, true]))
        #expect(board.count == 2)
        #expect(board.map(\.critic).contains(.tooFarTransposed) && board.map(\.critic).contains(.twoDrumSources))
        #expect(CriticBoard.standard.all.count == 12)
        #expect(review(0, uncleared: [true, false]).uncleared == ["Vessel – Arrival"])
    }
}
