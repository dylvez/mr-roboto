import Analysis
import Foundation
import MusicTheory
import SongGraph

// Sources: a stem, or a few bars, of another record pulled into the open song.
//
// A mashup meets two records halfway — one is the backbone, the other is moved — and makes a third
// song. A source has no halfway: the open song is the fixed side, its key, tempo and bar grid stand,
// and the record is moved onto them. The rules are the merge's (`Merge.move`: K1, K2, T1, F1, and the
// drums are never pitch-shifted), so a source and a mashup of the same two records move them the
// same way. Pure arithmetic, like `Mashup`: rendering the move is `MergeRender`'s, recording it is
// the app's.

/// One record's stem as the fit needs to know it.
public struct SourceMaterial: Hashable, Sendable {
    /// "Vocals of russianfreedom": what the move and its sentences call it.
    public var label: String
    public var key: Key?
    public var tempo: Double?
    /// The record's bars in its own seconds, as its analysis found them.
    public var bars: [SongGraph.TimeRange]
    /// The file's length in seconds.
    public var duration: Double
    /// The drums stem: stretched, never shifted.
    public var isDrums: Bool
    /// Cents the record sits above concert pitch (`Tuning`), when it has been measured. The fit
    /// takes them off, so every record in a song is at the pitch the band plays at.
    public var tuning: Double?

    public init(label: String, key: Key? = nil, tempo: Double? = nil, bars: [SongGraph.TimeRange] = [], duration: Double, isDrums: Bool = false,
                tuning: Double? = nil) {
        self.label = label
        self.key = key
        self.tempo = tempo
        self.bars = bars
        self.duration = duration
        self.isDrums = isDrums
        self.tuning = tuning
    }

    /// The second its first bar starts on: bar 1, which the song's bar grid is met on.
    public var firstDownbeat: Double { bars.first?.start ?? 0 }
}

/// What is taken from the record.
public enum SourceShape: Hashable, Sendable {
    /// The whole stem, running along the song: its first bar on song bar `atBar` (0-based). Below
    /// zero, it was already under way when the song began.
    case whole(atBar: Int)
    /// Bars `from` up to `to` of the record (0-based, `to` not included), fitted to whole bars of
    /// the song and looped in each section that plays them, like a chop.
    case clip(from: Int, to: Int)
}

/// How the record is moved onto the song.
public struct SourcePlan: Hashable, Sendable {
    public var shape: SourceShape
    /// Pitch and stretch. A clip's ratio fits it to whole bars exactly, not to the tempo the record
    /// was read at, so its loop never drifts against the song's.
    public var move: MergeMove
    /// The seconds of the record that are read and moved.
    public var region: SongGraph.TimeRange
    /// Transport seconds at which the moved region's first frame sounds: where a whole stem is laid.
    /// A clip has none of its own; it starts with each section that plays it.
    public var offset: Double
    /// Song bars the moved audio fills: a clip's length, or how far into the song a whole stem runs.
    public var bars: Int
    /// Seconds of the record's head left out, because they would sound before the song starts.
    public var cut: Double
    public var secondsPerBar: Double
    public var sentences: [String]
    public var flags: [String]
    /// Tightened: the region's moments pinned to the song's (`TightenMap`), in seconds from the
    /// region's start and from the render's. Nil is one ratio for all of it, `move.ratio`.
    public var anchors: [StretchAnchor]? = nil
    /// Bars held to `TightenMap.limit` rather than pinned exactly.
    public var held = 0

    public var isClip: Bool { if case .clip = shape { return true } else { return false } }
    public var isTightened: Bool { anchors != nil }
    /// The bar lines pinned, when tightened.
    public var pinned: Int { anchors?.count ?? 0 }
    /// Whether so many of its bars were held that its bar lines look misread (`TightenMap.mostHeld`).
    public var looksMisread: Bool { isTightened && Double(held) > Double(pinned) * TightenMap.mostHeld }

    /// Where a second of the region lands in the render, along the anchors or at the one ratio.
    public func output(atSource seconds: Double) -> Double {
        guard let anchors, !anchors.isEmpty else { return seconds * move.ratio }
        var previous = StretchAnchor(input: 0, output: 0)
        for anchor in anchors {
            if seconds <= anchor.input || anchor == anchors.last! {
                let slope = (anchor.output - previous.output) / max(1e-9, anchor.input - previous.input)
                return previous.output + (seconds - previous.input) * slope
            }
            previous = anchor
        }
        return seconds * move.ratio
    }

    /// The second of the region that lands at a second of the render.
    public func source(atOutput seconds: Double) -> Double {
        guard let anchors, !anchors.isEmpty else { return seconds / move.ratio }
        var previous = StretchAnchor(input: 0, output: 0)
        for anchor in anchors {
            if seconds <= anchor.output || anchor == anchors.last! {
                let slope = (anchor.input - previous.input) / max(1e-9, anchor.output - previous.output)
                return previous.input + (seconds - previous.output) * slope
            }
            previous = anchor
        }
        return seconds / move.ratio
    }

    /// The anchors for the stretch of the region from `from` to `to` (its own seconds), rebased
    /// to start there: what a preview of a few bars renders with.
    public func anchors(from: Double, to: Double) -> [StretchAnchor]? {
        guard let anchors else { return nil }
        let base = output(atSource: from)
        var out = anchors.filter { $0.input > from + 1e-6 && $0.input < to - 1e-6 }
            .map { StretchAnchor(input: $0.input - from, output: $0.output - base) }
        out.append(StretchAnchor(input: to - from, output: output(atSource: to) - base))
        return out
    }
}

public enum SourceFitting {

    /// A clip whose bars run this much longer or shorter than its tempo says is flagged: the record
    /// pushes or drags there, or the bar lines are off.
    public static let unevenBars = 0.03

    /// A record within this many cents of concert pitch is left where it is: nobody hears five
    /// cents, and the reading is no finer than that.
    public static let leastCents = 5.0

    /// The cents that bring a source to concert pitch, and the sentence that says so. Nothing for
    /// drums, a record never measured, or one already at pitch.
    static func concertPitch(_ source: SourceMaterial) -> (cents: Double, sentence: String)? {
        guard !source.isDrums, let tuning = source.tuning, abs(tuning) >= leastCents else { return nil }
        let cents = -tuning
        return (cents, String(format: "%@ %.0f cents to concert pitch: the record sits that far %@.",
                              cents > 0 ? "Up" : "Down", abs(cents), cents > 0 ? "flat" : "sharp"))
    }

    /// - Parameters:
    ///   - target: the song's key and tempo. A song with no key leaves the pitch alone.
    ///   - semitones: an override of the key arithmetic, by ear.
    ///   - tighten: each of the record's bars pinned to one of the song's (`TightenMap`), rather
    ///     than one ratio for all of it.
    public static func plan(_ source: SourceMaterial, into target: MergeTarget, beatsPerBar: Int = 4,
                            shape: SourceShape, semitones: Int? = nil, tighten: Bool = false) -> SourcePlan {
        // Tightened, every bar line is read where the smoothing put it: the region, bar 1 and the
        // pins all agree.
        var source = source
        let tightens = tighten && source.bars.count >= 2
        if tightens { source.bars = TightenMap.smoothed(source.bars) }
        var move = Merge.move(MergeFragment(label: source.label, kind: .sample, key: source.key, tempo: source.tempo,
                                            isDrums: source.isDrums),
                              to: target, semitones: source.isDrums ? 0 : semitones)
        if source.isDrums {
            move.semitones = 0
            move.key = source.key
            move.preservesFormants = false
            move.flags = []
        }
        let tempo = target.tempo ?? source.tempo ?? 120
        let secondsPerBar = Double(max(1, beatsPerBar)) * 60 / max(1, tempo)
        var flags = move.flags
        var sentences: [String] = []
        let tuned = concertPitch(source)
        move.cents = tuned?.cents ?? 0

        switch shape {
        case .whole(let atBar):
            // Bar 1 of the record on bar `atBar` of the song; a moment `s` of the record sounds at
            // `atBar` bars plus `(s − bar 1) × ratio`. What would sound before the song starts is not read.
            let downbeat = source.firstDownbeat
            let start = max(0, downbeat - Double(atBar) * secondsPerBar / move.ratio)
            let offset = max(0, Double(atBar) * secondsPerBar + (start - downbeat) * move.ratio)
            let end = offset + max(0, source.duration - start) * move.ratio
            let cut = start
            move.sentence = Merge.sentence(for: fragment(source), move: move, target: MergeTarget(key: target.key, tempo: tempo))
            sentences.append(move.sentence)
            if let tuned { sentences.append(tuned.sentence) }
            sentences.append(atBar >= 0 ? "Its bar 1 on bar \(atBar + 1) of the song."
                                        : "Already \(-atBar) bar\(atBar == -1 ? "" : "s") in when the song starts.")
            if cut > 0.05 {
                sentences.append(String(format: "The first %.1f s are left out: they would sound before the song starts.", cut))
            }
            var plan = SourcePlan(shape: shape, move: move, region: SongGraph.TimeRange(start: start, end: source.duration),
                                  offset: offset, bars: max(1, Int(ceil(end / secondsPerBar - 1e-9))), cut: cut,
                                  secondsPerBar: secondsPerBar, sentences: sentences, flags: flags)
            if tightens {
                // Bar line k of the record on the song's bar `atBar` + k (two of its bars to one
                // of the song's when its tempo was halved to meet it, and so on).
                let lines = source.bars.map(\.start) + [source.bars.last!.end]
                let pins = lines.enumerated().compactMap { index, line -> TightenMap.Pin? in
                    let output = (Double(atBar) + Double(index) * move.tempoFactor) * secondsPerBar - offset
                    guard line > start + 1e-6, line < source.duration, output > 0 else { return nil }
                    return TightenMap.Pin(source: line - start, output: output)
                }
                pin(&plan, pins: pins, label: source.label)
            }
            return plan

        case .clip(let from, let to):
            let sourceBar = source.tempo.map { Double(max(1, beatsPerBar)) * 60 / max(1, $0) } ?? secondsPerBar / move.ratio
            let region = clipRegion(of: source, from: from, to: to, secondsPerBar: sourceBar)
            let count = max(1, to - from)
            // As many of the song's bars as the clip comes to at the stretch the tempo asks for —
            // doubled or halved first, by T1 — then that many exactly.
            let plain = region.duration * move.ratio / secondsPerBar
            let bars = max(1, Int(plain.rounded()))
            let exact = region.duration > 0 ? Double(bars) * secondsPerBar / region.duration : move.ratio
            if abs(exact / move.ratio - 1) > unevenBars, source.tempo != nil {
                flags.append(String(format: "Bars %d–%d of %@ run %.0f%% %@ than its tempo says; they are fitted to %d bar%@ all the same.",
                                    from + 1, from + count, source.label, abs(exact / move.ratio - 1) * 100,
                                    exact < move.ratio ? "longer" : "shorter", bars, bars == 1 ? "" : "s"))
            }
            move.ratio = exact
            move.tempo = tempo
            move.sentence = Merge.sentence(for: fragment(source), move: move, target: MergeTarget(key: target.key, tempo: tempo))
            let span = count == 1 ? "Bar \(from + 1)" : "Bars \(from + 1)–\(from + count)"
            sentences.append("\(span) of \(source.label), fitted to \(bars) bar\(bars == 1 ? "" : "s") of the song.")
            sentences.append(move.sentence)
            if let tuned { sentences.append(tuned.sentence) }
            sentences.append("Loops in each section that plays it.")
            var plan = SourcePlan(shape: shape, move: move, region: region, offset: 0, bars: bars, cut: region.start,
                                  secondsPerBar: secondsPerBar, sentences: sentences, flags: flags)
            if tightens {
                // Each of its bars an equal share of the song's bars it fills, its end on theirs.
                let share = Double(bars) * secondsPerBar / Double(count)
                var pins = (1..<count).map { step in
                    TightenMap.Pin(source: clipRegion(of: source, from: from + step, to: from + step + 1, secondsPerBar: sourceBar).start - region.start,
                                   output: Double(step) * share)
                }
                pins.append(TightenMap.Pin(source: region.duration, output: Double(bars) * secondsPerBar))
                pin(&plan, pins: pins, label: source.label)
            }
            return plan
        }
    }

    /// The plan's anchors from its pins, and what it says about them.
    private static func pin(_ plan: inout SourcePlan, pins: [TightenMap.Pin], label: String) {
        guard !pins.isEmpty else { return }
        let (anchors, held) = TightenMap.anchors(pins, ratio: plan.move.ratio)
        plan.anchors = anchors
        plan.held = held
        plan.sentences.append("Tightened: each of its bars stretched onto one of the song's, so it keeps time with what is programmed under it.")
        if held > 0 {
            plan.flags.append("\(held) of \(label)'s \(pins.count) bars are more than \(Int(TightenMap.limit * 100))% off its overall stretch; "
                              + "each is held to that, and the bars after it catch up.")
        }
    }

    /// The seconds bars `from`..<`to` cover: the analysed bars where the record has them, else bars
    /// of `secondsPerBar` from its first downbeat.
    static func clipRegion(of source: SourceMaterial, from: Int, to: Int, secondsPerBar: Double) -> SongGraph.TimeRange {
        let lower = max(0, from), upper = max(lower + 1, to)
        let bars = source.bars
        func start(of bar: Int) -> Double {
            if bar < bars.count { return bars[bar].start }
            let last = bars.last.map { ($0.end, bars.count) } ?? (source.firstDownbeat, 0)
            return last.0 + Double(bar - last.1) * secondsPerBar
        }
        let begin = min(source.duration, start(of: lower))
        let finish = min(source.duration, upper - 1 < bars.count ? bars[upper - 1].end : start(of: upper))
        return SongGraph.TimeRange(start: begin, end: max(begin, finish))
    }

    private static func fragment(_ source: SourceMaterial) -> MergeFragment {
        MergeFragment(label: source.label, kind: .sample, key: source.key, tempo: source.tempo, isDrums: source.isDrums)
    }

    /// The gain that brings one record to another's loudness: `target − measured`, held within
    /// ±`limit` dB. Nil when either is unknown. One gain for every stem of a record, so its stems
    /// keep the balance they were separated with.
    public static func level(record measured: Double?, toward target: Double?, limit: Double = 12) -> Double? {
        guard let measured, let target, measured.isFinite, target.isFinite else { return nil }
        let gain = max(-limit, min(limit, target - measured))
        return (gain * 10).rounded() / 10
    }
}
