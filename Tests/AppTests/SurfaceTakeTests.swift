import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Inputs I8: Record on the Grid, the Piano roll and the Chords sheet. The controller plays the
// surface's own sound, and what is played lands on the surface — hits on their steps, notes where
// they were played, a chord a bar — as one edit, kept as the surface keeps.

private struct NoDevice: Error {}

@Suite("Record on a surface: the controller into the Grid, the Piano roll and the Chords", .serialized) @MainActor
struct SurfaceTakeTests {
    /// 120 bpm: half a second a beat, two seconds a bar.
    private let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000, startHostTime: 1_000_000)
    /// The section the take is played over starts at bar 3 of the song.
    private var sectionStart: Double { clock.seconds(forBar: 2) }

    private func at(beat: Double) -> UInt64 { clock.hostTime(forSeconds: sectionStart + clock.seconds(forBeat: beat))! }
    private func on(_ note: Int, _ velocity: Int, beat: Double) -> MIDIEvent {
        MIDIEvent(kind: .noteOn(note: note, velocity: velocity), channel: 0, hostTime: at(beat: beat), source: "Launchkey")
    }
    private func off(_ note: Int, beat: Double) -> MIDIEvent {
        MIDIEvent(kind: .noteOff(note: note), channel: 0, hostTime: at(beat: beat), source: "Launchkey")
    }

    private func fixture() -> (AppState, MIDIControl, () -> Void) {
        let directory = WiringFixture.temporaryDirectory("surface-take")
        let app = WiringFixture.app(in: directory)
        let suite = "surface-take-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let kits = WiringFixture.temporaryDirectory("surface-take-kits")
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: kits)
        let control = MIDIControl(app: app, service: service, defaults: defaults)
        return (app, control, {
            WiringFixture.remove(directory)
            WiringFixture.remove(kits)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func hits(_ grid: GridModel, _ voice: DrumVoice) -> [Int] {
        (0..<grid.stepCount).filter { grid.tier(voice, step: $0) != .rest }
    }

    // MARK: The Grid

    @Test("Grid: each hit lights its step as it is played, every bar of the section into the loop; one ⌘Z; kept when the take ends")
    func gridTake() async throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let host = StubGridHost()
        let grid = GridModel(host: host, tempo: 120)
        grid.autoKeep.delay = nil
        #expect(grid.takesInTime && grid.controllerVoice == .kit(grid.machine.id))

        control.beginTake(into: grid, clock: clock, sectionStart: sectionStart, bars: 2, punchOut: nil)
        #expect(control.isTaking(into: grid.surfaceID) && grid.isTaking && control.takeName == "the Grid")
        // Bar 1: a kick on the one, a hard snare on two, a hat a third of a step late off step 3.
        control.handle(on(36, 100, beat: 0.02))
        #expect(hits(grid, .kick) == [0], "lit as it is played, not when the take ends")
        control.handle(on(38, 118, beat: 1))
        control.handle(on(42, 40, beat: (3 + 1.0 / 3) / 4))
        // Bar 2 plays into the same one-bar loop: a kick on three lands on step 8.
        control.handle(on(36, 96, beat: 4 + 2))
        // A pad the grid has no row for gets one.
        control.handle(on(56, 90, beat: 4 + 3))
        // A crash on the next section's downbeat is not in the take.
        control.handle(on(49, 120, beat: 8))
        // Kept mid-take is nothing kept: half a take is not a version.
        #expect(grid.keepNow() && host.log.commits.isEmpty)
        #expect(!grid.canUndo, "nothing to step back to while the take comes in")

        control.finishTake(at: 8)
        #expect(!grid.isTaking && !control.isTaking(into: grid.surfaceID) && control.takeName == nil)
        #expect(hits(grid, .kick) == [0, 8])
        #expect(hits(grid, .snare) == [4] && grid.tier(.snare, step: 4) == .accent)
        #expect(hits(grid, .closedHat) == [3] && grid.tier(.closedHat, step: 3) == .ghost)
        #expect(grid.voices.contains(.cowbell) && hits(grid, .cowbell) == [12])
        #expect(!grid.voices.contains(.crash))
        #expect(control.takeNotes == 0, "forgotten with the take")
        // Heard through the grid's own kit, as a step touch is.
        await settle { host.log.auditions.count == 6 }
        let heard = host.log.auditions.map(\.voice.rawValue).sorted()
        #expect(heard == [DrumVoice.kick, .snare, .closedHat, .kick, .cowbell, .crash].map(\.rawValue).sorted())

        #expect(grid.hasUnkeptChanges && grid.keepNow())
        #expect(host.log.commits.count == 1)
        guard case .groove(let kept) = host.log.commits[0].kind else { Issue.record("not a groove"); return }
        #expect(kept.patterns.first { $0.voice == .kick }?.steps.enumerated().filter { $0.element != .rest }.map(\.offset) == [0, 8])

        // One step of ⌘Z takes the whole take back, the row it added with it.
        grid.undo()
        #expect(hits(grid, .kick).isEmpty && hits(grid, .snare).isEmpty && !grid.voices.contains(.cowbell))
    }

    @Test("Grid: an overdub keeps a louder hit already there, and a take with nothing in it changes nothing")
    func gridOverdub() throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let host = StubGridHost()
        let grid = GridModel(host: host, tempo: 120)
        grid.autoKeep.delay = nil
        grid.set(.accent, voice: .snare, step: 4)
        _ = grid.keepNow()
        control.beginTake(into: grid, clock: clock, sectionStart: sectionStart, bars: 1, punchOut: nil)
        control.handle(on(38, 40, beat: 1))
        control.handle(on(36, 90, beat: 0))
        control.finishTake(at: 4)
        #expect(grid.tier(.snare, step: 4) == .accent, "a ghost played over an accent leaves the accent")
        #expect(hits(grid, .kick) == [0])
        #expect(grid.keepNow())

        let versions = host.log.commits.count
        control.beginTake(into: grid, clock: clock, sectionStart: sectionStart, bars: 1, punchOut: nil)
        control.finishTake(at: 4)
        #expect(!grid.isTaking && host.log.commits.count == versions)
    }

    // MARK: The Piano roll

    @Test("Piano roll: a take over the writer's draft replaces it — notes where they were played, held as long as the keys were")
    func rollTakeReplacesTheDraft() async throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let stub = RollStub()
        let roll = PianoRollModel(host: stub, groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 120)
        roll.autoKeep.delay = nil
        let draft = roll.notes
        #expect(!draft.isEmpty && roll.takeReplaces && roll.lengthInBars == 2)
        #expect(roll.controllerVoice == .bass(roll.sound))

        control.beginTake(into: roll, clock: clock, sectionStart: sectionStart, bars: 4, punchOut: nil)
        #expect(roll.notes == draft, "nothing changes until a note lands")
        control.handle(on(38, 96, beat: 0.04))
        #expect(roll.notes.count == 1, "the draft is gone at the first note, and the note is on the roll")
        control.handle(off(38, beat: 0.5))
        // Struck a little early off its beat, and not let go before the take ends.
        control.handle(on(41, 88, beat: 0.98))
        // Into bar 3: the line grows to hold it.
        control.handle(on(45, 80, beat: 8.25))
        control.handle(off(45, beat: 8.75))
        // A note on the next section's downbeat is not in this one.
        control.handle(on(50, 90, beat: 16))
        // Clicks and drags wait for the take.
        roll.addNote(pitch: 60, at: 2)
        #expect(roll.keepNow() && stub.committed.isEmpty)
        control.finishTake(at: 12)

        #expect(!roll.isTaking)
        #expect(roll.notes.map(\.pitch.midi) == [38, 41, 45])
        #expect(abs(roll.notes[0].start - 0.04) < 1e-6 && abs(roll.notes[0].duration - 0.46) < 1e-6, "as played: Tighten is the press that snaps")
        #expect(abs(roll.notes[1].start - 0.98) < 1e-6 && abs(roll.notes[1].duration - 11.02) < 1e-6, "still held: let go where the take ended")
        #expect(roll.notes[0].velocity == 96)
        #expect(roll.lengthInBars == 3)
        #expect(roll.isTouched && roll.isHandEdited && roll.leversAreHeld, "the line is the hands' now; the writer holds off it")
        #expect(roll.keepNow())
        guard case .bassline(let kept) = try #require(stub.committed.last).kind else { Issue.record("not a bass line"); return }
        #expect(kept.notes.map(\.pitch.midi) == [38, 41, 45] && kept.lengthInBars == 3)

        // The next take plays into the line, as an overdub does.
        #expect(!roll.takeReplaces)
        control.beginTake(into: roll, clock: clock, sectionStart: sectionStart, bars: 4, punchOut: nil)
        control.handle(on(43, 90, beat: 2))
        control.handle(off(43, beat: 3))
        control.finishTake(at: 4)
        #expect(roll.notes.map(\.pitch.midi) == [38, 41, 43, 45])
        // One ⌘Z each.
        roll.undo()
        #expect(roll.notes.map(\.pitch.midi) == [38, 41, 45])
        roll.undo()
        #expect(roll.notes == draft && roll.lengthInBars == 2)
    }

    @Test("Piano roll: in melody mode the take is the tune, on the tune's instrument, and the bass line it was carried from is not mixed in")
    func rollTakeAsATune() throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let stub = RollStub()
        let roll = PianoRollModel(host: stub, groove: PianoRollTests.kicking(), key: PianoRollTests.key, tempo: 120)
        roll.autoKeep.delay = nil
        roll.setMode(.melody)
        #expect(roll.controllerVoice == .keys(roll.instrument))
        #expect(roll.takeReplaces, "the bass line's notes carried up are a proposal")
        control.beginTake(into: roll, clock: clock, sectionStart: sectionStart, bars: 2, punchOut: nil)
        roll.setMode(.bass)
        #expect(roll.mode == .melody, "a take cannot change line halfway")
        control.handle(on(74, 100, beat: 0))
        control.handle(off(74, beat: 1))
        control.handle(on(77, 90, beat: 1.5))
        control.handle(off(77, beat: 2))
        control.finishTake(at: 8)
        #expect(roll.notes.map(\.pitch.midi) == [74, 77])
        #expect(roll.keepNow())
        #expect(try #require(stub.committed.last).type == .melody)
    }

    // MARK: The Chords sheet

    @Test("Chords: a chord played is written as the next bar when the hand comes off it; one note says so; ⌘Z takes back one chord")
    func chordsTake() throws {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let stub = ChordsStub()
        let sheet = ChordsModel(host: stub, key: Key(tonic: NoteName(.c)))
        sheet.autoKeep.delay = nil
        #expect(!sheet.takesInTime && sheet.controllerVoice == .keys(sheet.instrument))
        #expect(sheet.isDefault, "the I–IV–V–I suggestion")

        control.beginTake(into: sheet, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
        func chord(_ keys: [Int]) {
            for key in keys { control.handle(MIDIEvent(kind: .noteOn(note: key, velocity: 90), channel: 0, hostTime: 0, source: "Launchkey")) }
            for key in keys { control.handle(MIDIEvent(kind: .noteOff(note: key), channel: 0, hostTime: 0, source: "Launchkey")) }
        }
        chord([48, 64, 67, 69])
        #expect(sheet.text == "C6", "the suggestion was not the song's chords: the first chord played is the first bar")
        chord([52, 55, 60])
        chord([50, 53, 60])
        chord([55, 59, 65])
        #expect(sheet.text == "C6 | C/E | Dm7 | G7")
        #expect(sheet.problem == nil && sheet.progression?.bars.count == 4)
        #expect(sheet.takeLine?.hasSuffix("→ G7") == true, "\(sheet.takeLine ?? "")")
        // One key is not a chord, and a cluster is not one either: nothing is written.
        chord([62])
        #expect(sheet.text == "C6 | C/E | Dm7 | G7" && sheet.takeLine?.hasPrefix("One note") == true)
        chord([60, 61, 62])
        #expect(sheet.text == "C6 | C/E | Dm7 | G7" && sheet.takeLine?.hasSuffix("not a chord I can name.") == true)

        // A chord still held when Record is let go is written.
        for key in [53, 57, 60] { control.handle(MIDIEvent(kind: .noteOn(note: key, velocity: 90), channel: 0, hostTime: 0, source: "Launchkey")) }
        control.finishTake(at: nil)
        #expect(!sheet.isTaking && sheet.text == "C6 | C/E | Dm7 | G7 | F")
        #expect(control.takeNotes == 0)

        sheet.undo()
        #expect(sheet.text == "C6 | C/E | Dm7 | G7", "a chord at a time")
        #expect(sheet.keepNow())
        guard case .progression(let kept) = try #require(stub.committed.last).kind else { Issue.record("not a progression"); return }
        #expect(kept.chords == [Chord(.c, .sixth), Chord(.c, .major).inverted(1), Chord(.d, .minorSeventh), Chord(.g, .dominantSeventh)])
    }

    @Test("Chords: a chord off the key is spelled as the key spells it, and reads back")
    func chordsTakeSpelledInTheKey() {
        let (_, control, cleanup) = fixture()
        defer { cleanup() }
        let sheet = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.e, .flat), mode: .aeolian))
        sheet.autoKeep.delay = nil
        control.beginTake(into: sheet, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
        // B D♯ F♯ A♯: the sixth of E♭ minor, C♭maj7.
        for key in [47, 51, 54, 58] { control.handle(MIDIEvent(kind: .noteOn(note: key, velocity: 90), channel: 0, hostTime: 0, source: "Launchkey")) }
        for key in [47, 51, 54, 58] { control.handle(MIDIEvent(kind: .noteOff(note: key), channel: 0, hostTime: 0, source: "Launchkey")) }
        #expect(sheet.text == Chord(.b, .majorSeventh).symbol(in: sheet.key))
        #expect(sheet.text.hasPrefix("C"), "\(sheet.text)")
        #expect(sheet.problem == nil && sheet.progression?.chords.first == Chord(.b, .majorSeventh))
        control.finishTake(at: nil)
    }

    // MARK: The controller

    @Test("the controller: one surface at a time; Play in waits for it; a song change ends it and keeps it")
    func oneSurfaceAtATime() async throws {
        let (app, control, cleanup) = fixture()
        defer { cleanup() }
        let host = StubGridHost()
        let grid = GridModel(host: host, tempo: 120)
        grid.autoKeep.delay = nil
        let sheet = ChordsModel(host: ChordsStub(), key: Key(tonic: NoteName(.c)))
        control.beginTake(into: grid, clock: clock, sectionStart: sectionStart, bars: 4, punchOut: nil)
        #expect(control.isTakingInTime)
        control.mode = .kit
        await control.playIn()
        #expect(!control.isPlayingIn, "Play in does not take the controller from a surface recording")

        control.handle(on(36, 100, beat: 0))
        control.finishForSongChange(keeping: true)
        #expect(!grid.isTaking && !control.isTakingInTime)
        #expect(host.log.commits.count == 1, "kept with the song it was played into")

        // In time, a take needs the song to run: with no engine it says so and takes nothing.
        await control.record(into: grid)
        #expect(!control.isTaking(into: grid.surfaceID) && !grid.isTaking && control.lastError != nil)
        #expect(!app.transport.isPlaying)

        // Without a song, a lead sheet still takes chords: nothing has to run under it.
        control.beginTake(into: sheet, clock: nil, sectionStart: 0, bars: nil, punchOut: nil)
        #expect(control.isTaking(into: sheet.surfaceID) && !control.isTakingInTime)
        control.finishTake(at: nil)
    }

    @Test("an empty song still has a click to play a first take to; plain Play still says there is nothing")
    func clickTakeOnAnEmptySong() async {
        let player = StubPlaybackHost()
        var song = TransportFixture.song([])
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4)]
        let app = AppState(library: Library(), song: song, transportHost: StubTransportHost())
        app.attach(playback: player)
        await app.startTransport()
        #expect(app.transport.silence != nil)
        #expect(await player.began.isEmpty)
        await app.startTransport(fromSection: song.sections[0].id, countInBars: 1, click: true)
        #expect(app.transport == .playing)
        let plan = await player.began.last
        #expect(plan?.isClickTake == true && plan?.isPlayable == false)
        await app.stopTransport()
    }
}

/// Waits for the surface's fire-and-forget auditions to land.
private func settle(_ predicate: @escaping @Sendable () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
