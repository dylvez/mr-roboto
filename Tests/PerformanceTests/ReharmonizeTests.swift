import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

// One named move on a chord sheet at a time: what each does to the loop every song here opened
// with, that each can be told from the others, and that none of them invents a sheet from nothing.

@Suite("Reharmonise: one move on a sheet")
struct ReharmonizeTests {

    private func sheet(_ text: String, _ key: String) throws -> Progression {
        try Progression.parse(text, key: try #require(Key(parsing: key))).get()
    }

    private func made(_ move: Reharmonization, _ text: String, _ key: String, variant: Int = 0) throws -> Reharmonized? {
        Reharmonize.apply(move, to: try sheet(text, key), variant: variant)
    }

    @Test("the bass line: inversions that keep the bass still, then step it home")
    func bassLine() throws {
        let made = try #require(try made(.bassLine, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor"))
        #expect(made.progression.symbols() == "Dm7 | Bbmaj7/D | Gm7/D | A7/C#")
        #expect(made.progression.chords.map(\.root) == (try sheet("Dm7 | Bbmaj7 | Gm7 | A7", "D minor")).chords.map(\.root), "the chords are the chords")
        #expect(made.says.contains("the bass goes D, D, D, C#"), "\(made.says)")
        // Two chords a step apart have nowhere better for the bass to go.
        #expect(try self.made(.bassLine, "C | Dm", "C major") == nil)
        // And the bass player plays the bass the chord names, not its root.
        let chords = made.progression.spans
        let groove = Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest })])
        let line = BassWriter.write(BassRequest(key: made.progression.key, chords: chords, groove: groove, tempo: 90, timeSignature: .fourFour,
                                                lineage: .rootFifth, lagMS: 0, density: 0.3, seed: 3, bars: 4))
        let last = line.notes.filter { $0.start >= 12 && $0.start < 15.4 }
        #expect(!last.isEmpty && last.contains { $0.pitch.pitchClass == NoteName(.c, .sharp).pitchClass }, "\(last.map(\.pitch.midi))")
    }

    @Test("a borrowed chord: the four made major or the flat two in a minor key, the minor four or the flat seven in a major")
    func borrowed() throws {
        #expect(try made(.borrowed, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor")?.progression.symbols() == "Dm7 | Bbmaj7 | G7 | A7")
        #expect(try made(.borrowed, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor", variant: 1)?.progression.symbols() == "Dm7 | Bbmaj7 | Ebmaj7 | A7")
        #expect(try made(.borrowed, "Dm | Bb | Gm | A", "D minor")?.progression.symbols() == "Dm | Bb | G | A", "triads stay triads")
        #expect(try made(.borrowed, "C | G | Am | F", "C major")?.progression.symbols() == "C | G | Am | F Fm")
        #expect(try made(.borrowed, "F | Dm | Gm | C", "F major")?.progression.symbols() == "F | Dm | Gm | C Eb")
        // No four and no five at the end: nothing to borrow against.
        #expect(try made(.borrowed, "Am7 | Fmaj7 | Cmaj7 | G", "A minor") == nil)
    }

    @Test("a secondary dominant goes before a chord that is not home, on the last beats of the chord before, and only where the key had none")
    func secondaryDominant() throws {
        let first = try #require(try made(.secondaryDominant, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor"))
        #expect(first.progression.symbols() == "Dm7 | Bbmaj7 D7 | Gm7 | A7")
        #expect(first.progression.bars.map(\.beats) == [4, 4, 4, 4], "the bars are as long as they were")
        #expect(first.says == "D7 on the last 2 beats before Gm7: its own dominant.")
        #expect(try made(.secondaryDominant, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor", variant: 1)?.progression.symbols() == "Dm7 F7 | Bbmaj7 | Gm7 | A7")
        // Two bars a chord: the dominant takes the last two beats of the second.
        let long = try sheet("Am7 | Am7 | Fmaj7 | Fmaj7", "A minor")
        #expect(Reharmonize.apply(.secondaryDominant, to: long)?.progression.symbols() == "Am7 | Am7 C7 | Fmaj7 | Fmaj7")
        // In a waltz it takes the last beat: E7 before the A minor the loop comes round to.
        let waltz = try Progression.parse("Am | Dm | G | C", key: .cMajor, beatsPerBar: 3).get()
        let turned = try #require(Reharmonize.apply(.secondaryDominant, to: waltz))
        #expect(turned.progression.symbols() == "Am | Dm | G | C E7" && turned.progression.bars.last?.chords.map(\.beats) == [2, 1])
    }

    @Test("a passing chord, the tritone substitute, uneven lengths, a second ending and the loop from its middle")
    func theRest() throws {
        #expect(try made(.passing, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor")?.progression.symbols() == "Dm7 | Bbmaj7 | Gm7 G#dim7 | A7")
        #expect(try made(.passing, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor", variant: 1)?.progression.symbols() == "Dm7 C7 | Bbmaj7 | Gm7 | A7")
        #expect(try made(.tritone, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor")?.progression.symbols() == "Dm7 | Bbmaj7 | Gm7 | A7 Eb7")
        #expect(try made(.tritone, "Am7 | Fmaj7 | Cmaj7 | G", "A minor") == nil, "no dominant to substitute")
        let uneven = try #require(try made(.uneven, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor"))
        #expect(uneven.progression.symbols() == "Dm7 | Dm7 | Bbmaj7 Gm7 | A7")
        #expect(uneven.progression.bars.map(\.beats) == [4, 4, 4, 4])
        #expect(try made(.uneven, "Dm7 | Gm7 | A7", "D minor") == nil)
        let twice = try #require(try made(.turnaround, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor"))
        #expect(twice.progression.symbols() == "Dm7 | Bbmaj7 | Gm7 | A7 | Dm7 | Bbmaj7 | Gm7 | Bbmaj7 C7")
        #expect(try made(.turnaround, "C | G | Am | F", "C major")?.progression.symbols() == "C | G | Am | F | C | G | Am | F G")
        #expect(try made(.rotated, "Dm7 | Bbmaj7 | Gm7 | A7", "D minor")?.progression.symbols() == "Gm7 | A7 | Dm7 | Bbmaj7")
    }

    @Test("every move is its own sheet, keeps the key and how the chords are played, and nothing is made of one chord")
    func options() throws {
        var loop = try sheet("Dm7 | Bbmaj7 | Gm7 | A7", "D minor")
        loop.playing = ChordPlaying(pattern: "arpeggio", voicing: "led", seed: 9)
        let all = Reharmonize.options(for: loop)
        #expect(all.map(\.move) == Reharmonization.allCases, "this loop has room for every one")
        #expect(Set(all.map { $0.progression.symbols() }).count == all.count)
        #expect(all.allSatisfy { $0.progression.key == loop.key && $0.progression.playing == loop.playing })
        #expect(all.allSatisfy { !$0.says.isEmpty && $0.progression.spans != loop.spans })
        // What comes back parses as it reads.
        for option in all {
            let again = try Progression.parse(option.progression.symbols(), key: loop.key).get()
            #expect(again.chords == option.progression.chords, "\(option.progression.symbols())")
        }
        #expect(Reharmonize.options(for: try sheet("Dm7", "D minor")).isEmpty)
        // An inversion's bass is spelled as the chord tone it is, in any key.
        #expect(Chord(root: NoteName(.a).pitchClass, quality: .dominantSeventh, inversion: 1).symbol(preferring: .flats) == "A7/C#")
    }
}
