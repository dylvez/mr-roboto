import Foundation
import MusicTheory
import Performance
import SongGraph

/// A progression as the Harmonist reads it: the chords in the key, how often they change, how far
/// the voices travel between them, whether the phrases land, and whether the bass line agrees.
///
/// Everything here is arithmetic on `SongGraph.Progression` and `SongGraph.Bassline`. No audio is
/// read: harmony is a written fact about a song, and a reading of it that needed a bounce could
/// not be given before anything sounds.
public struct HarmonyObservation: Hashable, Sendable {
    public var label: String
    public var key: Key
    public var beatsPerBar: Int
    /// The chords in order, each with the beat it starts on.
    public var chords: [Chord]
    public var starts: [Double]
    /// The total length in beats.
    public var beats: Double
    /// Chord changes where the bass is sounding a note of that chord.
    public var bassAgreements: Int
    /// Chord changes the bass was playing under at all. 0 when there is no bass line yet.
    public var bassChanges: Int
    /// The first chord the bass disagrees with, for the sentence that names it.
    public var firstBassClash: (chord: Chord, bass: Pitch)?
    /// Two other ways to say the progression, each as a move's name and what it makes of the
    /// sheet, for the reading that finds it the usual one. Empty when it was read with no sheet.
    public var alternatives: [String] = []
    /// What the library's other songs did. Nil reads the progression alone.
    public var before: SongsBefore?

    public static func == (a: HarmonyObservation, b: HarmonyObservation) -> Bool {
        a.label == b.label && a.key == b.key && a.beatsPerBar == b.beatsPerBar && a.chords == b.chords
            && a.starts == b.starts && a.beats == b.beats && a.bassAgreements == b.bassAgreements
            && a.bassChanges == b.bassChanges
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(label); hasher.combine(key); hasher.combine(chords); hasher.combine(beats)
    }

    public init(label: String, key: Key, beatsPerBar: Int = 4, chords: [Chord], starts: [Double], beats: Double,
                bassAgreements: Int = 0, bassChanges: Int = 0, firstBassClash: (chord: Chord, bass: Pitch)? = nil) {
        self.label = label
        self.key = key
        self.beatsPerBar = beatsPerBar
        self.chords = chords
        self.starts = starts
        self.beats = beats
        self.bassAgreements = bassAgreements
        self.bassChanges = bassChanges
        self.firstBassClash = firstBassClash
    }

    // MARK: The numbers

    public var bars: Double { beats / Double(max(1, beatsPerBar)) }

    /// Chord changes per bar. A progression of one chord a bar reads 1.
    public var changesPerBar: Double { bars <= 0 ? 0 : Double(chords.count) / bars }

    /// Different chords in the progression.
    public var distinctChords: Int { Set(chords).count }

    /// Whether the key holds every note of a chord. `MusicTheory.Key.romanNumeral(for:)` will
    /// spell a chromatic chord as a flattened degree, so it answers "can this be named in the key"
    /// rather than "is this in the key", which is the question here.
    public func owns(_ chord: Chord) -> Bool {
        let scale = Set(key.pitchClasses)
        return chord.pitchClasses.allSatisfy { scale.contains($0) }
    }

    /// Chords the key owns, over all chords.
    public var diatonicRatio: Double {
        guard !chords.isEmpty else { return 1 }
        return Double(chords.filter(owns).count) / Double(chords.count)
    }

    /// The chords the key does not own, in order and without repeats.
    public var borrowed: [Chord] {
        var seen = Set<Chord>()
        return chords.filter { !owns($0) && seen.insert($0).inserted }
    }

    /// Mean semitone distance the voices travel between consecutive chords.
    ///
    /// Measured over every pair of major and minor triads, this runs 0.33 to 1.67 and sits at 1.0
    /// in the middle — pitch classes wrap, so no two triads are ever far apart. The thresholds in
    /// `Harmonist` are on that scale rather than on the semitones a player would count.
    ///
    /// For each note of a chord, the nearest note of the next chord, on the pitch-class circle, and
    /// the mean of those over every change. Two chords sharing notes read near a third of a
    /// semitone; the furthest triads apart read near five thirds.
    public var voiceLeadingSemitones: Double {
        let moves = zip(chords, chords.dropFirst()).map { Self.motion(from: $0, to: $1) }
        return moves.isEmpty ? 0 : moves.reduce(0, +) / Double(moves.count)
    }

    static func motion(from: Chord, to: Chord) -> Double {
        let target = to.pitchClasses
        guard !target.isEmpty, !from.pitchClasses.isEmpty else { return 0 }
        let distances = from.pitchClasses.map { note in
            target.map { Double(Self.circle(note, $0)) }.min() ?? 0
        }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// Semitones between two pitch classes the short way round, 0…6.
    static func circle(_ a: PitchClass, _ b: PitchClass) -> Int {
        let up = a.distance(to: b)
        return min(up, 12 - up)
    }

    /// Root movements by a perfect fourth or fifth, over all movements. A chord held into the next
    /// bar is not a movement: counted as one, a twelve-bar blues — four bars of I — read as weak
    /// root motion for standing still.
    public var rootMotionFifths: Double {
        let moves = zip(chords, chords.dropFirst()).map { $0.root.distance(to: $1.root) }.filter { $0 != 0 }
        guard !moves.isEmpty else { return 0 }
        return Double(moves.filter { $0 == 5 || $0 == 7 }.count) / Double(moves.count)
    }

    /// Where a phrase ends: every fourth bar, and the end of the progression.
    var phraseEndings: [Int] {
        guard chords.count > 1 else { return chords.isEmpty ? [] : [0] }
        var out: [Int] = []
        let barLength = Double(beatsPerBar)
        for bar in stride(from: 4.0, through: bars, by: 4) {
            let cutoff = bar * barLength
            if let last = starts.lastIndex(where: { $0 < cutoff - 1e-9 }), !out.contains(last) { out.append(last) }
        }
        if let last = chords.indices.last, !out.contains(last) { out.append(last) }
        return out
    }

    /// Phrase endings that land: on the tonic, or approached by a fourth or a fifth.
    public var cadenceRatio: Double {
        let endings = phraseEndings
        guard !endings.isEmpty else { return 0 }
        let landed = endings.filter { index in
            let chord = chords[index]
            if chord.root == key.tonic.pitchClass { return true }
            guard index > 0 else { return false }
            let motion = chords[index - 1].root.distance(to: chord.root)
            return motion == 5 || motion == 7
        }
        return Double(landed.count) / Double(endings.count)
    }

    /// Chord changes the bass agrees with, over the changes it played under. 1 when there is no
    /// bass line: nothing disagrees with a progression nobody is playing under.
    public var bassAgreement: Double {
        bassChanges == 0 ? 1 : Double(bassAgreements) / Double(bassChanges)
    }

    /// The progression as numerals, with a borrowed chord named by its own letter.
    public var numerals: [String] {
        chords.map { key.romanNumeral(for: $0)?.description ?? "\($0.root.description)\($0.quality.symbol)" }
    }

    // MARK: What is its own

    /// How long each chord lasts, a chord held over a bar line counted once.
    public var lengths: [Double] {
        var out: [Double] = []
        var last: Chord?
        for (index, chord) in chords.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : beats
            let length = end - starts[index]
            if chord == last, !out.isEmpty { out[out.count - 1] += length } else { out.append(length) }
            last = chord
        }
        return out
    }

    /// Whether the key is a minor one, by its own tonic chord.
    var isMinor: Bool { key.scale.diatonicChord(degree: 1, root: key.tonic.pitchClass)?.quality.hasMinorThird ?? false }

    /// The major chord on the fifth of a minor key: outside the scale and inside every minor song
    /// ever written. Not counted as leaving the key.
    func isTheFive(_ chord: Chord) -> Bool {
        isMinor && key.tonic.pitchClass.distance(to: chord.root) == 7 && (chord.quality.third == 4 || chord.quality.isSuspended)
    }

    /// What about the progression is not the default, each in a few words. The default is the
    /// loop every songwriting tool hands you: chords from the key, home first, a root in every
    /// bass, each chord as long as the last, four of them or fewer.
    public var departures: [String] {
        var out: [String] = []
        let outside = borrowed.filter { !isTheFive($0) }
        if !outside.isEmpty {
            out.append("\(outside.map { key.symbol(of: $0) }.joined(separator: ", ")) \(outside.count == 1 ? "is" : "are") from outside the key")
        }
        if chords.contains(where: { $0.inversion > 0 }) { out.append("the bass is not always the root") }
        let lengths = Set(self.lengths.map { ($0 * 4).rounded() / 4 })
        if lengths.count > 1 { out.append("the chords are not all one length") }
        if let first = chords.first, first.root != key.tonic.pitchClass { out.append("it does not open at home") }
        let roots = Set(chords.map(\.root)).count
        if roots > 4 { out.append("it has \(roots) different roots") }
        return out
    }

    /// The loop as the library's memory keeps it.
    public var loop: [Int] { SongsBefore.loop(of: chords, key: key) }

    // MARK: Reading a song

    /// A progression as a part, with the newest bass line under it when the song has one.
    public static func of(_ progression: Progression, label: String, bassline: Bassline? = nil,
                          beatsPerBar: Int = 4) -> HarmonyObservation {
        var chords: [Chord] = []
        var starts: [Double] = []
        var beat = 0.0
        for span in progression.bars.flatMap(\.chords) {
            chords.append(span.chord)
            starts.append(beat)
            beat += span.beats
        }
        var observation = HarmonyObservation(label: label, key: progression.key, beatsPerBar: beatsPerBar,
                                             chords: chords, starts: starts, beats: beat)
        observation.alternatives = Reharmonize.options(for: progression).prefix(2).map {
            "\($0.move.name.lowercased()) (\($0.progression.symbols()))"
        }
        guard let bassline, !bassline.notes.isEmpty else { return observation }

        // At each change, what is the bass sounding? The note under the change if one is held, else
        // the first note the chord gets. A chord nothing is played under is not counted either way.
        var agreements = 0
        var changes = 0
        for (index, chord) in chords.enumerated() {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : beat
            let sounding = bassline.notes.first { $0.start <= start + 1e-9 && $0.start + $0.duration > start + 1e-9 }
                ?? bassline.notes.first { $0.start > start - 1e-9 && $0.start < end - 1e-9 }
            guard let note = sounding else { continue }
            changes += 1
            if chord.pitchClasses.contains(note.pitch.pitchClass) {
                agreements += 1
            } else if observation.firstBassClash == nil {
                observation.firstBassClash = (chord, note.pitch)
            }
        }
        observation.bassAgreements = agreements
        observation.bassChanges = changes
        return observation
    }
}
