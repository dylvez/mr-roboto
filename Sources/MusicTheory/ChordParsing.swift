import Foundation

// Chord symbols as people type them: "Dm7", "G7", "C#m7b5", "Bbmaj7", "F/A", "Cmaj9", "E7#9".

extension ChordQuality {
    /// Every spelling of a quality a lead sheet is likely to carry, longest first so "maj7" is not
    /// read as "ma" + "j7". The canonical `symbol` is always among them.
    public static let spellings: [(String, ChordQuality)] = [
        // Past the sevenths. Matched whole, so their order among themselves does not matter.
        ("maj7#11", .majorSevenSharpEleven), ("maj7(#11)", .majorSevenSharpEleven), ("M7#11", .majorSevenSharpEleven),
        ("Δ#11", .majorSevenSharpEleven), ("maj7♯11", .majorSevenSharpEleven),
        ("maj13", .majorThirteenth), ("Maj13", .majorThirteenth), ("M13", .majorThirteenth), ("Δ13", .majorThirteenth),
        ("maj9", .majorNinth), ("Maj9", .majorNinth), ("M9", .majorNinth), ("Δ9", .majorNinth), ("ma9", .majorNinth),
        ("m6/9", .minorSixNine), ("m69", .minorSixNine), ("min6/9", .minorSixNine), ("-6/9", .minorSixNine),
        ("6/9", .sixNine), ("69", .sixNine),
        ("madd9", .minorAddNine), ("m(add9)", .minorAddNine), ("minadd9", .minorAddNine),
        ("add9", .addNine), ("(add9)", .addNine),
        ("m13", .minorThirteenth), ("min13", .minorThirteenth), ("-13", .minorThirteenth),
        ("m11", .minorEleventh), ("min11", .minorEleventh), ("-11", .minorEleventh),
        ("m9", .minorNinth), ("min9", .minorNinth), ("-9", .minorNinth),
        ("m6", .minorSixth), ("min6", .minorSixth), ("-6", .minorSixth),
        ("7sus4", .sevenSuspendedFourth), ("7sus", .sevenSuspendedFourth),
        ("9sus4", .nineSuspendedFourth), ("9sus", .nineSuspendedFourth),
        ("7b9", .sevenFlatNine), ("7♭9", .sevenFlatNine), ("7(b9)", .sevenFlatNine),
        ("7#9", .sevenSharpNine), ("7♯9", .sevenSharpNine), ("7(#9)", .sevenSharpNine),
        ("7#11", .sevenSharpEleven), ("7♯11", .sevenSharpEleven), ("7(#11)", .sevenSharpEleven),
        ("7b13", .sevenFlatThirteen), ("7♭13", .sevenFlatThirteen), ("7(b13)", .sevenFlatThirteen),
        ("7#5", .sevenSharpFive), ("7♯5", .sevenSharpFive), ("aug7", .sevenSharpFive), ("+7", .sevenSharpFive), ("7+", .sevenSharpFive),
        ("7b5", .sevenFlatFive), ("7♭5", .sevenFlatFive),
        ("13", .dominantThirteenth), ("11", .dominantEleventh), ("9", .dominantNinth), ("6", .sixth), ("5", .power),
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
        // The last slash, and only when a note follows it: the slash in C6/9 is part of its name.
        if let slash = body.lastIndex(of: "/"), NoteName(String(body[body.index(after: slash)...])) != nil {
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
