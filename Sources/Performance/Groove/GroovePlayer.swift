import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph

/// Plays a groove through a `VoiceSampler`, looping it for a number of bars and reporting where it is.
///
/// A `ScheduledSource`, so the transport drives it: the engine calls `schedule(through:)` with a
/// monotonically increasing time and the player renders whole loop iterations into the sampler's
/// queue as that window reaches them. Nothing is rendered up front, so a groove can loop
/// indefinitely, and nothing is rendered late, because an iteration is materialised `preroll`
/// seconds before its first hit is due.
///
/// ## Who schedules the sampler
///
/// The sampler is itself a `ScheduledSource`. By default this player forwards `transportDidStart`,
/// `schedule(through:)` and `transportWillStop` to it after doing its own work, so only the player
/// needs adding to the `Engine` and the ordering is guaranteed: hits are queued before the sampler
/// is asked to look for them. Set `drivesSampler` to false when the sampler is registered with the
/// engine separately (several players sharing one kit), and add it to the engine *after* the
/// players so it still sees a full queue.
///
/// ## Determinism
///
/// Hits come from `GrooveRenderer`, which addresses its jitter by step index rather than drawing
/// from a stream, so scheduling in look-ahead chunks produces exactly the hits a single offline
/// render would. Loop iteration *k* uses step indices `k · stepsPerLoop …`, which means a longer
/// run is a prefix-preserving extension of a shorter one rather than a different performance.
@AudioActor
public final class GroovePlayer: ScheduledSource {

    /// Where the player is, in every unit a surface might want.
    public struct Position: Hashable, Sendable {
        /// Transport seconds.
        public var seconds: Double
        /// Beats since the groove's first step.
        public var beat: Double
        /// Bars since the groove's first step.
        public var bar: Int
        /// Beat within the bar, 0-based and fractional.
        public var beatInBar: Double
        /// Step within the current loop iteration.
        public var step: Int
        /// Which pass of the groove this is.
        public var loop: Int
    }

    // MARK: Configuration

    public let sampler: VoiceSampler
    /// The pattern being played. Changing it takes effect on the next loop iteration to be rendered.
    public var groove: Groove
    /// Where the steps land. Changing it takes effect on the next iteration.
    public var timeline: GrooveTimeline
    /// Velocities, swing, humanize and per-voice feel.
    public var options: GrooveRenderOptions
    /// Total bars to play, or nil to loop until the transport stops. Rounded up to whole iterations
    /// of the groove, because a feel is a phrase and half of one is not a feel.
    public var bars: Int?
    /// Drop the hits past `bars` rather than rounding the last iteration up. For a section of a
    /// song: five bars of a two-bar groove is five bars, and the sixth belongs to the next section.
    public var clipsToBars: Bool = false
    /// Beats after which the whole performance starts again, from its own start, for as long as
    /// the transport runs. How a section loops with the *form* rather than with itself: an
    /// eight-bar verse at bar 4 of a 46-bar song plays bars 4–12, then 50–58, and so on. Needs
    /// `bars`; without it the player already loops.
    public var cycleBeats: Double?
    /// How far ahead of an iteration's first hit it is queued, in seconds. Larger than the engine's
    /// look-ahead so a hit is never handed over after its own time.
    public var preroll: Double = 0.5
    /// Forward the transport callbacks to the sampler. See the type's documentation.
    public var drivesSampler: Bool = true

    // MARK: State

    /// Hits handed to the sampler since the transport started.
    public private(set) var scheduledHitCount = 0
    /// Loop iterations rendered since the transport started.
    public private(set) var scheduledLoopCount = 0
    /// The last `schedule(through:)` argument, i.e. the end of the window that has been covered.
    public private(set) var scheduledThrough: Double = -.infinity
    /// True once every iteration this player will ever produce has been queued.
    public private(set) var isFinished = false

    private var transportRunning = false
    private var nextLoop = 0

    // MARK: Init

    public init(sampler: VoiceSampler, groove: Groove, timeline: GrooveTimeline,
                options: GrooveRenderOptions = GrooveRenderOptions(), bars: Int? = nil) {
        self.sampler = sampler
        self.groove = groove
        self.timeline = timeline
        // `repeats` belongs to the renderer; the player loops instead, one iteration at a time.
        var options = options
        options.repeats = 1
        self.options = options
        self.bars = bars
    }

    /// A player for a named feel: its groove, velocities, swing and per-voice pocket.
    public convenience init(sampler: VoiceSampler, feel: Feel, timeline: GrooveTimeline,
                            bars: Int? = nil, seed: UInt64? = nil) {
        self.init(sampler: sampler, groove: feel.groove, timeline: timeline,
                  options: .feel(feel, seed: seed), bars: bars)
    }

    // MARK: Shape

    public var stepsPerLoop: Int { max(1, groove.stepsPerBar) * max(1, groove.bars) }
    public var barsPerLoop: Int { max(1, groove.bars) }
    public var beatsPerLoop: Double { Double(barsPerLoop * timeline.beatsPerBar) }

    /// Iterations in one pass over `bars`, or nil when there is no bound.
    public var loopsPerPass: Int? {
        guard let bars else { return nil }
        guard bars > 0 else { return 0 }
        return (bars + barsPerLoop - 1) / barsPerLoop
    }

    /// Total loop iterations this player will produce, or nil when it loops forever — which a
    /// cycling player does, pass after pass.
    public var totalLoops: Int? {
        guard cycleBeats == nil || loopsPerPass == 0 else { return nil }
        return loopsPerPass
    }

    /// Beats from the timeline's start at which iteration `index` begins.
    public func startBeat(ofLoop index: Int) -> Double {
        guard let cycleBeats, let perPass = loopsPerPass, perPass > 0 else {
            return Double(index) * beatsPerLoop
        }
        return Double(index / perPass) * cycleBeats + Double(index % perPass) * beatsPerLoop
    }

    /// Transport seconds where loop iteration `index` begins.
    public func startTime(ofLoop index: Int) -> Double {
        timeline.time(atBeat: startBeat(ofLoop: index))
    }

    /// Transport seconds at which the pass holding iteration `index` runs out of bars, when
    /// `clipsToBars` says the hits past it are dropped.
    func clipTime(ofLoop index: Int) -> Double? {
        guard clipsToBars, let bars, let perPass = loopsPerPass, perPass > 0 else { return nil }
        let passStart = Double(index / perPass) * (cycleBeats ?? Double(perPass) * beatsPerLoop)
        return timeline.time(atBeat: passStart + Double(bars * timeline.beatsPerBar))
    }

    /// Transport seconds where the whole performance ends, or nil when it loops forever.
    public var endTime: Double? {
        totalLoops.map { startTime(ofLoop: $0) }
    }

    /// Where `seconds` falls in the performance.
    public func position(at seconds: Double) -> Position {
        let beat = timeline.beat(atTime: seconds)
        let beatsPerBar = Double(timeline.beatsPerBar)
        let bar = Int((beat / beatsPerBar).rounded(.down))
        let loop = Int((beat / beatsPerLoop).rounded(.down))
        let beatInLoop = beat - Double(loop) * beatsPerLoop
        let step = Int((beatInLoop * Double(groove.stepsPerBar) / beatsPerBar).rounded(.down))
        return Position(seconds: seconds, beat: beat, bar: bar,
                        beatInBar: beat - Double(bar) * beatsPerBar,
                        step: step, loop: loop)
    }

    /// Where the transport has been asked to schedule to — the closest thing to "now" a source
    /// knows without the engine.
    public var position: Position {
        position(at: scheduledThrough.isFinite ? scheduledThrough : 0)
    }

    // MARK: ScheduledSource

    public func transportDidStart(_ transport: Transport) {
        transportDidStart(originSampleTime: Int64(transport.originSampleTime), sampleRate: transport.sampleRate)
    }

    /// The transport-free entry point, the same shape `VoiceSampler` offers, so the player can be
    /// driven by an offline harness that has no `Engine`.
    public func transportDidStart(originSampleTime: Int64, sampleRate: Double) {
        scheduledHitCount = 0
        scheduledLoopCount = 0
        scheduledThrough = -.infinity
        nextLoop = 0
        isFinished = totalLoops == 0
        transportRunning = true
        if drivesSampler {
            sampler.transportDidStart(originSampleTime: originSampleTime, sampleRate: sampleRate)
        }
    }

    public func schedule(through seconds: Double) {
        guard transportRunning else { return }
        scheduledThrough = max(scheduledThrough, seconds)
        let horizon = seconds + preroll
        while !isFinished, startTime(ofLoop: nextLoop) < horizon {
            if let total = totalLoops, nextLoop >= total { isFinished = true; break }
            queueLoop(nextLoop)
            nextLoop += 1
        }
        if drivesSampler { sampler.schedule(through: seconds) }
    }

    public func transportWillStop() {
        transportRunning = false
        isFinished = true
        if drivesSampler { sampler.transportWillStop() }
    }

    // MARK: Rendering

    /// Render one iteration and hand it to the sampler.
    private func queueLoop(_ index: Int) {
        var options = self.options
        options.repeats = 1
        // The jitter address continues across iterations, so the fifth pass of a two-bar loop is
        // humanized differently from the first — a loop that repeats its own mistakes sounds more
        // like a loop, not less. Position still comes entirely from the shifted timeline.
        options.jitterStepOffset = self.options.jitterStepOffset + index * stepsPerLoop
        var hits = GrooveRenderer.render(groove,
                                         on: shiftedTimeline(forLoop: index),
                                         options: options)
        if let clip = clipTime(ofLoop: index) { hits = hits.filter { $0.time < clip } }
        guard !hits.isEmpty else {
            scheduledLoopCount += 1
            return
        }
        sampler.enqueue(hits)
        scheduledHitCount += hits.count
        scheduledLoopCount += 1
    }

    /// The timeline advanced to iteration `index`, keeping the step numbering going so the seeded
    /// jitter differs from pass to pass.
    private func shiftedTimeline(forLoop index: Int) -> GrooveTimeline {
        var shifted = timeline
        shifted.startBeat = timeline.startBeat + Int(startBeat(ofLoop: index).rounded())
        return shifted
    }
}
