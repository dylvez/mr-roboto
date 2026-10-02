import Foundation
import MusicTheory
import Performance
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
    /// How long the chords run before they come round again, in beats. A tune twice the length
    /// of its loop is heard over the loop twice; without this every note past the sheet's end was
    /// read against its last chord. Nil reads the chords once.
    public var chordsLength: Double?
    /// Two other ways to play the tune, each in a few words, for the reading that finds nothing
    /// in it its own. Empty when it was read with no melody behind it.
    public var alternatives: [String] = []
    /// What the library's other songs did. Nil reads the tune alone.
    public var before: SongsBefore?

    public static func == (a: MelodyObservation, b: MelodyObservation) -> Bool {
        a.label == b.label && a.key == b.key && a.beatsPerBar == b.beatsPerBar && a.notes == b.notes
            && a.chords.map(\.chord) == b.chords.map(\.chord) && a.chords.map(\.start) == b.chords.map(\.start)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(label); hasher.combine(key); hasher.combine(notes)
    }

    public init(label: String, key: Key, beatsPerBar: Int = 4, notes: [NoteEvent],
                chords: [(chord: Chord, start: Double)] = [], chordsLength: Double? = nil) {
        self.label = label
        self.key = key
        self.beatsPerBar = beatsPerBar
        self.notes = notes.sorted { $0.start < $1.start }
        self.chords = chords
        self.chordsLength = chordsLength
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

    /// How much of the tune's sounding time is on a note of the chord under it, over the time it
    /// sounds with a chord under it. 1 when the song states no chords: nothing disagrees with a
    /// harmony nobody wrote.
    ///
    /// By length, which is what the rule has always said: land the long notes and pass through the
    /// rest. It used to count notes, so a passing eighth weighed as much as the whole note it led
    /// to — a tune that walked between its landings, or leaned on a note before resolving it, read
    /// as fighting the chords, and write_melody sent it back to be made plainer.
    public var chordToneRatio: Double {
        var landed = 0.0, judged = 0.0
        for note in notes {
            guard let chord = chord(at: note.start) else { continue }
            let length = max(note.duration, Self.shortestCounted)
            judged += length
            if chord.pitchClasses.contains(note.pitch.pitchClass) { landed += length }
        }
        guard judged > 0 else { return 1 }
        return landed / judged
    }

    /// A note counts for at least this long, in beats: a grace note is still a note.
    static let shortestCounted = 0.125

    /// The longest note that sits outside the chord under it: the one to land, if any is.
    public var longestClash: (note: NoteEvent, chord: Chord)? {
        var worst: (note: NoteEvent, chord: Chord)?
        for note in notes {
            guard let chord = chord(at: note.start), !chord.pitchClasses.contains(note.pitch.pitchClass) else { continue }
            if worst == nil || note.duration > worst!.note.duration + 1e-9 { worst = (note, chord) }
        }
        return worst
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
        var beat = beat
        // The chords come round again under a tune longer than they are.
        if let length = chordsLength, length > 0, beat >= length - 1e-9 { beat = beat.truncatingRemainder(dividingBy: length) }
        return chords.last { $0.start <= beat + 1e-9 }?.chord
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

    // MARK: What is its own

    /// What about the tune is not the default, each in a few words. The default is the tune a
    /// grid hands you: every note on a beat or halfway between two, every note from the key, no
    /// move wider than a fourth, and every long note a note of the chord.
    public var surprises: [String] {
        var out: [String] = []
        let scale = Set(key.pitchClasses)
        let minor = key.scale.diatonicChord(degree: 1, root: key.tonic.pitchClass)?.quality.hasMinorThird ?? false
        // The raised seventh of a minor key is in every minor tune, over the five: not counted.
        let leading = key.tonic.pitchClass.transposed(by: 11)
        let outside = notes.filter { !scale.contains($0.pitch.pitchClass) && !(minor && $0.pitch.pitchClass == leading) }
        if !outside.isEmpty {
            let degrees = Array(Set(outside.map { Self.degreeNames[key.tonic.pitchClass.distance(to: $0.pitch.pitchClass)] })).sorted()
            out.append("the \(degrees.joined(separator: " and the ")) \(degrees.count == 1 ? "is" : "are") from outside the key")
        }
        let bar = Double(max(1, beatsPerBar))
        let offGrid = notes.contains { note in
            let halves = note.start * 2
            return abs(halves - halves.rounded()) > 0.04
        }
        let tied = notes.contains { note in
            let inBar = note.start.truncatingRemainder(dividingBy: bar)
            return inBar >= bar - 0.5 - 1e-9 && note.start + note.duration >= (note.start - inBar + bar) + 0.25
        }
        if offGrid { out.append("a note comes in off the eighth") }
        if tied { out.append("a note is tied over a bar line") }
        if largestLeapSemitones >= 7 { out.append("it leaps \(Int(largestLeapSemitones)) semitones") }
        // Long enough to be heard against the chord and not on the way past it: a beat and a
        // half, or a beat begun on the bar line.
        if let leaning = notes.first(where: { note in
            let onTheBar = note.start.truncatingRemainder(dividingBy: bar) < 1e-9
            guard note.duration >= 1.5 || (note.duration >= 1 && onTheBar), let chord = chord(at: note.start) else { return false }
            return !chord.pitchClasses.contains(note.pitch.pitchClass)
        }), let chord = chord(at: leaning.start) {
            let degree = Self.degreeNames[key.tonic.pitchClass.distance(to: leaning.pitch.pitchClass)]
            out.append("the \(degree) leans on \(key.symbol(of: chord))")
        }
        return out
    }

    /// How the tune comes in, as the library's memory keeps it.
    public var opening: SongsBefore.Opening? { SongsBefore.opening(of: notes, key: key, beatsPerBar: beatsPerBar) }

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
        var observation = MelodyObservation(label: label, key: key, beatsPerBar: beatsPerBar, notes: melody.notes, chords: chords,
                                            chordsLength: beat > 0 ? beat : nil)
        observation.alternatives = alternatives(to: melody, key: key, beatsPerBar: beatsPerBar, chords: progression?.spans ?? [])
        return observation
    }

    /// The other ways to play a tune that change something, two of them, each as its sentence.
    public static func alternatives(to melody: Melody, key: Key, beatsPerBar: Int, chords: [ChordSpan]) -> [String] {
        let loop = melody.loopBars(beatsPerBar: beatsPerBar)
        return [TuneTreatment.pushed, .answered, .sequenced].compactMap { treatment in
            TuneVariation.vary(melody, as: treatment, bars: loop * 2, beatsPerBar: beatsPerBar, key: key,
                               chords: chords) == nil ? nil : treatment.about
        }.prefix(2).map { $0 }
    }
}
