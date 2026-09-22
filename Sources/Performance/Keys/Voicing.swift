import Foundation
import MusicTheory
import SongGraph

/// How a written chord becomes notes under the fingers.
///
/// A `Progression` is a decision about harmony, not a performance: "Dm7 for four beats" says
/// nothing about which four notes sound or where they sit. Something has to choose, and until now
/// two things did — `PartPlayer` voiced a progression one way to audition it, and the transport did
/// not voice it at all. One rule, in one place, is the point of this file: the chords you hear when
/// you press play on the Chords surface are the same chords, in the same octave, that the form
/// plays back to you.
///
/// The rule is deliberately plain. This app's pitched voices are a pad and a Rhodes, and a close
/// root-position voicing in the octave below middle C is what either of them is for. Anything
/// cleverer — drop 2, rootless left hand, a voice-leading pass across the bar line — is a decision
/// a player makes, and when this app grows one it will be a persona's decision, kept as a version,
/// not a constant buried in the transport.
public enum Voicing {

    /// The octave the chord's root sits in. C3 is MIDI 48: the left hand's home, and low enough
    /// that a seventh on top still clears the vocal register.
    public static let rootOctave = 3

    /// How hard the chord is struck. Under a melody, not over it.
    public static let velocity = 88

    /// How much of its written span a chord actually holds, 0…1. Just short of the whole, so a
    /// change of chord is heard as a change rather than as one note replacing another underneath a
    /// sustain — and so a repeat of the *same* chord re-articulates instead of blurring into one
    /// long note.
    public static let hold = 0.95

    /// A progression as notes, in beats from its own start.
    ///
    /// Inversions are honoured: `Chord.pitches(octave:)` moves the bottom note up an octave per
    /// inversion, so a progression written with a bass line under it voices the way it reads.
    public static func notes(for progression: Progression,
                             octave: Int = rootOctave,
                             velocity: Int = velocity,
                             hold: Double = hold) -> [NoteEvent] {
        var out: [NoteEvent] = []
        var beat = 0.0
        for span in progression.bars.flatMap(\.chords) {
            let duration = max(0.01, span.beats * hold)
            for pitch in span.chord.pitches(octave: octave) {
                out.append(NoteEvent(pitch: pitch, start: beat, duration: duration, velocity: velocity))
            }
            beat += span.beats
        }
        return out.sorted { $0.start < $1.start }
    }

    /// What the progression is written to last, in beats: the sum of its spans, not where its last
    /// note stops. The two differ by `hold`, and it is the written length a form repeats on.
    public static func lengthInBeats(of progression: Progression) -> Double {
        progression.bars.reduce(0) { $0 + $1.beats }
    }
}
