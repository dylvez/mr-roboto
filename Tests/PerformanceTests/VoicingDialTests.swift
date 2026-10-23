import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The voicing dial: a chord turned an inversion at a time, on its own, as the sheet turns it.
@Suite("Voicing dial: a chord turned")
struct VoicingDialTests {

    private func progression(_ line: String, lifts: [Int?], playing: ChordPlaying? = nil) -> Progression {
        var parsed = try! Progression.parse(line, key: Key(parsing: "C major")!).get()
        var index = 0
        for bar in parsed.bars.indices {
            for chord in parsed.bars[bar].chords.indices {
                parsed.bars[bar].chords[chord].lift = index < lifts.count ? lifts[index] : nil
                index += 1
            }
        }
        parsed.playing = playing
        return parsed
    }

    @Test("a step up moves the lowest note an octave up, a step down the highest an octave down; as many steps as notes is an octave")
    func lifted() {
        let c = [48, 52, 55]
        #expect(Voicing.lifted(c, by: 0) == c)
        #expect(Voicing.lifted(c, by: 1) == [52, 55, 60])
        #expect(Voicing.lifted(c, by: 2) == [55, 60, 64])
        #expect(Voicing.lifted(c, by: 3) == c.map { $0 + 12 })
        #expect(Voicing.lifted(c, by: -1) == [43, 48, 52])
        #expect(Voicing.lifted(c, by: -3) == c.map { $0 - 12 })
        #expect(Voicing.lifted([], by: 2) == [])
    }

    @Test("a lift turns its own chord and no other: the next is led from where the voicing put it")
    func liftIsItsOwn() {
        let plain = progression("Dm7 | G7 | Cmaj7", lifts: [])
        let turned = progression("Dm7 | G7 | Cmaj7", lifts: [nil, 2, nil])
        let before = Voicing.voicings(of: plain.spans, as: .led)
        let after = Voicing.voicings(of: turned.spans, as: .led)
        #expect(after[0] == before[0] && after[2] == before[2], "the chords either side are where they were")
        #expect(after[1] == Voicing.lifted(before[1], by: 2))
        #expect(Set(after[1].map { $0 % 12 }) == Set(before[1].map { $0 % 12 }), "the same notes, turned")
        // Every chord turned alike is the whole line an inversion up, not a climb.
        let all = Voicing.voicings(of: progression("Dm7 | G7 | Cmaj7 | Am7", lifts: [1, 1, 1, 1]).spans, as: .led)
        let led = Voicing.voicings(of: progression("Dm7 | G7 | Cmaj7 | Am7", lifts: []).spans, as: .led)
        #expect(all == led.map { Voicing.lifted($0, by: 1) })
    }

    @Test("turned, a spread keeps its feet: the root and fifth stay down and the hand above them moves")
    func spreadKeepsItsFeet() {
        let plain = Voicing.voicings(of: progression("Cmaj7", lifts: []).spans, as: .spread)[0]
        let turned = Voicing.voicings(of: progression("Cmaj7", lifts: [1]).spans, as: .spread)[0]
        #expect(Array(turned.prefix(2)) == Array(plain.prefix(2)))
        #expect(Array(turned.dropFirst(2)) == Voicing.lifted(Array(plain.dropFirst(2)), by: 1))
    }

    @Test("held and close, a turned chord is played turned and the rest as they were; struck, the same")
    func playedTurned() {
        let plain = Voicing.notes(for: progression("C | F | G", lifts: []))
        let turned = Voicing.notes(for: progression("C | F | G", lifts: [nil, 1]))
        func pitches(_ notes: [NoteEvent], from beat: Double) -> [Int] {
            notes.filter { abs($0.start - beat) < 1e-9 }.map(\.pitch.midi).sorted()
        }
        #expect(pitches(turned, from: 0) == pitches(plain, from: 0) && pitches(turned, from: 8) == pitches(plain, from: 8))
        #expect(pitches(turned, from: 4) == [57, 60, 65], "F in first inversion: A C F")
        let stabs = ChordPlaying(pattern: KeysPattern.quarters.rawValue, voicing: KeysVoicing.close.rawValue, seed: 0)
        let struck = Voicing.notes(for: progression("C | F | G", lifts: [nil, 1], playing: stabs))
        #expect(pitches(struck, from: 5) == [57, 60, 65])
        #expect(Voicing.topLine(of: progression("C | F | G", lifts: [nil, 1]), as: .close)[1] == 65)
    }

    @Test("a chord with no turn is written as it always was; one turned keeps its turn through the document")
    func coding() throws {
        let plain = ChordSpan(Chord(.c, .major), beats: 4)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("lift"), "\(json)")
        #expect(ChordSpan(chord: Chord(.c, .major), beats: 4, lift: 0).lift == nil, "no turn is none")
        let turned = ChordSpan(chord: Chord(.f, .major), beats: 4, lift: -2)
        #expect(try JSONDecoder().decode(ChordSpan.self, from: JSONEncoder().encode(turned)) == turned)
        let old = #"{"chord":{"root":0,"quality":"major","inversion":0},"beats":4}"#
        #expect(try JSONDecoder().decode(ChordSpan.self, from: Data(old.utf8)).lift == nil)
    }
}
