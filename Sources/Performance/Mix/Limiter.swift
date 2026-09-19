import Foundation

// M6 X2: the ceiling. A lookahead peak limiter over rendered audio — a bounce, an export — so the
// live transport stays sample-exact and the delivery never goes over the line.

public enum Limiter {
    /// Lookahead, seconds: the gain is down before the peak arrives.
    public static let lookahead = 0.002
    /// Release, seconds.
    public static let release = 0.08
    /// Head room under the ceiling for the inter-sample peaks the sample-domain detector misses.
    public static let headroomDB = 0.3

    /// The audio with no sample over `ceilingDBTP − headroom`, gain ridden down ahead of every
    /// peak and released over `release`. Untouched where it was already under.
    public static func apply(_ planar: [[Float]], sampleRate: Double, ceilingDBTP: Double) -> [[Float]] {
        guard let frames = planar.first?.count, frames > 0 else { return planar }
        let ceiling = Float(pow(10, (ceilingDBTP - headroomDB) / 20))
        let look = max(1, Int(lookahead * sampleRate))
        let releaseCoefficient = Float(exp(-1 / (release * sampleRate)))
        // The gain needed at every frame: ceiling over the loudest channel's peak, ≤ 1.
        var needed = [Float](repeating: 1, count: frames)
        for i in 0..<frames {
            var peak: Float = 0
            for lane in planar { peak = max(peak, abs(lane[i])) }
            if peak > ceiling { needed[i] = ceiling / peak }
        }
        // Lookahead: the gain at i is the minimum needed over the next `look` frames, so it is
        // down when the peak lands; then a one-pole release back up.
        var gain = [Float](repeating: 1, count: frames)
        var window = [Float](repeating: 1, count: look + 1)
        var envelope: Float = 1
        for i in 0..<frames {
            // Minimum of needed[i ..< i + look], computed with a small ring.
            var minimum: Float = 1
            for k in 0...look where i + k < frames { minimum = min(minimum, needed[i + k]) }
            if minimum < envelope { envelope = minimum } else { envelope = minimum + (envelope - minimum) * releaseCoefficient }
            gain[i] = envelope
            _ = window
        }
        window = []
        var out = planar
        for c in 0..<out.count {
            for i in 0..<frames { out[c][i] = planar[c][i] * gain[i] }
        }
        return out
    }
}
