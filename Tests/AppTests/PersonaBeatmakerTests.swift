import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The Beatmaker's golden tests.
//
// Each one is the Swift form of a `GoldenTest` the bible declares, and `goldensAreImplemented` below
// asserts that every declared golden has one — so a golden cannot be written into the bible and
// quietly left unwritten in code.
//
// No audio device, no engine, no model. A persona's opinion is a pure function of a proposal, and a
// persona's reading is a pure function of an observation, which is the whole reason this is testable
// at all.

private let beatmaker = Beatmaker()

@Suite("Persona: Beatmaker")
struct PersonaBeatmakerTests {

    // MARK: Goldens

    /// beatmaker.golden.dilla-direction
    @Test("The snare goes early against straight hats, and the late direction is flagged")
    func dillaDirection() {
        // The documented direction: early, inside the zone, hats untouched.
        let early = beatmaker.consider(.displaceVoice(voice: "snare", milliseconds: -24, tempo: 90))
        #expect(early.isAgreement)
        #expect(!early.isRefusal)
        #expect(early.spoken.contains("early"))

        // Moving the hats instead is refused: it takes away the thing the snare is early against.
        let hats = beatmaker.consider(.displaceVoice(voice: "closedHat", milliseconds: -24, tempo: 90))
        #expect(hats.refusedByRule == "beatmaker.hats-straight")

        // And the folklore direction is carried out but flagged, not silently accepted — because
        // this app's own feel library encodes it and the user has to be able to find that out.
        let late = beatmaker.consider(.displaceVoice(voice: "snare", milliseconds: 24, tempo: 90))
        #expect(late.isAgreement)
        if case .agreeWithCaveat(_, let caveat) = late {
            #expect(caveat.contains("early"))
            #expect(caveat.lowercased().contains("feel library"))
        } else {
            Issue.record("a late snare should be agreed with a caveat, not \(late)")
        }

        // The rule and the range agree with each other.
        let range = Beatmaker.bible.range(.snareLagMS, lineage: Beatmaker.dilla)
        #expect(range?.low == -65)
        #expect(range?.high == -21)
        #expect(Beatmaker.snareDisplacementZone.contains(-24))
    }

    /// beatmaker.golden.default-swing
    @Test("The default swing lands where the manual and the measured corpus agree")
    func defaultSwing() {
        // 54% is the MPC60 manual's own recommendation for sixteenth hats; 54.5% is the median of
        // Frane's thirty breaks. The zone contains both, which is the point.
        #expect(Beatmaker.defaultSwingZone.contains(54))
        #expect(Beatmaker.defaultSwingZone.contains(54.5))
        #expect(Beatmaker.defaultSwingZone.contains(56.5))   // Frane's mean, 1.3:1
        #expect(!Beatmaker.defaultSwingZone.contains(Swing.tripletPercent))

        let inside = beatmaker.consider(.setSwing(percent: 56, idiom: "boom-bap", tempo: 90))
        #expect(inside.isAgreement)
        #expect(!inside.isRefusal)

        let heavy = beatmaker.consider(.setSwing(percent: 70, idiom: "boom-bap", tempo: 90))
        if case .agreeWithCaveat(_, let caveat) = heavy {
            #expect(caveat.contains("54–58"))
        } else {
            Issue.record("70% should carry a caveat, not \(heavy)")
        }

        // The corpus range and the shipped feels agree: every idiom feel is inside the machines'
        // own 50–75 and none of them is past a triplet.
        for feel in FeelLibrary.standard.feels {
            #expect(feel.swing.percent >= Swing.minimumPercent)
            #expect(feel.swing.percent <= Swing.maximumPercent)
        }
    }

    /// beatmaker.golden.sub-perceptual
    @Test("A nudge under the detection threshold is refused rather than applied")
    func subPerceptualIsRefused() {
        let verdict = beatmaker.consider(.displaceVoice(voice: "snare", milliseconds: -4, tempo: 90))
        #expect(verdict.refusedByRule == "beatmaker.below-perception")
        #expect(verdict.spoken.contains("10 ms"))
        // The refusal offers something rather than just saying no.
        if case .refuse(_, _, let counter) = verdict {
            #expect(counter.contains("10"))
            #expect(!counter.isEmpty)
        }

        // Exactly at the threshold it is allowed through: the rule is "under", not "around".
        let atThreshold = beatmaker.consider(
            .displaceVoice(voice: "snare", milliseconds: -Beatmaker.perceptionFloorMS, tempo: 90))
        #expect(!atThreshold.isRefusal)

        // And the same figure is what marks a difference on the Compare surface, from one place.
        #expect(Beatmaker.bible.noticeable(.snareLagMS) == Beatmaker.perceptionFloorMS)
    }

    /// beatmaker.golden.thirty-second-grid
    @Test("Swing is refused on a thirty-second grid, where the machine never offered it")
    func swingOnAThirtySecondGrid() {
        let verdict = beatmaker.consider(.setSwing(percent: 66, idiom: "trap", tempo: 142))
        #expect(verdict.refusedByRule == "beatmaker.swing-domain")
        #expect(verdict.spoken.contains("1/16"))

        // Straight is fine there.
        let straight = beatmaker.consider(.setSwing(percent: 50, idiom: "trap", tempo: 142))
        #expect(!straight.isRefusal)

        // And the shipped trap feel already obeys this: 32 steps to the bar, swing at zero.
        let trap = FeelLibrary.standard.feel(named: "Trap Rolling Hats")
        #expect(trap?.groove.stepsPerBar == 32)
        #expect(trap?.swing.percent == Swing.minimumPercent)

        // The reading agrees with the opinion: the same groove read back says the lever does not
        // belong there.
        let observation = GrooveObservation(trap!)
        #expect(observation.subdivision == 8)
        let notes = beatmaker.read(observation)
        let domain = notes.first { $0.rule == "beatmaker.swing-domain" }
        #expect(domain?.holds == true)
    }

    /// beatmaker.golden.machine-reach
    @Test("A displacement past the machine's own reach is refused at 76 ms")
    func pastTheMachinesReach() {
        let verdict = beatmaker.consider(.displaceVoice(voice: "snare", milliseconds: -120, tempo: 90))
        #expect(verdict.refusedByRule == "beatmaker.machine-reach")
        #expect(verdict.spoken.contains("76"))
        // The counter is the limit, not zero: a refusal that offers nothing is an obstacle.
        if case .refuse(_, _, let counter) = verdict {
            #expect(counter.contains("76"))
        }

        // The number is derivable rather than invented: 11 ticks at 96 per quarter note, at 90 BPM.
        let tickSeconds = 60.0 / (90.0 * 96.0)
        #expect(abs(11 * tickSeconds * 1000 - Beatmaker.maximumShiftMS) < 1.0)
    }

    /// beatmaker.golden.tempo-independence
    @Test("Raising the tempo does not raise the recommended swing")
    func tempoDoesNotMoveSwing() {
        // The corpus finding is that swing ratio is uncorrelated with tempo, so the same figure is
        // agreed at both ends of the idiom's range with the same verdict kind.
        let slow = beatmaker.consider(.setSwing(percent: 56, idiom: "lo-fi", tempo: 85))
        let fast = beatmaker.consider(.setSwing(percent: 56, idiom: "lo-fi", tempo: 105))
        #expect(slow.isAgreement && fast.isAgreement)
        #expect(!slow.isRefusal && !fast.isRefusal)

        // What *does* change with tempo is the displacement that figure produces, which is why the
        // swing clash check works in milliseconds rather than in percent.
        let atEightyFive = SourceSwing.displacementMS(percent: 56, tempo: 85)
        let atOneOhFive = SourceSwing.displacementMS(percent: 56, tempo: 105)
        #expect(atEightyFive > atOneOhFive)
        #expect(abs(atEightyFive - 21.2) < 0.5)
        #expect(abs(atOneOhFive - 17.1) < 0.5)
    }

    /// beatmaker.golden.pushes-back — the disagreement test.
    @Test("It pushes back on a deliberately bad idea instead of complying")
    func pushesBack() {
        // The bad idea: flatten a sample-based groove onto the grid because it sounds sloppy.
        let verdict = beatmaker.consider(.quantiseHard(idiom: "lo-fi"))
        #expect(verdict.isRefusal, "the Beatmaker complied with hard quantisation: \(verdict)")
        #expect(verdict.refusedByRule == "beatmaker.hard-quantise-kills-it")

        guard case .refuse(_, let because, let counter) = verdict else {
            Issue.record("expected a refusal")
            return
        }
        // It says why in terms of a measurement, not in terms of taste.
        #expect(because.contains("spread"))
        // And it offers a way forward that is not "do it anyway" and not "no".
        #expect(counter.contains("humanize") || counter.contains("per-voice"))
        #expect(counter.count > 60)

        // The same refusal does not fire where it should not: a house groove has nothing that
        // depends on the voices disagreeing, so hard quantisation is simply agreed.
        let house = beatmaker.consider(.quantiseHard(idiom: "house"))
        #expect(house.isAgreement)

        // Second bad idea, second push-back: stripping the ghosts out of a neo-soul pocket.
        let ghosts = beatmaker.consider(.removeGhosts(currentRatio: 0.55, idiom: "neo-soul"))
        #expect(ghosts.refusedByRule == "beatmaker.ghosts-fill-the-gaps")
        // And not where the ghosts are incidental.
        #expect(beatmaker.consider(.removeGhosts(currentRatio: 0.03, idiom: "house")).isAgreement)
    }

    /// beatmaker.golden.defers
    @Test("It defers a source question rather than answering it")
    func defersTheSamplersWork() {
        for proposal: PersonaProposal in [
            .applyDegrade(preset: "vinyl", sourceBandwidthHz: 16_000, sourceNoiseFloorDB: -60),
            .chopDensity(slicesPerBar: 16, sourceTransients: 20),
            .moveCutLate(milliseconds: 9),
            .stackDegrade(first: "sp1200", second: "vinyl"),
            .leaveAlone(sourceBandwidthHz: 18_000),
        ] {
            let verdict = beatmaker.consider(proposal)
            if case .defer_(let to, _) = verdict {
                #expect(to == .sampler)
            } else {
                Issue.record("the Beatmaker answered \(proposal): \(verdict)")
            }
        }
    }

    // MARK: Reading the shipped feels

    @Test("It reads this app's own feels and says the true thing about each")
    func readsTheShippedFeels() throws {
        let library = FeelLibrary.standard

        // Lo-Fi Hip-Hop encodes the folklore direction — snare late, hats straight — and the
        // Beatmaker says so rather than approving it. This is the bible's central correction,
        // firing against the library it ships beside.
        let lofi = try #require(library.feel(named: "Lo-Fi Hip-Hop"))
        let lofiRead = beatmaker.read(GrooveObservation(lofi))
        let direction = try #require(lofiRead.first { $0.rule == "beatmaker.snare-direction" })
        #expect(direction.holds, "late is the house call, so the shipped feel is what the house plays")
        #expect(direction.value > 0, "the shipped lo-fi feel should have a late snare")
        #expect(direction.says.contains("documented accounts have it early"), "the record is still said")
        // But the hats *are* straight, which is the half the library got right.
        let hats = try #require(lofiRead.first { $0.rule == "beatmaker.hats-straight" })
        #expect(hats.holds)

        // Boom-Bap Pocket sits inside the corpus's swing zone.
        let boomBap = try #require(library.feel(named: "Boom-Bap Pocket"))
        #expect(Beatmaker.defaultSwingZone.contains(boomBap.swing.percent))
        let boomBapRead = beatmaker.read(GrooveObservation(boomBap))
        #expect(boomBapRead.first { $0.rule == "beatmaker.swing-default" }?.holds == true)

        // Neo-Soul Pocket is the one with the ghosts, by a wide margin.
        let neoSoul = try #require(library.feel(named: "Neo-Soul Pocket"))
        let neoSoulObservation = GrooveObservation(neoSoul)
        #expect(neoSoulObservation.ghostRatio > 0.4)
        #expect(neoSoulObservation.ghostRatio > GrooveObservation(boomBap).ghostRatio)
    }

    @Test("A groove observation is arithmetic over the values, at the tempo it is read at")
    func observationIsArithmetic() throws {
        let feel = try #require(FeelLibrary.standard.feel(named: "Neo-Soul Pocket"))
        let observation = GrooveObservation(feel, tempo: 80)

        // One sixteenth at 80 BPM is 187.5 ms, and the snare's stored 0.12 of a step is 22.5 ms.
        #expect(abs(observation.stepMS - 187.5) < 0.01)
        #expect(abs(observation.lagMS(.snare) - 22.5) < 0.01)
        // The same feel read faster produces a smaller displacement from the same stored fraction,
        // which is exactly why the bible works in milliseconds and the engine works in fractions.
        let faster = GrooveObservation(feel, tempo: 95)
        #expect(faster.lagMS(.snare) < observation.lagMS(.snare))

        // Ghost depth is the velocity map in dB: .wide is 24 against 88.
        #expect(abs(observation.ghostDepthDB - 20 * log10(88.0 / 24.0)) < 0.001)

        // The backbeats are counted, ghosts excluded: two bars, snare on 2 and 4 of each.
        #expect(observation.backbeatCount == 4)
    }

    // MARK: The bible's own promise

    @Test("Every golden the bible declares has a test here")
    func goldensAreImplemented() {
        // The names below are the functions in this file. Keeping the list explicit rather than
        // reflecting over the suite is deliberate: it fails loudly when a golden is added to the
        // bible and forgotten here, which is the whole point.
        let implemented: Set<String> = [
            "beatmaker.golden.dilla-direction",
            "beatmaker.golden.default-swing",
            "beatmaker.golden.sub-perceptual",
            "beatmaker.golden.thirty-second-grid",
            "beatmaker.golden.machine-reach",
            "beatmaker.golden.tempo-independence",
            "beatmaker.golden.pushes-back",
            "beatmaker.golden.defers",
        ]
        let declared = Set(Beatmaker.bible.goldens.map(\.id))
        let missing = declared.subtracting(implemented)
        let extra = implemented.subtracting(declared)
        #expect(declared == implemented,
                "declared but not implemented: \(missing); implemented but not declared: \(extra)")
        #expect(declared.count >= 5)
    }
}

@Suite("Beatmaker: house calls") @MainActor
struct BeatmakerHouseCallTests {
    @Test("the snare direction is settled late by ear, and the research is left as written")
    func snareCall() throws {
        #expect(Beatmaker.houseSnareIsLate)
        let call = try #require(Beatmaker.houseCalls.first)
        #expect(Beatmaker.bible.openQuestions.contains { $0.id == call.question },
                "a house call must settle a question the bible actually asks")
        let rule = try #require(Beatmaker.bible.rules.first { $0.id == "beatmaker.snare-direction" })
        #expect(rule.then.contains("EARLY"), "the documented rule is not rewritten to agree with the house")
    }

    @Test("an early snare is now the one flagged, with the house's reason")
    func earlyIsFlagged() throws {
        var feel = try #require(FeelLibrary.standard.feel(named: "Lo-Fi Hip-Hop"))
        feel.voices[.snare] = VoiceFeel(timingOffset: -0.115)
        let reading = Beatmaker().read(GrooveObservation(feel))
        let direction = try #require(reading.first { $0.rule == "beatmaker.snare-direction" })
        #expect(!direction.holds)
        #expect(direction.says.contains("plays it late"))
    }
}
