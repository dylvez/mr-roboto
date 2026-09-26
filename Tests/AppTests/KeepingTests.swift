import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// One rule for keeping: an edit keeps itself a moment after it settles, and at once whenever the
// frame is about to read the song. ⌘Z steps a surface back through its own edits; the ledger steps
// a part back through its versions.

@Suite("Keeping: the history a surface steps back through")
struct EditHistoryTests {

    @Test("undo and redo walk the states, an unchanged edit is not remembered, and a new edit drops the redo")
    func history() {
        var history = EditHistory<Int>()
        history.record(1, now: 1)
        #expect(!history.canUndo, "an edit that changed nothing is not an edit")
        history.record(1, now: 2)
        history.record(2, now: 3)
        #expect(history.undo(from: 3) == 2)
        #expect(history.undo(from: 2) == 1)
        #expect(history.undo(from: 1) == nil)
        #expect(history.redo(from: 1) == 2)
        history.record(2, now: 9)
        #expect(!history.canRedo, "a new edit after an undo forgets the way forward")
    }

    @Test("the history is capped")
    func capped() {
        var history = EditHistory<Int>(limit: 3)
        for value in 0..<10 { history.record(value, now: value + 1) }
        var count = 0
        var current = 10
        while let previous = history.undo(from: current) { current = previous; count += 1 }
        #expect(count == 3)
    }
}

@Suite("Keeping: a surface keeps itself") @MainActor
struct AutoKeepTests {

    @Test("a painted step is kept a moment after the last edit, as one version for a burst")
    func gridKeepsAfterABurst() async throws {
        let host = StubGridHost()
        let model = GridModel(host: host)
        model.autoKeep.delay = .milliseconds(40)
        model.toggle(.kick, step: 0)
        model.toggle(.kick, step: 4)
        model.toggle(.snare, step: 4)
        #expect(model.keepLine == .pending)
        for _ in 0..<200 where model.hasUnkeptChanges { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.hasUnkeptChanges)
        #expect(host.log.commits.count == 1, "three steps in a burst are one version")
        if case .kept = model.keepLine {} else { Issue.record("the status line says it is in the song") }
    }

    @Test("⌘Z takes a drag back as one step, and the undone state keeps itself too")
    func gridUndo() {
        let host = StubGridHost()
        let model = GridModel(host: host)
        model.autoKeep.delay = nil
        model.beginPaint(.closedHat, step: 0)
        for step in 1..<8 { model.continuePaint(.closedHat, step: step) }
        model.endPaint()
        model.toggle(.kick, step: 0)
        #expect(model.canUndo)
        model.undo()
        #expect(model.tier(.kick, step: 0) == .rest)
        #expect(model.tier(.closedHat, step: 7) != .rest, "undoing the click leaves the drag")
        model.undo()
        #expect(model.tier(.closedHat, step: 0) == .rest, "the whole drag goes in one step")
        #expect(!model.canUndo)
        model.redo()
        #expect(model.tier(.closedHat, step: 7) != .rest)
    }

    @Test("the frame keeps every surface before it plays, saves or switches song")
    func frameKeepsBeforeReading() async throws {
        let (app, directory, _) = CompletenessFixture.app("keep-before-play")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(CompletenessFixture.song("Draft"))
        // A surface model with an edit a moment old, standing in for the wiring's.
        let chords = ChordsModel(host: AppChordsHost(app: app), key: .cMajor)
        chords.autoKeep.delay = nil
        chords.text = "Dm7 G7 | Cmaj7"
        #expect(chords.hasUnkeptChanges)
        app.keepAllSurfaces = { chords.keepNow() }

        await app.startTransport()

        #expect(!chords.hasUnkeptChanges)
        #expect(app.song?.versions.contains { $0.type == .progression } == true, "the chords were in the song before it played")
        let began = await host.began
        #expect(began.last?.voices.contains { $0.progression != nil } == true, "and the transport played them")
    }

    @Test("the Piano roll's own draft is not kept until it is touched")
    func rollProposal() {
        let (app, directory, _) = CompletenessFixture.app("roll-proposal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = CompletenessFixture.song("Proposal")
        app.open(song)
        let groove = song.versions[0]
        guard case .groove(let g) = groove.kind else { Issue.record("fixture"); return }
        let roll = PianoRollModel(host: AppRollHost(app: app), groove: g, grooveVersion: groove.id, key: .cMajor, tempo: 92)
        roll.autoKeep.delay = nil
        #expect(!roll.notes.isEmpty, "the writer drafted a line")
        #expect(!roll.keepNow() || !roll.hasUnkeptChanges)
        #expect(app.song?.versions.contains { $0.type == .bassline } == false, "opening the roll wrote nothing into the song")
        roll.setDensity(0.9)
        roll.keepNow()
        #expect(app.song?.versions.contains { $0.type == .bassline } == true, "a lever is a touch")
    }
}

@Suite("Keeping: the ledger steps a part back") @MainActor
struct StepBackTests {

    @Test("back one version restores the previous music as a new version, and again goes further back")
    func stepBack() throws {
        let (app, directory, _) = CompletenessFixture.app("step-back")
        defer { try? FileManager.default.removeItem(at: directory) }
        let v1 = TransportFixture.progressionVersion()
        var song = CompletenessFixture.song("History")
        try song.append(v1)
        app.open(song)
        let p2 = Progression(key: .cMajor, bars: [ProgressionBar(Chord(.d, .minorSeventh))])
        let p3 = Progression(key: .cMajor, bars: [ProgressionBar(Chord(.g, .dominantSeventh))])
        let v2 = v1.deriving(.progression(p2), by: .user, operation: Operation.edit)
        #expect(app.record(v2))
        let v3 = v2.deriving(.progression(p3), by: .user, operation: Operation.edit)
        #expect(app.record(v3))

        #expect(app.stepBackTarget(for: v1.partID)?.id == v2.id)
        #expect(app.stepBack(v1.partID))
        let restored = try #require(app.song?.versions.last(where: { $0.partID == v1.partID }))
        #expect(restored.operation == Operation.restored)
        #expect(restored.kind == v2.kind, "the music of v2")
        #expect(restored.parents == [v3.id, v2.id])

        #expect(app.stepBackTarget(for: v1.partID)?.id == v1.id, "pressing it again goes to v1, not back to v3")
        #expect(app.stepBack(v1.partID))
        #expect(app.song?.versions.last(where: { $0.partID == v1.partID })?.kind == v1.kind)
        #expect(app.stepBackTarget(for: v1.partID) == nil, "v1 is as far back as it goes")
        #expect(app.song?.versions.filter { $0.partID == v1.partID }.count == 5, "nothing was removed")
    }

    @Test("a surface showing the part is rebound to the restored version")
    func surfaceFollows() throws {
        let (app, directory, _) = CompletenessFixture.app("step-back-surface")
        defer { try? FileManager.default.removeItem(at: directory) }
        let v1 = TransportFixture.progressionVersion()
        var song = CompletenessFixture.song("Follow")
        try song.append(v1)
        app.open(song)
        let v2 = v1.deriving(.progression(Progression(key: .cMajor, bars: [ProgressionBar(Chord(.e, .minor))])),
                             by: .user, operation: Operation.edit)
        #expect(app.record(v2))
        let surface = app.openSurface(.chords, title: "Chords", bound: [v2.id])
        var discarded: [SurfaceID] = []
        app.discardSurfaceModel = { discarded.append($0) }
        #expect(app.restore(v1.id))
        let newest = try #require(app.song?.versions.last(where: { $0.partID == v1.partID }))
        #expect(app.bound(for: surface) == [newest.id])
        #expect(discarded == [surface])
    }
}

@Suite("Transport: count-in and click") @MainActor
struct CountInPlanTests {

    private let media = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")

    @Test("a count-in plays the bars before the section, clicked, and moves the form after it")
    func countIn() {
        let groove = TransportFixture.grooveVersion()
        let song = TransportFixture.song([groove], sections: [
            Section(name: "Intro", stitch: [Lane(part: groove.partID)], lengthInBars: 4),
            Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8),
        ])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media)).starting(atBar: 4, countIn: 2)
        #expect(plan.startsAtBar == 2, "two bars before the verse")
        #expect(plan.countInBars == 2)
        #expect(plan.segments.map(\.name) == ["Intro", "Verse"], "the intro's last two bars are the count-in's")
        #expect(plan.segments.map(\.startBar) == [0, 2])
    }

    @Test("counting in before bar one moves everything later, loops included")
    func countInFromTheTop() {
        let groove = TransportFixture.grooveVersion()
        let flat = TransportFixture.song([groove], sections: [])
        let plan = SongPlayback.plan(for: flat, mediaURL: TransportFixture.resolver(media)).starting(atBar: 0, countIn: 1)
        #expect(plan.startsAtBar == -1)
        #expect(abs(plan.voicesStartAt - 2) < 0.001, "one bar at 120 in 4/4: the loop waits two seconds")
        #expect(abs(plan.startOffsetSeconds + 2) < 0.001)

        let arranged = TransportFixture.song([groove], sections: [Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8)])
        let form = SongPlayback.plan(for: arranged, mediaURL: TransportFixture.resolver(media)).starting(atBar: 0, countIn: 2)
        #expect(form.segments.map(\.startBar) == [2])
        #expect(form.lengthInBars == 10)
    }

    @Test("the click is the frame's flag, carried into the plan")
    func click() {
        let song = TransportFixture.song([TransportFixture.grooveVersion()])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))
        #expect(!plan.click)
        #expect(plan.clicking(true).click)
    }

    @Test("a take recorded during a count-in plays from where the song begins, its head skipped")
    func takeDuringCountIn() {
        let part = PartID()
        let audio = Audio(media: GuidanceFixture.media("e"), role: .take, sampleRate: 48_000, channelCount: 1,
                          duration: 10, alignmentOffset: -3, take: Take(startBar: 0))
        let song = TransportFixture.song([PartVersion(partID: part, kind: .audio(audio), author: .user,
                                                      operation: Operation.recorded, note: "Take 1")])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))
        #expect(plan.tracks.count == 1)
        #expect(plan.tracks[0].startsAt == 0)
        #expect(abs(plan.tracks[0].skip - 3) < 0.001)
    }
}

@Suite("Transport: the frame counts in") @MainActor
struct CountInFrameTests {

    @Test("starting from a section with a count-in reads the song's bars, and the readout counts down")
    func frameCountIn() async {
        let (app, directory, _) = CompletenessFixture.app("count-in")
        defer { try? FileManager.default.removeItem(at: directory) }
        let groove = TransportFixture.grooveVersion()
        let song = TransportFixture.song([groove], sections: [
            Section(name: "Intro", stitch: [Lane(part: groove.partID)], lengthInBars: 4),
            Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8),
        ])
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(song)
        await app.startTransport(fromSection: song.sections[0].id, countInBars: 2, click: true)
        let began = await host.began
        #expect(began.last?.countInBars == 2)
        #expect(began.last?.click == true)
        #expect(app.playbackStartBar == -2)
        #expect(app.isCountingIn)
        #expect(app.positionText == "In 2")
        await app.stopTransport()
        #expect(app.playbackStartBar == 0)
    }

    @Test("the transport's Click is a toggle carried into what the transport plays, and into no export")
    func toggle() async {
        let (app, directory, _) = CompletenessFixture.app("click")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(CompletenessFixture.song("Click"))
        app.toggleClick()
        #expect(app.isClicking)
        #expect(!app.playback.click, "the song's plan, which exports render, has no click in it")
        await app.startTransport()
        #expect(await host.began.last?.click == true, "the run the transport plays does")
        await app.stopTransport()
    }
}

// Thin hosts over the real frame, for the keeping tests: what the adapters do, minus the audio.

@MainActor
private final class AppChordsHost: ChordsHosting {
    let app: AppState
    init(app: AppState) { self.app = app }
    func audition(pitches: [Int], duration: Double) async {}
    var instrument: String { "rhodes" }
    func setInstrument(_ id: String, for part: PartID?) {}
    func commit(_ version: PartVersion) -> Bool { app.record(version) }
}

@MainActor
private final class AppRollHost: PianoRollHosting {
    let app: AppState
    init(app: AppState) { self.app = app }
    func audition(note: Int, velocity: Int, duration: Double, sound: String) async {}
    func play(_ bassline: Bassline, tempo: Double, timeSignature: TimeSignature) async {}
    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async {}
    func playMelody(_ notes: [NoteEvent], tempo: Double, timeSignature: TimeSignature, instrument: String) async {}
    func setInstrument(_ id: String, for part: PartID?) {}
    func stop() async {}
    func commit(_ version: PartVersion) -> Bool { app.record(version) }
}

@Suite("Transport: a counted-in take plays from its own bar")
struct CountedInTakeTests {

    @Test("the count-in's audio before the section is skipped; the take plays from the section")
    func laterSection() {
        let part = PartID()
        // Recorded for the section at bar 4 (8 s at 120), counted in from bar 2 (4 s): the audio's
        // first frame is at 4 s, the take begins at 8 s.
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "f", count: 64))!, fileExtension: "wav"),
                          role: .take, sampleRate: 48_000, channelCount: 1, duration: 20, alignmentOffset: 4,
                          take: Take(startBar: 4))
        let song = TransportFixture.song([PartVersion(partID: part, kind: .audio(audio), author: .user,
                                                      operation: Operation.recorded, note: "Take 1")])
        let plan = SongPlayback.plan(for: song, mediaURL: { _ in URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff") })
        #expect(plan.tracks.count == 1)
        #expect(abs(plan.tracks[0].startsAt - 7.95) < 0.001, "a breath of pre-roll, not two bars of count-in")
        #expect(abs(plan.tracks[0].skip - 3.95) < 0.001)
    }
}
