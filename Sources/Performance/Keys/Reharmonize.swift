import Foundation
import MusicTheory
import SongGraph

/// A way of saying a progression less plainly: one named move, made on the sheet as it stands.
///
/// Every song this app had written opened on its tonic, stayed in its key, gave each chord the
/// same length and put every root in the bass — four chords, a bar each, and the most-used four at
/// that. None of that is wrong and all of it together is nobody's. These are the moves a player
/// reaches for to make a loop theirs, each small enough to hear on its own and to take back:
/// one chord borrowed, one dominant added, one bar shared, the bass given somewhere to go.
public enum Reharmonization: String, CaseIterable, Sendable, Codable {
    /// Inversions, so the bass moves by step or stays while the chords change over it.
    case bassLine = "bass-line"
    /// One chord from the parallel mode: the major four in a minor key, the minor four in a major.
    case borrowed
    /// A chord's own dominant, on the beats before it.
    case secondaryDominant = "secondary-dominant"
    /// A chord in passing between two that are a step or a third apart.
    case passing
    /// The dominant's tritone substitute, a semitone above home.
    case tritone
    /// The chords given different lengths: the first held, the middle two sharing a bar.
    case uneven
    /// The loop twice, with a different way home the second time.
    case turnaround
    /// The same chords, starting from the middle of the loop.
    case rotated

    public var name: String {
        switch self {
        case .bassLine: return "A bass line"
        case .borrowed: return "A borrowed chord"
        case .secondaryDominant: return "A secondary dominant"
        case .passing: return "A passing chord"
        case .tritone: return "A tritone substitute"
        case .uneven: return "Uneven lengths"
        case .turnaround: return "A second ending"
        case .rotated: return "From the middle"
        }
    }

    /// What it does, for a picker and for a tool's schema.
    public var about: String {
        switch self {
        case .bassLine: return "inversions, so the bass moves by step or holds while the chords change over it"
        case .borrowed: return "one chord from the parallel mode: the major four or the flat two in a minor key, the minor four or the flat seven in a major"
        case .secondaryDominant: return "a chord's own dominant seventh on the beats before it"
        case .passing: return "a chord in passing between two that are a step or a third apart"
        case .tritone: return "the dominant's tritone substitute, a semitone above home, after it"
        case .uneven: return "the first chord held twice as long and the middle two sharing a bar"
        case .turnaround: return "the loop twice, with a different way home the second time"
        case .rotated: return "the same chords, starting from the middle of the loop"
        }
    }
}

/// A progression after one move, and what the move was in a sentence.
public struct Reharmonized: Equatable, Sendable {
    public var move: Reharmonization
    public var progression: Progression
    /// "D7 before Gm9, on the last two beats of the bar before it: its own dominant."
    public var says: String

    public init(move: Reharmonization, progression: Progression, says: String) {
        self.move = move
        self.progression = progression
        self.says = says
    }
}

public enum Reharmonize {

    /// Every move that changes this sheet, in the order worth hearing them: the quiet ones first.
    public static func options(for progression: Progression) -> [Reharmonized] {
        Reharmonization.allCases.compactMap { apply($0, to: progression) }
    }

    /// One move made on a progression. Nil when the sheet gives it nothing to work on — no
    /// dominant to substitute, no four to borrow — or when it would change nothing.
    ///
    /// - Parameter variant: which of the places the move could be made, when there are several;
    ///   it wraps, so any number picks one.
    public static func apply(_ move: Reharmonization, to progression: Progression, variant: Int = 0) -> Reharmonized? {
        let sheet = Sheet(progression)
        guard sheet.spans.count >= 2 else { return nil }
        let made: (spans: [Sheet.Span], says: String)?
        switch move {
        case .bassLine: made = bassLine(sheet)
        case .borrowed: made = borrowed(sheet, variant)
        case .secondaryDominant: made = secondaryDominant(sheet, variant)
        case .passing: made = passing(sheet, variant)
        case .tritone: made = tritone(sheet)
        case .uneven: made = uneven(sheet)
        case .turnaround: made = turnaround(sheet)
        case .rotated: made = rotated(sheet)
        }
        guard let made else { return nil }
        let result = Progression(key: progression.key, bars: sheet.bars(of: made.spans), playing: progression.playing)
        guard result.spans != progression.spans else { return nil }
        return Reharmonized(move: move, progression: result, says: made.says)
    }

    // MARK: - The sheet, as the moves see it

    /// A progression as its chords in order, each with how long it lasts — the same chord in two
    /// bars running is one chord held — and the bar length they are written back into.
    struct Sheet {
        struct Span: Equatable {
            var chord: Chord
            var beats: Double
        }

        var key: Key
        var spans: [Span]
        var barBeats: Double
        var spelling: SpellingPreference

        init(_ progression: Progression) {
            key = progression.key
            barBeats = progression.bars.first?.beats ?? 4
            spelling = progression.key.signature.preference
            var merged: [Span] = []
            for span in progression.spans {
                if let last = merged.last, last.chord == span.chord {
                    merged[merged.count - 1].beats += span.beats
                } else {
                    merged.append(Span(chord: span.chord, beats: span.beats))
                }
            }
            spans = merged
        }

        var tonic: PitchClass { key.tonic.pitchClass }
        var scale: Set<PitchClass> { Set(key.pitchClasses) }
        var isMinor: Bool { key.scale.diatonicChord(degree: 1, root: tonic)?.quality.hasMinorThird ?? false }
        var usesSevenths: Bool { spans.contains { !$0.chord.quality.isTriad && $0.chord.quality != .power } }
        func owns(_ chord: Chord) -> Bool { chord.pitchClasses.allSatisfy(scale.contains) }
        func name(_ chord: Chord) -> String { key.symbol(of: chord) }
        func degree(_ chord: Chord) -> Int { tonic.distance(to: chord.root) }

        /// Spans written back as bars of the sheet's own length, a chord that runs over a bar line
        /// carried into the next bar.
        func bars(of spans: [Span]) -> [ProgressionBar] {
            var bars: [ProgressionBar] = []
            var current: [ChordSpan] = []
            var room = barBeats
            for span in spans {
                var left = span.beats
                while left > 1e-9 {
                    let take = min(left, room)
                    current.append(ChordSpan(span.chord, beats: take))
                    left -= take
                    room -= take
                    if room <= 1e-9 {
                        bars.append(ProgressionBar(chords: current))
                        current = []
                        room = barBeats
                    }
                }
            }
            if !current.isEmpty { bars.append(ProgressionBar(chords: current)) }
            return bars
        }

        func line(_ spans: [Span]) -> String {
            bars(of: spans).map { bar in bar.chords.map { name($0.chord) }.joined(separator: " ") }.joined(separator: " | ")
        }

        /// How many beats a chord added before a change takes from the chord it follows: the last
        /// half of a bar, or the last beat of a short one.
        func tail(of beats: Double) -> Double? {
            if beats >= 4 { return 2 }
            if beats >= 2 { return 1 }
            return nil
        }

        func beatsWord(_ beats: Double) -> String {
            beats == 1 ? "the last beat" : "the last \(beats == beats.rounded() ? String(Int(beats)) : String(beats)) beats"
        }
    }

    // MARK: - The moves

    /// Inversions chosen so the bass goes the shortest way from each chord to the next, and steps
    /// into the top of the loop from the last.
    static func bassLine(_ sheet: Sheet) -> (spans: [Sheet.Span], says: String)? {
        var spans = sheet.spans
        func circle(_ a: PitchClass, _ b: PitchClass) -> Int { let up = a.distance(to: b); return min(up, 12 - up) }
        var bass = spans[0].chord.bass
        let home = spans[0].chord.root
        for index in 1..<spans.count {
            let chord = spans[index].chord
            guard chord.quality != .power else { bass = chord.root; continue }
            let last = index == spans.count - 1
            var best = (inversion: 0, cost: Double.infinity)
            for inversion in 0...min(2, chord.pitchClasses.count - 1) {
                let note = chord.inverted(inversion).bass
                var cost = Double(circle(bass, note)) + 0.3 * Double(inversion)
                // The last chord is heard into the first: a bass that steps home is worth a leap to it.
                if last { cost += Double(circle(note, home)) }
                if cost < best.cost - 1e-9 { best = (inversion, cost) }
            }
            spans[index].chord = chord.inverted(best.inversion)
            bass = spans[index].chord.bass
        }
        guard spans != sheet.spans else { return nil }
        let notes = spans.map { sheet.name($0.chord).split(separator: "/").last.map(String.init) ?? "" }
            .enumerated().map { index, text in spans[index].chord.inversion > 0 ? text : sheet.key.spell(spans[index].chord)[0].description }
        return (spans, "\(sheet.line(spans)): the bass goes \(notes.joined(separator: ", ")) under the same chords.")
    }

    /// One chord from the parallel mode, in place of the one the key would have.
    static func borrowed(_ sheet: Sheet, _ variant: Int) -> (spans: [Sheet.Span], says: String)? {
        var made: [(spans: [Sheet.Span], says: String)] = []
        let sevenths = sheet.usesSevenths
        if sheet.isMinor {
            for (index, span) in sheet.spans.enumerated() where sheet.degree(span.chord) == 5 && span.chord.quality.hasMinorThird {
                // The four made major: the Dorian's, bright where the key was not.
                var major = sheet.spans
                major[index].chord = Chord(root: span.chord.root, quality: sevenths ? .dominantSeventh : .major)
                made.append((major, "\(sheet.name(major[index].chord)) where \(sheet.name(span.chord)) was: the four made major, borrowed from the Dorian."))
                // The flat two, when the four was on its way to the five.
                let next = sheet.spans[(index + 1) % sheet.spans.count].chord
                if sheet.degree(next) == 7 {
                    var flat = sheet.spans
                    flat[index].chord = Chord(root: sheet.tonic.transposed(by: 1), quality: sevenths ? .majorSeventh : .major)
                    made.append((flat, "\(sheet.name(flat[index].chord)) where \(sheet.name(span.chord)) was: the flat two, a semitone above home, before \(sheet.name(next))."))
                }
                break
            }
        } else {
            if let index = sheet.spans.firstIndex(where: { sheet.degree($0.chord) == 5 && !$0.chord.quality.hasMinorThird }),
               sheet.spans[index].beats >= 2 {
                // The four, then the four made minor: the parallel minor's, for the second half of it.
                var spans = sheet.spans
                let half = spans[index].beats / 2
                let minor = Chord(root: spans[index].chord.root, quality: sevenths ? .minorSeventh : .minor)
                spans[index].beats = half
                spans.insert(Sheet.Span(chord: minor, beats: half), at: index + 1)
                made.append((spans, "\(sheet.name(minor)) after \(sheet.name(sheet.spans[index].chord)): the four made minor, borrowed from the parallel minor."))
            }
            if let last = sheet.spans.last, sheet.degree(last.chord) == 7, let tail = sheet.tail(of: last.beats) {
                // The flat seven after the five: the back door home.
                var spans = sheet.spans
                let flat = Chord(root: sheet.tonic.transposed(by: 10), quality: sevenths ? .dominantSeventh : .major)
                spans[spans.count - 1].beats -= tail
                spans.append(Sheet.Span(chord: flat, beats: tail))
                made.append((spans, "\(sheet.name(flat)) on \(sheet.beatsWord(tail)), after \(sheet.name(last.chord)): the flat seven, borrowed from the Mixolydian, and home by the back door."))
            }
        }
        guard !made.isEmpty else { return nil }
        return made[((variant % made.count) + made.count) % made.count]
    }

    /// A chord's own dominant seventh, on the beats before it, where the key would not have had one.
    static func secondaryDominant(_ sheet: Sheet, _ variant: Int) -> (spans: [Sheet.Span], says: String)? {
        var targets: [(index: Int, dominant: Chord, tail: Double, minor: Bool)] = []
        for index in sheet.spans.indices {
            let before = (index + sheet.spans.count - 1) % sheet.spans.count
            let target = sheet.spans[index].chord
            let dominant = Chord(root: target.root.transposed(by: 7), quality: .dominantSeventh)
            // Not home's own dominant, not one the key already has, and not after itself.
            guard target.root != sheet.tonic, !sheet.owns(dominant), sheet.spans[before].chord.root != dominant.root,
                  let tail = sheet.tail(of: sheet.spans[before].beats) else { continue }
            targets.append((index, dominant, tail, target.quality.hasMinorThird))
        }
        // A minor chord pulls hardest on its dominant; then in the order they come.
        let ordered = targets.filter(\.minor) + targets.filter { !$0.minor }
        guard !ordered.isEmpty else { return nil }
        let pick = ordered[((variant % ordered.count) + ordered.count) % ordered.count]
        var spans = sheet.spans
        let before = (pick.index + spans.count - 1) % spans.count
        let target = spans[pick.index].chord
        spans[before].beats -= pick.tail
        spans.insert(Sheet.Span(chord: pick.dominant, beats: pick.tail), at: before + 1)
        return (spans, "\(sheet.name(pick.dominant)) on \(sheet.beatsWord(pick.tail)) before \(sheet.name(target)): its own dominant.")
    }

    /// A chord in passing: a diminished seventh between two chords a tone apart going up, or the
    /// key's own chord on the degree between two a third apart.
    static func passing(_ sheet: Sheet, _ variant: Int) -> (spans: [Sheet.Span], says: String)? {
        var made: [(spans: [Sheet.Span], says: String)] = []
        let size = sheet.usesSevenths ? 4 : 3
        for index in sheet.spans.indices {
            let next = (index + 1) % sheet.spans.count
            let from = sheet.spans[index].chord, to = sheet.spans[next].chord
            guard let tail = sheet.tail(of: sheet.spans[index].beats).map({ min($0, sheet.spans[index].beats >= 4 ? 1 : $0) }) else { continue }
            let up = from.root.distance(to: to.root)
            var between: Chord?
            var what = ""
            if up == 2 {
                between = Chord(root: from.root.transposed(by: 1), quality: .diminishedSeventh)
                what = "a diminished chord on the semitone between them"
            } else if [3, 4, 8, 9].contains(up) {
                // The scale degree between the two roots, whichever way the third goes.
                let pitches = sheet.key.pitchClasses
                guard let a = pitches.firstIndex(of: from.root), let b = pitches.firstIndex(of: to.root) else { continue }
                let rising = up <= 4
                let middle = (a + (rising ? 1 : 6)) % 7
                guard (middle + (rising ? 1 : 6)) % 7 == b else { continue }
                between = sheet.key.scale.diatonicChord(degree: middle + 1, root: sheet.tonic, size: size)
                what = "the chord on the step between them"
            }
            guard let chord = between, chord != from, chord != to else { continue }
            var spans = sheet.spans
            spans[index].beats -= tail
            spans.insert(Sheet.Span(chord: chord, beats: tail), at: index + 1)
            made.append((spans, "\(sheet.name(chord)) between \(sheet.name(from)) and \(sheet.name(to)), on \(sheet.beatsWord(tail)): \(what)."))
        }
        // The chromatic ones first: they are the ones the key did not already hold.
        let ordered = made.filter { $0.says.contains("diminished") } + made.filter { !$0.says.contains("diminished") }
        guard !ordered.isEmpty else { return nil }
        return ordered[((variant % ordered.count) + ordered.count) % ordered.count]
    }

    /// The dominant, then the dominant seventh a tritone from it, a semitone above the chord they
    /// both lead to.
    static func tritone(_ sheet: Sheet) -> (spans: [Sheet.Span], says: String)? {
        for index in sheet.spans.indices.reversed() {
            let chord = sheet.spans[index].chord
            let next = sheet.spans[(index + 1) % sheet.spans.count].chord
            // A chord with a major third whose root falls a fifth to the next: a dominant.
            guard chord.quality.third == 4 || chord.quality.isSuspended, chord.root.distance(to: next.root) == 5 else { continue }
            let substitute = Chord(root: chord.root.transposed(by: 6), quality: .dominantSeventh)
            var spans = sheet.spans
            if let tail = sheet.tail(of: spans[index].beats) {
                spans[index].beats -= tail
                spans.insert(Sheet.Span(chord: substitute, beats: tail), at: index + 1)
                return (spans, "\(sheet.name(substitute)) on \(sheet.beatsWord(tail)), after \(sheet.name(chord)): its tritone substitute, a semitone above \(sheet.name(next)).")
            }
            spans[index].chord = substitute
            return (spans, "\(sheet.name(substitute)) where \(sheet.name(chord)) was: its tritone substitute, a semitone above \(sheet.name(next)).")
        }
        return nil
    }

    /// Four chords of one length, said unevenly: the first for two, the middle two for half each.
    static func uneven(_ sheet: Sheet) -> (spans: [Sheet.Span], says: String)? {
        guard sheet.spans.count == 4, let length = sheet.spans.first?.beats,
              sheet.spans.allSatisfy({ abs($0.beats - length) < 1e-9 }), length >= 2 else { return nil }
        var spans = sheet.spans
        spans[0].beats = length * 2
        spans[1].beats = length / 2
        spans[2].beats = length / 2
        let names = spans.map { sheet.name($0.chord) }
        return (spans, "\(sheet.line(spans)): \(names[0]) held twice as long, \(names[1]) and \(names[2]) sharing what was one chord's time, \(names[3]) as it was.")
    }

    /// The loop twice, the second time home another way: the flat six and the flat seven where the
    /// five was, or a five where there was none.
    static func turnaround(_ sheet: Sheet) -> (spans: [Sheet.Span], says: String)? {
        let total = sheet.spans.reduce(0) { $0 + $1.beats }
        guard total <= sheet.barBeats * 8 + 1e-9, let last = sheet.spans.last else { return nil }
        var second = sheet.spans
        let sevenths = sheet.usesSevenths
        let says: String
        if sheet.degree(last.chord) == 7 {
            // Home the long way: the flat six and the flat seven, climbing to the tonic.
            let six = Chord(root: sheet.tonic.transposed(by: 8), quality: sevenths ? .majorSeventh : .major)
            let seven = Chord(root: sheet.tonic.transposed(by: 10), quality: sevenths ? .dominantSeventh : .major)
            second.removeLast()
            second.append(Sheet.Span(chord: six, beats: last.beats / 2))
            second.append(Sheet.Span(chord: seven, beats: last.beats / 2))
            says = "The loop twice: the second time \(sheet.name(six)) and \(sheet.name(seven)) where \(sheet.name(last.chord)) was, climbing home by step."
        } else if let tail = sheet.tail(of: last.beats) {
            let five = Chord(root: sheet.tonic.transposed(by: 7), quality: sevenths ? .dominantSeventh : .major)
            guard five.root != last.chord.root else { return nil }
            second[second.count - 1].beats -= tail
            second.append(Sheet.Span(chord: five, beats: tail))
            says = "The loop twice: the second time \(sheet.name(five)) on \(sheet.beatsWord(tail)), a way back to the top that the first time does not have."
        } else {
            return nil
        }
        return (sheet.spans + second, says)
    }

    /// The loop from its middle: the same chords, and another one first.
    static func rotated(_ sheet: Sheet) -> (spans: [Sheet.Span], says: String)? {
        guard sheet.spans.count >= 4, sheet.spans.count % 2 == 0 else { return nil }
        let half = sheet.spans.count / 2
        let spans = Array(sheet.spans[half...] + sheet.spans[..<half])
        guard spans != sheet.spans else { return nil }
        return (spans, "\(sheet.line(spans)): the same chords from \(sheet.name(spans[0].chord)), so the loop leans somewhere else.")
    }
}
