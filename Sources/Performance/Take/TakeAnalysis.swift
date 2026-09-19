import Analysis
import AudioEngine
import Foundation
import MusicTheory
import SongGraph

// M5 R7: a take, observed. Every sung note against the key and the grid, in cents and milliseconds.

/// One sung note, placed in the song.
public struct TakeNote: Hashable, Sendable, Identifiable {
    public var index: Int
    /// Song seconds.
    public var start: Double
    public var end: Double
    /// Fractional MIDI pitch, the note's median.
    public var midi: Double
    /// The nearest equal-tempered note, and the cents from it (+ is sharp).
    public var nearest: Int
    public var cents: Double
    /// The nearest note *in the key*, and the cents from it. Equal to `cents` when the nearest
    /// note is in the key; larger when the singer landed between scale degrees.
    public var nearestInKey: Int
    public var centsFromKey: Double
    /// Bar and beat of the onset, 0-based.
    public var bar: Int
    public var beat: Double
    /// Milliseconds from the nearest sixteenth of the grid: + is late.
    public var timingMS: Double

    public var id: Int { index }
    public var duration: Double { end - start }
    public var pitchName: String { Pitch(midi: nearestInKey).description }
}

/// A take read against the key and the grid.
public struct TakeAnalysis: Hashable, Sendable {
    public var label: String
    public var sampleRate: Double
    public var alignmentSeconds: Double
    public var duration: Double
    public var notes: [TakeNote]
    public var peakDBFS: Double
    public var key: Key?

    public var worstCents: TakeNote? { notes.max { abs($0.centsFromKey) < abs($1.centsFromKey) } }
    public var worstTiming: TakeNote? { notes.max { abs($0.timingMS) < abs($1.timingMS) } }
    public var meanAbsoluteCents: Double { notes.isEmpty ? 0 : notes.map { abs($0.centsFromKey) }.reduce(0, +) / Double(notes.count) }
    public func late(over ms: Double) -> [TakeNote] { notes.filter { $0.timingMS > ms } }
    public func early(over ms: Double) -> [TakeNote] { notes.filter { $0.timingMS < -ms } }
    public func drifting(over cents: Double) -> [TakeNote] { notes.filter { abs($0.centsFromKey) > cents } }

    /// Reads planar audio placed at `alignmentSeconds` in a song at `clock`, against `key`.
    public static func of(_ planar: [[Float]], sampleRate: Double, alignmentSeconds: Double, key: Key?,
                          clock: TransportClock, label: String = "Take", tracker: PitchTracker = PitchTracker()) -> TakeAnalysis {
        let mono: [Float]
        if planar.count > 1 {
            let n = planar[0].count
            mono = (0..<n).map { i in planar.reduce(Float(0)) { $0 + $1[i] } / Float(planar.count) }
        } else {
            mono = planar.first ?? []
        }
        let frames = tracker.track(mono, sampleRate: sampleRate)
        let tracked = tracker.notes(in: frames)
        let sixteenth = clock.secondsPerBeat / 4
        let scale = key?.pitchClasses.map(\.rawValue) ?? Array(0..<12)
        let notes = tracked.enumerated().map { index, note -> TakeNote in
            let start = alignmentSeconds + note.start
            let end = alignmentSeconds + note.end
            let nearestInKey = Self.nearest(note.midi, inScale: scale)
            let position = clock.position(forSeconds: max(0, start))
            let gridLine = (start / sixteenth).rounded() * sixteenth
            return TakeNote(index: index, start: start, end: end, midi: note.midi, nearest: note.nearest, cents: note.cents,
                            nearestInKey: nearestInKey, centsFromKey: (note.midi - Double(nearestInKey)) * 100,
                            bar: position.bar, beat: position.beat, timingMS: (start - gridLine) * 1000)
        }
        let peak = MixMeter.samplePeakDB(planar)
        return TakeAnalysis(label: label, sampleRate: sampleRate, alignmentSeconds: alignmentSeconds,
                            duration: Double(mono.count) / sampleRate, notes: notes, peakDBFS: peak, key: key)
    }

    /// The nearest MIDI note whose pitch class is in the scale.
    static func nearest(_ midi: Double, inScale scale: [Int]) -> Int {
        let base = Int(midi.rounded())
        var best = base
        var bestDistance = Double.infinity
        for candidate in (base - 6)...(base + 6) where scale.contains(((candidate % 12) + 12) % 12) {
            let distance = abs(Double(candidate) - midi)
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }
        return best
    }
}
