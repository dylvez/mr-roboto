import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The keys player: where the notes of each chord sit, and when they are struck.
@Suite("Keys: voicing and striking")
struct KeysPlayingTests {

    static func progression(_ line: String, key: String = "C major", beats: Int = 4, playing: ChordPlaying? = nil) -> Progression {
        var parsed = try! Progression.parse(line, key: Key(parsing: key)!, beatsPerBar: beats).get()
        parsed.playing = playing
        return parsed
    }

    /// The loop asked for on the first day: each voice to move by a step, or stay.
    static let meditation = progression("Cmaj9 | Em7 | Fmaj7 | Am7")

    private func names(_ pitches: [Int]) -> [String] { pitches.map { Pitch(midi: $0).description } }

    // MARK: Voicing

    @Test("close is the chord as written, stacked from its root")
    func close() {
        let voiced = Voicing.voicings(of: Self.meditation.chords, as: .close)
        #expect(voiced[0] == [48, 52, 55, 59, 62])
        #expect(voiced[1] == [52, 55, 59, 62])
        #expect(voiced == Self.meditation.chords.map { $0.pitches(octave: 3).map(\.midi) })
    }

    @Test("voice-led: each chord in the inversion nearest the last, the top line moving by a step or staying")
    func led() {
        let voiced = Voicing.voicings(of: Self.meditation.chords, as: .led)
        let top = voiced.compactMap(\.last)
        for (before, after) in zip(top, top.dropFirst()) {
            #expect(abs(after - before) <= 2, "\(names(top))")
        }
        // Every chord is all there, whatever is at the bottom of it.
        for (chord, pitches) in zip(Self.meditation.chords, voiced) {
            let kept = Set(pitches.map { ($0 % 12 + 12) % 12 })
            #expect(kept.isSubset(of: Set(chord.pitchClasses.map(\.rawValue))))
            #expect(kept.contains((chord.root.rawValue + (chord.quality.third ?? 0)) % 12), "the third is never the note left out")
            #expect(pitches == pitches.sorted())
            #expect(pitches.allSatisfy { (45...76).contains($0) })
        }
        #expect(Voicing.movement(of: Self.meditation, as: .led) < Voicing.movement(of: Self.meditation, as: .close))
        #expect(Voicing.movement(of: Self.meditation, as: .led) <= 1.5, "\(Voicing.movement(of: Self.meditation, as: .led))")
        // Roots a fourth and a fifth apart are where close position jumps and a led voicing does not.
        let turnaround = Self.progression("Dm7 | G7 | Cmaj7 | A7")
        #expect(Voicing.movement(of: turnaround, as: .close) > 4)
        #expect(Voicing.movement(of: turnaround, as: .led) < 2, "\(Voicing.movement(of: turnaround, as: .led))")
    }

    @Test("a ninth chord loses its fifth before anything that says what it is")
    func tones() {
        let kept = Voicing.tones(of: Chord(.c, .dominantThirteenth), keepingRoot: true, atMost: 5)
        #expect(kept == [0, 4, 10, 2, 9], "root, third, seventh, ninth, thirteenth, as they stack: \(kept)")
        #expect(Voicing.tones(of: Chord(.c, .majorNinth), keepingRoot: false, atMost: 4) == [4, 7, 11, 2])
        #expect(Set(Voicing.tones(of: Chord(.g, .sevenSuspendedFourth), keepingRoot: false, atMost: 2)) == [0, 5], "the fourth stands where the third would")
    }

    @Test("no voicing puts two notes a semitone apart when the chord can be played without")
    func noRubs() {
        #expect(Voicing.rubs(in: [59, 60, 64]) == 1)
        #expect(Voicing.rubs(in: [52, 65]) == 1, "a semitone more than an octave is the same rub")
        #expect(Voicing.rubs(in: [48, 52, 55, 59, 62]) == 0)
        // Minor ninths and major sevenths, round a cycle that would turn them over.
        let lines = ["Dm9 | Gm9 | Cm9 | Fm9", "Cmaj7 | Fmaj7 | Bbmaj7 | Ebmaj7", "Cmaj9 | Em7 | Fmaj7 | Am7", "Am9 | Dm9 | Em9 | Am9"]
        for line in lines {
            let chords = Self.progression(line).chords
            for style in KeysVoicing.allCases {
                for (chord, pitches) in zip(chords, Voicing.voicings(of: chords, as: style)) {
                    #expect(Voicing.rubs(in: pitches) == 0, "\(chord) \(style.rawValue): \(names(pitches))")
                }
            }
        }
        // The ninth of a minor ninth is never beside its third.
        for pitches in Voicing.voicings(of: Self.progression("Dm9 | Am9 | Em9 | Bm9").chords, as: .rootless) {
            #expect(zip(pitches, pitches.dropFirst()).allSatisfy { $1 - $0 >= 2 }, "\(names(pitches))")
        }
    }

    @Test("rootless leaves the root to the bass, and a triad, which would be two notes, keeps it")
    func rootless() {
        let voiced = Voicing.voicings(of: Self.progression("Dm9 | G13 | Cmaj9 | C").chords, as: .rootless)
        #expect(!voiced[0].contains { $0 % 12 == 2 })
        #expect(!voiced[1].contains { $0 % 12 == 7 })
        #expect(!voiced[2].contains { $0 % 12 == 0 })
        #expect(Set(voiced[3].map { $0 % 12 }) == [0, 4, 7])
        #expect(voiced.allSatisfy { $0.count >= 3 && $0.allSatisfy { (52...79).contains($0) } })
        // ii–V–I the way a left hand plays it: the third of one chord is the seventh of the next.
        let top = voiced.prefix(3).compactMap(\.last)
        #expect(zip(top, top.dropFirst()).allSatisfy { abs($1 - $0) <= 2 }, "\(names(top))")
    }

    @Test("spread puts the root and its fifth low and the rest above them")
    func spread() {
        let voiced = Voicing.voicings(of: Self.progression("Am7 | Fmaj7 | Cmaj7 | G").chords, as: .spread)
        #expect(Array(voiced[0].prefix(2)) == [45, 52], "A2 and E3")
        #expect(Array(voiced[1].prefix(2)) == [41, 48], "F2 and C3")
        #expect(voiced.allSatisfy { $0 == $0.sorted() && $0.count >= 4 })
        #expect(voiced[0].dropFirst(2).allSatisfy { $0 >= 54 })
        // The triad's root and fifth are below; above it is the whole chord again.
        #expect(Set(voiced[3].dropFirst(2).map { $0 % 12 }) == [7, 11, 2])
    }

    // MARK: Striking

    @Test("a progression that says nothing of how it is played is held, in close position, as it always was")
    func plain() {
        let sheet = Self.progression("Dm7 G7 | Cmaj7")
        let notes = Voicing.notes(for: sheet)
        #expect(notes.count == 12)
        #expect(Set(notes.map(\.start)) == [0, 2, 4])
        #expect(notes.first { $0.start == 4 }?.duration == 4 * Voicing.hold)
        #expect(notes.allSatisfy { $0.velocity == Voicing.velocity })
        var said = sheet
        said.playing = ChordPlaying(.held, .close)
        #expect(Voicing.notes(for: said) == notes)
        #expect(Voicing.notes(for: sheet, playing: ChordPlaying(.held, .close)) == notes)
    }

    @Test("stabs: the two-bar house figure, short, on each chord as it comes")
    func stabs() {
        let sheet = Self.progression("Am7 | Am7 | Fmaj7 | Fmaj7", key: "A minor", playing: ChordPlaying(.stabs, .close))
        let notes = Voicing.notes(for: sheet)
        let starts = Array(Set(notes.map(\.start))).sorted()
        #expect(starts == [0, 0.75, 1.5, 2.5, 3.25, 4.5, 5.5, 6.25, 7, 7.5, 8, 8.75, 9.5, 10.5, 11.25, 12.5, 13.5, 14.25, 15, 15.5])
        #expect(notes.allSatisfy { $0.duration <= 0.35 })
        #expect(notes.filter { $0.start == 0 }.map(\.pitch.midi) == [57, 60, 64, 67])
        #expect(notes.filter { $0.start == 8 }.map(\.pitch.midi) == [53, 57, 60, 64])
        #expect(notes.first { $0.start == 0 }!.velocity > notes.first { $0.start == 0.75 }!.velocity)
        #expect(Voicing.lengthInBeats(of: sheet) == 16)
    }

    @Test("a push plays the chord that is coming a half-beat early, and the last pushes into the first")
    func pushes() {
        let sheet = Self.progression("C | F | G | Am", playing: ChordPlaying(.pushes, .close))
        let notes = Voicing.notes(for: sheet)
        func roots(at beat: Double) -> [Int] { notes.filter { $0.start == beat }.map(\.pitch.midi) }
        #expect(roots(at: 0).first == 48, "C on one")
        #expect(roots(at: 1.5).first == 48)
        #expect(roots(at: 3.5).first == 53, "F, before its bar")
        #expect(roots(at: 4).isEmpty, "and not struck again on its one")
        #expect(roots(at: 11.5).first == 57, "A minor, before its bar")
        #expect(notes.allSatisfy { $0.start < 16 })
        // Let go before the chord it played changes.
        #expect(notes.filter { $0.start == 3.5 }.allSatisfy { $0.end < 8 })
    }

    @Test("an arpeggio is a note every half-beat, up and back, begun again on the change")
    func arpeggio() {
        let notes = Voicing.notes(for: Self.progression("Cmaj7 | Am7", playing: ChordPlaying(.arpeggio, .close)))
        #expect(notes.count == 16)
        #expect(notes.prefix(8).map(\.pitch.midi) == [48, 52, 55, 59, 55, 52, 48, 52])
        #expect(notes.dropFirst(8).first?.pitch.midi == 57)
        #expect(notes.map(\.start) == (0..<16).map { Double($0) * 0.5 })
    }

    @Test("boom-chick: the low note on one and three, the chord on two and four; in three, a waltz")
    func boomChick() {
        let four = Voicing.notes(for: Self.progression("C | G7", playing: ChordPlaying(.boomChick, .close)))
        func pitches(_ notes: [NoteEvent], at beat: Double) -> [Int] { notes.filter { $0.start == beat }.map(\.pitch.midi) }
        #expect(pitches(four, at: 0) == [48])
        #expect(pitches(four, at: 1) == [52, 55])
        #expect(pitches(four, at: 2) == [43], "the fifth, under the root")
        #expect(pitches(four, at: 3) == [52, 55])
        #expect(pitches(four, at: 4) == [55])
        let three = Voicing.notes(for: Self.progression("C | F", beats: 3, playing: ChordPlaying(.boomChick, .close)))
        #expect(pitches(three, at: 0) == [48] && pitches(three, at: 1) == [52, 55] && pitches(three, at: 2) == [52, 55])
        #expect(pitches(three, at: 3) == [53], "and bar two begins on its own root")
        #expect(three.allSatisfy { $0.start < 6 })
    }

    @Test("off-beats, the backbeat, quarters and eighths fall where they say, in any meter")
    func plainPatterns() {
        func starts(_ pattern: KeysPattern, _ line: String = "C", beats: Int = 4) -> [Double] {
            Array(Set(Voicing.notes(for: Self.progression(line, beats: beats, playing: ChordPlaying(pattern, .close))).map(\.start))).sorted()
        }
        #expect(starts(.offbeats) == [0.5, 1.5, 2.5, 3.5])
        #expect(starts(.backbeat) == [1, 3])
        #expect(starts(.quarters) == [0, 1, 2, 3])
        #expect(starts(.eighths) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        #expect(starts(.bossa, "C | C") == [0, 1.5, 3, 5, 6.5])
        #expect(starts(.quarters, beats: 3) == [0, 1, 2])
        // A figure written in four is the nearest plain one in three.
        #expect(starts(.stabs, beats: 3) == [0.5, 1.5, 2.5])
        #expect(starts(.pushes, beats: 3) == [0, 1, 2])
    }

    @Test("two chords in a bar are each struck as they sound, and nothing rings over a change")
    func twoInABar() {
        let notes = Voicing.notes(for: Self.progression("Dm7 G7 | Cmaj7", playing: ChordPlaying(.quarters, .close)))
        #expect(notes.filter { $0.start == 1 }.map(\.pitch.midi) == [50, 53, 57, 60])
        #expect(notes.filter { $0.start == 2 }.map(\.pitch.midi) == [55, 59, 62, 65])
        #expect(notes.filter { $0.start == 4 }.map(\.pitch.midi) == [48, 52, 55, 59])
        #expect(notes.filter { $0.start < 2 }.allSatisfy { $0.end <= 2 })
    }

    @Test("a seed is the same hand every time, and no seed is a hand that never varies")
    func seeded() {
        let plain = Voicing.notes(for: Self.progression("C | F", playing: ChordPlaying(.eighths, .close)))
        let seeded = Voicing.notes(for: Self.progression("C | F", playing: ChordPlaying(.eighths, .close, seed: 41)))
        let again = Voicing.notes(for: Self.progression("C | F", playing: ChordPlaying(.eighths, .close, seed: 41)))
        let other = Voicing.notes(for: Self.progression("C | F", playing: ChordPlaying(.eighths, .close, seed: 42)))
        #expect(seeded == again)
        #expect(seeded.map(\.velocity) != other.map(\.velocity))
        #expect(seeded.map(\.start) == plain.map(\.start) && seeded.map(\.pitch) == plain.map(\.pitch))
        #expect(zip(seeded, plain).allSatisfy { abs($0.velocity - $1.velocity) <= 5 })
        // One velocity a strike: a chord is struck by one hand.
        #expect(Dictionary(grouping: seeded, by: \.start).values.allSatisfy { Set($0.map(\.velocity)).count == 1 })
    }

    @Test("how a progression is played travels with it, and one that says nothing reads as it did")
    func carried() throws {
        let plain = Self.progression("Dm7 | G7")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("playing"))
        var played = plain
        played.playing = ChordPlaying(.pushes, .rootless, seed: 7)
        let back = try JSONDecoder().decode(Progression.self, from: try encoder.encode(played))
        #expect(back == played && back.playing?.keysPattern == .pushes && back.playing?.keysVoicing == .rootless)
        #expect(played.transposed(by: 2).playing == played.playing)
        // A pattern from a build that has not been written yet is held, not a crash.
        #expect(ChordPlaying(pattern: "montuno", voicing: "quartal").keysPattern == .held)
        #expect(ChordPlaying(pattern: "montuno", voicing: "quartal").keysVoicing == .close)
        #expect(ChordPlaying(.stabs, .led).sentence == "Stabs, voice-led")
    }

    @Test("a genre has a usual way of playing its chords, and a pad is not asked for stabs")
    func suited() {
        #expect(KeysPattern.usual(inGenre: "house") == .stabs)
        #expect(KeysPattern.usual(inGenre: "reggae") == .offbeats)
        #expect(KeysPattern.usual(inGenre: "neo-soul") == .pushes)
        #expect(KeysPattern.usual(inGenre: "country") == .boomChick)
        #expect(KeysPattern.usual(inGenre: "bossa-nova") == .bossa)
        #expect(KeysPattern.usual(inGenre: "nothing-anyone-plays") == nil)
        #expect(KeysPattern.stabs.suits(family: "keys") && !KeysPattern.stabs.suits(family: "pad"))
        #expect(KeysPattern.held.suits(family: "pad") && KeysPattern.held.suits(family: "strings"))
    }
}
