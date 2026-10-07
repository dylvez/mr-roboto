import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate B: the Producer reads the song as counts and the Peer reads the form as a listener.

@Suite("Persona: Producer") @MainActor
struct PersonaProducerTests {
    private let producer = Producer()

    @Test("it counts the song: parts, orphans, churn and the brief, and says which it would cut")
    func readsArrival() throws {
        var song = FormFixture.build().song
        let observation = SongObservation.of(song)
        #expect(observation.partCount >= 5, "\(observation.partCount)")
        #expect(!observation.hasSections && observation.orphanedParts.isEmpty, "no sections, no orphans")
        #expect(observation.brief == nil)
        var readings = producer.read(observation)
        #expect(readings.first { $0.rule == "producer.brief-first" }?.holds == false)
        #expect(readings.first { $0.rule == "producer.brief-first" }?.says.contains("No brief") == true)

        // A brief, and a form that leaves one part out.
        song.seeds.append(Seed(kind: .brief("A late-night walk home, drums from a record and a bass that waits.")))
        let groove = try #require(Guidance.grooves(in: song).last)
        let bass = try #require(Guidance.basslines(in: song).last)
        song.sections = [Section(name: "Verse", stitch: [groove, bass].lanes, lengthInBars: 16)]
        let arranged = SongObservation.of(song)
        #expect(arranged.hasSections)
        #expect(arranged.briefWords == 13)
        #expect(!arranged.orphanedParts.isEmpty, "the chop and the chords are in no section")
        readings = producer.read(arranged)
        let orphans = try #require(readings.first { $0.rule == "producer.no-orphans" })
        #expect(!orphans.holds && orphans.says.contains("Stitch or cut"))
        #expect(readings.first { $0.rule == "producer.brief-first" }?.holds == true)
        #expect(readings.first { $0.rule == "producer.churn" }?.holds == true)

        // Redo the bass line five times and it says stop.
        for i in 0..<5 {
            let redo = bass.deriving(bass.kind, by: .user, operation: Operation.edit, note: "again \(i)")
            try song.append(redo)
        }
        let churned = SongObservation.of(song)
        #expect(churned.maximumVersions == 6)
        #expect(producer.read(churned).first { $0.rule == "producer.churn" }?.holds == false)
    }

    @Test("it says no to a part when the song has no room, and defers the sound to its owners")
    func verdicts() {
        #expect(producer.consider(.addPart(partsInSong: 9, orphaned: 0)).refusedByRule == "producer.fewer-parts")
        #expect(producer.consider(.addPart(partsInSong: 3, orphaned: 0)).isAgreement)
        #expect(producer.consider(.setReference(bars: 0)).refusedByRule == "producer.reference-has-bars")
        if case .defer_(let to, _) = producer.consider(.applyDegrade(preset: "vinyl", sourceBandwidthHz: 15_000, sourceNoiseFloorDB: -60)) {
            #expect(to == .sampler)
        } else { Issue.record("the chain is the Sampler's") }
        if case .defer_(let to, _) = producer.consider(.placeHook(atSeconds: 48)) { #expect(to == .peer) } else { Issue.record("the hook is the Peer's") }
        #expect(BibleMethod.lint(Producer.bible).isEmpty, "\(BibleMethod.lint(Producer.bible))")
    }
}

@Suite("Persona: Peer") @MainActor
struct PersonaPeerTests {
    private let peer = Peer()

    @Test("it times the form as a listener: the hook in seconds, the turns, the repeats, the lift")
    func readsTheForm() throws {
        var song = FormFixture.build().song
        song.tempo = 120
        let groove = try #require(Guidance.grooves(in: song).last).partID
        let bass = try #require(Guidance.basslines(in: song).last).partID
        #expect(peer.read(FormObservation.of(song)).first?.rule == "peer.finish-then-judge")

        song.sections = [Section(name: "Intro", stitch: [groove].lanes, lengthInBars: 4),
                         Section(name: "Verse", stitch: [groove, bass].lanes, lengthInBars: 16),
                         Section(name: "Hook", stitch: [groove, bass].lanes, lengthInBars: 8),
                         Section(name: "Verse", stitch: [groove, bass].lanes, lengthInBars: 16),
                         Section(name: "Hook", stitch: [groove, bass].lanes, lengthInBars: 8)]
        let form = FormObservation.of(song)
        #expect(form.sectionCount == 5 && form.turns == 3 && form.repeats == 2)
        #expect(form.hookArrivalSeconds == 40, "20 bars at 120 in 4/4")
        #expect(form.cutToBringHook == "Verse" && form.cutSeconds == 32)
        #expect(form.densitySpread == 1 && form.densest == "Verse")
        #expect(abs(form.repetitionRatio - 0.4) < 1e-9)
        let readings = peer.read(form)
        let hook = try #require(readings.first { $0.rule == "peer.hook-inside-thirty" })
        #expect(!hook.holds)
        #expect(hook.says.contains("0:40") && hook.says.contains("cut Verse") && hook.says.contains("0:08"))
        #expect(readings.first { $0.rule == "peer.form-turns" }?.says == "It turns 2 times.")
        #expect(readings.first { $0.rule == "peer.repetition" }?.holds == true)
        #expect(readings.first { $0.rule == "peer.something-lifts" }?.holds == true)

        // No hook named, and nothing lifting.
        song.sections = [Section(name: "A", stitch: [groove].lanes, lengthInBars: 8), Section(name: "A", stitch: [groove].lanes, lengthInBars: 8),
                         Section(name: "A", stitch: [groove].lanes, lengthInBars: 8), Section(name: "B", stitch: [groove].lanes, lengthInBars: 8)]
        let flat = peer.read(FormObservation.of(song))
        #expect(flat.first { $0.rule == "peer.hook-inside-thirty" }?.says.contains("Nothing is named as a hook") == true)
        #expect(flat.first { $0.rule == "peer.repetition" }?.holds == true, "2 of 4 repeat, under the ceiling")
        #expect(flat.first { $0.rule == "peer.something-lifts" }?.holds == false)

        // A jazz tune's head is its hook.
        song.sections[1].name = "Head"
        #expect(FormObservation.of(song).hookArrivalSeconds != nil)
    }

    @Test("it refuses a late hook in seconds and a form that never turns, and defers the sound")
    func verdicts() {
        let late = peer.consider(.placeHook(atSeconds: 48))
        #expect(late.refusedByRule == "peer.hook-inside-thirty")
        if case .refuse(_, let because, _) = late { #expect(because.contains("48")) }
        #expect(peer.consider(.placeHook(atSeconds: 22)).isAgreement)
        #expect(peer.consider(.shapeForm(sections: 6, turns: 1, minutes: 2.5)).refusedByRule == "peer.form-turns")
        #expect(peer.consider(.shapeForm(sections: 5, turns: 3, minutes: 0.8)).refusedByRule == "peer.not-too-many-sections")
        #expect(peer.consider(.shapeForm(sections: 6, turns: 3, minutes: 2.5)).isAgreement)
        if case .defer_(let to, _) = peer.consider(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 92, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger")) {
            #expect(to == .bassist)
        } else { Issue.record("the bass is the Bassist's") }
        #expect(BibleMethod.lint(Peer.bible).isEmpty, "\(BibleMethod.lint(Peer.bible))")
    }
}
