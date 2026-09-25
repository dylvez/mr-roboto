import AudioEngine
import Foundation
import MusicTheory
import SongGraph

// Inputs I6: what was played on a controller while the song ran, as a groove, a bass line or a tune.

/// A note as the hands played it: transport seconds in, and out when the key was let go.
public struct PlayedNote: Hashable, Sendable {
    public var note: Int
    public var velocity: Int
    public var start: Double
    public var end: Double?

    public init(note: Int, velocity: Int, start: Double, end: Double? = nil) {
        self.note = note
        self.velocity = velocity
        self.start = start
        self.end = end
    }
}

public enum MIDICapture {

    /// Note-ons paired with the note-off that follows on the same note. A note still held at the
    /// end has no end.
    public static func notes(from events: [(kind: MIDIEvent.Kind, seconds: Double)]) -> [PlayedNote] {
        var open: [Int: Int] = [:]
        var out: [PlayedNote] = []
        for event in events.sorted(by: { $0.seconds < $1.seconds }) {
            switch event.kind {
            case .noteOn(let note, let velocity):
                if let index = open[note] { out[index].end = event.seconds }
                open[note] = out.count
                out.append(PlayedNote(note: note, velocity: velocity, start: event.seconds))
            case .noteOff(let note):
                if let index = open.removeValue(forKey: note) { out[index].end = event.seconds }
            case .controlChange:
                continue
            }
        }
        return out
    }

    /// The groove: each hit on the nearest sixteenth of a grid that tolerates swing (a hit late
    /// off an odd step by up to half a step is that odd step, not the next even one), velocity to
    /// the tiers, and the swing measured from how late the odd-step hits were.
    ///
    /// - Parameters:
    ///   - sectionStart: transport seconds of the section's first bar.
    ///   - bars: the section's length; nil takes the bars actually played.
    public static func groove(_ notes: [PlayedNote], clock: TransportClock, sectionStart: Double, bars: Int?, stepsPerBar: Int = 16) -> Groove? {
        let beatsPerBar = Double(clock.timeSignature.beatsPerBar)
        let stepsPerBeat = Double(stepsPerBar) / beatsPerBar
        var placed: [(voice: DrumVoice, step: Int, velocity: Int, lateness: Double?)] = []
        for note in notes {
            let position = clock.beat(forSeconds: note.start - sectionStart) * stepsPerBeat
            guard position > -0.5 else { continue }
            let pair = max(0, position).truncatingRemainder(dividingBy: 2)
            let step: Int
            var lateness: Double?
            if pair >= 0.5, pair < 1.5 {
                step = Int(floor(max(0, position) / 2)) * 2 + 1
                lateness = pair - 1
            } else {
                step = Int((max(0, position) / 2).rounded()) * 2
            }
            placed.append((DrumMap.voice(for: note.note), step, note.velocity, lateness))
        }
        guard !placed.isEmpty else { return nil }
        let length = bars ?? max(1, Int(ceil(Double(placed.map(\.step).max()! + 1) / Double(stepsPerBar))))
        let total = stepsPerBar * length
        var patterns: [DrumVoice: [VelocityTier]] = [:]
        for hit in placed where hit.step < total {
            var steps = patterns[hit.voice] ?? [VelocityTier](repeating: .rest, count: total)
            let tier: VelocityTier = hit.velocity <= 50 ? .ghost : (hit.velocity >= 110 ? .accent : .normal)
            if steps[hit.step] == .rest || tier.velocity > steps[hit.step].velocity { steps[hit.step] = tier }
            patterns[hit.voice] = steps
        }
        guard !patterns.isEmpty else { return nil }
        let late = placed.compactMap(\.lateness).filter { $0 >= 0 }.sorted()
        let swing = late.isEmpty ? 0 : min(1, max(0, 2 * late[late.count / 2]))
        let ordered = DrumMap.notes.map(\.0).compactMap { voice in patterns[voice].map { GroovePattern(voice: voice, steps: $0) } }
        return Groove(stepsPerBar: stepsPerBar, bars: length, swing: swing, patterns: ordered)
    }

    /// The bass line, unquantised: starts and lengths in beats from the section's first bar, as
    /// played, so the lag against the kick is the one the hands put there.
    public static func bassline(_ notes: [PlayedNote], clock: TransportClock, sectionStart: Double, end: Double?, key: Key?, sound: String?) -> Bassline? {
        let events = noteEvents(notes, clock: clock, sectionStart: sectionStart, end: end)
        guard !events.isEmpty else { return nil }
        return Bassline(notes: events, sound: sound ?? "finger", key: key)
    }

    /// The tune, the same way: as played, from the section's first bar, one pass as long as the
    /// section — so a phrase whose last bar is a breath keeps the breath. Quantising is the Piano
    /// roll's job, where it can be heard and undone.
    public static func melody(_ notes: [PlayedNote], clock: TransportClock, sectionStart: Double, end: Double?, bars: Int?) -> Melody? {
        let events = noteEvents(notes, clock: clock, sectionStart: sectionStart, end: end)
        guard !events.isEmpty else { return nil }
        return Melody(notes: events, lengthInBars: bars)
    }

    /// Played notes as note events in beats from the section's first bar. A note let go of has
    /// the length it was held; one still held at the end runs to the end of the take.
    static func noteEvents(_ notes: [PlayedNote], clock: TransportClock, sectionStart: Double, end: Double?) -> [NoteEvent] {
        notes.compactMap { note in
            let start = clock.beat(forSeconds: note.start - sectionStart)
            guard start >= -0.05 else { return nil }
            let stop = note.end ?? end ?? (note.start + clock.secondsPerBeat)
            let duration = max(1.0 / 16, clock.beat(forSeconds: stop - note.start))
            return NoteEvent(pitch: Pitch(midi: note.note), start: max(0, start), duration: duration, velocity: max(1, min(127, note.velocity)))
        }
    }
}
