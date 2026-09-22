import AudioEngine
import Foundation
import Instrument
import MusicTheory
import SongGraph

/// Plays the song's pitched instrument under the transport: the chords, and the tune.
///
/// The sibling of `GroovePlayer` and `BasslinePlayer`, and deliberately the same shape — the same
/// `bars` cap, the same `clipsToBars`, the same `cycleBeats`, the same `drivesSampler` — because
/// the arranged transport drives all three the same way and a fourth idiom here would be a fourth
/// thing to get wrong.
///
/// What it plays is `[NoteEvent]` rather than a progression or a melody, because at this level
/// those are the same thing: pitches, at beats, for a length. `Voicing` turns a progression into
/// them; a melody already is them. That is why one player covers both, and why the chords and the
/// tune can share a sampler — which they must, since a song names one pitched instrument.
public final class KeysPlayer: ScheduledSource {

    public let sampler: VoiceSampler
    /// One iteration, in beats from its own start.
    public var notes: [NoteEvent]
    /// What one iteration covers, in beats. Held rather than derived: a progression's written
    /// length and the end of its last note differ by `Voicing.hold`, and it is the written length
    /// that repeats.
    public var lengthInBeats: Double
    public var timeline: GrooveTimeline
    public var bars: Int?
    /// Drop the notes past `bars` rather than rounding the last iteration up: a section's bars are
    /// its own, and the next section's start with the next section.
    public var clipsToBars: Bool = false
    /// Beats after which the performance starts again from its own start, for as long as the
    /// transport runs — a section looping with the form. Needs `bars`.
    public var cycleBeats: Double?
    public var preroll: Double = 0.5
    /// Forward the transport callbacks to the sampler. Off for every player but the first on a
    /// shared sampler: the chords, the tune and every section's share one instrument.
    public var drivesSampler: Bool = true

    public private(set) var scheduledHitCount = 0
    public private(set) var scheduledLoopCount = 0
    public private(set) var scheduledThrough: Double = -.infinity
    public private(set) var isFinished = false

    private var transportRunning = false
    private var nextLoop = 0

    public init(sampler: VoiceSampler, notes: [NoteEvent], lengthInBeats: Double,
                timeline: GrooveTimeline, bars: Int? = nil) {
        self.sampler = sampler
        self.notes = notes
        self.lengthInBeats = max(0, lengthInBeats)
        self.timeline = timeline
        self.bars = bars
    }

    /// A progression, voiced.
    public convenience init(sampler: VoiceSampler, progression: Progression,
                            timeline: GrooveTimeline, bars: Int? = nil) {
        self.init(sampler: sampler, notes: Voicing.notes(for: progression),
                  lengthInBeats: Voicing.lengthInBeats(of: progression), timeline: timeline, bars: bars)
    }

    /// A melody, as written.
    public convenience init(sampler: VoiceSampler, melody: Melody,
                            timeline: GrooveTimeline, bars: Int? = nil) {
        self.init(sampler: sampler, notes: melody.notes, lengthInBeats: melody.lengthInBeats,
                  timeline: timeline, bars: bars)
    }

    // MARK: Shape

    /// The performance's length in whole bars: what one iteration covers.
    public var barsPerLoop: Int {
        let beatsPerBar = Double(timeline.beatsPerBar)
        let written = max(lengthInBeats, notes.map(\.end).max() ?? 0)
        return max(1, Int((written / beatsPerBar).rounded(.up)))
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
        isFinished = totalLoops == 0 || notes.isEmpty
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
    nonisolated public static func hits(for notes: [NoteEvent], on timeline: GrooveTimeline,
                                        offsetBeats: Double) -> [VoiceSampler.Hit] {
        notes.map { note in
            let start = timeline.time(atBeat: offsetBeats + note.start)
            let end = timeline.time(atBeat: offsetBeats + note.end)
            return VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity, at: start,
                                    duration: max(0.02, end - start))
        }.sorted { $0.time < $1.time }
    }

    private func queueLoop(_ index: Int) {
        var hits = Self.hits(for: notes, on: timeline, offsetBeats: startBeat(ofLoop: index))
        if let clip = clipTime(ofLoop: index) { hits = hits.filter { $0.time < clip } }
        scheduledLoopCount += 1
        guard !hits.isEmpty else { return }
        sampler.enqueue(hits)
        scheduledHitCount += hits.count
    }
}
