import Foundation
import MusicTheory
import Performance
import SongGraph

/// How well something on the shelves goes with the open song: what bringing it in would do to it,
/// worked out by the arithmetic Sources and a merge use, said in the sentences they say it in, and
/// a cost to rank by. No audio is touched: it reads keys, tempos and tunings.
public struct LibraryFit: Hashable, Sendable {
    /// How far it has to go, from as it is to farther than the Sampler takes a sample.
    public enum Verdict: Int, Comparable, Sendable {
        /// Nothing moves.
        case asIs
        /// A semitone or two, a stretch of a few percent: it sits in.
        case near
        /// Moved, within what a sample bears.
        case moves
        /// Past four semitones — the timbre will tell (the Sampler's flag) — or stretched further
        /// than a merge stretches before it doubles or halves (`Merge.stretchLimit`).
        case far
        /// Past seven: the Sampler will not call it the same recording.
        case refused
        /// Nothing to go on: no key and no tempo.
        case unknown

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Semitones it is moved, by the key arithmetic: 0 for its key, its relative, a groove, or no key.
    public var semitones: Int
    /// 1, or 2 and ½ when its tempo is doubled or halved first.
    public var tempoFactor: Double
    /// The stretch after that: output over input, 1 untouched.
    public var ratio: Double
    /// Cents it is moved to concert pitch.
    public var cents: Double
    /// What is done to it, as Sources says it.
    public var sentences: [String]
    /// What to listen for: past four semitones, bars that run uneven.
    public var flags: [String]
    public var verdict: Verdict
    /// Lower is nearer: semitones moved, a step for doubling or halving, a semitone for every three
    /// percent of stretch.
    public var cost: Double

    /// "as it is", "−2 st", "+3 st, ½×", "×1.04": what the list's Fit column says.
    public var short: String {
        var pieces: [String] = []
        if semitones != 0 { pieces.append("\(semitones > 0 ? "+" : "−")\(abs(semitones)) st") }
        if tempoFactor > 1 { pieces.append("2×") } else if tempoFactor < 1 { pieces.append("½×") }
        if abs(ratio - 1) >= 0.005 { pieces.append(String(format: "×%.2f", ratio)) }
        if verdict == .unknown { return "" }
        return pieces.isEmpty ? "as it is" : pieces.joined(separator: ", ")
    }
}

/// What a fit is measured against: the open song's key, tempo and meter.
public struct FitTarget: Hashable, Sendable {
    public var title: String
    public var key: Key?
    public var tempo: Double
    public var beatsPerBar: Int

    public init(_ song: Song) {
        title = song.title
        key = song.key
        tempo = song.tempo
        beatsPerBar = song.timeSignature.beatsPerBar
    }

    /// What a song fits things to: nothing while it is blank, because Sources gives a blank song
    /// the first record's key and tempo, and everything goes with it as it is.
    static func of(_ song: Song?) -> FitTarget? {
        guard let song, !song.isBlank else { return nil }
        return FitTarget(song)
    }

    var merge: MergeTarget { MergeTarget(key: key, tempo: tempo) }
}

enum LibraryFitting {

    /// A record, whole, laid along the song from its first bar: what Sources plans for it, its
    /// sentence and the concert-pitch one included. Nil for a record not read yet.
    static func fit(_ record: Record, into target: FitTarget) -> LibraryFit? {
        guard let (material, _, _) = Sources.material(of: record, stem: Mashups.full) else { return nil }
        let plan = SourceFitting.plan(material, into: target.merge, beatsPerBar: target.beatsPerBar, shape: .whole(atBar: 0))
        // The move and the tuning; where its first bar lands is not about whether it fits.
        let sentences = plan.sentences.filter { !$0.hasPrefix("Its bar 1") && !$0.hasPrefix("Already ") && !$0.hasPrefix("The first ") }
        return made(plan.move, sentences: sentences, flags: plan.flags, known: material.key != nil || material.tempo != nil)
    }

    /// A sample on the shelf, moved as a merge moves audio: pitch and stretch.
    static func fit(_ entry: LibrarySample, into target: FitTarget) -> LibraryFit? {
        let fragment = MergeFragment(label: entry.name, kind: .sample, key: entry.sample.key, tempo: entry.sample.detectedTempo)
        let move = Merge.move(fragment, to: target.merge)
        return made(move, sentences: [move.sentence], flags: move.flags, known: fragment.key != nil || fragment.tempo != nil)
    }

    /// An idea: a written part moves by arithmetic and costs nothing to move, a groove has no key,
    /// a chop moves as audio. Audio with no reading has nothing to go on.
    static func fit(_ idea: PartVersion, into target: FitTarget) -> LibraryFit? {
        let label = PartLabel.title(of: idea)
        let fragment: MergeFragment
        switch idea.kind {
        case .progression(let progression): fragment = MergeFragment(label: label, kind: .written, key: progression.key)
        case .bassline(let line): fragment = MergeFragment(label: label, kind: .written, key: line.key)
        case .melody: fragment = MergeFragment(label: label, kind: .written)
        case .groove: fragment = MergeFragment(label: label, kind: .groove)
        case .sample(let sample): fragment = MergeFragment(label: label, kind: .sample, key: sample.key, tempo: sample.detectedTempo)
        case .audio, .lyric, .sound, .analysis, .mix: return nil
        }
        let move = Merge.move(fragment, to: target.merge)
        var fit = made(move, sentences: [move.sentence], flags: move.flags, known: true)
        // Arithmetic, not a pitch shift: a written part in any key sits in at no cost to its sound.
        if fragment.kind != .sample {
            fit.cost = 0
            fit.verdict = move.semitones == 0 ? .asIs : .near
        }
        return fit
    }

    private static func made(_ move: MergeMove, sentences: [String], flags: [String], known: Bool) -> LibraryFit {
        let stretch = abs(move.ratio - 1)
        let distance = abs(move.semitones)
        let verdict: LibraryFit.Verdict
        if !known {
            verdict = .unknown
        } else if distance > Sampler.transposeCeilingSemitones {
            verdict = .refused
        } else if Double(distance) > Sampler.transposeFlagSemitones || stretch > Merge.stretchLimit + 1e-9 {
            verdict = .far
        } else if distance == 0, stretch < 0.005, move.tempoFactor == 1 {
            verdict = .asIs
        } else if distance <= 2, stretch <= 0.06 {
            verdict = .near
        } else {
            verdict = .moves
        }
        var cost = Double(distance) + (move.tempoFactor == 1 ? 0 : 0.5) + stretch * 100 / 3
        if verdict == .unknown { cost = .infinity }
        if verdict == .refused { cost += 100 }
        return LibraryFit(semitones: move.semitones, tempoFactor: move.tempoFactor, ratio: move.ratio, cents: move.cents,
                          sentences: sentences, flags: flags, verdict: verdict, cost: cost)
    }
}
