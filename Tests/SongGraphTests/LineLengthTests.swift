import Foundation
import MusicTheory
import Testing
@testable import SongGraph

// A written line has a length of its own: a four-bar tune whose last bar is a breath, an
// eight-bar bass phrase over a one-bar groove. The length is new on the part, so every document
// written before it has to read and write exactly as it did.

@Suite struct LineLengthTests {

    static let notes = [NoteEvent(pitch: Pitch(midi: 62), start: 0, duration: 1, velocity: 96),
                        NoteEvent(pitch: Pitch(midi: 65), start: 5, duration: 2, velocity: 90)]

    @Test func aBasslineWithoutALengthWritesWhatItAlwaysWrote() throws {
        let line = Bassline(notes: Self.notes, sound: "finger", key: Key(tonic: NoteName(.d)))
        let encoded = try SongGraphCodec.encode(line)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("lengthInBars"))
        let decoded = try SongGraphCodec.decode(Bassline.self, from: encoded)
        #expect(decoded == line && decoded.lengthInBars == nil)
        #expect(try SongGraphCodec.encode(decoded) == encoded, "byte for byte")

        // A line as it was written before lengths, straight off the disk.
        let old = Data(#"{"notes":[{"duration":1,"pitch":{"midi":38},"start":0,"velocity":100}],"sound":"sub"}"#.utf8)
        let read = try SongGraphCodec.decode(Bassline.self, from: old)
        #expect(read.lengthInBars == nil && read.sound == "sub")
    }

    @Test func aBasslineKeepsItsLength() throws {
        let line = Bassline(notes: Self.notes, sound: "finger", lengthInBars: 4)
        let back = try SongGraphCodec.decode(Bassline.self, from: try SongGraphCodec.encode(line))
        #expect(back == line && back.lengthInBars == 4)
        // Through the part payload too, where the fields sit beside `type`.
        let kind = try SongGraphCodec.decode(PartKind.self, from: try SongGraphCodec.encode(PartKind.bassline(line)))
        #expect(kind == .bassline(line))
    }

    @Test func aMelodyWithoutALengthWritesWhatItAlwaysWrote() throws {
        let tune = Melody(notes: Self.notes)
        let encoded = try SongGraphCodec.encode(tune)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("lengthInBars"))
        let decoded = try SongGraphCodec.decode(Melody.self, from: encoded)
        #expect(decoded == tune)
        #expect(try SongGraphCodec.encode(decoded) == encoded, "byte for byte")

        // The schema fixtures' melodies — written before lengths — still read.
        let song = try SongGraphCodec.decodeSong(from: Data(schema2SongFixture.utf8))
        guard case .melody(let first) = song.versions[0].kind else { Issue.record("no melody"); return }
        #expect(first.lengthInBars == nil)
    }

    @Test func aMelodyKeepsItsLengthAndATranspositionCarriesIt() throws {
        let tune = Melody(notes: Self.notes, lengthInBars: 4)
        let back = try SongGraphCodec.decode(PartKind.self, from: try SongGraphCodec.encode(PartKind.melody(tune)))
        #expect(back == .melody(tune))
        let moved = tune.transposed(by: 3)
        #expect(moved.lengthInBars == 4, "moving the pitches does not move the bar line")
        #expect(moved.notes.map(\.pitch.midi) == [65, 68])
    }

    @Test func theLoopIsTheStatedLengthElseTheNotesRoundedUp() {
        // The notes reach beat 7: two bars of 4/4.
        #expect(Melody(notes: Self.notes).loopBars(beatsPerBar: 4) == 2)
        #expect(Melody(notes: Self.notes, lengthInBars: 4).loopBars(beatsPerBar: 4) == 4, "a trailing rest is part of it")
        #expect(Bassline(notes: Self.notes).loopBars(beatsPerBar: 4) == 2)
        #expect(Bassline(notes: Self.notes, lengthInBars: 8).loopBars(beatsPerBar: 4) == 8)
        #expect(Bassline(notes: [], lengthInBars: nil).loopBars(beatsPerBar: 4) == 1, "never less than a bar")
        #expect(Bassline(notes: Self.notes, lengthInBars: 0).lengthInBars == 1, "a length is at least a bar")
    }

    // MARK: The groove, repeated

    static func oneBar() -> Groove {
        Groove(stepsPerBar: 16, bars: 1, swing: 0.5, patterns: [
            GroovePattern(voice: .kick, steps: (0..<16).map { [0, 6, 10].contains($0) ? .normal : .rest }),
            GroovePattern(voice: .snare, steps: (0..<16).map { [4, 12].contains($0) ? .accent : .rest }),
        ], degradation: [])
    }

    @Test func aGrooveTilesToTheBarsAsked() {
        let groove = Self.oneBar()
        let four = groove.tiled(toBars: 4)
        #expect(four.bars == 4 && four.stepsPerBar == 16 && four.swing == 0.5)
        #expect(four.stepCount == 64)
        for pattern in four.patterns {
            let original = groove.patterns.first { $0.voice == pattern.voice }!
            #expect(pattern.steps.count == 64)
            for bar in 0..<4 {
                #expect(Array(pattern.steps[(bar * 16)..<((bar + 1) * 16)]) == original.steps, "\(pattern.voice) bar \(bar + 1)")
            }
        }
        #expect(groove.tiled(toBars: 1) == groove, "its own length is itself")
        #expect(groove.tiled(toBars: 0).bars == 1, "never less than a bar")
    }

    @Test func aLongerGrooveIsCutAndAnOddLengthRepeatsFromItsStart() {
        let two = Groove(stepsPerBar: 4, bars: 2, swing: 0, patterns: [
            GroovePattern(voice: .kick, steps: [.normal, .rest, .rest, .rest, .rest, .rest, .accent, .rest]),
        ])
        #expect(two.tiled(toBars: 1).patterns[0].steps == [.normal, .rest, .rest, .rest], "the first bar of itself")
        #expect(two.tiled(toBars: 3).patterns[0].steps
                == [.normal, .rest, .rest, .rest, .rest, .rest, .accent, .rest, .normal, .rest, .rest, .rest])
    }

    @Test func aTiledGrooveKeepsItsDust() throws {
        let dusty = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: Self.oneBar().patterns,
                           degradation: [Degradation(preset: "sp1200", parameters: ["bits": 12], seed: 7)])
        let tiled = dusty.tiled(toBars: 2)
        #expect(!tiled.degradation.isEmpty)
        #expect(tiled.degradation == dusty.degradation)
        #expect(try SongGraphCodec.decode(Groove.self, from: try SongGraphCodec.encode(tiled)) == tiled)
    }
}
