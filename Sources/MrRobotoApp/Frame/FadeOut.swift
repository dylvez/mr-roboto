import AudioEngine
import Foundation

/// A song's ending: its last bars faded to silence. One curve for everything that plays the song —
/// the transport as it plays, the master as it exports, the Master tab's reading — so the fade you
/// hear is the fade that leaves.
public enum FadeOut {

    /// The lengths offered, in bars.
    public static let choices = [2, 4, 8]

    /// Where the fade runs, in song seconds: over the last `bars` of a form `songBars` long. Nil
    /// with no fade, or no form to end.
    public static func span(bars: Int?, songBars: Int, clock: TransportClock) -> ClosedRange<Double>? {
        guard let bars, bars > 0, songBars > 0 else { return nil }
        let end = clock.seconds(forBar: songBars)
        let start = clock.seconds(forBar: max(0, songBars - bars))
        guard end > start else { return nil }
        return start...end
    }

    /// The gain at a song time: 1 before the fade, 0 after it, and a quarter cosine between —
    /// gentle at first and quicker at the end, which is how a fade is heard as even rather than
    /// as a drop followed by a long tail of nearly nothing.
    public static func gain(at seconds: Double, span: ClosedRange<Double>) -> Double {
        if seconds <= span.lowerBound { return 1 }
        if seconds >= span.upperBound { return 0 }
        let t = (seconds - span.lowerBound) / (span.upperBound - span.lowerBound)
        return cos(t * .pi / 2)
    }

    /// The fade on rendered audio whose first frame is song time `origin`: every channel, and
    /// silence after it, so the ring-out past the last bar does not come back up.
    public static func apply(_ planar: inout [[Float]], sampleRate: Double, origin: Double = 0, span: ClosedRange<Double>) {
        guard sampleRate > 0 else { return }
        let first = max(0, Int(((span.lowerBound - origin) * sampleRate).rounded(.down)))
        for channel in planar.indices where first < planar[channel].count {
            for frame in first..<planar[channel].count {
                let gain = Float(gain(at: origin + Double(frame) / sampleRate, span: span))
                planar[channel][frame] *= gain
            }
        }
    }
}
