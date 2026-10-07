import SongGraph
import Testing
@testable import Performance

/// A section's groove, laid out to the section and marked at its edges the way a drummer would.
@Suite("Section fills")
struct SectionFillTests {
    /// Two bars of 4/4 sixteenths: kick on 1 and 3, snare on 2 and 4, eighth hats, a shaker on every step.
    static let groove = Groove(stepsPerBar: 16, bars: 2, patterns: [
        GroovePattern(voice: .kick, steps: (0..<32).map { $0 % 8 == 0 ? .accent : .rest }),
        GroovePattern(voice: .snare, steps: (0..<32).map { $0 % 8 == 4 ? .accent : .rest }),
        GroovePattern(voice: .closedHat, steps: (0..<32).map { $0 % 2 == 0 ? .normal : .rest }),
        GroovePattern(voice: .shaker, steps: [VelocityTier](repeating: .ghost, count: 32)),
    ])

    private func steps(_ groove: Groove, _ voice: DrumVoice) -> [VelocityTier] {
        groove.patterns.first { $0.voice == voice }?.steps ?? []
    }

    @Test("the loop is laid out to the section, and every pattern keeps the section's length")
    func laidOut() {
        let arranged = SectionFill.arranged(Self.groove, bars: 8, beatsPerBar: 4, fillIntoNext: true, crashIn: true)
        #expect(arranged.bars == 8)
        #expect(arranged.patterns.allSatisfy { $0.steps.count == 128 })
        // Away from the edges it is the loop, bar for bar.
        #expect(Array(steps(arranged, .snare)[32..<64]) == steps(Self.groove, .snare))
    }

    @Test("the last half bar is a fill down the toms; the hats rest, the shaker keeps going")
    func fill() {
        let arranged = SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fillIntoNext: true, crashIn: false)
        let start = 4 * 16 - 8
        #expect(steps(arranged, .closedHat)[start...].allSatisfy { $0 == .rest })
        #expect(steps(arranged, .kick)[start] == .accent)
        #expect(steps(arranged, .snare)[start] == .ghost)
        #expect(steps(arranged, .highTom)[start + 2] != .rest)
        #expect(steps(arranged, .midTom)[start + 4] == .accent)
        #expect(steps(arranged, .lowTom)[start + 7] != .rest)
        #expect(steps(arranged, .shaker)[start...].allSatisfy { $0 == .ghost })
        // Nothing before the fill moves.
        #expect(Array(steps(arranged, .closedHat)[0..<start]) == Array((0..<start).map { $0 % 2 == 0 ? VelocityTier.normal : .rest }))
    }

    @Test("a section after another opens on a crash, with the kick under it")
    func crash() {
        let arranged = SectionFill.arranged(Self.groove, bars: 2, beatsPerBar: 4, fillIntoNext: false, crashIn: true)
        #expect(steps(arranged, .crash).first == .accent)
        #expect(steps(arranged, .crash).dropFirst().allSatisfy { $0 == .rest })
        #expect(steps(arranged, .kick).first == .accent)
        #expect(steps(arranged, .highTom).isEmpty, "no fill was asked for")
    }

    @Test("nothing to mark, or a one-bar section with only a fill, leaves the groove alone")
    func untouched() {
        #expect(SectionFill.arranged(Self.groove, bars: 8, beatsPerBar: 4, fillIntoNext: false, crashIn: false) == Self.groove)
        #expect(SectionFill.arranged(Self.groove, bars: 1, beatsPerBar: 4, fillIntoNext: true, crashIn: false) == Self.groove)
    }

    @Test("in 3/4 the fill takes the last beat; in 6/8 on eighths it takes the last three eighths")
    func otherMeters() {
        let waltz = Groove(stepsPerBar: 12, bars: 1, patterns: [
            GroovePattern(voice: .kick, steps: (0..<12).map { $0 == 0 ? .accent : .rest }),
        ])
        let arranged = SectionFill.arranged(waltz, bars: 2, beatsPerBar: 3, fillIntoNext: true, crashIn: false)
        let toms = [DrumVoice.snare, .highTom, .midTom, .lowTom].flatMap { voice in
            steps(arranged, voice).indices.filter { steps(arranged, voice)[$0] != .rest }
        }
        #expect(toms.min() == 20 && toms.max() == 23)

        let sixEight = Groove(stepsPerBar: 6, bars: 2, patterns: [
            GroovePattern(voice: .kick, steps: (0..<12).map { $0 % 6 == 0 ? .accent : .rest }),
        ])
        let bell = SectionFill.arranged(sixEight, bars: 4, beatsPerBar: 6, fillIntoNext: true, crashIn: false)
        let fillSteps = [DrumVoice.snare, .highTom, .midTom, .lowTom].flatMap { voice in
            steps(bell, voice).indices.filter { steps(bell, voice)[$0] != .rest }
        }
        #expect(fillSteps.min() == 21 && fillSteps.max() == 23)
    }
}

/// Every feel the library ships is heard on every kit: no line on a voice no machine plays.
@Suite("Feels and kits")
struct FeelVoicesTests {
    @Test("every voice a shipped feel writes is one the kits have")
    func everyVoiceIsPlayable() {
        let kitVoices: Set<DrumVoice> = [
            .kick, .snare, .clap, .rim, .closedHat, .openHat, .ride, .crash, .lowTom, .midTom, .highTom, .cowbell,
            .shaker, .tambourine, .highConga, .lowConga, .highBongo, .lowBongo, .claves, .woodblock,
            .highAgogo, .lowAgogo, .cabasa, .guiro, .guiroLong, .openTriangle, .muteTriangle, .vibraslap,
            .cajon, .cajonSlap, .darbuka, .darbukaTek, .frameDrum, .slitDrum,
        ]
        for feel in FeelLibrary.standard.feels {
            for pattern in feel.groove.patterns {
                #expect(kitVoices.contains(pattern.voice), "\(feel.name) writes \(pattern.voice), which no kit plays")
            }
        }
    }

    @Test("every shipped feel's steps fill its bars, and its bars divide into its meter")
    func shapes() {
        for feel in FeelLibrary.standard.feels {
            let groove = feel.groove
            #expect(groove.patterns.allSatisfy { $0.steps.count == groove.stepsPerBar * groove.bars }, "\(feel.name)")
            #expect(groove.stepsPerBar % feel.timeSignature.beatsPerBar == 0, "\(feel.name)")
            #expect(feel.tempoRange.contains(feel.suggestedTempo), "\(feel.name)")
            #expect(feel.tempoRange.upperBound <= 300, "\(feel.name) asks for more than the clock runs")
        }
    }
}
