import CoreGraphics
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Tests for the Compare surface's *model* and its layout. No view, no audio device: what is checked
// here is that the surface keeps its own contract — two to four rows, the reference always visible
// and never selectable, differences marked against a threshold that comes from a persona rather than
// from this file, at most two levers, and every row auditioning in place.

// MARK: - A stub host

/// What the surface asked the engine to do, recorded.
@MainActor
final class CompareHostStub: CompareHosting {
    struct Play: Sendable {
        var id: String
        var levers: [CompareLever: Double]
    }

    private(set) var plays: [Play] = []
    private(set) var stops = 0
    private(set) var chosen: [String] = []
    /// Set to make `choose` refuse, so the surface's refusal path is testable.
    var refuseChoices = false

    var lastPlay: Play? { plays.last }

    func audition(_ candidate: CompareCandidate, levers: [CompareLever: Double]) async {
        plays.append(Play(id: candidate.id, levers: levers))
    }

    func auditionReference(_ reference: CompareReference, levers: [CompareLever: Double]) async {
        plays.append(Play(id: CompareModel.referenceID, levers: levers))
    }

    func stopAudition() { stops += 1 }

    func choose(_ candidate: CompareCandidate) async -> Bool {
        guard !refuseChoices else { return false }
        chosen.append(candidate.id)
        return true
    }
}

/// Waits for the surface's fire-and-forget auditions to land.
@MainActor
private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Fixtures

@MainActor
private enum CompareFixtures {

    /// Three feels off the shipped library, read as candidates, judged against the one on the bench.
    /// Real values: every reading below is `GrooveObservation` over a `Feel`, so the numbers in the
    /// test are the numbers the engine would play.
    static func feelComparison(levers: [CompareLever] = [.tempo, .swing]) throws -> (CompareModel, CompareHostStub) {
        let library = FeelLibrary.standard
        let reference = try #require(library.feel(named: "Boom-Bap Pocket"))
        let candidates = try [
            #require(library.feel(named: "Lo-Fi Hip-Hop")),
            #require(library.feel(named: "Neo-Soul Pocket")),
            #require(library.feel(named: "Trip-Hop")),
        ]
        let features: [Feature] = [.swingPercent, .snareLagMS, .ghostRatio]
        let host = CompareHostStub()
        let model = try CompareModel(
            title: "Three feels for bar 9",
            reference: reference_(reference, features: features),
            candidates: candidates.map { candidate_($0, features: features) },
            features: features,
            levers: levers,
            vocabulary: Beatmaker.bible,
            host: host)
        return (model, host)
    }

    static func reference_(_ feel: Feel, features: [Feature]) -> CompareReference {
        let observation = GrooveObservation(feel)
        return CompareReference(title: feel.name, kind: "the version on the bench",
                                readings: readings(observation, features))
    }

    static func candidate_(_ feel: Feel, features: [Feature]) -> CompareCandidate {
        let observation = GrooveObservation(feel)
        return CompareCandidate(id: feel.name, title: feel.name, proposedBy: .beatmaker,
                                rationale: feel.provenance.summary,
                                readings: readings(observation, features))
    }

    static func readings(_ observation: GrooveObservation, _ features: [Feature]) -> [CompareReading] {
        features.compactMap { feature in
            observation.value(of: feature).map {
                CompareReading(feature, $0, unit: unit(of: feature))
            }
        }
    }

    static func unit(of feature: Feature) -> String {
        Beatmaker.bible.definition(of: feature).map { definition in
            definition.unit.split(separator: ",").first.map(String.init) ?? definition.unit
        } ?? ""
    }

    /// The smallest legal comparison: two rows, no levers.
    static func pair() throws -> (CompareModel, CompareHostStub) {
        let host = CompareHostStub()
        let model = try CompareModel(
            title: "Two",
            reference: CompareReference(title: "As it is", kind: "the bench",
                                        readings: [CompareReading(.swingPercent, 50, unit: "%")]),
            candidates: [
                CompareCandidate(id: "a", title: "A",
                                 readings: [CompareReading(.swingPercent, 58, unit: "%")]),
                CompareCandidate(id: "b", title: "B",
                                 readings: [CompareReading(.swingPercent, 51, unit: "%")]),
            ],
            features: [.swingPercent],
            host: host)
        return (model, host)
    }
}

// MARK: - The contract

@MainActor
@Suite("Compare surface: the contract", .serialized)
struct CompareContractTests {

    @Test("Two to four candidates, and anything else is refused rather than drawn")
    func candidateCount() throws {
        let reference = CompareReference(title: "As it is", kind: "the bench")
        func make(_ count: Int) throws -> CompareModel {
            try CompareModel(title: "t", reference: reference,
                             candidates: (0..<count).map { CompareCandidate(id: "\($0)", title: "\($0)") },
                             features: [])
        }
        #expect(throws: CompareError.notEnoughCandidates(0)) { try make(0) }
        #expect(throws: CompareError.notEnoughCandidates(1)) { try make(1) }
        #expect(throws: CompareError.tooManyCandidates(5)) { try make(5) }
        for count in 2...4 {
            #expect(try make(count).candidates.count == count)
        }
    }

    @Test("At most two levers")
    func leverCount() throws {
        let reference = CompareReference(title: "As it is", kind: "the bench")
        let candidates = [CompareCandidate(id: "a", title: "A"), CompareCandidate(id: "b", title: "B")]
        #expect(throws: CompareError.tooManyLevers(3)) {
            try CompareModel(title: "t", reference: reference, candidates: candidates,
                             features: [], levers: [.tempo, .swing, .ghostLevel])
        }
        let two = try CompareModel(title: "t", reference: reference, candidates: candidates,
                                   features: [], levers: [.tempo, .swing])
        #expect(two.levers.count == 2)
        #expect(CompareModel.maximumLevers == 2)
    }

    @Test("The reference is visible and cannot be selected as a candidate")
    func theReferenceIsNotACandidate() throws {
        let (model, _) = try CompareFixtures.feelComparison()
        #expect(model.reference.title == "Boom-Bap Pocket")
        #expect(!model.candidates.contains { $0.id == model.reference.id })
        // Selecting it by its own id does nothing but record the mistake.
        model.select(CompareModel.referenceID)
        #expect(model.selectedID == nil)
        #expect(model.lastError?.contains("no candidate") == true)
    }
}

// MARK: - The model test the brief asks for

@MainActor
@Suite("Compare surface: candidates differ audibly, and levers run locally", .serialized)
struct CompareModelTests {

    @Test("Every candidate differs from the reference on something a listener would hear")
    func candidatesDifferAudibly() throws {
        let (model, _) = try CompareFixtures.feelComparison()

        // This is the test the surface exists to pass. "Differ" is not "the numbers are not equal":
        // it is "the gap is at least the smallest change anybody detects", and that figure comes
        // from the Beatmaker's own vocabulary — 3 percentage points of swing, 10 ms of placement —
        // rather than from this test.
        for candidate in model.candidates {
            #expect(model.differs(candidate.id),
                    "\(candidate.title) reads the same as the reference on everything measured")
        }
        #expect(model.indistinguishable.isEmpty)

        // And the thresholds really are the bible's.
        #expect(model.vocabulary.noticeable(.swingPercent) == 3)
        #expect(model.vocabulary.noticeable(.snareLagMS) == Beatmaker.perceptionFloorMS)

        // A candidate inside the threshold is marked as the same rather than as a difference — which
        // is the half of "differences are marked" that a naive implementation gets wrong.
        let (pair, _) = try CompareFixtures.pair()
        #expect(pair.differs("a"))          // 58% against 50% — 8 points, well over 3
        #expect(!pair.differs("b"))         // 51% against 50% — one point, under it
        #expect(pair.indistinguishable.map(\.id) == ["b"])
        #expect(pair.difference(.swingPercent, for: "b")?.text == "—")
        #expect(pair.difference(.swingPercent, for: "a")?.text == "+8.00 %")
        #expect(pair.difference(.swingPercent, for: "a")?.direction == .higher)
    }

    @Test("The differences are the real arithmetic over real feels")
    func differencesAreReal() throws {
        let (model, _) = try CompareFixtures.feelComparison()
        let library = FeelLibrary.standard
        let reference = try #require(library.feel(named: "Boom-Bap Pocket"))
        let lofi = try #require(library.feel(named: "Lo-Fi Hip-Hop"))

        let swing = try #require(model.difference(.swingPercent, for: "Lo-Fi Hip-Hop"))
        #expect(abs(swing.reference - reference.swing.percent) < 0.001)
        #expect(abs(swing.candidate - lofi.swing.percent) < 0.001)
        #expect(abs(swing.delta - (lofi.swing.percent - reference.swing.percent)) < 0.001)
        // Lo-fi is swung further than boom-bap, and by enough to hear.
        #expect(swing.direction == .higher)
        #expect(swing.matters)

        // A feature neither side carries is skipped rather than compared against zero.
        #expect(model.difference(.bitDepth, for: "Lo-Fi Hip-Hop") == nil)
    }

    @Test("Selecting a row plays it, in place, with no round trip")
    func selectingPlays() async throws {
        let (model, host) = try CompareFixtures.feelComparison()
        model.select("Neo-Soul Pocket")
        await settle { host.plays.count == 1 }

        #expect(model.selectedID == "Neo-Soul Pocket")
        #expect(model.playingID == "Neo-Soul Pocket")
        #expect(host.lastPlay?.id == "Neo-Soul Pocket")
        // Nothing was committed by selecting.
        #expect(host.chosen.isEmpty)
        #expect(model.chosenID == nil)

        // The reference plays too, and does not become the selection.
        model.auditionReference()
        await settle { host.plays.count == 2 }
        #expect(host.lastPlay?.id == CompareModel.referenceID)
        #expect(model.isPlayingReference)
        #expect(model.selectedID == "Neo-Soul Pocket")
    }

    @Test("Moving a lever re-plays what is sounding, locally, with the new value")
    func leversRunLocally() async throws {
        let (model, host) = try CompareFixtures.feelComparison()

        // A lever on a silent surface starts nothing.
        model.setLever(.tempo, to: 96)
        #expect(model.value(of: .tempo) == 96)
        #expect(host.plays.isEmpty)

        model.select("Trip-Hop")
        await settle { host.plays.count == 1 }
        #expect(host.lastPlay?.levers[.tempo] == 96)

        // Now the lever re-plays the same row at the new value — no agent, no commit, no rebuild.
        model.setLever(.swing, to: 62)
        await settle { host.plays.count == 2 }
        #expect(host.lastPlay?.id == "Trip-Hop")
        #expect(host.lastPlay?.levers[.swing] == 62)
        #expect(host.lastPlay?.levers[.tempo] == 96)
        #expect(host.chosen.isEmpty)

        // And it applies to every row, not to the selected one — otherwise the comparison is unfair.
        model.select("Lo-Fi Hip-Hop")
        await settle { host.plays.count == 3 }
        #expect(host.lastPlay?.levers[.swing] == 62)

        // A lever the surface does not carry is ignored rather than silently added.
        model.setLever(.degradeMix, to: 0.5)
        #expect(model.leverValues[.degradeMix] == nil)

        // Values are clamped to the lever's own range.
        model.setLever(.swing, to: 400)
        #expect(model.value(of: .swing) == Swing.maximumPercent)
        model.setLever(.tempo, to: 1)
        #expect(model.value(of: .tempo) == 60)

        // Resetting puts them back and re-plays.
        let before = host.plays.count
        model.resetLevers()
        await settle { host.plays.count > before }
        #expect(model.value(of: .tempo) == CompareLever.tempo.defaultValue)
    }

    @Test("Choosing a row is the only thing that leaves the surface")
    func choosing() async throws {
        let (model, host) = try CompareFixtures.feelComparison()
        model.select("Neo-Soul Pocket")
        let taken = await model.choose("Neo-Soul Pocket")
        #expect(taken)
        #expect(host.chosen == ["Neo-Soul Pocket"])
        #expect(model.chosenID == "Neo-Soul Pocket")
        #expect(model.lastError == nil)

        // A host that refuses leaves the selection alone and says so.
        host.refuseChoices = true
        let refused = await model.choose("Trip-Hop")
        #expect(!refused)
        #expect(model.chosenID == "Neo-Soul Pocket")
        #expect(model.lastError?.contains("would not take") == true)
    }

    @Test("Critic findings ride on the rows without being acted on")
    func findingsAreCarriedNotApplied() throws {
        let (model, _) = try CompareFixtures.feelComparison()
        let finding = Finding(critic: .swingClash, criticName: "Swing check", persona: .beatmaker,
                              subject: .bar(0), locus: Locus(bar: 0, beat: 0, start: 0, end: 2),
                              headline: "h", why: "w.", severity: .warn,
                              measurement: Measurement(.swingPercent, measured: 40,
                                                       threshold: .atMost(.swingPercent, 10, unit: "ms"),
                                                       unit: "ms"),
                              first: Fix("a", title: "a", detail: "a", change: .setSwing(percent: 54)),
                              second: Fix("b", title: "b", detail: "b", change: .setSwing(percent: 50)))
        model.attach([finding], to: "Lo-Fi Hip-Hop")

        #expect(model.findingCount == 1)
        #expect(model.candidate("Lo-Fi Hip-Hop")?.warnings.count == 1)
        // Flags, never fixes: the candidate's own readings are untouched by the finding.
        let swing = try #require(model.candidate("Lo-Fi Hip-Hop")?.reading(.swingPercent))
        #expect(abs(swing.value - 60) < 0.001)
    }

    @Test("The surface binds to the versions it is comparing")
    func bindsToVersions() throws {
        let reference = PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()),
                                    author: .user, operation: Operation.written)
        let candidate = PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()),
                                    author: .user, operation: Operation.written)
        let model = try CompareModel(
            title: "t",
            reference: CompareReference(title: "As it is", kind: "the bench", version: reference.id),
            candidates: [
                CompareCandidate(id: "a", title: "A", version: candidate),
                CompareCandidate(id: "b", title: "B"),
            ],
            features: [])
        #expect(model.boundVersions == [reference.id, candidate.id])
        #expect(model.surface.bound == model.boundVersions)
        #expect(CompareSurface.kind == .compare)
        #expect(SurfaceKind.compare.isAnswer)
    }
}

// MARK: - Layout

@Suite("Compare surface: it uses the room it is given")
struct CompareLayoutTests {

    private func layout(_ size: CGSize, candidates: Int = 3, features: Int = 3,
                        levers: Int = 2) -> CompareLayout {
        CompareLayout(size: size, candidates: candidates, features: features, levers: levers)
    }

    @Test("The rows grow rather than multiplying: taller at the default window than at the minimum")
    func rowsGrow() {
        let tight = layout(SurfaceGeometry.minimum)
        let standard = layout(SurfaceGeometry.standard)
        #expect(standard.rowHeight > tight.rowHeight)
        #expect(tight.rowHeight >= CompareLayout.minimumRowHeight)
        #expect(standard.rowHeight <= CompareLayout.maximumRowHeight)
        // A row is a thing you press to hear something, so it is never smaller than a control.
        for size in SurfaceGeometry.all {
            #expect(layout(size).rowHeight >= Design.Metric.controlHeight)
        }
    }

    @Test("Two candidates get a taller row than four")
    func fewerRowsAreTaller() {
        let two = layout(SurfaceGeometry.standard, candidates: 2)
        let four = layout(SurfaceGeometry.standard, candidates: 4)
        #expect(two.rowHeight > four.rowHeight)
        // And the tall row has room for the rationale line under the title.
        #expect(two.showsRationale)
    }

    @Test("The columns take the width, with a floor and a ceiling on them")
    func columnsTakeTheWidth() {
        let tight = layout(SurfaceGeometry.minimum)
        let wide = layout(SurfaceGeometry.wide)

        // The name column grows with the panel, because a candidate title and the persona that
        // proposed it are the two things worth more room.
        #expect(wide.titleWidth > tight.titleWidth)

        // With only three columns both geometries hit the ceiling, and that is right: a cell
        // holding "+12.5 ms" does not become more legible at 300 points. Where the width actually
        // buys something is a comparison with enough columns to be squeezed.
        #expect(tight.columnWidth == CompareLayout.maximumColumnWidth)
        #expect(layout(SurfaceGeometry.wide, features: 8).columnWidth
                    > layout(SurfaceGeometry.minimum, features: 8).columnWidth)
        for size in SurfaceGeometry.all {
            let l = layout(size)
            #expect(l.columnWidth >= CompareLayout.minimumColumnWidth)
            #expect(l.columnWidth <= CompareLayout.maximumColumnWidth)
            #expect(l.rowWidth <= l.contentSize.width + 1)
        }
    }

    @Test("Past what fits, it shows fewer columns rather than illegible ones")
    func dropsColumnsRatherThanSqueezing() {
        // Eight features cannot all hold a number at 640 points of width, so the surface shows the
        // ones that fit instead of eight 40-point columns.
        let tight = layout(SurfaceGeometry.minimum, features: 8)
        #expect(tight.visibleFeatureCount < 8)
        #expect(tight.visibleFeatureCount >= 1)
        #expect(tight.columnWidth >= CompareLayout.minimumColumnWidth)
        // With the side regions folded away, more of them fit.
        #expect(layout(SurfaceGeometry.wide, features: 8).visibleFeatureCount
                    > tight.visibleFeatureCount)
    }

    @Test("The levers are capped, not stretched")
    func leversAreCapped() {
        let standard = layout(SurfaceGeometry.standard)
        let wide = layout(SurfaceGeometry.wide)
        #expect(standard.leverStripWidth == wide.leverStripWidth)
        #expect(wide.leverStripWidth < wide.contentSize.width)
        #expect(layout(SurfaceGeometry.standard, levers: 0).leverStripWidth == 0)
    }

    @Test("Nothing overflows at any of the three geometries")
    func nothingOverflows() {
        for size in SurfaceGeometry.all {
            for candidates in 2...4 {
                let l = layout(size, candidates: candidates)
                #expect(l.rowsAreaHeight > 0)
                #expect(l.referenceHeight + l.rowsAreaHeight + CompareLayout.chromeHeight
                            <= l.contentSize.height + 1)
                #expect(l.rowsScroll == (l.rowsHeight > l.rowsAreaHeight + 0.5))
            }
        }
    }

    @Test("The reference band is never a share of the height the rows need")
    func theReferenceBandIsBounded() {
        for size in SurfaceGeometry.all {
            let l = layout(size)
            #expect(l.referenceHeight >= 64 && l.referenceHeight <= 104)
            #expect(l.referenceHeight < l.contentSize.height * 0.25)
        }
    }
}
