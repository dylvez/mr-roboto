import Foundation
import Instrument
import MusicTheory
import SongGraph

// MARK: - Per-voice feel

/// How one drum voice departs from the groove's own settings.
///
/// This is what makes a *feel* rather than a pattern. The machines Dilla worked on could swing and
/// displace one pad without touching the others — "you could swing the snare but not the kick, and
/// swing the hi-hats a little while swinging the snare a lot" — and that independence, not a global
/// swing knob, is where the drunk, off-kilter character comes from.
///
/// The direction is contested in the literature: the MPC3000 accounts describe the snare pushed
/// *late* against straight hats, while at least one analysis reports Dilla's snares slightly early
/// with the upbeat hats nudged back. Both are the same mechanism with opposite signs, so this type
/// takes a signed offset and each feel states its own.
///
/// Sources: <https://mixdownmag.com.au/features/gear-rundown-j-dilla/>,
/// <https://gearspace.com/board/rap-hip-hop-engineering-and-production/864711-j-dilla-quot-swing-quot-his-beats.html>.
public struct VoiceFeel: Hashable, Sendable, Codable {
    /// Swing for this voice only. `nil` uses the groove's.
    public var swing: Swing?
    /// A constant displacement in *fractions of a step*, positive = late. Expressed relative to the
    /// step so a feel keeps its character across tempos; at 90 BPM one sixteenth is 166.7 ms, so
    /// 0.06 is 10 ms.
    public var timingOffset: Double
    /// Multiplier on this voice's velocities, after the tier map and before humanizing.
    public var velocityScale: Double
    /// Multiplier on this voice's humanize jitter. 0 pins a voice to the grid while the rest breathe.
    public var humanizeScale: Double

    public init(swing: Swing? = nil, timingOffset: Double = 0,
                velocityScale: Double = 1, humanizeScale: Double = 1) {
        self.swing = swing
        self.timingOffset = timingOffset
        self.velocityScale = max(0, velocityScale)
        self.humanizeScale = max(0, humanizeScale)
    }

    /// Straight and on the grid however the groove is swung — the "hats stay straight" half of a
    /// Dilla-style feel.
    public static let straight = VoiceFeel(swing: .straight, humanizeScale: 0)
}

// MARK: - Options

/// Everything the renderer needs beyond the groove itself.
public struct GrooveRenderOptions: Hashable, Sendable {
    /// Tier → MIDI velocity.
    public var velocities: VelocityMap
    /// Overrides `Groove.swing`. `nil` uses what the part stores.
    public var swing: Swing?
    /// Seeded jitter. `.none` renders the grid exactly.
    public var humanize: Humanize
    /// Per-voice departures from the above.
    public var voices: [DrumVoice: VoiceFeel]
    /// How many times to lay the groove down end to end. The player loops instead of raising this.
    public var repeats: Int
    /// Note-off delay, in seconds, for hits that need one. Drums are one-shots: nil is right.
    public var duration: Double?
    /// Drop hits whose time is before this. Used when re-entering a loop mid-bar.
    public var startingAt: Double?
    /// Added to a step's index when *addressing* its seeded jitter — nothing moves, and the timeline
    /// still decides where the step lands. `GroovePlayer` sets it to the iteration's first step so
    /// the fifth pass of a two-bar loop is humanized differently from the first, which is the
    /// difference between a groove and a copy-paste.
    public var jitterStepOffset: Int

    public init(velocities: VelocityMap = .standard, swing: Swing? = nil,
                humanize: Humanize = .none, voices: [DrumVoice: VoiceFeel] = [:],
                repeats: Int = 1, duration: Double? = nil, startingAt: Double? = nil,
                jitterStepOffset: Int = 0) {
        self.velocities = velocities
        self.swing = swing
        self.humanize = humanize
        self.voices = voices
        self.repeats = max(0, repeats)
        self.duration = duration
        self.startingAt = startingAt
        self.jitterStepOffset = jitterStepOffset
    }

    /// The options a feel carries, with its humanize reseeded if asked.
    public static func feel(_ feel: Feel, seed: UInt64? = nil, repeats: Int = 1) -> GrooveRenderOptions {
        GrooveRenderOptions(velocities: feel.velocities,
                            swing: Swing(factor: feel.groove.swing),
                            humanize: seed.map { feel.humanize.seeded($0) } ?? feel.humanize,
                            voices: feel.voices,
                            repeats: repeats)
    }

    /// How a groove from a song plays: in the feel it names, on its own seed, with the swing it
    /// stores (which may have been set apart from the feel's). A groove that names no feel, or one
    /// the library no longer has, plays its steps on the grid, as every groove did before.
    public static func stored(_ groove: Groove, feels: FeelLibrary = .standard, repeats: Int = 1) -> GrooveRenderOptions {
        guard let named = groove.feel, let feel = feels.feel(named: named.name) else {
            return GrooveRenderOptions(repeats: repeats)
        }
        var options = GrooveRenderOptions.feel(feel, seed: named.seed, repeats: repeats)
        options.swing = nil
        return options
    }
}

// MARK: - Renderer

/// Turns a `SongGraph.Groove` into `VoiceSampler.Hit`s on a transport timeline.
///
/// One pass, no state: everything that varies — swing, tiers, humanizing, per-voice displacement —
/// is a pure function of the step's address, so rendering four bars in one call and rendering them
/// bar by bar give byte-identical results, which is what makes a bounce reproducible.
///
/// Order of operations for one step, in the order a drummer would describe them:
///
/// 1. the grid position, from the timeline (a detected beat time, not `60 / bpm`);
/// 2. swing, delaying the odd steps by `factor · stepDuration · 0.5`;
/// 3. the voice's constant displacement (the pocket: ahead of or behind the beat);
/// 4. seeded timing jitter;
/// 5. the tier's velocity, scaled for the voice, then seeded velocity jitter.
public enum GrooveRenderer {

    /// Render `groove` onto `timeline`, sorted by time.
    public static func render(_ groove: Groove, on timeline: GrooveTimeline,
                              options: GrooveRenderOptions = GrooveRenderOptions()) -> [VoiceSampler.Hit] {
        var hits: [VoiceSampler.Hit] = []
        let stepsPerBar = max(1, groove.stepsPerBar)
        let stepsPerLoop = max(1, stepsPerBar * max(1, groove.bars))
        let stepsPerBeat = max(1, stepsPerBar / max(1, timeline.beatsPerBar))
        let grooveSwing = options.swing ?? Swing(factor: groove.swing)
        let humanize = options.humanize
        hits.reserveCapacity(groove.patterns.reduce(0) { $0 + $1.steps.count } * max(1, options.repeats))

        for pattern in groove.patterns {
            let voiceFeel = options.voices[pattern.voice] ?? VoiceFeel()
            let swing = voiceFeel.swing ?? grooveSwing
            let voiceKey = SeededRandom.fnv1a(pattern.voice.rawValue)
            let usable = min(pattern.steps.count, stepsPerLoop)
            guard usable > 0 else { continue }

            for repeatIndex in 0..<options.repeats {
                for localStep in 0..<usable {
                    let tier = pattern.steps[localStep]
                    guard tier != .rest else { continue }
                    let step = repeatIndex * stepsPerLoop + localStep
                    let onBeat = step % stepsPerBeat == 0
                    // Jitter is addressed, not streamed: this is the address.
                    let address = UInt64(bitPattern: Int64(step + options.jitterStepOffset))

                    let stepDuration = timeline.stepDuration(ofStep: step, stepsPerBar: stepsPerBar)
                    var time = timeline.time(ofStep: step, stepsPerBar: stepsPerBar)
                    time += swing.offset(forStep: step, stepDuration: stepDuration)
                    time += voiceFeel.timingOffset * stepDuration
                    if humanize.timing > 0, voiceFeel.humanizeScale > 0 {
                        let jitter = humanize.timingJitter(voice: voiceKey, step: address, onBeat: onBeat)
                        time += jitter * voiceFeel.humanizeScale * stepDuration
                    }

                    var velocity = Double(options.velocities[tier]) * voiceFeel.velocityScale
                    if let floor = humanize.downbeatFloor, onBeat {
                        velocity = max(velocity, floor * 127)
                    }
                    if humanize.velocity > 0, voiceFeel.humanizeScale > 0 {
                        velocity += humanize.velocityJitter(voice: voiceKey, step: address, onBeat: onBeat)
                            * voiceFeel.humanizeScale
                    }
                    let midi = Int(velocity.rounded())
                    guard midi > 0 else { continue }

                    if let start = options.startingAt, time < start { continue }
                    hits.append(VoiceSampler.Hit(pattern.voice, velocity: min(127, midi),
                                                 at: time, duration: options.duration))
                }
            }
        }

        // A stable sort: the sampler consumes its queue FIFO, and two hits at the same instant must
        // come out in the same order on every render or the round robin would differ.
        return hits.enumerated()
            .sorted { a, b in a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time }
            .map(\.element)
    }

    /// Render a feel. Convenience over `render(_:on:options:)` with the feel's own settings.
    public static func render(_ feel: Feel, on timeline: GrooveTimeline,
                              repeats: Int = 1, seed: UInt64? = nil) -> [VoiceSampler.Hit] {
        render(feel.groove, on: timeline, options: .feel(feel, seed: seed, repeats: repeats))
    }

    /// Length of one pass of `groove` on `timeline`, in seconds.
    public static func duration(of groove: Groove, on timeline: GrooveTimeline) -> Double {
        let stepsPerBar = max(1, groove.stepsPerBar)
        let steps = stepsPerBar * max(1, groove.bars)
        return timeline.time(ofStep: steps, stepsPerBar: stepsPerBar) - timeline.time(ofStep: 0, stepsPerBar: stepsPerBar)
    }
}
