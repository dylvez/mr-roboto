import Foundation
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
