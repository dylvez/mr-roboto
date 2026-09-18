import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import Performance

// M3 Gate B: the merge's rules as a table, and its render measured.

private func key(_ text: String) -> Key { Key(parsing: text)! }

@Suite("Merge: the plan")
struct MergePlanTests {

    private func sample(_ label: String, _ k: String?, _ tempo: Double?, drums: Bool = false) -> MergeFragment {
        MergeFragment(label: label, kind: .sample, key: k.map(key), tempo: tempo, isDrums: drums)
    }
    private func written(_ label: String, _ k: String) -> MergeFragment {
        MergeFragment(label: label, kind: .written, key: key(k))
    }

    @Test("K1: the smallest absolute transposition wins, folded into −6…5")
    func smallestMove() {
        #expect(Merge.semitones(from: key("C major"), to: key("D major")) == 2)
        #expect(Merge.semitones(from: key("C major"), to: key("B major")) == -1)
        #expect(Merge.semitones(from: key("C major"), to: key("G major")) == -5)
        #expect(Merge.semitones(from: key("C major"), to: key("F# major")) == -6, "a tritone goes down")
        #expect(Merge.semitones(from: key("E minor"), to: key("A minor")) == 5)
    }

    @Test("K2: relative keys are one key; a minor fragment stays minor inside the major target")
    func relativeKeys() {
        #expect(Merge.semitones(from: key("A minor"), to: key("C major")) == 0)
        #expect(Merge.semitones(from: key("C major"), to: key("A minor")) == 0)
        #expect(Merge.semitones(from: key("A minor"), to: key("D major")) == 2, "A minor into D major is B minor")
        #expect(Merge.semitones(from: key("D major"), to: key("E minor")) == 5, "D major into E minor's collection is G major")
        let plan = Merge.plan(sample("Horns", "A minor", 92), written("Bass line", "C major"), target: MergeTarget(key: key("C major"), tempo: 92))
        #expect(plan.a.semitones == 0 && plan.b.semitones == 0)
        #expect(plan.a.sentence == "Horns stays in A minor at 92.")
    }

    @Test("K3/K4: a written part moves by arithmetic and is never stretched; a groove never moves")
    func writtenAndGroove() {
        let plan = Merge.plan(written("Bass line", "E minor"), MergeFragment(label: "Groove", kind: .groove),
                              target: MergeTarget(key: key("D major"), tempo: 92))
        #expect(plan.a.semitones == -5, "E minor into D major's collection is B minor, five down")
        #expect(plan.a.ratio == 1, "never stretched")
        #expect(plan.a.key?.name == "B minor")
        #expect(plan.a.sentence == "Bass line down 5 semitones to B minor.")
        #expect(plan.b.isUntouched)
        #expect(plan.b.sentence == "Groove stays: a groove has no key.")
        #expect(plan.flags.isEmpty)
    }

    @Test("T1: within ±12% a sample is stretched; past it the tempo is doubled or halved first")
    func tempo() {
        let (f1, r1) = Merge.stretch(from: 98, to: 92)
        #expect(f1 == 1 && abs(r1 - 98.0 / 92.0) < 1e-9)
        let (f2, r2) = Merge.stretch(from: 170, to: 85)
        #expect(f2 == 0.5 && abs(r2 - 1) < 1e-9, "170 sits under 85")
        let (f3, r3) = Merge.stretch(from: 45, to: 92)
        #expect(f3 == 2 && abs(r3 - 90.0 / 92.0) < 1e-9)
        let (f4, r4) = Merge.stretch(from: 120, to: 92)
        #expect(f4 == 1 && abs(r4 - 120.0 / 92.0) < 1e-9, "no factor gets closer, so it is stretched anyway")
        let plan = Merge.plan(sample("Break", "C major", 170, drums: true), written("Bass line", "C major"), target: MergeTarget(key: key("C major"), tempo: 85))
        #expect(plan.a.tempoFactor == 0.5)
        #expect(plan.a.isUntouched, "170 under 85 is not stretched: each bar counts as two")
        #expect(plan.a.sentence.contains("170 halved to 85"))
        #expect(plan.b.ratio == 1)
    }

    @Test("T2: the target tempo is the song's, then the drums' source, then the first fragment's")
    func targetTempo() {
        let drums = sample("Break", "C major", 96, drums: true)
        let horns = sample("Horns", "C major", 120)
        #expect(Merge.plan(horns, drums).target.tempo == 96)
        #expect(Merge.plan(horns, sample("Keys", "C major", 100)).target.tempo == 120)
        #expect(Merge.plan(horns, drums, target: MergeTarget(tempo: 88)).target.tempo == 88)
    }

    @Test("K1 across the pair: with no song key, the target moves the sample least, and a written part's move is free")
    func targetKey() {
        let horns = sample("Horns", "E major", 92)
        let bass = written("Bass line", "C major")
        let plan = Merge.plan(horns, bass)
        #expect(plan.target.key == key("E major"), "the sample stays, the bass line moves")
        #expect(plan.a.isUntouched && plan.b.semitones == 4)

        // Two samples: whichever target costs fewer semitones in total.
        let plan2 = Merge.plan(sample("Horns", "E major", 92), sample("Keys", "C major", 92))
        #expect([key("E major"), key("C major")].contains(plan2.target.key!))
        #expect(abs(plan2.a.semitones) + abs(plan2.b.semitones) == 4)
        // A tie goes to the target under which the first sample moves down.
        let plan3 = Merge.plan(sample("Horns", "D major", 92), sample("Keys", "C major", 92))
        #expect(plan3.target.key == key("C major"))
        #expect(plan3.a.semitones == -2)
        #expect(!(plan2.a.movesPitch && plan2.b.movesPitch), "never both when moving one would do")
    }

    @Test("F1: past ±4 semitones a sample is flagged; formants are held from ±3")
    func flags() {
        let plan = Merge.plan(sample("Horns", "C major", 92), written("Bass line", "F major"), target: MergeTarget(key: key("F major"), tempo: 92))
        #expect(plan.a.semitones == 5)
        #expect(plan.a.preservesFormants)
        #expect(plan.a.flags.count == 1)
        #expect(plan.a.flags[0].contains("timbre"))
        #expect(plan.b.flags.isEmpty, "a written part has no timbre to lose")
        let mild = Merge.move(sample("Horns", "C major", 92), to: MergeTarget(key: key("D major"), tempo: 92))
        #expect(!mild.preservesFormants && mild.flags.isEmpty)
        let three = Merge.move(sample("Horns", "C major", 92), to: MergeTarget(key: key("Eb major"), tempo: 92))
        #expect(three.preservesFormants && three.flags.isEmpty)
    }

    @Test("the table: thirty pairs produce the plan the rules say")
    func table() {
        struct Row { var from: String; var to: String; var semitones: Int }
        let rows: [Row] = [
            .init(from: "C major", to: "C major", semitones: 0), .init(from: "C major", to: "C# major", semitones: 1),
            .init(from: "C major", to: "D major", semitones: 2), .init(from: "C major", to: "Eb major", semitones: 3),
            .init(from: "C major", to: "E major", semitones: 4), .init(from: "C major", to: "F major", semitones: 5),
            .init(from: "C major", to: "F# major", semitones: -6), .init(from: "C major", to: "G major", semitones: -5),
            .init(from: "C major", to: "Ab major", semitones: -4), .init(from: "C major", to: "A major", semitones: -3),
            .init(from: "C major", to: "Bb major", semitones: -2), .init(from: "C major", to: "B major", semitones: -1),
            .init(from: "A minor", to: "C major", semitones: 0), .init(from: "A minor", to: "G major", semitones: -5),
            .init(from: "A minor", to: "A major", semitones: -3), .init(from: "A minor", to: "D minor", semitones: 5),
            .init(from: "A minor", to: "E minor", semitones: -5), .init(from: "A minor", to: "F# minor", semitones: -3),
            .init(from: "D major", to: "B minor", semitones: 0), .init(from: "D major", to: "E minor", semitones: 5),
            .init(from: "D major", to: "A minor", semitones: -2), .init(from: "D major", to: "F major", semitones: 3),
            .init(from: "F major", to: "D major", semitones: -3), .init(from: "F major", to: "D minor", semitones: 0),
            .init(from: "E minor", to: "D major", semitones: -5), .init(from: "E minor", to: "C major", semitones: 5),
            .init(from: "Bb major", to: "G minor", semitones: 0), .init(from: "Bb major", to: "E major", semitones: -6),
            .init(from: "G major", to: "A minor", semitones: 5), .init(from: "G major", to: "C major", semitones: 5),
        ]
        for row in rows {
            let got = Merge.semitones(from: key(row.from), to: key(row.to))
            #expect(got == row.semitones, "\(row.from) → \(row.to): expected \(row.semitones), got \(got)")
            // The move never exceeds a tritone, and a written part in the same key stays.
            #expect(abs(got) <= 6)
        }
    }
}

@Suite("Merge: the render")
struct MergeRenderTests {

    /// A steady tone: `frequency` Hz for `seconds`.
    private func tone(_ frequency: Double, seconds: Double, rate: Double = 48_000) -> [[Float]] {
        let frames = Int(seconds * rate)
        return [(0..<frames).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }]
    }

    /// The fundamental of a steady tone from its zero crossings, ignoring the ends.
    private func frequency(of samples: [Float], rate: Double) -> Double {
        let start = samples.count / 4, end = samples.count * 3 / 4
        var crossings: [Int] = []
        for i in (start + 1)..<end where samples[i - 1] < 0 && samples[i] >= 0 { crossings.append(i) }
        guard crossings.count > 2, let first = crossings.first, let last = crossings.last else { return 0 }
        return Double(crossings.count - 1) * rate / Double(last - first)
    }

    private func cents(_ measured: Double, _ expected: Double) -> Double { 1200 * log2(measured / expected) }

    @Test("a G2 loop at 100 rendered to D at 92 measures within 5 cents and 2 ms of the plan")
    func g2ToD() throws {
        // G2 is 98 Hz. G major into D major is five up (K1 folds it to −5: down to D2, 73.4 Hz).
        let move = Merge.move(MergeFragment(label: "Loop", kind: .sample, key: key("G major"), tempo: 100),
                              to: MergeTarget(key: key("D major"), tempo: 92))
        #expect(move.semitones == -5)
        #expect(abs(move.ratio - 100.0 / 92.0) < 1e-9)

        let rate = 48_000.0
        let input = tone(98, seconds: 2.4, rate: rate)
        let output = try MergeRender.audio(input, sampleRate: rate, move: move)
        let expectedFrequency = 98 * pow(2, Double(move.semitones) / 12)
        let measured = frequency(of: output[0], rate: rate)
        #expect(abs(cents(measured, expectedFrequency)) < 5, "measured \(measured) Hz, expected \(expectedFrequency)")
        // And the same render twice is the same bytes.
        #expect(try MergeRender.audio(input, sampleRate: rate, move: move) == output)

        // Two semitones down, the case the default preset got 26 cents wrong.
        let two = Merge.move(MergeFragment(label: "Loop", kind: .sample, key: key("D major"), tempo: 92),
                             to: MergeTarget(key: key("C major"), tempo: 92))
        #expect(two.semitones == -2)
        let down = try MergeRender.audio(input, sampleRate: rate, move: two)
        #expect(abs(cents(frequency(of: down[0], rate: rate), 98 * pow(2, -2.0 / 12))) < 5)
        let expectedFrames = Double(input[0].count) * move.ratio
        #expect(abs(Double(output[0].count) - expectedFrames) / rate < 0.002, "\(output[0].count) frames, expected \(expectedFrames)")

        // An untouched move is the input, bit for bit.
        let still = Merge.move(MergeFragment(label: "Loop", kind: .sample, key: key("G major"), tempo: 92),
                               to: MergeTarget(key: key("G major"), tempo: 92))
        #expect(try MergeRender.audio(input, sampleRate: rate, move: still) == input)
    }

    @Test("slices re-time with the stretch and re-base on the region; written parts move by arithmetic")
    func slicesAndWritten() {
        let markers = [SliceMarker(position: 10.0), SliceMarker(position: 10.5), SliceMarker(position: 11.25), SliceMarker(position: 13)]
        let moved = MergeRender.slices(markers, region: SongGraph.TimeRange(start: 10, end: 12), ratio: 1.1)
        #expect(moved.count == 3, "the marker outside the region is dropped")
        #expect(abs(moved[1].position - 0.55) < 1e-9)
        #expect(abs(moved[2].position - 1.375) < 1e-9)

        let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 1)], sound: "finger", key: key("E minor"))
        let move = Merge.move(MergeFragment(label: "Bass line", kind: .written, key: key("E minor")), to: MergeTarget(key: key("D major")))
        let transposed = MergeRender.bassline(line, move: move)
        #expect(transposed.notes[0].pitch.midi == 35)
        #expect(transposed.key?.name == "B minor")
        #expect(transposed.sound == "finger")

        let c = NoteName(.c).pitchClass, f = NoteName(.f).pitchClass, d = NoteName(.d).pitchClass, g = NoteName(.g).pitchClass
        let progression = Progression(key: key("C major"), bars: [ProgressionBar(Chord(c, .major)), ProgressionBar(Chord(f, .major))])
        let up = MergeRender.progression(progression, move: Merge.move(MergeFragment(label: "Chords", kind: .written, key: key("C major")),
                                                                        to: MergeTarget(key: key("D major"))))
        #expect(up.key.name == "D major")
        #expect(up.chords.map { $0.root } == [d, g])
    }
}
