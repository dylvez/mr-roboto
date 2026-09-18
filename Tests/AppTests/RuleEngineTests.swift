import Foundation
import Testing

@testable import MrRobotoApp

// M4 Gate A, P2: a bible run by the engine answers the way its author does.

@Suite("Rule engine: a document-only persona")
struct RuleEngineTests {

    @Test("with the Bassist's bible it refuses, agrees and defers on the Bassist's goldens exactly as the Swift Bassist does")
    func matchesTheBassist() {
        let document = DocumentPersona(bible: Bassist.bible)
        let bassist = Bassist()
        for golden in Bassist.bible.goldens {
            guard let proposal = golden.proposal, let expects = golden.expects else { continue }
            let engine = VerdictShape(document.consider(proposal))
            let swift = VerdictShape(bassist.consider(proposal))
            let said = document.consider(proposal).spoken
            #expect(engine == expects, "\(golden.id): engine said \(engine.description), bible expects \(expects.description) — \(said)")
            #expect(engine == swift, "\(golden.id): engine \(engine.description) v Swift \(swift.description)")
        }
        // The house tempo cap applies at 120 and over, and not below.
        let fast = document.consider(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 130, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger"))
        #expect(fast.refusedByRule == "bassist.house-tempo", "\(fast.spoken)")
        // Thundercat's ten milliseconds is that player's range, not a lag budget failing.
        let thundercat = document.consider(.writeBassline(lineage: "thundercat", lagMS: 10, tempo: 84, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger"))
        #expect(thundercat.isAgreement, "\(thundercat.spoken)")
        // Ahead of the kick is refused by direction.
        #expect(document.consider(.pushBassAhead(milliseconds: 30, alternating: false)).refusedByRule == "bassist.direction")
        // The sub under a long kick is fine; a played bass is not.
        #expect(document.consider(.sustainUnder808(sound: "sub", kickDecaySeconds: 0.7)).isAgreement)
        #expect(document.consider(.sustainUnder808(sound: "finger", kickDecaySeconds: 0.7)).refusedByRule == "bassist.808-is-the-bass")
        // Nothing the Bassist measures: deferred to whoever owns the features.
        if case .defer_(let to, _) = document.consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90)) {
            #expect(to == .beatmaker)
        } else { Issue.record("a swing question is not the Bassist's") }
        if case .defer_(let to, _) = document.consider(.moveCutLate(milliseconds: 9)) {
            #expect(to == .sampler)
        } else { Issue.record("a cut is not the Bassist's") }
    }

    @Test("with the Sampler's bible it fires the Sampler's thresholds, in the bible's words")
    func runsTheSampler() {
        let document = DocumentPersona(bible: Sampler.bible)
        let far = document.consider(.transposeSample(label: "Horns", semitones: 9))
        #expect(far.refusedByRule == "sampler.past-four-semitones")
        if case .refuse(_, let because, let counter) = far {
            #expect(because.contains("merge.transpose.semitones is 9"))
            #expect(counter.hasPrefix("Say so"))
        }
        #expect(document.consider(.transposeSample(label: "Horns", semitones: 2)).isAgreement)
        #expect(document.consider(.mergeSources(drumSources: 2, uncleared: [])).refusedByRule == "sampler.one-drum-source")
        #expect(document.consider(.moveCutLate(milliseconds: 9)).refusedByRule == "sampler.cut-before-not-after")
        #expect(document.consider(.moveCutLate(milliseconds: 1)).isAgreement)
        #expect(document.consider(.chopDensity(slicesPerBar: 32, sourceTransients: 40)).isRefusal)
        #expect(document.consider(.leaveAlone(sourceBandwidthHz: 18_000)).isAgreement)
        // A groove question is the Beatmaker's.
        if case .defer_(let to, _) = document.consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90)) { #expect(to == .beatmaker) }
        else { Issue.record("swing is not the Sampler's") }
    }

    @Test("every proposal measures something, except the one that is out of scope")
    func measures() {
        #expect(ProposalMeasures.of(.outOfScope(what: "the artwork")).values.isEmpty)
        #expect(ProposalMeasures.of(.setSwing(percent: 56, idiom: "x", tempo: 90)).values[.swingPercent] == 56)
        #expect(ProposalMeasures.of(.displaceVoice(voice: "snare", milliseconds: -21, tempo: 90)).values[.snareLagMS] == -21)
        #expect(ProposalMeasures.of(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 92, hatLagMS: 50, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger")).values[.referenceLagMS] == 50)
        #expect(ProposalMeasures.of(.applyDegrade(preset: "cassette", sourceBandwidthHz: 9_000, sourceNoiseFloorDB: -60)).values[.bitDepth] != nil)
        #expect(PersonaID.owner(of: .snareLagMS) == .beatmaker && PersonaID.owner(of: .attackShaveMS) == .sampler && PersonaID.owner(of: .bassKickOffsetMS) == .bassist)
    }
}
