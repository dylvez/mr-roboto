import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Tests for the Grid surface's *model*. No view, no audio device: what is checked here is that the
// grid and the groove engine agree about what a pattern is.

// MARK: - A stub host

/// What the surface asked the engine to do, recorded.
final class GridHostLog: @unchecked Sendable {
    struct Push: Sendable {
        var groove: Groove
        var options: GrooveRenderOptions
        var tempo: Double
        var timeSignature: TimeSignature
    }

    private let lock = NSLock()
    private var _pushes: [Push] = []
    private var _auditions: [(voice: DrumVoice, velocity: Int)] = []
    private var _machines: [String] = []
    private var _commits: [PartVersion] = []

    var pushes: [Push] { lock.withLock { _pushes } }
    var auditions: [(voice: DrumVoice, velocity: Int)] { lock.withLock { _auditions } }
    var machines: [String] { lock.withLock { _machines } }
    var commits: [PartVersion] { lock.withLock { _commits } }

    func push(_ push: Push) { lock.withLock { _pushes.append(push) } }
    func audition(_ voice: DrumVoice, _ velocity: Int) { lock.withLock { _auditions.append((voice, velocity)) } }
    func machine(_ id: String) { lock.withLock { _machines.append(id) } }
    func commit(_ version: PartVersion) { lock.withLock { _commits.append(version) } }
}

struct StubGridHost: GridHosting {
    let log = GridHostLog()
    /// A host with no song to take the version, so the surface has to say so.
    var refuses = false

    func audition(_ voice: DrumVoice, velocity: Int) async {
        log.audition(voice, velocity)
    }

    func setPattern(_ groove: Groove, options: GrooveRenderOptions,
                    tempo: Double, timeSignature: TimeSignature) async {
        log.push(GridHostLog.Push(groove: groove, options: options, tempo: tempo, timeSignature: timeSignature))
    }

    func loadMachine(_ machine: SynthMachine) async throws {
        log.machine(machine.id)
    }

    func commit(_ version: PartVersion) async -> Bool {
        if refuses { return false }
        log.commit(version)
        return true
    }
}

/// Waits for the surface's fire-and-forget notifications to land.
private func settle(_ predicate: @escaping @Sendable () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Tests

/// Serialized: these tests assert on the order of events in a log fed by the surface's
/// fire-and-forget notifications. Run in parallel with the rest of AppTests, task scheduling
/// interleaves and a different ordering assertion fails each run. The surface being
/// fire-and-forget is correct for a UI; the test's ordering expectation is what needs the
/// serialization.
@MainActor
@Suite("Grid surface", .serialized)
struct GridSurfaceTests {

    // MARK: Round trip

    @Test("a pattern round-trips through SongGraph.Groove unchanged")
    func grooveRoundTrip() {
        let original = Groove(stepsPerBar: 16, bars: 2, swing: 0.32, patterns: [
            GroovePattern(voice: .kick, steps: (0..<32).map { $0 % 8 == 0 ? .accent : .rest }),
            GroovePattern(voice: .snare, steps: (0..<32).map { $0 % 8 == 4 ? .normal : .rest }),
            GroovePattern(voice: .closedHat, steps: (0..<32).map { $0 % 2 == 0 ? .normal : .ghost }),
        ])
        let model = GridModel(host: StubGridHost(), groove: original)

        #expect(model.groove == original)
        #expect(model.voices == [.kick, .snare, .closedHat])
        #expect(model.stepsPerBar == 16)
        #expect(model.bars == 2)
        #expect(model.stepCount == 32)
        #expect(model.stepsPerBeat == 4)

        // An edit makes a different groove, and only in the cell that was edited.
        model.set(.accent, voice: .snare, step: 4)
        #expect(model.tier(.snare, step: 4) == .accent)
        var expected = original
        expected.patterns[1].steps[4] = .accent
        #expect(model.groove == expected)
    }

    @Test("an edit makes a new version rather than mutating the one it came from")
    func editsProduceNewVersions() async {
        let host = StubGridHost()
        let base = PartVersion(partID: PartID(), kind: .groove(GridModel.emptyGroove()),
                               author: .user, operation: Operation.written)
        let model = GridModel(host: host, version: base)

        model.set(.accent, voice: .kick, step: 0)
        let first = model.commit()
        #expect(first.parents == [base.id])
        #expect(first.partID == base.partID, "an edit is a new version of the same part")
        #expect(first.operation == Operation.edit)

        model.set(.normal, voice: .snare, step: 4)
        let second = model.commit()
        #expect(second.parents == [first.id])
        #expect(model.versions.map(\.id) == [first.id, second.id])

        // The version the grid opened against is untouched.
        guard case .groove(let baseGroove) = base.kind else { return }
        #expect(baseGroove.patterns.allSatisfy { $0.steps.allSatisfy { $0 == .rest } })

        // Both commits reach the host, but not in a promised order: `commit()` notifies through an
        // unstructured Task, which is right for a UI and gives Swift no ordering guarantee between
        // two of them. Order is asserted above on `model.versions`, which is synchronous and is
        // where the ledger reads from. Asserting it here instead was flaky, and was testing
        // something the surface never promised.
        await settle { host.log.commits.count == 2 }
        #expect(Set(host.log.commits.map(\.id)) == Set([first.id, second.id]))
    }

    // MARK: The swing lever

    @Test("the swing lever shows the MPC percentage the graph's factor stands for")
    func swingMapsToPercent() {
        let model = GridModel(host: StubGridHost())

        model.setSwing(.straight)
        #expect(model.swingPercent == 50)
        #expect(model.groove.swing == 0)

        model.snapSwingToTriplet()
        #expect(abs(model.swingPercent - Swing.tripletPercent) < 1e-9)
        #expect(abs(model.groove.swing - 2.0 / 3.0) < 1e-9, "triplet is 2/3 of the factor, not 1")

        model.setSwing(percent: 75)
        #expect(model.groove.swing == 1)
        #expect(model.swingPercent == 75)

        // Linn's "loosen it without it sounding like swing".
        model.setSwing(percent: 54)
        #expect(abs(model.groove.swing - 0.16) < 1e-9)

        // The machines stop at 75 %; so does the lever.
        model.setSwing(percent: 90)
        #expect(model.swingPercent == 75)
        model.setSwing(percent: 10)
        #expect(model.swingPercent == 50)

        // The lever marks the steps it moves: the second of every pair.
        #expect(!model.isSwung(step: 0))
        #expect(model.isSwung(step: 1))
        #expect(!model.isSwung(step: 2))
    }

    @Test("moving the swing lever re-sends the pattern without reloading anything")
    func swingChangesFeelWithoutAReload() async {
        let host = StubGridHost()
        let model = GridModel(host: host)
        let before = host.log.pushes.count

        model.snapSwingToTriplet()

        await settle { host.log.pushes.count > before }
        let push = host.log.pushes.last
        #expect(push != nil)
        #expect(abs((push?.groove.swing ?? 0) - 2.0 / 3.0) < 1e-9)
        #expect(abs((push?.options.swing?.percent ?? 0) - Swing.tripletPercent) < 1e-9)
        #expect(host.log.machines.isEmpty, "changing swing must not reload the kit")
    }

    // MARK: Tiers

    @Test("tier painting produces the velocities the tier map says")
    func tiersProduceTheRightVelocities() {
        let model = GridModel(host: StubGridHost())

        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .kick, step: 4)
        model.set(.ghost, voice: .kick, step: 6)

        #expect(model.velocity(.kick, step: 0) == VelocityMap.standard.accent)   // 120
        #expect(model.velocity(.kick, step: 4) == VelocityMap.standard.normal)   // 90
        #expect(model.velocity(.kick, step: 6) == VelocityMap.standard.ghost)    // 40
        #expect(model.velocity(.kick, step: 1) == 0, "a rest has no velocity")

        // The ghost lever moves the ghost tier and nothing else.
        model.setGhostLevel(0.25)
        #expect(model.velocities.ghost == 23)   // 0.25 of 90, rounded
        #expect(model.velocity(.kick, step: 6) == 23)
        #expect(model.velocity(.kick, step: 0) == VelocityMap.standard.accent)
        #expect(model.velocity(.kick, step: 4) == VelocityMap.standard.normal)

        // A per-voice velocity scale is part of the pocket, so it counts too.
        let scaled = GridModel(host: StubGridHost(),
                               groove: GridModel.emptyGroove(),
                               voiceFeels: [.snare: VoiceFeel(velocityScale: 0.5)])
        scaled.set(.accent, voice: .snare, step: 0)
        #expect(scaled.velocity(.snare, step: 0) == 60)

        // Repeated clicks walk the tiers.
        let walked = GridModel(host: StubGridHost())
        #expect(walked.tier(.kick, step: 2) == .rest)
        walked.cycle(.kick, step: 2); #expect(walked.tier(.kick, step: 2) == .normal)
        walked.cycle(.kick, step: 2); #expect(walked.tier(.kick, step: 2) == .accent)
        walked.cycle(.kick, step: 2); #expect(walked.tier(.kick, step: 2) == .ghost)
        walked.cycle(.kick, step: 2); #expect(walked.tier(.kick, step: 2) == .rest)
    }

    @Test("a drag paints a run of steps, and a drag that starts on a hit erases one")
    func draggingPaintsAndErases() {
        let model = GridModel(host: StubGridHost())
        model.brush = .ghost

        model.beginPaint(.closedHat, step: 0)
        for step in 1...5 { model.continuePaint(.closedHat, step: step) }
        model.endPaint()
        #expect((0...5).allSatisfy { model.tier(.closedHat, step: $0) == .ghost })
        #expect(model.tier(.closedHat, step: 6) == .rest)

        // Starting on a hit erases for the rest of the gesture.
        model.beginPaint(.closedHat, step: 2)
        for step in 3...4 { model.continuePaint(.closedHat, step: step) }
        model.endPaint()
        #expect((2...4).allSatisfy { model.tier(.closedHat, step: $0) == .rest })
        #expect(model.tier(.closedHat, step: 5) == .ghost)
    }

    @Test("painting a step auditions it and reaches the engine for the next pass")
    func paintingIsAudibleOnTheNextPass() async {
        let host = StubGridHost()
        let model = GridModel(host: host)

        model.set(.accent, voice: .snare, step: 4)

        await settle { !host.log.auditions.isEmpty && !host.log.pushes.isEmpty }
        #expect(host.log.auditions.last?.voice == .snare)
        #expect(host.log.auditions.last?.velocity == VelocityMap.standard.accent)
        let pushed = try? #require(host.log.pushes.last)
        #expect(pushed?.groove.patterns.first { $0.voice == .snare }?.steps[4] == .accent)

        // Erasing still plays nothing, because there is nothing to play.
        let auditionsBefore = host.log.auditions.count
        model.set(.rest, voice: .snare, step: 4)
        await settle { host.log.pushes.count > 1 }
        #expect(host.log.auditions.count == auditionsBefore)
    }

    // MARK: Machines

    @Test("the kit picker offers the machines Instrument can synthesize and switching one is audible")
    func machinePicker() async {
        let host = StubGridHost()
        let model = GridModel(host: host)

        #expect(model.machines.map(\.id) == ["tr808", "tr909", "linn"])
        #expect(model.machine.id == "tr808")

        model.setMachine(.tr909)
        #expect(model.machine.id == "tr909")
        await settle { !host.log.machines.isEmpty && !host.log.auditions.isEmpty }
        #expect(host.log.machines == ["tr909"])
        #expect(host.log.auditions.last?.voice == .kick)
        #expect(model.lastError == nil)
    }

    // MARK: Feels

    @Test("choosing a feel loads its pattern and keeps its provenance")
    func feelLoadsWithProvenance() {
        let model = GridModel(host: StubGridHost())
        let feel = try? #require(FeelLibrary.standard.feel(named: "Boom-Bap"))
        guard let feel else { return }

        model.load(feel)

        // The pattern, exactly as the feel states it.
        #expect(model.groove == feel.groove)
        #expect(model.voices == feel.groove.patterns.map(\.voice))
        #expect(model.stepsPerBar == feel.groove.stepsPerBar)
        #expect(model.bars == feel.groove.bars)

        // And everything that makes it a feel rather than a pattern.
        #expect(model.swing == feel.swing)
        #expect(model.velocities == feel.velocities)
        #expect(model.humanize == feel.humanize)
        #expect(model.voiceFeels == feel.voices)
        #expect(model.tempo == feel.suggestedTempo)
        #expect(model.timeSignature == feel.timeSignature)
        #expect(model.feelName == "Boom-Bap")

        // The provenance a persona will cite.
        #expect(model.provenance == feel.provenance)
        #expect(model.provenance?.origin == .grooveTheory)
        let line = try? #require(model.provenanceLine)
        #expect(line?.contains(feel.provenance.summary) == true)

        // …and it survives into the graph, not only onto the screen.
        let version = model.commit()
        let note = version.note ?? ""
        #expect(note.contains("Boom-Bap"))
        #expect(note.contains(feel.provenance.summary))
        #expect(note.contains("groove-theory"))
    }

    @Test("every shipped feel loads into the grid and comes back out identical")
    func everyFeelRoundTrips() {
        let library = FeelLibrary.standard
        #expect(library.count == 33, "the library ships 33 feels with provenance")
        #expect(library.validate().isEmpty)

        let model = GridModel(host: StubGridHost())
        for feel in library.feels {
            model.load(feel)
            #expect(model.groove == feel.groove, "\(feel.name) did not round-trip")
            #expect(model.provenance == feel.provenance, "\(feel.name) lost its provenance")
            #expect(!feel.provenance.summary.isEmpty)
        }
    }

    @Test("the feel picker suggests feels that suit the grid's tempo and meter")
    func feelSuggestion() {
        let model = GridModel(host: StubGridHost())
        model.setTempo(92)
        let suggestions = model.suggestedFeels(limit: 5)
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.timeSignature == .fourFour })
    }

    @Test("a feel asks first when steps are painted, and — puts back what was there")
    func feelLoadAsksAndRestores() {
        let model = GridModel(host: StubGridHost())
        let library = FeelLibrary.standard
        let first = library.feels[0], second = library.feels[1]
        #expect(!model.canRestore)

        // Nothing painted: the feel loads outright, and there is a before — even if it was silence.
        model.chooseFeel(named: first.name)
        #expect(model.groove == first.groove)
        #expect(model.pendingFeel == nil)
        #expect(model.canRestore)

        // A feel nobody has edited gives way to the next without a question.
        model.chooseFeel(named: second.name)
        #expect(model.groove == second.groove)
        #expect(model.pendingFeel == nil)

        // Edited: the next feel waits for the word, and nothing changes until it comes.
        let voice = model.voices[0]
        let restStep = (0..<model.stepCount).first { model.tier(voice, step: $0) == .rest } ?? 0
        model.set(.accent, voice: voice, step: restStep)
        let edited = model.groove
        #expect(model.feelLoadNeedsConfirmation)
        model.chooseFeel(named: first.name)
        #expect(model.pendingFeel?.name == first.name)
        #expect(model.groove == edited)
        #expect(model.feelName == second.name)
        model.cancelPendingFeel()
        #expect(model.pendingFeel == nil)
        #expect(model.groove == edited)

        model.chooseFeel(named: first.name)
        model.confirmPendingFeel()
        #expect(model.pendingFeel == nil)
        #expect(model.groove == first.groove)
        #expect(model.feelName == first.name)

        // — puts back what was there before that load: the edited pattern, its feel's name, its tempo.
        model.chooseFeel(named: "")
        #expect(model.groove == edited)
        #expect(model.feelName == second.name)
        #expect(model.tempo == second.suggestedTempo)
        #expect(!model.canRestore, "one deep: what was restored is now on screen")
        #expect(model.loadFeel(named: "") == false, "nothing further back to put back")
    }

    @Test("a tap paints what the brush says, and a second tap takes it back")
    func tapHonoursBrush() {
        let model = GridModel(host: StubGridHost())
        model.brush = .accent
        model.toggle(.kick, step: 0)
        #expect(model.tier(.kick, step: 0) == .accent, "a tap paints the brush tier, not always normal")
        model.toggle(.kick, step: 0)
        #expect(model.tier(.kick, step: 0) == .rest, "the same tap on the same tier is a rest")

        model.set(.normal, voice: .kick, step: 4)
        model.brush = .ghost
        model.toggle(.kick, step: 4)
        #expect(model.tier(.kick, step: 4) == .ghost, "a tap on another tier repaints it with the brush rather than erasing")

        model.brush = .rest
        model.toggle(.kick, step: 8)
        #expect(model.tier(.kick, step: 8) == .normal, "a rest brush cannot paint nothing")
    }

    // MARK: Keeping

    @Test("the keep control follows the groove: nothing to keep until a step is painted, nothing again once it is kept")
    func unkeptChanges() {
        let host = StubGridHost()
        let model = GridModel(host: host)
        #expect(!model.hasUnkeptChanges, "a silent fresh grid has nothing to keep")
        model.setSwing(percent: 60)
        #expect(!model.hasUnkeptChanges, "swing on a silent grid is still nothing to keep")

        model.toggle(.kick, step: 0)
        #expect(model.hasUnkeptChanges)
        let first = model.commit()
        #expect(!model.hasUnkeptChanges, "just kept: the version is what is on screen")
        #expect(model.lastKept?.id == first.id)

        model.setSwing(percent: 66)
        #expect(model.hasUnkeptChanges, "swing is part of the groove, so it counts")
        model.setSwing(percent: 60)
        #expect(!model.hasUnkeptChanges, "back where the kept version is")
        model.setTempo(120)
        model.setGhostLevel(0.3)
        #expect(!model.hasUnkeptChanges, "tempo and the tier map are how it is heard here, not what is kept")

        model.clearAll()
        #expect(model.hasUnkeptChanges, "silence differs from the kept version")

        // Opened on a version: nothing to keep until an edit.
        let editor = GridModel(host: host, version: first)
        #expect(!editor.hasUnkeptChanges)
        editor.toggle(.snare, step: 4)
        #expect(editor.hasUnkeptChanges)
    }

    @Test("a host that refuses the version says so, and the version does not stay in the list")
    func refusedKeep() async {
        var host = StubGridHost()
        host.refuses = true
        let model = GridModel(host: host)
        model.toggle(.kick, step: 0)
        let version = model.commit()
        #expect(model.versions.map(\.id) == [version.id])

        for _ in 0..<1_000 where model.lastError == nil { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(model.lastError != nil)
        #expect(model.versions.isEmpty, "a refused version is not a version")
        #expect(model.lastKept == nil)
        #expect(model.hasUnkeptChanges, "and the keep control comes back")
        #expect(host.log.commits.isEmpty)
    }

    // MARK: Rendering

    @Test("what the grid hands the engine renders the hits the grid shows")
    func theGrooveEngineAgreesWithTheGrid() {
        let model = GridModel(host: StubGridHost())
        model.setSwing(.triplet)
        model.set(.accent, voice: .kick, step: 0)
        model.set(.ghost, voice: .kick, step: 1)

        let hits = GrooveRenderer.render(model.groove,
                                         on: .tempo(model.tempo, timeSignature: model.timeSignature),
                                         options: model.renderOptions)
        #expect(hits.count == 2)
        #expect(hits[0].velocity == model.velocity(.kick, step: 0))
        #expect(hits[1].velocity == model.velocity(.kick, step: 1))

        // The swung step is late by factor · stepDuration / 2, which is what the lever promises.
        let stepDuration = 60 / model.tempo / Double(model.stepsPerBeat)
        let expectedOffset = model.swing.factor * stepDuration * 0.5
        #expect(abs((hits[1].time - stepDuration) - expectedOffset) < 1e-9)
    }
}
