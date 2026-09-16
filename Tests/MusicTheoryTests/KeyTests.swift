import Testing
@testable import MusicTheory

private func names(_ noteNames: [NoteName]) -> [String] { noteNames.map(\.description) }

@Suite("Key signatures")
struct KeySignatureTests {
    // Translated from game/src/theory/scales.ts KEY_SIGNATURES
    @Test func sharpKeys() {
        let expected: [(String, [String])] = [
            ("C", []), ("G", ["F#"]), ("D", ["F#", "C#"]), ("A", ["F#", "C#", "G#"]),
            ("E", ["F#", "C#", "G#", "D#"]), ("B", ["F#", "C#", "G#", "D#", "A#"]),
            ("F#", ["F#", "C#", "G#", "D#", "A#", "E#"]), ("C#", ["F#", "C#", "G#", "D#", "A#", "E#", "B#"]),
        ]
        for (tonic, sharps) in expected {
            let signature = Key(tonic: NoteName(tonic)!).signature
            #expect(signature.sharpCount == sharps.count, "\(tonic)")
            #expect(signature.flatCount == 0, "\(tonic)")
            #expect(names(signature.accidentals) == sharps, "\(tonic)")
        }
    }
    @Test func flatKeys() {
        let expected: [(String, [String])] = [
            ("F", ["Bb"]), ("Bb", ["Bb", "Eb"]), ("Eb", ["Bb", "Eb", "Ab"]), ("Ab", ["Bb", "Eb", "Ab", "Db"]),
            ("Db", ["Bb", "Eb", "Ab", "Db", "Gb"]), ("Gb", ["Bb", "Eb", "Ab", "Db", "Gb", "Cb"]),
            ("Cb", ["Bb", "Eb", "Ab", "Db", "Gb", "Cb", "Fb"]),
        ]
        for (tonic, flats) in expected {
            let signature = Key(tonic: NoteName(tonic)!).signature
            #expect(signature.flatCount == flats.count, "\(tonic)")
            #expect(signature.sharpCount == 0, "\(tonic)")
            #expect(names(signature.accidentals) == flats, "\(tonic)")
        }
    }
    @Test func minorAndModalKeysShareTheRelativeMajorSignature() {
        #expect(Key.aMinor.signature.fifths == 0)
        #expect(Key(tonic: NoteName(.e), mode: .aeolian).signature.fifths == 1)
        #expect(Key(tonic: NoteName(.d), mode: .dorian).signature.fifths == 0)
        #expect(Key(tonic: NoteName(.g), mode: .mixolydian).signature.fifths == 0)
        #expect(Key(tonic: NoteName(.f), mode: .lydian).signature.fifths == 0)
        #expect(Key(tonic: NoteName(.b), mode: .locrian).signature.fifths == 0)
        #expect(Key(tonic: NoteName(.e), mode: .phrygian).signature.fifths == 0)
        #expect(Key(tonic: NoteName(.a), mode: .dorian).signature.fifths == 1)
    }
    @Test func signatureRoundTripsThroughTonics() {
        for fifths in -7...7 {
            let signature = KeySignature(fifths: fifths)
            #expect(Key(tonic: signature.majorTonic).signature.fifths == fifths)
            #expect(Key(tonic: signature.minorTonic, mode: .aeolian).signature.fifths == fifths)
        }
        #expect(KeySignature(fifths: 0).description == "no sharps or flats")
        #expect(KeySignature(fifths: -2).description == "2 flats (Bb, Eb)")
        #expect(KeySignature(fifths: 1).description == "1 sharp (F#)")
        #expect(KeySignature(fifths: 3).accidental(for: .g) == .sharp)
        #expect(KeySignature(fifths: 3).accidental(for: .d) == .natural)
        #expect(KeySignature(fifths: -1).accidental(for: .b) == .flat)
    }
}

@Suite("Key construction and spelling")
struct KeySpellingTests {
    @Test func spelledScales() {
        #expect(names(Key(tonic: NoteName(.d)).spelledScale) == ["D", "E", "F#", "G", "A", "B", "C#"])
        #expect(names(Key(tonic: NoteName(.f)).spelledScale) == ["F", "G", "A", "Bb", "C", "D", "E"])
        #expect(names(Key(tonic: .gFlat).spelledScale) == ["Gb", "Ab", "Bb", "Cb", "Db", "Eb", "F"])
        #expect(names(Key(tonic: .fSharp).spelledScale) == ["F#", "G#", "A#", "B", "C#", "D#", "E#"])
        #expect(names(Key(tonic: NoteName(.c), mode: .aeolian).spelledScale) == ["C", "D", "Eb", "F", "G", "Ab", "Bb"])
        #expect(names(Key(tonic: NoteName(.d), mode: .dorian).spelledScale) == ["D", "E", "F", "G", "A", "B", "C"])
    }
    @Test func pitchClassTonicsGetConventionalSpelling() {
        #expect(Key(tonicPitchClass: .cSharp).tonic.description == "Db")
        #expect(Key(tonicPitchClass: .fSharp).tonic.description == "F#")
        #expect(Key(tonicPitchClass: .aSharp).tonic.description == "Bb")
        #expect(Key(tonicPitchClass: .gSharp, mode: .aeolian).tonic.description == "G#")
        #expect(Key(tonicPitchClass: .aSharp, mode: .aeolian).tonic.description == "Bb")
        #expect(Key(tonicPitchClass: .cSharp, mode: .dorian).tonic.description == "C#")
        #expect(Key(tonicPitchClass: .dSharp, mode: .aeolian).tonic.description == "D#")
    }
    @Test func seventeenTonicsBuildKeys() {
        for tonic in Tonic.allCases {
            let major = Key(tonic: tonic)
            #expect(major.tonic == tonic.noteName)
            #expect(major.pitchClasses.first == tonic.pitchClass)
            #expect(major.signature.fifths == tonic.noteName.fifths, "\(tonic)")
            #expect(major.signature.majorTonic == tonic.noteName, "\(tonic)")
            #expect(major.signature.accidentals.count == abs(major.signature.fifths), "\(tonic)")
            let minor = Key(tonic: tonic, mode: .aeolian)
            #expect(minor.relativeMajor.pitchClasses.sorted() == minor.pitchClasses.sorted())
        }
        #expect(Key(tonic: .gFlat).signature.fifths == -6)
        #expect(Key(tonic: .fSharp).signature.fifths == 6)
        #expect(Key(tonic: .aSharp, mode: .aeolian).signature.fifths == 7)
        // A♯, D♯ and G♯ are minor-key tonics in practice; as majors they are theoretical keys past 7 sharps.
        #expect(Key(tonic: .gSharp).signature.fifths == 8)
        #expect(names(Key(tonic: .gSharp).spelledScale) == ["G#", "A#", "B#", "C#", "D#", "E#", "F##"])
        #expect(Key(tonic: .aSharp).signature.fifths == 10)
    }
    @Test func spellsPitchClassesInContext() {
        let fMajor = Key(tonic: NoteName(.f))
        #expect(fMajor.spell(.aSharp).description == "Bb")
        #expect(fMajor.spell(.b).description == "B")
        #expect(fMajor.spell(.cSharp).description == "Db")
        #expect(Key.cMajor.spell(.cSharp).description == "C#")
        #expect(Key(tonic: NoteName(.b)).spell(.aSharp).description == "A#")
        #expect(Key(tonic: .gFlat).spell(.b).description == "Cb")
        #expect(fMajor.name(of: Pitch(70)) == "Bb4")
        #expect(fMajor.spellingPreference == .flats)
        #expect(Key.cMajor.spellingPreference == .sharps)
    }
    @Test func spellsChordsWithFewestAccidentals() {
        #expect(names(Key.cMajor.spell(Chord(.dSharp, .major))) == ["Eb", "G", "Bb"])
        #expect(names(Key.cMajor.spell(Chord(.fSharp, .diminished))) == ["F#", "A", "C"])
        #expect(names(Key.cMajor.spell(Chord(.gSharp, .major))) == ["Ab", "C", "Eb"])
        #expect(names(Key.cMajor.spell(Chord(.aSharp, .major))) == ["Bb", "D", "F"])
        #expect(names(Key(tonic: NoteName(.d)).spell(Chord(.fSharp, .minor))) == ["F#", "A", "C#"])
        #expect(Key.cMajor.symbol(of: Chord(.dSharp, .major)) == "Eb")
        #expect(Key(tonic: NoteName(.b)).symbol(of: Chord(.aSharp, .major)) == "A#")
        #expect(Key.cMajor.symbol(of: Chord(.c, .major).inverted(1)) == "C/E")
    }
    @Test func parsing() {
        #expect(Key(parsing: "F# minor") == Key(tonic: NoteName(.f, .sharp), mode: .aeolian))
        #expect(Key(parsing: "Eb") == Key(tonic: .eFlat))
        #expect(Key(parsing: "D dorian") == Key(tonic: NoteName(.d), mode: .dorian))
        #expect(Key(parsing: "H major") == nil)
        #expect(Key(parsing: "C blues") == nil)
    }
    @Test func naming() {
        #expect(Key.cMajor.name == "C major")
        #expect(Key(tonic: .fSharp, mode: .aeolian).name == "F\u{266F} minor")
        #expect(Key(tonic: NoteName(.d), mode: .dorian).name == "D Dorian")
        #expect(Key.cMajor.isMajor && !Key.cMajor.isMinor)
        #expect(Key.aMinor.isMinor)
    }
}

@Suite("Relative and parallel keys")
struct RelatedKeyTests {
    @Test func relativeKeys() {
        #expect(Key.cMajor.relativeMinor == .aMinor)
        #expect(Key.aMinor.relativeMajor == .cMajor)
        #expect(Key(tonic: .eFlat).relativeMinor.tonic.description == "C")
        #expect(Key(tonic: .fSharp).relativeMinor.tonic.description == "D#")
        #expect(Key(tonic: .gFlat).relativeMinor.tonic.description == "Eb")
        #expect(Key(tonic: NoteName(.b, .flat), mode: .aeolian).relativeMajor.tonic.description == "Db")
        #expect(Key.cMajor.relative(.dorian) == Key(tonic: NoteName(.d), mode: .dorian))
        #expect(Key(tonic: NoteName(.d), mode: .dorian).relativeMajor == .cMajor)
        #expect(Key(tonic: NoteName(.e), mode: .phrygian).relativeMinor == .aMinor)
    }
    @Test func parallelKeys() {
        #expect(Key.cMajor.parallelMinor == Key(tonic: NoteName(.c), mode: .aeolian))
        #expect(Key.cMajor.parallelMinor.signature.fifths == -3)
        #expect(Key.aMinor.parallelMajor.signature.fifths == 3)
        #expect(Key.cMajor.parallel(.lydian).signature.fifths == 1)
        #expect(Key(tonic: .fSharp).parallelMinor.tonic.description == "F#")
    }
}

@Suite("Diatonic chords and Roman numerals in keys")
struct KeyHarmonyTests {
    @Test func majorDiatonicTriadsMatchTheChorusAndGrooveTables() {
        let chords = Key.cMajor.diatonicTriads
        #expect(chords.map(\.root) == [.c, .d, .e, .f, .g, .a, .b])
        #expect(chords.map(\.quality) == [.major, .minor, .minor, .major, .major, .minor, .diminished])
        #expect(Key.cMajor.romanNumerals().map(\.description) == ["I", "ii", "iii", "IV", "V", "vi", "vii\u{00B0}"])
    }
    @Test func minorDiatonicTriads() {
        let chords = Key.aMinor.diatonicTriads
        #expect(chords.map(\.quality) == [.minor, .diminished, .major, .minor, .minor, .major, .major])
        #expect(Key.aMinor.romanNumerals().map(\.description) == ["i", "ii\u{00B0}", "III", "iv", "v", "VI", "VII"])
        #expect(Key.aMinor.romanNumerals(reference: .parallelMajor).map(\.description)
                == ["i", "ii\u{00B0}", "\u{266D}III", "iv", "v", "\u{266D}VI", "\u{266D}VII"])
    }
    @Test func diatonicSevenths() {
        #expect(Key.cMajor.diatonicSevenths.map(\.quality) == [
            .majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .dominantSeventh, .minorSeventh, .halfDiminishedSeventh,
        ])
        #expect(Key.cMajor.romanNumerals(sevenths: true).map(\.description)
                == ["Imaj7", "ii7", "iii7", "IVmaj7", "V7", "vi7", "vii\u{00F8}7"])
        #expect(Key(tonic: NoteName(.g)).diatonicSevenths[4] == Chord(.d, .dominantSeventh))
    }
    @Test func modalNumeralsMatchGrooveTheoryTables() {
        func render(_ mode: Mode, _ reference: NumeralReference? = nil) -> [String] {
            Key(tonic: NoteName(.c), mode: mode).romanNumerals(reference: reference).map(\.description)
        }
        // Church modes default to the parallel-major reference (♭III, ♭VII in Dorian), as groove-theory does
        // for Phrygian, Lydian and Locrian. groove-theory left the flats off Dorian and Mixolydian; that
        // rendering is available with `.ownScale`.
        #expect(render(.dorian) == ["i", "ii", "\u{266D}III", "IV", "v", "vi\u{00B0}", "\u{266D}VII"])
        #expect(render(.dorian, .ownScale) == ["i", "ii", "III", "IV", "v", "vi\u{00B0}", "VII"])
        #expect(render(.mixolydian) == ["I", "ii", "iii\u{00B0}", "IV", "v", "vi", "\u{266D}VII"])
        #expect(render(.mixolydian, .ownScale) == ["I", "ii", "iii\u{00B0}", "IV", "v", "vi", "VII"])
        #expect(render(.phrygian) == ["i", "\u{266D}II", "\u{266D}III", "iv", "v\u{00B0}", "\u{266D}VI", "\u{266D}vii"])
        #expect(render(.lydian) == ["I", "II", "iii", "\u{266F}iv\u{00B0}", "V", "vi", "vii"])
        // groove-theory's Locrian table calls degree 6 minor; stacking thirds (B Locrian: G B D) gives a major triad.
        #expect(render(.locrian) == ["i\u{00B0}", "\u{266D}II", "\u{266D}iii", "iv", "\u{266D}V", "\u{266D}VI", "\u{266D}vii"])
    }
    @Test func nonDiatonicChordsGetBorrowedNumerals() {
        #expect(Key.cMajor.romanNumeral(for: Chord(.dSharp, .major))?.description == "\u{266D}III")
        #expect(Key.cMajor.romanNumeral(for: Chord(.gSharp, .major))?.description == "\u{266D}VI")
        #expect(Key.cMajor.romanNumeral(for: Chord(.aSharp, .major))?.description == "\u{266D}VII")
        #expect(Key.cMajor.romanNumeral(for: Chord(.cSharp, .major))?.description == "\u{266D}II")
        #expect(Key.cMajor.romanNumeral(for: Chord(.fSharp, .diminished))?.description == "\u{266F}iv\u{00B0}")
        #expect(Key.cMajor.romanNumeral(for: Chord(.d, .dominantSeventh))?.description == "II7")
        #expect(Key.aMinor.romanNumeral(for: Chord(.e, .dominantSeventh))?.description == "V7")
        #expect(Key.aMinor.romanNumeral(for: Chord(.gSharp, .diminishedSeventh))?.description == "\u{266F}vii\u{00B0}7")
    }
    @Test func numeralsRoundTripToChords() {
        for key in [Key.cMajor, .aMinor, Key(tonic: .eFlat), Key(tonic: .fSharp, mode: .aeolian), Key(tonic: NoteName(.e), mode: .phrygian)] {
            for chord in key.diatonicTriads + key.diatonicSevenths {
                let numeral = key.romanNumeral(for: chord)
                #expect(numeral != nil, "\(key) \(chord)")
                #expect(numeral.map { key.chord(for: $0) } == chord, "\(key) \(chord)")
            }
        }
        #expect(Key.cMajor.chord(for: RomanNumeral(degree: 3, quality: .major, accidental: .flat)) == Chord(.dSharp, .major))
        #expect(Key.cMajor.chord(for: RomanNumeral(degree: 5, quality: .dominantSeventh)) == Chord(.g, .dominantSeventh))
    }
}
