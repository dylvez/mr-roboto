/// A musical interval as a diatonic number (1 = unison, 8 = octave) and quality, with semitone arithmetic and inversion.
public struct Interval: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Interval quality; perfect applies to unisons, fourths, fifths and octaves, major/minor to the rest.
    public enum Quality: String, CaseIterable, Hashable, Codable, Sendable {
        case perfect = "P", major = "M", minor = "m", augmented = "A", diminished = "d"

        /// Quality of the inverted interval (M↔m, A↔d, P↔P).
        public var inverted: Quality {
            switch self {
            case .perfect: return .perfect
            case .major: return .minor
            case .minor: return .major
            case .augmented: return .diminished
            case .diminished: return .augmented
            }
        }

        public var name: String {
            switch self {
            case .perfect: return "Perfect"
            case .major: return "Major"
            case .minor: return "Minor"
            case .augmented: return "Augmented"
            case .diminished: return "Diminished"
            }
        }
    }

    public let number: Int
    public let quality: Quality

    /// Fails when the quality does not fit the number (no "major fifth", no "perfect third") or the number is < 1.
    public init?(number: Int, quality: Quality) {
        guard number >= 1 else { return nil }
        let perfectClass = Interval.isPerfectClass(number)
        switch quality {
        case .perfect where !perfectClass, .major where perfectClass, .minor where perfectClass:
            return nil
        default:
            self.number = number
            self.quality = quality
        }
    }

    private init(unchecked number: Int, _ quality: Quality) {
        self.number = number
        self.quality = quality
    }

    /// The canonical interval for an absolute semitone count (6 → augmented fourth, 12 → octave, 16 → major tenth).
    public init(semitones: Int) {
        let s = abs(semitones)
        if s == 0 { self.init(unchecked: 1, .perfect); return }
        let octaves = (s - 1) / 12
        let remainder = s - 12 * octaves
        let (number, quality) = Interval.simpleTable[remainder - 1]
        self.init(unchecked: number + 7 * octaves, quality)
    }

    private static let simpleTable: [(Int, Quality)] = [
        (2, .minor), (2, .major), (3, .minor), (3, .major), (4, .perfect), (4, .augmented),
        (5, .perfect), (6, .minor), (6, .major), (7, .minor), (7, .major), (8, .perfect),
    ]

    /// Whether intervals of this number take perfect (rather than major/minor) qualities.
    public static func isPerfectClass(_ number: Int) -> Bool {
        let simple = (number - 1) % 7 + 1
        return simple == 1 || simple == 4 || simple == 5
    }

    public var isPerfectClass: Bool { Interval.isPerfectClass(number) }

    /// Semitone span.
    public var semitones: Int {
        let octaves = (number - 1) / 7
        let simple = (number - 1) % 7 + 1
        let base = [0, 2, 4, 5, 7, 9, 11][simple - 1] + 12 * octaves
        switch quality {
        case .perfect, .major: return base
        case .minor: return base - 1
        case .augmented: return base + 1
        case .diminished: return base - (isPerfectClass ? 1 : 2)
        }
    }

    /// True for intervals larger than an octave.
    public var isCompound: Bool { number > 8 }

    /// The interval reduced to within one octave (a tenth becomes a third; octaves stay octaves).
    public var simple: Interval {
        if number <= 8 { return self }
        let reduced = (number - 1) % 7 + 1
        return Interval(unchecked: reduced == 1 ? 8 : reduced, quality)
    }

    /// The inversion of the simple form (M3 → m6, P5 → P4, P8 → P1).
    public var inverted: Interval {
        let s = simple
        let number = s.number == 8 ? 1 : 9 - s.number
        return Interval(unchecked: number, s.quality.inverted)
    }

    /// Compact name such as "M3", "P5", "A4", "d5".
    public var shortName: String { "\(quality.rawValue)\(number)" }

    /// Full name such as "Major third" or "Tritone" for the augmented fourth.
    public var longName: String {
        if number == 4 && quality == .augmented { return "Tritone" }
        return "\(quality.name) \(Interval.ordinalName(number))"
    }

    public var description: String { shortName }

    static func ordinalName(_ number: Int) -> String {
        let names = ["unison", "second", "third", "fourth", "fifth", "sixth", "seventh", "octave",
                     "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth"]
        return number <= names.count ? names[number - 1] : "\(number)th"
    }

    /// The canonical interval spanning two pitches, ignoring direction.
    public static func between(_ a: Pitch, _ b: Pitch) -> Interval {
        Interval(semitones: b.midi - a.midi)
    }

    /// The pitch this interval above `pitch`.
    public func above(_ pitch: Pitch) -> Pitch { pitch + semitones }

    /// The pitch this interval below `pitch`.
    public func below(_ pitch: Pitch) -> Pitch { pitch - semitones }

    public static let unison = Interval(unchecked: 1, .perfect)
    public static let minorSecond = Interval(unchecked: 2, .minor)
    public static let majorSecond = Interval(unchecked: 2, .major)
    public static let minorThird = Interval(unchecked: 3, .minor)
    public static let majorThird = Interval(unchecked: 3, .major)
    public static let perfectFourth = Interval(unchecked: 4, .perfect)
    public static let tritone = Interval(unchecked: 4, .augmented)
    public static let diminishedFifth = Interval(unchecked: 5, .diminished)
    public static let perfectFifth = Interval(unchecked: 5, .perfect)
    public static let minorSixth = Interval(unchecked: 6, .minor)
    public static let majorSixth = Interval(unchecked: 6, .major)
    public static let minorSeventh = Interval(unchecked: 7, .minor)
    public static let majorSeventh = Interval(unchecked: 7, .major)
    public static let octave = Interval(unchecked: 8, .perfect)

    /// The 13 simple intervals from unison to octave, one per semitone (the tritone is spelled A4).
    public static let simpleIntervals: [Interval] = [
        .unison, .minorSecond, .majorSecond, .minorThird, .majorThird, .perfectFourth, .tritone,
        .perfectFifth, .minorSixth, .majorSixth, .minorSeventh, .majorSeventh, .octave,
    ]

    /// Looks up a simple interval by short name ("M3", "P5", "TT" for the tritone).
    public static func named(_ shortName: String) -> Interval? {
        if shortName == "TT" { return .tritone }
        return simpleIntervals.first { $0.shortName == shortName }
    }
}
