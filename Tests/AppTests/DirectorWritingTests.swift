import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The band's new hands: a tune and words written in the Melodist's and the Lyricist's names and
// read back by them, the song's settings, an instrument, the takes comped, another song opened.
// Every success runs through a real `AppState` over a temporary library where the frame is what
// the tool meets; the comp is also planned apart from any audio, and rendered once in memory.

@MainActor
private enum WritingFixture {
    struct Rig {
        var app: AppState
        var box: DirectorToolbox
        var directory: URL
        func clean() { WiringFixture.remove(directory) }
    }

    static func rig(_ song: Song? = Song.new(title: "Arrival", key: Key(tonic: NoteName(.d), mode: .aeolian), tempo: 96),
                    library: Library = Library()) -> Rig {
        let directory = WiringFixture.temporaryDirectory("writing")
        let app = AppState(library: library, song: nil, store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        if let song { app.open(song) }
        return Rig(app: app, box: toolbox(AppStateWorkspace(app)), directory: directory)
    }

    static func toolbox(_ workspace: any DirectorWorkspace) -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()), workspace: workspace,
                              audition: DirectorSilentAudition())
    }

    static func run(_ box: DirectorToolbox, _ tool: String, _ json: String) async -> ClaudeToolResult {
        let input = (try? DirectorJSON.parse(Data(json.utf8))) ?? .object([])
        return await box.run(ClaudeToolUse(id: "t", name: tool, input: input))
    }

    static func json(_ result: ClaudeToolResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

// MARK: - The six, appended

@Suite("Director: writing's six are appended after write_groove") @MainActor
struct DirectorWritingToolboxTests {

    static let six = ["write_melody", "write_lyrics", "set_song", "set_instrument", "comp_takes", "open_song"]

    @Test("the six come after write_groove, in order, and none of them spends the optional budget")
    func appended() {
        let names = DirectorTools.names
        #expect(Array(names.suffix(6)) == Self.six)
        #expect(names[names.count - 7] == "write_groove", "appended after the last tool, never among the earlier ones")
        let box = WritingFixture.toolbox(DirectorScratchWorkspace(song: DirectorSongFixture.song()))
        #expect(box.names == names)
        for name in Self.six {
            guard let tool = box.tool(named: name), case .object(let properties)? = tool.definition.inputSchema["properties"] else {
                Issue.record("\(name) has no schema")
                continue
            }
            let required = tool.definition.inputSchema["required"]?.arrayValue?.count ?? -1
            #expect(required == properties.keys.count, "\(name): every parameter required, empty or 0 for none")
            #expect(DirectorSession.activity(for: name) != "\(name)…", "\(name) has a sentence in the rail")
        }
    }

    @Test("the prompt tells the Director it writes for the Melodist and the Lyricist, sets the song first, comps after the Booth, and moves between songs")
    func prompt() {
        let prompt = DirectorPrompt.system
        for phrase in ["write_melody", "on the Melodist's and the Lyricist's behalf", "write_lyrics", "align_to \"newest\"",
                       "the song is set first", "set_song for the open one", "set_instrument",
                       "After the Booth, when the user has sung two takes", "comp_takes", "open_song"] {
            #expect(prompt.contains(phrase), "\(phrase)")
        }
        #expect(prompt.hasSuffix("the ledger and the rail if they want them."), "Answer short is still the last paragraph")
    }
}

// MARK: - write_melody

@Suite("Director: write_melody", .serialized) @MainActor
struct DirectorWriteMelodyTests {

    @Test("a line of notes is read as pitch, start and beats; fractions, velocity and MIDI numbers too")
    func parsing() throws {
        let notes = try WriteMelodyTool.parse("D4 0 1, F#4 1 0.5; Bb3 1.5 1/3 110\nA4 2 2", tool: "write_melody")
        #expect(notes.map(\.pitch.midi) == [62, 66, 58, 69])
        #expect(notes.map(\.start) == [0, 1, 1.5, 2])
        #expect(abs(notes[2].duration - 1.0 / 3.0) < 1e-9 && notes[2].velocity == 110 && notes[0].velocity == 100)
        #expect(try WriteMelodyTool.parse("62 0 1", tool: "t").first?.pitch.midi == 62)
        for bad in ["", "D4 0", "X9 0 1", "D4 -1 1", "D4 0 0", "D4 0 1 200", "D4 zero 1"] {
            #expect(throws: DirectorToolFailure.self, "\"\(bad)\"") { try WriteMelodyTool.parse(bad, tool: "write_melody") }
        }
        do {
            _ = try WriteMelodyTool.parse("D4 0 1, H4 1 1", tool: "write_melody")
            Issue.record("H4 parsed")
        } catch let failure as DirectorToolFailure {
            #expect(failure.reason.contains("Note 2") && failure.reason.contains("H4"))
            #expect(failure.suggestion?.contains("\"D4 0 1, F4 1 0.5, A4 1.5 1.5\"") == true, "the refusal shows the format")
        }
    }

    @Test("the tune is recorded as the Melodist's, read over the chords, and put on the instrument named")
    func writes() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm7 | Gm7 | A7 | Dm7","key":"D minor"}"#)
        #expect(!chords.isError, "\(chords.content)")

        let result = await WritingFixture.run(rig.box, "write_melody", #"""
            {"notes":"D4 0 1, F4 1 1, A4 2 1, G4 3 1, F4 4 1, G4 5 1, A4 6 2, D4 8 1, F4 9 1, A4 10 1, G4 11 1, E4 12 2, D4 14 1",
             "bars":4,"instrument":"lead","parent":"","note":"The verse tune"}
            """#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["note_count"] as? Int == 13 && out["bars"] as? Int == 4 && out["recorded"] as? Bool == true)
        #expect((out["chords"] as? String)?.hasPrefix("read over Dm7") == true, "\(out["chords"] ?? "")")
        #expect(out["key"] as? String == "D minor" && out["instrument"] as? String == "Square Lead")
        #expect((out["range"] as? String)?.hasPrefix("D4–A4") == true, "\(out["range"] ?? "")")
        #expect((out["readings"] as? [String])?.count ?? 0 >= 4, "the Melodist read range, leap, steps, chords and figure")

        let song = try #require(rig.app.song)
        let version = try #require(song.versions.last { $0.type == .melody })
        #expect(version.author == .persona("Melodist") && version.operation == Operation.written && version.note == "The verse tune")
        guard case .melody(let melody) = version.kind else { Issue.record("not a melody"); return }
        #expect(melody.lengthInBars == 4 && melody.notes.count == 13)
        #expect(SongPlayback.instrumentID(for: version.partID, in: song) == "lead", "this tune on the lead, not the song's")
        #expect(out["version"] as? String == version.id.description)

        // A rewrite is the next version of the same part.
        let again = await WritingFixture.run(rig.box, "write_melody", #"""
            {"notes":"D4 0 1, E4 1 1, F4 2 1, A4 3 1","bars":0,"instrument":"","parent":"\#(version.id.description)","note":""}
            """#)
        #expect(!again.isError, "\(again.content)")
        let rewritten = try #require(rig.app.song?.versions.last { $0.type == .melody })
        #expect(rewritten.partID == version.partID && rewritten.parents == [version.id])
        #expect(rewritten.note == "Tune, 1 bar, D4–A4", "an empty note names it by its range")
    }

    @Test("what the Melodist flags is said in the rail in its own name")
    func flagsInTheRail() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "write_melody",
                                              #"{"notes":"C4 0 1, C6 1 1","bars":0,"instrument":"","parent":"","note":"A leap"}"#)
        #expect(!result.isError, "\(result.content)")
        let flags = WritingFixture.json(result)["flags"] as? [String] ?? []
        #expect(flags.contains { $0.contains("24 semitones") }, "\(flags)")
        // The rail also says the Melodist kept the tune ("Written → melody"); the flags are the rest.
        let said = rig.app.log.filter { $0.source == .persona("Melodist") && !$0.text.contains(" → ") }.map(\.text)
        #expect(said.count == flags.count && !said.isEmpty, "\(said)")
        #expect(rig.app.log.contains { $0.source == .persona("Melodist") && $0.text.hasPrefix("Written → melody") }, "kept in its own name")
    }

    @Test("refused: notes past the bars, an instrument that is not one, a parent that is not a melody, and no song")
    func refusals() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let past = await WritingFixture.run(rig.box, "write_melody", #"{"notes":"D4 0 1, A4 8 1","bars":2,"instrument":"","parent":"","note":""}"#)
        #expect(past.isError && past.content.contains("past the end of 2 bars"), "\(past.content)")
        let kazoo = await WritingFixture.run(rig.box, "write_melody", #"{"notes":"D4 0 1","bars":0,"instrument":"kazoo","parent":"","note":""}"#)
        #expect(kazoo.isError && kazoo.content.contains("rhodes"), "\(kazoo.content)")
        let bad = await WritingFixture.run(rig.box, "write_melody", #"{"notes":"D4 0 1, Q4 1 1","bars":0,"instrument":"","parent":"","note":""}"#)
        #expect(bad.isError && bad.content.contains("D4 0 1, F4 1 0.5"), "\(bad.content)")
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm7","key":"D minor"}"#)
        let chordID = WritingFixture.json(chords)["version"] as? String ?? ""
        let wrong = await WritingFixture.run(rig.box, "write_melody", #"{"notes":"D4 0 1","bars":0,"instrument":"","parent":"\#(chordID)","note":""}"#)
        #expect(wrong.isError && wrong.content.contains("not a melody"), "\(wrong.content)")
        #expect(rig.app.song?.versions.contains { $0.type == .melody } == false, "nothing refused was recorded")

        let empty = WritingFixture.toolbox(DirectorScratchWorkspace(song: nil))
        let none = await WritingFixture.run(empty, "write_melody", #"{"notes":"D4 0 1","bars":0,"instrument":"","parent":"","note":""}"#)
        #expect(none.isError && none.content.contains("start_song"))
    }
}

// MARK: - write_lyrics

@Suite("Director: write_lyrics", .serialized) @MainActor
struct DirectorWriteLyricsTests {

    static let words = """
        [Verse]
        I walked the long way home tonight
        the streetlights humming low
        and every window held a light
        for someone I don't know

        [Hook]
        stay with me
        the night is ours to keep
        """

    @Test("the words are the Lyricist's, read back with a scheme per stanza, and set to the newest tune")
    func writes() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let tune = await WritingFixture.run(rig.box, "write_melody", #"""
            {"notes":"D4 0 1, F4 1 1, A4 2 1, G4 3 1, F4 4 1, E4 5 1, D4 6 2, A4 8 1, G4 9 1, F4 10 1, E4 11 1, D4 12 4",
             "bars":4,"instrument":"","parent":"","note":"Verse tune"}
            """#)
        let melodyID = try #require(WritingFixture.json(tune)["version"] as? String)

        let text = Self.words.replacingOccurrences(of: "\n", with: "\\n")
        let result = await WritingFixture.run(rig.box, "write_lyrics", #"{"text":"\#(text)","align_to":"newest"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["lines"] as? Int == 6 && out["recorded"] as? Bool == true)
        let stanzas = out["stanzas"] as? [[String: Any]] ?? []
        #expect(stanzas.map { $0["label"] as? String } == ["Verse", "Hook"])
        #expect(stanzas.map { $0["lines"] as? Int } == [4, 2])
        #expect(stanzas.allSatisfy { ($0["scheme"] as? String)?.count == $0["lines"] as? Int }, "\(stanzas)")
        #expect(out["melody"] as? String == melodyID && out["melody_notes"] as? Int == 12)
        let syllables = try #require(out["syllables"] as? Int)
        #expect(syllables > 12 && out["syllables_set"] as? Int == 12, "one syllable a note, the rest unset")
        #expect((out["detail"] as? String)?.contains("12 of \(syllables) syllables have a note") == true, "\(out["detail"] ?? "")")
        #expect(!(out["readings"] as? [String] ?? []).isEmpty)

        let song = try #require(rig.app.song)
        let version = try #require(song.versions.last { $0.type == .lyric })
        #expect(version.author == .persona("Lyricist") && version.operation == Operation.written)
        #expect(version.note?.hasPrefix("Verse and Hook, 6 lines") == true, "\(version.note ?? "")")
        guard case .lyric(let lyric) = version.kind else { Issue.record("not a lyric"); return }
        #expect(lyric.alignedTo?.description == melodyID && lyric.labels?.map(\.name) == ["Verse", "Hook"])
        let said = rig.app.log.filter { $0.source == .persona("Lyricist") && !$0.text.contains(" → ") }.count
        #expect(said == (out["flags"] as? [String] ?? []).count, "the Lyricist's flags are said in its name")

        // New words are the next version of the song's lyric, not a second lyric.
        let again = await WritingFixture.run(rig.box, "write_lyrics", #"{"text":"the long way home\nthe lights are low","align_to":""}"#)
        #expect(!again.isError, "\(again.content)")
        let lyrics = rig.app.song?.versions.filter { $0.type == .lyric } ?? []
        #expect(lyrics.count == 2 && lyrics[1].partID == lyrics[0].partID && lyrics[1].parents == [lyrics[0].id])
        #expect(WritingFixture.json(again)["syllables_set"] as? Int == 0 && WritingFixture.json(again)["melody"] == nil)
    }

    @Test("refused: no words, no melody to set them to, and a version that is not a melody")
    func refusals() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let blank = await WritingFixture.run(rig.box, "write_lyrics", #"{"text":"[Hook]\n\n","align_to":""}"#)
        #expect(blank.isError && blank.content.contains("no words"), "\(blank.content)")
        let noTune = await WritingFixture.run(rig.box, "write_lyrics", #"{"text":"one line\ntwo lines","align_to":"newest"}"#)
        #expect(noTune.isError && noTune.content.contains("write_melody"), "\(noTune.content)")
        let chords = await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm7","key":"D minor"}"#)
        let chordID = WritingFixture.json(chords)["version"] as? String ?? ""
        let notTune = await WritingFixture.run(rig.box, "write_lyrics", #"{"text":"one line\ntwo lines","align_to":"\#(chordID)"}"#)
        #expect(notTune.isError && notTune.content.contains("not a melody"), "\(notTune.content)")
        #expect(rig.app.song?.versions.contains { $0.type == .lyric } == false)
    }
}

@Suite("Director: convene reads words on the tune they are set to") @MainActor
struct DirectorConveneWordsTests {

    @Test("an aligned lyric is read against its melody, so a stress off the beat is flagged in the room")
    func stressOnTheTune() async throws {
        var song = Song(title: "Arrival", key: Key(tonic: NoteName(.d)), tempo: 96)
        // Every note on an "and": wherever a stressed syllable lands, it lands off the beat.
        let tune = Melody(notes: (0..<12).map { NoteEvent(pitch: Pitch(midi: 62 + $0 % 5), start: Double($0) + 0.5, duration: 0.4) })
        let melody = PartVersion(partID: PartID(), kind: .melody(tune), author: .persona("Melodist"), operation: Operation.written, note: "Offbeat tune")
        try song.append(melody)
        let words = Lyricist.lyric(from: "hello to the morning\nthe window is open").aligned(to: tune, version: melody.id)
        try song.append(PartVersion(partID: PartID(), kind: .lyric(words), author: .persona("Lyricist"), operation: Operation.written, note: "Words"))

        let result = await WritingFixture.run(WritingFixture.toolbox(DirectorScratchWorkspace(song: song)), "convene",
                                              #"{"question":"do the words sit on the tune?","section":"","personas":["lyricist"]}"#)
        #expect(!result.isError, "\(result.content)")
        let readings = WritingFixture.json(result)["readings"] as? [[String: Any]] ?? []
        let stress = readings.first { $0["rule"] as? String == "lyricist.stressed-on-strong" }
        #expect(stress?["holds"] as? Bool == false, "\(readings.map { $0["rule"] ?? "" })")
        #expect((stress?["says"] as? String)?.contains("the and of") == true, "\(stress?["says"] ?? "")")
    }
}

// MARK: - set_song

@Suite("Director: set_song", .serialized) @MainActor
struct DirectorSetSongTests {

    @Test("title, artist, tempo, key and meter go through the frame's setters, and say what changed")
    func sets() async throws {
        let rig = WritingFixture.rig(Song.new(title: "Untitled", tempo: 120))
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "set_song",
                                              #"{"title":"Night Bus","artist":"Vessel","tempo":92,"key":"Dm","time_signature":"3/4"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        let song = try #require(rig.app.song)
        #expect(song.title == "Night Bus" && song.artist == "Vessel" && song.tempo == 92)
        #expect(song.key == Key(tonic: NoteName(.d), mode: .aeolian) && song.timeSignature == TimeSignature(3, 4))
        #expect((out["changed"] as? [String])?.count == 5 && (out["refused"] as? [Any])?.isEmpty == true, "\(out)")
        #expect(out["key"] as? String == "D minor" && out["time_signature"] as? String == "3/4" && out["tempo"] as? Double == 92)
        #expect(rig.app.library.song(song.id)?.title == "Night Bus", "the sidebar follows the title")
        #expect(rig.app.hasUnsavedChanges)

        // "none" clears the key; the same title is unchanged rather than an error.
        let cleared = WritingFixture.json(await WritingFixture.run(rig.box, "set_song",
                                                                   #"{"title":"Night Bus","artist":"","tempo":0,"key":"none","time_signature":""}"#))
        #expect(rig.app.song?.key == nil && cleared["unchanged"] as? [String] == ["title"])
    }

    @Test("a key that does not parse, a tempo out of range and a meter that is not one are refused; the rest still lands")
    func refusals() async throws {
        let rig = WritingFixture.rig(Song.new(title: "Untitled", tempo: 120))
        defer { rig.clean() }
        let result = await WritingFixture.run(rig.box, "set_song",
                                              #"{"title":"Arrival","artist":"","tempo":500,"key":"H minor","time_signature":"7/5"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        let refused = (out["refused"] as? [[String: Any]] ?? []).compactMap { $0["field"] as? String }
        #expect(Set(refused) == ["tempo", "key", "time_signature"], "\(out)")
        #expect((out["detail"] as? String)?.contains("500 bpm is outside 20 to 300") == true, "\(out["detail"] ?? "")")
        #expect(rig.app.song?.title == "Arrival" && rig.app.song?.tempo == 120 && rig.app.song?.key == nil)
        #expect(rig.app.song?.timeSignature == .fourFour)

        let nothing = await WritingFixture.run(rig.box, "set_song", #"{"title":"","artist":"","tempo":0,"key":"","time_signature":""}"#)
        #expect(nothing.isError && nothing.content.contains("Nothing was asked"))
        let closed = await WritingFixture.run(WritingFixture.toolbox(DirectorScratchWorkspace(song: nil)), "set_song",
                                              #"{"title":"X","artist":"","tempo":0,"key":"","time_signature":""}"#)
        #expect(closed.isError && closed.content.contains("open_song"))
    }
}

// MARK: - set_instrument

@Suite("Director: set_instrument", .serialized) @MainActor
struct DirectorSetInstrumentTests {

    @Test("the song's own instrument, then one part's, and what each now plays")
    func sets() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let chords = WritingFixture.json(await WritingFixture.run(rig.box, "set_progression", #"{"chords":"Dm7 | Gm7","key":"D minor"}"#))
        let tune = WritingFixture.json(await WritingFixture.run(rig.box, "write_melody",
                                                                #"{"notes":"D4 0 1, F4 1 1, A4 2 2","bars":0,"instrument":"","parent":"","note":"Hook tune"}"#))
        let melodyID = try #require(tune["version"] as? String)
        let chordID = try #require(chords["version"] as? String)

        let pad = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"pad","part":""}"#)
        #expect(!pad.isError, "\(pad.content)")
        let padOut = WritingFixture.json(pad)
        #expect(padOut["name"] as? String == "Warm Pad" && padOut["target"] as? String == "the song" && padOut["changed"] as? Bool == true)
        #expect((padOut["plays"] as? [String])?.count == 2, "the chords and the tune both play on the song's own")

        let lead = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"lead","part":"\#(melodyID)"}"#)
        let leadOut = WritingFixture.json(lead)
        #expect(!lead.isError && leadOut["target"] as? String == "Hook tune" && leadOut["plays"] as? [String] == ["Hook tune"], "\(lead.content)")
        let song = try #require(rig.app.song)
        let melodyPart = try #require(song.version(VersionID(uuidString: melodyID)!)).partID
        let chordPart = try #require(song.version(VersionID(uuidString: chordID)!)).partID
        #expect(SongPlayback.instrumentID(for: melodyPart, in: song) == "lead")
        #expect(SongPlayback.instrumentID(for: chordPart, in: song) == "pad")

        let same = WritingFixture.json(await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"lead","part":"\#(melodyID)"}"#))
        #expect(same["changed"] as? Bool == false && (same["detail"] as? String)?.contains("already") == true)
    }

    @Test("refused: a preset the app does not have, an id that is nothing, and a part that does not play on these")
    func refusals() async throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let groove = PartVersion(partID: PartID(), kind: .groove(FeelLibrary.standard.feels[0].groove), author: .persona("Beatmaker"),
                                 operation: Operation.written, note: "Beat")
        #expect(rig.app.record(groove))
        let kazoo = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"kazoo","part":""}"#)
        #expect(kazoo.isError && kazoo.content.contains("rhodes (Rhodes)"), "\(kazoo.content)")
        let nothing = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"pad","part":"\#(UUID().uuidString)"}"#)
        #expect(nothing.isError && nothing.content.contains("read_song"), "\(nothing.content)")
        let drums = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"pad","part":"\#(groove.id.description)"}"#)
        #expect(drums.isError && drums.content.contains("drum machine"), "\(drums.content)")
        #expect(rig.app.song?.versions.contains { $0.type == .sound } == false, "nothing refused was recorded")
    }
}

// MARK: - comp_takes

/// Two bars sung at 120 in D: D F♯ A D in each, every note on its beat. One note can be sung
/// 31 cents sharp, which the pitch-drift critic flags on its bar and nothing else does.
enum CompFixture {
    static let rate = 48_000.0
    static let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)

    static func sung(sharpInBar: Int?, bars: Int = 2) -> [[Float]] {
        let length = Int(Double(bars) * 2 * rate)
        var out = [Float](repeating: 0, count: length)
        for bar in 0..<bars {
            for (index, midi) in [62.0, 66.0, 69.0, 62.0].enumerated() {
                let pitch = bar == sharpInBar && index == 1 ? midi + 0.31 : midi
                let hz = 440 * pow(2, (pitch - 69) / 12)
                let start = Int((Double(bar) * 2 + Double(index) * 0.5) * rate), n = Int(0.4 * rate)
                let ramp = Int(0.01 * rate)
                var phase = 0.0
                for i in 0..<n where start + i < length {
                    phase += 2 * .pi * hz / rate
                    var env = 1.0
                    if i < ramp { env = Double(i) / Double(ramp) }
                    if n - i < ramp { env = Double(n - i) / Double(ramp) }
                    out[start + i] += Float(0.3 * env * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)))
                }
            }
        }
        return [out]
    }

    static func song() -> Song {
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 2)]
        return song
    }

    static func take(_ pass: Int, part: PartID, section: SectionID, media: MediaRef) -> PartVersion {
        let audio = Audio(media: media, role: .take, sampleRate: rate, channelCount: 1, duration: 4, alignmentOffset: 0,
                          take: Take(section: section, startBar: 0, input: "Stub mic", pass: pass))
        return PartVersion(partID: part, kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take \(pass), Verse")
    }

    static func media(_ digit: Character) -> MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: digit, count: 64))!, fileExtension: "wav")
    }
}

@Suite("Director: comp_takes", .serialized) @MainActor
struct DirectorCompTakesTests {

    @Test("each bar comes from the take flagged least there; a tie goes to the later pass; silence never wins a sung bar")
    func planning() {
        let one = VersionID(), two = VersionID(), three = VersionID()
        let everything: Set<Int> = [4, 5, 6, 7]
        let candidates = [
            CompPlanner.Candidate(take: one, flags: [5: 2], sung: everything, covers: everything),
            CompPlanner.Candidate(take: two, flags: [4: 1, 5: 1], sung: everything, covers: everything),
            // Clean everywhere, because it stopped singing after bar 5.
            CompPlanner.Candidate(take: three, flags: [4: 1], sung: [4, 5], covers: [4, 5]),
        ]
        let choices = CompPlanner.choose(bars: 4..<8, from: candidates)
        #expect(choices[4] == one, "fewest flags")
        #expect(choices[5] == three, "fewest flags among the three that sang it")
        #expect(choices[6] == two, "a tie between the two that sang goes to the later pass, never to the take that was silent")
        #expect(choices[7] == two)
        let plan = CompPlanner.plan(choices, bars: 4..<8)
        #expect(plan.spans.map(\.startBar) == [4, 5, 6] && plan.spans.map(\.endBar) == [5, 6, 8])
        let names: [VersionID: String] = [one: "Take 1", two: "Take 2", three: "Take 3"]
        #expect(CompPlanner.describe(plan, name: { names[$0]! }) == ["bar 5 Take 1", "bar 6 Take 3", "bars 7–8 Take 2"])

        // A bar nobody sang falls back to the takes that cover it, then to anyone, latest first.
        let rest = CompPlanner.choose(bars: 0..<2, from: [
            CompPlanner.Candidate(take: one, flags: [:], sung: [], covers: [0]),
            CompPlanner.Candidate(take: two, flags: [:], sung: [], covers: []),
        ])
        #expect(rest[0] == one && rest[1] == two)
    }

    @Test("two takes, each sharp in a different bar: the comp takes the clean bar of each and records it with both underneath")
    func compsInMemory() async throws {
        var song = CompFixture.song()
        let part = PartID(), section = song.sections[0].id
        let first = CompFixture.take(1, part: part, section: section, media: CompFixture.media("a"))
        let second = CompFixture.take(2, part: part, section: section, media: CompFixture.media("b"))
        try song.append(first)
        try song.append(second)
        let workspace = DirectorScratchWorkspace(song: song)
        workspace.takeAudio[first.id] = Comp.TakeAudio(planar: CompFixture.sung(sharpInBar: 1), sampleRate: CompFixture.rate, alignmentSeconds: 0)
        workspace.takeAudio[second.id] = Comp.TakeAudio(planar: CompFixture.sung(sharpInBar: 0), sampleRate: CompFixture.rate, alignmentSeconds: 0)

        let result = await WritingFixture.run(WritingFixture.toolbox(workspace), "comp_takes", #"{"takes":"verse"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(out["plan"] as? [String] == ["bar 1 Take 1", "bar 2 Take 2"], "\(out)")
        #expect(out["section"] as? String == "Verse" && out["bars"] as? String == "bars 1–2")
        let avoided = out["flags_avoided"] as? [String] ?? []
        #expect(avoided.count == 2 && avoided.contains { $0.hasPrefix("Take 2: Bar 1") } && avoided.contains { $0.hasPrefix("Take 1: Bar 2") }, "\(avoided)")
        #expect((out["flags_kept"] as? [String])?.isEmpty == true)

        let comp = try #require(workspace.song?.versions.last)
        #expect(comp.operation == Operation.comped && comp.author == .persona("Director") && comp.partID == part)
        #expect(comp.parents == [first.id, second.id])
        #expect(comp.note == "Comp of 2 takes: bar 1 Take 1, bar 2 Take 2")
        let audio = try #require(Guidance.audio(of: comp))
        #expect(audio.comp?.spans.map(\.take) == [first.id, second.id] && audio.take == nil)
        let kept = try #require(workspace.kept[audio.media])
        #expect(kept.first?.count == Int(4 * CompFixture.rate), "two bars at 120, rendered")
        #expect(workspace.notes.contains { $0.text.hasPrefix("Comped the Verse: bar 1 Take 1") })
    }

    @Test("in the app: the comp's audio is kept in the song's package, and it reads clean where each take did not")
    func compsInTheApp() async throws {
        let directory = WiringFixture.temporaryDirectory("comp-takes")
        defer { WiringFixture.remove(directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        let song = CompFixture.song()
        app.open(song)
        app.save()
        let package = try store.songStore(for: song.id)
        let part = PartID()
        var takes: [PartVersion] = []
        for (pass, sharp) in [(1, 1), (2, 0)] {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sung-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try BoothAdapter.write(CompFixture.sung(sharpInBar: sharp), sampleRate: CompFixture.rate, to: scratch)
            let take = CompFixture.take(pass, part: part, section: song.sections[0].id, media: try package.addMedia(copying: scratch))
            #expect(app.record(take))
            takes.append(take)
        }

        let box = WritingFixture.toolbox(AppStateWorkspace(app))
        let result = await WritingFixture.run(box, "comp_takes", #"{"takes":"\#(takes[0].id.description)"}"#)
        #expect(!result.isError, "\(result.content)")
        let comp = try #require(app.song?.versions.last)
        #expect(comp.operation == Operation.comped && comp.parents == takes.map(\.id))
        let audio = try #require(Guidance.audio(of: comp))
        #expect(package.hasMedia(audio.media), "kept in the package, beside the takes")
        let rendered = try BoothAdapter.planar(try store.mediaURL(for: audio.media, song: song.id))
        let analysis = TakeAnalysis.of(rendered.planar, sampleRate: rendered.sampleRate, alignmentSeconds: audio.alignmentOffset ?? 0,
                                       key: song.key, clock: CompFixture.clock)
        let drift = CriticBoard.standard.review(TakeReview(analysis: analysis)).filter { $0.critic == .pitchDrift }
        #expect(analysis.notes.count == 8 && drift.isEmpty, "\(analysis.notes.map(\.centsFromKey)) \(drift.map(\.headline))")
        #expect(Guidance.takes(in: app.song!).map(\.id) == takes.map(\.id), "every take is still there, untouched")
    }

    @Test("refused: no takes, one take, takes with no audio, and a section nobody sang")
    func refusals() async throws {
        var song = CompFixture.song()
        let bare = await WritingFixture.run(WritingFixture.toolbox(DirectorScratchWorkspace(song: song)), "comp_takes", #"{"takes":""}"#)
        #expect(bare.isError && bare.content.contains("no takes yet"), "\(bare.content)")

        let part = PartID(), section = song.sections[0].id
        let first = CompFixture.take(1, part: part, section: section, media: CompFixture.media("a"))
        try song.append(first)
        let lonely = DirectorScratchWorkspace(song: song)
        lonely.takeAudio[first.id] = Comp.TakeAudio(planar: CompFixture.sung(sharpInBar: nil), sampleRate: CompFixture.rate, alignmentSeconds: 0)
        let one = await WritingFixture.run(WritingFixture.toolbox(lonely), "comp_takes", #"{"takes":""}"#)
        #expect(one.isError && one.content.contains("only one take of the Verse") && one.content.contains("Booth"), "\(one.content)")

        let second = CompFixture.take(2, part: part, section: section, media: CompFixture.media("b"))
        try song.append(second)
        let deaf = DirectorScratchWorkspace(song: song)
        let silent = await WritingFixture.run(WritingFixture.toolbox(deaf), "comp_takes", #"{"takes":""}"#)
        #expect(silent.isError && silent.content.contains("could not be read"), "\(silent.content)")
        #expect(deaf.song?.versions.count == 2, "nothing was recorded")

        let chorus = await WritingFixture.run(WritingFixture.toolbox(deaf), "comp_takes", #"{"takes":"Chorus"}"#)
        #expect(chorus.isError && chorus.content.contains("Takes were sung to: Verse"), "\(chorus.content)")
    }
}

// MARK: - open_song

@Suite("Director: open_song", .serialized) @MainActor
struct DirectorOpenSongTests {

    @Test("a title is found by any case, inside a longer one, or by the closest spelling — never by a guess between two")
    func matching() {
        let bus = SongID(), drive = SongID(), arrival = SongID()
        let songs: [(id: SongID, title: String)] = [(bus, "Night Bus"), (drive, "Night Drive"), (arrival, "Arrival (Demo)")]
        #expect(OpenSongTool.match("night bus", in: songs) == .one(bus))
        #expect(OpenSongTool.match("  NIGHT BUS ", in: songs) == .one(bus))
        #expect(OpenSongTool.match("arrival", in: songs) == .one(arrival), "inside a longer title")
        #expect(OpenSongTool.match("nite bus", in: songs) == .one(bus), "the closest spelling")
        #expect(OpenSongTool.match("night", in: songs) == .several([bus, drive]))
        #expect(OpenSongTool.match("Nowhere", in: songs) == .none)
        #expect(OpenSongTool.match(drive.description, in: songs) == .one(drive), "an id, when two share a title")
        let twins: [(id: SongID, title: String)] = [(bus, "Sketch"), (drive, "sketch")]
        #expect(OpenSongTool.match("Sketch", in: twins) == .several([bus, drive]))
        let short: [(id: SongID, title: String)] = [(bus, "Go"), (drive, "Good Morning Sunshine")]
        #expect(OpenSongTool.match("good morning", in: short) == .one(drive), "whole words: \"go\" is not inside \"good\"")
    }

    /// A library of three saved songs, with Arrival open.
    static func library(in directory: URL) -> AppState {
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        for (title, tempo) in [("Night Bus", 92.0), ("Night Drive", 100.0), ("Arrival", 90.0)] {
            app.open(Song.new(title: title, tempo: tempo))
            app.save()
        }
        return app
    }

    @Test("opens a library song by title, keeping the open one first, and reads it as read_song does")
    func opens() async throws {
        let directory = WiringFixture.temporaryDirectory("open-song")
        defer { WiringFixture.remove(directory) }
        let app = Self.library(in: directory)
        #expect(app.setTempo(84), "an unsaved change to the open song")
        let box = WritingFixture.toolbox(AppStateWorkspace(app))

        let result = await WritingFixture.run(box, "open_song", #"{"title":"night bus"}"#)
        #expect(!result.isError, "\(result.content)")
        let out = WritingFixture.json(result)
        #expect(app.song?.title == "Night Bus" && out["title"] as? String == "Night Bus" && out["tempo"] as? Double == 92)
        #expect(out["is_open"] as? Bool == true && (out["sections"] as? [Any])?.count == 3)
        #expect((out["note"] as? String)?.hasPrefix("Opened Night Bus. Arrival was kept first.") == true, "\(out["note"] ?? "")")
        #expect(app.library.songs.first { $0.title == "Arrival" }?.tempo == 84, "the song that was open was saved on the way out")

        let already = WritingFixture.json(await WritingFixture.run(box, "open_song", #"{"title":"Night Bus"}"#))
        #expect((already["note"] as? String)?.contains("already open") == true)

        let ambiguous = await WritingFixture.run(box, "open_song", #"{"title":"night"}"#)
        #expect(ambiguous.isError && ambiguous.content.contains("Night Bus") && ambiguous.content.contains("Night Drive"), "\(ambiguous.content)")
        let missing = await WritingFixture.run(box, "open_song", #"{"title":"Nowhere Fast"}"#)
        #expect(missing.isError && missing.content.contains("\"Arrival\""), "the refusal lists what there is: \(missing.content)")
        #expect(app.song?.title == "Night Bus", "a refusal opens nothing")
    }

    @Test("in a turn: opening a song does not stop the turn that asked for it")
    func openingKeepsTheTurn() async throws {
        let directory = WiringFixture.temporaryDirectory("open-song-turn")
        defer { WiringFixture.remove(directory) }
        let app = Self.library(in: directory)
        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                            workspace: AppStateWorkspace(app), audition: DirectorSilentAudition(),
                                            stage: stage, pad: pad)
        let transport = DirectorScriptedTransport([
            .events(DirectorSSE.start() + DirectorSSE.toolUse(id: "t1", name: "open_song", jsonPieces: [#"{"title":"Night Drive"}"#])
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Night Drive is open, at 100.")),
        ])
        let client = ClaudeClient(keySource: DirectorTestClient.key, transport: transport,
                                  sleeper: DirectorRecordingSleeper(), retry: .none)
        let session = DirectorSession(director: Director(client: client, toolbox: toolbox, stage: stage, pad: pad), app: app)
        app.attach(band: session)

        await session.refreshKeyStatus()
        session.composing = "open night drive"
        session.send()
        while session.isWorking { await Task.yield() }

        #expect(app.song?.title == "Night Drive")
        #expect(await transport.requestCount == 2, "the turn went on to read what it opened")
        let second = try await transport.request(1).bodyJSON().jsonText
        #expect(second.contains("open night drive") && second.contains("Opened Night Drive"), "the thread was not started over mid-turn")
        #expect(app.log.contains { $0.source == .director && $0.text.contains("Night Drive is open") },
                "the turn landed with its answer, not as stopped: \(app.log.suffix(4).map { "\($0.source): \($0.text)" })")
        #expect(app.log.contains { $0.source == .director && $0.text == "Opened Night Drive" }, "the rail says who opened it")
    }

    @Test("in a turn: starting a song over one that holds work does not stop the turn either")
    func startingKeepsTheTurn() async throws {
        let directory = WiringFixture.temporaryDirectory("start-song-turn")
        defer { WiringFixture.remove(directory) }
        let app = Self.library(in: directory)
        let tune = Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1)])
        #expect(app.record(PartVersion(partID: PartID(), kind: .melody(tune), author: .user, operation: Operation.written, note: "Tune")))
        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                            workspace: AppStateWorkspace(app), audition: DirectorSilentAudition(),
                                            stage: stage, pad: pad)
        let transport = DirectorScriptedTransport([
            .events(DirectorSSE.start() + DirectorSSE.toolUse(id: "t1", name: "start_song",
                                                              jsonPieces: [#"{"title":"Glass","tempo":88,"key":"","machine":"tr808"}"#])
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Glass is open at 88.")),
        ])
        let client = ClaudeClient(keySource: DirectorTestClient.key, transport: transport,
                                  sleeper: DirectorRecordingSleeper(), retry: .none)
        let session = DirectorSession(director: Director(client: client, toolbox: toolbox, stage: stage, pad: pad), app: app)
        app.attach(band: session)

        await session.refreshKeyStatus()
        session.composing = "start something new at 88"
        session.send()
        while session.isWorking { await Task.yield() }

        #expect(app.song?.title == "Glass")
        #expect(await transport.requestCount == 2, "the turn went on after the switch")
        #expect(app.log.contains { $0.source == .director && $0.text.contains("Glass is open") })
    }

    @Test("the Director's own moves are signed as the Director: on the rail, and on the instrument it picked")
    func signedAsTheDirector() async throws {
        let rig = WritingFixture.rig(Song.new(title: "Untitled", tempo: 120))
        defer { rig.clean() }
        _ = await WritingFixture.run(rig.box, "set_song", #"{"title":"","artist":"","tempo":92,"key":"","time_signature":""}"#)
        #expect(rig.app.log.contains { $0.source == .director && $0.text == "Tempo 92 bpm" },
                "\(rig.app.log.suffix(3).map { "\($0.source): \($0.text)" })")
        #expect(!rig.app.log.contains { $0.source == .you && $0.text == "Tempo 92 bpm" })
        #expect(rig.app.setTempo(96) && rig.app.log.last?.source == .you, "a change you make is still yours")

        _ = await WritingFixture.run(rig.box, "set_instrument", #"{"instrument":"juno","part":""}"#)
        let pick = try #require(rig.app.song?.versions.last)
        guard case .sound(let sound) = pick.kind else { Issue.record("not a sound: \(pick.type)"); return }
        #expect(sound.instrument == "juno" && pick.author == .persona("Director"))
        #expect(rig.app.log.contains { $0.source == .director && $0.text.hasPrefix("Written → sound") }, "the rail names who kept it")
    }
}
