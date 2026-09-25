import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate B: the Lyricist reads words as stress shapes, rhyme by type and images against the house.

@Suite("Persona: Lyricist")
struct PersonaLyricistTests {
    private let lyricist = Lyricist()

    static let verse = """
        I put the coffee on at six
        I watched it make itself
        The light came through the window
        And landed somewhere else
        """

    @Test("the lexicon holds the words with their stresses and endings, and guesses the rest")
    func lexicon() {
        let lexicon = StressLexicon.shared
        #expect(lexicon.count > 100_000, "\(lexicon.count) words")
        let window = lexicon.entry(for: "window")
        #expect(window.stresses == [.primary, .unstressed] && !window.isGuessed)
        #expect(window.ending == ["IH", "N", "D", "OW"])
        #expect(lexicon.entry(for: "melody").stresses == [.primary, .unstressed, .unstressed])
        #expect(lexicon.entry(for: "Coffee,").stresses.count == 2, "punctuation and case are stripped")
        let made = lexicon.entry(for: "xyzzyquux")
        #expect(made.isGuessed && made.stresses.first == .primary)
        #expect(StressLexicon.chunks(of: "melody", count: 3) == ["me", "lo", "dy"])
        #expect(StressLexicon.chunks(of: "central", count: 2) == ["cen", "tral"])
        #expect(StressLexicon.chunks(of: "window", count: 2) == ["win", "dow"])
        #expect(StressLexicon.chunks(of: "six", count: 1) == ["six"])
        #expect(StressLexicon.chunks(of: "machine", count: 2) == ["ma", "chine"], "not through the ch")
        #expect(StressLexicon.chunks(of: "machine,", count: 2) == ["ma", "chine,"], "a comma does not hide the silent e")
        #expect(StressLexicon.chunks(of: "father", count: 2) == ["fa", "ther"])
        #expect(StressLexicon.chunks(of: "singer", count: 2) == ["sing", "er"])
        #expect(StressLexicon.chunks(of: "rocket", count: 2) == ["rock", "et"])
    }

    @Test("a verse reads back with its stresses and its scheme, and the lines share their shape")
    func readsAVerse() throws {
        let lyric = Lyricist.lyric(from: Self.verse)
        #expect(lyric.lines.count == 4)
        #expect(lyric.lines[0].text == "I put the coffee on at six")
        #expect(lyric.lines[2].syllables.map(\.text).joined(separator: "·") == "The·light·came·through·the·win·dow", "\(lyric.lines[2].syllables.map(\.text))")
        let observation = LyricObservation.of(lyric, label: "Soft Machine, verse 1")
        #expect(observation.lineCount == 4)
        #expect(observation.schemes == ["ABCB"], "\(observation.schemes): itself / else is a family rhyme (F and S are fricatives)")
        #expect(observation.perfectRhymeRate == 0)
        #expect(observation.shapes[2] == "uSSSuSu", "\(observation.shapes)")
        #expect(observation.patternMatch > 0.5, "\(observation.patternMatch)")
        let readings = lyricist.read(observation)
        #expect(readings.first { $0.rule == "lyricist.not-a-nursery-rhyme" }?.says.contains("ABCB") == true)
        #expect(readings.first { $0.rule == "lyricist.a-line-is-a-breath" }?.holds == true)

        // Rhyme by type.
        #expect(LyricObservation.rhyme(["EH", "L", "F"], ["EH", "L", "S"]) == .family)
        #expect(LyricObservation.rhyme(["AY", "T"], ["AY", "T"]) == .perfect)
        #expect(LyricObservation.rhyme(["AY", "T"], ["AY", "M"]) == .assonance)
        #expect(LyricObservation.rhyme(["AY", "T"], ["EH", "T"]) == .consonance)
        #expect(LyricObservation.rhyme(["AY", "T"], ["EH", "M"]) == .none)
        #expect(LyricObservation.similarity("uSuS", "uSuS") == 1 && LyricObservation.similarity("uSuS", "SuSu") == 0.5)
        #expect(LyricObservation.similarity("uSuS", "SuSuSuSu") == 0.5)

        // A nursery rhyme is flagged; a long line is flagged.
        let tight = Lyricist.lyric(from: "the cat sat on the mat\nthe dog slept on the log\nthe cat came back to the mat\nthe dog went off the log")
        let tightReading = lyricist.read(LyricObservation.of(tight))
        #expect(tightReading.first { $0.rule == "lyricist.not-a-nursery-rhyme" }?.holds == false, "\(LyricObservation.of(tight).perfectRhymeRate)")
        let long = Lyricist.lyric(from: "I put the coffee on at six and watched it make itself into the morning I forgot\nI watched it make itself")
        #expect(lyricist.read(LyricObservation.of(long)).first { $0.rule == "lyricist.a-line-is-a-breath" }?.holds == false)
        #expect(lyricist.read(LyricObservation.of(Lyricist.lyric(from: "one line"))).first?.rule == "lyricist.two-lines-minimum")
    }

    @Test("the house voice: an image the house keeps using is named, from the markdown the house keeps")
    func houseVoice() {
        let markdown = """
            ### 1. Soft Machine

            ```
            [Verse 1]
            The light came through the window
            And landed somewhere else
            ```

            ### 2. Fluorescent

            ```
            [Chorus]
            Fluorescent window light
            ```

            ### 3. The Survey

            ```
            [Verse]
            A window and a form
            ```
            """
        let lyrics = LyricCorpus.parse(markdown: markdown, source: "test")
        #expect(lyrics.map(\.title) == ["Soft Machine", "Fluorescent", "The Survey"])
        #expect(lyrics[0].text == "The light came through the window\nAnd landed somewhere else")
        let corpus = LyricCorpus(lyrics)
        #expect(corpus.imageCounts["window"] == 3)
        #expect(corpus.reuse(in: "a window, a light and a machine").first?.image == "window")
        #expect(corpus.reuse(in: "a window", excluding: "Soft Machine").first?.songs == 2)
        let observation = LyricObservation.of(Lyricist.lyric(from: "I watched the window\nand the window watched me"), corpus: corpus, title: "New song")
        #expect(observation.reusedImages.first?.image == "window" && observation.reusedImages.first?.songs == 3)
        #expect(lyricist.read(observation).first { $0.rule == "lyricist.image-is-a-tic" }?.holds == false)
        // Plain text falls back to a title line per block.
        let plain = LyricCorpus.parse(markdown: "First\nline one\nline two\n\nSecond\nline three\nline four")
        #expect(plain.map(\.title) == ["First", "Second"])
    }

    @Test("it refuses a mismatched shape, a nursery rhyme, a tic and a long line, and defers the rest")
    func verdicts() {
        #expect(lyricist.consider(.writeLine(syllables: 8, patternMatch: 0.4)).refusedByRule == "lyricist.lines-share-a-shape")
        #expect(lyricist.consider(.writeLine(syllables: 8, patternMatch: 0.9)).isAgreement)
        #expect(lyricist.consider(.rhymeLine(perfectRate: 1)).refusedByRule == "lyricist.not-a-nursery-rhyme")
        #expect(lyricist.consider(.reuseImage(songs: 4)).refusedByRule == "lyricist.image-is-a-tic")
        #expect(lyricist.consider(.writeLine(syllables: 15, patternMatch: 0.9)).refusedByRule == "lyricist.a-line-is-a-breath")
        if case .defer_(let to, _) = lyricist.consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90)) { #expect(to == .beatmaker) }
        else { Issue.record("swing is the Beatmaker's") }
        #expect(BibleMethod.lint(Lyricist.bible).isEmpty, "\(BibleMethod.lint(Lyricist.bible))")
    }

    @Test("a \"[Hook]\" line names the stanza under it: read as a label, written back as one, and the start of a stanza")
    func labels() {
        let text = "[Verse]\nI put the coffee on at six\nI watched it make itself\n\n[Hook]\nsoft machine\nsoft machine"
        let lyric = Lyricist.lyric(from: text)
        #expect(lyric.labels == [Lyric.StanzaLabel(line: 0, name: "Verse"), Lyric.StanzaLabel(line: 3, name: "Hook")])
        #expect(lyric.lines.count == 5, "the label lines are not sung")
        #expect(lyric.text == text, "written back the way it was typed")
        #expect(Lyricist.lyric(from: lyric.text) == lyric)
        #expect(Lyricist.lyric(from: "no labels\nat all").labels == nil, "a lyric with no labels carries none")
        #expect(Lyricist.label(in: "  [ Chorus 2 ] ") == "Chorus 2")
        #expect(Lyricist.label(in: "[]") == nil && Lyricist.label(in: "[the] light") == nil)
        #expect(Lyricist.isHook("Chorus 2") && Lyricist.isHook("hook") && !Lyricist.isHook("Verse") && !Lyricist.isHook("Hooky"))

        // A label with no blank line above it still starts a stanza, and the scheme is its own.
        let tight = Lyricist.lyric(from: "the light\nthe night\n[Hook]\nsoft machine\nsoft machine")
        #expect(LyricObservation.stanzas(of: tight) == [[0, 1], [2, 3]])
        #expect(LyricObservation.of(tight).schemes.count == 2)

        // "[Chorus]" is how the words are organised, not an image the house has sung.
        let corpus = LyricCorpus([VoiceLyric(title: "One", text: "the chorus again"), VoiceLyric(title: "Two", text: "one more chorus"),
                                  VoiceLyric(title: "Three", text: "chorus, chorus")])
        let labelled = LyricObservation.of(Lyricist.lyric(from: "[Chorus]\nthe light\nthe night"), corpus: corpus)
        #expect(!labelled.reusedImages.contains { $0.image == "chorus" })
    }

    @Test("where a note falls, counted as a player counts it")
    func beatPlaces() {
        func place(_ start: Double, _ beats: Int = 4) -> BeatPlace { BeatPlace(start: start, beatsPerBar: beats) }
        #expect(place(0).isOnTheBeat && place(0).bar == 1 && place(0).name == "1")
        #expect(place(3).isOnTheBeat && place(3).name == "4", "the backbeat is on the beat")
        #expect(place(0.5).name == "the and of 1")
        #expect(place(5.25).name == "the e of 2" && place(5.25).bar == 2)
        #expect(place(6.75).name == "the a of 3")
        #expect(place(1 + 1.0 / 3).name == "the second triplet of 2")
        #expect(place(2 + 2.0 / 3).name == "the third triplet of 3")
        #expect(place(3.99).isOnTheBeat && place(3.99).bar == 2 && place(3.99).beat == 1, "a hair early is on the beat")
        #expect(place(2.1).name == "between 3 and 4")
        #expect(place(3.6).name == "between 4 and 1")
        #expect(place(2.5, 3).name == "the and of 3" && place(3.5, 3).bar == 2)
    }

    /// "I walk a-lone / in the night": stressed on walk, -lone and night.
    private static let alone = Lyric(lines: [
        LyricLine(syllables: [Syllable("I"), Syllable("walk", stress: .primary), Syllable("a"),
                              Syllable("lone", stress: .primary, startsWord: false)]),
        LyricLine(syllables: [Syllable("in"), Syllable("the"), Syllable("night", stress: .primary)]),
    ])

    private static func melody(_ starts: [Double]) -> Melody {
        Melody(notes: starts.map { NoteEvent(pitch: Pitch(midi: 64), start: $0, duration: 0.5) })
    }

    @Test("stressed-on-strong: read only once the words are set, holds when every stress is on a beat, names the first that is not")
    func stressedOnStrong() throws {
        let version = VersionID()
        func reading(_ lyric: Lyric, _ melody: Melody?) -> PersonaReading? {
            lyricist.read(LyricObservation.of(lyric, melody: melody)).first { $0.rule == "lyricist.stressed-on-strong" }
        }
        // Not set, or set with no melody to read against: nothing to say.
        #expect(reading(Self.alone, Self.melody([0, 1, 2, 3, 4, 5, 6])) == nil, "the words are not set")
        let onTheBeat = Self.alone.aligned(to: Self.melody([0.5, 1, 1.5, 2, 3, 3.5, 4]), version: version)
        #expect(reading(onTheBeat, nil) == nil, "no melody to read against")

        // walk on 2, -lone on 3, night on the next bar's 1: the unstressed pickups may fall anywhere.
        let holds = try #require(reading(onTheBeat, Self.melody([0.5, 1, 1.5, 2, 3, 3.5, 4])))
        #expect(holds.holds && holds.value == 0)
        #expect(holds.says == "Every stressed syllable on a note lands on a beat: 3 of them.", "\(holds.says)")

        // -lone pushed to the and of 3, night to the e of 1.
        let pushed = Self.alone.aligned(to: Self.melody([0, 1, 1.5, 2.5, 3, 3.5, 4.25]), version: version)
        let flag = try #require(reading(pushed, Self.melody([0, 1, 1.5, 2.5, 3, 3.5, 4.25])))
        #expect(!flag.holds && flag.value == 2)
        #expect(flag.says == "\"-lone\" in line 1 lands on the and of 3, bar 1 — move the note or the word. 1 more stressed syllable lands off the beat.",
                "\(flag.says)")
        let setting = try #require(LyricObservation.of(pushed, melody: Self.melody([0, 1, 1.5, 2.5, 3, 3.5, 4.25])).setting)
        #expect(setting.offBeat.map(\.text) == ["-lone", "night"])
        #expect(setting.offBeat.map(\.position) == ["the and of 3", "the e of 1"] && setting.offBeat.map(\.bar) == [1, 2])

        // A first syllable reads with its word still open; a secondary stress is not flagged.
        let window = Lyric(lines: [
            LyricLine(syllables: [Syllable("win", stress: .primary), Syllable("dow", startsWord: false)]),
            LyricLine(syllables: [Syllable("sun", stress: .primary), Syllable("light", stress: .secondary, startsWord: false)]),
        ])
        let early = window.aligned(to: Self.melody([0.5, 1, 2, 2.5]), version: version)
        let first = try #require(LyricObservation.of(early, melody: Self.melody([0.5, 1, 2, 2.5])).setting)
        #expect(first.offBeat.map(\.text) == ["win-"], "\"light\" is secondary, on the and, and not flagged")

        // Syllables past the last note have nowhere to land and are not counted.
        let short = Self.alone.aligned(to: Self.melody([0, 1]), version: version)
        let none = try #require(reading(short, Self.melody([0, 1])))
        #expect(none.holds && none.says == "The one stressed syllable on a note lands on a beat.", "\(none.says)")
    }

    @Test("title-in-the-hook: the stanza labelled Hook or Chorus is held to the song's title, whole words, case aside")
    func titleInTheHook() throws {
        func reading(_ text: String, title: String?) -> PersonaReading? {
            lyricist.read(LyricObservation.of(Lyricist.lyric(from: text), title: title)).first { $0.rule == "lyricist.title-in-the-hook" }
        }
        let song = "[Verse]\nI put the coffee on at six\nI watched it make itself\n\n[Hook]\nit's a soft machine, humming\nsoft machine"
        let holds = try #require(reading(song, title: "Soft Machine"))
        #expect(holds.holds && holds.value == 1)
        #expect(holds.says == "The Hook sings the title, \"Soft Machine\".")

        let flag = try #require(reading(song, title: "Arrival"))
        #expect(!flag.holds && flag.value == 0)
        #expect(flag.says.hasPrefix("The Hook never sings \"Arrival\"."), "\(flag.says)")

        // The title in the verse does not count; a chorus is a hook; punctuation and case aside.
        #expect(reading("[Verse]\narrival now\narrival\n\n[Chorus 2]\nsomething else\nand more", title: "Arrival")?.holds == false)
        #expect(reading("[chorus]\nDON'T STOP, now\nkeep on", title: "Don't Stop")?.holds == true)
        // Whole words: "running" does not sing "Run".
        #expect(reading("[Hook]\nrunning away\nrunning home", title: "Run")?.holds == false)
        // No hook, no title: nothing to read.
        #expect(reading("[Verse]\none line here\nand another", title: "Soft Machine") == nil)
        #expect(reading(song, title: nil) == nil)
        #expect(reading(song, title: "  ") == nil)
    }
}

/// Where the house keeps its lyrics on this machine.
private let houseCorpusPath = NSString(string: "~/Documents/projects/vessel/VESSEL_suno_and_lyrics.md").expandingTildeInPath

/// The real corpus, when it is on this machine.
@Suite("Persona: Lyricist on the house corpus",
       .enabled(if: FileManager.default.fileExists(atPath: houseCorpusPath), "Vessel's lyrics are not on this machine"))
struct PersonaLyricistCorpusTests {
    static let path = houseCorpusPath

    @Test("Vessel's lyrics import as the house voice, and a verse of one reads against the other twenty-nine")
    func vessel() throws {
        let text = try String(contentsOfFile: Self.path, encoding: .utf8)
        let lyrics = LyricCorpus.parse(markdown: text, source: "VESSEL_suno_and_lyrics.md")
        #expect(lyrics.count >= 25, "\(lyrics.count) lyrics")
        #expect(lyrics.first?.title == "Soft Machine")
        let corpus = LyricCorpus(lyrics)
        let counts = corpus.imageCounts
        let top = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8)
        print("[voice] most-used images: " + top.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        let verse = Lyricist.lyric(from: PersonaLyricistTests.verse)
        let observation = LyricObservation.of(verse, label: "Soft Machine, verse 1", corpus: corpus, title: "Soft Machine")
        let readings = Lyricist().read(observation)
        for reading in readings { print("[voice] \(reading.says)") }
        #expect(observation.corpusSongs == lyrics.count)
        #expect(!observation.reusedImages.isEmpty, "at least one image of this verse recurs elsewhere in the house")
    }
}
