/// The catalog of chord qualities (triads, suspensions and sevenths) as semitone offsets above the root.
public enum ChordQuality: String, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case major, minor, diminished, augmented
    case suspendedSecond, suspendedFourth
    case majorSeventh, dominantSeventh, minorSeventh, halfDiminishedSeventh, diminishedSeventh
    case minorMajorSeventh, augmentedMajorSeventh

    /// Semitone offsets above the root.
    public var intervals: [Int] {
        switch self {
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
        }
    }

    /// True when the chord contains a minor third above the root (rendered lower-case in Roman numerals).
    public var hasMinorThird: Bool { intervals.contains(3) }

    public var isTriad: Bool { intervals.count == 3 }
    public var isSeventh: Bool { intervals.count == 4 }
    public var isSuspended: Bool { self == .suspendedSecond || self == .suspendedFourth }

    /// The triad a seventh chord is built on (major7 → major, half-diminished → diminished); triads return themselves.
    public var triad: ChordQuality {
        guard isSeventh else { return self }
        return ChordQuality(intervals: Array(intervals.prefix(3))) ?? .major
    }

    /// The quality with exactly these offsets (order-insensitive, root must be 0), if catalogued.
    public init?(intervals: [Int]) {
        let wanted = intervals.map { ($0 % 12 + 12) % 12 }.sorted()
        guard let match = ChordQuality.allCases.first(where: { $0.intervals == wanted }) else { return nil }
        self = match
    }

    /// The four triads plus the two suspensions.
    public static let triads: [ChordQuality] = allCases.filter(\.isTriad)
    /// The seven catalogued seventh chords.
    public static let sevenths: [ChordQuality] = allCases.filter(\.isSeventh)

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

    /// Every root-position chord whose tone set equals `pitchClasses` (C sus2 and G sus4 both match {C, D, G}).
    public static func identify(_ pitchClasses: Set<PitchClass>) -> [Chord] {
        var found: [Chord] = []
        for root in PitchClass.allCases where pitchClasses.contains(root) {
            for quality in ChordQuality.allCases {
                let chord = Chord(root: root, quality: quality)
                if chord.matches(pitchClasses) { found.append(chord) }
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
