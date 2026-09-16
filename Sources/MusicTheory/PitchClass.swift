/// One of the twelve chromatic pitch classes (C = 0 … B = 11); the single source of truth every other type derives from.
public enum PitchClass: Int, CaseIterable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    /// Wraps any integer (a MIDI number, a negative offset, …) into the 0...11 range.
    public init(wrapping value: Int) {
        self.init(rawValue: ((value % 12) + 12) % 12)!
    }

    /// Parses a note name such as "C#", "Db", "F♯", "b♭" or "E".
    public init?(name: String) {
        guard let noteName = NoteName(name) else { return nil }
        self = noteName.pitchClass
    }

    /// True for the five raised keys of the piano octave (C♯ D♯ F♯ G♯ A♯).
    public var isBlackKey: Bool {
        switch self {
        case .cSharp, .dSharp, .fSharp, .gSharp, .aSharp: return true
        default: return false
        }
    }

    /// True for the seven natural (white-key) pitch classes.
    public var isWhiteKey: Bool { !isBlackKey }

    /// The natural letter this pitch class is, if it is a white key.
    public var naturalLetter: Letter? {
        Letter.allCases.first { $0.semitones == rawValue }
    }

    /// The pitch class `semitones` above (or below, if negative) this one.
    public func transposed(by semitones: Int) -> PitchClass {
        PitchClass(wrapping: rawValue + semitones)
    }

    /// Ascending semitone distance from this pitch class up to `other` (0...11).
    public func distance(to other: PitchClass) -> Int {
        ((other.rawValue - rawValue) % 12 + 12) % 12
    }

    /// Signed semitone distance to `other`, folded into -6...5 (the nearer direction).
    public func signedDistance(to other: PitchClass) -> Int {
        let d = distance(to: other)
        return d > 6 ? d - 12 : d
    }

    /// The spelling using the given accidental preference: C♯ vs D♭ for the black keys, naturals otherwise.
    public func spelling(preferring preference: SpellingPreference = .sharps) -> NoteName {
        if let letter = naturalLetter { return NoteName(letter, .natural) }
        switch preference {
        case .sharps:
            return NoteName(Letter.allCases.first { $0.semitones == rawValue - 1 }!, .sharp)
        case .flats:
            return NoteName(Letter.allCases.first { $0.semitones == rawValue + 1 }!, .flat)
        }
    }

    /// Every spelling of this pitch class that uses at most a double accidental, ordered by letter from C.
    public var enharmonicSpellings: [NoteName] {
        Letter.allCases.compactMap { NoteName.spelling(of: self, letter: $0) }
    }

    /// Sharp-preferring name, e.g. "C#".
    public var description: String { spelling(preferring: .sharps).description }

    public static func < (lhs: PitchClass, rhs: PitchClass) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func + (lhs: PitchClass, rhs: Int) -> PitchClass { lhs.transposed(by: rhs) }
    public static func - (lhs: PitchClass, rhs: Int) -> PitchClass { lhs.transposed(by: -rhs) }
}

/// Whether ambiguous black keys are written as sharps (C♯) or flats (D♭).
public enum SpellingPreference: String, Codable, Sendable, Hashable, CaseIterable {
    case sharps, flats
}

/// One of the seven letter names, with its semitone offset above C.
public enum Letter: Int, CaseIterable, Hashable, Codable, Sendable, Comparable {
    case c = 0, d, e, f, g, a, b

    /// Semitones above C for the natural note of this letter.
    public var semitones: Int {
        switch self {
        case .c: return 0
        case .d: return 2
        case .e: return 4
        case .f: return 5
        case .g: return 7
        case .a: return 9
        case .b: return 11
        }
    }

    /// The natural pitch class of this letter.
    public var pitchClass: PitchClass { PitchClass(rawValue: semitones)! }

    /// Upper-case letter character.
    public var character: Character {
        switch self {
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .a: return "A"
        case .b: return "B"
        }
    }

    public init?(character: Character) {
        guard let match = Letter.allCases.first(where: { $0.character == Character(character.uppercased()) }) else { return nil }
        self = match
    }

    /// The letter `steps` letters above this one, wrapping (C + 7 = C).
    public func advanced(by steps: Int) -> Letter {
        Letter(rawValue: ((rawValue + steps) % 7 + 7) % 7)!
    }

    /// Number of letter steps ascending from this letter to `other` (0...6).
    public func steps(to other: Letter) -> Int {
        ((other.rawValue - rawValue) % 7 + 7) % 7
    }

    public static func < (lhs: Letter, rhs: Letter) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An accidental from double flat (−2) to double sharp (+2), as a semitone adjustment.
public enum Accidental: Int, CaseIterable, Hashable, Codable, Sendable, Comparable {
    case doubleFlat = -2, flat, natural, sharp, doubleSharp

    /// Unicode symbol: 𝄫 ♭ (empty) ♯ 𝄪.
    public var symbol: String {
        switch self {
        case .doubleFlat: return "\u{1D12B}"
        case .flat: return "\u{266D}"
        case .natural: return ""
        case .sharp: return "\u{266F}"
        case .doubleSharp: return "\u{1D12A}"
        }
    }

    /// ASCII spelling: bb b (empty) # ##.
    public var asciiSymbol: String {
        switch self {
        case .doubleFlat: return "bb"
        case .flat: return "b"
        case .natural: return ""
        case .sharp: return "#"
        case .doubleSharp: return "##"
        }
    }

    /// Parses "#", "##", "b", "bb", "x", "♯", "♭", "𝄪", "𝄫", "♮" or the empty string.
    public init?(parsing text: Substring) {
        switch text {
        case "", "\u{266E}": self = .natural
        case "#", "\u{266F}": self = .sharp
        case "##", "x", "\u{1D12A}": self = .doubleSharp
        case "b", "\u{266D}": self = .flat
        case "bb", "\u{1D12B}": self = .doubleFlat
        default: return nil
        }
    }

    public static func < (lhs: Accidental, rhs: Accidental) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A spelled note name (letter + accidental) without an octave, such as C♯ or B♭; enharmonics are distinct values.
public struct NoteName: Hashable, Codable, Sendable, CustomStringConvertible {
    public var letter: Letter
    public var accidental: Accidental

    public init(_ letter: Letter, _ accidental: Accidental = .natural) {
        self.letter = letter
        self.accidental = accidental
    }

    public init(letter: Letter, accidental: Accidental = .natural) {
        self.init(letter, accidental)
    }

    /// Parses "C", "C#", "Db", "F##", "Bbb", "C♯", "D♭" (case-insensitive letter).
    public init?(_ text: String) {
        guard let first = text.first, let letter = Letter(character: first) else { return nil }
        guard let accidental = Accidental(parsing: text.dropFirst()) else { return nil }
        self.init(letter, accidental)
    }

    /// The spelling of `pitchClass` on `letter`, or nil if it would need more than a double accidental.
    public static func spelling(of pitchClass: PitchClass, letter: Letter) -> NoteName? {
        let diff = letter.pitchClass.signedDistance(to: pitchClass)
        guard let accidental = Accidental(rawValue: diff) else { return nil }
        return NoteName(letter, accidental)
    }

    /// The pitch class this spelling denotes.
    public var pitchClass: PitchClass {
        PitchClass(wrapping: letter.semitones + accidental.rawValue)
    }

    /// ASCII name, e.g. "C#", "Db".
    public var description: String { "\(letter.character)\(accidental.asciiSymbol)" }

    /// Unicode name, e.g. "C♯", "D♭".
    public var symbolicName: String { "\(letter.character)\(accidental.symbol)" }

    /// The note name whose letter is `letterSteps` higher and whose pitch is `semitones` higher, if spellable.
    public func transposed(letterSteps: Int, semitones: Int) -> NoteName? {
        NoteName.spelling(of: pitchClass.transposed(by: semitones), letter: letter.advanced(by: letterSteps))
    }
}

/// The 17 tonic spellings Apple's Music Understanding reports (A, A♭, A♯, B♭, B, C, C♯, D♭, D, D♯, E♭, E, F, F♯, G, G♭, G♯).
public enum Tonic: String, CaseIterable, Hashable, Codable, Sendable, CustomStringConvertible {
    case a = "A"
    case aFlat = "A\u{266D}"
    case aSharp = "A\u{266F}"
    case bFlat = "B\u{266D}"
    case b = "B"
    case c = "C"
    case cSharp = "C\u{266F}"
    case dFlat = "D\u{266D}"
    case d = "D"
    case dSharp = "D\u{266F}"
    case eFlat = "E\u{266D}"
    case e = "E"
    case f = "F"
    case fSharp = "F\u{266F}"
    case g = "G"
    case gFlat = "G\u{266D}"
    case gSharp = "G\u{266F}"

    /// The spelled note name of this tonic.
    public var noteName: NoteName { NoteName(rawValue)! }

    /// The pitch class of this tonic.
    public var pitchClass: PitchClass { noteName.pitchClass }

    /// Parses either the Unicode raw value ("E♭") or an ASCII form ("Eb").
    public init?(parsing text: String) {
        if let exact = Tonic(rawValue: text) { self = exact; return }
        guard let name = NoteName(text), let match = Tonic(noteName: name) else { return nil }
        self = match
    }

    /// The tonic with exactly this spelling, if it is one of the 17.
    public init?(noteName: NoteName) {
        guard let match = Tonic.allCases.first(where: { $0.noteName == noteName }) else { return nil }
        self = match
    }

    /// The tonic for a pitch class, choosing the sharp or flat member where the set offers both.
    public init(pitchClass: PitchClass, preferring preference: SpellingPreference = .sharps) {
        let candidates = Tonic.allCases.filter { $0.pitchClass == pitchClass }
        let wanted: Accidental = preference == .sharps ? .sharp : .flat
        self = candidates.first { $0.noteName.accidental == wanted }
            ?? candidates.first { $0.noteName.accidental == .natural }
            ?? candidates[0]
    }

    public var description: String { rawValue }
}
