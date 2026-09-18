import Foundation

// Chord symbols as people type them: "Dm7", "G7", "C#m7b5", "Bbmaj7", "F/A".

extension ChordQuality {
    /// Every spelling of a quality a lead sheet is likely to carry, longest first so "maj7" is not
    /// read as "ma" + "j7". The canonical `symbol` is always among them.
    static let spellings: [(String, ChordQuality)] = [
        ("augMaj7", .augmentedMajorSeventh), ("+maj7", .augmentedMajorSeventh),
        ("mMaj7", .minorMajorSeventh), ("mmaj7", .minorMajorSeventh), ("m(maj7)", .minorMajorSeventh), ("minMaj7", .minorMajorSeventh),
        ("m7b5", .halfDiminishedSeventh), ("ø7", .halfDiminishedSeventh), ("ø", .halfDiminishedSeventh), ("min7b5", .halfDiminishedSeventh),
        ("dim7", .diminishedSeventh), ("°7", .diminishedSeventh), ("o7", .diminishedSeventh),
        ("maj7", .majorSeventh), ("Maj7", .majorSeventh), ("M7", .majorSeventh), ("Δ7", .majorSeventh), ("Δ", .majorSeventh), ("ma7", .majorSeventh),
        ("min7", .minorSeventh), ("m7", .minorSeventh), ("-7", .minorSeventh),
        ("sus2", .suspendedSecond), ("sus4", .suspendedFourth), ("sus", .suspendedFourth),
        ("dim", .diminished), ("°", .diminished), ("o", .diminished),
        ("aug", .augmented), ("+", .augmented),
        ("min", .minor), ("m", .minor), ("-", .minor),
        ("maj", .major), ("M", .major), ("7", .dominantSeventh), ("dom7", .dominantSeventh),
        ("", .major),
    ]
}

extension Chord {
    /// Parses a chord symbol: a root, a quality suffix, and optionally a slash bass that sets the
    /// inversion when it is a chord tone. Nil for anything it cannot read, so a typo is a typo and
    /// not a C major.
    ///
    ///     Chord(parsing: "Dm7")   == Chord(.d, .minorSeventh)
    ///     Chord(parsing: "C/E")   == Chord(root: .c, quality: .major, inversion: 1)
    ///     Chord(parsing: "Ebmaj7") == Chord(.dSharp, .majorSeventh)
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var body = Substring(trimmed)
        var bassText: Substring?
        if let slash = body.firstIndex(of: "/") {
            bassText = body[body.index(after: slash)...]
            body = body[..<slash]
        }
        // The root: a letter and up to two accidentals.
        guard let first = body.first, let letter = Letter(parsing: first) else { return nil }
        var rest = body.dropFirst()
        var accidental = Accidental.natural
        for candidate in ["##", "bb", "#", "b", "♯", "♭", "x"] where rest.hasPrefix(candidate) {
            // "b" is also the start of no quality, so only take it as a flat when what follows is
            // not a quality that begins with the same letters ("bmaj7" would be nonsense anyway).
            if let parsed = Accidental(parsing: Substring(candidate)) {
                accidental = parsed
                rest = rest.dropFirst(candidate.count)
            }
            break
        }
        let root = NoteName(letter: letter, accidental: accidental).pitchClass

        // The quality: the longest spelling that matches what is left, exactly.
        let suffix = String(rest)
        guard let quality = ChordQuality.spellings.first(where: { $0.0 == suffix })?.1 else { return nil }
        var chord = Chord(root: root, quality: quality)

        if let bassText {
            guard let bassName = NoteName(String(bassText)) else { return nil }
            let bass = bassName.pitchClass
            guard let position = chord.pitchClasses.firstIndex(of: bass) else { return nil }
            chord = chord.inverted(position)
        }
        self = chord
    }
}

extension Letter {
    /// "C"…"B", either case.
    init?(parsing character: Character) {
        switch character.uppercased() {
        case "C": self = .c
        case "D": self = .d
        case "E": self = .e
        case "F": self = .f
        case "G": self = .g
        case "A": self = .a
        case "B": self = .b
        default: return nil
        }
    }
}

public struct ChordParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var symbol: String
    public init(symbol: String) { self.symbol = symbol }
    public var description: String {
        symbol.isEmpty ? "No chords to read." : "\"\(symbol)\" is not a chord symbol this app can read."
    }
}
