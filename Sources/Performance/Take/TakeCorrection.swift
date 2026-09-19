import Analysis
import Foundation

// M5 R8: the offer, rendered. A note shifted by its measured cents with formants held, or an
// onset nudged by its milliseconds — as new audio, never as a change to the take.

public enum TakeCorrection {

    /// The tonal preset MergeRender measured for bass; a voice is higher and shorter, so a
    /// shorter block keeps consonants: 120 ms at a 30 ms hop.
    public static let voicePreset = SignalsmithTimeStretcher.Preset.custom(block: 0.12, interval: 0.03)
    /// Seconds of raised-cosine at every edge the correction cuts.
    public static let edge = 0.01

    /// The audio with the span `start..<end` (seconds from the take's frame 0) shifted by `cents`,
    /// formants preserved, edges crossfaded into the untouched audio.
    public static func shifting(_ planar: [[Float]], sampleRate: Double, start: Double, end: Double, cents: Double) throws -> [[Float]] {
        guard abs(cents) > 0.01, let frames = planar.first?.count, frames > 0 else { return planar }
        let a = max(0, Int(start * sampleRate)), b = min(frames, Int(end * sampleRate))
        guard b > a + Int(edge * sampleRate) else { return planar }
        // Shift a little more than the span, so the stretcher's own ramp-up is outside the seam.
        let pad = Int(0.05 * sampleRate)
        let from = max(0, a - pad), to = min(frames, b + pad)
        let segment = planar.map { Array($0[from..<to]) }
        let stretcher = SignalsmithTimeStretcher(preset: voicePreset, preserveFormants: true, seed: 1)
        var shifted = try stretcher.stretch(planar: segment, sampleRate: sampleRate, ratio: 1, pitchShift: cents / 100)
        // The stretcher may return a frame or two off; fit it to the segment.
        for channel in 0..<shifted.count {
            if shifted[channel].count > segment[0].count { shifted[channel] = Array(shifted[channel].prefix(segment[0].count)) }
            while shifted[channel].count < segment[0].count { shifted[channel].append(0) }
        }
        var out = planar
        let ramp = Int(edge * sampleRate)
        for channel in 0..<out.count {
            let lane = min(channel, shifted.count - 1)
            for i in a..<b {
                var mix: Float = 1
                if i - a < ramp { mix = Float(0.5 - 0.5 * cos(Double(i - a) / Double(ramp) * .pi)) }
                if b - i <= ramp { mix = min(mix, Float(0.5 - 0.5 * cos(Double(b - i) / Double(ramp) * .pi))) }
                out[channel][i] = (1 - mix) * planar[channel][i] + mix * shifted[lane][i - from]
            }
        }
        return out
    }

    /// The audio with the span `start..<end` moved by `milliseconds` (negative is earlier), the
    /// vacated and the covered edges crossfaded.
    public static func nudging(_ planar: [[Float]], sampleRate: Double, start: Double, end: Double, milliseconds: Double) -> [[Float]] {
        guard abs(milliseconds) > 0.01, let frames = planar.first?.count, frames > 0 else { return planar }
        let delta = Int(milliseconds / 1000 * sampleRate)
        let a = max(0, Int(start * sampleRate)), b = min(frames, Int(end * sampleRate))
        guard b > a, a + delta >= 0, b + delta <= frames else { return planar }
        let ramp = max(1, Int(edge * sampleRate))
        var out = planar
        for channel in 0..<out.count {
            let source = planar[channel]
            // Fill the whole affected region from the moved segment, and beyond its ends from what
            // was there, with a ramp at each end of the moved segment.
            let lo = min(a, a + delta), hi = max(b, b + delta)
            for i in lo..<hi {
                let j = i - delta   // where this frame came from
                let inside = j >= a && j < b
                var mix: Float = inside ? 1 : 0
                if inside, j - a < ramp { mix = Float(0.5 - 0.5 * cos(Double(j - a) / Double(ramp) * .pi)) }
                if inside, b - j <= ramp { mix = min(mix, Float(0.5 - 0.5 * cos(Double(b - j) / Double(ramp) * .pi))) }
                let moved: Float = inside ? source[j] : 0
                // Where the note was and no longer is, silence — not the note's own tail left behind.
                let vacated = !inside && i >= a && i < b
                let base: Float = vacated ? 0 : source[i]
                out[channel][i] = (1 - mix) * base + mix * moved
            }
        }
        return out
    }
}
