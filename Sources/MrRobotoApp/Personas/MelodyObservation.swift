import Foundation
import MusicTheory
import SongGraph

/// A tune as the Melodist reads it: how far it travels, how it moves between notes, how much of it
/// you have heard before, whether it lands on the chord underneath, and whether it ever stops.
///
/// Arithmetic on `SongGraph.Melody`, with the progression underneath it when the song has one.
/// Nothing here is audio: a melody is written before it is sung, and the Melodist reads what is on
/// the grid so it can answer before anything is recorded.
public struct MelodyObservation: Hashable, Sendable {
    public var label: String
    public var key: Key
    public var beatsPerBar: Int
    public var notes: [NoteEvent]
    /// The chords underneath, each with the beat it starts on. Empty when the song states none.
    public var chords: [(chord: Chord, start: Double)]

    public static func == (a: MelodyObservation, b: MelodyObservation) -> Bool {
        a.label == b.label && a.key == b.key && a.beatsPerBar == b.beatsPerBar && a.notes == b.notes
            && a.chords.map(\.chord) == b.chords.map(\.chord) && a.chords.map(\.start) == b.chords.map(\.start)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(label); hasher.combine(key); hasher.combine(notes)
    }

    public init(label: String, key: Key, beatsPerBar: Int = 4, notes: [NoteEvent],
                chords: [(chord: Chord, start: Double)] = []) {
        self.label = label
        self.key = key
        self.beatsPerBar = beatsPerBar
        self.notes = notes.sorted { $0.start < $1.start }
        self.chords = chords
    }

    // MARK: The numbers

    /// Lowest to highest, in semitones. What a singer is being asked for.
    public var rangeSemitones: Double {
        guard let low = notes.map(\.pitch.midi).min(), let high = notes.map(\.pitch.midi).max() else { return 0 }
        return Double(high - low)
    }

    /// The intervals between consecutive notes, signed, in semitones.
    public var intervals: [Int] {
        zip(notes, notes.dropFirst()).map { $1.pitch.midi - $0.pitch.midi }
    }

    /// The largest single leap, unsigned.
    public var largestLeapSemitones: Double { Double(intervals.map(abs).max() ?? 0) }

    /// Moves of a tone or less, over all moves. A tune that only steps is a scale; one that only
    /// leaps is an arpeggio. Singable tunes are mostly steps with a few leaps in them.
    public var stepwiseRatio: Double {
        guard !intervals.isEmpty else { return 1 }
        return Double(intervals.filter { abs($0) <= 2 }.count) / Double(intervals.count)
    }

    /// Notes sounding a note of the chord under them, over the notes that had a chord under them.
    /// 1 when the song states no chords: nothing disagrees with a harmony nobody wrote.
    public var chordToneRatio: Double {
        let judged = notes.compactMap { note -> Bool? in
            guard let chord = chord(at: note.start) else { return nil }
            return chord.pitchClasses.contains(note.pitch.pitchClass)
        }
        guard !judged.isEmpty else { return 1 }
        return Double(judged.filter { $0 }.count) / Double(judged.count)
    }

    /// The first note that sits outside the chord under it, for the sentence that names it.
    public var firstClash: (note: NoteEvent, chord: Chord)? {
        for note in notes {
            guard let chord = chord(at: note.start) else { continue }
            if !chord.pitchClasses.contains(note.pitch.pitchClass) { return (note, chord) }
        }
        return nil
    }

    func chord(at beat: Double) -> Chord? {
        chords.last { $0.start <= beat + 1e-9 }?.chord
    }

    public var lengthInBeats: Double {
        notes.map { $0.start + $0.duration }.max() ?? 0
    }

    public var bars: Double { lengthInBeats / Double(max(1, beatsPerBar)) }

    /// Notes a bar: how busy it is.
    public var notesPerBar: Double { bars <= 0 ? 0 : Double(notes.count) / bars }

    /// The share of the tune's length that nothing is sounding. A tune with no rests never breathes,
    /// and a singer cannot sing it.
    public var restRatio: Double {
        guard lengthInBeats > 0 else { return 0 }
        var sounding = 0.0
        var covered = -1.0
        for note in notes {
            let start = max(note.start, covered)
            let end = note.start + note.duration
            if end > start { sounding += end - start }
            covered = max(covered, end)
        }
        return max(0, min(1, 1 - sounding / lengthInBeats))
    }

    /// How many times the highest note is struck. A tune has one peak; a tune that touches its
    /// ceiling over and over has no climax, only a range.
    public var peakCount: Double {
        guard let high = notes.map(\.pitch.midi).max() else { return 0 }
        return Double(notes.filter { $0.pitch.midi == high }.count)
    }

    /// The longest run of notes whose shape appears again later, as a share of the tune.
    ///
    /// Shape rather than pitch: the intervals, so a figure repeated a third up still counts. This
    /// is what makes a tune a tune rather than a walk, and what a listener sings back.
    public var motifRatio: Double {
        let steps = intervals
        guard steps.count >= 4 else { return 0 }
        var best = 0
        // Longest run of intervals that occurs at least twice, checked from long to short.
        for length in stride(from: min(8, steps.count / 2), through: 2, by: -1) {
            for start in 0...(steps.count - length) {
                let figure = Array(steps[start..<(start + length)])
                var found = 0
                for other in 0...(steps.count - length) where Array(steps[other..<(other + length)]) == figure {
                    found += 1
                }
                if found >= 2 { best = max(best, length) }
            }
            if best > 0 { break }
        }
        return Double(best) / Double(steps.count)
    }

    /// The tune's notes as scale degrees, for the sentence.
    public var degrees: [String] {
        notes.map { note in
            let distance = key.tonic.pitchClass.distance(to: note.pitch.pitchClass)
            return Self.degreeNames[distance]
        }
    }

    static let degreeNames = ["1", "b2", "2", "b3", "3", "4", "b5", "5", "b6", "6", "b7", "7"]

    // MARK: Reading a song

    /// A melody part, with the song's newest progression underneath it.
    public static func of(_ melody: Melody, label: String, key: Key, progression: Progression? = nil,
                          beatsPerBar: Int = 4) -> MelodyObservation {
        var chords: [(chord: Chord, start: Double)] = []
        var beat = 0.0
        for span in progression?.bars.flatMap(\.chords) ?? [] {
            chords.append((span.chord, beat))
            beat += span.beats
        }
        return MelodyObservation(label: label, key: key, beatsPerBar: beatsPerBar, notes: melody.notes, chords: chords)
    }
}
