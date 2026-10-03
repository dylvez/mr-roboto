import Analysis
import Foundation
import SongGraph

/// Tightening: a record stretched bar by bar onto the song's bars, rather than by one ratio for all.
///
/// One ratio keeps a record at its average tempo. A record played by people drifts — a verse
/// pushes, a bridge drags — and a programmed kit under it does not, so the two part a little more
/// each bar: in the user's own mashup the beat "doesn't seem to match the rest of the song" a
/// minute in. Tightened, each of the record's bars is pinned to one of the song's, and the beat
/// meets every bar line.
///
/// It can only be as right as the record's bar lines. A beat tracker that misplaces one bar line
/// would have that bar sped up and the next slowed down — a lurch where the record had none — so
/// a bar line far from where its neighbours put it is put back first, and no bar is stretched more
/// than 8% past the record's overall ratio; a bar held there catches up over the bars after it.
public enum TightenMap {
    /// How far one bar's stretch may stray from the overall ratio.
    public static let limit = 0.08
    /// Past this share of its bars held to `limit`, a record's bar lines look misread rather than
    /// played, and it is not tightened unasked. The beat trackers' agreement was the first gate
    /// tried: it turned tightening off for every old record in the library, the two whose bar
    /// lines tightened cleanly with it.
    public static let mostHeld = 0.10
    /// A bar line this far from where its neighbours put it, and standing out from them, was misread.
    public static let misread = 0.04
    /// At most this share of a record's bar lines are put back: past it, the grid is not misread
    /// here and there, it is wrong, and correcting it is the grid's job (phase 5), not this one's.
    public static let mostMisread = 0.25
    /// How far past both its neighbours' errors a misread line's own error stands.
    static let standsOut = 1.3

    /// The record's bars with its misread bar lines put back.
    ///
    /// Every bar line is checked against the four around it, two either side: the curve through
    /// those four says where it should be. A bar line 40 ms or more from there, and further from
    /// its curve than either neighbour is from theirs, was misread — the tracker heard a late
    /// snare as the one, say — and is put on the curve. The worst is put back first, since its
    /// neighbours look wrong only because of it. Every other bar line stays exactly where it was,
    /// so a record that really pushes and drags is followed bar for bar.
    ///
    /// Smoothing every bar line against its neighbours was tried first. Narrow enough to follow a
    /// record that swings 5% over a dozen bars, it left a line misread by 100 ms where it was;
    /// wide enough to put that back, it bent the swing by 50 to 130 ms.
    public static func smoothed(_ bars: [SongGraph.TimeRange]) -> [SongGraph.TimeRange] {
        guard bars.count >= 5, let last = bars.last else { return bars }
        var lines = bars.map(\.start) + [last.end]
        func predicted(_ index: Int) -> Double {
            (-lines[index - 2] + 4 * lines[index - 1] + 4 * lines[index + 1] - lines[index + 2]) / 6
        }
        let checked = Array(2..<(lines.count - 2))
        var corrected = Set<Int>()
        // A misread line stands out from its neighbours' curve more than either neighbour does
        // from theirs — they are pulled two thirds as far by it — while a record that really
        // pushes or drags moves every line's error together.
        for _ in 0..<(2 * lines.count) {
            let errors = Dictionary(uniqueKeysWithValues: checked.map { ($0, abs(lines[$0] - predicted($0))) })
            let worst = checked.filter { index in
                let error = errors[index]!
                let beside = max(errors[index - 1] ?? 0, errors[index + 1] ?? 0)
                return error > misread && error >= standsOut * beside
            }.max { errors[$0]! < errors[$1]! }
            guard let worst, corrected.count < Int(Double(lines.count) * mostMisread) || corrected.contains(worst) else { break }
            lines[worst] = predicted(worst)
            corrected.insert(worst)
        }
        return zip(lines, lines.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }
    }

    /// Where a moment of the region should land: its source second and its output second, both
    /// from the start of what is rendered.
    public struct Pin: Hashable, Sendable {
        public var source: Double
        public var output: Double

        public init(source: Double, output: Double) {
            self.source = source
            self.output = output
        }
    }

    /// The anchors that put each pin where it should land, from (0, 0), with no stretch further
    /// than `limit` from `ratio`; and how many bars were held to that.
    public static func anchors(_ pins: [Pin], ratio: Double) -> (anchors: [StretchAnchor], held: Int) {
        var anchors: [StretchAnchor] = []
        var source = 0.0, output = 0.0, held = 0
        for pin in pins.sorted(by: { $0.source < $1.source }) where pin.source > source + 1e-6 {
            let span = pin.source - source
            let wanted = (pin.output - output) / span
            let stretch = min(ratio * (1 + limit), max(ratio * (1 - limit), wanted))
            if abs(stretch - wanted) > 1e-9 { held += 1 }
            output += stretch * span
            source = pin.source
            anchors.append(StretchAnchor(input: source, output: output))
        }
        return (anchors, held)
    }
}
