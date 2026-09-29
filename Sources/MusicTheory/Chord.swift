/// The catalog of chord qualities as semitone offsets above the root: triads, suspensions and
/// sevenths, and then what a lead sheet adds to them — sixths, ninths, elevenths, thirteenths, added
/// and altered notes.
///
/// The first thirteen are `basic`, and were the whole catalog. The rest are appended after them, so
/// anything that looks a quality up from its notes still finds a triad or a seventh first.
public enum ChordQuality: String, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case major, minor, diminished, augmented
    case suspendedSecond, suspendedFourth
    case majorSeventh, dominantSeventh, minorSeventh, halfDiminishedSeventh, diminishedSeventh
    case minorMajorSeventh, augmentedMajorSeventh
    case sixth, minorSixth, sixNine, minorSixNine
    case addNine, minorAddNine
    case majorNinth, dominantNinth, minorNinth
    case dominantEleventh, minorEleventh, majorSevenSharpEleven
    case majorThirteenth, dominantThirteenth, minorThirteenth
    case sevenFlatNine, sevenSharpNine, sevenSharpEleven, sevenFlatThirteen
    case sevenSharpFive, sevenFlatFive
    case sevenSuspendedFourth, nineSuspendedFourth
    case power

    /// Semitone offsets above the root, in the order the chord is stacked: a ninth is 14, above
    /// the seventh, not 2, beside the root.
    public var intervals: [Int] {
        switch self {
        case .sixth: return [0, 4, 7, 9]
        case .minorSixth: return [0, 3, 7, 9]
        case .sixNine: return [0, 4, 7, 9, 14]
        case .minorSixNine: return [0, 3, 7, 9, 14]
        case .addNine: return [0, 4, 7, 14]
        case .minorAddNine: return [0, 3, 7, 14]
        case .majorNinth: return [0, 4, 7, 11, 14]
        case .dominantNinth: return [0, 4, 7, 10, 14]
        case .minorNinth: return [0, 3, 7, 10, 14]
        // No third: under an eleventh it is the note that fights it.
        case .dominantEleventh: return [0, 7, 10, 14, 17]
        case .minorEleventh: return [0, 3, 7, 10, 14, 17]
        case .majorSevenSharpEleven: return [0, 4, 7, 11, 18]
        case .majorThirteenth: return [0, 4, 7, 11, 14, 21]
        case .dominantThirteenth: return [0, 4, 7, 10, 14, 21]
        case .minorThirteenth: return [0, 3, 7, 10, 14, 21]
        case .sevenFlatNine: return [0, 4, 7, 10, 13]
        case .sevenSharpNine: return [0, 4, 7, 10, 15]
        case .sevenSharpEleven: return [0, 4, 7, 10, 18]
        case .sevenFlatThirteen: return [0, 4, 7, 10, 20]
        case .sevenSharpFive: return [0, 4, 8, 10]
        case .sevenFlatFive: return [0, 4, 6, 10]
        case .sevenSuspendedFourth: return [0, 5, 7, 10]
        case .nineSuspendedFourth: return [0, 5, 7, 10, 14]
        case .power: return [0, 7]
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .suspendedSecond: return [0, 2, 7]
        case .suspendedFourth: return [0, 5, 7]
        case .majorSeventh: return [0, 4, 7, 11]
        case .dominantSeventh: return [0, 4, 7, 10]
        case .minorSeventh: return [0, 3, 7, 10]
        case .halfDiminishedSeventh: return [0, 3, 6, 10]
        case .diminishedSeventh: return [0, 3, 6, 9]
        case .minorMajorSeventh: return [0, 3, 7, 11]
        case .augmentedMajorSeventh: return [0, 4, 8, 11]
        }
    }

    /// Letter steps above the root letter for each chord tone (thirds stack 0, 2, 4, 6; suspensions replace the third).
    public var letterSteps: [Int] {
        switch self {
        case .suspendedSecond: return [0, 1, 4]
        case .suspendedFourth: return [0, 3, 4]
        case .sixth, .minorSixth: return [0, 2, 4, 5]
        case .sixNine, .minorSixNine: return [0, 2, 4, 5, 8]
        case .addNine, .minorAddNine: return [0, 2, 4, 8]
        case .dominantEleventh: return [0, 4, 6, 8, 10]
        case .majorSevenSharpEleven, .sevenSharpEleven: return [0, 2, 4, 6, 10]
        case .majorThirteenth, .dominantThirteenth, .minorThirteenth: return [0, 2, 4, 6, 8, 12]
        case .sevenFlatThirteen: return [0, 2, 4, 6, 12]
        case .sevenSuspendedFourth: return [0, 3, 4, 6]
        case .nineSuspendedFourth: return [0, 3, 4, 6, 8]
        case .power: return [0, 4]
        default: return Array(stride(from: 0, to: 2 * intervals.count, by: 2))
        }
    }

    /// Chord-symbol suffix: "", "m", "dim", "aug", "sus2", "sus4", "maj7", "7", "m7", "m7b5", "dim7", "mMaj7", "augMaj7".
    public var symbol: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .suspendedSecond: return "sus2"
        case .suspendedFourth: return "sus4"
        case .majorSeventh: return "maj7"
        case .dominantSeventh: return "7"
        case .minorSeventh: return "m7"
        case .halfDiminishedSeventh: return "m7b5"
        case .diminishedSeventh: return "dim7"
        case .minorMajorSeventh: return "mMaj7"
        case .augmentedMajorSeventh: return "augMaj7"
        case .sixth: return "6"
        case .minorSixth: return "m6"
        case .sixNine: return "6/9"
        case .minorSixNine: return "m6/9"
        case .addNine: return "add9"
        case .minorAddNine: return "madd9"
        case .majorNinth: return "maj9"
        case .dominantNinth: return "9"
        case .minorNinth: return "m9"
        case .dominantEleventh: return "11"
        case .minorEleventh: return "m11"
        case .majorSevenSharpEleven: return "maj7#11"
        case .majorThirteenth: return "maj13"
        case .dominantThirteenth: return "13"
        case .minorThirteenth: return "m13"
        case .sevenFlatNine: return "7b9"
        case .sevenSharpNine: return "7#9"
        case .sevenSharpEleven: return "7#11"
        case .sevenFlatThirteen: return "7b13"
        case .sevenSharpFive: return "7#5"
        case .sevenFlatFive: return "7b5"
        case .sevenSuspendedFourth: return "7sus4"
        case .nineSuspendedFourth: return "9sus4"
        case .power: return "5"
        }
    }

    /// Display name such as "Major", "Half-Diminished 7th".
    public var name: String {
        switch self {
        case .major: return "Major"
        case .minor: return "Minor"
        case .diminished: return "Diminished"
        case .augmented: return "Augmented"
        case .suspendedSecond: return "Suspended 2nd"
        case .suspendedFourth: return "Suspended 4th"
        case .majorSeventh: return "Major 7th"
        case .dominantSeventh: return "Dominant 7th"
        case .minorSeventh: return "Minor 7th"
        case .halfDiminishedSeventh: return "Half-Diminished 7th"
        case .diminishedSeventh: return "Diminished 7th"
        case .minorMajorSeventh: return "Minor-Major 7th"
        case .augmentedMajorSeventh: return "Augmented Major 7th"
        case .sixth: return "6th"
        case .minorSixth: return "Minor 6th"
        case .sixNine: return "6/9"
        case .minorSixNine: return "Minor 6/9"
        case .addNine: return "Added 9th"
        case .minorAddNine: return "Minor Added 9th"
        case .majorNinth: return "Major 9th"
        case .dominantNinth: return "Dominant 9th"
        case .minorNinth: return "Minor 9th"
        case .dominantEleventh: return "Dominant 11th"
        case .minorEleventh: return "Minor 11th"
        case .majorSevenSharpEleven: return "Major 7th Sharp 11th"
        case .majorThirteenth: return "Major 13th"
        case .dominantThirteenth: return "Dominant 13th"
        case .minorThirteenth: return "Minor 13th"
        case .sevenFlatNine: return "7th Flat 9th"
        case .sevenSharpNine: return "7th Sharp 9th"
        case .sevenSharpEleven: return "7th Sharp 11th"
        case .sevenFlatThirteen: return "7th Flat 13th"
        case .sevenSharpFive: return "7th Sharp 5th"
        case .sevenFlatFive: return "7th Flat 5th"
        case .sevenSuspendedFourth: return "7th Suspended 4th"
        case .nineSuspendedFourth: return "9th Suspended 4th"
        case .power: return "5th"
        }
    }

    /// Suffix used after a Roman numeral: "°", "+", "7", "maj7", "ø7", "°7", "M7", "+maj7", "sus2", "sus4".
    public var numeralSuffix: String {
        switch self {
        case .major, .minor: return ""
        case .diminished: return "\u{00B0}"
        case .augmented: return "+"
        case .suspendedSecond: return "sus2"
        case .suspendedFourth: return "sus4"
        case .majorSeventh: return "maj7"
        case .dominantSeventh, .minorSeventh: return "7"
        case .halfDiminishedSeventh: return "\u{00F8}7"
        case .diminishedSeventh: return "\u{00B0}7"
        case .minorMajorSeventh: return "M7"
        case .augmentedMajorSeventh: return "+maj7"
        // The case of the numeral says minor; the suffix says the rest.
        case .sixth, .minorSixth: return "6"
        case .sixNine, .minorSixNine: return "6/9"
        case .addNine, .minorAddNine: return "add9"
        case .majorNinth: return "maj9"
        case .dominantNinth, .minorNinth: return "9"
        case .dominantEleventh, .minorEleventh: return "11"
        case .majorSevenSharpEleven: return "maj7\u{266F}11"
        case .majorThirteenth: return "maj13"
        case .dominantThirteenth, .minorThirteenth: return "13"
        case .sevenFlatNine: return "7\u{266D}9"
        case .sevenSharpNine: return "7\u{266F}9"
        case .sevenSharpEleven: return "7\u{266F}11"
        case .sevenFlatThirteen: return "7\u{266D}13"
        case .sevenSharpFive: return "7\u{266F}5"
        case .sevenFlatFive: return "7\u{266D}5"
        case .sevenSuspendedFourth: return "7sus4"
        case .nineSuspendedFourth: return "9sus4"
        case .power: return "5"
        }
    }

    /// True when the chord contains a minor third above the root (rendered lower-case in Roman numerals).
    public var hasMinorThird: Bool { intervals.contains(3) }

    /// The triads, suspensions and sevenths: what the catalog was before it had extensions, and
    /// what a chord is read as first when its notes could be named two ways — A C E G under a C
    /// is A minor seventh over its third before it is a C sixth.
    public static let basic: [ChordQuality] = [
        .major, .minor, .diminished, .augmented, .suspendedSecond, .suspendedFourth,
        .majorSeventh, .dominantSeventh, .minorSeventh, .halfDiminishedSeventh, .diminishedSeventh,
        .minorMajorSeventh, .augmentedMajorSeventh,
    ]

    public var isTriad: Bool { ChordQuality.triads.contains(self) }
    public var isSeventh: Bool { ChordQuality.sevenths.contains(self) }
    public var isSuspended: Bool {
        [.suspendedSecond, .suspendedFourth, .sevenSuspendedFourth, .nineSuspendedFourth].contains(self)
    }
    /// Whether the chord is one of those past the sevenths: a sixth, a ninth, an altered dominant.
    public var isExtended: Bool { !ChordQuality.basic.contains(self) }

    /// The seventh in the chord, as semitones above the root, when it has one: 10 or 11, or the
    /// diminished seventh's 9.
    public var seventh: Int? {
        if self == .diminishedSeventh { return 9 }
        return intervals.first { $0 == 10 || $0 == 11 }
    }

    /// The third, or the note a suspension puts in its place. Nil for a bare fifth, and for an
    /// eleventh, which leaves it out.
    public var third: Int? {
        intervals.first { $0 == 3 || $0 == 4 } ?? (isSuspended ? intervals.first { $0 == 2 || $0 == 5 } : nil)
    }

    /// The triad a chord is built on (major7 → major, half-diminished → diminished, minor ninth →
    /// minor); triads return themselves. A chord with no triad under it — a bare fifth, a seventh
    /// with a flattened fifth — answers major.
    public var triad: ChordQuality {
        if isTriad { return self }
        let fifth = intervals.first { (6...8).contains($0) } ?? 7
        guard let third else { return .major }
        return ChordQuality(intervals: [0, third, fifth], among: ChordQuality.triads) ?? .major
    }

    /// The quality with exactly these offsets (order-insensitive, octaves ignored, root must be 0),
    /// if catalogued: the first of `among` that has them.
    public init?(intervals: [Int], among qualities: [ChordQuality] = ChordQuality.allCases) {
        func folded(_ offsets: [Int]) -> [Int] { Array(Set(offsets.map { ($0 % 12 + 12) % 12 })).sorted() }
        let wanted = folded(intervals)
        guard let match = qualities.first(where: { folded($0.intervals) == wanted }) else { return nil }
        self = match
    }

    /// The four triads plus the two suspensions.
    public static let triads: [ChordQuality] = [.major, .minor, .diminished, .augmented, .suspendedSecond, .suspendedFourth]
    /// The seven catalogued seventh chords.
    public static let sevenths: [ChordQuality] = [
        .majorSeventh, .dominantSeventh, .minorSeventh, .halfDiminishedSeventh, .diminishedSeventh,
        .minorMajorSeventh, .augmentedMajorSeventh,
    ]

    public var description: String { name }
}

/// A chord: root pitch class, quality and inversion, from which pitch classes, voiced pitches and symbols derive.
public struct Chord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var root: PitchClass
    public var quality: ChordQuality
    /// 0 = root position, 1 = first inversion, … (capped at the number of chord tones when voicing).
    public var inversion: Int

    public init(root: PitchClass, quality: ChordQuality, inversion: Int = 0) {
        self.root = root
        self.quality = quality
        self.inversion = max(0, inversion)
    }

    public init(_ root: PitchClass, _ quality: ChordQuality) {
        self.init(root: root, quality: quality)
    }

    /// Semitone offsets above the root (root position).
    public var intervals: [Int] { quality.intervals }

    /// Chord tones in root-position order.
    public var pitchClasses: [PitchClass] { intervals.map { root.transposed(by: $0) } }

    /// Chord tones as a set, for matching.
    public var pitchClassSet: Set<PitchClass> { Set(pitchClasses) }

    /// The lowest chord tone after inversion.
    public var bass: PitchClass { pitchClasses[min(inversion, pitchClasses.count - 1) % pitchClasses.count] }

    /// Voiced pitches with the root in `octave`, then each inversion moves the lowest note up an octave.
    public func pitches(octave: Int) -> [Pitch] {
        var notes = intervals.map { Pitch(root, octave: octave) + $0 }
        for _ in 0..<min(inversion, notes.count) {
            let bottom = notes.removeFirst()
            notes.append(bottom + 12)
        }
        return notes
    }

    /// Voiced pitches with the root at `rootPitch`, inverted as above.
    public func pitches(root rootPitch: Pitch) -> [Pitch] {
        var chord = self
        chord.root = rootPitch.pitchClass
        return chord.pitches(octave: rootPitch.octave)
    }

    /// The same chord in inversion `n`.
    public func inverted(_ n: Int) -> Chord { Chord(root: root, quality: quality, inversion: n) }

    /// The chord transposed by `semitones`.
    public func transposed(by semitones: Int) -> Chord {
        Chord(root: root.transposed(by: semitones), quality: quality, inversion: inversion)
    }

    /// True when `pitchClasses` is exactly this chord's tone set (any voicing, any octave, no extras or omissions).
    public func matches(_ pitchClasses: Set<PitchClass>) -> Bool { pitchClasses == pitchClassSet }

    /// True when the pitches, reduced to pitch classes, are exactly this chord's tones.
    public func matches(_ pitches: [Pitch]) -> Bool { matches(Set(pitches.map(\.pitchClass))) }

    /// Every root-position chord whose tone set equals `pitchClasses` (C sus2 and G sus4 both match
    /// {C, D, G}), the triads and sevenths before the chords past them.
    public static func identify(_ pitchClasses: Set<PitchClass>) -> [Chord] {
        var found: [Chord] = []
        for qualities in [ChordQuality.basic, ChordQuality.allCases.filter(\.isExtended)] {
            for root in PitchClass.allCases where pitchClasses.contains(root) {
                for quality in qualities {
                    let chord = Chord(root: root, quality: quality)
                    if chord.matches(pitchClasses) { found.append(chord) }
                }
            }
        }
        return found
    }

    /// Chord symbol such as "C#m7" or, when inverted, a slash chord such as "C/E".
    public func symbol(preferring preference: SpellingPreference = .sharps) -> String {
        var text = root.spelling(preferring: preference).description + quality.symbol
        if inversion > 0 { text += "/" + bass.spelling(preferring: preference).description }
        return text
    }

    /// Long name such as "C# Minor 7th".
    public func name(preferring preference: SpellingPreference = .sharps) -> String {
        "\(root.spelling(preferring: preference)) \(quality.name)"
    }

    public var description: String { symbol() }
}

/// A Roman-numeral chord label: degree, accidental prefix and quality (case and suffix derive from the quality).
public struct RomanNumeral: Hashable, Codable, Sendable, CustomStringConvertible {
    /// One-based scale degree, 1...7.
    public var degree: Int
    /// Accidental applied to the degree relative to the reference scale (♭ in ♭VII).
    public var accidental: Accidental
    public var quality: ChordQuality

    public init(degree: Int, quality: ChordQuality, accidental: Accidental = .natural) {
        self.degree = ((degree - 1) % 7 + 7) % 7 + 1
        self.quality = quality
        self.accidental = accidental
    }

    private static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]

    /// Rendered numeral such as "I", "ii", "vii°", "V7", "Imaj7", "♭III+", "iiø7".
    public var description: String {
        let base = RomanNumeral.numerals[degree - 1]
        let cased = quality.hasMinorThird ? base.lowercased() : base
        return accidental.symbol + cased + quality.numeralSuffix
    }
}
