import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// B2: the writer's own arithmetic. The bible's golden tests live with the Bassist, which reads
/// the writer's output back; these are the structural facts a line has to have before a persona
/// is even asked.
@Suite("Bass writer")
struct BassWriterTests {

    /// G1's groove: 92 bpm, hats on the grid, kick on 1 and the and of 2, two bars.
    static func groove() -> Groove {
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : ($0 == "." ? .ghost : .rest) })
        }
        return Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            line(.kick,      "x-----x---------x-----x---------"),
            line(.snare,     "----x-------x-------x-------x---"),
            line(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-"),
        ])
    }

    static let dm7g7: [ChordSpan] = [
        ChordSpan(Chord(.d, .minorSeventh), beats: 4),
        ChordSpan(Chord(.g, .dominantSeventh), beats: 4),
    ]

    static func request(_ lineage: BassLineage, density: Double = 0.5, lag: Double? = nil,
                        early: Bool = false, chords: [ChordSpan] = dm7g7, seed: UInt64 = 7) -> BassRequest {
        BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: chords, groove: groove(),
                    tempo: 92, lineage: lineage, lagMS: lag, density: density, earlyAlternation: early, seed: seed)
    }

    @Test("the same request writes the same line; a different seed writes a different one")
    func deterministic() {
        let a = BassWriter.write(Self.request(.palladino))
        let b = BassWriter.write(Self.request(.palladino))
        let c = BassWriter.write(Self.request(.palladino, seed: 8))
        #expect(a == b)
        #expect(a != c)
        #expect(a.sound == "finger")
    }

    @Test("every lineage stays inside its register", arguments: BassLineage.allCases)
    func register(lineage: BassLineage) {
        let line = BassWriter.write(Self.request(lineage, density: 1))
        #expect(!line.notes.isEmpty)
        for note in line.notes {
            #expect(lineage.register.contains(note.pitch.midi), "\(lineage): \(note.pitch) is outside \(lineage.register)")
        }
    }

    @Test("Palladino: the lag is on the onsets and the note-offs are on the beat")
    func palladinoPlacement() {
        let line = BassWriter.write(Self.request(.palladino, lag: 40))
        let beat = 60.0 / 92
        // The downbeat note of bar one: 40 ms after the kick, which is at 0.
        let first = line.notes.min { $0.start < $1.start }!
        #expect(abs(first.start * beat * 1000 - 40) < 1)
        // Note-offs of the displaced notes land on beat lines.
        let displaced = line.notes.filter { $0.velocity > 60 }
        let onBeat = displaced.filter { abs($0.end - $0.end.rounded()) < 1e-6 }
        #expect(Double(onBeat.count) / Double(displaced.count) > 0.6, "\(onBeat.count) of \(displaced.count) end on a beat")
    }

    @Test("Palladino: a root move of a fourth is approached from the half-step below")
    func approach() {
        let line = BassWriter.write(Self.request(.palladino))
        // D to G at beat 4 (a fourth): F# (pitch class 6) somewhere in beat 3.5…4.
        let fSharpBefore = line.notes.contains { $0.pitch.pitchClass == .fSharp && $0.start >= 3 && $0.start < 4 }
        #expect(fSharpBefore, "no F# before the G7: \(line.notes.map { "\($0.pitch)@\($0.start)" })")
        // And G back to D at the wrap (beat 8): C#.
        let cSharpBefore = line.notes.contains { $0.pitch.pitchClass == .cSharp && $0.start >= 7 && $0.start < 8 }
        #expect(cSharpBefore)
    }

    @Test("density moves the attack count inside R14's budget")
    func density() {
        let sparse = BassWriter.write(Self.request(.palladino, density: 0))
        let busy = BassWriter.write(Self.request(.palladino, density: 1))
        func attacks(_ line: Bassline) -> Int { Set(line.notes.filter { $0.velocity > 60 }.map { ($0.start * 100).rounded() }).count }
        #expect(attacks(sparse) < attacks(busy))
        #expect(attacks(busy) <= 6 * 2 + 2, "at 92 bpm a bar gets at most six attacks plus approaches")
    }

    @Test("Programmed: the line is the kick, note for note, held to the next kick")
    func programmed() {
        let line = BassWriter.write(Self.request(.programmed))
        let kicks = BassWriter.kickOnsets(in: Self.groove(), beatsPerBar: 4)
        #expect(line.notes.count == kicks.count)
        for (note, kick) in zip(line.notes, kicks) {
            #expect(abs(note.start - kick) < 1e-6)
            #expect(note.duration > 1, "held, not plucked")
        }
        #expect(line.sound == "sub")
    }

    @Test("Thundercat: the change is voiced with the seventh and the third")
    func thundercatVoicing() {
        let line = BassWriter.write(Self.request(.thundercat, density: 0.6))
        let atZero = Set(line.notes.filter { abs($0.start - $0.start.rounded()) < 0.05 && $0.start < 0.5 }.map(\.pitch.pitchClass))
        // Dm7: D, F (third), C (seventh).
        #expect(atZero.isSuperset(of: [.d, .f, .c]), "\(atZero)")
    }

    @Test("early alternation puts every other onset up to 25 ms early")
    func earlyAlternation() {
        let line = BassWriter.write(Self.request(.palladino, lag: 40, early: true))
        let beat = 60.0 / 92
        let kicks = BassWriter.kickOnsets(in: Self.groove(), beatsPerBar: 4)
        let displaced = line.notes.filter { $0.velocity > 60 }.sorted { $0.start < $1.start }
        var early = 0, late = 0
        for note in displaced {
            let nearest = kicks.min { abs($0 - note.start) < abs($1 - note.start) }!
            guard abs(nearest - note.start) < 0.3 else { continue }   // a pickup or an and, not a kick note
            let ms = (note.start - nearest) * beat * 1000
            if ms < 0 { early += 1; #expect(ms >= -25.5) } else if ms > 1 { late += 1 }
        }
        #expect(early > 0 && late > 0)
    }

    @Test("over an inversion every note is the chord's: the fifth of D/F♯ is A, not the C sharp a fifth over its bass",
          arguments: [BassLineage.rolling, .rootFifth, .octave, .oneDrop])
    func inversions(lineage: BassLineage) throws {
        let chords = try ["D/F#", "Gmaj7/F#", "A7/C#", "Em7/D"].map { ChordSpan(try #require(Chord(parsing: $0)), beats: 4) }
        var request = Self.request(lineage, chords: chords)
        request.bars = 4
        let line = BassWriter.write(request)
        #expect(!line.notes.isEmpty)
        for note in line.notes {
            let chord = chords[min(chords.count - 1, Int(note.start / 4))].chord
            #expect(chord.pitchClassSet.contains(note.pitch.pitchClass), "\(note.pitch) at beat \(note.start) is no note of \(chord.symbol)")
        }
        // The line still starts each bar on the chord's bass note (a one drop leaves beat one empty).
        for (bar, span) in chords.enumerated() where lineage != .oneDrop {
            let first = try #require(line.notes.first { $0.start >= Double(bar) * 4 - 1e-6 && $0.start < Double(bar) * 4 + 1 })
            #expect(first.pitch.pitchClass == span.chord.bass, "bar \(bar + 1) starts on \(first.pitch)")
        }
        // In root position nothing has moved.
        let plain = BassWriter.write(Self.request(lineage))
        #expect(plain.notes.allSatisfy { note in Self.dm7g7[min(1, Int(note.start / 4))].chord.pitchClassSet.contains(note.pitch.pitchClass) }
                || lineage == .oneDrop)
    }

    @Test("with no chords, the writer uses the key's I–IV–V–I and says so")
    func defaultHarmony() {
        let request = Self.request(.palladino, chords: [])
        #expect(request.usesDefaultChords)
        #expect(request.effectiveChords.count == 4)
        let line = BassWriter.write(request)
        #expect(!line.notes.isEmpty)
    }
}
