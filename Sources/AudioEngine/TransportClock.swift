import AVFAudio
import Foundation
import MusicTheory

// MARK: - TransportClock

/// A musical clock: tempo, time signature and an optional host-time anchor for
/// transport zero. All conversions are pure functions of the clock's fields.
///
/// "Transport seconds" is the module's canonical timeline: 0 is where the transport
/// started. Beats and bars are 0-based.
public struct TransportClock: Hashable, Sendable {
    /// Tempo in beats per minute.
    public var tempo: Double
    public var timeSignature: TimeSignature
    /// Sample rate used by the frame conversions.
    public var sampleRate: Double
    /// Host time (mach absolute ticks) at transport zero. Nil while the transport is not
    /// anchored to a realtime clock (e.g. offline rendering).
    public var startHostTime: UInt64?

    public init(tempo: Double, timeSignature: TimeSignature = .fourFour,
                sampleRate: Double = 48_000, startHostTime: UInt64? = nil) {
        precondition(tempo > 0 && sampleRate > 0)
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.sampleRate = sampleRate
        self.startHostTime = startHostTime
    }

    // MARK: beats <-> seconds

    public var secondsPerBeat: Double { 60 / tempo }
    public var secondsPerBar: Double { secondsPerBeat * Double(timeSignature.beatsPerBar) }

    public func seconds(forBeat beat: Double) -> Double { beat * secondsPerBeat }
    public func beat(forSeconds seconds: Double) -> Double { seconds / secondsPerBeat }

    public func seconds(forBar bar: Int, beat: Double = 0) -> Double {
        seconds(forBeat: Double(bar * timeSignature.beatsPerBar) + beat)
    }

    /// Bar index and beat-within-bar for a transport time.
    public func position(forSeconds seconds: Double) -> (bar: Int, beat: Double) {
        let totalBeats = beat(forSeconds: seconds)
        let bar = Int(floor(totalBeats / Double(timeSignature.beatsPerBar)))
        return (bar, totalBeats - Double(bar * timeSignature.beatsPerBar))
    }

    // MARK: frames

    public func frame(forSeconds seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((seconds * sampleRate).rounded())
    }

    public func seconds(forFrame frame: AVAudioFramePosition) -> Double {
        Double(frame) / sampleRate
    }

    public func frame(forBeat beat: Double) -> AVAudioFramePosition {
        frame(forSeconds: seconds(forBeat: beat))
    }

    public func frame(forBar bar: Int, beat: Double = 0) -> AVAudioFramePosition {
        frame(forSeconds: seconds(forBar: bar, beat: beat))
    }

    // MARK: host time

    /// Host ticks for a duration in seconds (mach timebase).
    public static func hostTicks(forSeconds seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }

    /// Seconds for a duration in host ticks.
    public static func seconds(forHostTicks ticks: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: ticks)
    }

    /// Host time for a transport time; nil if the clock is not anchored.
    public func hostTime(forSeconds seconds: Double) -> UInt64? {
        guard let start = startHostTime else { return nil }
        if seconds >= 0 {
            return start &+ TransportClock.hostTicks(forSeconds: seconds)
        }
        let back = TransportClock.hostTicks(forSeconds: -seconds)
        return back > start ? 0 : start - back
    }

    public func hostTime(forBeat beat: Double) -> UInt64? {
        hostTime(forSeconds: seconds(forBeat: beat))
    }

    /// Transport time for a host time; nil if the clock is not anchored.
    public func seconds(forHostTime hostTime: UInt64) -> Double? {
        guard let start = startHostTime else { return nil }
        if hostTime >= start {
            return TransportClock.seconds(forHostTicks: hostTime - start)
        }
        return -TransportClock.seconds(forHostTicks: start - hostTime)
    }

    public func beat(forHostTime hostTime: UInt64) -> Double? {
        seconds(forHostTime: hostTime).map(beat(forSeconds:))
    }

    // MARK: AVAudioTime

    /// An `AVAudioTime` for a transport time.
    ///
    /// When the clock is anchored this is a host time (what realtime player-node scheduling
    /// uses); otherwise it is a sample time relative to transport zero, which is what
    /// manual-rendering mode honours (host times are ignored offline).
    public func audioTime(forSeconds seconds: Double) -> AVAudioTime {
        if let host = hostTime(forSeconds: seconds) {
            return AVAudioTime(hostTime: host)
        }
        return AVAudioTime(sampleTime: frame(forSeconds: seconds), atRate: sampleRate)
    }

    public func audioTime(forBeat beat: Double) -> AVAudioTime {
        audioTime(forSeconds: seconds(forBeat: beat))
    }

    // MARK: grid

    /// A regular `BeatGrid` of `bars` bars starting at `start` seconds.
    public func grid(bars barCount: Int, startingAt start: Double = 0) -> BeatGrid {
        let bpb = timeSignature.beatsPerBar
        var beats: [Double] = []
        var bars: [Double] = []
        beats.reserveCapacity(barCount * bpb)
        bars.reserveCapacity(barCount)
        for bar in 0..<barCount {
            bars.append(start + seconds(forBar: bar))
            for b in 0..<bpb {
                beats.append(start + seconds(forBar: bar, beat: Double(b)))
            }
        }
        return BeatGrid(beats: beats, bars: bars)
    }
}
