import Foundation
import MusicTheory
import Testing
@testable import SongGraph

// A lyric knows which stanza is which section, and which note each syllable is sung on. Both are
// new fields on a type already on disk, so a lyric that uses neither must write what it always did.

@Suite struct LyricLabelTests {

    private func line(_ words: String, stressed: Set<String> = []) -> LyricLine {
        LyricLine(syllables: words.split(separator: " ").map { Syllable(String($0), stress: stressed.contains(String($0)) ? .primary : .unstressed) })
    }

    /// Verse, blank, Hook: seven syllables, the Hook's line starting at index 3.
    private var labelled: Lyric {
        Lyric(lines: [line("down by the"), line("water"), LyricLine(syllables: []), line("home again")],
              labels: [Lyric.StanzaLabel(line: 0, name: "Verse"), Lyric.StanzaLabel(line: 3, name: "Hook")])
    }

    @Test func syllablesAreSetToTheNotesInTheOrderTheySound() {
        // Listed 3, 0, 1, 2 by start: the first syllable goes on the note at beat 0.
        let notes = [3.0, 0, 1, 2].map { NoteEvent(pitch: Pitch(midi: 60), start: $0, duration: 0.5) }
        let set = Lyric(lines: [line("one two three four")]).aligned(to: Melody(notes: notes), version: VersionID())
        #expect(set.lines[0].syllables.map(\.noteIndex) == [1, 2, 3, 0])
    }

    @Test func aSectionSingsTheStanzaLabelledForIt() {
        // Verse, Verse, Hook stanzas; a form of Intro, Verse, Hook, Verse, Verse.
        let lyric = Lyric(lines: [line("down by the"), line("water"), LyricLine(syllables: []),
                                  line("second verse"), LyricLine(syllables: []), line("home again")],
                          labels: [Lyric.StanzaLabel(line: 0, name: "Verse"), Lyric.StanzaLabel(line: 3, name: "verse"),
                                   Lyric.StanzaLabel(line: 5, name: "Hook")])
        let form = ["Intro", "Verse", "Hook", "Verse", "Verse"].map { Section(name: $0, stitch: [], lengthInBars: 4) }
        #expect(lyric.stanza(forSectionAt: 0, in: form) == nil, "no stanza is labelled Intro")
        #expect(lyric.stanza(forSectionAt: 1, in: form)?.lines == 0..<2)
        #expect(lyric.stanza(forSectionAt: 2, in: form)?.lines == 5..<6)
        #expect(lyric.stanza(forSectionAt: 3, in: form)?.lines == 3..<4, "the second Verse sings the second stanza, case aside")
        #expect(lyric.stanza(forSectionAt: 4, in: form)?.lines == 3..<4, "a third Verse with two stanzas sings the last")
        #expect(lyric.stanza(forSectionAt: 9, in: form) == nil)
    }

    @Test func labelsAreWrittenBackAboveTheirStanzas() {
        #expect(labelled.text == "[Verse]\ndown by the\nwater\n\n[Hook]\nhome again")
        var unlabelled = labelled
        unlabelled.labels = nil
        #expect(unlabelled.text == "down by the\nwater\n\nhome again", "no labels, no label lines")
    }

    @Test func labelsRoundTripThroughJSON() throws {
        let aligned = labelled.aligned(to: Melody(notes: []), version: VersionID())
        for lyric in [labelled, aligned] {
            let decoded = try SongGraphCodec.decode(Lyric.self, from: try SongGraphCodec.encode(lyric))
            #expect(decoded == lyric)
            #expect(decoded.labels?.map(\.name) == ["Verse", "Hook"])
        }
        let kind = try SongGraphCodec.decode(PartKind.self, from: try SongGraphCodec.encode(PartKind.lyric(labelled)))
        #expect(kind == .lyric(labelled))
    }

    @Test func aLyricWithNoLabelsWritesExactlyWhatItAlwaysDid() throws {
        let lyric = Lyric(lines: [LyricLine(syllables: [Syllable("home", stress: .primary)])])
        let json = String(decoding: try SongGraphCodec.encode(lyric), as: UTF8.self)
        #expect(json == """
            {
              "lines" : [
                {
                  "syllables" : [
                    {
                      "startsWord" : true,
                      "stress" : "primary",
                      "text" : "home"
                    }
                  ]
                }
              ]
            }
            """, "\(json)")
        // And a document from before labels reads with none.
        let old = Data(#"{"lines":[{"syllables":[{"text":"home","stress":"primary","startsWord":true}]}]}"#.utf8)
        let decoded = try SongGraphCodec.decode(Lyric.self, from: old)
        #expect(decoded == lyric && decoded.labels == nil && decoded.alignedTo == nil)
    }

    @Test func aStanzaIsFoundByItsName() {
        #expect(labelled.stanza(named: "hook")?.map(\.text) == ["home again"], "case aside")
        #expect(labelled.stanza(named: "Verse")?.map(\.text) == ["down by the", "water"], "stops at the blank line")
        #expect(labelled.stanza(named: "Bridge") == nil)
        // A label on the blank line above its stanza still finds it; a label straight under the
        // last line of another stanza ends that one.
        let tight = Lyric(lines: [line("one"), line("two"), line("three"), LyricLine(syllables: []), line("four")],
                          labels: [Lyric.StanzaLabel(line: 0, name: "Verse"), Lyric.StanzaLabel(line: 2, name: "Hook"),
                                   Lyric.StanzaLabel(line: 3, name: "Bridge")])
        #expect(tight.stanza(named: "Verse")?.map(\.text) == ["one", "two"])
        #expect(tight.stanza(named: "Hook")?.map(\.text) == ["three"])
        #expect(tight.stanza(named: "Bridge")?.map(\.text) == ["four"])
    }

    @Test func alignmentIsOneSyllableToANoteAndCountsWhatIsLeftOver() {
        let version = VersionID()
        func notes(_ count: Int) -> Melody {
            Melody(notes: (0..<count).map { NoteEvent(pitch: Pitch(midi: 60), start: Double($0), duration: 1) })
        }
        #expect(labelled.syllableCount == 6 && labelled.setSyllableCount == 0)

        let short = labelled.aligned(to: notes(4), version: version)
        #expect(short.alignedTo == version)
        #expect(short.setSyllableCount == 4, "two syllables past the last note")
        #expect(short.lines.flatMap(\.syllables).map(\.noteIndex) == [0, 1, 2, 3, nil, nil])
        #expect(short.labels == labelled.labels && short.text == labelled.text, "the words and labels are untouched")

        let long = labelled.aligned(to: notes(9), version: version)
        #expect(long.setSyllableCount == 6, "three notes with no syllable")
        #expect(long.lines.flatMap(\.syllables).compactMap(\.noteIndex) == Array(0..<6))

        let unset = long.unaligned()
        #expect(unset.alignedTo == nil && unset.setSyllableCount == 0)
        #expect(unset == labelled)
    }
}
