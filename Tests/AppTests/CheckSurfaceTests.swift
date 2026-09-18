import CoreGraphics
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Tests for the Check surface's model and its layout.
//
// The finding under test is a real one: it comes out of `TransientCutCritic` rather than being
// hand-written, so what the card renders is what a critic actually produces — including the two
// fixes, which the critic's own type makes it impossible to have a different number of.

// MARK: - A stub host

@MainActor
final class CheckHostStub: CheckHosting {
    private(set) var problemPlays = 0
    private(set) var fixPlays: [Fix.ID] = []
    private(set) var stops = 0
    private(set) var appliedChanges: [EngineChange] = []

    /// What `apply` returns. Defaults to resolving, which is the common case.
    var outcome: CheckOutcome = .resolved
    /// Fixes this host cannot render a preview of.
    var unpreviewable: Set<Fix.ID> = []

    func auditionProblem(_ finding: Finding) async { problemPlays += 1 }

    func auditionFix(_ fix: Fix, of finding: Finding) async { fixPlays.append(fix.id) }

    func canPreview(_ fix: Fix) -> Bool { !unpreviewable.contains(fix.id) }

    func stopAudition() { stops += 1 }

    func apply(_ fix: Fix, of finding: Finding) async -> CheckOutcome {
        if outcome.wasApplied { appliedChanges.append(fix.change) }
        return outcome
    }
}

@MainActor
private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Fixtures

private enum CheckFixtures {

    /// A real finding: a cut snapped 9 ms past its transient, produced by the shipped critic.
    static func lateCut() -> Finding {
        let rate = ChopLaneFixtures.sampleRate
        let slices = [
            Slice(index: 0, start: 0, end: Int(0.5 * rate), sampleRate: rate,
                  origin: .onset, peak: 0.8, rms: 0.3),
            Slice(index: 1, start: Int(0.5 * rate), end: Int(1.0 * rate), sampleRate: rate,
                  origin: .snapped, peak: 0.7, rms: 0.28, snapOffset: 0.009),
        ]
        let chop = Chop(slices: slices, sampleRate: rate, sourceFrameCount: Int(rate),
                        detectedTempo: 90)
        let findings = TransientCutCritic().review(ChopReview(label: "Bar 9 of Arrival", chop: chop))
        return findings[0]
    }

    /// A finding about a bar rather than a slice, so the locus prints a bar and a beat.
    static func swingClash() -> Finding {
        let observation = GrooveObservation(
            label: "bar",
            groove: Groove(stepsPerBar: 16, bars: 1, swing: Swing.triplet.factor,
                           patterns: [GroovePattern(voice: .snare,
                                                    steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest })]),
            options: GrooveRenderOptions(swing: .triplet),
            tempo: 90)
        return SwingClashCritic().review(
            GrooveReview(label: "bar", observation: observation,
                         sourceSwingPercent: 54, sourceSwingSupport: 12))[0]
    }
}

// MARK: - The model

@MainActor
@Suite("Check surface: one finding, two fixes, and a way to hear it", .serialized)
struct CheckModelTests {

    @Test("A finding renders with who found it, the bar, why, and its two fixes")
    func theCardIsComplete() {
        let finding = CheckFixtures.lateCut()
        let model = CheckModel(finding: finding, host: CheckHostStub())

        // Who found it.
        #expect(model.attribution == "the Sampler's transient check")
        #expect(model.finding.persona == .sampler)
        // The place — which for a slice finding is the slice and its span in seconds.
        #expect(model.finding.subject.named == "slice 1")
        #expect(model.where_.contains("s"))
        #expect(model.finding.locus.duration > 0)
        // Why, in one sentence.
        #expect(model.finding.why.hasSuffix("."))
        #expect(!model.finding.why.contains(". "))
        // And two fixes, each with a title and what it costs.
        #expect(model.fixes.count == 2)
        for fix in model.fixes {
            #expect(!fix.title.isEmpty)
            #expect(fix.detail.count > 30)
        }
        // The title is short enough for a bench chip and specific enough to tell two Checks apart.
        #expect(model.title == "Transient check: slice 1")
        #expect(CheckSurface.kind == .check)
        #expect(model.isOpen)
        #expect(!model.isResolved)
    }

    @Test("A bar finding prints a bar and a beat")
    func aBarFindingPrintsABar() {
        let model = CheckModel(finding: CheckFixtures.swingClash(), host: CheckHostStub())
        #expect(model.attribution == "the Beatmaker's swing check")
        #expect(model.where_.hasPrefix("bar 1"))
        #expect(model.finding.locus.bar == 0)
        #expect(model.finding.subject.named == "bar 1")
    }

    @Test("The problem can be heard, and so can each fix, without applying anything")
    func hearingIt() async {
        let host = CheckHostStub()
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: host)

        model.hearProblem()
        await settle { host.problemPlays == 1 }
        #expect(model.isPlayingProblem)
        #expect(host.appliedChanges.isEmpty)

        let fix = model.fixes[0]
        model.hear(fix)
        await settle { host.fixPlays.count == 1 }
        #expect(host.fixPlays == [fix.id])
        #expect(model.isPlaying(fix.id))
        #expect(!model.isPlayingProblem)
        // Hearing a fix applies nothing. This is the whole "flags, never fixes" rule in one
        // assertion: the only way the engine changes is through `apply`.
        #expect(host.appliedChanges.isEmpty)
        #expect(!model.isResolved)

        model.stop()
        await settle { host.stops == 1 }
        #expect(model.playingID == nil)

        // A host that cannot preview a change says so rather than playing the unfixed audio.
        host.unpreviewable = [model.fixes[1].id]
        #expect(model.canPreview(model.fixes[0]))
        #expect(!model.canPreview(model.fixes[1]))
    }

    @Test("Applying a fix resolves the finding")
    func applyingResolvesIt() async {
        let host = CheckHostStub()
        let finding = CheckFixtures.lateCut()
        let model = CheckModel(finding: finding, host: host)

        let outcome = await model.apply(model.fixes[0])
        #expect(outcome == .resolved)
        #expect(model.isResolved)
        #expect(!model.isOpen)
        #expect(model.resolvedBy == model.fixes[0].id)
        #expect(model.applied.map(\.id) == [model.fixes[0].id])
        #expect(model.lastError == nil)

        // The host got the change as data — the critic never touched anything.
        #expect(host.appliedChanges == [.moveSliceStart(slice: 1, by: -0.009)])

        // The finding itself is unchanged: it is the record of what was measured, and rewriting it
        // would destroy the only evidence there is.
        #expect(model.finding.measurement == finding.measurement)
        #expect(model.finding.headline == finding.headline)

        // And the version note carries the provenance of the correction.
        #expect(model.versionNote.contains("Transient check"))
        #expect(model.versionNote.contains("slice 1"))
        #expect(model.versionNote.contains("fixed by"))
    }

    @Test("Applying the other fix resolves it too, and either one is enough")
    func eitherFixResolvesIt() async {
        let host = CheckHostStub()
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: host)
        let outcome = await model.apply(model.fixes[1])
        #expect(outcome == .resolved)
        #expect(model.resolvedBy == model.fixes[1].id)
        #expect(host.appliedChanges == [.setSnapTolerance(0)])
    }

    @Test("A fix that was applied and did not work says so instead of closing the card")
    func stillFiresIsNotResolved() async {
        let host = CheckHostStub()
        let measurement = Measurement(.attackShaveMS, measured: 6,
                                      threshold: .atMost(.attackShaveMS, 2, unit: "ms"), unit: "ms")
        host.outcome = .stillFires(measurement)
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: host)

        let outcome = await model.apply(model.fixes[0])
        #expect(outcome == .stillFires(measurement))
        #expect(!model.isResolved)
        #expect(model.isOpen, "the card closed on a fix that did not work")
        // It was applied, so it is in the history, but it did not resolve.
        #expect(model.applied.count == 1)
        #expect(model.resolvedBy == nil)
        #expect(model.lastOutcome?.spoken.contains("still fires") == true)
    }

    @Test("A host that refuses changes nothing and says why")
    func refusedIsNotApplied() async {
        let host = CheckHostStub()
        host.outcome = .refused("check: that version is locked")
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: host)

        let outcome = await model.apply(model.fixes[0])
        #expect(!outcome.wasApplied)
        #expect(model.applied.isEmpty)
        #expect(!model.isResolved)
        #expect(model.lastError == "check: that version is locked")
        #expect(host.appliedChanges.isEmpty)
    }

    @Test("A fix that is not this finding's is refused rather than applied")
    func aForeignFixIsRefused() async {
        let host = CheckHostStub()
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: host)
        let foreign = Fix("somewhere-else", title: "x", detail: "x", change: .accept)

        let outcome = await model.apply(foreign)
        #expect(!outcome.wasApplied)
        #expect(host.appliedChanges.isEmpty)
        model.hear(foreign)
        #expect(host.fixPlays.isEmpty)
        #expect(model.lastError?.contains("not one of this finding's fixes") == true)
    }

    @Test("With no host nothing happens, and the card says so")
    func noHost() async {
        let model = CheckModel(finding: CheckFixtures.lateCut())
        let outcome = await model.apply(model.fixes[0])
        #expect(outcome == .refused("check: no host to apply through"))
        #expect(!model.isResolved)
    }

    @Test("Keeping a finding is recorded as keeping it, not as fixing it")
    func dismissingIsNotResolving() {
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: CheckHostStub())
        model.dismiss()
        #expect(model.isDismissed)
        #expect(!model.isResolved)
        #expect(!model.isOpen)
        #expect(model.versionNote.contains("heard and kept"))
        // And nothing about a dismissal is destructive.
        model.reopen()
        #expect(model.isOpen)
    }

    @Test("The finding becomes a mark the Chop lane can draw, and nothing more")
    func itBecomesAMark() {
        let model = CheckModel(finding: CheckFixtures.lateCut(), host: CheckHostStub())
        let mark = model.mark
        #expect(mark.sliceIndex == 1)
        #expect(mark.summary == model.finding.headline)
        #expect(mark.severity == .warn)
        #expect(mark.start <= mark.end)
    }
}

// MARK: - Layout

@Suite("Check surface: it uses the room it is given")
struct CheckLayoutTests {

    @Test("The type grows with the panel, because the content here is prose")
    func typeGrows() {
        let tight = CheckLayout(size: SurfaceGeometry.minimum)
        let standard = CheckLayout(size: SurfaceGeometry.standard)
        #expect(standard.headlineSize > tight.headlineSize)
        #expect(standard.reasonSize > tight.reasonSize)
        #expect(tight.headlineSize == 17)
        #expect(standard.headlineSize == 22)
        // And it stops growing, rather than becoming a poster at 1269 points.
        #expect(CheckLayout(size: SurfaceGeometry.wide).headlineSize == standard.headlineSize)
    }

    @Test("The card is centred in a readable column rather than stretched")
    func theCardIsBounded() {
        let wide = CheckLayout(size: SurfaceGeometry.wide)
        #expect(wide.cardWidth == CheckLayout.maximumCardWidth)
        #expect(wide.cardInset > 0)
        // At the window minimum the card takes what there is and the inset goes to zero.
        let tight = CheckLayout(size: SurfaceGeometry.minimum)
        #expect(tight.cardWidth == tight.contentSize.width)
        #expect(tight.cardInset == 0)
    }

    @Test("The two fixes stack when narrow and sit side by side when there is room")
    func fixesReflow() {
        let tight = CheckLayout(size: SurfaceGeometry.minimum)
        let standard = CheckLayout(size: SurfaceGeometry.standard)
        #expect(!tight.fixesSideBySide)
        #expect(standard.fixesSideBySide)
        #expect(tight.fixWidth == tight.cardWidth)
        #expect(standard.fixWidth < standard.cardWidth)
        // Two options you weigh against each other, so they are the same width.
        #expect(abs(standard.fixWidth * 2 + Design.Metric.gutter - standard.cardWidth) < 0.001)
    }

    @Test("The arithmetic panel appears only where there is room for it")
    func arithmeticIsConditional() {
        let tight = CheckLayout(size: SurfaceGeometry.minimum)
        let standard = CheckLayout(size: SurfaceGeometry.standard)
        #expect(!tight.showsArithmetic)
        #expect(standard.showsArithmetic)
        // And dropping it is what buys the stacked fixes their height at the window minimum.
        #expect(tight.chromeHeight < standard.chromeHeight)
        #expect(tight.fixHeight >= CheckLayout.minimumFixHeight)
    }

    @Test("Nothing overflows at any of the three geometries")
    func nothingOverflows() {
        for size in SurfaceGeometry.all {
            let l = CheckLayout(size: size)
            #expect(l.cardWidth > 0)
            #expect(l.cardWidth <= l.contentSize.width + 0.001)
            #expect(l.fixHeight >= CheckLayout.minimumFixHeight)
            #expect(l.fixHeight <= CheckLayout.maximumFixHeight)
            let rows: CGFloat = l.fixesSideBySide ? 1 : 2
            let used = l.chromeHeight + l.fixHeight * rows
                + (rows - 1) * Design.Metric.gutter + CheckLayout.footerReserve
            #expect(used <= l.contentSize.height + 1,
                    "the card overflows at \(size): \(used) in \(l.contentSize.height)")
            #expect(l.footerHeight >= 0)
        }
    }
}
