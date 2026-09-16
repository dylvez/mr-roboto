#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Twelve-tone equal temperament: conversions between MIDI numbers, frequencies and cents.
public enum EqualTemperament {
    /// MIDI number of concert A.
    public static let a4Midi = 69
    /// Default concert pitch in hertz.
    public static let defaultA4: Double = 440
    /// Frequency ratio of one semitone (2^(1/12)).
    public static let semitoneRatio: Double = exp2(1.0 / 12.0)

    /// Frequency of a (possibly fractional) MIDI number.
    public static func frequency(midi: Double, a4: Double = defaultA4) -> Double {
        a4 * exp2((midi - Double(a4Midi)) / 12)
    }

    /// Fractional MIDI number of a frequency (69.0 for A4); frequencies ≤ 0 are clamped to a tiny positive value.
    public static func midi(frequency: Double, a4: Double = defaultA4) -> Double {
        Double(a4Midi) + 12 * log2(max(1e-3, frequency) / a4)
    }

    /// Signed cents from one frequency to another (1200 per octave).
    public static func cents(from: Double, to: Double) -> Double {
        1200 * log2(to / from)
    }

    /// Frequency ratio corresponding to a cents value.
    public static func ratio(cents: Double) -> Double {
        exp2(cents / 1200)
    }

    /// Cents of a frequency ratio.
    public static func cents(ratio: Double) -> Double {
        1200 * log2(ratio)
    }
}

/// A just-intonation interval as a reduced small-integer frequency ratio (3:2, 5:4 …), with cents and the harmonic series.
public struct JustInterval: Hashable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    /// Creates the ratio numerator:denominator, reduced to lowest terms. Both must be positive.
    public init(_ numerator: Int, _ denominator: Int) {
        precondition(numerator > 0 && denominator > 0, "JustInterval ratios must be positive")
        let g = JustInterval.gcd(numerator, denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    /// The ratio as a Double (1.5 for 3:2).
    public var ratio: Double { Double(numerator) / Double(denominator) }

    /// Size in cents (701.955 for 3:2).
    public var cents: Double { EqualTemperament.cents(ratio: ratio) }

    /// The nearest equal-tempered interval.
    public var nearestInterval: Interval {
        Interval(semitones: Int((cents / 100).rounded()))
    }

    /// Signed cents by which this ratio differs from its nearest equal-tempered interval (+1.955 for 3:2).
    public var centsFromEqualTemperament: Double {
        cents - Double(nearestInterval.semitones * 100)
    }

    /// The same ratio folded into the octave [1, 2): the 5th harmonic 5:1 becomes 5:4.
    public var reducedToOctave: JustInterval {
        var n = numerator, d = denominator
        while n >= 2 * d { d *= 2 }
        while n < d { n *= 2 }
        return JustInterval(n, d)
    }

    /// The octave complement (3:2 → 4:3).
    public var inverted: JustInterval {
        let r = reducedToOctave
        return JustInterval(2 * r.denominator, r.numerator)
    }

    /// The frequency this ratio above `base`.
    public func frequency(above base: Double) -> Double { base * ratio }

    /// Stacks two ratios (3:2 × 4:3 = 2:1).
    public static func * (lhs: JustInterval, rhs: JustInterval) -> JustInterval {
        JustInterval(lhs.numerator * rhs.numerator, lhs.denominator * rhs.denominator)
    }

    /// Ratio "3:2".
    public var description: String { "\(numerator):\(denominator)" }

    /// Historical name where one exists (unison, octave, perfect fifth, …).
    public var name: String? {
        JustInterval.named.first { $0.interval == self }?.name
    }

    public static let unison = JustInterval(1, 1)
    public static let octave = JustInterval(2, 1)
    public static let perfectFifth = JustInterval(3, 2)
    public static let perfectFourth = JustInterval(4, 3)
    public static let majorThird = JustInterval(5, 4)
    public static let minorThird = JustInterval(6, 5)
    public static let majorSixth = JustInterval(5, 3)
    public static let minorSixth = JustInterval(8, 5)
    public static let tritone = JustInterval(7, 5)
    public static let majorSecond = JustInterval(9, 8)
    public static let minorSecond = JustInterval(16, 15)
    public static let majorSeventh = JustInterval(15, 8)
    public static let minorSeventh = JustInterval(9, 5)
    public static let harmonicSeventh = JustInterval(7, 4)

    private static let named: [(interval: JustInterval, name: String)] = [
        (.unison, "Unison"), (.octave, "Octave"), (.perfectFifth, "Perfect fifth"),
        (.perfectFourth, "Perfect fourth"), (.majorThird, "Major third"), (.minorThird, "Minor third"),
        (.majorSixth, "Major sixth"), (.minorSixth, "Minor sixth"), (.tritone, "Tritone"),
        (.majorSecond, "Major second"), (.minorSecond, "Minor second"), (.majorSeventh, "Major seventh"),
        (.minorSeventh, "Minor seventh"), (.harmonicSeventh, "Harmonic seventh"),
    ]

    /// The eight ratios of the harmonograph palette: 1:1, 2:1, 3:2, 4:3, 5:4, 5:3, 6:5, 7:5.
    public static let harmonographIntervals: [JustInterval] = [
        .unison, .octave, .perfectFifth, .perfectFourth, .majorThird, .majorSixth, .minorThird, .tritone,
    ]

    /// The n-th harmonic as the ratio n:1 above the fundamental.
    public static func harmonic(_ n: Int) -> JustInterval { JustInterval(n, 1) }

    /// The first `count` harmonics (1:1, 2:1, 3:1, …).
    public static func harmonicSeries(count: Int) -> [JustInterval] {
        (1...max(1, count)).map { harmonic($0) }
    }

    /// The senario 1:2:3:4:5:6 of the harmonices orrery, as ratios above the fundamental.
    public static let senario = harmonicSeries(count: 6)

    /// Ratios of each term of an integer chord (4:5:6 → 1:1, 5:4, 3:2) relative to its first term.
    public static func ratios(_ terms: [Int]) -> [JustInterval] {
        guard let first = terms.first else { return [] }
        return terms.map { JustInterval($0, first) }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}
