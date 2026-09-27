import SongGraph

/// What a drummer plays at a section's edges: a fill in its last bar that leads into the next
/// section, and a crash on the first beat of the section after it.
///
/// A groove is written as a short loop — one bar, two, four — and the arranged transport repeats
/// it to fill a section. Repeated as written, the loop walks straight over every section change,
/// and a form of verse, hook and bridge sounds like one pattern that changes its mind. This lays
/// the loop out to the section's length and marks the edges, as a player would.
///
/// The fill takes the second half of the last bar (the last beat and a half in 3/4, or the last
/// beat when the bar has only one or two): the kit's own lines rest there and the snare walks down
/// the toms, one voice a beat, accented on each beat and ghosted where it begins. Hand percussion
/// keeps playing through it — a conga player does not stop for the drummer's fill. The kick holds
/// the first step of the fill, so the bar still has its weight.
public enum SectionFill {

    /// The voices a fill silences: the kit a drummer plays. Anything else keeps going.
    public static let kitVoices: Set<DrumVoice> = [
        .kick, .snare, .clap, .rim, .closedHat, .openHat, .ride, .crash, .lowTom, .midTom, .highTom,
    ]

    /// The order a fill walks down the kit.
    public static let walk: [DrumVoice] = [.snare, .highTom, .midTom, .lowTom]

    /// `groove` laid out over `bars` bars, with a fill in the last bar when `fillIntoNext` and a
    /// crash on the first beat when `crashIn`.
    ///
    /// - Parameters:
    ///   - beatsPerBar: the song's meter, to find the beats inside a bar. When the groove's steps do
    ///     not divide into it, the fill falls back to the last quarter of the bar.
    /// - Returns: `groove` untouched when there is nothing to mark, or when it is empty.
    public static func arranged(_ groove: Groove, bars: Int, beatsPerBar: Int,
                                fillIntoNext: Bool, crashIn: Bool) -> Groove {
        let stepsPerBar = max(1, groove.stepsPerBar)
        let bars = max(1, bars)
        let fill = fillIntoNext && bars >= 2
        guard fill || crashIn, !groove.patterns.isEmpty else { return groove }

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

        if fill {
            let beats = max(1, beatsPerBar)
            let stepsPerBeat = stepsPerBar % beats == 0 ? stepsPerBar / beats : 0
            let length: Int
            if stepsPerBeat > 0 {
                let fillBeats = beats >= 3 ? beats / 2 : 1
                length = fillBeats * stepsPerBeat
            } else {
                length = max(1, stepsPerBar / 4)
            }
            let start = total - length
            for p in patterns.indices where kitVoices.contains(patterns[p].voice) {
                for step in start..<total { patterns[p].steps[step] = .rest }
            }
            let kick = index(of: .kick)
            patterns[kick].steps[start] = .accent
            let per = max(1, stepsPerBeat)
            for offset in 0..<length {
                let voice = walk[min(walk.count - 1, offset * walk.count / length)]
                let tier: VelocityTier
                if offset == 0, length > 2 {
                    tier = .ghost
                } else if offset % per == 0 {
                    tier = .accent
                } else {
                    tier = .normal
                }
                patterns[index(of: voice)].steps[start + offset] = tier
            }
        }

        var arranged = groove
        arranged.bars = bars
        arranged.patterns = patterns
        return arranged
    }
}
