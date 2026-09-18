import Foundation
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The method, as tests.
//
// The pilot bible's argument was that a role is only useful when it is written as measurable
// features and if/then rules with thresholds, and when every claim says whether anybody wrote it
// down. Those are properties of a value, so they are assertable — and these are the assertions that
// stop the next bible from being a mood board with citations glued on.
//
// Nothing here is about music. These tests would pass for a Bassist or a Mixer; they are about
// whether a bible is the shape the method requires.

private let bibles: [PersonaBible] = [Beatmaker.bible, Sampler.bible]

@Suite("Persona: the method holds for every bible")
struct PersonaMethodTests {

    @Test("Every claim is marked cited or inferred, and every mark is well formed",
          arguments: bibles)
    func everyClaimIsMarked(_ bible: PersonaBible) {
        #expect(!bible.claims.isEmpty)
        for claim in bible.claims {
            // There is no third case to fall into, so the real test is that a *cited* claim carries
            // URLs and an *inferred* one says what it was derived from. A citation with no link and
            // an inference with no basis are the two ways to fake this.
            #expect(claim.evidence.isWellFormed,
                    "\(bible.name): \"\(claim.statement)\" is marked but its mark is empty")
        }
    }

    @Test("Most of the bible is cited, and the inferred part is a real minority",
          arguments: bibles)
    func mostlyCited(_ bible: PersonaBible) {
        let cited = bible.citedClaimCount
        let inferred = bible.inferredClaimCount
        #expect(cited + inferred == bible.claims.count)
        #expect(cited > inferred,
                "\(bible.name): \(inferred) inferred against \(cited) cited — that is a bible of guesses")
        // And the inferred part is not zero, because a bible with nothing inferred is a bible that
        // did not admit anything.
        #expect(inferred > 0, "\(bible.name): nothing is marked inferred, which is not credible")
    }

    @Test("Every rule that thresholds names a feature the vocabulary defines", arguments: bibles)
    func thresholdsAreDefined(_ bible: PersonaBible) {
        #expect(bible.undefinedThresholdFeatures.isEmpty,
                "\(bible.name): thresholds on undefined features \(bible.undefinedThresholdFeatures)")
    }

    /// The mechanical form of "a rule that cannot be expressed against the engines is a rule the app
    /// cannot apply". Every feature names the engine property it is read from, and every rule names
    /// the engine property it would move.
    @Test("Every feature is measurable and every rule is applicable", arguments: bibles)
    func everythingIsApplicable(_ bible: PersonaBible) {
        #expect(bible.unmeasurableFeatures.isEmpty,
                "\(bible.name): features with no engine field \(bible.unmeasurableFeatures)")
        for rule in bible.rules {
            #expect(!rule.engineAction.isEmpty,
                    "\(bible.name): rule \(rule.id) names no engine action")
            // The engine field has to name something in the engines, not a hope. Every one of these
            // prefixes is a real module or a real type in this package.
            let known = ["Performance.", "Instrument.", "SongGraph.", "Analysis.", "MusicTheory.",
                         "SourceMeasurement", "refuse", "clamp", "the "]
            #expect(known.contains { rule.engineAction.contains($0) },
                    "\(bible.name): rule \(rule.id) acts on \(rule.engineAction), which is nothing in the engines")
        }
    }

    @Test("Most rules carry a threshold, and a rule without one is genuinely categorical",
          arguments: bibles)
    func rulesAreMeasurable(_ bible: PersonaBible) {
        let withThreshold = bible.rules.filter { $0.threshold != nil }
        #expect(withThreshold.count * 2 > bible.rules.count,
                "\(bible.name): fewer than half the rules are measurable")
        #expect(bible.rules.count >= 10, "\(bible.name): \(bible.rules.count) rules is a sketch")
    }

    @Test("Rule ids are unique and namespaced to the persona", arguments: bibles)
    func ruleIDsAreClean(_ bible: PersonaBible) {
        #expect(Set(bible.rules.map(\.id)).count == bible.rules.count)
        for rule in bible.rules {
            #expect(rule.id.hasPrefix(bible.id.rawValue + "."),
                    "\(rule.id) is not namespaced to \(bible.id)")
        }
    }

    @Test("Two or three named practitioners, each with a stated reason", arguments: bibles)
    func lineagesAreChosen(_ bible: PersonaBible) {
        #expect(bible.lineages.count >= 3 && bible.lineages.count <= 4)
        for lineage in bible.lineages {
            #expect(lineage.why.count > 80,
                    "\(lineage.name): \"why\" is too short to be a reason")
            #expect(!lineage.period.isEmpty)
        }
    }

    @Test("Every lineage named in a range is a lineage the bible declares", arguments: bibles)
    func rangesBelongToLineages(_ bible: PersonaBible) {
        let names = Set(bible.lineages.map(\.name))
        for range in bible.ranges {
            #expect(names.contains(range.lineage),
                    "\(bible.name): range for an unknown lineage \"\(range.lineage)\"")
        }
    }

    @Test("Ranges are well formed and at least three features carry one per lineage",
          arguments: bibles)
    func rangesAreUseful(_ bible: PersonaBible) {
        for range in bible.ranges {
            #expect(range.low <= range.high)
            if let typical = range.typical {
                #expect(range.contains(typical),
                        "\(range.lineage)/\(range.feature): typical \(typical) is outside \(range.low)…\(range.high)")
            }
        }
        for lineage in bible.lineages {
            let mine = bible.ranges.filter { $0.lineage == lineage.name }
            #expect(mine.count >= 2,
                    "\(lineage.name) has \(mine.count) ranges — not enough to be a lineage with a sound")
        }
    }

    @Test("It listens in a stated order, starting from one thing", arguments: bibles)
    func listeningIsOrdered(_ bible: PersonaBible) {
        #expect(bible.listensFor.count >= 4)
        #expect(bible.listensFor.first?.priority == 1)
        #expect(Set(bible.listensFor.map(\.priority)).count == bible.listensFor.count)
        let defined = Set(bible.vocabulary.map(\.feature))
        for point in bible.listensFor {
            #expect(!point.features.isEmpty, "\(point.what) reads nothing")
            for feature in point.features {
                #expect(defined.contains(feature),
                        "\(bible.name) listens for \(feature), which the vocabulary does not define")
            }
        }
    }

    @Test("It knows how it talks, and what it will not say", arguments: bibles)
    func voiceAndRefusals(_ bible: PersonaBible) {
        #expect(bible.voice.examples.count >= 3)
        #expect(!bible.voice.usesWords.isEmpty)
        #expect(!bible.voice.avoidsWords.isEmpty)
        #expect(bible.refusals.count >= 3)
        for refusal in bible.refusals {
            #expect(!refusal.because.isEmpty)
            // A refusal with no alternative is an obstacle, not a role.
            #expect(!refusal.instead.isEmpty, "\(refusal.id) refuses without offering anything")
        }
    }

    @Test("It says how it disagrees with every other persona in the cast", arguments: bibles)
    func disagreesWithEveryone(_ bible: PersonaBible) {
        let others = [PersonaID.beatmaker, .sampler, .bassist].filter { $0 != bible.id }
        for other in others {
            let disagreement = bible.disagreement(with: other)
            #expect(disagreement != nil, "\(bible.name) has nothing to say about the \(other)")
            // And the disagreement has to be settleable, not just stated.
            #expect(disagreement.map { !$0.settledBy.isEmpty } ?? false,
                    "\(bible.name) v \(other): no way to settle it")
            #expect(disagreement.map { !$0.theirs.isEmpty } ?? false,
                    "\(bible.name) v \(other): the other side is not stated")
        }
    }

    @Test("Reference tracks name the bars, not just the record", arguments: bibles)
    func referencesNameBars(_ bible: PersonaBible) {
        #expect(bible.references.count >= 4)
        for reference in bible.references {
            #expect(!reference.bars.isEmpty,
                    "\(reference.id): no bars — a reference nobody can put the needle on")
            #expect(reference.listenFor.count > 40,
                    "\(reference.id): \"listen for\" is too short to point at anything")
            #expect(!reference.features.isEmpty)
        }
    }

    @Test("At least five goldens, each with a checkable pass criterion", arguments: bibles)
    func goldensAreStated(_ bible: PersonaBible) {
        #expect(bible.goldens.count >= 5, "\(bible.name): \(bible.goldens.count) goldens")
        #expect(Set(bible.goldens.map(\.id)).count == bible.goldens.count)
        let ruleIDs = Set(bible.rules.map(\.id))
        for golden in bible.goldens {
            #expect(!golden.premise.isEmpty)
            #expect(golden.passes.count > 30, "\(golden.id): the pass criterion is not checkable")
            for rule in golden.exercises {
                #expect(ruleIDs.contains(rule), "\(golden.id) exercises unknown rule \(rule)")
            }
        }
        // One golden has to be a disagreement: a persona that never pushes back is a filter.
        #expect(bible.goldens.contains { $0.id.hasSuffix("pushes-back") },
                "\(bible.name): no golden proves it pushes back")
    }

    @Test("Open questions state both readings and what would change", arguments: bibles)
    func openQuestionsAreHonest(_ bible: PersonaBible) {
        #expect(bible.openQuestions.count >= 4,
                "\(bible.name): \(bible.openQuestions.count) open questions is suspiciously confident")
        let ruleIDs = Set(bible.rules.map(\.id))
        for question in bible.openQuestions {
            #expect(!question.encoded.isEmpty)
            #expect(question.alternative.count > 60,
                    "\(question.id): the alternative is not stated fairly enough to switch to")
            for rule in question.affects {
                #expect(ruleIDs.contains(rule), "\(question.id) affects unknown rule \(rule)")
            }
        }
    }

    @Test("Every URL is an https reference rather than a note to self", arguments: bibles)
    func urlsAreURLs(_ bible: PersonaBible) {
        let urls = bible.references_urls
        #expect(urls.count >= 10, "\(bible.name) leans on \(urls.count) sources")
        for url in urls {
            #expect(url.hasPrefix("https://"), "\(url) is not a link")
            #expect(URL(string: url) != nil, "\(url) does not parse")
        }
    }
}

// MARK: - The bibles against each other

@Suite("Persona: the two bibles fit together")
struct PersonaCastTests {

    @Test("They own different things and say so")
    func differentDomains() {
        #expect(Beatmaker.bible.id != Sampler.bible.id)
        let beatmakerFeatures = Set(Beatmaker.bible.vocabulary.map(\.feature))
        let samplerFeatures = Set(Sampler.bible.vocabulary.map(\.feature))
        // Some overlap is right — both care about tempo — but the two vocabularies must not be the
        // same vocabulary, or the two personas are one persona with two names.
        let shared = beatmakerFeatures.intersection(samplerFeatures)
        #expect(shared.count <= 2, "the two vocabularies overlap on \(shared)")
        #expect(!beatmakerFeatures.isSubset(of: samplerFeatures))
        #expect(!samplerFeatures.isSubset(of: beatmakerFeatures))
    }

    @Test("Their disagreement is the same disagreement, stated from both sides")
    func theyDisagreeAboutTheSameThing() throws {
        let his = try #require(Beatmaker.bible.disagreement(with: .sampler))
        let hers = try #require(Sampler.bible.disagreement(with: .beatmaker))
        #expect(his.about == hers.about)
        // Each one's statement of the other's position has to resemble the other's own statement of
        // it. Checked loosely, on the load-bearing noun, because these are sentences and not keys.
        #expect(his.theirs.contains("transient") && hers.position.contains("transient"))
        #expect(hers.theirs.contains("swing") && his.position.contains("swing"))
        // And both agree on how it gets settled.
        #expect(his.settledBy.contains("SourceSwing") && hers.settledBy.contains("SourceSwing"))
        #expect(his.settledBy.contains("10 ms") && hers.settledBy.contains("10 ms"))
    }

    @Test("Each defers the other's work rather than answering it")
    func theyDefer() {
        let beatmaker = Beatmaker()
        let sampler = Sampler()

        let chainToBeatmaker = beatmaker.consider(
            .applyDegrade(preset: "vinyl", sourceBandwidthHz: 16_000, sourceNoiseFloorDB: -60))
        if case .defer_(let to, _) = chainToBeatmaker {
            #expect(to == .sampler)
        } else {
            Issue.record("the Beatmaker answered a chain question: \(chainToBeatmaker)")
        }

        let swingToSampler = sampler.consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90))
        if case .defer_(let to, _) = swingToSampler {
            #expect(to == .beatmaker)
        } else {
            Issue.record("the Sampler answered a swing question: \(swingToSampler)")
        }
    }

    @Test("The cast routes a proposal to whoever owns it, and to nobody when nobody does")
    func theCastRoutes() {
        let cast = Cast.standard
        #expect(cast.personas.count == 2)
        #expect(cast.bibles.map(\.id) == [.beatmaker, .sampler])

        #expect(cast.owner(of: .setSwing(percent: 56, idiom: "lo-fi", tempo: 90)) == .beatmaker)
        #expect(cast.owner(of: .moveCutLate(milliseconds: 9)) == .sampler)
        // Something neither of them measures: both defer, and the cast says so rather than picking
        // whoever answered first.
        #expect(cast.owner(of: .outOfScope(what: "the vocal's tuning")) == nil)

        // Objections are the refusals only, which is what a Director has to surface before acting.
        let objections = cast.objections(to: .moveCutLate(milliseconds: 9))
        #expect(objections.count == 1)
        #expect(objections.first?.persona == .sampler)
        #expect(cast.objections(to: .leaveAlone(sourceBandwidthHz: 18_000)).isEmpty)

        // And asking always gets an answer from everybody.
        #expect(cast.ask(.quantiseHard(idiom: "lo-fi")).count == 2)
    }

    @Test("Every finding a shipped critic can make belongs to a persona in the cast")
    func criticsBelongToPersonas() {
        let known: Set<PersonaID> = [Beatmaker.bible.id, Sampler.bible.id]
        for critic in CriticBoard.standard.all {
            #expect(known.contains(critic.persona),
                    "\(critic.id) is owned by \(critic.persona), who is not in the cast")
            #expect(!critic.checks.isEmpty, "\(critic.id) does not say what it checks")
        }
    }
}
