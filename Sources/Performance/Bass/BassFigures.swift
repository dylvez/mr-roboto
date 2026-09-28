import Foundation
import MusicTheory
import SongGraph

/// The genres' own bass figures: each is the pattern a genre is known by, written against the
/// chords and bent by density and the seed, so two lines in the same hands are two lines.
///
/// Positions are in beats from the bar's start; a figure written for four beats is laid over the
/// bar it has, so a waltz's root–fifth still lands on one. Onsets here sit on the grid: every one of
/// these players plays with the drums rather than behind them, which is what `defaultLagMS` of 0
/// says.
enum BassFigures {
    typealias Draft = BassWriter.Draft

    static func write(_ request: BassRequest, harmony: HarmonyMap, beatsPerBar: Double, bars: Int,
                      rng: inout BassRandom) -> [Draft] {
        let lineage = request.lineage
        var drafts: [Draft] = []
        var last: Int?
        let total = beatsPerBar * Double(bars)
        for bar in 0..<bars {
            let start = Double(bar) * beatsPerBar
            let figure: [Note]
            switch lineage {
            case .octave: figure = octave(request.density, beatsPerBar)
            case .oneDrop: figure = oneDrop(request.density, beatsPerBar, &rng)
            case .tumbao: figure = tumbao(beatsPerBar)
            case .walking: figure = walking(beatsPerBar)
            case .rootFifth: figure = rootFifth(request.density, beatsPerBar, harmony: harmony, barStart: start)
            case .motown: figure = motown(request.density, beatsPerBar, &rng)
            case .rolling: figure = rolling(request.density, beatsPerBar)
            case .logDrum: figure = logDrum(request.density, beatsPerBar, &rng)
            default: figure = []
            }
            for note in figure {
                let onset = start + note.at
                guard onset < total else { continue }
                // Whose chord: the one at the onset, or — for an anticipation — the one it lands on.
                let chord = harmony.chord(at: min(total - 0.001, start + (note.anticipates ?? note.at)))
                let pitch: Int
                switch note.tone {
                case .interval(let interval):
                    let root = BassWriter.place(chord.root, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(root + chordTone(chord, interval), lineage)
                case .octaveUp:
                    pitch = BassWriter.clampToRegister(BassWriter.place(chord.root, near: nil, in: lineage) + 12, lineage)
                case .chordTone:
                    // One of the two chord tones nearest the last note, never the same note again:
                    // a line that moves by the shortest way, the seed choosing which way.
                    let root = BassWriter.place(chord.root, near: last, in: lineage)
                    let tones = chord.intervals.map { BassWriter.clampToRegister(root + $0, lineage) }
                    let near = last ?? tones[0]
                    let moving = tones.filter { $0 != near }
                    let nearest = (moving.isEmpty ? tones : moving).sorted { abs($0 - near) < abs($1 - near) }
                    pitch = nearest[rng.unit() < 0.65 || nearest.count == 1 ? 0 : 1]
                case .approach:
                    // A half-step into the next beat's root, from below or above as the seed says.
                    let next = harmony.chord(at: min(total - 0.001, onset + 1))
                    let target = BassWriter.place(next.root, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(target + (rng.unit() < 0.6 ? -1 : 1), lineage)
                }
                last = pitch
                drafts.append(Draft(pitch: pitch, start: onset, end: min(total, onset + note.length),
                                    velocity: note.velocity + Int(rng.unit() * 6)))
            }
        }
        // Walking and Motown lines step into a change; the others land on the root.
        if lineage == .walking {
            drafts = approachChanges(drafts, harmony: harmony, lineage: lineage, beatsPerBar: beatsPerBar)
        }
        if lineage == .motown {
            drafts += BassWriter.approaches(harmony: harmony, lineage: lineage, minimumMove: 2, totalBeats: total)
                .map { var d = $0; d.displaced = true; return d }
            drafts = dropOverlaps(drafts)
        }
        return drafts
    }

    // MARK: The figures

    struct Note {
        enum Tone { case interval(Int), octaveUp, chordTone, approach }
        var at: Double
        var tone: Tone
        var length: Double
        var velocity: Int = 100
        /// For a note that plays the chord of a later beat: that beat, in the bar.
        var anticipates: Double?
    }

    /// Disco and house: the root and its octave on eighths. Sparse, the octave on the off-beats
    /// only — the house bass that answers the kick; busy, every eighth, low–high.
    static func octave(_ density: Double, _ beats: Double) -> [Note] {
        if density < 0.4 {
            return stride(from: 0.5, to: beats, by: 1).map { Note(at: $0, tone: .octaveUp, length: 0.35, velocity: 104) }
        }
        return stride(from: 0.0, to: beats, by: 0.5).enumerated().map { i, t in
            Note(at: t, tone: i % 2 == 0 ? .interval(0) : .octaveUp, length: 0.38, velocity: i % 2 == 0 ? 102 : 110)
        }
    }

    /// Reggae one drop: nothing on one. The figure starts after it and leans on three, where the
    /// kick is; density adds the passing notes between.
    static func oneDrop(_ density: Double, _ beats: Double, _ rng: inout BassRandom) -> [Note] {
        guard beats >= 4 else { return [Note(at: 1, tone: .interval(0), length: 0.9), Note(at: 2, tone: .interval(7), length: 0.9)] }
        var notes = [Note(at: 2, tone: .interval(0), length: 0.9, velocity: 110)]
        notes.append(Note(at: 1, tone: .interval(0), length: 0.45))
        if density > 0.3 { notes.append(Note(at: 1.5, tone: .interval(rng.unit() < 0.5 ? 7 : 3), length: 0.45)) }
        if density > 0.5 { notes.append(Note(at: 3, tone: .interval(7), length: 0.45)) }
        if density > 0.7 { notes.append(Note(at: 3.5, tone: .interval(rng.unit() < 0.5 ? 3 : 10), length: 0.45)) }
        return notes.sorted { $0.at < $1.at }
    }

    /// The tumbao: the and of two, anticipating beat three's chord, and four, anticipating the
    /// next bar's — tied over, so one is never struck.
    static func tumbao(_ beats: Double) -> [Note] {
        guard beats >= 4 else { return [Note(at: beats - 1, tone: .interval(0), length: 1.5, anticipates: beats)] }
        return [Note(at: 1.5, tone: .interval(7), length: 1.5, velocity: 104, anticipates: 2),
                Note(at: 3, tone: .interval(0), length: 2.5, velocity: 110, anticipates: 4)]
    }

    /// A walking line: a quarter note a beat, the root on one, chord tones after. The step into
    /// the next change is added by `approachChanges`.
    static func walking(_ beats: Double) -> [Note] {
        stride(from: 0.0, to: beats, by: 1).map { t in
            Note(at: t, tone: t == 0 ? .interval(0) : .chordTone, length: 0.92, velocity: t == 0 ? 106 : 98)
        }
    }

    /// Root on one, fifth on three (on one and the next bar's one in three); busy, the eighth
    /// before three and four as well, a walk-up into a change on the last two beats.
    static func rootFifth(_ density: Double, _ beats: Double, harmony: HarmonyMap, barStart: Double) -> [Note] {
        guard beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108)] }
        var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108),
                     Note(at: 2, tone: .interval(-5), length: 0.9, velocity: 100)]
        let changeNext = harmony.changes.contains { abs($0 - (barStart + beats)) < 1e-6 }
        if density > 0.6, changeNext {
            notes.append(Note(at: 3, tone: .approach, length: 0.9, velocity: 96, anticipates: beats))
        } else if density > 0.4 {
            notes.append(Note(at: 3, tone: .interval(0), length: 0.45, velocity: 92))
        }
        return notes
    }

    /// Jamerson's eighths: one, then syncopated pickups on the ands, chord tones moving by the
    /// nearest way, the change approached chromatically.
    static func motown(_ density: Double, _ beats: Double, _ rng: inout BassRandom) -> [Note] {
        var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108)]
        let pool = stride(from: 0.5, to: beats, by: 0.5).filter { $0 != 0 }
            .sorted { a, b in
                let aAnd = a.truncatingRemainder(dividingBy: 1) != 0, bAnd = b.truncatingRemainder(dividingBy: 1) != 0
                return aAnd != bAnd ? aAnd : a < b
            }
        let count = Int((2 + density * 5).rounded())
        var picked = Array(pool.prefix(max(0, count - 1)))
        if rng.unit() < 0.5, let drop = picked.indices.randomElement(using: &rng) { picked.remove(at: drop) }
        notes += picked.map { Note(at: $0, tone: .chordTone, length: 0.4) }
        return notes.sorted { $0.at < $1.at }
    }

    /// The rolling sub: the root held, then a move — to the fifth or the octave — on the and of
    /// two or on three, and a third note when busy.
    static func rolling(_ density: Double, _ beats: Double) -> [Note] {
        var notes = [Note(at: 0, tone: .interval(0), length: density < 0.35 ? beats * 0.95 : beats * 0.6, velocity: 112)]
        if density >= 0.35 { notes.append(Note(at: beats * 0.625, tone: .interval(7), length: beats * 0.3, velocity: 104)) }
        if density >= 0.7 { notes.append(Note(at: beats * 0.875, tone: .octaveUp, length: beats * 0.12, velocity: 100)) }
        return notes
    }

    /// The log drum: short pitched hits off the beat, the root mostly and the octave for lift.
    static func logDrum(_ density: Double, _ beats: Double, _ rng: inout BassRandom) -> [Note] {
        let pool: [Double] = [0.75, 1.5, 2.75, 3.5, 2.25, 0.25, 3.0, 1.0].filter { $0 < beats }
        let count = max(2, Int((3 + density * 4).rounded()))
        return pool.prefix(count).map { t in
            Note(at: t, tone: rng.unit() < 0.3 ? .octaveUp : .interval(0), length: 0.22, velocity: 100 + Int(rng.unit() * 12))
        }.sorted { $0.at < $1.at }
    }

    // MARK: Shared

    /// The semitones above the root of a chord's tone by its nominal interval: a fifth is the
    /// chord's own fifth (diminished in a diminished chord), a third its own third.
    static func chordTone(_ chord: Chord, _ interval: Int) -> Int {
        let tones = chord.intervals
        switch interval {
        case 3, 4: return tones.first { $0 == 3 || $0 == 4 } ?? interval
        case 7, 6, 8: return tones.first { $0 >= 6 && $0 <= 8 } ?? 7
        case -5: return (tones.first { $0 >= 6 && $0 <= 8 } ?? 7) - 12
        case 10, 11: return tones.first { $0 == 10 || $0 == 11 } ?? 10
        default: return interval
        }
    }

    /// The last beat before each change becomes a half-step into the new root.
    static func approachChanges(_ drafts: [Draft], harmony: HarmonyMap, lineage: BassLineage, beatsPerBar: Double) -> [Draft] {
        var out = drafts
        for change in harmony.changes where change > 0 {
            guard let i = out.firstIndex(where: { abs($0.start - (change - 1)) < 1e-6 }) else { continue }
            let target = BassWriter.place(harmony.chord(at: change).root, near: out[i].pitch, in: lineage)
            out[i].pitch = BassWriter.clampToRegister(target - 1, lineage)
        }
        return out
    }

    /// Two notes starting together: the later one written wins.
    static func dropOverlaps(_ drafts: [Draft]) -> [Draft] {
        var seen: [Double: Int] = [:]
        var out: [Draft] = []
        for draft in drafts {
            let key = (draft.start * 1000).rounded()
            if let i = seen[key] { out[i] = draft } else { seen[key] = out.count; out.append(draft) }
        }
        return out
    }
}

extension BassRandom: RandomNumberGenerator {}
