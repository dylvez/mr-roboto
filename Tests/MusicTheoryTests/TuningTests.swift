import Testing
@testable import MusicTheory

@Suite("Equal temperament")
struct EqualTemperamentTests {
    @Test func midiAndFrequencyRoundTrip() {
        #expect(EqualTemperament.frequency(midi: 69) == 440)
        #expect(abs(EqualTemperament.frequency(midi: 60) - 261.6256) < 0.001)
        #expect(abs(EqualTemperament.midi(frequency: 440) - 69) < 1e-9)
        #expect(abs(EqualTemperament.midi(frequency: 880) - 81) < 1e-9)
        #expect(abs(EqualTemperament.midi(frequency: 261.6256) - 60) < 0.001)
        #expect(abs(EqualTemperament.frequency(midi: 69, a4: 432) - 432) < 1e-9)
    }
    @Test func nonPositiveFrequenciesAreClamped() {
        #expect(EqualTemperament.midi(frequency: 0).isFinite)
        #expect(EqualTemperament.midi(frequency: -5).isFinite)
    }
    @Test func cents() {
        #expect(abs(EqualTemperament.cents(from: 440, to: 880) - 1200) < 1e-9)
        #expect(abs(EqualTemperament.cents(from: 440, to: 220) + 1200) < 1e-9)
        #expect(abs(EqualTemperament.cents(ratio: EqualTemperament.semitoneRatio) - 100) < 1e-9)
        #expect(abs(EqualTemperament.ratio(cents: 1200) - 2) < 1e-12)
    }
}

@Suite("Just intervals")
struct JustIntervalTests {
    @Test func ratiosAreReduced() {
        #expect(JustInterval(6, 4) == .perfectFifth)
        #expect(JustInterval(6, 4).description == "3:2")
        #expect(JustInterval(10, 5) == .octave)
        #expect(JustInterval.perfectFifth.ratio == 1.5)
    }
    @Test func harmonographPaletteRatios() {
        #expect(JustInterval.harmonographIntervals.map(\.description)
                == ["1:1", "2:1", "3:2", "4:3", "5:4", "5:3", "6:5", "7:5"])
        #expect(JustInterval.harmonographIntervals.map(\.name) == [
            "Unison", "Octave", "Perfect fifth", "Perfect fourth", "Major third", "Major sixth", "Minor third", "Tritone",
        ])
    }
    @Test func centsAndDeviationFromEqualTemperament() {
        #expect(abs(JustInterval.perfectFifth.cents - 701.955) < 0.001)
        #expect(abs(JustInterval.majorThird.cents - 386.314) < 0.001)
        #expect(abs(JustInterval.octave.cents - 1200) < 1e-9)
        #expect(JustInterval.perfectFifth.nearestInterval == .perfectFifth)
        #expect(JustInterval.majorThird.nearestInterval == .majorThird)
        #expect(JustInterval.tritone.nearestInterval == .tritone)
        #expect(abs(JustInterval.perfectFifth.centsFromEqualTemperament - 1.955) < 0.001)
        #expect(abs(JustInterval.majorThird.centsFromEqualTemperament + 13.686) < 0.001)
    }
    @Test func harmonicSeries() {
        #expect(JustInterval.senario.map(\.description) == ["1:1", "2:1", "3:1", "4:1", "5:1", "6:1"])
        #expect(JustInterval.harmonicSeries(count: 8).count == 8)
        #expect(JustInterval.harmonic(3).reducedToOctave == .perfectFifth)
        #expect(JustInterval.harmonic(5).reducedToOctave == .majorThird)
        #expect(JustInterval.harmonic(6).reducedToOctave == .perfectFifth)
        #expect(JustInterval.harmonic(7).reducedToOctave == .harmonicSeventh)
        #expect(JustInterval.harmonic(8).reducedToOctave == .unison)
        #expect(JustInterval(1, 3).reducedToOctave == .perfectFourth)
        #expect(JustInterval.ratios([4, 5, 6]).map(\.description) == ["1:1", "5:4", "3:2"])
        #expect(JustInterval.ratios([]).isEmpty)
    }
    @Test func inversionAndStacking() {
        #expect(JustInterval.perfectFifth.inverted == .perfectFourth)
        #expect(JustInterval.majorThird.inverted == .minorSixth)
        #expect(JustInterval.perfectFifth * .perfectFourth == .octave)
        #expect(JustInterval.majorThird * .minorThird == .perfectFifth)
        #expect(abs(JustInterval.perfectFifth.frequency(above: 196) - 294) < 1e-9)
    }
}
