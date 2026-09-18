import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

/// The two answer surfaces, registered and filled.
///
/// The registry under test is a *private* one rather than `SurfaceRegistry.shared`: the Gate A
/// wiring tests assert that the shared registry holds exactly the four they register, and a suite
/// that quietly added two to it would make that test pass or fail by scheduling order.
@Suite("Band: the answer surfaces are registered") @MainActor
struct BandRegistryTests {

    @Test("registerAnswerSurfaces registers the two answer kinds and nothing else")
    func registersTheTwoAnswers() {
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerAnswerSurfaces(in: registry)
        #expect(registry.registeredKinds == SurfaceKind.answers)
        #expect(registry.hasBuilder(for: .compare))
        #expect(registry.hasBuilder(for: .check))
        #expect(!registry.hasBuilder(for: .grid))
    }

    @Test("registerSurfaces registers the whole catalog, so nothing falls back to the placeholder")
    func registersEverything() {
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        #expect(registry.registeredKinds == SurfaceKind.allCases)

        let directory = WiringFixture.temporaryDirectory("band-registry")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let grooves = app.versions.filter { if case .groove = $0.kind { return true } else { return false } }
        #expect(grooves.count >= 3)

        // One at a time: the bench holds three, and a retired surface is not the thing under test.
        for kind in SurfaceKind.answers {
            let bound = kind == .compare ? grooves.map(\.id) : [grooves[0].id]
            let item = BandFixture.item(kind, in: app, title: kind.rawValue, bound: bound)
            #expect(!registry.resolve(item, app: app).isPlaceholder,
                    "\(kind.rawValue) fell back to the placeholder")
            app.closeSurface(item.id)
        }
    }

    @Test("openSurface reaches both of them, and canPerform still refuses an empty one")
    func openSurfaceReachesThem() {
        let directory = WiringFixture.temporaryDirectory("band-open")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let groove = try! #require(app.versions.last)

        let compare = app.openSurface(.compare, title: "Three reads", bound: [groove.id])
        #expect(app.bench.items.contains { $0.id == compare && $0.kind == .compare })
        let check = app.openSurface(.check, title: "Transient check", bound: [groove.id])
        #expect(app.bench.items.contains { $0.id == check && $0.kind == .check })

        // The frame's own gate is unchanged: an answer surface with nothing in it is still refused.
        #expect(!app.canPerform(SurfaceAction(surface: .compare, title: "Nothing")))
        #expect(!app.canPerform(SurfaceAction(surface: .check, title: "Nothing")))
        #expect(app.canPerform(SurfaceAction(surface: .compare, title: "Something", bound: [groove.id])))
    }
}

// MARK: - Compare

@Suite("Band: the Compare surface, wired") @MainActor
struct BandCompareWiringTests {

    @Test("a Compare filed with a brief keeps its reference, its rows and its columns")
    func compareFromABrief() throws {
        let directory = WiringFixture.temporaryDirectory("band-compare")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let grooves = app.versions.compactMap { version -> PartVersion? in
            if case .groove = version.kind { return version } else { return nil }
        }
        let reference = try #require(grooves.first)
        let candidates = Array(grooves.dropFirst())

        let item = BandFixture.item(.compare, in: app, title: "Three slower reads",
                                    bound: [reference.id] + candidates.map(\.id))
        app.file(.compare(CompareBrief(
            title: "Three slower reads",
            reference: CompareReference(title: "Bar 9, as it is", kind: "what the song already has",
                                        readings: [CompareReading(.swingPercent, 50, unit: "%")],
                                        version: reference.id),
            candidates: candidates.map { version in
                CompareCandidate(id: version.id.description, title: version.note ?? "",
                                 proposedBy: .beatmaker, rationale: "slower and dustier",
                                 readings: [CompareReading(.swingPercent, 58, unit: "%")],
                                 version: version)
            },
            features: [.swingPercent],
            levers: [.tempo, .degradeMix])), for: item.id)

        guard case .ready(let model) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("the brief did not produce a Compare")
            return
        }
        #expect(model.title == "Three slower reads")
        #expect(model.reference.version == reference.id)
        #expect(model.candidates.count == candidates.count)
        #expect(model.candidates.allSatisfy { $0.proposedBy == .beatmaker })
        #expect(model.levers == [.tempo, .degradeMix])
        // The reference is never one of the rows — the failure this surface exists to refuse.
        #expect(!model.candidates.contains { $0.version?.id == reference.id })
        // And the brief goes when the surface does.
        app.closeSurface(item.id)
        #expect(app.answer(for: item.id) == nil)
    }

    @Test("with no brief a Compare reads its binding, and measures the rows off the graph")
    func compareFromTheBinding() throws {
        let directory = WiringFixture.temporaryDirectory("band-compare-derived")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let grooves = app.versions.compactMap { version -> PartVersion? in
            if case .groove = version.kind { return version } else { return nil }
        }
        let item = BandFixture.item(.compare, in: app, title: "Three feels",
                                    bound: grooves.map(\.id))

        guard case .ready(let model) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("a binding of three grooves did not produce a Compare")
            return
        }
        #expect(model.reference.version == grooves[0].id)
        #expect(model.candidates.count == grooves.count - 1)
        #expect(!model.features.isEmpty)
        // Every row carries a reading for at least one of the columns: the numbers come from
        // `GrooveObservation`, not from the surface.
        #expect(model.candidates.allSatisfy { candidate in
            model.features.contains { candidate.reading($0) != nil }
        })
        // The graph says who made them, so the rows are attributed without anybody writing it down.
        #expect(model.candidates.allSatisfy { $0.proposedBy == .beatmaker })
    }

    @Test("a Compare the Director opened keeps the levers it put on it")
    func derivedCompareKeepsItsLevers() throws {
        let directory = WiringFixture.temporaryDirectory("band-compare-levers")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let grooves = app.versions.compactMap { version -> VersionID? in
            if case .groove = version.kind { return version.id } else { return nil }
        }
        // Exactly what `open_surface` does: one validated action, levers and all.
        let id = try #require(app.perform(SurfaceAction(
            surface: .compare, title: "Two slower reads", bound: grooves,
            levers: [SurfaceLever(quantity: .dust, label: "Dustier", value: 0.45),
                     SurfaceLever(quantity: .tempo, label: "Slower still", value: 82)])))
        let item = try #require(app.bench.items.first { $0.id == id })

        guard case .ready(let model) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("the Compare did not build")
            return
        }
        // The frame stores a `SurfaceLever` and the surface draws a `CompareLever`; without the
        // translation the live run opened a Compare carrying two controls and showed neither.
        #expect(model.levers == [.degradeMix, .tempo])
        #expect(model.value(of: .tempo) == CompareLever.tempo.defaultValue)
    }

    @Test("a row is labelled by its headline, not by its whole ledger note")
    func rowsAreLabelledNotQuoted() throws {
        let note = "Bar 9 on a trip-hop pocket: 80 bpm, nearly straight at 58%, and heavier."
        let version = PartVersion(partID: PartID(), kind: .groove(Groove(patterns: [])),
                                  author: .user, operation: Operation.regroove, note: note)
        #expect(CompareBriefing.headline(of: version) == "Bar 9 on a trip-hop pocket")

        // A note with nothing to cut at keeps all of it rather than being truncated mid-word.
        let plain = PartVersion(partID: PartID(), kind: .groove(Groove(patterns: [])),
                                author: .user, operation: Operation.regroove, note: "Boom-bap")
        #expect(CompareBriefing.headline(of: plain) == "Boom-bap")
    }

    @Test("a Compare with one thing in it is not a comparison, and says so")
    func oneCandidateIsNotAComparison() {
        let directory = WiringFixture.temporaryDirectory("band-compare-thin")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let groove = app.versions.last!
        let item = BandFixture.item(.compare, in: app, title: "One read", bound: [groove.id])

        guard case .unfilled(let title, let reason) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("one bound version drew a comparison")
            return
        }
        #expect(title == "One read")
        #expect(!reason.isEmpty)
    }

    @Test("the levers are applied to the hits rather than to the surface")
    func leversMoveTheHits() throws {
        let feel = try #require(FeelLibrary.standard.feels.first { $0.groove.patterns.contains { $0.steps.contains(.ghost) } })
        let groove = feel.groove

        let plain = CompareAdapter.hits(for: groove, levers: [:], tempo: 90, timeSignature: .fourFour)
        #expect(!plain.isEmpty)

        // Tempo: the same pattern, later in absolute time, because the bar is longer.
        let slower = CompareAdapter.hits(for: groove, levers: [.tempo: 60], tempo: 90,
                                         timeSignature: .fourFour)
        #expect(slower.count == plain.count)
        let lastPlain = try #require(plain.map(\.time).max())
        let lastSlower = try #require(slower.map(\.time).max())
        #expect(lastSlower > lastPlain, "a slower tempo did not stretch the bar")

        // Swing: the offbeats move and the downbeat does not.
        let swung = CompareAdapter.hits(for: groove, levers: [.swing: 66], tempo: 90,
                                        timeSignature: .fourFour)
        #expect(swung.count == plain.count)
        #expect(zip(plain, swung).contains { $0.time != $1.time }, "the swing lever moved nothing")
        #expect(abs((swung.first?.time ?? 1) - (plain.first?.time ?? 0)) < 1e-9,
                "the swing lever moved the downbeat")

        // Ghost level: the quietest hits get quieter and the loudest do not.
        let quiet = CompareAdapter.hits(for: groove, levers: [.ghostLevel: 0.2], tempo: 90,
                                        timeSignature: .fourFour)
        let plainFloor = try #require(plain.map(\.velocity).min())
        let quietFloor = try #require(quiet.map(\.velocity).min())
        #expect(quietFloor < plainFloor, "the ghost lever did not lower the ghosts")
        #expect(quiet.map(\.velocity).max() == plain.map(\.velocity).max())
    }

    @Test("taking a row selects the version the song already holds rather than appending a copy")
    func choosingSelectsRatherThanDuplicates() async throws {
        let directory = WiringFixture.temporaryDirectory("band-compare-choose")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let adapter = CompareAdapter(app: app, service: WiringFixture.silentService(),
                                     surface: SurfaceID())
        let version = try #require(app.versions.last)
        let before = app.versions.count

        let candidate = CompareCandidate(id: version.id.description, title: "The dustier one",
                                         rationale: "12-bit, 26 kHz hold", version: version)
        #expect(await adapter.choose(candidate))
        #expect(app.versions.count == before, "taking a row that is already in the song appended a copy")
        #expect(app.selectedVersion == version.id)
        // Pressing it twice is the same answer and still no copy.
        #expect(await adapter.choose(candidate))
        #expect(app.versions.count == before)
    }

    @Test("a candidate with nothing behind it is not played, and the rail says why")
    func anEmptyCandidateIsNotPlayed() async {
        let directory = WiringFixture.temporaryDirectory("band-compare-empty")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let adapter = CompareAdapter(app: app, service: WiringFixture.silentService(),
                                     surface: SurfaceID())
        await adapter.audition(CompareCandidate(id: "ghost", title: "A label"), levers: [:])
        #expect(app.log.contains { $0.source == .session && $0.text.contains("nothing to play") })
    }

    @Test("the model is kept per surface and let go when the bench lets the surface go")
    func modelsAreStablePerSurface() {
        let directory = WiringFixture.temporaryDirectory("band-compare-lifetime")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let grooves = app.versions.compactMap { version -> VersionID? in
            if case .groove = version.kind { return version.id } else { return nil }
        }
        let item = BandFixture.item(.compare, in: app, title: "Three feels", bound: grooves)

        guard case .ready(let first) = wiring.compareFilling(for: item, app: app),
              case .ready(let second) = wiring.compareFilling(for: item, app: app) else {
            Issue.record("the Compare did not build")
            return
        }
        #expect(first === second, "rebuilding per render would lose the selected row")
        first.select(first.candidates[0].id)
        #expect(second.selectedID == first.candidates[0].id)

        app.closeSurface(item.id)
        let next = BandFixture.item(.grid, in: app, title: "Grid")
        _ = wiring.gridModel(for: next, app: app)
        #expect(!wiring.holds(item.id), "a closed Compare is still being held")
    }
}

// MARK: - Check

@Suite("Band: the Check surface, wired") @MainActor
struct BandCheckWiringTests {

    @Test("a filed finding becomes a card with the critic's own two fixes")
    func checkFromAFinding() throws {
        let directory = WiringFixture.temporaryDirectory("band-check")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let sample = try #require(app.versions.first { if case .sample = $0.kind { return true } else { return false } })
        let finding = BandFixture.lateCut()

        let item = BandFixture.item(.check, in: app, title: "Transient check", bound: [sample.id])
        app.file(.check(finding), for: item.id)

        guard case .finding(let model) = wiring.checkFilling(for: item, app: app) else {
            Issue.record("a filed finding did not produce a card")
            return
        }
        #expect(model.finding.id == finding.id)
        #expect(model.fixes.count == 2, "a finding offers exactly two fixes, by its own type")
        #expect(model.attribution.contains("Sampler"))
        #expect(model.isOpen)
        // The card can only preview what this host can honestly render; the transient critic's two
        // fixes both change where a cut is, which it cannot.
        #expect(model.fixes.allSatisfy { !model.canPreview($0) })
    }

    @Test("a Check the Director opened in words is drawn as words, with no arithmetic behind it")
    func checkFromASentence() {
        let directory = WiringFixture.temporaryDirectory("band-check-stated")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let sample = app.versions.first { if case .sample = $0.kind { return true } else { return false } }!

        let item = BandFixture.item(.check, in: app, title: "The hats are gone", bound: [sample.id])
        app.file(.stated("Only the kick and the snare survived the separation."), for: item.id)

        guard case .stated(let title, let text, let about) = wiring.checkFilling(for: item, app: app) else {
            Issue.record("a stated finding was not drawn as one")
            return
        }
        #expect(title == "The hats are gone")
        #expect(text.contains("separation"))
        #expect(about != nil)
    }

    @Test("a Check with nothing filed says there is nothing to check")
    func checkWithNothing() {
        let directory = WiringFixture.temporaryDirectory("band-check-empty")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let wiring = SurfaceWiring()
        let item = BandFixture.item(.check, in: app, title: "Check", bound: [app.versions[0].id])

        guard case .unfilled = wiring.checkFilling(for: item, app: app) else {
            Issue.record("an unfiled Check drew a card")
            return
        }
    }

    @Test("applying the critic's own fix records a version and re-measures it")
    func applyingMovesTheCutAndSaysWhatItNowIs() async throws {
        let directory = WiringFixture.temporaryDirectory("band-check-apply")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let sample = try #require(app.versions.first { if case .sample = $0.kind { return true } else { return false } })
        let finding = BandFixture.lateCut()
        let adapter = CheckAdapter(app: app, service: WiringFixture.silentService(), subject: sample.id)
        let model = CheckModel(finding: finding, bound: [sample.id], host: adapter)
        let before = app.versions.count

        let move = try #require(model.fixes.first { if case .moveSliceStart = $0.change { return true } else { return false } })
        let outcome = await model.apply(move)
        #expect(outcome == .resolved, "moving the cut back to its transient should clear the check")
        #expect(app.versions.count == before + 1, "the fix did not append a version")
        #expect(model.isResolved)

        // And the version it recorded is a *new* one derived from the part the critic measured.
        let landed = try #require(app.versions.last)
        #expect(landed.parents.contains(sample.id))
        #expect(landed.note?.contains(finding.criticName) == true)
    }

    @Test("a fix that is a render setting is refused, and nothing is recorded")
    func aRenderSettingIsRefused() async throws {
        let directory = WiringFixture.temporaryDirectory("band-check-refuse")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory)
        let sample = try #require(app.versions.first { if case .sample = $0.kind { return true } else { return false } })
        let adapter = CheckAdapter(app: app, service: WiringFixture.silentService(), subject: sample.id)
        let finding = BandFixture.lateCut()
        let before = app.versions.count

        let outcome = await adapter.apply(
            Fix("back-off", title: "Back the chain off to dry", detail: "", change: .setDegradeMix(0)),
            of: finding)
        #expect(!outcome.wasApplied)
        #expect(outcome.spoken.contains("chop lane"))
        #expect(app.versions.count == before, "a refused fix recorded a version")
    }

    @Test("a fix that is applied but does not clear the check says so rather than closing")
    func stillFiresIsTheHonestOutcome() throws {
        // 40 ms past the transient, moved back by only 5: the arithmetic still trips the threshold.
        let finding = BandFixture.lateCut(shave: 0.040)
        let remeasured = try #require(CheckAdapter.remeasured(finding, after: .moveSliceStart(slice: 1, by: -0.005)))
        #expect(remeasured.trips)
        #expect(abs(remeasured.measured - 35) < 0.5)

        // And moving it all the way back clears it.
        let cleared = try #require(CheckAdapter.remeasured(finding, after: .moveSliceStart(slice: 1, by: -0.040)))
        #expect(!cleared.trips)
    }

    @Test("only the changes a part version actually carries become one")
    func onlyGraphChangesBecomeVersions() throws {
        let sample = Sample(media: BandFixture.media,
                            slices: [SliceMarker(position: 1), SliceMarker(position: 2)],
                            detectedTempo: 90)
        let moved = try #require(CheckAdapter.applying(.moveSliceStart(slice: 1, by: -0.5), to: .sample(sample)))
        guard case .sample(let after) = moved else { return }
        #expect(after.slices.map(\.position) == [1, 1.5])

        let dropped = try #require(CheckAdapter.applying(.dropSlice(0), to: .sample(sample)))
        guard case .sample(let fewer) = dropped else { return }
        #expect(fewer.slices.count == 1)

        let groove = Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [])
        let swung = try #require(CheckAdapter.applying(.setSwing(percent: 62), to: .groove(groove)))
        guard case .groove(let after62) = swung else { return }
        #expect(abs(Swing(factor: after62.swing).percent - 62) < 1e-9)

        // A slice gain is not in the graph, so it is not a version.
        #expect(CheckAdapter.applying(.setSliceGain(slice: 0, dB: -3), to: .sample(sample)) == nil)
        // And a swing is not something a sample carries.
        #expect(CheckAdapter.applying(.setSwing(percent: 62), to: .sample(sample)) == nil)
    }
}
