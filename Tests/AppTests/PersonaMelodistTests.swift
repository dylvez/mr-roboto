import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The Melodist: a tune as a shape, and the one thing about it nobody could sing.

@Suite("Melodist: the tune, read")
struct PersonaMelodistTests {
    private let c = Key(tonic: NoteName(.c))

    /// Notes from MIDI numbers, a beat each.
    private func tune(_ midi: [Int], duration: Double = 1) -> [NoteEvent] {
        midi.enumerated().map { NoteEvent(pitch: Pitch(midi: $1), start: Double($0) * duration, duration: duration) }
    }

    private func observe(_ midi: [Int], duration: Double = 1, chords: [(Chord, Double)] = []) -> MelodyObservation {
        MelodyObservation(label: "Tune", key: c, notes: tune(midi, duration: duration), chords: chords.map { ($0.0, $0.1) })
    }

    @Test("range, leaps and steps are what a singer feels")
    func shape() {
        // A scale up an octave: every move a step, an octave of range, no leap.
        let scale = observe([60, 62, 64, 65, 67, 69, 71, 72])
        #expect(scale.rangeSemitones == 12 && scale.stepwiseRatio == 1 && scale.largestLeapSemitones == 2)
        // An arpeggio: no steps at all.
        let arpeggio = observe([60, 64, 67, 72, 67, 64])
        #expect(arpeggio.stepwiseRatio == 0 && arpeggio.largestLeapSemitones == 5)
        // Two octaves and a fourth is past what one voice covers.
        #expect(observe([48, 50, 77]).rangeSemitones == 29)
    }

    @Test("a figure that comes back is the tune; a walk that never repeats is not")
    func motif() {
        // The same three-note shape twice, moved up a third: the intervals repeat, the pitches do not.
        let stated = observe([60, 62, 64, 67, 64, 66, 68, 71])
        #expect(stated.motifRatio > 0, "a figure moved to a new degree still counts")
        // A line whose every interval differs.
        let walk = observe([60, 61, 63, 66, 70, 75])
        #expect(walk.motifRatio == 0, "\(walk.motifRatio)")
    }

    @Test("breathing and the peak: a tune that never stops, and a ceiling touched over and over")
    func breathAndPeak() {
        // Notes a beat long, one per beat: nothing rests.
        #expect(observe([60, 62, 64, 65]).restRatio == 0)
        // Three half-beat notes at beats 0, 1 and 2: the tune runs 2.5 beats and sounds for 1.5.
        let sparse = MelodyObservation(label: "T", key: c, notes: [
            NoteEvent(pitch: Pitch(midi: 60), start: 0, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 64), start: 1, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 67), start: 2, duration: 0.5),
        ])
        #expect(abs(sparse.restRatio - 0.4) < 0.01, "\(sparse.restRatio)")
        // The top note once, against the top note four times.
        #expect(observe([60, 64, 72, 64, 60]).peakCount == 1)
        #expect(observe([72, 60, 72, 62, 72, 64, 72]).peakCount == 4)
    }

    @Test("landing on the chord: a chord tone agrees, a passing note does not, and no chords means nothing to disagree with")
    func chordTones() throws {
        let cMajor = Chord(root: NoteName(.c).pitchClass, quality: .major)
        let f = Chord(root: NoteName(.f).pitchClass, quality: .major)
        // C E over C major, then F A over F major: all chord tones.
        let landing = observe([60, 64, 65, 69], chords: [(cMajor, 0), (f, 2)])
        #expect(landing.chordToneRatio == 1 && landing.firstClash == nil)
        // A D over C major is not a chord tone.
        let clashing = observe([60, 62, 65, 69], chords: [(cMajor, 0), (f, 2)])
        #expect(clashing.chordToneRatio == 0.75)
        let clash = try #require(clashing.firstClash)
        #expect(clash.note.pitch.midi == 62 && clash.chord.root == cMajor.root)
        // With no chords stated, nothing is wrong.
        #expect(observe([60, 61, 62]).chordToneRatio == 1)

        // By length: three passing eighths between two held chord tones are a fifth of the tune,
        // not three fifths of its notes. Counted by the note this read 40% and was sent back.
        func note(_ midi: Int, _ start: Double, _ duration: Double) -> NoteEvent {
            NoteEvent(pitch: Pitch(midi: midi), start: start, duration: duration, velocity: 96)
        }
        let walked = MelodyObservation(label: "", key: .cMajor,
                                       notes: [note(60, 0, 2), note(62, 2, 0.5), note(65, 2.5, 0.5), note(69, 3, 0.5), note(67, 3.5, 4)],
                                       chords: [(cMajor, 0)])
        #expect(abs(walked.chordToneRatio - 6 / 7.5) < 1e-9)
        #expect(Melodist().read(walked).first { $0.rule == "melodist.lands-on-the-chord" }?.holds == true)
        // A long note off the chord is what the reading names, however late it comes.
        let leaning = MelodyObservation(label: "", key: .cMajor,
                                        notes: [note(62, 0, 0.5), note(64, 0.5, 1), note(65, 1.5, 3), note(64, 4.5, 0.5)],
                                        chords: [(cMajor, 0)])
        #expect(leaning.firstClash?.note.pitch.midi == 62 && leaning.longestClash?.note.pitch.midi == 65)
        let said = try #require(Melodist().read(leaning).first { $0.rule == "melodist.lands-on-the-chord" })
        #expect(!said.holds && said.says.contains("the longest note off it is the 4 over C"), "\(said.says)")
    }

    @Test("the readings: the shape first, then the number that is wrong, in degrees and semitones")
    func readings() throws {
        // Two octaves and a fourth, all leaps, nothing repeating, never resting.
        let hard = Melodist().read(observe([48, 60, 72, 65, 77, 53]))
        let byRule = Dictionary(hard.map { ($0.rule, $0) }, uniquingKeysWith: { a, _ in a })
        let range = try #require(byRule["melodist.singable-range"])
        #expect(!range.holds && range.says.contains("29 semitones"))
        #expect(byRule["melodist.mostly-steps"]?.holds == false)
        #expect(byRule["melodist.it-breathes"]?.holds == false)
        #expect(hard.allSatisfy { $0.rule.hasPrefix("melodist.") })

        // A singable one holds everywhere it is judged.
        let easy = Melodist().read(MelodyObservation(label: "T", key: c, notes: [
            NoteEvent(pitch: Pitch(midi: 60), start: 0, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 62), start: 1, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 64), start: 2, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 62), start: 3, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 64), start: 4, duration: 0.5),
            NoteEvent(pitch: Pitch(midi: 65), start: 5, duration: 0.5),
        ]))
        #expect(easy.first { $0.rule == "melodist.singable-range" }?.holds == true)
        #expect(easy.first { $0.rule == "melodist.it-breathes" }?.holds == true)
        #expect(easy.first { $0.rule == "melodist.mostly-steps" }?.holds == true)

        // One note is not a tune, and it says so rather than reading nothing.
        let single = Melodist().read(observe([60]))
        #expect(single.count == 1 && !single[0].holds && single[0].says.contains("not a tune yet"))
    }

    @Test("the tune is the Melodist's: everyone else defers, and it defers on everyone else's")
    func ownership() {
        let proposal = PersonaProposal.writeMelody(rangeSemitones: 12, largestLeapSemitones: 7, stepwiseRatio: 0.8,
                                                   chordToneRatio: 0.8, notesPerBar: 4, restRatio: 0.2, motifRatio: 0.4)
        for persona in Cast.standard.personas where persona.bible.id != .melodist {
            guard case .defer_(let to, _) = persona.consider(proposal) else {
                Issue.record("\(persona.bible.id) did not defer on a melody")
                continue
            }
            #expect(to == .melodist)
        }
        #expect(VerdictShape(Melodist().consider(proposal)) == .agree)
        guard case .defer_(let to, _) = Melodist().consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90)) else {
            Issue.record("the Melodist ruled on the swing")
            return
        }
        #expect(to == .beatmaker)
    }
}
