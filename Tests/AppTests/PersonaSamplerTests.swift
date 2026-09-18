import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The Sampler's golden tests. Same contract as the Beatmaker's: every golden the bible declares has
// a test here, and `goldensAreImplemented` fails when one does not.

private let sampler = Sampler()

@Suite("Persona: Sampler")
struct PersonaSamplerTests {

    // MARK: Goldens

    /// sampler.golden.late-cut
    @Test("A cut after its transient is refused; a cut before it is not")
    func lateCutIsRefused() {
        let late = sampler.consider(.moveCutLate(milliseconds: 9))
        #expect(late.refusedByRule == "sampler.cut-before-not-after")
        #expect(late.spoken.contains("attack"))
        if case .refuse(_, _, let counter) = late {
            // The counter moves it back rather than abandoning the slice.
            #expect(counter.contains("other way"))
        }

        // Under the limit it is agreed: the declick's own working range covers it.
        #expect(!sampler.consider(.moveCutLate(milliseconds: 1)).isRefusal)
        // And the limit is the engine's own number, not a new one.
        #expect(Sampler.shaveLimitMS == 2)
        #expect(TransientCutCritic().shaveLimit == Sampler.shaveLimitMS / 1000)
    }

    /// sampler.golden.bar-does-not-fit
    @Test("A bar at 90 BPM does not fit the machine, so the lineage chops inside it")
    func barDoesNotFit() {
        // The arithmetic the rule rests on: one bar of 4/4 against a 2.5 s sample slot.
        let barAtNinety = 4 * 60.0 / 90.0
        #expect(barAtNinety > Sampler.sp1200SampleSeconds)
        let barAtTheBoundary = 4 * 60.0 / Sampler.barFitsAboveBPM
        #expect(abs(barAtTheBoundary - Sampler.sp1200SampleSeconds) < 0.001)

        // And the reading says so out loud for a chop cut at that tempo.
        let observation = SourceObservation(label: "bar", sampleRate: 48_000, duration: barAtNinety,
                                            tempo: 90, sliceCount: 8)
        let fit = sampler.read(observation).first { $0.rule == "sampler.bar-does-not-fit" }
        #expect(fit?.holds == false)
        #expect(fit?.says.contains("2.67") == true)

        // Above 96 BPM the bar fits and the rule is quiet.
        let quick = SourceObservation(label: "bar", sampleRate: 48_000, duration: 4 * 60.0 / 110,
                                      tempo: 110, sliceCount: 8)
        #expect(sampler.read(quick).first { $0.rule == "sampler.bar-does-not-fit" }?.holds == true)
    }

    /// sampler.golden.corner-above-source
    @Test("A chain whose corner is above the source's own top end is refused")
    func cornerAboveTheSource() {
        // The cassette preset's corner is 14 kHz. A source that stops at 9 kHz has nothing above it.
        let cassette = DegradeSettings(preset: .cassette)
        #expect(cassette.highCut == 14_000)

        let verdict = sampler.consider(.applyDegrade(preset: "cassette",
                                                     sourceBandwidthHz: 9_000,
                                                     sourceNoiseFloorDB: -58))
        #expect(verdict.refusedByRule == "sampler.corner-above-the-source")
        #expect(verdict.spoken.contains("noise bed"))

        // A source with a top end left keeps the chain.
        let bright = sampler.consider(.applyDegrade(preset: "cassette",
                                                    sourceBandwidthHz: 18_000,
                                                    sourceNoiseFloorDB: -70))
        #expect(!bright.isRefusal)
        #expect(bright.spoken.contains("4000") || bright.spoken.contains("takes"))

        // The SP-1200 preset's corner is lower, so it still has work to do on the same dark source.
        #expect(DegradeSettings(preset: .sp1200).highCut == 12_000)
        #expect(!sampler.consider(.applyDegrade(preset: "sp1200",
                                                sourceBandwidthHz: 13_000,
                                                sourceNoiseFloorDB: -58)).isRefusal)
    }

    /// sampler.golden.no-stacking
    @Test("A second lossy chain over a source that already had one is refused")
    func noStacking() {
        let verdict = sampler.consider(.stackDegrade(first: "sp1200", second: "vinyl"))
        #expect(verdict.refusedByRule == "sampler.one-effect")
        #expect(verdict.spoken.contains("one effect at a time"))
        if case .refuse(_, _, let counter) = verdict {
            // The counter keeps one chain rather than abandoning both.
            #expect(counter.contains("third") || counter.contains("Pick"))
        }
    }

    /// sampler.golden.eight-pads
    @Test("Thirty-two slices is refused; eight is a bank; twelve is a caveat")
    func padCounts() {
        let tooMany = sampler.consider(.chopDensity(slicesPerBar: 32, sourceTransients: 40))
        #expect(tooMany.refusedByRule == "sampler.fewer-than-the-detector-wants")
        #expect(tooMany.spoken.contains("fourteen"))

        let bank = sampler.consider(.chopDensity(slicesPerBar: 8, sourceTransients: 12))
        #expect(bank.isAgreement)
        #expect(!bank.isRefusal)
        #expect(bank.spoken.contains("bank"))

        let between = sampler.consider(.chopDensity(slicesPerBar: 12, sourceTransients: 16))
        if case .agreeWithCaveat(_, let caveat) = between {
            #expect(caveat.contains("eight"))
        } else {
            Issue.record("twelve slices should carry a caveat about the bank, not \(between)")
        }

        // The thresholds are the documented figures rather than round numbers picked by eye.
        #expect(Sampler.sp303Pads == 8)
        #expect(Sampler.workableSlices == 16)
    }

    /// sampler.golden.leave-it-alone
    @Test("Leaving a source alone is a real answer, with what a chain would have changed")
    func leaveItAlone() {
        let verdict = sampler.consider(.leaveAlone(sourceBandwidthHz: 18_000))
        #expect(verdict.isAgreement)
        #expect(verdict.spoken.contains("18000") || verdict.spoken.contains("top end"))

        // And the clean chain is agreed rather than argued with.
        let clean = sampler.consider(.applyDegrade(preset: "clean",
                                                   sourceBandwidthHz: 18_000,
                                                   sourceNoiseFloorDB: -80))
        #expect(clean.isAgreement)
        #expect(!clean.isRefusal)
    }

    /// sampler.golden.pushes-back — the disagreement test.
    @Test("It pushes back on three chains at once instead of stacking them")
    func pushesBack() {
        let verdict = sampler.consider(.stackDegrade(first: "vinyl", second: "sp1200"))
        #expect(verdict.isRefusal, "the Sampler stacked two chains: \(verdict)")
        #expect(verdict.refusedByRule == "sampler.one-effect")

        guard case .refuse(_, let because, let counter) = verdict else {
            Issue.record("expected a refusal")
            return
        }
        // It refuses on the lineage's actual constraint, not on taste.
        #expect(because.contains("one effect at a time"))
        #expect(because.contains("lattice") || because.contains("quantiser"))
        // And offers a way to get what was actually wanted.
        #expect(counter.count > 60)

        // The rule behind it is the one the bible declares, and it is cited rather than asserted.
        let rule = Sampler.bible.rule("sampler.one-effect")
        #expect(rule?.evidence.isCited == true)
        #expect(rule?.evidence.references.isEmpty == false)
    }

    /// sampler.golden.defers
    @Test("It defers a groove question rather than answering it")
    func defersTheBeatmakersWork() {
        for proposal: PersonaProposal in [
            .setSwing(percent: 62, idiom: "boom-bap", tempo: 90),
            .displaceVoice(voice: "snare", milliseconds: -24, tempo: 90),
            .quantiseHard(idiom: "lo-fi"),
            .setHumanizeTiming(milliseconds: 12, tempo: 90),
            .removeGhosts(currentRatio: 0.5, idiom: "neo-soul"),
        ] {
            let verdict = sampler.consider(proposal)
            if case .defer_(let to, _) = verdict {
                #expect(to == .beatmaker)
            } else {
                Issue.record("the Sampler answered \(proposal): \(verdict)")
            }
        }
    }

    // MARK: Reading a real chop

    @Test("It reads a chop cut off this app's own chopper")
    func readsAChop() {
        let signal = ChopLaneFixtures.cleanBar()
        let chopper = Chopper()
        let chop = chopper.sliceByOnsets(signal, sampleRate: ChopLaneFixtures.sampleRate,
                                         snappingTo: ChopLaneFixtures.grid, division: 4,
                                         detectedTempo: ChopLaneFixtures.bpm)
        let classifications = SliceClassifier().classify(chop, in: signal)
        let observation = SourceObservation(label: "Bar 1", chop: chop,
                                            classifications: classifications,
                                            bandwidthHz: SourceMeasurement.rolloff(
                                                signal, sampleRate: ChopLaneFixtures.sampleRate))
        #expect(observation.sliceCount > 4)
        #expect(observation.tempo == ChopLaneFixtures.bpm)
        // A real 90 BPM bar: the machine rule fires.
        #expect(sampler.read(observation).first { $0.rule == "sampler.bar-does-not-fit" }?.holds == false)

        // The rolloff is a real measurement of a real signal, not a placeholder.
        let bandwidth = try? #require(observation.bandwidthHz)
        #expect((bandwidth ?? 0) > 500)
        #expect((bandwidth ?? .infinity) < ChopLaneFixtures.sampleRate / 2)

        // Every reading names a rule the bible declares.
        let ruleIDs = Set(Sampler.bible.rules.map(\.id))
        for reading in sampler.read(observation) {
            #expect(ruleIDs.contains(reading.rule), "\(reading.rule) is not in the bible")
        }
    }

    @Test("The rolloff is lower for a darker source, which is what the chain rule rests on")
    func rolloffTracksBrightness() {
        let bright = ChopLaneFixtures.hat(1.0)
        let dark = ChopLaneFixtures.kick()
        let rate = ChopLaneFixtures.sampleRate
        let brightRolloff = SourceMeasurement.rolloff(bright, sampleRate: rate)
        let darkRolloff = SourceMeasurement.rolloff(dark, sampleRate: rate)
        #expect(darkRolloff < brightRolloff)
        // And a noise floor measurement puts silence far below a signal.
        let quiet = [Float](repeating: 0.0005, count: 48_000)
        #expect(SourceMeasurement.noiseFloorDB(quiet, sampleRate: rate) < -50)
    }

    // MARK: The bible's own promise

    @Test("Every golden the bible declares has a test here")
    func goldensAreImplemented() {
        let implemented: Set<String> = [
            "sampler.golden.late-cut",
            "sampler.golden.bar-does-not-fit",
            "sampler.golden.corner-above-source",
            "sampler.golden.no-stacking",
            "sampler.golden.eight-pads",
            "sampler.golden.leave-it-alone",
            "sampler.golden.pushes-back",
            "sampler.golden.defers",
        ]
        let declared = Set(Sampler.bible.goldens.map(\.id))
        let missing = declared.subtracting(implemented)
        let extra = implemented.subtracting(declared)
        #expect(declared == implemented,
                "declared but not implemented: \(missing); implemented but not declared: \(extra)")
        #expect(declared.count >= 5)
    }

    @Test("The corrections the research forced are recorded rather than quietly applied")
    func theCorrectionsAreWrittenDown() throws {
        // RZA was the obvious third lineage and the premise was wrong; the bible says so.
        let rza = try #require(Sampler.bible.openQuestions.first { $0.id == "sampler.oq.rza" })
        #expect(rza.evidence.isCited)
        #expect(rza.encoded.contains("Ensoniq"))
        #expect(!Sampler.bible.lineages.contains { $0.name.contains("RZA") })
        // And the refusal that follows from it is in the bible too, so the persona will not call
        // the SP-1200 preset something it is not.
        #expect(Sampler.bible.refusals.contains { $0.id == "no-36-chambers-preset" })

        // The pre-roll figure nobody publishes is marked as not published.
        let preRoll = try #require(Sampler.bible.openQuestions.first { $0.id == "sampler.oq.pre-roll" })
        #expect(preRoll.encoded.contains("No figure") || preRoll.encoded.contains("no figure")
                || preRoll.encoded.contains("not asserted"))
        #expect(preRoll.affects.contains("sampler.cut-before-not-after"))

        // The cassette preset's exaggeration against a real deck is stated, with the real figures.
        let cassette = try #require(
            Sampler.bible.openQuestions.first { $0.id == "sampler.oq.cassette-preset" })
        #expect(cassette.encoded.contains("0.06%"))
        // Stored as a Float in the C, so read it with a tolerance rather than for equality.
        let presetWow = DegradeSettings(preset: .cassette).wowDepth * 100
        #expect(abs(presetWow - 0.12) < 1e-6)
        #expect(!Sampler.portastudioWowFlutter.contains(presetWow),
                "the preset now matches a real deck; the open question needs rewriting")
    }
}
