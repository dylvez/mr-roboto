import Foundation
import MusicTheory

/// A genre's progression, written in numerals, as chords in a key: "i - bVII - bVI - bVII" in A
/// minor is "Am G F G", one bar each — what the Chords surface and the Director can play.
///
/// Numerals follow the analyses the profiles cite. Upper case is major and lower case minor;
/// `°`/`dim`, `+`/`aug`, `ø`, `maj7`, `m7`, `7`, `sus2`, `sus4` qualify it. A progression with an
/// accidental anywhere reads its degrees from the major scale on the tonic — "bVII" is a flat
/// seventh because the major scale's is natural — and one with none reads them from its own mode
/// when it names one, else the key's, so "i - VII - VI" in A minor is Am G F, as a minor-key
/// analysis means it.
public enum GenreNumerals {

    /// The chords, or nil when a numeral cannot be read.
    public static func chords(_ roman: String, in key: Key, mode: String? = nil) -> [Chord]? {
        let tokens = roman.split(whereSeparator: { " -–—|,→".contains($0) }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let fromMajor = tokens.contains { $0.first.map { "b♭#♯".contains($0) } ?? false }
        let named = mode.flatMap { name in Mode.allCases.first { $0.name.lowercased() == name.lowercased() } }
        let scale = fromMajor ? Mode.ionian.scale : (named?.scale ?? key.scale)
        var out: [Chord] = []
        for token in tokens {
            guard let chord = chord(token, key: key, scale: scale) else { return nil }
            out.append(chord)
        }
        return out
    }

    /// Lead-sheet symbols, a bar each: what `Progression.parse` reads.
    public static func symbols(_ roman: String, in key: Key, mode: String? = nil) -> String? {
        // A flat written in the numerals is spelled as a flat: bVII in C is Bb, not A#.
        let preference: SpellingPreference = roman.contains { $0 == "b" || $0 == "♭" } ? .flats : key.signature.preference
        return chords(roman, in: key, mode: mode)?.map { $0.symbol(preferring: preference) }.joined(separator: " | ")
    }

    /// Whether a progression written in `mode` belongs in a key: minor modes in a minor key, major
    /// ones in a major key. A progression that names no mode fits either.
    public static func fits(mode: String?, _ key: Key) -> Bool {
        guard let mode = mode?.lowercased(), !mode.isEmpty else { return true }
        let minor = ["aeolian", "dorian", "phrygian", "locrian", "harmonic minor", "melodic minor", "minor"].contains(mode)
        let keyMinor = [.aeolian, .dorian, .phrygian, .locrian].contains(key.mode)
        return minor == keyMinor
    }

    static let numerals = ["vii": 7, "vi": 6, "iv": 4, "v": 5, "iii": 3, "ii": 2, "i": 1]

    static func chord(_ token: String, key: Key, scale: Scale) -> Chord? {
        var rest = Substring(token)
        var shift = 0
        while let first = rest.first, "b♭#♯".contains(first) {
            shift += (first == "#" || first == "♯") ? 1 : -1
            rest = rest.dropFirst()
        }
        // The longest numeral first, so "vii" is not read as "v" then "ii".
        let lowered = rest.lowercased()
        guard let (numeral, degree) = numerals.sorted(by: { $0.key.count > $1.key.count })
            .first(where: { lowered.hasPrefix($0.key) }) else { return nil }
        let written = rest.prefix(numeral.count)
        let upper = written.allSatisfy(\.isUppercase)
        let suffix = String(rest.dropFirst(numeral.count)).replacingOccurrences(of: " ", with: "")
        let root = scale.pitchClass(degree: degree, root: key.tonic.pitchClass).transposed(by: shift)
        guard let quality = quality(suffix, upper: upper) else { return nil }
        return Chord(root, quality)
    }

    static func quality(_ suffix: String, upper: Bool) -> ChordQuality? {
        switch suffix {
        case "": return upper ? .major : .minor
        case "°", "o", "dim": return .diminished
        case "°7", "o7", "dim7": return .diminishedSeventh
        case "ø", "ø7", "m7b5", "m7♭5": return .halfDiminishedSeventh
        case "+", "aug": return .augmented
        case "maj7", "M7", "Δ", "Δ7": return upper ? .majorSeventh : .minorMajorSeventh
        case "7": return upper ? .dominantSeventh : .minorSeventh
        case "m7": return .minorSeventh
        case "sus2": return .suspendedSecond
        case "sus4", "sus": return .suspendedFourth
        // The case of the numeral says minor, as it does for a seventh.
        case "9": return upper ? .dominantNinth : .minorNinth
        case "11": return upper ? .dominantEleventh : .minorEleventh
        case "13": return upper ? .dominantThirteenth : .minorThirteenth
        case "6": return upper ? .sixth : .minorSixth
        case "6/9", "69": return upper ? .sixNine : .minorSixNine
        case "add9": return upper ? .addNine : .minorAddNine
        case "maj9": return upper ? .majorNinth : .minorNinth
        case "m9": return .minorNinth
        case "m11": return .minorEleventh
        case "m13": return .minorThirteenth
        case "m6": return .minorSixth
        default:
            // Anything else a lead sheet spells — "maj7#11", "7b9", "7sus4" — as the chord parser
            // reads it.
            let normal = suffix.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
            if let spelled = ChordQuality.spellings.first(where: { $0.0 == normal })?.1 { return spelled }
            // And what nothing reads — "m11(9)" — is played as the chord it alters: the longest
            // suffix it begins with.
            let known = ["m7b5", "maj7", "maj9", "dim7", "sus2", "sus4", "add9", "m7", "m9", "m6", "dim", "aug", "7", "9", "11", "13", "6", "ø", "°", "+", "m"]
            guard let base = known.first(where: { suffix.hasPrefix($0) && suffix != $0 }) else { return nil }
            return base == "m" ? .minor : quality(base, upper: upper)
        }
    }
}
