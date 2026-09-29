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

    /// One move of a tune: which way it goes to the next note, and how long until it.
    struct Move: Hashable {
        /// Up, down or the same note again: 1, -1, 0.
        var direction: Int
        /// In beats, to the sixteenth.
        var gap: Double
    }

    var moves: [Move] {
        zip(notes, notes.dropFirst()).map { a, b in
            Move(direction: (b.pitch.midi - a.pitch.midi).signum(),
                 gap: ((b.start - a.start) * 4).rounded(.toNearestOrEven) / 4)
        }
    }

    /// The fewest moves that make a figure: three, which is four notes. Two notes in a rhythm come
    /// back by accident in any tune.
    public static let shortestFigure = 3

    /// The fewest notes a line has before it is read for a figure, and the fewest a bar. A pad
    /// holding a chord every four bars has no figure in it and is not short of one.
    public static let fewestNotesForAFigure = 8

    /// Whether the line is busy enough to have a figure in it at all.
    public var hasRoomForAFigure: Bool {
        notes.count >= Self.fewestNotesForAFigure && notesPerBar >= 1
    }

    /// How much of the tune is a figure heard twice: the share of its moves that lie in a run of
    /// three or more that comes again later — the statement and every return of it.
    ///
    /// A figure is its rhythm and its shape: the time between the notes, and which way each one
    /// goes. Not its pitches, so a figure brought back a third up is the figure; and not the size
    /// of its steps, so the answer that ends a tone lower than the question did is still the
    /// question coming back. The same notes in another rhythm are something else.
    ///
    /// It used to be the *longest* run of intervals that occurred twice, over all the moves, and
    /// no longer than eight. A tune of forty notes could not reach a quarter on it however much
    /// came back — "the same two-bar figure four times" read 19% — and eight-bar phrases of 9,000
    /// recorded melodies read 16% at the median (`Bench/genres/melody_ranges.py`). The Melodist's
    /// floor was a quarter, so it flagged nearly every tune anyone wrote.
    public var motifRatio: Double {
        let moves = moves
        let shortest = Self.shortestFigure
        guard moves.count >= 4, moves.count >= shortest * 2 else { return 0 }
        var heard = [Bool](repeating: false, count: moves.count)
        for a in 0...(moves.count - shortest) {
            var b = a + shortest
            while b <= moves.count - shortest {
                var length = 0
                while b + length < moves.count, a + length < b, moves[a + length] == moves[b + length] { length += 1 }
                if length >= shortest {
                    for offset in 0..<length {
                        heard[a + offset] = true
                        heard[b + offset] = true
                    }
                }
                b += 1
            }
        }
        return Double(heard.count { $0 }) / Double(moves.count)
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
