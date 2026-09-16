import Testing
@testable import MusicTheory

// Translated from game/src/theory/pitch.test.ts

@Suite("pitchToMidi")
struct PitchToMidiTests {
    @Test func mapsMiddleC() {
        #expect(Pitch(NoteName(.c), octave: 4).midi == 60)
    }
    @Test func handlesSharps() {
        #expect(Pitch(NoteName(.c, .sharp), octave: 4).midi == 61)
    }
    @Test func handlesFlats() {
        #expect(Pitch(NoteName(.d, .flat), octave: 4).midi == 61)
    }
    @Test func handlesOctaves() {
        #expect(Pitch(NoteName(.c), octave: 5).midi == 72)
        #expect(Pitch(NoteName(.c), octave: 3).midi == 48)
    }
}

@Suite("noteName")
struct NoteNameTests {
    @Test func namesMiddleC() {
        #expect(Pitch(60).name() == "C4")
    }
    @Test func usesSharpsByDefault() {
        #expect(Pitch(61).name() == "C#4")
        #expect(Pitch(66).name() == "F#4")
    }
    @Test func supportsFlats() {
        #expect(Pitch(61).name(preferring: .flats) == "Db4")
        #expect(Pitch(66).name(preferring: .flats) == "Gb4")
    }
    @Test func wrapsOctaves() {
        #expect(Pitch(72).name() == "C5")
        #expect(Pitch(48).name() == "C3")
    }
}

@Suite("pitchClass")
struct PitchClassOfMidiTests {
    @Test func returnsZeroToElevenForAnyMidi() {
        #expect(Pitch(60).pitchClass.rawValue == 0)
        #expect(Pitch(61).pitchClass.rawValue == 1)
        #expect(Pitch(72).pitchClass.rawValue == 0)
        #expect(Pitch(127).pitchClass.rawValue == 7)
    }
}

@Suite("octaveOf")
struct OctaveOfTests {
    @Test func returnsTheRightOctaveNumber() {
        #expect(Pitch(60).octave == 4)
        #expect(Pitch(72).octave == 5)
        #expect(Pitch(21).octave == 0) // A0, lowest piano key
    }
}

@Suite("isWhiteKey / isBlackKey")
struct KeyColorTests {
    @Test func identifiesWhiteKeys() {
        for midi in [60, 62, 64, 65, 67, 69, 71] { #expect(Pitch(midi).isWhiteKey) }
    }
    @Test func identifiesBlackKeys() {
        for midi in [61, 63, 66, 68, 70] { #expect(Pitch(midi).isBlackKey) }
    }
}

// Additional Pitch / PitchClass / NoteName coverage

@Suite("Pitch extras")
struct PitchExtraTests {
    @Test func negativeMidiWrapsCorrectly() {
        #expect(Pitch(-1).pitchClass == .b)
        #expect(Pitch(-1).octave == -2)
        #expect(Pitch(-13).pitchClass == .b)
    }
    @Test func parsesNames() {
        #expect(Pitch(name: "C4") == Pitch(60))
        #expect(Pitch(name: "Db4") == Pitch(61))
        #expect(Pitch(name: "C-1") == Pitch(0))
        #expect(Pitch(name: "F##5") == Pitch(79))
        #expect(Pitch(name: "H4") == nil)
    }
    @Test func spelledNamesFollowTheLetterOctave() {
        #expect(Pitch(60).name(spelledAs: NoteName(.b, .sharp)) == "B#3")
        #expect(Pitch(59).name(spelledAs: NoteName(.c, .flat)) == "Cb4")
    }
    @Test func frequencyRoundTrip() {
        #expect(Pitch.a4.frequency() == 440)
        #expect(abs(Pitch.middleC.frequency() - 261.6256) < 0.001)
        #expect(Pitch(frequency: 440) == .a4)
        #expect(Pitch(frequency: 261.63) == .middleC)
        #expect(Pitch(frequency: 0) == nil)
        #expect(Pitch(frequency: 432, a4: 432) == .a4)
    }
    @Test func centsDeviation() {
        let (pitch, cents) = Pitch.nearest(frequency: 445)!
        #expect(pitch == .a4)
        #expect(abs(cents - 19.56) < 0.05)
        #expect(abs(Pitch.a4.cents(to: 220) + 1200) < 1e-9)
    }
    @Test func arithmetic() {
        #expect(Pitch(60) + 7 == Pitch(67))
        #expect(Pitch(67) - 7 == Pitch(60))
        #expect(Pitch(67) - Pitch(60) == 7)
        #expect(Pitch(65).snappedToC == Pitch(60))
        #expect(Pitch(60) < Pitch(61))
    }
}

@Suite("PitchClass")
struct PitchClassTests {
    @Test func wrapping() {
        #expect(PitchClass(wrapping: 60) == .c)
        #expect(PitchClass(wrapping: -1) == .b)
        #expect(PitchClass(wrapping: 127) == .g)
    }
    @Test func distances() {
        #expect(PitchClass.c.distance(to: .g) == 7)
        #expect(PitchClass.g.distance(to: .c) == 5)
        #expect(PitchClass.c.signedDistance(to: .b) == -1)
        #expect(PitchClass.c.signedDistance(to: .fSharp) == 6)
        #expect(PitchClass.b + 1 == .c)
        #expect(PitchClass.c - 1 == .b)
    }
    @Test func spelling() {
        #expect(PitchClass.cSharp.spelling(preferring: .sharps).description == "C#")
        #expect(PitchClass.cSharp.spelling(preferring: .flats).description == "Db")
        #expect(PitchClass.e.spelling(preferring: .flats).description == "E")
        #expect(PitchClass.c.enharmonicSpellings.map(\.description) == ["C", "Dbb", "B#"])
    }
    @Test func parsing() {
        #expect(PitchClass(name: "C#") == .cSharp)
        #expect(PitchClass(name: "Db") == .cSharp)
        #expect(PitchClass(name: "F\u{266F}") == .fSharp)
        #expect(PitchClass(name: "b\u{266D}") == .aSharp)
        #expect(PitchClass(name: "Cb") == .b)
        #expect(PitchClass(name: "X") == nil)
        #expect(NoteName("E#")?.pitchClass == .f)
        #expect(NoteName("Fx")?.pitchClass == .g)
    }
    @Test func blackKeys() {
        #expect(PitchClass.allCases.filter(\.isBlackKey).map(\.rawValue) == [1, 3, 6, 8, 10])
    }
}

@Suite("Tonic (Music Understanding 17)")
struct TonicTests {
    @Test func hasSeventeenCases() {
        #expect(Tonic.allCases.count == 17)
    }
    @Test func rawValuesAreAppleSpellings() {
        #expect(Tonic.aFlat.rawValue == "A\u{266D}")
        #expect(Tonic.cSharp.rawValue == "C\u{266F}")
        #expect(Tonic(rawValue: "G\u{266D}") == .gFlat)
    }
    @Test func mapsEveryTonicToItsPitchClass() {
        let expected: [Tonic: PitchClass] = [
            .a: .a, .aFlat: .gSharp, .aSharp: .aSharp, .bFlat: .aSharp, .b: .b, .c: .c,
            .cSharp: .cSharp, .dFlat: .cSharp, .d: .d, .dSharp: .dSharp, .eFlat: .dSharp,
            .e: .e, .f: .f, .fSharp: .fSharp, .g: .g, .gFlat: .fSharp, .gSharp: .gSharp,
        ]
        for (tonic, pitchClass) in expected { #expect(tonic.pitchClass == pitchClass, "\(tonic)") }
    }
    @Test func coversAllTwelvePitchClasses() {
        #expect(Set(Tonic.allCases.map(\.pitchClass)).count == 12)
    }
    @Test func pitchClassToTonicHonorsPreference() {
        #expect(Tonic(pitchClass: .cSharp, preferring: .sharps) == .cSharp)
        #expect(Tonic(pitchClass: .cSharp, preferring: .flats) == .dFlat)
        #expect(Tonic(pitchClass: .gSharp, preferring: .flats) == .aFlat)
        #expect(Tonic(pitchClass: .e, preferring: .flats) == .e)
        for pitchClass in PitchClass.allCases {
            #expect(Tonic(pitchClass: pitchClass, preferring: .sharps).pitchClass == pitchClass)
            #expect(Tonic(pitchClass: pitchClass, preferring: .flats).pitchClass == pitchClass)
        }
    }
    @Test func parsesAsciiAndUnicode() {
        #expect(Tonic(parsing: "Eb") == .eFlat)
        #expect(Tonic(parsing: "E\u{266D}") == .eFlat)
        #expect(Tonic(parsing: "F#") == .fSharp)
        #expect(Tonic(parsing: "Cb") == nil) // not one of the 17
        #expect(Tonic(noteName: NoteName(.g, .flat)) == .gFlat)
    }
}
