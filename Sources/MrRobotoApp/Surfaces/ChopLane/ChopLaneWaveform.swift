import Foundation

/// The peak envelope a waveform is drawn from, and the time/pixel arithmetic the lane's gestures
/// need. Pure and `nonisolated` so it can be computed off the main actor and checked without a view.
public enum ChopLaneWaveform {

    /// Minimum and maximum sample per horizontal pixel column.
    ///
    /// Min/max rather than RMS, because a chop lane is read for *transients*: an RMS envelope
    /// smooths away the very edges a marker has to be dragged onto.
    public struct Column: Hashable, Sendable {
        public var minimum: Float
        public var maximum: Float

        public init(minimum: Float, maximum: Float) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    /// `buckets` columns of peak envelope over `signal`, normalised so the loudest column fills
    /// the plate. A silent bar draws as a flat line rather than dividing by zero.
    public static func envelope(_ signal: [Float], buckets: Int) -> [Column] {
        guard buckets > 0, !signal.isEmpty else { return [] }
        var columns: [Column] = []
        columns.reserveCapacity(buckets)
        var loudest: Float = 0
        for bucket in 0..<buckets {
            let lo = signal.count * bucket / buckets
            let hi = max(lo + 1, signal.count * (bucket + 1) / buckets)
            var minimum: Float = 0
            var maximum: Float = 0
            for i in lo..<min(hi, signal.count) {
                let x = signal[i]
                if x < minimum { minimum = x }
                if x > maximum { maximum = x }
            }
            loudest = max(loudest, max(-minimum, maximum))
            columns.append(Column(minimum: minimum, maximum: maximum))
        }
        guard loudest > 0 else { return columns }
        return columns.map { Column(minimum: $0.minimum / loudest, maximum: $0.maximum / loudest) }
    }

    /// Seconds at a horizontal position.
    public static func time(atX x: Double, width: Double, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, x / width), 1) * duration
    }

    /// Horizontal position of a time.
    public static func x(atTime time: Double, width: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(0, time / duration), 1) * width
    }
}
