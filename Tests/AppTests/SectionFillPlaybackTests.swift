import Foundation
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

/// The arranged drums play to the form: a fill into each next section and a crash out of the
/// last, unless the song turns them off.
@Suite("Fills in the arranged plan") @MainActor
struct SectionFillPlaybackTests {
    private let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))

    private func song(fills: Bool?) -> Song {
        let built = FormFixture.build(tempo: 92)
        var song = built.song
        song.sections = [
            Section(name: "Verse", stitch: [built.groove, built.bass].lanes, lengthInBars: 4),
            Section(name: "Hook", stitch: [built.groove].lanes, lengthInBars: 4),
        ]
        song.fills = fills
        return song
    }

    private func groove(_ segment: SongPlayback.Segment) throws -> Groove {
        try #require(segment.groove)
    }

    private func hits(_ groove: Groove, _ voice: DrumVoice) -> [Int] {
        let steps = groove.patterns.first { $0.voice == voice }?.steps ?? []
        return steps.indices.filter { steps[$0] != .rest }
    }

    @Test("a song plays fills unless it says not to, and the setting round-trips as absent when on")
    func defaultOn() throws {
        #expect(song(fills: nil).playsFills)
        #expect(!song(fills: false).playsFills)
        let data = try JSONEncoder().encode(song(fills: nil))
        #expect(!String(decoding: data, as: UTF8.self).contains("\"fills\""))
    }

    @Test("the verse ends on a fill, the hook starts on a crash, and nothing fills out of the last section")
    func planHasFills() throws {
        let plan = SongPlayback.plan(for: song(fills: nil), mediaURL: resolver)
        #expect(plan.segments.count == 2)
        let verse = try groove(plan.segments[0]), hook = try groove(plan.segments[1])
        #expect(verse.bars == 4 && hook.bars == 4)
        #expect(hits(verse, .lowTom).contains { $0 >= 4 * 16 - 8 })
        #expect(hits(verse, .crash).isEmpty, "the first section has nothing to crash out of")
        #expect(hits(hook, .crash) == [0])
        #expect(hits(hook, .lowTom).isEmpty, "the last section fills into nothing")
    }

    @Test("with fills off the sections play the groove as written")
    func off() throws {
        let song = song(fills: false)
        let written = try #require(Guidance.grooves(in: song).last.flatMap { version -> Groove? in
            if case .groove(let groove) = version.kind { return groove }
            return nil
        })
        let plan = SongPlayback.plan(for: song, mediaURL: resolver)
        #expect(try plan.segments.allSatisfy { try groove($0) == written })
    }
}
