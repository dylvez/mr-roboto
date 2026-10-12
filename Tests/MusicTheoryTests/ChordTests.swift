import Testing
@testable import MusicTheory

// Translated from game/src/theory/chords.test.ts

private func midi(_ pitches: [Pitch]) -> [Int] { pitches.map(\.midi) }

@Suite("triadFromRoot")
struct TriadFromRootTests {
    @Test func buildsCMajor() {
        #expect(midi(Chord(.c, .major).pitches(octave: 4)) == [60, 64, 67])
    }
    @Test func buildsAMinor() {
        #expect(midi(Chord(.a, .minor).pitches(root: Pitch(57))) == [57, 60, 64])
    }
    @Test func buildsBDiminished() {
        #expect(midi(Chord(.b, .diminished).pitches(root: Pitch(59))) == [59, 62, 65])
    }
    @Test func buildsCAugmented() {
        #expect(midi(Chord(.c, .augmented).pitches(octave: 4)) == [60, 64, 68])
    }
}

@Suite("seventhFromRoot")
struct SeventhFromRootTests {
    @Test func buildsCmaj7() {
        #expect(midi(Chord(.c, .majorSeventh).pitches(octave: 4)) == [60, 64, 67, 71])
    }
    @Test func buildsG7() {
        #expect(midi(Chord(.g, .dominantSeventh).pitches(root: Pitch(67))) == [67, 71, 74, 77])
    }
    @Test func buildsDm7() {
        #expect(midi(Chord(.d, .minorSeventh).pitches(root: Pitch(62))) == [62, 65, 69, 72])
    }
}

@Suite("invertChord")
struct InvertChordTests {
    @Test func firstInversionRootToTop() {
        #expect(midi(Chord(.c, .major).inverted(1).pitches(octave: 4)) == [64, 67, 72])
    }
    @Test func secondInversion() {
        #expect(midi(Chord(.c, .major).inverted(2).pitches(octave: 4)) == [67, 72, 76])
    }
}

@Suite("matchesTriad")
struct MatchesTriadTests {
    private let cMajor = Chord(.c, .major)

    @Test func matchesRootPosition() {
        #expect(cMajor.matches([Pitch(60), Pitch(64), Pitch(67)]))
    }
    @Test func matchesFirstInversion() {
        #expect(cMajor.matches([Pitch(64), Pitch(67), Pitch(72)]))
    }
    @Test func matchesAcrossOctaves() {
        #expect(cMajor.matches([Pitch(48), Pitch(64), Pitch(79)]))
    }
    @Test func rejectsWrongQuality() {
        #expect(!cMajor.matches([Pitch(60), Pitch(63), Pitch(67)])) // Cm
        #expect(Chord(.c, .minor).matches([Pitch(60), Pitch(63), Pitch(67)]))
    }
    @Test func rejectsMissingNote() {
        #expect(!cMajor.matches([Pitch(60), Pitch(64)]))
    }
}

@Suite("TRIAD_INTERVALS catalog")
struct TriadCatalogTests {
    @Test func hasAllFourQualities() {
        for quality in [ChordQuality.major, .minor, .diminished, .augmented] {
            #expect(quality.intervals.count == 3)
            #expect(ChordQuality.triads.contains(quality))
        }
    }
}

// Additional Chord / ChordQuality / RomanNumeral coverage

@Suite("ChordQuality catalog")
struct ChordQualityTests {
    @Test func everySourceQualityIsPresent() {
        let expected: [String: [Int]] = [
            "": [0, 4, 7], "m": [0, 3, 7], "dim": [0, 3, 6], "aug": [0, 4, 8],
            "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "7": [0, 4, 7, 10],
            "dim7": [0, 3, 6, 9], "m7b5": [0, 3, 6, 10], "sus2": [0, 2, 7], "sus4": [0, 5, 7],
            "mMaj7": [0, 3, 7, 11],
        ]
        for (symbol, intervals) in expected {
            let quality = ChordQuality.allCases.first { $0.symbol == symbol }
            #expect(quality?.intervals == intervals, "\(symbol)")
        }
    }
    @Test func intervalsLookupIsOrderInsensitive() {
        #expect(ChordQuality(intervals: [7, 4, 0]) == .major)
        #expect(ChordQuality(intervals: [0, 3, 6, 10]) == .halfDiminishedSeventh)
        #expect(ChordQuality(intervals: [0, 1, 2]) == nil)
    }
    @Test("the chords past the sevenths are stacked above them, read after them, and know what they are built on")
    func extended() {
        #expect(ChordQuality.basic.count == 13)
        #expect(Array(ChordQuality.allCases.prefix(13)) == ChordQuality.basic)
        #expect(ChordQuality.triads.count == 6 && ChordQuality.sevenths.count == 7)
        #expect(ChordQuality.majorNinth.intervals == [0, 4, 7, 11, 14])
        #expect(Chord(.c, .majorNinth).pitches(octave: 3).map(\.midi) == [48, 52, 55, 59, 62])
        #expect(Chord(.c, .majorNinth).pitchClasses.map(\.rawValue) == [0, 4, 7, 11, 2])
        // A sixth and a minor seventh are the same four notes; the seventh is read first.
        #expect(ChordQuality(intervals: [0, 4, 7, 9]) == .sixth)
        #expect(Chord.identify([.a, .c, .e, .g]).first == Chord(.a, .minorSeventh))
        #expect(Chord.identify([.a, .c, .e, .g]).contains(Chord(.c, .sixth)))
        #expect(ChordQuality(intervals: [0, 2, 4, 7, 11]) == .majorNinth, "a ninth folded into the octave is still the ninth")
        #expect(ChordQuality.minorNinth.triad == .minor)
        #expect(ChordQuality.dominantThirteenth.triad == .major)
        #expect(ChordQuality.sevenSuspendedFourth.triad == .suspendedFourth)
        #expect(ChordQuality.sevenSharpFive.triad == .augmented)
        #expect(ChordQuality.power.triad == .major)
        #expect(ChordQuality.minorNinth.seventh == 10 && ChordQuality.majorNinth.seventh == 11 && ChordQuality.sixth.seventh == nil)
        #expect(!ChordQuality.minorNinth.isSeventh && ChordQuality.minorNinth.isExtended && !ChordQuality.minorSeventh.isExtended)
        // In a key, a ninth is spelled on the letter a ninth above its root.
        let key = Key(tonic: NoteName(.d), mode: .aeolian)
        #expect(key.spell(Chord(.d, .minorNinth)).map(\.description) == ["D", "F", "A", "C", "E"])
        #expect(key.romanNumeral(for: Chord(.d, .minorNinth))?.description == "i9")
        #expect(Key.cMajor.romanNumeral(for: Chord(.g, .dominantThirteenth))?.description == "V13")
        #expect(Key.cMajor.symbol(of: Chord(.f, .sixNine)) == "F6/9")
    }

    @Test func seventhsKnowTheirTriad() {
        #expect(ChordQuality.dominantSeventh.triad == .major)
        #expect(ChordQuality.halfDiminishedSeventh.triad == .diminished)
        #expect(ChordQuality.minorMajorSeventh.triad == .minor)
        #expect(ChordQuality.augmentedMajorSeventh.triad == .augmented)
        #expect(ChordQuality.minor.triad == .minor)
    }
}

@Suite("Chord extras")
struct ChordExtraTests {
    @Test func pitchClassesAndBass() {
        let chord = Chord(.g, .dominantSeventh)
        #expect(chord.pitchClasses == [.g, .b, .d, .f])
        #expect(chord.bass == .g)
        #expect(chord.inverted(1).bass == .b)
        #expect(chord.inverted(3).bass == .f)
        #expect(chord.inverted(9).bass == .f)
    }
    @Test func rootOctaveOverflowMovesUpAnOctave() {
        // groove-theory getChordNotesWithOctave: A4 major → A4 C#5 E5
        #expect(Chord(.a, .major).pitches(octave: 4).map { $0.name() } == ["A4", "C#5", "E5"])
    }
    @Test func symbolsAndNames() {
        #expect(Chord(.cSharp, .minorSeventh).symbol() == "C#m7")
        #expect(Chord(.cSharp, .minorSeventh).symbol(preferring: .flats) == "Dbm7")
        #expect(Chord(.c, .major).inverted(1).symbol() == "C/E")
        #expect(Chord(.b, .halfDiminishedSeventh).name() == "B Half-Diminished 7th")
        #expect("\(Chord(.f, .suspendedFourth))" == "Fsus4")
    }
    @Test func identifyFindsAllMatchingChords() {
        let found = Chord.identify([.c, .e, .g])
        #expect(found == [Chord(.c, .major)])
        let sus = Chord.identify([.c, .d, .g])
        #expect(Set(sus) == [Chord(.c, .suspendedSecond), Chord(.g, .suspendedFourth)])
        let dim7 = Chord.identify([.b, .d, .f, .gSharp])
        #expect(dim7.count == 4) // symmetric: every tone is a root
        #expect(Chord.identify([.c, .cSharp]).isEmpty)
    }
    @Test func transposition() {
        #expect(Chord(.c, .major).transposed(by: 7) == Chord(.g, .major))
        #expect(Chord(.c, .major).transposed(by: -1).root == .b)
    }
}

@Suite("Chord symbols in a key")
struct ChordSymbolInKeyTests {
    private let eFlatMinor = Key(tonic: .eFlat, mode: .aeolian)
    private let eMajor = Key(tonic: NoteName(.e))

    private func chords(_ line: String) throws -> [Chord] {
        try line.split(separator: " ").map { try #require(Chord(parsing: String($0))) }
    }

    /// Every major and minor key with no more than seven sharps or flats.
    private var keys: [Key] {
        (-7...7).flatMap { fifths -> [Key] in
            let signature = KeySignature(fifths: fifths)
            return [Key(tonic: signature.majorTonic), Key(tonic: signature.minorTonic, mode: .aeolian)]
        }
    }

    @Test("a root on a step of the key is spelled as the key spells that step: the sixth of E♭ minor is C♭")
    func rootsOnTheKeysSteps() throws {
        let line = try chords("Ebm9 Ab7 Cbmaj7 Bb7")
        #expect(line[2] == Chord(.b, .majorSeventh), "a chord keeps its pitch, not its letter")
        #expect(line.map { $0.symbol(in: eFlatMinor) } == ["Ebm9", "Ab7", "Cbmaj7", "Bb7"])
        #expect(line[2].symbol(preferring: eFlatMinor.spellingPreference) == "Bmaj7", "a preference alone cannot reach C♭")
        // The bass of an inversion is spelled from the root, as the chord tone it is.
        #expect(try chords("Cbmaj7/Eb Cb/Gb").map { $0.symbol(in: eFlatMinor) } == ["Cbmaj7/Eb", "Cb/Gb"])
        // The other white keys a key writes as accidentals: IV of G♭, vii° of F♯, and vii°7 of C♯
        // harmonic minor, whose raised seventh is B♯.
        #expect(Chord(.b, .major).symbol(in: Key(tonic: .gFlat)) == "Cb")
        #expect(Chord(.f, .diminished).symbol(in: Key(tonic: .fSharp)) == "E#dim")
        #expect(Chord(.c, .diminishedSeventh).symbol(in: Key(tonic: NoteName(.c, .sharp), colour: .harmonicMinor)) == "B#dim7")
    }

    @Test("a sharp key keeps its sharps: C♯m7 and F♯ in E major")
    func sharpKey() throws {
        #expect(try chords("Emaj7 C#m7 F#m7 B7").map { $0.symbol(in: eMajor) } == ["Emaj7", "C#m7", "F#m7", "B7"])
        #expect(try chords("F# E/G# B7/D#").map { $0.symbol(in: eMajor) } == ["F#", "E/G#", "B7/D#"])
    }

    @Test("a root off the key is spelled as it always was, by the key's preference, its bass from it")
    func rootsOffTheKey() throws {
        #expect(try chords("D7 E/G# A7").map { $0.symbol(in: eFlatMinor) } == ["D7", "E/G#", "A7"])
        #expect(try chords("A#dim7").map { $0.symbol(in: eMajor) } == ["A#dim7"])
        #expect(try chords("Dbmaj7").map { $0.symbol(in: Key(tonic: NoteName(.f))) } == ["Dbmaj7"])
        #expect(try chords("F#dim7").map { $0.symbol(in: .cMajor) } == ["F#dim7"])
        for key in keys {
            for root in PitchClass.allCases where !key.pitchClasses.contains(root) {
                for quality in [ChordQuality.major, .minor, .dominantSeventh, .diminishedSeventh, .majorNinth] {
                    for inversion in 0...2 {
                        let chord = Chord(root: root, quality: quality, inversion: inversion)
                        #expect(chord.symbol(in: key) == chord.symbol(preferring: key.spellingPreference), "\(chord) in \(key)")
                    }
                }
            }
        }
    }

    @Test("in C, the key a song with none is read in, every chord is spelled as it was")
    func cMajorIsUnchanged() {
        for quality in ChordQuality.allCases {
            for root in PitchClass.allCases {
                for inversion in 0...1 {
                    let chord = Chord(root: root, quality: quality, inversion: inversion)
                    #expect(chord.symbol(in: .cMajor) == chord.symbol(), "\(chord)")
                }
            }
        }
    }

    @Test("the key's own chords are spelled as the line it keeps spells them, inversions too")
    func agreesWithTheKeptLine() {
        for key in keys {
            for chord in key.diatonicTriads + key.diatonicSevenths {
                for inversion in 0...2 {
                    let inverted = chord.inverted(inversion)
                    #expect(inverted.symbol(in: key) == key.symbol(of: inverted), "\(inverted) in \(key)")
                }
            }
        }
    }
}

@Suite("Roman numerals")
struct RomanNumeralTests {
    @Test func rendersCaseAndSuffixFromQuality() {
        #expect(RomanNumeral(degree: 1, quality: .major).description == "I")
        #expect(RomanNumeral(degree: 2, quality: .minor).description == "ii")
        #expect(RomanNumeral(degree: 7, quality: .diminished).description == "vii\u{00B0}")
        #expect(RomanNumeral(degree: 3, quality: .augmented).description == "III+")
        #expect(RomanNumeral(degree: 5, quality: .dominantSeventh).description == "V7")
        #expect(RomanNumeral(degree: 1, quality: .majorSeventh).description == "Imaj7")
        #expect(RomanNumeral(degree: 2, quality: .minorSeventh).description == "ii7")
        #expect(RomanNumeral(degree: 7, quality: .halfDiminishedSeventh).description == "vii\u{00F8}7")
        #expect(RomanNumeral(degree: 7, quality: .diminishedSeventh).description == "vii\u{00B0}7")
        #expect(RomanNumeral(degree: 3, quality: .major, accidental: .flat).description == "\u{266D}III")
        #expect(RomanNumeral(degree: 4, quality: .diminished, accidental: .sharp).description == "\u{266F}iv\u{00B0}")
        #expect(RomanNumeral(degree: 4, quality: .suspendedFourth).description == "IVsus4")
    }
    @Test func degreeWraps() {
        #expect(RomanNumeral(degree: 8, quality: .major).degree == 1)
        #expect(RomanNumeral(degree: 0, quality: .major).degree == 7)
    }
    @Test func scaleNumeralsMatchGrooveTheoryTables() {
        func render(_ scale: Scale, size: Int = 3) -> [String] { scale.romanNumerals(size: size).map(\.description) }
        #expect(render(.major) == ["I", "ii", "iii", "IV", "V", "vi", "vii\u{00B0}"])
        #expect(render(.naturalMinor) == ["i", "ii\u{00B0}", "III", "iv", "v", "VI", "VII"])
        #expect(render(.harmonicMinor) == ["i", "ii\u{00B0}", "III+", "iv", "V", "VI", "vii\u{00B0}"])
        #expect(render(.melodicMinor) == ["i", "ii", "III+", "IV", "V", "vi\u{00B0}", "vii\u{00B0}"])
        #expect(render(.dorian) == ["i", "ii", "III", "IV", "v", "vi\u{00B0}", "VII"])
        #expect(render(.major, size: 4) == ["Imaj7", "ii7", "iii7", "IVmaj7", "V7", "vi7", "vii\u{00F8}7"])
        #expect(render(.harmonicMinor, size: 4) == ["iM7", "ii\u{00F8}7", "III+maj7", "iv7", "V7", "VImaj7", "vii\u{00B0}7"])
        #expect(render(.pentatonicMajor).isEmpty)
    }
}
