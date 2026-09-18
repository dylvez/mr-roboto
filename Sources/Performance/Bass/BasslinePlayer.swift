import AudioEngine
import Foundation
import Instrument
import SongGraph

/// Plays a `Bassline` on a sampler holding a bass kit, looping it under the transport the way
/// `GroovePlayer` loops a groove.
///
/// The line's notes are in beats from its own start; the timeline turns them into seconds, and a
/// note's duration becomes the hit's `duration`, so the sampler's note-off — the zone's release —
/// lands where the writer put it. That is R8 arriving at the speaker: a note that ends on the beat
/// ends on the beat because the note-off was scheduled there, not because the sample ran out.
///
/// One iteration is the line rounded up to whole bars. `bars` caps the performance like the groove
/// player's; nil loops until the transport stops.
public final class BasslinePlayer: ScheduledSource {

    public let sampler: VoiceSampler
    public var bassline: Bassline
    public var timeline: GrooveTimeline
    public var bars: Int?
    /// Drop the notes past `bars` rather than rounding the last iteration up: a section's bars
    /// are its own, and the next section's start with the next section.
    public var clipsToBars: Bool = false
    /// Beats after which the performance starts again from its own start, for as long as the
    /// transport runs — a section looping with the form. Needs `bars`.
    public var cycleBeats: Double?
    public var preroll: Double = 0.5
    /// Forward the transport callbacks to the sampler. On when this player is the only thing on
    /// its sampler, which it is: the bass has a sampler of its own.
    public var drivesSampler: Bool = true

    public private(set) var scheduledHitCount = 0
    public private(set) var scheduledLoopCount = 0
    public private(set) var scheduledThrough: Double = -.infinity
    public private(set) var isFinished = false

    private var transportRunning = false
    private var nextLoop = 0

    public init(sampler: VoiceSampler, bassline: Bassline, timeline: GrooveTimeline, bars: Int? = nil) {
        self.sampler = sampler
        self.bassline = bassline
        self.timeline = timeline
        self.bars = bars
    }

    // MARK: Shape

    /// The line's length in whole bars: what one iteration covers.
    public var barsPerLoop: Int {
        let beatsPerBar = Double(timeline.beatsPerBar)
        return max(1, Int((bassline.lengthInBeats / beatsPerBar).rounded(.up)))
    }

    public var beatsPerLoop: Double { Double(barsPerLoop * timeline.beatsPerBar) }

    public var loopsPerPass: Int? {
        guard let bars else { return nil }
        guard bars > 0 else { return 0 }
        return (bars + barsPerLoop - 1) / barsPerLoop
    }

    public var totalLoops: Int? {
        guard cycleBeats == nil || loopsPerPass == 0 else { return nil }
        return loopsPerPass
    }

    public func startBeat(ofLoop index: Int) -> Double {
        guard let cycleBeats, let perPass = loopsPerPass, perPass > 0 else {
            return Double(index) * beatsPerLoop
        }
        return Double(index / perPass) * cycleBeats + Double(index % perPass) * beatsPerLoop
    }

    public func startTime(ofLoop index: Int) -> Double {
        timeline.time(atBeat: startBeat(ofLoop: index))
    }

    func clipTime(ofLoop index: Int) -> Double? {
        guard clipsToBars, let bars, let perPass = loopsPerPass, perPass > 0 else { return nil }
        let passStart = Double(index / perPass) * (cycleBeats ?? Double(perPass) * beatsPerLoop)
        return timeline.time(atBeat: passStart + Double(bars * timeline.beatsPerBar))
    }

    public var endTime: Double? { totalLoops.map { startTime(ofLoop: $0) } }

    // MARK: ScheduledSource

    public func transportDidStart(_ transport: Transport) {
        transportDidStart(originSampleTime: Int64(transport.originSampleTime), sampleRate: transport.sampleRate)
    }

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

    /// The hits for one iteration, starting at `offsetBeats` on the timeline.
    nonisolated public static func hits(for bassline: Bassline, on timeline: GrooveTimeline, offsetBeats: Double) -> [VoiceSampler.Hit] {
        bassline.notes.map { note in
            let start = timeline.time(atBeat: offsetBeats + note.start)
            let end = timeline.time(atBeat: offsetBeats + note.end)
            return VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity, at: start,
                                    duration: max(0.02, end - start))
        }.sorted { $0.time < $1.time }
    }

    private func queueLoop(_ index: Int) {
        var hits = Self.hits(for: bassline, on: timeline, offsetBeats: startBeat(ofLoop: index))
        if let clip = clipTime(ofLoop: index) { hits = hits.filter { $0.time < clip } }
        scheduledLoopCount += 1
        guard !hits.isEmpty else { return }
        sampler.enqueue(hits)
        scheduledHitCount += hits.count
    }
}
