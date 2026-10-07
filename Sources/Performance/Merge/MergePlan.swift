import Foundation
import MusicTheory
import SongGraph

// The merge: two fragments in different keys and tempos, one plan for how each moves so that they
// sit together. Pure arithmetic over what the fragments say about themselves, so the rules are
// written down once (`MergePlanTests` runs the table) and every sentence the surface and the
// Director speak comes from here.
//
// The rules, as the M3 spec lists them:
//   K1 the smallest absolute transposition wins; ties go to moving the sample down;
//   K2 relative keys are one key: A minor under C major moves nothing;
//   K3 a written part transposes by arithmetic and never by audio;
//   K4 a groove has no key and is never moved;
//   T1 before stretching past ±12%, double or halve: 170 sits under 85;
//   T2 the target tempo is the open song's, then the drums' source, then the first fragment's;
//   T3 slices re-time with the stretch (the renderer's job; `MergeMove.ratio` is what it reads);
//   F1 past ±4 semitones a sample is flagged — the timbre will tell — and formants are preserved
//      from ±3.

/// One thing to be merged, as the plan needs to know it.
public struct MergeFragment: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Audio: moves by pitch shift and stretch.
        case sample
        /// A written part with pitches: moves by arithmetic.
        case written
        /// A groove: no key, never moved.
        case groove
    }

    public var label: String
    public var kind: Kind
    public var key: Key?
    public var tempo: Double?
    /// The sample carries the drums, which decides the target tempo when the song has none.
    public var isDrums: Bool

    public init(label: String, kind: Kind, key: Key? = nil, tempo: Double? = nil, isDrums: Bool = false) {
        self.label = label
        self.kind = kind
        self.key = key
        self.tempo = tempo
        self.isDrums = isDrums
    }
}

/// Where the fragments are being brought: the open song's key and tempo when it has them.
public struct MergeTarget: Hashable, Sendable {
    public var key: Key?
    public var tempo: Double?

    public init(key: Key? = nil, tempo: Double? = nil) {
        self.key = key
        self.tempo = tempo
    }
}

/// How one fragment moves.
public struct MergeMove: Hashable, Sendable {
    public var label: String
    /// Semitones up (positive) or down. 0 is untouched.
    public var semitones: Int
    /// Cents on top of the semitones, for a record that sits between the keys (`SourceFitting`).
    public var cents: Double = 0
    /// Output duration over input duration for the stretch. 1 is untouched. Written parts and
    /// grooves are never stretched: they play at the song's tempo already.
    public var ratio: Double
    /// The tempo the fragment is heard at once it is moved — its own tempo doubled or halved
    /// first when T1 said so.
    public var tempo: Double?
    /// Its key once moved, when it had one.
    public var key: Key?
    /// The factor T1 applied before stretching: 1, 2 or 0.5.
    public var tempoFactor: Double
    /// Keep formants where they are while shifting (F1: from ±3 semitones).
    public var preservesFormants: Bool
    /// The fragment is drums: the render keeps its transients sharp rather than its pitch exact.
    public var keepsTransients: Bool
    /// What the plan wants said about this move beyond the sentence.
    public var flags: [String]
    /// The move in a sentence: "Horns up 2 semitones to D, stretched ×0.94 from 98 to 92."
    public var sentence: String

    public var movesPitch: Bool { semitones != 0 || abs(cents) > 1e-9 }
    /// The whole pitch move in semitones, as the stretcher takes it.
    public var pitchShift: Double { Double(semitones) + cents / 100 }
    public var movesTime: Bool { abs(ratio - 1) > 1e-9 }
    public var isUntouched: Bool { !movesPitch && !movesTime }

    public init(label: String, semitones: Int = 0, ratio: Double = 1, tempo: Double? = nil, key: Key? = nil,
                tempoFactor: Double = 1, preservesFormants: Bool = false, keepsTransients: Bool = false,
                flags: [String] = [], sentence: String = "") {
        self.label = label
        self.semitones = semitones
        self.ratio = ratio
        self.tempo = tempo
        self.key = key
        self.tempoFactor = tempoFactor
        self.preservesFormants = preservesFormants
        self.keepsTransients = keepsTransients
        self.flags = flags
        self.sentence = sentence
    }
}

/// The plan: the target settled on, and one move per fragment.
public struct MergePlan: Hashable, Sendable {
    public var target: MergeTarget
    public var a: MergeMove
    public var b: MergeMove
    /// Every sentence, in order, the way the surface and the Director say it.
    public var sentences: [String] { [a.sentence, b.sentence] }
    public var flags: [String] { a.flags + b.flags }

    public init(target: MergeTarget, a: MergeMove, b: MergeMove) {
        self.target = target
        self.a = a
        self.b = b
    }
}

public enum Merge {

    /// Past this many semitones a sample is flagged (F1).
    public static let flagSemitones = 4
    /// From this many semitones a sample's formants are held in place (F1).
    public static let formantSemitones = 3
    /// The stretch a fragment takes before T1 doubles or halves its tempo instead.
    public static let stretchLimit = 0.12

    /// Decides how `a` and `b` move to sit together in `target`. A target with no key or no tempo
    /// is filled in by the rules (K1 across the pair, T2).
    public static func plan(_ a: MergeFragment, _ b: MergeFragment, target: MergeTarget = MergeTarget()) -> MergePlan {
        let key = target.key ?? chooseKey(a, b)
        let tempo = target.tempo ?? chooseTempo(a, b)
        let settled = MergeTarget(key: key, tempo: tempo)
        return MergePlan(target: settled, a: move(a, to: settled), b: move(b, to: settled))
    }

    /// One fragment's move into a target. `semitones`, when given, replaces what the rules chose —
    /// a hand on the surface's stepper — and the key, the flags and the sentence follow it.
    public static func move(_ fragment: MergeFragment, to target: MergeTarget, semitones override: Int? = nil) -> MergeMove {
        var move = MergeMove(label: fragment.label, tempo: fragment.tempo, key: fragment.key, keepsTransients: fragment.isDrums)

        // Pitch.
        if fragment.kind != .groove, let from = fragment.key, target.key != nil || override != nil {
            move.semitones = override ?? target.key.map { semitones(from: from, to: $0) } ?? 0
            move.key = move.semitones == 0 ? from : from.transposed(by: move.semitones)
            if fragment.kind == .sample {
                move.preservesFormants = abs(move.semitones) >= formantSemitones
                if abs(move.semitones) > flagSemitones {
                    move.flags.append("\(fragment.label) moves \(abs(move.semitones)) semitones — past \(flagSemitones), the timbre will tell.")
                }
            }
        }

        // Time. Only audio is stretched; a written part or a groove plays at the song's tempo.
        if fragment.kind == .sample, let from = fragment.tempo, let to = target.tempo, from > 0, to > 0 {
            let (factor, ratio) = stretch(from: from, to: to)
            move.tempoFactor = factor
            move.ratio = ratio
            move.tempo = to
        }

        move.sentence = sentence(for: fragment, move: move, target: target)
        return move
    }

    // MARK: The rules

    /// K1 and K2: the signed semitones from `from` into `to`'s pitch collection, keeping `from`'s
    /// mode — A minor into D major is B minor, two up; A minor into C major is nothing at all.
    public static func semitones(from: Key, to: Key) -> Int {
        guard from.signature != to.signature else { return 0 }
        let destination = to.relative(from.mode)
        // Folded to −6…5 by hand rather than `signedDistance`, so a tritone goes down (K1's tie).
        let up = from.tonic.pitchClass.distance(to: destination.tonic.pitchClass)
        return up >= 6 ? up - 12 : up
    }

    /// T1: the factor (1, 2 or ½) and the stretch ratio that bring `from` to `to`, doubling or
    /// halving first when a plain stretch would pass ±12%.
    public static func stretch(from: Double, to: Double) -> (factor: Double, ratio: Double) {
        let plain = from / to
        if abs(plain - 1) <= stretchLimit { return (1, plain) }
        let candidates: [(Double, Double)] = [1, 2, 0.5].map { ($0, from * $0 / to) }
        let best = candidates.min { abs($0.1 - 1) < abs($1.1 - 1) } ?? (1, plain)
        return best
    }

    /// K1 across the pair when the song says nothing: the key that moves the pair least, counting
    /// a written part's move as free (K3) and preferring to move the sample down on a tie.
    static func chooseKey(_ a: MergeFragment, _ b: MergeFragment) -> Key? {
        let keys = [a, b].compactMap { $0.kind == .groove ? nil : $0.key }
        guard let first = keys.first else { return nil }
        guard keys.count == 2 else { return first }
        func cost(_ target: Key) -> Int {
            [a, b].reduce(0) { total, fragment in
                guard let key = fragment.key, fragment.kind == .sample else { return total }
                return total + abs(semitones(from: key, to: target))
            }
        }
        let costA = cost(keys[0]), costB = cost(keys[1])
        if costA != costB { return costA < costB ? keys[0] : keys[1] }
        // A tie: the target under which the sample moves down rather than up.
        let sample = [a, b].first { $0.kind == .sample && $0.key != nil }
        if let key = sample?.key, semitones(from: key, to: keys[1]) < 0 { return keys[1] }
        return keys[0]
    }

    /// T2 when the song says nothing: the drums' source, then the first fragment with a tempo.
    static func chooseTempo(_ a: MergeFragment, _ b: MergeFragment) -> Double? {
        if let drums = [a, b].first(where: { $0.isDrums && $0.tempo != nil }) { return drums.tempo }
        return [a, b].compactMap(\.tempo).first
    }

    // MARK: Words

    static func sentence(for fragment: MergeFragment, move: MergeMove, target: MergeTarget) -> String {
        if fragment.kind == .groove { return "\(fragment.label) stays: a groove has no key." }
        var pieces: [String] = []
        if move.semitones != 0, let key = move.key {
            pieces.append("\(move.semitones > 0 ? "up" : "down") \(abs(move.semitones)) semitone\(abs(move.semitones) == 1 ? "" : "s") to \(key.name)")
        }
        if let from = fragment.tempo, let to = move.tempo, move.tempoFactor != 1 || move.movesTime {
            var time = ""
            if move.tempoFactor != 1 {
                time = String(format: "%.0f %@ to %.0f", from, move.tempoFactor > 1 ? "doubled" : "halved", from * move.tempoFactor)
            }
            if move.movesTime {
                time += time.isEmpty ? String(format: "stretched ×%.2f from %.0f to %.0f", move.ratio, from, to)
                                     : String(format: ", stretched ×%.2f to %.0f", move.ratio, to)
            }
            pieces.append(time)
        }
        if pieces.isEmpty {
            var stays = "\(fragment.label) stays"
            if let key = fragment.key { stays += " in \(key.name)" }
            if let tempo = fragment.tempo, target.tempo != nil { stays += String(format: " at %.0f", tempo) }
            return stays + "."
        }
        return "\(fragment.label) \(pieces.joined(separator: ", "))."
    }
}
