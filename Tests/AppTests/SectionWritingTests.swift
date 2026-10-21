import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing
@testable import MrRobotoApp

// The band's writing tools with a section named: that section's own drums, bass, tune, chords
// played another way, dust and instrument, the rest of the song as it was; a section's name meaning
// every section of it in the mix tools; and a new part saying where it plays.
@Suite("Director: a part of a section's own, and where a new part plays", .serialized) @MainActor
struct SectionWritingTests {

    /// A loop playing everything in every section of Intro, Verse, Hook, Verse, Hook.
    private func rig() throws -> (rig: WritingFixture.Rig, loop: DevelopFixture.Loop) {
        let loop = try DevelopFixture.loop(sections: [("Intro", 4), ("Verse", 8), ("Hook", 8), ("Verse", 8), ("Hook", 8)])
        let rig = WritingFixture.rig(loop.song)
        rig.app.sectionSettle = 0
        return (rig, loop)
    }

    private func lane(_ type: PartType, in name: String, nth: Int = 0, of song: Song) -> SectionWriting.Played? {
        let sections = song.sections.filter { $0.name == name }
        return nth < sections.count ? AnotherWay.lane(of: type, in: sections[nth], of: song) : nil
    }

    @Test("write_groove and degrade_part with a section: the intro's own drums, then dust there alone")
    func drumsAndDust() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let beat = await WritingFixture.run(rig.box, "write_groove",
            #"{"feel":"","bars":1,"swing_percent":0,"rows":["kick: X...X...X...X..."],"note":"Four on the floor","steps_per_bar":16,"parent":"","section":"intro"}"#)
        #expect(!beat.isError, "\(beat.content)")
        #expect(WritingFixture.json(beat)["sections"] as? [String] == ["Intro"])
        #expect((WritingFixture.json(beat)["detail"] as? String)?.contains("It plays in Intro as its own drums; the rest of the song keeps its.") == true)
        var song = try #require(rig.app.song)
        let intro = try #require(lane(.groove, in: "Intro", of: song))
        #expect(song.variation(of: intro.lane.part)?.of == loop.drums.partID && Develop.isHeld(intro.lane, in: song))
        #expect(lane(.groove, in: "Verse", of: song)?.lane.part == loop.drums.partID, "the verse keeps the song's drums")

        // The song's drums dusty in the intro alone: what the intro plays — its own beat — dirtied there.
        let dust = await WritingFixture.run(rig.box, "degrade_part", #"{"version":"\#(loop.drums.id)","preset":"radio","mix":0.8,"section":"intro"}"#)
        #expect(!dust.isError, "\(dust.content)")
        song = try #require(rig.app.song)
        let dusty = try #require(lane(.groove, in: "Intro", of: song))
        #expect(dusty.lane.part == intro.lane.part && !dusty.version.kind.degradation.isEmpty, "the intro's own part, its next version, dusty")
        #expect(lane(.groove, in: "Verse", of: song)?.version.kind.degradation.isEmpty == true)
        #expect(song.latestVersion(of: loop.drums.partID)?.kind.degradation.isEmpty == true)
    }

    @Test("write_melody for both hooks: their own tune, the song's tune and its mark as they were; play_chords stabs in the verses alone")
    func tuneAndPlaying() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let tune = await WritingFixture.run(rig.box, "write_melody",
            #"{"notes":"E5 0 1, D5 1 1, C5 2 2, A4 4 2, C5 6 1","bars":2,"instrument":"","parent":"","note":"The hook line","draft":3,"section":"hook"}"#)
        #expect(!tune.isError, "\(tune.content)")
        let out = WritingFixture.json(tune)
        #expect(out["sections"] as? [String] == ["Hook", "Hook"], "\(out)")
        #expect((out["detail"] as? String)?.contains("as a tune of its own in both Hooks, in place of the one played there") == true,
                "\(out["detail"] ?? "")")
        var song = try #require(rig.app.song)
        for nth in 0..<2 {
            let hook = try #require(lane(.melody, in: "Hook", nth: nth, of: song))
            #expect(song.variation(of: hook.lane.part)?.of == loop.tune.partID)
        }
        #expect(lane(.melody, in: "Verse", of: song)?.lane.part == loop.tune.partID)
        #expect(SongTune.marked(in: song) == nil, "a section's own tune does not take the song's mark")

        let stabs = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"stabs","voicing":"close","seed":3,"section":"verse"}"#)
        #expect(!stabs.isError, "\(stabs.content)")
        #expect(WritingFixture.json(stabs)["sections"] as? [String] == ["Verse", "Verse"])
        song = try #require(rig.app.song)
        for nth in 0..<2 {
            guard case .progression(let p)? = lane(.progression, in: "Verse", nth: nth, of: song)?.version.kind else { Issue.record("no chords"); return }
            #expect(p.playing?.pattern == "stabs")
        }
        guard case .progression(let hook)? = lane(.progression, in: "Hook", of: song)?.version.kind else { Issue.record("no chords"); return }
        #expect(hook.playing == nil, "the hooks play their chords as they did")
    }

    @Test("write_bassline under a section's own chords; set_progression's first chords say where they play")
    func bassUnderOwnChords() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let own = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm7 | E7","key":"A minor","section":"intro"}"#)
        #expect(!own.isError, "\(own.content)")
        let line = await WritingFixture.run(rig.box, "write_bassline",
            #"{"groove":"\#(loop.drums.id)","hands":"palladino","lag_ms":35,"density":0.45,"seed":7,"sound":"","section":"intro"}"#)
        #expect(!line.isError, "\(line.content)")
        #expect(WritingFixture.json(line)["sections"] as? [String] == ["Intro"])
        let song = try #require(rig.app.song)
        let bass = try #require(lane(.bassline, in: "Intro", of: song))
        #expect(song.variation(of: bass.lane.part)?.of == loop.bass.partID)
        guard case .bassline(let written) = bass.version.kind else { Issue.record("no line"); return }
        // Under the intro's own chords: D, then E.
        for (bar, root) in [2, 4].enumerated() {
            let first = try #require(written.notes.first { $0.start >= Double(bar * 4) - 0.01 && $0.start < Double(bar * 4) + 0.5 }, "bar \(bar + 1)")
            #expect(first.pitch.midi % 12 == root, "bar \(bar + 1): \(first.pitch)")
        }
        #expect(lane(.bassline, in: "Verse", of: song)?.lane.part == loop.bass.partID)

        // A song with a form and no chords: the first ones say where they play.
        var bare = Song(title: "Bare", key: Key(parsing: "A minor")!, tempo: 100)
        bare.sections = [Section(name: "Intro", stitch: [], lengthInBars: 4)]
        let empty = WritingFixture.rig(bare)
        defer { empty.clean() }
        let first = WritingFixture.json(await WritingFixture.run(empty.box, "set_progression", #"{"chords":"Am | F","key":"A minor","section":""}"#))
        #expect((first["detail"] as? String)?.contains("It plays in Intro.") == true, "\(first["detail"] ?? "")")
    }

    @Test("a new part with nowhere to play says so, and how to put it somewhere")
    func saysWhereItPlays() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let beat = WritingFixture.json(await WritingFixture.run(rig.box, "write_groove",
            #"{"feel":"","bars":1,"swing_percent":0,"rows":["kick: X.X.X.X.X.X.X.X."],"note":"Busier","steps_per_bar":16,"parent":"","section":""}"#))
        #expect((beat["detail"] as? String)?.contains("It plays in no section yet: every section already plays a groove of its own") == true,
                "\(beat["detail"] ?? "")")
        let line = WritingFixture.json(await WritingFixture.run(rig.box, "write_bassline",
            #"{"groove":"\#(loop.drums.id)","hands":"palladino","lag_ms":35,"density":0.6,"seed":3,"sound":"","section":""}"#))
        #expect((line["detail"] as? String)?.contains("It plays in no section yet") == true, "\(line["detail"] ?? "")")
        let tune = WritingFixture.json(await WritingFixture.run(rig.box, "write_melody",
            #"{"notes":"A4 0 1, C5 1 1, E5 2 2","bars":1,"instrument":"","parent":"","note":"Another","draft":3,"section":""}"#))
        #expect((tune["detail"] as? String)?.contains("It plays in no section yet") == true, "\(tune["detail"] ?? "")")
        // A rewrite plays where the part played.
        let again = WritingFixture.json(await WritingFixture.run(rig.box, "write_groove",
            #"{"feel":"","bars":1,"swing_percent":0,"rows":["kick: X...X...X...X..."],"note":"Again","steps_per_bar":16,"parent":"\#(loop.drums.id)","section":""}"#))
        #expect((again["detail"] as? String)?.contains("It plays wherever") == true, "\(again["detail"] ?? "")")
        #expect(DirectorPrompt.system.contains("When an answer says a new part plays in no section, tell the user"))
    }

    @Test("set_instrument with a section: its own part on its own sampler, the rest of the song on what it had")
    func ownInstrument() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        var song = try #require(rig.app.song)
        let was = SongPlayback.instrumentID(for: loop.chords.partID, in: song)
        let other = try #require(InstrumentVoiceSpec.available.first { $0.id != was && $0.family != "drums" })
        let set = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"\#(other.id)","part":"\#(loop.chords.partID)","section":"intro"}"#)
        #expect(!set.isError, "\(set.content)")
        #expect(WritingFixture.json(set)["sections"] as? [String] == ["Intro"])
        song = try #require(rig.app.song)
        let intro = try #require(lane(.progression, in: "Intro", of: song))
        #expect(intro.lane.part != loop.chords.partID && song.strip(of: intro.lane.part) == loop.chords.partID, "a part of its own, on the strip")
        #expect(SongPlayback.instrumentID(for: intro.lane.part, in: song) == other.id)
        #expect(SongPlayback.instrumentID(for: loop.chords.partID, in: song) == was, "the rest of the song on what it had")
        // Two samplers on the one strip, each with its own instrument.
        let plan = SongPlayback.plan(for: song, mediaURL: { _ in nil })
        let sounds = Set(LiveSongPlayer.samplerKeys(of: plan).filter { $0.family == .instrument && $0.part == loop.chords.partID }.compactMap(\.sound))
        #expect(sounds.contains(other.id) && sounds.count >= 2, "\(sounds)")
        // Set again everywhere, the intro keeps its own.
        _ = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"\#(was)","part":"\#(loop.chords.partID)","section":""}"#)
        song = try #require(rig.app.song)
        #expect(SongPlayback.instrumentID(for: intro.lane.part, in: song) == other.id)
    }

    @Test("set_mix and set_effects with a name move every section of it, and with an id one")
    func everySectionOfAName() async throws {
        let (rig, loop) = try rig()
        defer { rig.clean() }
        let both = await WritingFixture.run(rig.box, "set_mix",
            #"{"part":"\#(loop.bass.partID)","gain_db":-3,"band_hz":0,"band_db":0,"reason":"the bass down in the chorus","section":"hook"}"#)
        #expect(!both.isError, "\(both.content)")
        var song = try #require(rig.app.song)
        var mix = try #require(Guidance.mix(in: song))
        let hooks = song.sections.filter { $0.name == "Hook" }.map(\.id)
        #expect(hooks.allSatisfy { id in mix.sectionGains.contains { $0.section == id && $0.part == loop.bass.partID } }, "both hooks")
        let lastVerse = try #require(song.sections.last { $0.name == "Verse" })
        let one = await WritingFixture.run(rig.box, "set_mix",
            #"{"part":"\#(loop.bass.partID)","gain_db":2,"band_hz":0,"band_db":0,"reason":"the last verse up","section":"\#(lastVerse.id)"}"#)
        #expect(!one.isError, "\(one.content)")
        song = try #require(rig.app.song)
        mix = try #require(Guidance.mix(in: song))
        let verses = song.sections.filter { $0.name == "Verse" }.map(\.id)
        #expect(mix.sectionGains.contains { $0.section == lastVerse.id } && !mix.sectionGains.contains { $0.section == verses[0] })

        let echo = await WritingFixture.run(rig.box, "set_effects",
            #"{"part":"\#(loop.chords.partID)","insert":"keep","echo":"-12","section":"hook","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"echo in the chorus","pedal":"keep","modulation":"keep","filter":"keep","filter_hz":-1,"filter_to_hz":-1,"pump":"keep","pump_db":-1,"echo_tape":"keep"}"#)
        #expect(!echo.isError, "\(echo.content)")
        song = try #require(rig.app.song)
        mix = try #require(Guidance.mix(in: song))
        #expect(hooks.allSatisfy { id in mix.sectionEffect(for: loop.chords.partID, in: id)?.echoDB == -12 }, "both hooks")
    }
}
