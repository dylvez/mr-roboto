import Testing
@testable import MusicTheory

// Translated from game/src/theory/scales.test.ts

private func midi(_ pitches: [Pitch]) -> [Int] { pitches.map(\.midi) }

@Suite("scaleFromRoot")
struct ScaleFromRootTests {
    @Test func buildsCMajorFromMiddleC() {
        #expect(midi(Scale.major.pitches(root: Pitch(60))) == [60, 62, 64, 65, 67, 69, 71, 72])
    }
    @Test func buildsANaturalMinor() {
        #expect(midi(Scale.naturalMinor.pitches(root: Pitch(57))) == [57, 59, 60, 62, 64, 65, 67, 69])
    }
    @Test func buildsDDorianSameNotesAsCMajor() {
        #expect(midi(Scale.dorian.pitches(root: Pitch(62))) == [62, 64, 65, 67, 69, 71, 72, 74])
    }
    @Test func buildsCWholeTone() {
        #expect(midi(Scale.wholeTone.pitches(root: Pitch(60))) == [60, 62, 64, 66, 68, 70, 72])
    }
    @Test func buildsAMinorPentatonic() {
        #expect(midi(Scale.pentatonicMinor.pitches(root: Pitch(57))) == [57, 60, 62, 64, 67, 69])
    }
}

@Suite("isInScale")
struct IsInScaleTests {
    @Test func recognizesCMajorScaleTones() {
        for m in [60, 62, 64, 65, 67, 69, 71] { #expect(Scale.major.contains(Pitch(m), root: .c)) }
    }
    @Test func rejectsCSharpFromCMajor() {
        #expect(!Scale.major.contains(Pitch(61), root: .c))
    }
    @Test func worksAcrossOctaves() {
        #expect(Scale.major.contains(Pitch(72), root: .c))
        #expect(Scale.major.contains(Pitch(84), root: .c))
    }
}

@Suite("SCALE_INTERVALS catalog")
struct ScaleCatalogTests {
    @Test func containsAllCanonicalModes() {
        for name in ["major", "natural minor", "dorian", "phrygian", "lydian", "mixolydian", "locrian"] {
            #expect(Scale.named(name) != nil, "\(name)")
        }
    }
    @Test func diatonicScalesStartOnZeroAndSpanAnOctave() {
        for scale in [Scale.major, .naturalMinor, .dorian, .phrygian, .lydian, .mixolydian, .locrian] {
            #expect(scale.intervals.first == 0)
            #expect(scale.pitches(root: Pitch(60)).last == Pitch(72))
        }
    }
}

// Additional Scale / Mode / degree coverage

@Suite("Scale catalog")
struct ScaleCatalogExtraTests {
    @Test func everySourceScaleIsPresent() {
        let expected: [String: [Int]] = [
            "Major": [0, 2, 4, 5, 7, 9, 11],
            "Natural Minor": [0, 2, 3, 5, 7, 8, 10],
            "Harmonic Minor": [0, 2, 3, 5, 7, 8, 11],
            "Melodic Minor": [0, 2, 3, 5, 7, 9, 11],
            "Dorian": [0, 2, 3, 5, 7, 9, 10],
            "Phrygian": [0, 1, 3, 5, 7, 8, 10],
            "Lydian": [0, 2, 4, 6, 7, 9, 11],
            "Mixolydian": [0, 2, 4, 5, 7, 9, 10],
            "Locrian": [0, 1, 3, 5, 6, 8, 10],
            "Pentatonic Major": [0, 2, 4, 7, 9],
            "Pentatonic Minor": [0, 3, 5, 7, 10],
            "Blues": [0, 3, 5, 6, 7, 10],
            "Whole Tone": [0, 2, 4, 6, 8, 10],
            "Chromatic": Array(0..<12),
            "Hirajoshi": [0, 2, 3, 7, 8],
            "Fifths": [0, 7],
        ]
        #expect(Scale.all.count == expected.count)
        for (name, intervals) in expected {
            #expect(Scale.named(name)?.intervals == intervals, "\(name)")
        }
    }
    @Test func modesAreRotationsOfMajor() {
        #expect(Scale.ionian.hasSameIntervals(as: .major))
        #expect(Scale.aeolian.hasSameIntervals(as: .naturalMinor))
        #expect(Mode.dorian.intervals == [0, 2, 3, 5, 7, 9, 10])
        #expect(Mode.locrian.intervals == [0, 1, 3, 5, 6, 8, 10])
        #expect(Mode.major == .ionian)
        #expect(Mode.minor == .aeolian)
        #expect(Mode.allCases.filter(\.isMinorLike) == [.dorian, .phrygian, .aeolian, .locrian])
    }
    @Test func initNormalizesIntervals() {
        let scale = Scale(name: "odd", intervals: [7, 19, 3, 15])
        #expect(scale.intervals == [0, 3, 7])
    }
    @Test func lookupIsCaseInsensitive() {
        #expect(Scale.named("WHOLE TONE") == .wholeTone)
        #expect(Scale.named("aeolian") == .aeolian)
        #expect(Scale.named("nope") == nil)
    }
}

@Suite("Scale degrees")
struct ScaleDegreeTests {
    @Test func pitchClassesFromRoot() {
        #expect(Scale.major.pitchClasses(root: .g) == [.g, .a, .b, .c, .d, .e, .fSharp])
        #expect(Scale.pentatonicMinor.pitchClasses(root: .a) == [.a, .c, .d, .e, .g])
    }
    @Test func degreeLookupIsOneBased() {
        #expect(Scale.major.degree(of: .c, root: .c) == 1)
        #expect(Scale.major.degree(of: .b, root: .c) == 7)
        #expect(Scale.major.degree(of: .cSharp, root: .c) == nil)
        #expect(Scale.major.pitchClass(degree: 5, root: .c) == .g)
        #expect(Scale.major.pitchClass(degree: 8, root: .c) == .c)
        #expect(Scale.major.pitch(degree: 8, root: Pitch(60)) == Pitch(72))
        #expect(Scale.major.pitch(degree: 9, root: Pitch(60)) == Pitch(74))
        #expect(Scale.major.pitch(degree: 0, root: Pitch(60)) == Pitch(59))
    }
    @Test func degreeNames() {
        #expect(Scale.major.degreeNames.map(\.name) == [
            "Tonic", "Supertonic", "Mediant", "Subdominant", "Dominant", "Submediant", "Leading Tone",
        ])
        #expect(Scale.naturalMinor.degreeName(7) == .subtonic)
        #expect(Scale.harmonicMinor.degreeName(7) == .leadingTone)
        #expect(Scale.mixolydian.degreeName(7) == .subtonic)
        #expect(Scale.pentatonicMajor.degreeName(1) == nil)
        #expect(Scale.pentatonicMajor.degreeNames.isEmpty)
        #expect(ScaleDegree.subtonic.number == 7)
    }
    @Test func multipleOctaves() {
        #expect(midi(Scale.pentatonicMajor.pitches(root: Pitch(60), octaves: 2, includingOctave: false))
                == [60, 62, 64, 67, 69, 72, 74, 76, 79, 81])
        #expect(Scale.major.pitches(root: Pitch(60), octaves: 0).isEmpty)
    }
}

@Suite("Scale quantize")
struct ScaleQuantizeTests {
    @Test func scaleTonesAreUnchanged() {
        for m in [60, 62, 64, 65, 67, 69, 71, 72] {
            #expect(Scale.major.quantize(Pitch(m), root: .c) == Pitch(m))
        }
    }
    @Test func nonScaleTonesSnapToTheNearestAndTiesGoDown() {
        // C# is one semitone from both C and D: The-Chorus checks below first.
        #expect(Scale.major.quantize(Pitch(61), root: .c) == Pitch(60))
        #expect(Scale.major.quantize(Pitch(66), root: .c) == Pitch(65))
        #expect(Scale.major.quantize(Pitch(70), root: .c) == Pitch(69))
        #expect(Scale.major.quantize(midi: 73, root: .c) == 72)
    }
    @Test func snapsUpWhenTheNearestToneIsAbove() {
        // In C pentatonic major (C D E G A), F is 1 below G but 1 above E: tie goes down to E.
        #expect(Scale.pentatonicMajor.quantize(Pitch(65), root: .c) == Pitch(64))
        // F# is 1 from G and 2 from E: snaps up to G.
        #expect(Scale.pentatonicMajor.quantize(Pitch(66), root: .c) == Pitch(67))
        // In the fifths scale on C (C G), Eb (3 above C, 4 below G) snaps down to C; E (4/3) snaps up to G.
        #expect(Scale.fifths.quantize(Pitch(63), root: .c) == Pitch(60))
        #expect(Scale.fifths.quantize(Pitch(64), root: .c) == Pitch(67))
    }
    @Test func respectsTheRoot() {
        // D major: C natural is not diatonic, C# is.
        #expect(Scale.major.quantize(Pitch(60), root: .d) == Pitch(59))
        #expect(Scale.major.quantize(Pitch(61), root: .d) == Pitch(61))
    }
    @Test func chromaticQuantizeIsIdentity() {
        for m in 40...80 { #expect(Scale.chromatic.quantize(midi: m, root: .e) == m) }
    }
    @Test func frequencyQuantizeSnapsToScaleTones() {
        // 450 Hz is ~39 cents above A4; A is in C major, so it snaps to exactly 440.
        #expect(abs(Scale.major.quantize(frequency: 450, root: .c) - 440) < 1e-9)
        // 466.16 Hz (Bb4) is not in C major; it lies exactly between A and B, and the lower candidate wins.
        let bFlat = Pitch(70).frequency()
        #expect(abs(Scale.major.quantize(frequency: bFlat, root: .c) - 440) < 1e-6)
        // Slightly sharp of Bb snaps up to B.
        #expect(abs(Scale.major.quantize(frequency: bFlat * 1.01, root: .c) - Pitch(71).frequency()) < 1e-6)
        // Root offset: 440 Hz in D pentatonic minor (D F G A C) is A → unchanged.
        #expect(abs(Scale.pentatonicMinor.quantize(frequency: 440, root: .d) - 440) < 1e-9)
    }
    @Test func fractionalMidiQuantize() {
        #expect(Scale.major.quantize(midiValue: 60.4, root: .c) == 60)
        #expect(Scale.major.quantize(midiValue: 61.6, root: .c) == 62)
        #expect(Scale.major.quantize(midiValue: 71.9, root: .c) == 72)
        #expect(Scale.wholeTone.quantize(midiValue: 59.2, root: .c) == 60)
    }
}
