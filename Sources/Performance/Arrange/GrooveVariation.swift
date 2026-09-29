import Foundation
import SongGraph

/// A way of playing a groove for a section that is not the loop as written.
public enum GrooveTreatment: String, Sendable, CaseIterable, Codable {
    /// The kick and whatever keeps time: an intro, an outro.
    case thin
    /// No kick, everything else a step quieter: a breakdown.
    case noKick = "no-kick"
    /// No kick, and the snare from quarters to eighths to sixteenths: into a drop.
    case build
    /// The loop, with the snare on every beat of its last bars: into a chorus.
    case push
    /// The loop with a layer on top of it: a hook, a drop.
    case lift
    /// The hats moved to the ride: a bridge.
    case ride

    /// What it is called on a chip, after the section it was written for.
    public var word: String {
        switch self {
        case .thin: return "thinned"
        case .noKick: return "no kick"
        case .build: return "build"
        case .push: return "push"
        case .lift: return "lifted"
        case .ride: return "on the ride"
        }
    }
}

/// A groove, played another way.
///
/// A loop repeated through every section is one pattern that changes its length. What a drummer
/// does instead is small and mostly subtraction: leaves the backbeat out of the intro, takes the
/// kick away under a breakdown, rolls the snare into the drop, opens something on top when the hook
/// arrives. Each of those is written here from the loop itself, so a variation is still that
/// groove — its voices, its swing, its feel, its dust — and not a preset laid over the song.
///
/// Every treatment answers nil when it would change nothing or leave nothing: a groove that is
/// only a kick has no breakdown in it, and the section plays the loop.
public enum GrooveVariation {

    /// The voices that keep time when everything else has stopped.
    public static let timekeepers: Set<DrumVoice> = [.closedHat, .ride, .shaker]
    /// Where the backbeat is.
    public static let backbeat: [DrumVoice] = [.snare, .clap, .rim]
    /// Hand percussion: a second player, who does not stop when the drummer does.
    public static let hands: Set<DrumVoice> = [
        .shaker, .tambourine, .highConga, .lowConga, .highBongo, .lowBongo, .claves, .woodblock, .cowbell, .perc,
    ]

    /// The longest a written-through variation runs. The Grid draws sixteen bars and no more, and
    /// a roll that came round again halfway through a longer section would be two builds.
    public static let longestBars = 16

    /// - Parameters:
    ///   - bars: the section's length, for the treatments that are written through it — a build
    ///     and a push. The others stay the loop's own length.
    ///   - layers: how many layers a lift adds: one for a hook, two for a drop.
    ///   - electronic: whether the song is dance music, which lifts with an open hat off the beat
    ///     where a band would reach for a tambourine.
    public static func vary(_ groove: Groove, as treatment: GrooveTreatment, bars: Int, beatsPerBar: Int,
                            layers: Int = 1, electronic: Bool = false) -> Groove? {
        guard sounds(groove) else { return nil }
        let varied: Groove?
        switch treatment {
        case .thin: varied = thin(groove)
        case .noKick: varied = noKick(groove)
        case .build: varied = build(groove, bars: bars, beatsPerBar: beatsPerBar)
        case .push: varied = push(groove, bars: bars, beatsPerBar: beatsPerBar)
        case .lift: varied = lift(groove, beatsPerBar: beatsPerBar, layers: layers, electronic: electronic)
        case .ride: varied = ride(groove)
        }
        guard let varied, sounds(varied), varied.patterns != groove.patterns else { return nil }
        return varied
    }

    // MARK: The treatments

    static func thin(_ groove: Groove) -> Groove? {
        var out = groove
        let keepsTime = groove.patterns.contains { timekeepers.contains($0.voice) && hits(in: $0) > 0 }
        if keepsTime {
            out.patterns = groove.patterns.filter { $0.voice == .kick || timekeepers.contains($0.voice) }
        } else {
            // Nothing keeps time but the kick and the backbeat: both stay, the backbeat a step down.
            out.patterns = groove.patterns.compactMap { pattern in
                if pattern.voice == .kick { return pattern }
                guard backbeat.contains(pattern.voice) else { return nil }
                return GroovePattern(voice: pattern.voice, steps: pattern.steps.map(softer))
            }
        }
        return tidy(out)
    }

    static func noKick(_ groove: Groove) -> Groove? {
        let dropped: Set<DrumVoice> = [.kick, .openHat, .crash, .lowTom, .midTom, .highTom]
        var out = groove
        out.patterns = groove.patterns.compactMap { pattern in
            if dropped.contains(pattern.voice) { return nil }
            if hands.contains(pattern.voice) { return pattern }
            return GroovePattern(voice: pattern.voice, steps: pattern.steps.map(softer))
        }
        return tidy(out)
    }

    /// Written through the section: no kick, the snare on the beats, then the eighths, then every
    /// step, louder as it goes; the hats off the beat and then on every step with it.
    static func build(_ groove: Groove, bars: Int, beatsPerBar: Int) -> Groove? {
        let steps = max(1, groove.stepsPerBar), beats = max(1, beatsPerBar)
        guard steps % beats == 0, (2...longestBars).contains(bars) else { return nil }
        let perBeat = steps / beats
        let length = bars
        let total = steps * length
        let totalBeats = beats * length
        /// The step inside a beat where the off-beat eighth falls: halfway, or the last of a triplet.
        let and = perBeat % 2 == 0 ? perBeat / 2 : perBeat - 1
        let snareVoice = backbeat.first { voice in groove.patterns.contains { $0.voice == voice && hits(in: $0) > 0 } } ?? .snare

        var snare = [VelocityTier](repeating: .rest, count: total)
        var hat = [VelocityTier](repeating: .rest, count: total)
        for beat in 0..<totalBeats {
            let phase = Double(beat) / Double(totalBeats)
            let start = beat * perBeat
            let lastBar = beat >= totalBeats - beats
            if phase < 0.5 {
                snare[start] = phase < 0.25 ? .ghost : .normal
                if perBeat > 1 { hat[start + and] = .normal }
            } else if phase < 0.75 {
                snare[start] = .normal
                if perBeat > 1 { snare[start + and] = .normal; hat[start + and] = .normal }
            } else {
                for step in 0..<perBeat {
                    snare[start + step] = lastBar ? .accent : .normal
                    hat[start + step] = step == 0 || step == and ? .normal : .ghost
                }
            }
        }

        var out = groove
        out.bars = length
        // A light swing on a roll is only unsteadiness; a real one — a shuffle — stays a shuffle.
        if Swing(factor: groove.swing).percent < 58 { out.swing = 0 }
        var patterns = [GroovePattern(voice: snareVoice, steps: snare), GroovePattern(voice: .closedHat, steps: hat)]
        // The shaker, if the loop has one, plays through: a second pair of hands.
        for pattern in groove.patterns where pattern.voice == .shaker && hits(in: pattern) > 0 {
            patterns.append(GroovePattern(voice: .shaker, steps: tile(pattern.steps, cycle: groove.stepCount, to: total)))
        }
        out.patterns = patterns
        return out
    }

    /// The loop laid out to the section, with the snare on every beat of its last two bars.
    static func push(_ groove: Groove, bars: Int, beatsPerBar: Int) -> Groove? {
        let steps = max(1, groove.stepsPerBar), beats = max(1, beatsPerBar)
        guard steps % beats == 0, (2...longestBars).contains(bars) else { return nil }
        let perBeat = steps / beats
        let length = bars
        var out = groove.tiled(toBars: length)
        let snareVoice = backbeat.first { voice in groove.patterns.contains { $0.voice == voice && hits(in: $0) > 0 } } ?? .snare
        let at = index(of: snareVoice, in: &out)
        let pushed = min(2, max(1, length / 2))
        for bar in (length - pushed)..<length {
            for beat in 0..<beats {
                let step = bar * steps + beat * perBeat
                let tier: VelocityTier = bar == length - 1 ? .accent : .normal
                if out.patterns[at].steps[step].velocity < tier.velocity { out.patterns[at].steps[step] = tier }
            }
        }
        return out
    }

    static func lift(_ groove: Groove, beatsPerBar: Int, layers: Int, electronic: Bool) -> Groove? {
        let steps = max(1, groove.stepsPerBar), beats = max(1, beatsPerBar)
        guard steps % beats == 0, steps / beats > 1 else { return nil }
        let perBeat = steps / beats
        let and = perBeat % 2 == 0 ? perBeat / 2 : perBeat - 1
        let total = groove.stepCount
        func silent(_ voice: DrumVoice) -> Bool {
            !groove.patterns.contains { $0.voice == voice && hits(in: $0) > 0 }
        }
        /// A layer as steps: a tier on the beat, a tier off it.
        func layer(on: VelocityTier, off: VelocityTier) -> [VelocityTier] {
            (0..<total).map { step in
                let inBeat = step % perBeat
                return inBeat == 0 ? on : inBeat == and ? off : .rest
            }
        }
        // In the order each is reached for. A layer the loop already plays is not added again.
        let offered: [(DrumVoice, [VelocityTier])] = electronic
            ? [(.openHat, layer(on: .rest, off: .normal)), (.tambourine, layer(on: .normal, off: .ghost)),
               (.ride, layer(on: .rest, off: .normal))]
            : [(.tambourine, layer(on: .normal, off: .ghost)), (.ride, layer(on: .normal, off: .rest)),
               (.openHat, layer(on: .rest, off: .normal))]
        var out = groove
        var added = 0
        for (voice, pattern) in offered where added < max(1, layers) && silent(voice) {
            if let at = out.patterns.firstIndex(where: { $0.voice == voice }) {
                out.patterns[at].steps = pattern
            } else {
                out.patterns.append(GroovePattern(voice: voice, steps: pattern))
            }
            // An open hat and a closed one on the same step are one hat: the open one wins.
            if voice == .openHat, let closed = out.patterns.firstIndex(where: { $0.voice == .closedHat }) {
                for step in 0..<min(total, out.patterns[closed].steps.count) where pattern[step] != .rest {
                    out.patterns[closed].steps[step] = .rest
                }
            }
            added += 1
        }
        return added > 0 ? out : nil
    }

    static func ride(_ groove: Groove) -> Groove? {
        guard let hat = groove.patterns.firstIndex(where: { $0.voice == .closedHat && hits(in: $0) > 0 }),
              !groove.patterns.contains(where: { $0.voice == .ride && hits(in: $0) > 0 }) else { return nil }
        var out = groove
        out.patterns.removeAll { $0.voice == .ride || $0.voice == .openHat }
        if let at = out.patterns.firstIndex(where: { $0.voice == .closedHat }) {
            out.patterns[at] = GroovePattern(voice: .ride, steps: groove.patterns[hat].steps)
        }
        return out
    }

    // MARK: Helpers

    /// One step down, and never to nothing: a ghost is already as quiet as a hit gets.
    static func softer(_ tier: VelocityTier) -> VelocityTier {
        switch tier {
        case .accent: return .normal
        case .normal, .ghost: return .ghost
        case .rest: return .rest
        }
    }

    static func hits(in pattern: GroovePattern) -> Int { pattern.steps.count { $0 != .rest } }

    static func sounds(_ groove: Groove) -> Bool { groove.patterns.contains { hits(in: $0) > 0 } }

    /// Without the rows that have nothing left in them.
    static func tidy(_ groove: Groove) -> Groove? {
        var out = groove
        out.patterns.removeAll { hits(in: $0) == 0 }
        return out.patterns.isEmpty ? nil : out
    }

    static func tile(_ steps: [VelocityTier], cycle: Int, to count: Int) -> [VelocityTier] {
        let cycle = max(1, cycle)
        return (0..<count).map { index in
            let step = index % cycle
            return step < steps.count ? steps[step] : .rest
        }
    }

    static func index(of voice: DrumVoice, in groove: inout Groove) -> Int {
        if let found = groove.patterns.firstIndex(where: { $0.voice == voice }) {
            let missing = groove.stepCount - groove.patterns[found].steps.count
            if missing > 0 { groove.patterns[found].steps += [VelocityTier](repeating: .rest, count: missing) }
            return found
        }
        groove.patterns.append(GroovePattern(voice: voice, steps: [VelocityTier](repeating: .rest, count: groove.stepCount)))
        return groove.patterns.count - 1
    }
}
