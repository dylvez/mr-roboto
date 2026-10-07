import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The four players and the twelve feels the new genres were written for.
@Suite("New bass hands and feels")
struct NewHandsAndFeelsTests {

    static func request(_ lineage: BassLineage, density: Double = 0.6, chords: [ChordSpan] = BassWriterTests.dm7g7,
                        bars: Int? = nil) -> BassRequest {
        BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: chords, groove: BassWriterTests.groove(),
                    tempo: 92, lineage: lineage, density: density, seed: 7, bars: bars)
    }

    @Test("Every new hand writes a line in its register, and the same line twice", arguments: [BassLineage.dub, .afrobeat, .pedal, .boomBap])
    func writes(lineage: BassLineage) {
        let line = BassWriter.write(Self.request(lineage))
        #expect(!line.notes.isEmpty, "\(lineage)")
        for note in line.notes { #expect(lineage.register.contains(note.pitch.midi), "\(lineage): \(note.pitch.midi)") }
        #expect(line == BassWriter.write(Self.request(lineage)))
        #expect(!lineage.about.isEmpty && lineage.name != lineage.rawValue)
    }

    @Test("Dub leaves room: few attacks, the root held from one")
    func dub() throws {
        let line = BassWriter.write(Self.request(.dub, density: 0.5))
        let first = try #require(line.notes.min { $0.start < $1.start })
        #expect(first.start < 0.05 && first.duration > 1, "the root on one, held")
        #expect(line.notes.count <= 8, "two bars, at most four attacks a bar: \(line.notes.count)")
    }

    @Test("The afrobeat ostinato is the same figure every bar")
    func afrobeat() {
        let chords = [ChordSpan(Chord(.d, .minorSeventh), beats: 8)]
        let line = BassWriter.write(Self.request(.afrobeat, chords: chords))
        let first = line.notes.filter { $0.start < 4 }.map { ($0.start, $0.pitch.midi) }
        let second = line.notes.filter { $0.start >= 4 }.map { ($0.start - 4, $0.pitch.midi) }
        #expect(first.count == second.count && zip(first, second).allSatisfy { abs($0.0 - $1.0) < 1e-6 && $0.1 == $1.1 })
    }

    @Test("A pedal is one note a chord, held across the bars the chord lasts")
    func pedal() {
        let chords = [ChordSpan(Chord(.d, .minor), beats: 8), ChordSpan(Chord(.aSharp, .major), beats: 8)]
        let line = BassWriter.write(Self.request(.pedal, chords: chords, bars: 4))
        #expect(line.notes.count == 2, "\(line.notes.map { ($0.start, $0.duration) })")
        #expect(line.notes.allSatisfy { $0.duration > 7.5 })
    }

    @Test("Boom-bap plays on the kick's hits, cut short of the next")
    func boomBap() {
        let line = BassWriter.write(Self.request(.boomBap, density: 0.3))
        // G1's kicks: 0, 1.5, 4, 5.5 — late by the hand's lag, never held to the next.
        let lag = BassLineage.boomBap.defaultLagMS / 1000 * 92 / 60
        let starts = line.notes.map { $0.start - lag }.sorted()
        #expect(zip(starts, [0, 1.5, 4, 5.5]).allSatisfy { abs($0 - $1) < 0.01 }, "\(starts)")
        #expect(line.notes.allSatisfy { $0.duration <= 0.76 })
    }

    @Test("The new feels are in the library, valid, and play only voices the kits have")
    func feels() throws {
        let names = ["Big Band Swing", "Ska", "Steppers", "Rockers", "Dancehall", "New Jack Swing", "Slow Jam", "Cinematic Toms",
                     "Rumba Flamenca", "Bulerías", "Bulgar", "Saidi"]
        for name in names {
            let feel = try #require(FeelLibrary.standard.feel(named: name), "\(name)")
            #expect(feel.groove.patterns.allSatisfy { $0.steps.count == feel.groove.stepCount }, "\(name)")
        }
        let swing = try #require(FeelLibrary.standard.feel(named: "Big Band Swing"))
        #expect(swing.groove.stepsPerBar == 12, "on the triplet grid")
        let bulerias = try #require(FeelLibrary.standard.feel(named: "Bulerías"))
        #expect(bulerias.timeSignature == TimeSignature(12, 8))
        let accents = bulerias.groove.patterns.first { $0.voice == .clap }?.steps.indices.filter { bulerias.groove.patterns.first { $0.voice == .clap }!.steps[$0] == .accent }
        #expect(accents == [2, 5, 7, 9, 11], "the compás' 3, 6, 8, 10 and 12")
    }
}
