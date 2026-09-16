import Testing
@testable import MusicTheory

// Translated from game/src/theory/intervals.test.ts

@Suite("INTERVALS catalog")
struct IntervalCatalogTests {
    @Test func containsAllThirteenSimpleIntervals() {
        #expect(Interval.simpleIntervals.count == 13)
    }
    @Test func semitonesAreMonotonicallyIncreasing() {
        let catalog = Interval.simpleIntervals
        for i in 1..<catalog.count {
            #expect(catalog[i].semitones > catalog[i - 1].semitones)
        }
    }
    @Test func hasUniqueNames() {
        let names = Interval.simpleIntervals.map(\.shortName)
        #expect(Set(names).count == names.count)
    }
}

@Suite("INTERVAL_BY_NAME")
struct IntervalByNameTests {
    @Test func looksUpIntervalsByName() {
        #expect(Interval.named("M3")?.semitones == 4)
        #expect(Interval.named("P5")?.semitones == 7)
        #expect(Interval.named("P8")?.semitones == 12)
        #expect(Interval.named("TT") == .tritone)
    }
}

@Suite("intervalBetween")
struct IntervalBetweenTests {
    @Test func findsTheIntervalBetweenTwoMidiNotes() {
        #expect(Interval.between(Pitch(60), Pitch(64)).shortName == "M3")
        #expect(Interval.between(Pitch(60), Pitch(67)).shortName == "P5")
        #expect(Interval.between(Pitch(60), Pitch(72)).shortName == "P8")
    }
    @Test func handlesDescendingSameAbsoluteDistance() {
        #expect(Interval.between(Pitch(72), Pitch(60)).shortName == "P8")
        #expect(Interval.between(Pitch(67), Pitch(60)).shortName == "P5")
    }
}

@Suite("intervalAbove / intervalBelow")
struct IntervalAboveBelowTests {
    @Test func appliesIntervalUpward() {
        #expect(Interval.majorThird.above(Pitch(60)) == Pitch(64))
        #expect(Interval.perfectFifth.above(Pitch(60)) == Pitch(67))
        #expect(Interval.octave.above(Pitch(60)) == Pitch(72))
    }
    @Test func appliesIntervalDownward() {
        #expect(Interval.octave.below(Pitch(72)) == Pitch(60))
        #expect(Interval.perfectFifth.below(Pitch(72)) == Pitch(65))
    }
}

// Additional Interval coverage

@Suite("Interval extras")
struct IntervalExtraTests {
    @Test func numberQualityValidation() {
        #expect(Interval(number: 5, quality: .major) == nil)
        #expect(Interval(number: 3, quality: .perfect) == nil)
        #expect(Interval(number: 0, quality: .perfect) == nil)
        #expect(Interval(number: 5, quality: .diminished)?.semitones == 6)
        #expect(Interval(number: 2, quality: .augmented)?.semitones == 3)
        #expect(Interval(number: 7, quality: .diminished)?.semitones == 9)
        #expect(Interval(number: 3, quality: .diminished)?.semitones == 2)
    }
    @Test func semitoneInitializerCoversCompoundIntervals() {
        #expect(Interval(semitones: 0) == .unison)
        #expect(Interval(semitones: 6) == .tritone)
        #expect(Interval(semitones: -7) == .perfectFifth)
        #expect(Interval(semitones: 16).shortName == "M10")
        #expect(Interval(semitones: 16).semitones == 16)
        #expect(Interval(semitones: 24).shortName == "P15")
        #expect(Interval(semitones: 24).semitones == 24)
        #expect(Interval(semitones: 13).shortName == "m9")
        for s in 0...36 { #expect(Interval(semitones: s).semitones == s, "\(s)") }
    }
    @Test func inversion() {
        #expect(Interval.majorThird.inverted == .minorSixth)
        #expect(Interval.perfectFifth.inverted == .perfectFourth)
        #expect(Interval.octave.inverted == .unison)
        #expect(Interval.unison.inverted == .octave)
        #expect(Interval.tritone.inverted == .diminishedFifth)
        #expect(Interval.majorSeventh.inverted == .minorSecond)
        #expect(Interval(semitones: 16).inverted == .minorSixth)
        for interval in Interval.simpleIntervals where interval.number < 8 {
            #expect(interval.semitones + interval.inverted.semitones == 12, "\(interval.shortName)")
        }
    }
    @Test func simpleAndCompound() {
        #expect(Interval(semitones: 16).isCompound)
        #expect(Interval(semitones: 16).simple == .majorThird)
        #expect(Interval(semitones: 24).simple == .octave)
        #expect(!Interval.octave.isCompound)
    }
    @Test func names() {
        #expect(Interval.majorThird.longName == "Major third")
        #expect(Interval.tritone.longName == "Tritone")
        #expect(Interval.tritone.shortName == "A4")
        #expect(Interval.diminishedFifth.longName == "Diminished fifth")
        #expect(Interval(semitones: 14).longName == "Major ninth")
        #expect("\(Interval.perfectFifth)" == "P5")
    }
}
