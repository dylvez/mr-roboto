import SongGraph

/// What a drummer plays at a section's edges: a fill in its last bar that leads into the next
/// section, and a crash on the first beat of the section after it.
///
/// A groove is written as a short loop — one bar, two, four — and the arranged transport repeats
/// it to fill a section. Repeated as written, the loop walks straight over every section change,
/// and a form of verse, hook and bridge sounds like one pattern that changes its mind. This lays
/// the loop out to the section's length and marks the edges, as a player would.
///
/// The fill is one of `FillShape`'s, at a `FillSize`: the kit's own lines rest where the shape says
/// and the shape's voices play there. Hand percussion keeps playing through it — a conga player
/// does not stop for the drummer's fill. The usual fill, the one every song had, is the snare down
/// the toms over the last half bar (the last beat and a half in 3/4, or the last beat when the bar
/// has only one or two), the kick holding the fill's first step so the bar still has its weight.
public enum SectionFill {

    /// The voices a fill silences: the kit a drummer plays. Anything else keeps going.
    public static let kitVoices: Set<DrumVoice> = [
        .kick, .snare, .clap, .rim, .closedHat, .openHat, .ride, .crash, .lowTom, .midTom, .highTom,
    ]

    /// The order a fill walks down the kit.
    public static let walk: [DrumVoice] = [.snare, .highTom, .midTom, .lowTom]
    /// A timbalero's fill, round the timbales high to low: what a groove that has them fills on.
    public static let timbaleWalk: [DrumVoice] = [.timbaleHigh, .timbaleHigh, .timbaleLow, .timbaleLow]

    /// `groove` laid out over `bars` bars, with the usual fill in the last bar when `fillIntoNext`
    /// and a crash on the first beat when `crashIn`.
    public static func arranged(_ groove: Groove, bars: Int, beatsPerBar: Int,
                                fillIntoNext: Bool, crashIn: Bool) -> Groove {
        arranged(groove, bars: bars, beatsPerBar: beatsPerBar, fill: fillIntoNext ? .usual : nil, crashIn: crashIn)
    }

    /// `groove` laid out over `bars` bars, with `fill` at the end of its last bar and a crash on the
    /// first beat when `crashIn`.
    ///
    /// - Parameters:
    ///   - beatsPerBar: the song's meter, to find the beats inside a bar. When the groove's steps do
    ///     not divide into it, the fill falls back to the last quarter of the bar.
    ///   - fill: the fill to play; nil, or `.none`, for the groove run to the bar line. The usual
    ///     fill walks the timbales instead of the toms in a groove that has them.
    /// - Returns: `groove` untouched when there is nothing to mark, or when it is empty.
    public static func arranged(_ groove: Groove, bars: Int, beatsPerBar: Int,
                                fill: Fill?, crashIn: Bool) -> Groove {
        let stepsPerBar = max(1, groove.stepsPerBar)
        let bars = max(1, bars)
        let fill = fill.flatMap { $0.shape == .none ? nil : $0 }
        let fills = fill != nil && bars >= 2
        guard fills || crashIn, !groove.patterns.isEmpty else { return groove }

        let total = stepsPerBar * bars
        var patterns = groove.patterns.map { pattern -> GroovePattern in
            let source = pattern.steps.isEmpty ? [VelocityTier.rest] : pattern.steps
            return GroovePattern(voice: pattern.voice, steps: (0..<total).map { source[$0 % source.count] })
        }
        func index(of voice: DrumVoice) -> Int {
            if let found = patterns.firstIndex(where: { $0.voice == voice }) { return found }
            patterns.append(GroovePattern(voice: voice, steps: [VelocityTier](repeating: .rest, count: total)))
            return patterns.count - 1
        }

        if crashIn {
            patterns[index(of: .crash)].steps[0] = .accent
            let kick = index(of: .kick)
            if patterns[kick].steps[0] == .rest { patterns[kick].steps[0] = .accent }
        }

        if let fill, fills {
            let beats = max(1, beatsPerBar)
            let stepsPerBeat = stepsPerBar % beats == 0 ? stepsPerBar / beats : 0
            let per = max(1, stepsPerBeat)
            let timbales = groove.patterns.contains { ($0.voice == .timbaleHigh || $0.voice == .timbaleLow) && $0.steps.contains { $0 != .rest } }
            // The usual fill on a groove with timbales is the timbales' fill.
            let shape = fill.shape == .tomWalkDown && timbales ? FillShape.timbales : fill.shape
            let length = min(total - 1, max(1, Self.length(of: fill.size, shape: shape, stepsPerBar: stepsPerBar,
                                                              stepsPerBeat: stepsPerBeat, beats: beats, bars: bars)))
            let start = total - length
            func rest(_ voices: Set<DrumVoice>) {
                for p in patterns.indices where voices.contains(patterns[p].voice) {
                    for step in start..<total { patterns[p].steps[step] = .rest }
                }
            }
            func put(_ voice: DrumVoice, _ step: Int, _ tier: VelocityTier) {
                guard step >= 0, step < total else { return }
                patterns[index(of: voice)].steps[step] = tier
            }
            let onBeat = { (offset: Int) in offset % per == 0 }

            switch shape {
            case .tomWalkDown, .tomWalkUp, .timbales:
                rest(kitVoices)
                if shape == .timbales { rest([.timbaleHigh, .timbaleLow]) }
                put(.kick, start, .accent)
                let order = shape == .timbales ? timbaleWalk : (shape == .tomWalkUp ? Array(walk.reversed()) : walk)
                for offset in 0..<length {
                    let voice = order[min(order.count - 1, offset * order.count / length)]
                    let tier: VelocityTier = offset == 0 && length > 2 ? .ghost : (onBeat(offset) ? .accent : .normal)
                    put(voice, start + offset, tier)
                }
            case .snareRoll:
                rest(kitVoices)
                put(.kick, start, .accent)
                // Eighths through the first half, sixteenths through the second.
                let half = length / 2
                let eighth = max(1, per / 2)
                for offset in 0..<length where offset < half ? offset % eighth == 0 : true {
                    put(.snare, start + offset, onBeat(offset) || offset == length - 1 ? .accent : .normal)
                }
            case .kickSnare:
                rest(kitVoices)
                for offset in 0..<length {
                    let pos = offset % per
                    if per >= 4 {
                        if pos == 0 || pos == 1 { put(.kick, start + offset, .normal) }
                        if pos == 2 { put(.snare, start + offset, .accent) }
                    } else {
                        put(offset % 2 == 0 ? .kick : .snare, start + offset, offset % 2 == 0 ? .normal : .accent)
                    }
                }
            case .flam:
                rest(kitVoices)
                put(.snare, start, .accent)
                if length >= 2 { put(.snare, total - 1, .ghost) }
            case .dropOut:
                rest(kitVoices)
            case .hatLift:
                // The kick and the snare as written; the closed hats become open hats on eighths.
                rest([.closedHat, .openHat, .ride, .lowTom, .midTom, .highTom])
                let eighth = max(1, per / 2)
                for offset in stride(from: 0, to: length, by: eighth) {
                    put(.openHat, start + offset, onBeat(offset) ? .accent : .normal)
                }
            case .rimPickup:
                rest(kitVoices)
                put(.rim, start, .normal)
                if length >= 2 { put(.highTom, start + max(1, per / 2), .accent) }
            case .build:
                rest(kitVoices)
                let half = length / 2
                let eighth = max(1, per / 2)
                for offset in 0..<length {
                    if onBeat(offset) { put(.kick, start + offset, .normal) }
                    guard offset < half ? offset % eighth == 0 : true else { continue }
                    let tier: VelocityTier = offset < length / 4 ? .ghost : (offset < half ? .normal : .accent)
                    put(.snare, start + offset, tier)
                }
            case .none:
                break
            }
        }

        var arranged = groove
        arranged.bars = bars
        arranged.patterns = patterns
        return arranged
    }

    /// A fill's length in steps: its size in the meter, held to what the section has — a bar
    /// needs a bar before it, two bars two — and to the shape's own size for a beat-long shape.
    static func length(of size: FillSize, shape: FillShape, stepsPerBar: Int, stepsPerBeat: Int, beats: Int, bars: Int) -> Int {
        let size = shape.sizes.contains(size) || shape.sizes.isEmpty ? size : shape.defaultSize
        let halfBar: Int
        if stepsPerBeat > 0 {
            halfBar = (beats >= 3 ? beats / 2 : 1) * stepsPerBeat
        } else {
            halfBar = max(1, stepsPerBar / 4)
        }
        switch size {
        case .beat: return stepsPerBeat > 0 ? stepsPerBeat : max(1, stepsPerBar / 4)
        case .halfBar: return halfBar
        case .bar: return bars >= 2 ? stepsPerBar : halfBar
        case .twoBars: return bars >= 3 ? stepsPerBar * 2 : (bars >= 2 ? stepsPerBar : halfBar)
        }
    }
}
