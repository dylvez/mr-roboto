import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The keys player in the app: on the Chords surface, in the Director's hands, and in the song.

/// A host that keeps what it is handed, and says what it was asked to play.
@MainActor
private final class PlayingHost: ChordsHosting {
    var kept: [PartVersion] = []
    var heard: [Progression] = []
    var family = "keys"
    var instrument: String { "rhodes" }
    func audition(pitches: [Int], duration: Double) async {}
    func setInstrument(_ id: String, for part: PartID?) {}
    func commit(_ version: PartVersion) -> Bool { kept.append(version); return true }
    func newest(of part: PartID) -> PartVersion? { kept.last { $0.partID == part } }
    func audition(_ progression: Progression, for part: PartID?) async { heard.append(progression) }
    func instrumentFamily(for part: PartID?) -> String { family }
}

@Suite("Chords surface: how the chords are played") @MainActor
struct ChordsPlayingSurfaceTests {

    private func model(_ host: PlayingHost, text: String = "Cmaj9 | Em7 | Fmaj7 | Am7") -> ChordsModel {
        let model = ChordsModel(host: host, key: Key.cMajor)
        model.autoKeep.delay = nil
        model.text = text
        return model
    }

    @Test("the sheet reads the chords a lead sheet carries: ninths, thirteenths, sixths, altered dominants")
    func reads() {
        let model = model(PlayingHost(), text: "Dm9 G13 | Cmaj9 | C6/9 | E7#9 Am11")
        #expect(model.problem == nil)
        #expect(model.progression?.chords.map(\.quality) == [.minorNinth, .dominantThirteenth, .majorNinth, .sixNine, .sevenSharpNine, .minorEleventh])
        #expect(model.progression?.symbols() == "Dm9 G13 | Cmaj9 | C6/9 | E7#9 Am11")
        #expect(model.numeral(of: Chord(.d, .minorNinth)) == "ii9")
    }

    @Test("held and close until somebody says otherwise, and then kept with the chords")
    func playing() throws {
        let host = PlayingHost()
        let model = model(host)
        #expect(model.pattern == .held && model.voicing == .close)
        #expect(model.progression?.playing == nil, "chords nobody has chosen a playing for say nothing of one")
        #expect(model.keepNow())
        #expect(host.kept.count == 1)

        model.setVoicing(.led)
        #expect(model.progression?.playing == ChordPlaying(.held, .led))
        #expect(model.hasUnkeptChanges)
        model.setPattern(.pushes)
        let playing = try #require(model.progression?.playing)
        #expect(playing.keysPattern == .pushes && playing.keysVoicing == .led && playing.seed != 0)
        #expect(model.keepNow())
        #expect(host.kept.count == 2 && host.kept[1].partID == host.kept[0].partID)
        guard case .progression(let kept) = host.kept[1].kind else { Issue.record("not chords"); return }
        #expect(kept.playing == playing)
        #expect(host.kept[1].note == "Cmaj9 | Em7 | Fmaj7 | Am7 in C major: pushes, voice-led")

        // The line moves on; the player stays.
        model.text = "Cmaj9 | Em7 | Fmaj7 | G13"
        #expect(model.progression?.playing == playing)
        // Undo steps back through the playing as it does through the line.
        model.undo()
        model.undo()
        #expect(model.pattern == .held && model.voicing == .led)
        // Held and close again is nothing said.
        model.setVoicing(.close)
        #expect(model.progression?.playing == nil)
    }

    @Test("choosing a way of playing is heard at once, as the song will play it")
    func heard() async throws {
        let host = PlayingHost()
        let model = model(host)
        model.setPattern(.arpeggio)
        for _ in 0..<20 where host.heard.isEmpty { await Task.yield() }
        #expect(host.heard.last?.playing?.keysPattern == .arpeggio)
    }

    @Test("the sheet says the line on top, how far the voices move, and when a pattern will not be heard")
    func said() {
        let host = PlayingHost()
        let model = model(host)
        let close = model.movement
        model.setVoicing(.led)
        #expect(model.movement < close)
        #expect(model.topLine.components(separatedBy: " · ").count == 4)
        #expect(model.patternCaution == nil)
        host.family = "pad"
        model.setPattern(.stabs)
        #expect(model.patternCaution?.contains("swells") == true)
        model.setPattern(.held)
        #expect(model.patternCaution == nil)
    }

    @Test("chords kept with a playing open as they were played")
    func opens() {
        var sheet = try! Progression.parse("Am7 | Fmaj7", key: Key(parsing: "A minor")!).get()
        sheet.playing = ChordPlaying(.stabs, .spread, seed: 11)
        let version = PartVersion(partID: PartID(), kind: .progression(sheet), author: .user, operation: Operation.written, note: "Am7 Fmaj7")
        let model = ChordsModel(host: PlayingHost(), key: Key.cMajor, progression: version)
        #expect(model.pattern == .stabs && model.voicing == .spread)
        #expect(model.progression == sheet)
        #expect(!model.hasUnkeptChanges)
    }
}

@Suite("Director: play_chords", .serialized) @MainActor
struct PlayChordsToolTests {

    private func rig() async -> WritingFixture.Rig {
        let rig = WritingFixture.rig(Song.new(title: "Still Water", key: Key.cMajor, tempo: 72))
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Cmaj9 | Em7 | Fmaj7 | Am9","key":"C major"}"#)
        #expect(!chords.isError, "\(chords.content)")
        return rig
    }

    private func sheet(_ rig: WritingFixture.Rig) -> Progression? {
        guard let song = rig.app.song, case .progression(let sheet)? = Guidance.progressions(in: song).last?.kind else { return nil }
        return sheet
    }

    @Test("the chords a lead sheet carries are read, and a slash over a note the chord does not hold is said so")
    func ninths() async throws {
        let rig = await rig()
        defer { rig.clean() }
        #expect(sheet(rig)?.symbols() == "Cmaj9 | Em7 | Fmaj7 | Am9")
        let refused = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"C/D | G","key":"C major"}"#)
        #expect(refused.isError && refused.content.contains("has to be a note of the chord"), "\(refused.content)")
    }

    @Test("a pattern and a voicing are kept on the chords as their next version, and said back in notes")
    func plays() async throws {
        let rig = await rig()
        defer { rig.clean() }
        let before = try #require(rig.app.song?.versions.last { $0.type == .progression })
        let result = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"arpeggio","voicing":"led","seed":0}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["pattern"] as? String == "arpeggio" && out["voicing"] as? String == "led" && out["recorded"] as? Bool == true)
        #expect((out["seed"] as? Int ?? 0) > 0, "a hand nobody chose")
        #expect((out["top_line"] as? [String])?.count == 4)
        #expect((out["movement"] as? Double ?? 9) < 1.5)
        #expect(out["notes"] as? Int == 32, "eight to the bar over four bars")
        let kept = try #require(rig.app.song?.versions.last { $0.type == .progression })
        #expect(kept.partID == before.partID && kept.parents == [before.id])
        #expect(kept.author == .persona("Harmonist"))
        #expect(sheet(rig)?.playing?.keysPattern == .arpeggio)
        // The song plays them that way: the transport's chords are the arpeggio's notes.
        let playing = try #require(rig.app.playback.segments.first?.progression)
        #expect(Voicing.notes(for: playing).count == 32)

        // The same seed is the same hand.
        let seed = try #require(out["seed"] as? Int)
        let again = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"arpeggio","voicing":"led","seed":\#(seed)}"#)
        #expect(WritingFixture.json(again)["seed"] as? Int == seed)
    }

    @Test("new chords keep the player they had")
    func keepsThePlayer() async throws {
        let rig = await rig()
        defer { rig.clean() }
        _ = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"pushes","voicing":"rootless","seed":7}"#)
        let restated = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm9 | G13 | Cmaj9 | A7b9","key":"C major"}"#)
        #expect(!restated.isError, "\(restated.content)")
        #expect(sheet(rig)?.symbols() == "Dm9 | G13 | Cmaj9 | A7b9")
        #expect(sheet(rig)?.playing == ChordPlaying(.pushes, .rootless, seed: 7))
    }

    @Test("a short pattern on an instrument that swells is said, and what is not a pattern is refused")
    func cautions() async throws {
        let rig = await rig()
        defer { rig.clean() }
        let part = try #require(rig.app.song?.versions.last { $0.type == .progression }).partID
        #expect(rig.app.setInstrument("air-pad", for: part))
        let stabs = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"stabs","voicing":"close","seed":0}"#)
        #expect((WritingFixture.json(stabs)["detail"] as? String)?.contains("swells into a note") == true, "\(stabs.content)")
        let montuno = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"montuno","voicing":"close","seed":0}"#)
        #expect(montuno.isError && montuno.content.contains("stabs"), "\(montuno.content)")
        let quartal = await WritingFixture.run(rig.box, "play_chords", #"{"progression":"","pattern":"held","voicing":"quartal","seed":0}"#)
        #expect(quartal.isError && quartal.content.contains("rootless"))
        let empty = WritingFixture.rig(Song.new(title: "Empty"))
        defer { empty.clean() }
        let none = await WritingFixture.run(empty.box, "play_chords", #"{"progression":"","pattern":"held","voicing":"close","seed":0}"#)
        #expect(none.isError && none.content.contains("set_progression"))
    }

    @Test("the tool is the forty-seventh, has a sentence in the rail, and the prompt says when to reach for it")
    func told() throws {
        #expect(DirectorTools.names.last == "play_chords" && DirectorTools.names.count == 47)
        #expect(DirectorSession.activity(for: "play_chords") == "Playing the chords…")
        #expect(DirectorPrompt.system.contains("play_chords"))
    }
}

@Suite("The band asks what next: how the chords are played", .serialized) @MainActor
struct PlayingNextTests {

    private func song(playing: ChordPlaying?, bass: Bool = true) throws -> Song {
        var sheet = try Progression.parse("Am7 | Fmaj7 | Dm7 | E7", key: Key(parsing: "A minor")!).get()
        sheet.playing = playing
        var song = TransportFixture.song([TransportFixture.grooveVersion()], sections: [])
        if bass {
            try song.append(PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 45), start: 0, duration: 1)])),
                                        author: .user, operation: Operation.written, note: "Roots"))
        }
        try song.append(PartVersion(partID: PartID(), kind: .progression(sheet), author: .user, operation: Operation.written, note: "Am7 Fmaj7 Dm7 E7"))
        return song
    }

    @Test("chords just kept, held, over a beat: playing them is offered, and it is the Harmonist's to ask")
    func offered() throws {
        let (app, directory, _) = CompletenessFixture.app("next-playing")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(try song(playing: nil))
        let question = app.nextQuestion
        let option = try #require(question.options.first { $0.kind == "playing" }, "\(question.options.map(\.kind))")
        #expect(option.title == "Play the chords")
        #expect(NextAdvisor.owner(of: "playing") == "Harmonist")
        #expect(NextAdvisor.phrase(option) == "play the chords")
        guard case .surface(let action) = option.move else { Issue.record("not a surface"); return }
        #expect(action.surface == .chords && action.bound.count == 1)
        #expect(NextAdvisor.observe("playing", in: try #require(app.song), app: app).contains("is held"))
        // Taking it opens the Chords surface on those chords; with it open, it is not asked again.
        app.take(option, from: question)
        #expect(app.bench.active?.kind == .chords)
        #expect(!app.nextQuestion.options.contains { $0.kind == "playing" })
    }

    @Test("chords somebody has chosen a playing for are not asked about")
    func notAskedTwice() throws {
        let (app, directory, _) = CompletenessFixture.app("next-played")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(try song(playing: ChordPlaying(.offbeats, .led, seed: 3)))
        #expect(!app.nextQuestion.options.contains { $0.kind == "playing" })
        #expect(NextAdvisor.observe("playing", in: try #require(app.song), app: app).contains("is played off-beats, voice-led"))
    }
}

@Suite("Director: a bass line is as long as its chords", .serialized) @MainActor
struct BassUnderTheChordsTests {

    @Test("an imported instrument is offered to the bass by the word: a bass, a contrabass, a tuba, never a bassoon")
    func calledABass() {
        func spec(_ name: String, family: String = ImportedInstruments.family) -> InstrumentVoiceSpec {
            InstrumentVoiceSpec(id: "sfz-x", name: name, family: family, engine: .sampled, summary: "")
        }
        #expect(PianoRollModel.isCalledABass(spec("Jazz Bass")))
        #expect(PianoRollModel.isCalledABass(spec("Contrabass Pizzicato")))
        #expect(PianoRollModel.isCalledABass(spec("Tuba, Brass Band")))
        #expect(PianoRollModel.isCalledABass(spec("Double Bass, Late Night")))
        #expect(PianoRollModel.isCalledABass(spec("Big Little", family: "bass")))
        #expect(!PianoRollModel.isCalledABass(spec("Bassoon")))
        #expect(!PianoRollModel.isCalledABass(spec("Cello Section")))
    }

    @Test("four bars of chords over a two-bar break get four bars of bass, a root under every chord")
    func asLongAsTheChords() async throws {
        let rig = WritingFixture.rig(nil)
        defer { rig.clean() }
        _ = await WritingFixture.run(rig.box, "start_song", #"{"title":"Tidewater","tempo":78,"key":"E minor","machine":"vintage"}"#)
        let beat = WritingFixture.json(await WritingFixture.run(rig.box, "write_groove",
            #"{"feel":"Trip-Hop","bars":2,"swing_percent":0,"rows":[],"note":"A break","steps_per_bar":0,"parent":""}"#))
        let groove = try #require(beat["version"] as? String)
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Em9 | Cmaj7#11 | Am9 | B7b9","key":"E minor"}"#)
        #expect(!chords.isError)
        let result = await WritingFixture.run(rig.box, "write_bassline",
            #"{"groove":"\#(groove)","hands":"palladino","lag_ms":35,"density":0.45,"seed":7}"#)
        #expect(!result.isError, "\(result.content)")
        let song = try #require(rig.app.song)
        guard case .bassline(let line)? = Guidance.basslines(in: song).last?.kind else { Issue.record("no line"); return }
        #expect(line.lengthInBars == 4)
        // What sounds on the first beat of each bar is that bar's root: E, C, A, B.
        let roots = [4, 0, 9, 11]
        for (bar, root) in roots.enumerated() {
            let first = try #require(line.notes.first { $0.start >= Double(bar * 4) - 0.01 && $0.start < Double(bar * 4) + 0.5 }, "bar \(bar + 1)")
            #expect(first.pitch.midi % 12 == root, "bar \(bar + 1): \(first.pitch)")
        }
        // Read a bar at a time, not as twice as busy as it is.
        let said = (WritingFixture.json(result)["readings"] as? [String] ?? []).joined(separator: " ")
        #expect(said.contains("attacks a bar"))
        #expect(!(WritingFixture.json(result)["flags"] as? [String] ?? []).contains { $0.contains("attacks a bar") }, "\(said)")

        // Chords no longer than the groove, and none at all, are the groove's length as before.
        #expect(WriteBasslineTool.bars(under: [], over: Groove(bars: 2, patterns: []), in: .fourFour) == nil)
        let two = try Progression.parse("Em9 | Cmaj7", key: Key(parsing: "E minor")!).get().spans
        #expect(WriteBasslineTool.bars(under: two, over: Groove(bars: 2, patterns: []), in: .fourFour) == nil)
        let three = try Progression.parse("Em9 | Cmaj7 | Am9", key: Key(parsing: "E minor")!).get().spans
        #expect(WriteBasslineTool.bars(under: three, over: Groove(bars: 2, patterns: []), in: .fourFour) == 4)
    }
}
