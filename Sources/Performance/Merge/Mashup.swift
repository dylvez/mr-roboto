import Foundation
import MusicTheory
import SongGraph

// Mashup: two whole records brought to one key and tempo and lined up bar to bar.
//
// A merge moves two fragments into a section. A mashup keeps one record as the backbone — its
// tempo and key stand, because an instrumental takes a stretch worse than a voice does — and
// moves the other onto its grid: the first downbeat of each lands on a bar line, and a bar shift
// says which of the backbone's bars the other's first bar meets.

/// One record, as the plan needs to know it.
public struct MashupSource: Hashable, Sendable {
    public var label: String
    public var key: Key?
    public var tempo: Double?
    /// Seconds into the file of its first downbeat: where bar 0 starts.
    public var firstDownbeat: Double
    /// The file's length in seconds.
    public var duration: Double

    public init(label: String, key: Key? = nil, tempo: Double? = nil, firstDownbeat: Double = 0, duration: Double) {
        self.label = label
        self.key = key
        self.tempo = tempo
        self.firstDownbeat = max(0, firstDownbeat)
        self.duration = duration
    }
}

/// How the two records meet.
public struct MashupPlan: Hashable, Sendable {
    public enum Side: String, Hashable, Sendable, CaseIterable { case a, b }

    public var target: MergeTarget
    public var backbone: Side
    /// How each record's tonal stems move. Drums take `drumMove(_:)`: stretched, never shifted.
    public var a: MergeMove
    public var b: MergeMove
    /// Transport seconds at which each record's first frame sounds, never negative.
    public var offsetA: Double
    public var offsetB: Double
    /// Whole bars of lead-in put before the backbone so nothing starts before zero.
    public var leadBars: Int
    /// The bar of the backbone the other record's first bar meets.
    public var barShift: Int
    public var lengthInBars: Int
    public var beatsPerBar: Int

    public func move(_ side: Side) -> MergeMove { side == .a ? a : b }
    public func offset(_ side: Side) -> Double { side == .a ? offsetA : offsetB }

    /// The move for a side's drums: the same stretch, the transients kept, the pitch left alone.
    public func drumMove(_ side: Side) -> MergeMove {
        var move = self.move(side)
        move.semitones = 0
        move.preservesFormants = false
        move.keepsTransients = true
        return move
    }

    public var secondsPerBar: Double { Double(beatsPerBar) * 60 / (target.tempo ?? 120) }

    /// The plan in sentences, the way the surface and the Director say it.
    public var sentences: [String] {
        let other: Side = backbone == .a ? .b : .a
        var out = [a.sentence, b.sentence]
        // In the backbone's bars, and — with a lead-in before them — in the mashup's, which is what
        // the preview and the new song count.
        var meets = barShift == 0 ? "bar 1 meets bar 1" : "its bar 1 meets bar \(barShift + 1) of \(move(backbone).label)"
        if leadBars > 0, barShift > 0 { meets += " (bar \(barShift + leadBars + 1) of the mashup)" }
        out.append("\(move(other).label) rides \(move(backbone).label)'s grid: \(meets).")
        if leadBars > 0 { out.append("\(leadBars) bar\(leadBars == 1 ? "" : "s") of lead-in, so the pickup before the first downbeat is kept.") }
        return out
    }

    public var flags: [String] { a.flags + b.flags }
}

public enum Mashup {

    /// - Parameters:
    ///   - backbone: whose tempo and key stand unless `target` says otherwise.
    ///   - barShift: the backbone bar the other record's first bar meets; negative starts the
    ///     other record first.
    ///   - semitonesA/B: an override of the key arithmetic, for a relative-key choice by ear.
    public static func plan(a: MashupSource, b: MashupSource, backbone: MashupPlan.Side = .a, barShift: Int = 0,
                            target: MergeTarget = MergeTarget(), semitonesA: Int? = nil, semitonesB: Int? = nil,
                            beatsPerBar: Int = 4) -> MashupPlan {
        let spine = backbone == .a ? a : b
        let other = backbone == .a ? b : a
        // A nudge of the backbone moves the key both sides meet in, so the other side follows it:
        // it used to stay in the backbone's key from before the nudge, a whole tone off.
        var key = target.key ?? spine.key ?? other.key
        if target.key == nil, let nudge = backbone == .a ? semitonesA : semitonesB, let from = spine.key {
            key = from.transposed(by: nudge)
        }
        let settled = MergeTarget(key: key, tempo: target.tempo ?? spine.tempo ?? other.tempo)
        let moveA = Merge.move(MergeFragment(label: a.label, kind: .sample, key: a.key, tempo: a.tempo), to: settled, semitones: semitonesA)
        let moveB = Merge.move(MergeFragment(label: b.label, kind: .sample, key: b.key, tempo: b.tempo), to: settled, semitones: semitonesB)

        let secondsPerBar = Double(beatsPerBar) * 60 / (settled.tempo ?? 120)
        // Each file's first downbeat, after its stretch, sits on a bar line: the backbone's on bar
        // 0, the other's on `barShift`.
        var offsetA = (backbone == .a ? 0 : Double(barShift) * secondsPerBar) - a.firstDownbeat * moveA.ratio
        var offsetB = (backbone == .b ? 0 : Double(barShift) * secondsPerBar) - b.firstDownbeat * moveB.ratio
        let earliest = min(offsetA, offsetB)
        let leadBars = earliest < -1e-9 ? Int(ceil(-earliest / secondsPerBar - 1e-9)) : 0
        offsetA += Double(leadBars) * secondsPerBar
        offsetB += Double(leadBars) * secondsPerBar
        let end = max(offsetA + a.duration * moveA.ratio, offsetB + b.duration * moveB.ratio)
        return MashupPlan(target: settled, backbone: backbone, a: moveA, b: moveB, offsetA: max(0, offsetA), offsetB: max(0, offsetB),
                          leadBars: leadBars, barShift: barShift, lengthInBars: max(1, Int(ceil(end / secondsPerBar - 1e-9))), beatsPerBar: beatsPerBar)
    }

    /// Where a moment of a record lands on the mashup's transport, in bars from zero.
    public static func bar(of seconds: Double, in side: MashupPlan.Side, plan: MashupPlan) -> Double {
        (plan.offset(side) + seconds * plan.move(side).ratio) / plan.secondsPerBar
    }
}
