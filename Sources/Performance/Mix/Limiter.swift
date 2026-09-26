import Foundation

// M6 X2: the ceiling. A lookahead peak limiter over rendered audio — a bounce, an export — so the
// live transport stays sample-exact and the delivery never goes over the line.

public enum Limiter {
    /// Lookahead, seconds: the gain is down before the peak arrives.
    public static let lookahead = 0.002
    /// Release, seconds.
    public static let release = 0.08
    /// Head room under the ceiling, over a true-peak detector: a tenth of a dB for the rounding.
    public static let headroomDB = 0.1

    /// The audio with no sample over `ceilingDBTP − headroom`, gain ridden down ahead of every
    /// peak and released over `release`. Untouched where it was already under.
    public static func apply(_ planar: [[Float]], sampleRate: Double, ceilingDBTP: Double) -> [[Float]] {
        guard let frames = planar.first?.count, frames > 0 else { return planar }
        let ceiling = Float(pow(10, (ceilingDBTP - headroomDB) / 20))
        let look = max(1, Int(lookahead * sampleRate))
        let releaseCoefficient = Float(exp(-1 / (release * sampleRate)))
        // The gain needed at every frame: ceiling over the true peak between this frame and the
        // next (4× oversampled), ≤ 1. Sample peaks alone let inter-sample peaks over the line.
        let truePeaks = MixMeter.truePeakEnvelope(planar)
        var needed = [Float](repeating: 1, count: frames)
        for i in 0..<frames {
            var peak = truePeaks[i]
            for lane in planar { peak = max(peak, abs(lane[i])) }
            if peak > ceiling { needed[i] = ceiling / peak }
        }
        // Lookahead: the gain at i is the minimum needed over needed[i ... i + look], so it is down
        // when the peak lands; then a one-pole release back up.
        //
        // The minimum slides with the window on a ring of candidate indices, each needing less
        // than the ones after it, so every frame goes in and comes out once. It used to be scanned
        // afresh at every frame — `look` is 240 at 48 kHz — and a three-minute master spent over a
        // minute here before it was written.
        var gain = [Float](repeating: 1, count: frames)
        let capacity = look + 2
        var ring = [Int](repeating: 0, count: capacity)
        var head = 0, count = 0
        func push(_ index: Int) {
            while count > 0, needed[ring[(head + count - 1) % capacity]] >= needed[index] { count -= 1 }
            ring[(head + count) % capacity] = index
            count += 1
        }
        for index in 0..<min(look, frames) { push(index) }
        var envelope: Float = 1
        for i in 0..<frames {
            if i + look < frames { push(i + look) }
            while count > 0, ring[head] < i { head = (head + 1) % capacity; count -= 1 }
            let minimum = count > 0 ? min(1, needed[ring[head]]) : 1
            if minimum < envelope { envelope = minimum } else { envelope = minimum + (envelope - minimum) * releaseCoefficient }
            gain[i] = envelope
        }
        var out = planar
        for c in 0..<out.count {
            for i in 0..<frames { out[c][i] = planar[c][i] * gain[i] }
        }
        return out
    }
}
