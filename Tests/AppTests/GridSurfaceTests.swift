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

    @MainActor func commit(_ version: PartVersion) -> Bool {
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

        // Recorded kits are listed after them, when a library has some; another test may have one in.
        #expect(model.machines.filter { $0.family != .recorded }.map(\.id)
                == ["tr808", "tr909", "linn", "cr78", "tr606", "tr707", "dmx", "simmons",
                    "sp1200", "mpc60", "studio", "jazz", "rock", "funk", "vintage", "trap", "lofi"])
        // Listed by kind, and the kinds in the order the list gives them.
        #expect(model.machines.map(\.family) == model.machines.map(\.family).sorted {
            SynthMachine.Family.allCases.firstIndex(of: $0)! < SynthMachine.Family.allCases.firstIndex(of: $1)!
        })
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

        // The pattern, exactly as the feel states it, and the feel named so the song plays it.
        #expect(model.groove.unfelt == feel.groove)
        #expect(model.groove.feel?.name == "Boom-Bap")
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
        #expect(library.count == 51, "the library ships 51 feels with provenance")
        #expect(library.validate().isEmpty)

        let model = GridModel(host: StubGridHost())
        for feel in library.feels {
            model.load(feel)
            #expect(model.groove.unfelt == feel.groove, "\(feel.name) did not round-trip")
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

    @Test("a feel loads outright over painted steps, and ⌘Z puts back everything it replaced")
    func feelLoadUndoes() {
        let model = GridModel(host: StubGridHost())
        model.autoKeep.delay = nil
        let library = FeelLibrary.standard
        let first = library.feels[0], second = library.feels[1]
        #expect(first.groove != second.groove, "the test needs two different pockets")

        #expect(model.loadFeel(named: first.name))
        #expect(model.groove.unfelt == first.groove)

        // Edited, then another feel: no question in between. It loads.
        let voice = model.voices[0]
        let restStep = (0..<model.stepCount).first { model.tier(voice, step: $0) == .rest } ?? 0
        model.set(.accent, voice: voice, step: restStep)
        let edited = model.groove
        #expect(model.loadFeel(named: second.name))
        #expect(model.groove.unfelt == second.groove)
        #expect(model.feelName == second.name)
        #expect(model.tempo == second.suggestedTempo)

        // One undo is the whole load: the edited pattern, and the first feel's name, tempo and levers.
        model.undo()
        #expect(model.groove == edited)
        #expect(model.feelName == first.name)
        #expect(model.tempo == first.suggestedTempo)
        #expect(model.swing == first.swing)
        #expect(model.velocities == first.velocities)
        #expect(model.voiceFeels == first.voices)
        #expect(model.provenance == first.provenance)

        // The one before that is the edit, and before that the first load over an empty grid.
        model.undo()
        #expect(model.groove.unfelt == first.groove)
        model.undo()
        #expect(!model.isPainted)
        #expect(model.feelName == nil)
        #expect(!model.canUndo)

        // And forward again, all the way to the second feel.
        model.redo(); model.redo(); model.redo()
        #expect(model.groove.unfelt == second.groove)
        #expect(model.feelName == second.name)

        // A name the library does not have changes nothing.
        #expect(model.loadFeel(named: "No Such Feel") == false)
        #expect(model.groove.unfelt == second.groove)
    }

    // MARK: Length

    @Test("lengthening repeats the bars that are there; shortening drops the ones past the end")
    func setBarsRepeatsAndTruncates() {
        let model = GridModel(host: StubGridHost())
        model.autoKeep.delay = nil
        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .snare, step: 4)
        model.set(.ghost, voice: .closedHat, step: 15)
        let oneBar = model.groove

        model.setBars(4)
        #expect(model.bars == 4)
        #expect(model.stepCount == 64)
        #expect(model.groove.bars == 4)
        for pattern in model.groove.patterns {
            let original = oneBar.patterns.first { $0.voice == pattern.voice }?.steps ?? []
            #expect(pattern.steps.count == 64)
            for bar in 0..<4 {
                #expect(Array(pattern.steps[bar * 16 ..< (bar + 1) * 16]) == original,
                        "bar \(bar + 1) of \(pattern.voice) is a copy of the one bar there was")
            }
        }

        // Vary bar 3, then shorten to two: bars 3 and 4 go, the variation with them.
        model.set(.accent, voice: .snare, step: 2 * 16 + 12)
        model.setBars(2)
        #expect(model.stepCount == 32)
        for pattern in model.groove.patterns {
            let original = oneBar.patterns.first { $0.voice == pattern.voice }?.steps ?? []
            #expect(pattern.steps == original + original)
        }

        // Two bars to three repeats cyclically: the third bar is the first again, not the second.
        model.set(.normal, voice: .clap, step: 16 + 8)
        model.setBars(3)
        #expect(model.tier(.clap, step: 16 + 8) == .normal)
        #expect(model.tier(.clap, step: 32 + 8) == .rest)
        #expect(model.tier(.kick, step: 32) == .accent)

        // Doubling copies what is there once more: three bars become six, the second three a copy.
        let three = model.groove
        model.doubleLength()
        #expect(model.bars == 6)
        for pattern in model.groove.patterns {
            let original = three.patterns.first { $0.voice == pattern.voice }?.steps ?? []
            #expect(pattern.steps == original + original)
        }

        // The range is clamped, and doubling stops at its top.
        model.setBars(0)
        #expect(model.bars == 1)
        model.setBars(40)
        #expect(model.bars == GridModel.barRange.upperBound)
        #expect(!model.canDoubleLength)
        model.doubleLength()
        #expect(model.bars == GridModel.barRange.upperBound)
        #expect(GridModel.lengthChoices == [1, 2, 4, 8])
    }

    @Test("a length change is one edit: ⌘Z puts back the bars and every step that was in them")
    func setBarsUndoes() {
        let host = StubGridHost()
        let model = GridModel(host: host)
        model.autoKeep.delay = nil
        model.set(.accent, voice: .kick, step: 0)
        _ = model.commit()
        let oneBar = model.groove

        model.setBars(2)
        #expect(model.hasUnkeptChanges, "a longer groove is a different groove, so it keeps")
        #expect(model.keepLine == .pending)
        model.set(.accent, voice: .snare, step: 16 + 4)
        let varied = model.groove

        // Shortening loses the variation; one undo brings the second bar back with it.
        model.setBars(1)
        #expect(model.groove == oneBar)
        model.undo()
        #expect(model.bars == 2)
        #expect(model.groove == varied)
        #expect(model.tier(.snare, step: 16 + 4) == .accent)

        model.undo()   // the variation
        model.undo()   // the lengthening
        #expect(model.bars == 1)
        #expect(model.groove == oneBar)
        #expect(!model.hasUnkeptChanges, "back where the kept version is")

        model.redo()
        #expect(model.bars == 2)

        // Setting the length it already is changes nothing and is not an edit.
        let undoable = model.canRedo
        model.setBars(2)
        #expect(model.canRedo == undoable, "a no-op does not clear the way forward")
    }

    @Test("the ruler counts beats in one bar and bars past it, and bar lines fall where bars start")
    func rulerAndBarLines() {
        let model = GridModel(host: StubGridHost())
        #expect(model.rulerLabel(step: 0) == "1")
        #expect(model.rulerLabel(step: 4) == "2")
        #expect(model.rulerLabel(step: 12) == "4")
        #expect(model.rulerLabel(step: 1) == "")
        #expect(!model.startsBar(step: 0), "no line before the first bar")

        model.setBars(2)
        #expect(model.rulerLabel(step: 0) == "1")
        #expect(model.rulerLabel(step: 4) == "1.2")
        #expect(model.rulerLabel(step: 16) == "2")
        #expect(model.rulerLabel(step: 28) == "2.4")
        #expect(model.startsBar(step: 16))
        #expect(!model.startsBar(step: 8))
        #expect(!model.startsBar(step: 32), "no line after the last bar")
    }

    // MARK: Voices

    @Test("a voice can be added as an empty row and removed, and ⌘Z undoes either")
    func addAndRemoveVoices() {
        let model = GridModel(host: StubGridHost())
        model.autoKeep.delay = nil
        let usual: [DrumVoice] = [.kick, .snare, .closedHat, .openHat, .clap]
        #expect(model.voices == usual)
        #expect(model.addableVoices.contains(.ride))
        #expect(!model.addableVoices.contains(.kick), "a voice already a row is not offered")

        model.addVoice(.ride)
        #expect(model.voices == usual + [.ride])
        #expect(model.groove.patterns.last?.voice == .ride)
        #expect(model.groove.patterns.last?.steps == Array(repeating: .rest, count: 16))
        #expect(!model.addableVoices.contains(.ride))
        model.set(.normal, voice: .ride, step: 2)

        // Adding it twice is not two rows.
        model.addVoice(.ride)
        #expect(model.voices.filter { $0 == .ride }.count == 1)

        // A row added to a longer grid is as long as the grid.
        model.setBars(2)
        model.addVoice(.lowTom)
        #expect(model.groove.patterns.last?.steps.count == 32)
        model.undo(); model.undo()
        #expect(model.bars == 1)

        model.set(.accent, voice: .snare, step: 4)
        model.removeVoice(.snare)
        #expect(!model.voices.contains(.snare))
        #expect(model.groove.patterns.allSatisfy { $0.voice != .snare })
        #expect(model.addableVoices.contains(.snare))

        // Undo brings the row back in its place, with its hits.
        model.undo()
        #expect(model.voices == usual + [.ride])
        #expect(model.tier(.snare, step: 4) == .accent)

        model.undo()   // the snare hit
        model.undo()   // the ride hit
        model.undo()   // the ride row
        #expect(model.voices == usual)
        model.redo()
        #expect(model.voices == usual + [.ride])

        // The last row cannot go: the grid is always a grid.
        let single = GridModel(host: StubGridHost(), groove: GridModel.emptyGroove(voices: [.kick]))
        #expect(!single.canRemoveVoice)
        single.removeVoice(.kick)
        #expect(single.voices == [.kick])
        #expect(!single.canUndo)
    }

    @Test("the voice menu knows every machine's voices, and says which the machine has no sound for")
    func voiceMenuKnowsTheMachines() {
        let model = GridModel(host: StubGridHost())
        for machine in SynthMachine.all {
            for spec in machine.voices {
                #expect(GridModel.knownVoices.contains(spec.kind.drumVoice),
                        "\(machine.name)'s \(spec.kind) is not offered")
            }
        }
        // perc is written by MIDI import; no machine has a voice of that name, and every one plays
        // it on its shaker.
        #expect(GridModel.knownVoices.contains(.perc))
        #expect(SynthMachine.all.allSatisfy { machine in
            !machine.voices.contains { $0.kind.drumVoice == .perc }
                && SynthVoiceKind.handPercussion.allSatisfy { kind in machine.spec(for: kind) != nil }
        })
        #expect(model.machineSounds(.perc))
        #expect(model.machineSounds(.highConga) && model.machineSounds(.claves))
        #expect(model.machineSounds(.ride))
        #expect(model.machineSounds(DrumVoice("cowbell")))

        #expect(GridModel.name(of: .closedHat) == "closed hat")
        #expect(GridModel.name(of: .lowTom) == "low tom")
        #expect(GridModel.name(of: .kick) == "kick")
    }

    // MARK: The Beatmaker

    @Test("the Beatmaker reads the painted groove under the grid, flags first, and again after every edit")
    func beatmakerReadsTheGrid() {
        let model = GridModel(host: StubGridHost())
        model.autoKeep.delay = nil
        #expect(model.readings.isEmpty, "nothing painted, nothing to read")

        model.set(.accent, voice: .kick, step: 0)
        model.set(.normal, voice: .snare, step: 4)
        model.set(.normal, voice: .snare, step: 12)
        for step in stride(from: 0, to: 16, by: 2) { model.set(.normal, voice: .closedHat, step: step) }
        #expect(!model.readings.isEmpty)

        // Straight is outside the 54–58 % the corpus sits in: a flag, and flags come first.
        #expect(model.flags.contains { $0.rule == "beatmaker.swing-default" })
        #expect(model.readings.first?.holds == false)
        #expect(model.readings == model.flags + model.holds)
        // The standard tier map puts a ghost 7 dB under a normal hit, which holds.
        #expect(model.holds.contains { $0.rule == "beatmaker.ghost-depth" })

        // It is the persona's own reading of what is on screen, levers included.
        let direct = Beatmaker().read(GrooveObservation(label: model.title, groove: model.groove,
                                                        options: model.renderOptions, tempo: model.tempo,
                                                        timeSignature: model.timeSignature))
        #expect(Set(direct) == Set(model.readings))

        // The edit that answers the flag clears it at once.
        model.setSwing(percent: 56)
        #expect(!model.flags.contains { $0.rule == "beatmaker.swing-default" })
        #expect(model.holds.contains { $0.rule == "beatmaker.swing-default" })

        // Undo reads again too.
        model.undo()
        #expect(model.flags.contains { $0.rule == "beatmaker.swing-default" })

        // A feel with a displaced snare is read in milliseconds at the grid's tempo.
        let displaced = FeelLibrary.standard.feels.first {
            abs(GrooveObservation($0).lagMS(.snare)) >= Beatmaker.perceptionFloorMS
        }
        #expect(displaced != nil, "the library has a feel that moves its snare")
        if let lofi = displaced {
            model.load(lofi)
            #expect(model.readings.contains { $0.rule == "beatmaker.snare-direction" },
                    "\(lofi.name) moves its snare, and the Beatmaker says which way")
        }

        model.clearAll()
        #expect(model.readings.isEmpty, "cleared, nothing to read")
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
        model.autoKeep.delay = nil
        model.toggle(.kick, step: 0)
        _ = model.commit()
        // The keep is synchronous now: refused is refused at once.
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

extension Groove {
    /// The steps without the feel they play in: what a feel's own groove is compared against, since
    /// a loaded feel carries its name and a seed of the grid's own.
    fileprivate var unfelt: Groove {
        var copy = self
        copy.feel = nil
        return copy
    }
}
