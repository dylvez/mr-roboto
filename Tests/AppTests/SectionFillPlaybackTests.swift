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

    @Test("a section's stored way out is what plays: a shape at its size, a cut, or the usual fill when it names none")
    func storedShape() throws {
        var song = song(fills: nil)
        song.sections[0].transitionOut = Transition.fill(Fill(shape: .snareRoll, size: .bar), beatsPerBar: 4)
        var plan = SongPlayback.plan(for: song, mediaURL: resolver)
        var verse = try groove(plan.segments[0])
        #expect(hits(verse, .lowTom).isEmpty && hits(verse, .highTom).isEmpty, "a snare roll has no toms")
        #expect(hits(verse, .snare).filter { $0 >= 48 }.count == 12, "\(hits(verse, .snare))")
        #expect(hits(verse, .closedHat).allSatisfy { $0 < 48 }, "the hats rest through the bar")
        #expect(hits(try groove(plan.segments[1]), .crash) == [0])

        song.sections[0].transitionOut = Transition(kind: .cut)
        plan = SongPlayback.plan(for: song, mediaURL: resolver)
        verse = try groove(plan.segments[0])
        #expect(hits(verse, .lowTom).isEmpty && verse == Guidance.grooves(in: song).last.flatMap { if case .groove(let g) = $0.kind { return g } else { return nil } },
                "cut: the groove runs to the bar line as written")

        song.sections[0].transitionOut = Transition(kind: .fill)
        plan = SongPlayback.plan(for: song, mediaURL: resolver)
        #expect(hits(try groove(plan.segments[0]), .lowTom).contains { $0 >= 4 * 16 - 8 }, "a fill with no shape is the usual one")
        #expect(SongPlayback.fill(out: Section(name: "Verse", stitch: [], lengthInBars: 4), beatsPerBar: 4) == .usual)
        #expect(SongPlayback.fill(out: song.sections[0], beatsPerBar: 4) == .usual)
        #expect(SongPlayback.fills(out: song.sections[0]) && !SongPlayback.fills(out: Section(name: "V", stitch: [], lengthInBars: 4, transitionOut: Transition(kind: .riser))))
    }

    @Test("with fills off, a section that names a fill still plays it, with a crash where it leads; the rest play as written")
    func namedWithFillsOff() throws {
        var song = song(fills: false)
        song.sections[0].transitionOut = Transition.fill(Fill(shape: .snareRoll, size: .bar), beatsPerBar: 4)
        let plan = SongPlayback.plan(for: song, mediaURL: resolver)
        let verse = try groove(plan.segments[0]), hook = try groove(plan.segments[1])
        #expect(hits(verse, .snare).filter { $0 >= 48 }.count == 12, "the roll plays")
        #expect(hits(hook, .crash) == [0], "and the crash it leads to")
        #expect(FillChoosing.wayOut(of: Section(name: "V", stitch: [], lengthInBars: 4), beatsPerBar: 4, fillsOn: false) == "no fill")
        #expect(FillChoosing.wayOut(of: Section(name: "V", stitch: [], lengthInBars: 4), beatsPerBar: 4) == "the usual fill")
    }

    @Test("Choosing keeps a seam, reads the genre first, plays no timbales nobody has, and the way in follows the way out")
    func choosing() throws {
        func section(_ name: String, out: Transition? = nil, into: Transition? = nil, intensity: Double? = nil) -> Section {
            Section(name: name, stitch: [], lengthInBars: 8, intensity: intensity, transitionIn: into, transitionOut: out)
        }
        let cut = Transition(kind: .cut)
        // The two halves of one section stay a cut; a cut between two kinds of section gets its fill.
        let form = [section("Verse", out: cut), section("Verse 2", out: cut, into: cut), section("Chorus", into: cut), section("Verse 3"), section("Outro")]
        let chosen = FillChoosing.chosen(form, family: .kit, seed: 4, beatsPerBar: 4)
        #expect(chosen[0].transitionOut?.kind == .cut && chosen[1].transitionIn?.kind == .cut, "the seam")
        #expect(chosen[1].transitionOut?.fill(beatsPerBar: 4) != nil && chosen[2].transitionIn == nil, "into the chorus: a fill and a crash")
        // No fill and no arrival: the groove goes on, with no crash on its one.
        let seed = (1...40).map(UInt64.init).first { FillChoosing.chosen(form, family: .kit, seed: $0, beatsPerBar: 4)[2].transitionOut?.fill(beatsPerBar: 4)?.shape == FillShape.none }
        let quiet = FillChoosing.chosen(form, family: .kit, seed: try #require(seed), beatsPerBar: 4)
        #expect(quiet[3].transitionIn?.kind == .cut, "\(quiet[3])")
        // The family: the genre said, then the feel, then whether anybody plays a snare.
        var built = FormFixture.build(tempo: 122)
        #expect(FillChoosing.family(of: built.song) == .kit)
        built.song.genre = "house"
        #expect(FillChoosing.family(of: built.song) == .electronic)
        built.song.genre = "dub"
        #expect(FillChoosing.family(of: built.song) == .reggae)
        var machine = Song.new(title: "Signal", tempo: 122)
        try machine.append(PartVersion(partID: PartID(), kind: .groove(Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest })])),
                                       author: .user, operation: Operation.written))
        #expect(FillChoosing.family(of: machine) == .electronic, "no snare, no drummer")
        // A note that happens to name a feel is not a genre: only what was said, or stored, counts.
        var noted = FormFixture.build(tempo: 131).song
        try noted.append(PartVersion(partID: PartID(), kind: .groove(Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .snare, steps: (0..<16).map { $0 % 8 == 4 ? .normal : .rest })])),
                                     author: .user, operation: Operation.written, note: "A shuffle over the Folk Strum"))
        #expect(FillChoosing.family(of: noted) == .kit)
        #expect(!FillChoosing.hasTimbales(in: machine))
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
