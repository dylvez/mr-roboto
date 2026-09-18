import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate B: the Engineer reads a bounce of what the transport would have played.

@Suite("Section bounce: the Engineer's ears", .serialized)
struct SectionBounceTests {

    /// Two sections at 120: a bar of groove, then a bar of groove and bass.
    private func form() -> (SongPlayback, SectionID) {
        var plan = SongPlayback(tempo: 120, loops: true)
        plan.machine = SynthMachine.tr808.id
        plan.lengthInBars = 2
        let groove = TransportFixture.groove(bars: 1)
        let hook = SectionID()
        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 4, velocity: 100)], sound: "finger")
        plan.segments = [
            SongPlayback.Segment(section: SectionID(), name: "Intro", startBar: 0, lengthInBars: 1,
                                 groove: groove, grooveVersion: VersionID()),
            SongPlayback.Segment(section: hook, name: "Hook", startBar: 1, lengthInBars: 1,
                                 groove: groove, grooveVersion: VersionID(),
                                 bassline: line, basslineVersion: VersionID(), bassSound: "finger"),
        ]
        return (plan, hook)
    }

    @Test("a section is cut out of the form and rebased to bar 0, with the loop off")
    func isolates() throws {
        let (plan, hook) = form()
        let (cut, label, bars) = try SectionBounce.isolate(plan, section: hook)
        #expect(label == "Hook" && bars == 1 && cut.segments.count == 1 && cut.segments[0].startBar == 0 && !cut.loops)
        #expect(SectionBounce.has(cut, .drums) && SectionBounce.has(cut, .bass))
        #expect(!SectionBounce.has(SectionBounce.only(.drums, of: cut), .bass))
        #expect(!SectionBounce.has(SectionBounce.only(.bass, of: cut), .drums))
        var dusty = cut
        dusty.segments[0].grooveChain = [Degradation(preset: "sp1200", parameters: ["highCut": 13_000], seed: 1)]
        #expect(SectionBounce.corner(of: dusty) == 13_000)
        #expect(SectionBounce.corner(of: cut) == nil)
    }

    @Test("the hook bounces to a mix, the drums and the bass, and the Engineer reads them in numbers")
    @AudioActor
    func bouncesAndReads() async throws {
        let kits = TransportFixture.temporaryDirectory("bounce")
        defer { try? FileManager.default.removeItem(at: kits) }
        let (plan, hook) = form()
        let stems = try await SectionBounce.render(plan, section: hook, kitsDirectory: kits)
        #expect(stems.label == "Hook")
        #expect(stems.mix.count == 2 && stems.mix[0].count == Int(2.5 * 48_000))
        #expect(stems.drums[0].contains { abs($0) > 0.001 } && stems.bass[0].contains { abs($0) > 0.001 })

        let observation = stems.observation
        #expect(observation.integratedLUFS.isFinite && observation.integratedLUFS < 0)
        #expect(observation.peakDBFS < 0)
        #expect(observation.drumsCrestDB.map { $0 > 8 } == true, "a drum bounce has a crest: \(observation.drumsCrestDB ?? -1)")
        #expect(observation.lowEndSeparationDB != nil && observation.lowEndOwner != nil)

        let readings = Engineer().read(observation)
        #expect(readings.count == 5)
        #expect(readings.allSatisfy { !$0.says.isEmpty })
        #expect(readings.first { $0.rule == "engineer.who-owns-eighty" }?.says.contains("owns") == true)
    }
}
