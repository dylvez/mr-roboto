import Foundation
import MusicTheory
import SongGraph

// MARK: - A figure, a turnaround, a phrase

/// One bar of a hand's vocabulary: a way its player is known to play, as a record has it.
///
/// A hand used to be one figure, the same every bar of every song, so eleven lines in four genres
/// were one line. Each figure hand now has a few, cited the way the genre profiles cite, and a line
/// is a phrase of them: the seed picks the figure and the turnaround, so a fresh seed is a fresh
/// line and the same seed is the same line again.
public struct BassFigure: Sendable {
    public let name: String
    public let lineage: BassLineage
    /// Where the figure is heard: the player and the record, and the profile that cites them.
    public let source: String
    /// What it does, in a line.
    public let about: String
    /// The bar, at a density, over the bar it has. The seed is in the generator.
    let bar: @Sendable (BassFigures.Bar, inout BassRandom) -> [BassFigures.Note]
}

/// The last bar of a phrase: how the line turns into the next.
public enum BassTurnaround: String, Sendable, Hashable, CaseIterable {
    /// The figure as it is: a line that goes round.
    case none
    /// Beats three and four walk up the scale into the next bar's root.
    case walkUp = "walk-up"
    /// The last beat left empty: the drums have it.
    case restOnFour = "rest-on-four"
    /// A sixteenth skip on the and of four into the next bar.
    case skip
    /// The figure answered a fifth down from beat two on.
    case fifthDown = "fifth-down"
    /// The octaves walk down the scale into the next root: the disco turnaround.
    case octaveWalkDown = "octave-walk-down"
    /// The root struck on the last bar's one, where the figure leaves it empty: the marked tumbao.
    case markOne = "mark-one"

    public var name: String {
        switch self {
        case .none: return "straight through"
        case .walkUp: return "a walk-up into the next phrase"
        case .restOnFour: return "the last beat left to the drums"
        case .skip: return "a sixteenth skip into the next phrase"
        case .fifthDown: return "answered a fifth down"
        case .octaveWalkDown: return "the octaves walking down into the next phrase"
        case .markOne: return "the root marked on the last bar's one"
        }
    }
}

/// The shape a line is written in: a figure for the body, a turnaround for the last bar of each
/// phrase, both the seed's choice unless a figure is asked for by number.
public struct BassPhrase: Sendable {
    public let figure: BassFigure
    /// The figure's place in the hand's vocabulary: what `BassRequest.figure` names.
    public let figureIndex: Int
    public let turnaround: BassTurnaround
    /// What every eighth bar turns with instead, so a long line's halves end differently.
    public let secondTurnaround: BassTurnaround
    /// Bars a phrase: four, two for a two-bar line, one for a one-bar line, which never turns.
    public let length: Int
    /// For a two-celled figure, which cell comes first.
    public let swapped: Bool

    /// "the Nashville alternating bass, a walk-up into the next phrase".
    public var about: String {
        length > 1 && turnaround != .none ? "\(figure.name), \(turnaround.name)" : figure.name
    }

    /// How a bar turns, if it is the last of its phrase.
    func turnaround(atBar index: Int, of bars: Int) -> BassTurnaround? {
        guard length > 1 else { return nil }
        guard (index + 1) % length == 0 || index == bars - 1 else { return nil }
        return (index + 1) % 8 == 0 ? secondTurnaround : turnaround
    }

    static func choose(for request: BassRequest, bars: Int, rng: inout BassRandom) -> BassPhrase {
        let figures = request.lineage.figures
        precondition(!figures.isEmpty, "\(request.lineage) has no figures")
        // Every draw is made whether or not a figure was asked for, so asking for one changes
        // nothing else about the line.
        let figureDraw = rng.unit()
        let turnDraw = rng.unit()
        let secondDraw = rng.unit()
        let swapped = rng.unit() < 0.5
        let index = request.figure.map { (($0 % figures.count) + figures.count) % figures.count }
            ?? min(figures.count - 1, Int(figureDraw * Double(figures.count)))
        let turns = BassFigures.turnarounds(for: request.lineage)
        let turn = turns[min(turns.count - 1, Int(turnDraw * Double(turns.count)))]
        let second = turns[min(turns.count - 1, Int(secondDraw * Double(turns.count)))]
        let length = bars >= 4 ? 4 : (bars >= 2 ? 2 : 1)
        return BassPhrase(figure: figures[index], figureIndex: index, turnaround: turn, secondTurnaround: second,
                          length: length, swapped: swapped)
    }
}

public extension BassLineage {
    /// The hand's vocabulary, in the order `BassRequest.figure` counts; empty for the players that
    /// write from the kick rather than from a figure.
    var figures: [BassFigure] { BassFigures.vocabulary(for: self) }

    /// Whether the hand writes from a vocabulary of figures.
    var writesFigures: Bool { !figures.isEmpty }
}

// MARK: - The figure writer

/// The genres' own bass figures, written against the chords, in phrases, under the kick.
///
/// Positions are in beats from the bar's start; a figure written for four beats is laid over the
/// bar it has, so a waltz's root–fifth still lands on one. Onsets here sit on the grid: every one of
/// these players plays with the drums rather than behind them, which is what `defaultLagMS` of 0
/// says.
enum BassFigures {
    typealias Draft = BassWriter.Draft

    /// What a figure knows of the bar it is writing.
    struct Bar {
        var density: Double
        var beats: Double
        /// The bar's index in the line, from 0.
        var index: Int
        var bars: Int
        /// Whether the chord on one is the one the bar before ended on.
        var held: Bool
        /// Whether the next bar begins a new chord.
        var changeNext: Bool
        /// Where the chord changes inside the bar, in beats from its start.
        var changes: [Double]
        /// For a two-celled figure, whether the cells come the other way round.
        var swapped: Bool

        /// Whether this is the first cell of a two-bar figure.
        var firstCell: Bool { (index % 2 == 0) != swapped }
    }

    struct Note {
        enum Tone {
            case interval(Int), octaveUp, chordTone, approach
            /// The next bar's root, offset by semitones: an enclosure from above or below.
            case nextRoot(Int)
            /// So many scale steps from the next bar's root (below when negative), `up` semitones
            /// higher: a walk-up, or the octaves walking down.
            case stepTo(Int, up: Int)
        }
        var at: Double
        var tone: Tone
        var length: Double
        var velocity: Int = 100
        /// How much the figure needs it: 3 is the figure itself and stands whatever the budget,
        /// 2 is its body, 1 is what density added.
        var weight: Int = 2
        /// For a note that plays the chord of a later beat: that beat, in the bar.
        var anticipates: Double?
    }

    /// How a hand hears the drums.
    enum KickReading {
        /// An off-beat kick gets a note, and the figure's own off-beats are kept where the kick is
        /// first when the budget is short.
        case follows
        /// The figure stands against the kick: that is the point of it.
        case against
        /// The hand sits with the bar and does not listen.
        case ignores
    }

    static func kickReading(_ lineage: BassLineage) -> KickReading {
        switch lineage {
        case .motown, .octave, .rolling, .afrobeat, .logDrum: return .follows
        case .oneDrop, .tumbao, .dub: return .against
        default: return .ignores
        }
    }

    /// The turnarounds a hand turns with. `.none` where a straight line is the idiom too.
    static func turnarounds(for lineage: BassLineage) -> [BassTurnaround] {
        switch lineage {
        case .rootFifth: return [.walkUp, .restOnFour, .skip, .none]
        case .motown: return [.skip, .walkUp, .restOnFour, .none]
        case .oneDrop: return [.fifthDown, .skip, .restOnFour, .none]
        case .octave: return [.octaveWalkDown, .skip, .restOnFour, .none]
        case .tumbao: return [.markOne, .fifthDown, .none]
        case .walking: return [.walkUp, .restOnFour, .none]
        case .rolling: return [.fifthDown, .restOnFour, .none]
        case .dub: return [.fifthDown, .restOnFour, .skip]
        case .logDrum: return [.skip, .restOnFour, .none]
        case .afrobeat, .pedal: return [.none]
        default: return [.none]
        }
    }

    static func write(_ request: BassRequest, kicks: [Double], harmony: HarmonyMap, beatsPerBar: Double, bars: Int,
                      rng: inout BassRandom) -> [Draft] {
        let lineage = request.lineage
        let phrase = BassPhrase.choose(for: request, bars: bars, rng: &rng)
        let reading = kickReading(lineage)
        let budget = BassWriter.attackBudget(density: request.density, tempo: request.tempo, lineage: lineage)
        var drafts: [Draft] = []
        /// Onsets that step into a change by design: `approachChanges` leaves them as written.
        var protected: [Double] = []
        var last: Int?
        let total = beatsPerBar * Double(bars)
        for bar in 0..<bars {
            let start = Double(bar) * beatsPerBar
            let end = start + beatsPerBar
            // The bar after this one: the first, after the last.
            let nextStart = end < total - 1e-6 ? end : 0
            let previousEnd = bar == 0 ? total - 0.001 : start - 0.001
            let context = Bar(density: request.density, beats: beatsPerBar, index: bar, bars: bars,
                              held: harmony.chord(at: start) == harmony.chord(at: previousEnd),
                              changeNext: harmony.chord(at: nextStart) != harmony.chord(at: end - 0.001),
                              changes: harmony.changes.filter { $0 > start + 1e-6 && $0 < end - 1e-6 }.map { $0 - start },
                              swapped: phrase.swapped)
            var figure = phrase.figure.bar(context, &rng)
            if let turn = phrase.turnaround(atBar: bar, of: bars) {
                figure = turned(figure, turn, bar: context, lineage: lineage)
            }
            figure = heard(figure, kicks: kicks, barStart: start, beats: beatsPerBar, budget: budget, reading: reading, lineage: lineage)
            figure = changing(figure, on: context.changes, lineage: lineage)

            for note in figure {
                let onset = start + note.at
                guard onset < total else { continue }
                // Whose chord: the one at the onset, or — for an anticipation — the one it lands on.
                let chord = harmony.chord(at: min(total - 0.001, start + (note.anticipates ?? note.at)))
                let pitch: Int
                switch note.tone {
                case .interval(let interval):
                    let root = BassWriter.place(chord.bass, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(root + tone(of: chord, interval), lineage)
                case .octaveUp:
                    pitch = BassWriter.clampToRegister(BassWriter.place(chord.bass, near: nil, in: lineage) + 12, lineage)
                case .chordTone:
                    // One of the two chord tones nearest the last note, never the same note again:
                    // a line that moves by the shortest way, the seed choosing which way.
                    let root = BassWriter.place(chord.bass, near: last, in: lineage)
                    // Over an inversion the tones are counted from the bass note, not the root.
                    let offset = bassOffset(chord)
                    let tones = chord.intervals.map { BassWriter.clampToRegister(root + (offset == 0 ? $0 : (($0 - offset) % 12 + 12) % 12), lineage) }
                    let near = last ?? tones[0]
                    let moving = tones.filter { $0 != near }
                    let nearest = (moving.isEmpty ? tones : moving).sorted { abs($0 - near) < abs($1 - near) }
                    pitch = nearest[rng.unit() < 0.65 || nearest.count == 1 ? 0 : 1]
                case .approach:
                    // A half-step into the next beat's root, from below or above as the seed says.
                    let next = harmony.chord(at: min(total - 0.001, onset + 1))
                    let target = BassWriter.place(next.bass, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(target + (rng.unit() < 0.6 ? -1 : 1), lineage)
                    protected.append(onset)
                case .nextRoot(let offset):
                    let target = BassWriter.place(harmony.chord(at: nextStart).bass, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(target + offset, lineage)
                    protected.append(onset)
                case .stepTo(let steps, let up):
                    let target = BassWriter.place(harmony.chord(at: nextStart).bass, near: last, in: lineage)
                    pitch = BassWriter.clampToRegister(scaleStep(from: target, by: steps, in: request.key) + up, lineage)
                    protected.append(onset)
                }
                last = pitch
                drafts.append(Draft(pitch: pitch, start: onset, end: min(total, onset + note.length),
                                    velocity: note.velocity + Int(rng.unit() * 6)))
            }
        }
        // Walking and Motown lines step into a change; the others land on the root.
        if lineage == .walking {
            drafts = approachChanges(drafts, harmony: harmony, lineage: lineage, beatsPerBar: beatsPerBar, protected: protected)
        }
        // A pedal is held as long as its chord is: a bar's root that is the bar before's goes on.
        if lineage == .pedal {
            var held: [Draft] = []
            for draft in drafts.sorted(by: { $0.start < $1.start }) {
                if let previous = held.last, previous.pitch == draft.pitch, abs(previous.end - draft.start) < 0.05 {
                    held[held.count - 1].end = draft.end
                } else {
                    held.append(draft)
                }
            }
            drafts = held
        }
        if lineage == .motown {
            drafts += BassWriter.approaches(harmony: harmony, lineage: lineage, minimumMove: 2, totalBeats: total)
                .map { var d = $0; d.displaced = true; return d }
            drafts = dropOverlaps(drafts)
        }
        return drafts
    }

    // MARK: A change inside the bar

    /// The bar with its chord changes said: the root has to move. A note on a change plays the new
    /// chord's root whatever the figure had there, and a change the figure has nothing near gets
    /// one. A pedal holds through its own way, and the tumbao says a change by anticipating it.
    static func changing(_ notes: [Note], on changes: [Double], lineage: BassLineage) -> [Note] {
        guard !changes.isEmpty, lineage != .pedal, lineage != .tumbao else { return notes }
        var out = notes
        for change in changes {
            if let index = out.firstIndex(where: { abs(($0.anticipates ?? $0.at) - change) < 1e-6 }) {
                if case .interval = out[index].tone { out[index].tone = .interval(0) }
                if case .chordTone = out[index].tone { out[index].tone = .interval(0) }
            } else if !out.contains(where: { abs($0.at - change) < 0.3 }) {
                let next = out.map(\.at).filter { $0 > change }.min()
                out.append(Note(at: change, tone: .interval(0), length: min(0.9, (next ?? change + 0.9) - change), velocity: 102, weight: 3))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    // MARK: The turnaround

    /// The last bar of a phrase, turned.
    static func turned(_ notes: [Note], _ turnaround: BassTurnaround, bar: Bar, lineage: BassLineage) -> [Note] {
        let beats = bar.beats
        guard beats >= 4 else { return notes }
        switch turnaround {
        case .none:
            return notes
        case .walkUp:
            var kept = notes.filter { $0.at < beats - 2 }
            kept.append(Note(at: beats - 2, tone: .stepTo(-2, up: 0), length: 0.9, velocity: 100, weight: 3))
            kept.append(Note(at: beats - 1, tone: .stepTo(-1, up: 0), length: 0.9, velocity: 102, weight: 3))
            return kept
        case .restOnFour:
            return notes.filter { $0.at < beats - 1 }
        case .skip:
            var kept = notes.filter { $0.at < beats - 0.5 }
            let short = lineage == .logDrum ? 0.22 : 0.2
            kept.append(Note(at: beats - 0.5, tone: .interval(0), length: short, velocity: 98, weight: 3, anticipates: beats))
            kept.append(Note(at: beats - 0.25, tone: lineage == .octave ? .octaveUp : .interval(0), length: short, velocity: 104,
                             weight: 3, anticipates: beats))
            return kept
        case .fifthDown:
            return notes.map { note in
                var note = note
                if note.at >= 1, case .interval(0) = note.tone { note.tone = .interval(-5) }
                return note
            }
        case .octaveWalkDown:
            // Eighths down the scale into the next root, low and high, the last beat left.
            var out: [Note] = []
            for (i, step) in [3, 2, 1].enumerated() {
                out.append(Note(at: Double(i), tone: .stepTo(step, up: 0), length: 0.38, velocity: 102, weight: 3))
                out.append(Note(at: Double(i) + 0.5, tone: .stepTo(step, up: 12), length: 0.38, velocity: 108, weight: 3))
            }
            return out
        case .markOne:
            guard !notes.contains(where: { $0.at < 0.01 }) else { return notes }
            return [Note(at: 0, tone: .interval(0), length: 1.4, velocity: 110, weight: 3)] + notes
        }
    }

    // MARK: The kick

    /// The bar as the hand hears it under the drums, inside R14's budget. A hand that follows the
    /// kick gives every off-beat kick a short root where the figure has nothing, and when the
    /// budget is short keeps the heavier notes first, and among equals the ones on a beat, then
    /// the ones on a kick, then the earlier; the figure's own notes — weight 3 — stand whatever
    /// the budget, so a figure is still itself at the bottom of the density lever.
    static func heard(_ notes: [Note], kicks: [Double], barStart: Double, beats: Double, budget: Int,
                      reading: KickReading, lineage: BassLineage) -> [Note] {
        var notes = notes
        let barKicks = kicks.filter { $0 >= barStart - 1e-6 && $0 < barStart + beats - 1e-6 }.map { $0 - barStart }
        func onKick(_ at: Double) -> Bool { barKicks.contains { abs($0 - at) < 0.13 } }
        func onBeat(_ at: Double) -> Bool { abs(at - at.rounded()) < 1e-6 }
        if reading == .follows {
            let short: Double = lineage == .logDrum ? 0.22 : (lineage == .octave ? 0.35 : 0.4)
            for kick in barKicks where !onBeat(kick) && !notes.contains(where: { abs($0.at - kick) < 0.13 }) {
                notes.append(Note(at: kick, tone: .interval(0), length: short, velocity: 100, weight: 2))
            }
        }
        let standing = notes.filter { $0.weight >= 3 }
        var rest = notes.filter { $0.weight < 3 }
        let room = max(0, budget - standing.count)
        if rest.count > room {
            rest.sort { a, b in
                let ra = (-a.weight, onBeat(a.at) ? 0 : 1, reading == .follows && onKick(a.at) ? 0 : 1, a.at)
                let rb = (-b.weight, onBeat(b.at) ? 0 : 1, reading == .follows && onKick(b.at) ? 0 : 1, b.at)
                return ra < rb
            }
            rest = Array(rest.prefix(room))
        }
        return (standing + rest).sorted { $0.at < $1.at }
    }

    // MARK: The vocabularies

    static func vocabulary(for lineage: BassLineage) -> [BassFigure] {
        switch lineage {
        case .rootFifth: return rootFifth
        case .motown: return motown
        case .oneDrop: return oneDrop
        case .octave: return octave
        case .tumbao: return tumbao
        case .walking: return walking
        case .rolling: return rolling
        case .dub: return dub
        case .afrobeat: return afrobeat
        case .logDrum: return logDrum
        case .pedal: return pedal
        case .palladino, .thundercat, .programmed, .boomBap: return []
        }
    }

    static let country = "the country profile: notreble, Mastering country bass lines — roots, fifths and chord function"
    static let klezmer = "the klezmer profile: Musik-for, Klezmergroove (Kap01)"
    static let bossa = "the bossa-nova profile: Acoustic Guitar, Learn basic bossa nova patterns inside and out"
    static let cumbia = "the cumbia profile: Bass Scales, How to play cumbia bass; Se7en Beat Lab, Cumbia"
    static let soul = "the soul profile: Ryan Madora, Easy Motown bass lines — James Jamerson for beginners; MusicRadar, Play bass like James Jamerson"
    static let reggae = "the reggae profile: Wayne & Wax, Roots riddim tutorial; Tunable, Reggae one drop; the ska profile: LargeUp, Reggae's ten greatest bassists"
    static let disco = "the disco profile: TalkingBass, Good Times — breakdown of a Bernard Edwards classic; Wikipedia, Disco"
    static let house = "the house profile: Attack Magazine, Beat dissected — 90s house; EDMProd, How to make house music"
    static let salsa = "the salsa profile: Wikipedia, Tumbao; Rhythm Notes, Salsa rhythms"
    static let jazz = "the jazz profile: Learn Jazz Standards, How to write a walking bass line"
    static let drumAndBass = "the drum-and-bass profile: EDMProd, How to make drum and bass; Attack Magazine, Reese bass redux"
    static let dubProfile = "the dub profile: Wikipedia, Dub music; Wayne & Wax, Roots riddim tutorial; Sound On Sound, Mad Professor"
    static let afrobeatProfile = "the afrobeat profile: Grady Short, Listening to echoes of afrobeat; Afrofunk Forum, Afrobeat architect Tony Allen"
    static let amapiano = "the amapiano profile: Roland, Creating amapiano tracks; Inspired by Beatz, How the log drum sound is created"
    static let score = "the film-score profile: Frank Lehman, Star Wars thematic catalogue (pedal points); the ambient profile: Wikipedia, Pop (Gas)"

    /// Country, folk, klezmer, cumbia: the two-beat bass and its relatives.
    static let rootFifth: [BassFigure] = [
        BassFigure(name: "Root and fifth", lineage: .rootFifth, source: "the country two-beat — \(country)",
                   about: "root on one, the fifth below on three; busier, a root on the and of three") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3),
                         Note(at: 2, tone: .interval(-5), length: 0.9, velocity: 100, weight: 3)]
            if bar.density > 0.4 { notes.append(Note(at: 3, tone: .interval(0), length: 0.45, velocity: 92, weight: 1)) }
            return notes
        },
        BassFigure(name: "Alternating bass", lineage: .rootFifth,
                   source: "the Nashville alternating bass — Buck Owens' and Johnny Cash's two-beat; \(country)",
                   about: "root on one, the fifth above on three, and the fifth below on a bar whose chord is held from the one before") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3),
                         Note(at: 2, tone: .interval(bar.held ? -5 : 7), length: 0.9, velocity: 100, weight: 3)]
            if bar.density > 0.6 { notes.append(Note(at: 3.5, tone: .interval(0), length: 0.4, velocity: 90, weight: 1, anticipates: bar.beats)) }
            return notes
        },
        BassFigure(name: "Boom-chick with a push", lineage: .rootFifth,
                   source: "bluegrass's pickup into the fifth — \(country)",
                   about: "root on one, a chord tone on the and of two pushing into the fifth below on three") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3),
                         Note(at: 1.5, tone: .chordTone, length: 0.45, velocity: 94, weight: 3),
                         Note(at: 2, tone: .interval(-5), length: 0.9, velocity: 100, weight: 3)]
            if bar.density > 0.5 { notes.append(Note(at: 3.5, tone: .interval(0), length: 0.4, velocity: 90, weight: 1, anticipates: bar.beats)) }
            return notes
        },
        BassFigure(name: "Walk-up", lineage: .rootFifth,
                   source: "the train beat's quarters walking into each change — \(country)",
                   about: "quarters, root and fifth, the last beat stepping up the scale into a change") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3),
                         Note(at: 1, tone: .interval(-5), length: 0.9, velocity: 96, weight: 2),
                         Note(at: 2, tone: .interval(0), length: 0.9, velocity: 102, weight: 3)]
            if bar.changeNext {
                if bar.density > 0.5 { notes[2].tone = .stepTo(-2, up: 0) }
                notes.append(Note(at: 3, tone: .stepTo(-1, up: 0), length: 0.9, velocity: 100, weight: 3))
            } else {
                notes.append(Note(at: 3, tone: .interval(-5), length: 0.9, velocity: 94, weight: 2))
            }
            return notes
        },
        BassFigure(name: "Oom-pah", lineage: .rootFifth,
                   source: "the tuba's quarters of klezmer and polka — \(klezmer)",
                   about: "root, fifth, root as short quarters, the fourth beat left to the drums unless busy") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 110, weight: 3),
                         Note(at: 1, tone: .interval(-5), length: 0.45, velocity: 96, weight: 3),
                         Note(at: 2, tone: .interval(0), length: 0.45, velocity: 104, weight: 3)]
            if bar.density > 0.6 { notes.append(Note(at: 3, tone: .interval(-5), length: 0.45, velocity: 94, weight: 1)) }
            return notes
        },
        BassFigure(name: "Three-three-two", lineage: .rootFifth,
                   source: "the bulgar's 3+3+2, which the bass follows — \(klezmer)",
                   about: "root on one, the fifth below on the and of two, the root on four: the bulgar's three-three-two") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            return [Note(at: 0, tone: .interval(0), length: 1.4, velocity: 110, weight: 3),
                    Note(at: 1.5, tone: .interval(-5), length: 1.4, velocity: 100, weight: 3),
                    Note(at: 3, tone: .interval(0), length: 0.9, velocity: 104, weight: 3)]
        },
        BassFigure(name: "Bossa", lineage: .rootFifth,
                   source: "root and fifth on one and three with a bounce on the upbeat, a change anticipated on the and — \(bossa)",
                   about: "root on one with a bounce on the and of two, the fifth below on three, and a change anticipated on the and of four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 104, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 1.4, velocity: 104, weight: 3),
                         Note(at: 1.5, tone: .interval(0), length: 0.4, velocity: 84, weight: 2),
                         Note(at: 2, tone: .interval(-5), length: 1.4, velocity: 98, weight: 3)]
            if bar.changeNext {
                notes.append(Note(at: 3.5, tone: .interval(0), length: 0.45, velocity: 96, weight: 3, anticipates: 4))
            } else if bar.density > 0.45 {
                notes.append(Note(at: 3.5, tone: .interval(-5), length: 0.4, velocity: 84, weight: 1))
            }
            return notes
        },
        BassFigure(name: "Cumbia", lineage: .rootFifth,
                   source: "roots on one and three, fifths between, cut to half their value, the quarter on three left long — \(cumbia)",
                   about: "staccato root and fifth, the root on three held its full value, which is what gives the swing") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 110, weight: 3),
                         Note(at: 1, tone: .interval(-5), length: 0.45, velocity: 96, weight: 2),
                         Note(at: 2, tone: .interval(0), length: 0.92, velocity: 106, weight: 3),
                         Note(at: 3, tone: .interval(-5), length: 0.45, velocity: 96, weight: 2)]
            if bar.density > 0.7 { notes.insert(Note(at: 1.5, tone: .interval(3), length: 0.4, velocity: 88, weight: 1), at: 2) }
            return notes
        },
    ]

    /// Jamerson's lines, as the published transcriptions have them.
    static let motown: [BassFigure] = [
        BassFigure(name: "Syncopated eighths", lineage: .motown,
                   source: "Jamerson's pickups on the ands — \(soul)",
                   about: "root on one, then chord tones on the ands the seed picks, moving by the nearest way") { bar, rng in
            syncopatedEighths(bar, &rng)
        },
        BassFigure(name: "My Girl", lineage: .motown,
                   source: "the My Girl verse (The Temptations, 1964) — \(soul)",
                   about: "root on one, the third on the and of two stepping up to the fifth on three") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 1.4, velocity: 108, weight: 3),
                         Note(at: 1.5, tone: .interval(3), length: 0.45, velocity: 96, weight: 3),
                         Note(at: 2, tone: .interval(7), length: 0.9, velocity: 104, weight: 3)]
            if bar.density > 0.5 { notes.append(Note(at: 3, tone: .interval(7), length: 0.45, velocity: 92, weight: 1)) }
            if bar.density > 0.7 { notes.append(Note(at: 3.5, tone: .interval(3), length: 0.4, velocity: 94, weight: 1)) }
            return notes
        },
        BassFigure(name: "And-of-four skip", lineage: .motown,
                   source: "the sixteenth skip into the next bar of Ain't No Mountain High Enough (1967) — \(soul)",
                   about: "roots on one and three, a chord tone on two, and a sixteenth skip on the and of four into the next bar") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108, weight: 3),
                         Note(at: 1, tone: .chordTone, length: 0.45, velocity: 96, weight: 2),
                         Note(at: 2, tone: .interval(0), length: 0.45, velocity: 104, weight: 3),
                         Note(at: 3.5, tone: .interval(0), length: 0.2, velocity: 98, weight: 3, anticipates: 4),
                         Note(at: 3.75, tone: .interval(0), length: 0.2, velocity: 104, weight: 3, anticipates: 4)]
            if bar.density > 0.5 { notes.insert(Note(at: 2.5, tone: .chordTone, length: 0.4, velocity: 92, weight: 1), at: 3) }
            return notes
        },
        BassFigure(name: "Held, then eighths", lineage: .motown,
                   source: "the tension and release of Standing in the Shadows of Love (1966) — \(soul)",
                   about: "a bar of the root held with a pickup at its end, then a bar of syncopated eighths") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)] }
            if bar.firstCell {
                return [Note(at: 0, tone: .interval(0), length: 3.4, velocity: 108, weight: 3),
                        Note(at: 3.5, tone: .chordTone, length: 0.4, velocity: 96, weight: 3)]
            }
            return syncopatedEighths(bar, &rng)
        },
    ]

    /// Root on one and chord tones after it, as many as density says: on the ands, which the seed
    /// picks, with one of them on a beat instead when the seed says so — at the middle of the
    /// density lever every and would otherwise be taken and every seed would be the one line.
    static func syncopatedEighths(_ bar: Bar, _ rng: inout BassRandom) -> [Note] {
        var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 108, weight: 3)]
        let pool = stride(from: 0.5, to: bar.beats, by: 0.5).filter { $0 != 0 }
        let ands = pool.filter { $0.truncatingRemainder(dividingBy: 1) != 0 }.shuffled(using: &rng)
        let beats = pool.filter { $0.truncatingRemainder(dividingBy: 1) == 0 }.shuffled(using: &rng)
        let count = max(0, Int((2 + bar.density * 5).rounded()) - 1)
        let onBeats = min(beats.count, count > 1 && rng.unit() < 0.5 ? 1 : 0)
        let picked = Array(ands.prefix(max(0, count - onBeats))) + Array(beats.prefix(onBeats))
        notes += picked.map { Note(at: $0, tone: .chordTone, length: 0.4) }
        return notes.sorted { $0.at < $1.at }
    }

    /// Family Man Barrett's and Robbie Shakespeare's lines under the one drop and the rockers.
    static let oneDrop: [BassFigure] = [
        BassFigure(name: "One drop", lineage: .oneDrop,
                   source: "the one drop's bass, nothing on one, landing with the kick on three — \(reggae)",
                   about: "beat one left empty, a short root on two, the root held on three; busier, the fifth or third between and after") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 1, tone: .interval(0), length: 0.9, weight: 3), Note(at: 2, tone: .interval(7), length: 0.9, weight: 3)] }
            var notes = [Note(at: 2, tone: .interval(0), length: 0.9, velocity: 110, weight: 3),
                         Note(at: 1, tone: .interval(0), length: 0.45, weight: 2)]
            if bar.density > 0.3 { notes.append(Note(at: 1.5, tone: .interval(rng.unit() < 0.5 ? 7 : 3), length: 0.45, weight: 1)) }
            if bar.density > 0.5 { notes.append(Note(at: 3, tone: .interval(7), length: 0.45, weight: 1)) }
            if bar.density > 0.7 { notes.append(Note(at: 3.5, tone: .interval(rng.unit() < 0.5 ? 3 : 10), length: 0.45, weight: 1)) }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Rockers", lineage: .oneDrop,
                   source: "the rockers line of Sly & Robbie, the root held from one — \(reggae)",
                   about: "the root held from one, the fifth on three; busier, the root again on four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 1.9, velocity: 110, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 1.9, velocity: 110, weight: 3),
                         Note(at: 2, tone: .interval(7), length: 0.9, velocity: 102, weight: 3)]
            if bar.density > 0.5 { notes.append(Note(at: 3, tone: .interval(0), length: 0.45, velocity: 98, weight: 1)) }
            if bar.density > 0.7 { notes.append(Note(at: 3.5, tone: .chordTone, length: 0.4, velocity: 94, weight: 1)) }
            return notes
        },
        BassFigure(name: "Question and answer", lineage: .oneDrop,
                   source: "the two-bar line of Stir It Up (1973), the second bar a fourth down — \(reggae)",
                   about: "the one drop's figure, then the same figure answered a fourth down in the next bar") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 1, tone: .interval(0), length: 0.9, weight: 3)] }
            let root = bar.firstCell ? 0 : -5
            var notes = [Note(at: 2, tone: .interval(root), length: 0.9, velocity: 110, weight: 3),
                         Note(at: 1, tone: .interval(root), length: 0.45, weight: 2)]
            if bar.density > 0.3 { notes.append(Note(at: 1.5, tone: .interval(rng.unit() < 0.5 ? 7 : 3), length: 0.45, weight: 1)) }
            if bar.density > 0.6 { notes.append(Note(at: 3, tone: .interval(bar.firstCell ? 7 : 0), length: 0.45, weight: 1)) }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Pickup", lineage: .oneDrop,
                   source: "the line that comes in on the and of four of the bar before — \(reggae)",
                   about: "a root on the and of four pulling into the next bar, the root on three, a chord tone on two") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: bar.beats - 0.5, tone: .interval(0), length: 0.4, weight: 3, anticipates: bar.beats)] }
            var notes = [Note(at: 1, tone: .chordTone, length: 0.45, velocity: 96, weight: 2),
                         Note(at: 2, tone: .interval(0), length: 0.9, velocity: 110, weight: 3),
                         Note(at: 3.5, tone: .interval(0), length: 0.4, velocity: 100, weight: 3, anticipates: 4)]
            if bar.density > 0.5 { notes.insert(Note(at: 3, tone: .interval(7), length: 0.45, velocity: 94, weight: 1), at: 2) }
            return notes
        },
    ]

    /// Disco and house: the octave bass and what Bernard Edwards did with it.
    static let octave: [BassFigure] = [
        BassFigure(name: "Pumping octaves", lineage: .octave,
                   source: "disco's eighth-note octaves — \(disco)",
                   about: "the root and its octave on eighths, low–high; sparse, the octave on the off-beats only") { bar, _ in
            if bar.density < 0.4 {
                return stride(from: 0.5, to: bar.beats, by: 1).map { Note(at: $0, tone: .octaveUp, length: 0.35, velocity: 104, weight: 2) }
            }
            return stride(from: 0.0, to: bar.beats, by: 0.5).enumerated().map { i, t in
                Note(at: t, tone: i % 2 == 0 ? .interval(0) : .octaveUp, length: 0.38, velocity: i % 2 == 0 ? 102 : 110, weight: 2)
            }
        },
        BassFigure(name: "Good Times", lineage: .octave,
                   source: "Bernard Edwards' sixteenth skip into the next bar, Good Times (Chic, 1979) — \(disco)",
                   about: "octaves on eighths through three beats, then a root on four and a sixteenth skip on the and of four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.38, weight: 3)] }
            var notes: [Note] = []
            for t in stride(from: 0.0, to: 3.0, by: 0.5) {
                let onBeat = t.truncatingRemainder(dividingBy: 1) == 0
                if onBeat || bar.density >= 0.4 {
                    notes.append(Note(at: t, tone: onBeat ? .interval(0) : .octaveUp, length: 0.38, velocity: onBeat ? 102 : 110,
                                      weight: t == 0 || t == 2 ? 3 : 2))
                }
            }
            notes.append(Note(at: 3, tone: .interval(0), length: 0.38, velocity: 104, weight: 2))
            notes.append(Note(at: 3.5, tone: .octaveUp, length: 0.2, velocity: 106, weight: 3))
            notes.append(Note(at: 3.75, tone: .octaveUp, length: 0.2, velocity: 110, weight: 3, anticipates: 4))
            return notes
        },
        BassFigure(name: "House octave", lineage: .octave,
                   source: "the house bass that answers the kick on the off-beats — \(house)",
                   about: "the root on one and three, the octave on every off-beat answering the kick; busier, the root on every beat") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.45, weight: 3), Note(at: 0.5, tone: .octaveUp, length: 0.35, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.45, velocity: 104, weight: 3),
                         Note(at: 2, tone: .interval(0), length: 0.45, velocity: 100, weight: 2)]
            notes += stride(from: 0.5, to: bar.beats, by: 1).map { Note(at: $0, tone: .octaveUp, length: 0.35, velocity: 110, weight: 3) }
            if bar.density > 0.6 { notes += [Note(at: 1, tone: .interval(0), length: 0.45, velocity: 96, weight: 1), Note(at: 3, tone: .interval(0), length: 0.45, velocity: 96, weight: 1)] }
            return notes.sorted { $0.at < $1.at }
        },
    ]

    /// Cachao's and Arsenio Rodríguez's tumbaos.
    static let tumbao: [BassFigure] = [
        BassFigure(name: "Tumbao", lineage: .tumbao,
                   source: "the tumbao's bombo and ponche, anticipating and tied over — \(salsa)",
                   about: "the fifth on the and of two anticipating three, the root on four anticipating the next bar, tied over; one is never struck") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: bar.beats - 1, tone: .interval(0), length: 1.5, weight: 3, anticipates: bar.beats)] }
            return [Note(at: 1.5, tone: .interval(7), length: 1.5, velocity: 104, weight: 3, anticipates: 2),
                    Note(at: 3, tone: .interval(0), length: 2.5, velocity: 110, weight: 3, anticipates: 4)]
        },
        BassFigure(name: "Marked tumbao", lineage: .tumbao,
                   source: "the tumbao with the root marked on one every second bar — \(salsa)",
                   about: "the tumbao, with the root struck on one every second bar") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: bar.beats - 1, tone: .interval(0), length: 1.5, weight: 3, anticipates: bar.beats)] }
            var notes = [Note(at: 1.5, tone: .interval(7), length: 1.5, velocity: 104, weight: 3, anticipates: 2),
                         Note(at: 3, tone: .interval(0), length: 2.5, velocity: 110, weight: 3, anticipates: 4)]
            if bar.firstCell { notes.insert(Note(at: 0, tone: .interval(0), length: 1.4, velocity: 106, weight: 2), at: 0) }
            return notes
        },
        BassFigure(name: "Two-celled tumbao", lineage: .tumbao,
                   source: "Arsenio Rodríguez's two-celled tumbao, the cells trading root and fifth — \(salsa)",
                   about: "the tumbao, then a bar with the root on the and of two and the fifth on four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: bar.beats - 1, tone: .interval(0), length: 1.5, weight: 3, anticipates: bar.beats)] }
            if bar.firstCell {
                return [Note(at: 1.5, tone: .interval(7), length: 1.5, velocity: 104, weight: 3, anticipates: 2),
                        Note(at: 3, tone: .interval(0), length: 2.5, velocity: 110, weight: 3, anticipates: 4)]
            }
            return [Note(at: 1.5, tone: .interval(0), length: 1.5, velocity: 108, weight: 3, anticipates: 2),
                    Note(at: 3, tone: .interval(7), length: 2.5, velocity: 104, weight: 3, anticipates: 4)]
        },
        BassFigure(name: "Tresillo tumbao", lineage: .tumbao,
                   source: "the tumbao on the clave: a tresillo on the three side, the tumbao on the two side — \(salsa)",
                   about: "on the clave's three-side bar the root on one, the fifth on the and of two and the root on four; on the two-side bar the tumbao") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: bar.beats - 1, tone: .interval(0), length: 1.5, weight: 3, anticipates: bar.beats)] }
            if bar.firstCell {
                return [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 108, weight: 3),
                        Note(at: 1.5, tone: .interval(7), length: 1.4, velocity: 104, weight: 3, anticipates: 2),
                        Note(at: 3, tone: .interval(0), length: 1.9, velocity: 110, weight: 3, anticipates: 4)]
            }
            return [Note(at: 1.5, tone: .interval(7), length: 1.5, velocity: 104, weight: 3, anticipates: 2),
                    Note(at: 3, tone: .interval(0), length: 2.5, velocity: 110, weight: 3, anticipates: 4)]
        },
    ]

    /// The walking line and what a jazz bassist does to it.
    static let walking: [BassFigure] = [
        BassFigure(name: "Quarters", lineage: .walking,
                   source: "the walking line: a quarter a beat, the root on one, chord tones after — \(jazz)",
                   about: "a quarter note a beat, the root on one, chord tones moving by the nearest way, a chromatic step into each change") { bar, _ in
            stride(from: 0.0, to: bar.beats, by: 1).map { t in
                Note(at: t, tone: t == 0 ? .interval(0) : .chordTone, length: 0.92, velocity: t == 0 ? 106 : 98, weight: 3)
            }
        },
        BassFigure(name: "The skip", lineage: .walking,
                   source: "the eighth-note skip on four every second bar — \(jazz)",
                   about: "quarters, with beat four split into an eighth pair every second bar") { bar, _ in
            var notes = stride(from: 0.0, to: bar.beats, by: 1).map { t in
                Note(at: t, tone: t == 0 ? .interval(0) : .chordTone, length: 0.92, velocity: t == 0 ? 106 : 98, weight: 3)
            }
            if !bar.firstCell, bar.beats >= 4 {
                notes[notes.count - 1].length = 0.45
                notes.append(Note(at: bar.beats - 0.5, tone: .chordTone, length: 0.45, velocity: 94, weight: 3))
            }
            return notes
        },
        BassFigure(name: "Two-feel", lineage: .walking,
                   source: "the two-feel of an A section, half notes before the line walks — \(jazz)",
                   about: "half notes: the root on one, a chord tone on three") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: bar.beats * 0.9, velocity: 104, weight: 3)] }
            return [Note(at: 0, tone: .interval(0), length: 1.9, velocity: 104, weight: 3),
                    Note(at: 2, tone: .chordTone, length: 1.9, velocity: 98, weight: 3)]
        },
        BassFigure(name: "Enclosure", lineage: .walking,
                   source: "the chromatic enclosure of the next root, from above then below — \(jazz)",
                   about: "quarters; before a change, beats three and four enclose the new root from a half-step above and below") { bar, _ in
            var notes = stride(from: 0.0, to: bar.beats, by: 1).map { t in
                Note(at: t, tone: t == 0 ? .interval(0) : .chordTone, length: 0.92, velocity: t == 0 ? 106 : 98, weight: 3)
            }
            if bar.changeNext, bar.beats >= 4 {
                notes[2].tone = .nextRoot(1)
                notes[3].tone = .nextRoot(-1)
            }
            return notes
        },
    ]

    /// The sub under the breaks.
    static let rolling: [BassFigure] = [
        BassFigure(name: "Held sub", lineage: .rolling,
                   source: "the long sub note moving once or twice a bar — \(drumAndBass)",
                   about: "the root held, then a move to the fifth late in the bar, and an octave when busy") { bar, _ in
            var notes = [Note(at: 0, tone: .interval(0), length: bar.density < 0.35 ? bar.beats * 0.95 : bar.beats * 0.6, velocity: 112, weight: 3)]
            if bar.density >= 0.35 { notes.append(Note(at: bar.beats * 0.625, tone: .interval(7), length: bar.beats * 0.3, velocity: 104, weight: 2)) }
            if bar.density >= 0.7 { notes.append(Note(at: bar.beats * 0.875, tone: .octaveUp, length: bar.beats * 0.12, velocity: 100, weight: 1)) }
            return notes
        },
        BassFigure(name: "Seventh under the break", lineage: .rolling,
                   source: "the Reese moving to the flat seventh for the second half of the bar — \(drumAndBass)",
                   about: "the root held through the first half of the bar, the flat seventh through the second") { bar, _ in
            var notes = [Note(at: 0, tone: .interval(0), length: bar.beats * 0.58, velocity: 112, weight: 3),
                         Note(at: bar.beats * 0.625, tone: .interval(10), length: bar.beats * 0.33, velocity: 104, weight: 3)]
            if bar.density >= 0.7 { notes.append(Note(at: bar.beats * 0.875, tone: .interval(7), length: bar.beats * 0.12, velocity: 100, weight: 1)) }
            return notes
        },
        BassFigure(name: "Pulse", lineage: .rolling,
                   source: "the half-time pulse, two long roots a bar — \(drumAndBass)",
                   about: "two long roots a bar, on one and three") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: bar.beats * 0.95, velocity: 112, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 1.9, velocity: 112, weight: 3),
                         Note(at: 2, tone: .interval(0), length: 1.9, velocity: 106, weight: 3)]
            if bar.density >= 0.7 { notes[1].length = 1.4; notes.append(Note(at: 3.5, tone: .interval(7), length: 0.45, velocity: 100, weight: 1)) }
            return notes
        },
    ]

    /// King Tubby's and Augustus Pablo's riddims, the room left in.
    static let dub: [BassFigure] = [
        BassFigure(name: "Heavy riff", lineage: .dub,
                   source: "the roots riddim's bass, the root held from one and the fifth late — \(dubProfile)",
                   about: "the root struck on one and held, the fifth on the and of three and the root on four; busier, a seventh or third on the last off-beat") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: bar.beats * 0.8, velocity: 112, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 1.4, velocity: 114, weight: 3),
                         Note(at: 2.5, tone: .interval(7), length: 0.45, velocity: 100, weight: 3)]
            if bar.density > 0.35 { notes.append(Note(at: 3, tone: .interval(0), length: 0.45, velocity: 104, weight: 1)) }
            if bar.density > 0.6 { notes.append(Note(at: 3.5, tone: .interval(rng.unit() < 0.5 ? 3 : 10), length: 0.4, velocity: 96, weight: 1)) }
            if bar.density > 0.8 { notes.append(Note(at: 1.5, tone: .octaveUp, length: 0.4, velocity: 90, weight: 1)) }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Riddim answer", lineage: .dub,
                   source: "the riddim that answers its own downbeat late in the bar — \(dubProfile)",
                   about: "the root on one, then nothing until the flat seventh on the and of three answers with the root on four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: bar.beats * 0.8, velocity: 112, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.9, velocity: 114, weight: 3),
                         Note(at: 2.5, tone: .interval(10), length: 0.45, velocity: 100, weight: 3),
                         Note(at: 3, tone: .interval(0), length: 0.45, velocity: 106, weight: 3)]
            if bar.density > 0.6 { notes.append(Note(at: 3.5, tone: .interval(7), length: 0.4, velocity: 96, weight: 1)) }
            return notes
        },
        BassFigure(name: "Rest on one", lineage: .dub,
                   source: "the dub line that leaves one to the drop — \(dubProfile)",
                   about: "nothing on one; the root on two, the fifth on the and of three, the root held on four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 1, tone: .interval(0), length: 0.9, velocity: 110, weight: 3)] }
            var notes = [Note(at: 1, tone: .interval(0), length: 0.9, velocity: 110, weight: 3),
                         Note(at: 2.5, tone: .interval(7), length: 0.45, velocity: 100, weight: 3),
                         Note(at: 3, tone: .interval(0), length: 0.9, velocity: 108, weight: 3)]
            if bar.density > 0.6 { notes[2].length = 0.45; notes.append(Note(at: 3.5, tone: .interval(3), length: 0.4, velocity: 94, weight: 1)) }
            return notes
        },
    ]

    /// Fela's lines: an ostinato that comes round and interlocks with the guitars.
    static let afrobeat: [BassFigure] = [
        BassFigure(name: "Ostinato", lineage: .afrobeat,
                   source: "the one-bar ostinato under Tony Allen's kit — \(afrobeatProfile)",
                   about: "a short root on one and a ghost on its last sixteenth, the flat seventh on the and of two, the fifth on the and of three; busier, the root and third on four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.4, weight: 3), Note(at: bar.beats - 0.5, tone: .interval(7), length: 0.4, weight: 3)] }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.4, velocity: 110, weight: 3),
                         Note(at: 0.75, tone: .interval(0), length: 0.2, velocity: 86, weight: 2),
                         Note(at: 1.5, tone: .interval(10), length: 0.4, velocity: 100, weight: 3),
                         Note(at: 2.5, tone: .interval(7), length: 0.4, velocity: 104, weight: 3)]
            if bar.density > 0.4 {
                notes.append(Note(at: 3, tone: .interval(0), length: 0.2, velocity: 92, weight: 1))
                notes.append(Note(at: 3.25, tone: .interval(3), length: 0.4, velocity: 98, weight: 1))
            }
            if bar.density > 0.7 { notes.append(Note(at: 1.75, tone: .octaveUp, length: 0.2, velocity: 88, weight: 1)) }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Two-bar ostinato", lineage: .afrobeat,
                   source: "the two-bar ostinato, the second bar answering the first — \(afrobeatProfile)",
                   about: "the ostinato, then a bar that answers it with the fifth and the seventh and a root on the and of four") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0, tone: .interval(0), length: 0.4, weight: 3)] }
            if bar.firstCell {
                var notes = [Note(at: 0, tone: .interval(0), length: 0.4, velocity: 110, weight: 3),
                             Note(at: 0.75, tone: .interval(0), length: 0.2, velocity: 86, weight: 2),
                             Note(at: 1.5, tone: .interval(10), length: 0.4, velocity: 100, weight: 3),
                             Note(at: 2.5, tone: .interval(7), length: 0.4, velocity: 104, weight: 3)]
                if bar.density > 0.5 { notes.append(Note(at: 3, tone: .interval(0), length: 0.2, velocity: 92, weight: 1)) }
                return notes
            }
            var notes = [Note(at: 0, tone: .interval(0), length: 0.4, velocity: 108, weight: 3),
                         Note(at: 1.5, tone: .interval(7), length: 0.4, velocity: 100, weight: 3),
                         Note(at: 2.5, tone: .interval(10), length: 0.4, velocity: 102, weight: 3),
                         Note(at: 3.5, tone: .interval(0), length: 0.2, velocity: 96, weight: 3)]
            if bar.density > 0.5 { notes.append(Note(at: 2, tone: .interval(0), length: 0.2, velocity: 90, weight: 1)) }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Off-beat roots", lineage: .afrobeat,
                   source: "roots on the ands, the beats left to the guitars — \(afrobeatProfile)",
                   about: "short roots on the and of one and two, the flat seventh on the and of three, the fifth on the and of four; busier, a ghost on one") { bar, _ in
            guard bar.beats >= 4 else { return [Note(at: 0.5, tone: .interval(0), length: 0.4, weight: 3)] }
            var notes = [Note(at: 0.5, tone: .interval(0), length: 0.4, velocity: 106, weight: 3),
                         Note(at: 1.5, tone: .interval(0), length: 0.4, velocity: 100, weight: 3),
                         Note(at: 2.5, tone: .interval(10), length: 0.4, velocity: 102, weight: 3),
                         Note(at: 3.5, tone: .interval(7), length: 0.4, velocity: 104, weight: 3)]
            if bar.density > 0.5 { notes.insert(Note(at: 0, tone: .interval(0), length: 0.2, velocity: 80, weight: 1), at: 0) }
            return notes
        },
    ]

    /// Amapiano's log drum.
    static let logDrum: [BassFigure] = [
        BassFigure(name: "Log drum", lineage: .logDrum,
                   source: "the log drum's off-beat hits — \(amapiano)",
                   about: "short pitched hits off the beat, the root mostly and the octave for lift, the seed choosing the slots past the first two") { bar, rng in
            let pool: [Double] = [0.75, 1.5, 2.75, 3.5, 2.25, 0.25, 3.0, 1.0].filter { $0 < bar.beats }
            let count = max(2, Int((3 + bar.density * 4).rounded()))
            let slots = Array(pool.prefix(2)) + Array(pool.dropFirst(2)).shuffled(using: &rng)
            return slots.prefix(count).map { t in
                Note(at: t, tone: rng.unit() < 0.3 ? .octaveUp : .interval(0), length: 0.22, velocity: 100 + Int(rng.unit() * 12), weight: 2)
            }.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Call and answer", lineage: .logDrum,
                   source: "the two-bar log-drum phrase, the second bar answering — \(amapiano)",
                   about: "a bar of hits on the e of one, the and of two and the a of three, answered by a bar that ends on the octave") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 0.75, tone: .interval(0), length: 0.22, weight: 3)] }
            var notes: [Note]
            if bar.firstCell {
                notes = [0.75, 1.5, 2.75].map { Note(at: $0, tone: .interval(0), length: 0.22, velocity: 100 + Int(rng.unit() * 12), weight: 3) }
                if bar.density > 0.6 { notes.append(Note(at: 3.5, tone: .interval(0), length: 0.22, velocity: 98, weight: 1)) }
            } else {
                notes = [Note(at: 0.75, tone: .interval(0), length: 0.22, velocity: 104, weight: 3),
                         Note(at: 2.25, tone: .interval(0), length: 0.22, velocity: 100, weight: 3),
                         Note(at: 3.5, tone: .octaveUp, length: 0.22, velocity: 108, weight: 3)]
                if bar.density > 0.6 { notes.append(Note(at: 1.5, tone: .interval(0), length: 0.22, velocity: 96, weight: 1)) }
            }
            return notes.sorted { $0.at < $1.at }
        },
        BassFigure(name: "Sparse log", lineage: .logDrum,
                   source: "the log drum that leaves the bar mostly empty — \(amapiano)",
                   about: "hits on the and of two and the and of four only; busier, the octave on the a of three") { bar, rng in
            guard bar.beats >= 4 else { return [Note(at: 1.5, tone: .interval(0), length: 0.22, weight: 3)] }
            var notes = [Note(at: 1.5, tone: .interval(0), length: 0.22, velocity: 100 + Int(rng.unit() * 10), weight: 3),
                         Note(at: 3.5, tone: .interval(0), length: 0.22, velocity: 100 + Int(rng.unit() * 10), weight: 3)]
            if bar.density > 0.5 { notes.insert(Note(at: 2.75, tone: .octaveUp, length: 0.22, velocity: 104, weight: 1), at: 1) }
            return notes
        },
    ]

    /// A drone under the harmony.
    static let pedal: [BassFigure] = [
        BassFigure(name: "Pedal", lineage: .pedal,
                   source: "the pedal point, the bottom held still while the harmony moves — \(score)",
                   about: "one long root a chord, held across the bars it lasts") { bar, _ in
            let starts = [0.0] + bar.changes
            return starts.enumerated().map { index, at in
                let end = index + 1 < starts.count ? starts[index + 1] : bar.beats
                return Note(at: at, tone: .interval(0), length: end - at, velocity: 84, weight: 3)
            }
        },
        BassFigure(name: "Breathing pedal", lineage: .pedal,
                   source: "the drone re-struck each bar — \(score)",
                   about: "the root of each chord struck again on every bar's one, let go just before the next") { bar, _ in
            let starts = [0.0] + bar.changes
            return starts.enumerated().map { index, at in
                let end = index + 1 < starts.count ? starts[index + 1] : bar.beats
                return Note(at: at, tone: .interval(0), length: max(0.5, end - at - 0.2), velocity: 86, weight: 3)
            }
        },
    ]

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

    /// A chord tone as semitones above the chord's bass note. In root position that is the tone's
    /// own interval. Over an inversion the bass is not the root — a fifth counted up from the F
    /// sharp of D/F♯ is C sharp, which is no note of D major — so the tone is found from the root
    /// and set above the bass (below it, for the fifth below). The bass's own octave stays its own.
    static func tone(of chord: Chord, _ interval: Int) -> Int {
        let tone = chordTone(chord, interval)
        let offset = bassOffset(chord)
        guard offset != 0, interval % 12 != 0 else { return tone }
        let up = ((tone - offset) % 12 + 12) % 12
        if interval < 0 { return up == 0 ? -12 : up - 12 }
        return up == 0 ? 12 : up
    }

    /// Semitones from a chord's root up to its bass note: 0 in root position, 4 for D/F♯.
    static func bassOffset(_ chord: Chord) -> Int {
        let stack = chord.intervals
        return stack.isEmpty ? 0 : stack[min(max(0, chord.inversion), stack.count - 1)] % 12
    }

    /// So many scale steps from a pitch, along the key's scale: up when positive, down when
    /// negative. A pitch the scale does not hold walks by semitones instead.
    static func scaleStep(from pitch: Int, by steps: Int, in key: Key) -> Int {
        let classes = key.pitchClasses.map(\.rawValue)
        let pc = ((pitch % 12) + 12) % 12
        guard classes.count > 1, var index = classes.firstIndex(of: pc) else { return pitch + steps }
        var out = pitch
        if steps > 0 {
            for _ in 0..<steps {
                let next = (index + 1) % classes.count
                out += ((classes[next] - classes[index]) % 12 + 12) % 12
                index = next
            }
        } else {
            for _ in 0..<(-steps) {
                let next = (index - 1 + classes.count) % classes.count
                out -= ((classes[index] - classes[next]) % 12 + 12) % 12
                index = next
            }
        }
        return out
    }

    /// The last note before each change becomes a half-step into the new root — unless the figure
    /// put a step of its own there.
    static func approachChanges(_ drafts: [Draft], harmony: HarmonyMap, lineage: BassLineage, beatsPerBar: Double,
                                protected: [Double] = []) -> [Draft] {
        var out = drafts
        for change in harmony.changes where change > 0 {
            let before = out.indices.filter { out[$0].start >= change - 1 - 1e-6 && out[$0].start < change - 1e-6 }
            guard let i = before.max(by: { out[$0].start < out[$1].start }) else { continue }
            guard !protected.contains(where: { abs($0 - out[i].start) < 1e-6 }) else { continue }
            let target = BassWriter.place(harmony.chord(at: change).bass, near: out[i].pitch, in: lineage)
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
