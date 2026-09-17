import Foundation
import Testing
@testable import Performance

@Suite("Slice classifier")
struct SliceClassifierTests {
    static let sr: Double = 48_000

    /// One sound per slice, half a second apart, so the classifier sees exactly one drum each time.
    static func chopOf(_ sounds: [[Float]]) -> (signal: [Float], chop: Chop) {
        let spacing = 0.5
        let signal = ChopFixtures.place(sounds.enumerated().map { (Double($0.offset) * spacing, $0.element) },
                                        length: spacing * Double(sounds.count), sampleRate: sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: sr, divisions: sounds.count)
        return (signal, chop)
    }

    @Test("a low sine is a kick and a noise burst is a hat")
    func lowSineIsAKickNoiseIsAHat() {
        let (signal, chop) = Self.chopOf([
            ChopFixtures.decayingSine(sampleRate: Self.sr, frequency: 55, duration: 0.3, decay: 18),
            ChopFixtures.noiseBurst(sampleRate: Self.sr, duration: 0.04, decay: 120, seed: 11),
        ])
        let result = SliceClassifier().classify(chop, in: signal)

        #expect(result[0].kind == .kick, "centroid \(result[0].centroid) Hz was not a kick")
        #expect(result[1].kind == .hat, "centroid \(result[1].centroid) Hz was not a hat")
        #expect(result[0].centroid < result[1].centroid)
        #expect(result.allSatisfy { $0.confidence > 0 })
    }

    @Test("a lowpassed noise-plus-tone burst lands on the snare")
    func bandLimitedNoiseIsASnare() {
        let (signal, chop) = Self.chopOf([
            ChopFixtures.kick(Self.sr), ChopFixtures.snare(Self.sr), ChopFixtures.hat(Self.sr),
        ])
        let result = SliceClassifier().classify(chop, in: signal)

        #expect(result.map(\.kind) == [.kick, .snare, .hat])
    }

    @Test("length, not the slice's length, decides whether a bright slice is a hat")
    func hatRuleUsesTheSoundsOwnLength() {
        let classifier = SliceClassifier()
        // A closed hat cut on an eighth grid is a 40 ms sound inside a 330 ms slice. The slice's
        // length must not turn it into a ride.
        let (signal, chop) = Self.chopOf([ChopFixtures.hat(Self.sr)])
        let result = classifier.classify(chop, in: signal)
        #expect(result[0].duration > 0.4)
        #expect(result[0].effectiveDuration < 0.15)
        #expect(result[0].kind == .hat)

        // But a bright sound that really does ring is not a closed hat, and the rule says so.
        #expect(classifier.score(centroid: 9000, duration: 0.05).ranked[0].kind == .hat)
        #expect(classifier.score(centroid: 9000, duration: 0.6).ranked[0].kind == .snare)
    }

    @Test("the scoring rule is legible on its own")
    func scoringRule() {
        let classifier = SliceClassifier()
        #expect(classifier.score(centroid: 80, duration: 0.2).ranked[0].kind == .kick)
        #expect(classifier.score(centroid: 2600, duration: 0.15).ranked[0].kind == .snare)
        #expect(classifier.score(centroid: 11_000, duration: 0.04).ranked[0].kind == .hat)
        // Scores are negative octave distances, so a perfect match is 0 and every score is ≤ 0.
        #expect(classifier.score(centroid: 150, duration: 0.1).kick == 0)
        #expect(classifier.score(centroid: 300, duration: 0.1).kick == -1)
    }

    @Test("a hand can overrule the machine, and it stays visible that it did")
    func overridesAreExposed() {
        let (signal, chop) = Self.chopOf([ChopFixtures.kick(Self.sr), ChopFixtures.hat(Self.sr)])
        let machine = SliceClassifier().classify(chop, in: signal)
        let edited = SliceClassifier().classify(chop, in: signal, overrides: [0: .snare])

        #expect(machine[0].kind == .kick)
        #expect(edited[0].kind == .snare)
        #expect(edited[0].isOverride)
        // The measurement that the override disagrees with is still there.
        #expect(edited[0].centroid == machine[0].centroid)
        #expect(edited[1].isOverride == false)
    }

    @Test("a silent slice is classified with no confidence rather than guessed at")
    func silenceHasNoConfidence() {
        let signal = [Float](repeating: 0, count: Int(Self.sr))
        let chop = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 2)
        let result = SliceClassifier().classify(chop, in: signal)

        #expect(result.allSatisfy { $0.confidence == 0 })
    }
}
