import Foundation
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate B: the Engineer reads a bounce in the delivery spec's numbers.

@Suite("Persona: Engineer")
struct PersonaEngineerTests {
    private let engineer = Engineer()
    private let rate = 48_000.0

    private func sine(_ hz: Double, peakDB: Double, seconds: Double = 2) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test("it reads loudness, peak, crest, bandwidth and who owns the low end, in numbers")
    func readsABounce() {
        // A kick-like 80 Hz tone at −6 and a bass-like 100 Hz tone at −8: within 6 dB, they fight.
        let drums = sine(80, peakDB: -6)
        let bass = sine(100, peakDB: -8)
        let mix = zip(drums, bass).map { $0 + $1 }
        let observation = MixObservation.measure(label: "Verse", mix: [mix], sampleRate: rate, drums: [drums], bass: [bass])
        #expect(observation.integratedLUFS.isFinite)
        #expect(abs(observation.peakDBFS - MixMeter.samplePeakDB([mix])) < 1e-9)
        #expect(observation.lowEndOwner == "kick")
        #expect(observation.lowEndSeparationDB.map { $0 > 1 && $0 < 4 } == true, "\(observation.lowEndSeparationDB ?? -1)")
        #expect(observation.bandwidthHz < 8_000, "two low tones have no top end")
        let readings = engineer.read(observation)
        let low = readings.first { $0.rule == "engineer.who-owns-eighty" }
        #expect(low?.holds == false && low?.says.contains("The kick owns it") == true, "\(low?.says ?? "")")
        #expect(readings.first { $0.rule == "engineer.a-corner-is-a-choice" }?.holds == false)
        #expect(readings.first { $0.rule == "engineer.peak-ceiling" }?.holds == true)
        #expect(readings.first { $0.rule == "engineer.drums-keep-their-crest" }?.says.contains("squashed") == true, "a sine's crest is 3 dB")

        // Loud and separated: a −9 LUFS mix is hot; a bass 10 dB under the kick is owned.
        let hot = MixObservation.measure(label: "Hook", mix: [sine(1_000, peakDB: -3), sine(1_000, peakDB: -3)], sampleRate: rate,
                                         drums: [sine(80, peakDB: -6)], bass: [sine(100, peakDB: -18)])
        let hotReadings = engineer.read(hot)
        #expect(hotReadings.first { $0.rule == "engineer.delivery-loudness" }?.holds == false)
        #expect(hotReadings.first { $0.rule == "engineer.delivery-loudness" }?.says.contains("hot") == true)
        #expect(hotReadings.first { $0.rule == "engineer.who-owns-eighty" }?.holds == true)
        let silent = MixObservation.measure(label: "Nothing", mix: [[Float](repeating: 0, count: 4800)], sampleRate: rate)
        #expect(engineer.read(silent).first { $0.rule == "engineer.delivery-loudness" }?.says.contains("silent") == true)
    }

    @Test("a section's loudness is said, not judged as a delivery: not against −14, not by the genre, not by the master's target")
    func aSectionIsNotADelivery() throws {
        var verse = MixObservation(label: "Verse", integratedLUFS: -10.7, peakDBFS: -1.3, crestDB: 12, tiltDB: -3, bandwidthHz: 14_000)
        verse.section = "Verse"
        let said = try #require(engineer.read(verse).first { $0.rule == "engineer.delivery-loudness" })
        #expect(said.holds && said.feature == .sectionLUFS && said.says.hasPrefix("The Verse plays at -10.7 LUFS"), "\(said.says)")
        // Disco delivers at −10.4 to −8; a verse at −10.7 is the arrangement, and the genre leaves it be.
        let disco = try #require(GenreBook.standard.profile(named: "disco"))
        #expect(GenreLens(disco).apply(said, bible: Engineer.bible) == said)
        #expect(HotMasterCritic().review(MixReview(observation: verse, master: Master(targetLUFS: -14))).isEmpty)
        // The whole song is a delivery, judged as before.
        var song = verse
        song.section = nil
        let whole = try #require(engineer.read(song).first { $0.rule == "engineer.delivery-loudness" })
        #expect(!whole.holds && whole.feature == .integratedLUFS && whole.says.contains("hot against −14"))
        #expect(!GenreLens(disco).apply(whole, bible: Engineer.bible).holds, "−10.7 is under disco's −10.4")
        #expect(HotMasterCritic().review(MixReview(observation: song, master: Master(targetLUFS: -14))).count == 1)
    }

    @Test("a dark top end a filter or a chain put there is decided and stands; one nothing put there is said")
    func aDecidedCorner() throws {
        var robot = MixObservation(label: "Robot", integratedLUFS: -11, peakDBFS: -1.3, crestDB: 13, tiltDB: -9, bandwidthHz: 3_000)
        func corner(_ observation: MixObservation) -> PersonaReading? { engineer.read(observation).first { $0.rule == "engineer.a-corner-is-a-choice" } }
        #expect(corner(robot)?.holds == false && corner(robot)?.says.contains("no chain or filter put it there") == true)
        robot.filterCornerHz = 450
        #expect(corner(robot)?.holds == true && corner(robot)?.says == "Top end stops at 3 kHz, behind a filter at 450 Hz: dark, and decided.",
                "\(corner(robot)?.says ?? "")")
        robot.filterCornerHz = nil
        robot.chainCornerHz = 4_000
        #expect(corner(robot)?.holds == true && corner(robot)?.says.contains("under the chain's corner at 4 kHz") == true)
        // A corner over the floor does not explain a top end under it.
        robot.chainCornerHz = 13_000
        #expect(corner(robot)?.holds == false && corner(robot)?.says.contains("the chain's corner is 13 kHz") == true)
    }

    @Test("the filter corner in force is the section's own, held or swept, else a strip's closed filter; a sweep does not darken the song")
    @MainActor func filterCornerOfAPlan() throws {
        let (song, chords) = try EffectsToolTests.song()
        let chorus = try #require(song.sections.last?.id)
        var plan = SongPlayback.plan(for: song, mediaURL: { _ in nil })
        var mix = Mix.unity
        mix.strips = [Strip(part: chords, label: "Organ", filter: StripFilter(kind: .lowPass))]
        mix.setSectionEffect(SectionEffect(section: chorus, part: chords, filterFromHz: 300, filterToHz: 20_000))
        plan.mix = mix
        #expect(SectionBounce.filterCorner(of: plan, section: chorus) == 300)
        #expect(SectionBounce.filterCorner(of: plan, section: song.sections.first?.id) == nil, "open where no section moves it")
        #expect(SectionBounce.filterCorner(of: plan, section: nil) == nil)
        mix.strips = [Strip(part: chords, label: "Organ", filter: StripFilter(kind: .lowPass, cutoffHz: 800))]
        plan.mix = mix
        #expect(SectionBounce.filterCorner(of: plan, section: nil) == 800)
        #expect(SectionBounce.filterCorner(of: plan, section: chorus) == 300, "the section's corner, not the strip's")
        mix.strips = [Strip(part: chords, label: "Organ", filter: StripFilter(kind: .highPass, cutoffHz: 800))]
        mix.sectionEffects = []
        plan.mix = mix
        #expect(SectionBounce.filterCorner(of: plan, section: nil) == nil, "a high-pass takes nothing off the top")
    }

    @Test("kick and bass are judged in the whole decibels they are said in")
    func lowEndSaidAndJudgedAlike() {
        func low(_ separation: Double) -> PersonaReading? {
            let observation = MixObservation(label: "Verse", integratedLUFS: -14, peakDBFS: -2, crestDB: 12, tiltDB: -3, bandwidthHz: 14_000,
                                             lowEndSeparationDB: separation, lowEndOwner: "kick")
            return engineer.read(observation).first { $0.rule == "engineer.who-owns-eighty" }
        }
        #expect(low(5.6)?.holds == true && low(5.6)?.says == "The kick owns 60–120 Hz by 6 dB.", "\(low(5.6)?.says ?? "")")
        #expect(low(5.4)?.holds == false && low(5.4)?.says.contains("within 5 dB") == true && low(5.4)?.says.contains("down 1 dB") == true,
                "\(low(5.4)?.says ?? "")")
        #expect(low(1.7)?.says.contains("within 2 dB") == true && low(1.7)?.says.contains("down 4 dB") == true)
    }

    @Test("it refuses a hot master, a squashed drum bus and a fighting low end, and defers the rest")
    func verdicts() {
        #expect(engineer.consider(.setLoudness(integratedLUFS: -9, peakDBFS: -0.1)).refusedByRule == "engineer.delivery-loudness")
        #expect(engineer.consider(.setLoudness(integratedLUFS: -14.5, peakDBFS: -2)).isAgreement)
        #expect(engineer.consider(.setLoudness(integratedLUFS: -14, peakDBFS: 0)).refusedByRule == "engineer.peak-ceiling")
        #expect(engineer.consider(.squashDrums(crestDB: 5)).refusedByRule == "engineer.drums-keep-their-crest")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 2)).refusedByRule == "engineer.who-owns-eighty")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 20)).refusedByRule == "engineer.bass-has-a-body")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 9)).isAgreement)
        if case .defer_(let to, _) = engineer.consider(.moveCutLate(milliseconds: 9)) { #expect(to == .sampler) } else { Issue.record("a cut is the Sampler's") }
        // M6: the hands.
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -3, bandHz: 0, bandDB: 0)).isAgreement)
        #expect(engineer.consider(.moveStrip(part: "kick", gainDB: 0, bandHz: 3_000, bandDB: 4)).refusedByRule == "engineer.cut-before-boost")
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -3, bandHz: 80, bandDB: -6)).refusedByRule == "engineer.one-move-at-a-time")
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -9, bandHz: 0, bandDB: 0)).refusedByRule == "engineer.small-moves")
        #expect(engineer.consider(.setMaster(targetLUFS: -14, ceilingDBTP: -1)).isAgreement)
        #expect(engineer.consider(.setMaster(targetLUFS: -14, ceilingDBTP: 0)).refusedByRule == "engineer.master-ceiling")
        #expect(engineer.consider(.setMaster(targetLUFS: -4, ceilingDBTP: -1)).refusedByRule == "engineer.master-target")
        if case .defer_(let to, _) = Beatmaker().consider(.moveStrip(part: "kick", gainDB: -3, bandHz: 0, bandDB: 0)) { #expect(to == .engineer) } else { Issue.record("a strip move is the Engineer's") }
        #expect(BibleMethod.lint(Engineer.bible).isEmpty, "\(BibleMethod.lint(Engineer.bible))")
    }
}
