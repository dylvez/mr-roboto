import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// How a strike leaves the hand — together, strummed, run as a harp, loose off the grid — and the
/// three more ways of breaking a chord.
@Suite("Keys: strum, harp, slop and the arpeggios")
struct StrumSlopTests {

    private func notes(_ line: String, _ playing: ChordPlaying, beats: Int = 4) -> [NoteEvent] {
        Voicing.notes(for: try! Progression.parse(line, key: Key(parsing: "C major")!, beatsPerBar: beats).get(), playing: playing)
    }
    private func at(_ notes: [NoteEvent], from: Double, to: Double) -> [NoteEvent] {
        notes.filter { $0.start >= from - 1e-9 && $0.start < to - 1e-9 }
    }

    @Test("strummed, a strike runs low to high a twenty-fourth of a beat apart; on an off-beat it is the upstroke, high to low")
    func strum() throws {
        let held = notes("C", ChordPlaying(.held, .close, roll: .strum))
        #expect(held.map(\.pitch.midi) == [48, 52, 55])
        #expect(held.map(\.start) == [0, 1.0 / 24, 2.0 / 24])
        #expect(abs(held[2].end - held[0].end) < 1e-9, "each let go where the strike is")
        let eighths = notes("C", ChordPlaying(.eighths, .close, roll: .strum))
        let up = at(eighths, from: 0.5, to: 0.75).sorted { $0.start < $1.start }
        #expect(up.map(\.pitch.midi) == [55, 52, 48], "the and of one, upward from the top down")
        let down = at(eighths, from: 1, to: 1.25).sorted { $0.start < $1.start }
        #expect(down.map(\.pitch.midi) == [48, 52, 55])
        // Together is every note at once, as before there was a choice.
        #expect(notes("C", ChordPlaying(.held, .close)).map(\.start) == [0, 0, 0])
    }

    @Test("a harp runs a change up two octaves a twelfth of a beat apart, and strums the strikes after it")
    func harp() {
        let held = notes("C | F", ChordPlaying(.held, .close, roll: .harp))
        let first = at(held, from: 0, to: 1).sorted { $0.start < $1.start }
        #expect(first.map(\.pitch.midi) == [48, 52, 55, 60, 64, 67])
        #expect(zip(first.map(\.start), (0..<6).map { Double($0) / 12 }).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(at(held, from: 4, to: 5).count == 6, "every change runs")
        let quarters = notes("C", ChordPlaying(.quarters, .close, roll: .harp))
        #expect(at(quarters, from: 0, to: 1).count == 6)
        let second = at(quarters, from: 1, to: 2).sorted { $0.start < $1.start }
        #expect(second.map(\.pitch.midi) == [48, 52, 55] && second.map(\.start) == [1, 1 + 1.0 / 24, 1 + 2.0 / 24],
                "the strike after the change is strummed")
    }

    @Test("loose, every strike lands off the grid within a thirtieth early and a twentieth late, the same for one seed, never before the top")
    func slop() {
        let tight = notes("C | F | G | C", ChordPlaying(.quarters, .close, seed: 9))
        let loose = notes("C | F | G | C", ChordPlaying(.quarters, .close, seed: 9, slop: true))
        #expect(loose == notes("C | F | G | C", ChordPlaying(.quarters, .close, seed: 9, slop: true)), "the same for one seed")
        #expect(loose != notes("C | F | G | C", ChordPlaying(.quarters, .close, seed: 10, slop: true)), "another seed, another hand")
        let tightStarts = Set(tight.map(\.start)).sorted()
        let looseStarts = Set(loose.map(\.start)).sorted()
        #expect(tightStarts.count == 16 && looseStarts.count == 16)
        for (grid, played) in zip(tightStarts, looseStarts) {
            #expect(played >= grid - 1.0 / 30 - 1e-9 && played <= grid + 1.0 / 20 + 1e-9, "\(played) against \(grid)")
        }
        #expect(zip(tightStarts, looseStarts).filter { abs($0 - $1) > 1e-6 }.count >= 12, "most strikes moved")
        #expect(looseStarts[0] >= 0)
        #expect(loose.map(\.velocity) == tight.map(\.velocity), "the same hand otherwise")
    }

    @Test("up: a note every half-beat from the bottom, again from the bottom at the top; two octaves: the chord and its octave in sixteenths")
    func arpeggioUpAndWide() {
        let up = notes("C", ChordPlaying(.arpeggioUp, .close))
        #expect(up.map(\.start) == stride(from: 0.0, to: 4, by: 0.5).map { $0 })
        #expect(up.map(\.pitch.midi) == [48, 52, 55, 48, 52, 55, 48, 52])
        let wide = notes("C", ChordPlaying(.arpeggioWide, .close))
        #expect(wide.count == 16 && wide[1].start == 0.25)
        #expect(Array(wide.prefix(7).map(\.pitch.midi)) == [48, 52, 55, 60, 64, 67, 48])
    }

    @Test("rolling: the chord's notes once a beat each, as many to the beat as it has — triplets for a triad, sixteenths for a seventh")
    func rolling() {
        let triad = notes("C", ChordPlaying(.rolling, .close))
        #expect(triad.count == 12)
        #expect(abs(triad[1].start - 1.0 / 3) < 1e-9 && abs(triad[3].start - 1) < 1e-9)
        let seventh = notes("Cmaj7", ChordPlaying(.rolling, .close))
        #expect(seventh.count == 16 && abs(seventh[1].start - 0.25) < 1e-9)
        #expect(Array(seventh.prefix(5).map(\.pitch.midi)) == [48, 52, 55, 59, 48])
    }

    @Test("the Played row keeps its ten, Arpeggio standing for the four ways of breaking a chord")
    func rows() {
        #expect(KeysPattern.row == [.held, .stabs, .offbeats, .backbeat, .pushes, .arpeggio, .quarters, .eighths, .boomChick, .bossa])
        #expect(KeysPattern.broken.allSatisfy(\.isBroken) && !KeysPattern.stabs.isBroken)
        #expect(KeysPattern.broken.map(\.brokenName) == ["Up and down", "Up", "Two octaves", "Rolling"])
    }

    @Test("a roll or slop is a playing; nothing of either is written for a playing without them")
    func coding() throws {
        #expect(!ChordPlaying(.held, .close, roll: .strum).isPlain && !ChordPlaying(.held, .close, slop: true).isPlain)
        #expect(ChordPlaying(.held, .close).isPlain)
        let plain = String(decoding: try JSONEncoder().encode(ChordPlaying(.stabs, .led, seed: 3)), as: UTF8.self)
        #expect(!plain.contains("roll") && !plain.contains("slop"), "\(plain)")
        let played = ChordPlaying(.stabs, .led, seed: 3, roll: .harp, slop: true)
        #expect(try JSONDecoder().decode(ChordPlaying.self, from: JSONEncoder().encode(played)) == played)
        #expect(played.sentence == "Stabs, voice-led, harped, loose")
        #expect(ChordPlaying(pattern: "held", voicing: "close", roll: "glissando").keysRoll == .together, "a roll nobody knows is together")
    }
}
