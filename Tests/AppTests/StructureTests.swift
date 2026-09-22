import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// B10: the form. The Structure model edits a working copy of the sections — add, reorder, length,
// duplicate, stitch — and keeps it as one move; the transport's plan reads the sections in order;
// a kept form survives a save and a reopen.

/// `GuidanceFixture.everyKind()` with a groove that kicks and a bass line with notes in it: the
/// fixture's own groove is the Grid's empty one and its bass line is bare, which is right for the
/// ledger and wrong for a form, whose whole point is what plays.
@MainActor
enum FormFixture {
    struct Built {
        var song: Song
        var groove: VersionID
        var bass: VersionID
        var progression: VersionID
        var dryChop: VersionID
    }

    static func build(tempo: Double = 92) -> Built {
        var built = GuidanceFixture.everyKind()
        built.song.tempo = tempo
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : .rest })
        }
        let groove = Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            line(.kick, "x-----x---------x-----x---------"),
            line(.snare, "----x-------x-------x-------x---"),
            line(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-"),
        ])
        let grooveVersion = PartVersion(partID: PartID(), kind: .groove(groove), author: .user,
                                        operation: Operation.written, note: "Boom-bap pocket")
        try? built.song.append(grooveVersion)
        let bassline = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1),
                                        NoteEvent(pitch: Pitch(midi: 38), start: 2.5, duration: 0.5),
                                        NoteEvent(pitch: Pitch(midi: 43), start: 4, duration: 1)], sound: "finger")
        let bassVersion = PartVersion(partID: PartID(), kind: .bassline(bassline), author: .persona("Bassist"),
                                      parents: [grooveVersion.id], operation: Operation.written, note: "Palladino line")
        try? built.song.append(bassVersion)
        let progression = built.song.versions.first { $0.type == .progression }!.id
        return Built(song: built.song, groove: grooveVersion.id, bass: bassVersion.id,
                     progression: progression, dryChop: built.sample!.id)
    }

    static func app(_ built: Built, in directory: URL) -> AppState {
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        app.open(built.song)
        return app
    }
}

@MainActor
private final class StubStructureHost: StructureHosting {
    var arranged: [[Section]] = []
    var played = 0
    var refuses = false
    func arrange(_ sections: [Section]) async -> Bool {
        guard !refuses else { return false }
        arranged.append(sections)
        return true
    }
    func play() async { played += 1 }
    func stop() async {}
    func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool { false }
}

@Suite("Structure: the sections, edited and kept") @MainActor
struct StructureModelTests {

    private func model(_ host: StubStructureHost = StubStructureHost()) -> (StructureModel, FormFixture.Built) {
        let built = FormFixture.build()
        return (StructureModel(host: host, song: built.song), built)
    }

    @Test("the layers are the newest of each part that plays, and a new section is stitched from them")
    func layersAndDefaultStitch() throws {
        let (model, built) = model()
        let types = Set(model.layers.map(\.type))
        #expect(types.isSubset(of: Set(StructureModel.playableTypes)))
        #expect(model.layers.contains { $0.id == built.groove && $0.plays })
        #expect(model.layers.contains { $0.id == built.bass && $0.plays })
        #expect(model.layers.contains { $0.id == built.progression && $0.plays },
                "the chords are offered, and they play: the transport sounds them")
        #expect(model.layers.contains { $0.id == built.dryChop && !$0.plays }, "the dry chop is offered, and said not to play")
        #expect(model.isEmpty)

        let verse = model.add(.verse)
        #expect(verse.lengthInBars == 16)
        #expect(verse.stitch == [built.groove, built.bass, built.progression],
                "the newest groove, bass line and chords; the dry chop is not stitched")
        #expect(model.sections.count == 1)
        #expect(model.selected == verse.id)
        #expect(model.isDirty)
        #expect(model.silence(of: verse) == nil)
    }

    // What the surface says a section plays, and whether that is true.
    //
    // The bug: the Plays row was a flat line of chips titled with version *sentences* — "Brushes
    // under the C loop: kick on 1, brushed accent on 3, ghost snare sweeping between…" — so you
    // could not tell a groove from a bass line from the chords, nothing said the song had chords
    // this section left out, and a section naming two bass lines lit two chips and played one.

    @Test("the plays rows are grouped by kind, and each kind is named in one word")
    func groupedByKind() throws {
        let (model, built) = model()
        let verse = model.add(.verse)
        let choices = model.choices(for: verse)

        #expect(choices.map(\.type) == [.groove, .bassline, .progression, .melody, .sample],
                "one row per kind the song has, in stitch order")
        #expect(choices.map { StructureModel.name(of: $0.type) } == ["Groove", "Bass", "Chords", "Tune", "Chop"])
        #expect(model.kinds(of: verse) == ["Groove", "Bass", "Chords"],
                "what the block says it plays, in words rather than anonymous dots")
        #expect(try #require(model.layer(built.dryChop)).silentReason == "dry")
        let melody = try #require(model.layers.first { $0.type == .melody })
        #expect(melody.silentReason == "empty", "an empty melody is not 'dry': that is a word about chops")
    }

    @Test("a section names what it leaves out, and one move puts it in")
    func missingKinds() throws {
        let (model, built) = model()
        let verse = model.add(name: "Verse", bars: 16, stitch: [built.groove])

        #expect(model.missing(from: verse) == [.bassline, .progression])
        #expect(model.missingText(from: verse) == "bass and chords")

        model.fill(verse.id)
        let filled = try #require(model.sections.first { $0.id == verse.id })
        #expect(model.missing(from: filled).isEmpty)
        #expect(filled.stitch.contains(built.progression), "the chords are in the form now")
        #expect(model.missingText(from: filled) == nil)
        #expect(model.kinds(of: filled) == ["Groove", "Bass", "Chords"])
    }

    @Test("one of a kind: a second bass line replaces the first rather than joining it")
    func oneOfAKind() throws {
        let (model, built) = model()
        let emptyBass = try #require(model.layers.first { $0.type == .bassline && !$0.plays }).id
        let verse = model.add(name: "Verse", bars: 8, stitch: [built.groove, built.bass])

        model.toggle(emptyBass, in: verse.id)
        let after = try #require(model.sections.first { $0.id == verse.id })
        #expect(after.stitch.filter { model.layer($0)?.type == .bassline } == [emptyBass],
                "the transport plays one bass line, so the section names one")
        #expect(after.stitch.contains(built.groove), "the other kinds are untouched")

        // And taking it out leaves the kind empty rather than restoring what it replaced.
        model.toggle(emptyBass, in: verse.id)
        #expect(try #require(model.sections.first { $0.id == verse.id }).stitch == [built.groove])
    }

    @Test("a form that named two bass lines opens showing the one it was playing, and says it is dirty")
    func legacyStitchIsTidied() throws {
        let host = StubStructureHost()
        var built = FormFixture.build()
        let emptyBass = built.song.versions.first { $0.type == .bassline && $0.id != built.bass }!.id
        // The shape a form could be saved in before the stitch was one of a kind.
        built.song.sections = [Section(name: "Loop", stitch: [built.groove, built.bass, emptyBass],
                                       lengthInBars: 16)]
        let model = StructureModel(host: host, song: built.song)

        let loop = try #require(model.sections.first)
        let basses = loop.stitch.filter { model.layer($0)?.type == .bassline }
        #expect(basses == [built.bass], "the empty line never sounded; the Palladino line did")
        #expect(model.isDirty, "tidying is a change, and Keep writes back what was being heard")
        #expect(model.kinds(of: loop) == ["Groove", "Bass"])
    }

    @Test("order, length, duplicate, remove, stitch")
    func editing() throws {
        let (model, built) = model()
        let intro = model.add(.intro)
        let verse = model.add(.verse)
        let hook = model.add(.hook)
        #expect(model.sections.map(\.name) == ["Intro", "Verse", "Hook"])
        #expect(model.totalBars == 28)

        model.move(hook.id, before: verse.id)
        #expect(model.sections.map(\.name) == ["Intro", "Hook", "Verse"])
        model.move(intro.id, before: nil)
        #expect(model.sections.map(\.name) == ["Hook", "Verse", "Intro"])
        model.moveEarlier(intro.id)
        #expect(model.sections.map(\.name) == ["Hook", "Intro", "Verse"])
        model.moveLater(hook.id)
        #expect(model.sections.map(\.name) == ["Intro", "Hook", "Verse"])

        model.setLength(hook.id, bars: 0)
        #expect(model.sections[1].lengthInBars == 1, "a section is at least a bar")
        model.setLength(hook.id, bars: 8)
        model.rename(hook.id, to: "Chorus")
        #expect(model.sections[1].name == "Chorus")

        let copy = try #require(model.duplicate(hook.id))
        #expect(copy.id != hook.id)
        #expect(model.sections.map(\.name) == ["Intro", "Chorus", "Chorus", "Verse"])
        #expect(model.sections[2].stitch == model.sections[1].stitch)

        model.toggle(built.groove, in: verse.id)
        #expect(!model.sections[3].stitch.contains(built.groove))
        model.toggle(built.groove, in: verse.id)
        #expect(model.sections[3].stitch.contains(built.groove))

        model.remove(copy.id)
        #expect(model.sections.count == 3)
        #expect(model.selected == verse.id, "the selection moves to the neighbour")

        let bare = model.add(name: "Rest", bars: 2, stitch: [])
        #expect(model.silence(of: bare)?.contains("rest") == true)
        #expect(model.lengthText.hasSuffix("bpm"))
    }

    @Test("keep hands the sections to the host once; revert goes back to what was kept")
    func keepAndRevert() async throws {
        let host = StubStructureHost()
        let (model, _) = model(host)
        model.add(.intro)
        model.add(.verse)
        #expect(await model.keep())
        #expect(host.arranged.count == 1)
        #expect(host.arranged[0].map(\.name) == ["Intro", "Verse"])
        #expect(!model.isDirty)

        model.add(.hook)
        #expect(model.isDirty)
        model.revert()
        #expect(model.sections.map(\.name) == ["Intro", "Verse"])
        #expect(!model.isDirty)

        await model.play()
        #expect(host.played == 1, "play keeps first, then plays")

        host.refuses = true
        model.add(.outro)
        #expect(await model.keep() == false)
        #expect(model.lastError != nil)
    }
}

@Suite("Structure: the song, the transport and the package") @MainActor
struct StructureSongTests {

    @Test("AppState.arrange replaces the form, drops ids the song does not hold, and the plan follows")
    func arrangeInApp() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-app")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        let groove = built.groove
        let bass = built.bass

        #expect(app.playback.segments.isEmpty)
        #expect(app.arrange([
            Section(name: "Intro", stitch: [groove], lengthInBars: 4),
            Section(name: "Verse", stitch: [groove, bass, VersionID()], lengthInBars: 8),
            Section(name: "Rest", stitch: [], lengthInBars: 0),
        ]))
        let song = try #require(app.song)
        #expect(song.sections.count == 3)
        #expect(song.sections[1].stitch == [groove, bass], "an id the song does not hold is dropped")
        #expect(song.sections[2].lengthInBars == 1)
        #expect(app.hasUnsavedChanges)
        #expect(app.activeSection == song.sections[0].id)

        let plan = app.playback
        #expect(plan.isArranged)
        #expect(plan.segments.map(\.name) == ["Intro", "Verse", "Rest"])
        #expect(plan.segments.map(\.startBar) == [0, 4, 12])
        #expect(plan.segments[0].groove != nil)
        #expect(plan.segments[0].bassline == nil)
        #expect(plan.segments[1].bassline != nil)
        #expect(!plan.segments[2].isSounding)
        #expect(plan.lengthInBars == 13)
        #expect(plan.summary.hasPrefix("3 sections"))

        // Clearing is arranging nothing.
        #expect(app.arrange([]))
        #expect(app.song?.sections.isEmpty == true)
        #expect(!app.playback.isArranged)
    }

    @Test("a section of nothing but chords plays them: the form sounds the harmony, not just the drums")
    func chordsAlone() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-chords")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        #expect(app.arrange([Section(name: "Verse", stitch: [built.progression], lengthInBars: 8)]))
        let plan = app.playback
        #expect(plan.isArranged)
        #expect(plan.isPlayable, "chords in a section are a sound, not a drawing")
        #expect(plan.silence == nil)
        #expect(plan.segments.first?.progression != nil)
        #expect(plan.segments.first?.isSounding == true)
        #expect(plan.summary.contains("Chords"))
    }

    @Test("sections whose stitches play nothing are silence with a reason, not a plan that starts")
    func silentForm() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-silent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        // A lyric is written, kept and drawn, and is not a sound: the one kind a section can name
        // that the transport still has nothing to do with.
        let lyric = try #require(built.song.versions.first { $0.type == .lyric }).id
        #expect(app.arrange([Section(name: "Verse", stitch: [lyric], lengthInBars: 8)]))
        let plan = app.playback
        #expect(plan.isArranged)
        #expect(!plan.isPlayable)
        #expect(plan.silence?.headline.contains("play nothing yet") == true)
    }

    @Test("Arrival arranged as intro · verse · hook is saved, reopened and still plays end to end")
    func savedAndReopened() async throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-package")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        let groove = built.groove
        let bass = built.bass
        let chop = built.dryChop

        let model = StructureModel(host: StructureAdapter(app: app), song: app.song)
        model.add(.intro)
        model.add(.verse)
        model.add(.hook)
        #expect(model.sections.allSatisfy { $0.stitch.contains(groove) && $0.stitch.contains(bass) })
        // The dry chop is offered but does not play; the transport says which.
        #expect(model.layers.contains { $0.id == chop && !$0.plays })
        #expect(await model.keep())
        #expect(app.song?.sections.map(\.name) == ["Intro", "Verse", "Hook"])
        app.save()
        #expect(!app.hasUnsavedChanges)

        let reopened = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                                status: .empty(directory), transportHost: StubTransportHost())
        reopened.reloadLibrary()
        reopened.openSong(built.song.id)
        let song = try #require(reopened.song)
        #expect(song.sections.map(\.name) == ["Intro", "Verse", "Hook"])
        #expect(song.sections.map(\.lengthInBars) == [4, 16, 8])
        #expect(song.lengthInBars == 28)
        let plan = reopened.playback
        #expect(plan.isArranged)
        #expect(plan.isPlayable)
        #expect(plan.segments.count == 3)
        #expect(plan.segments.allSatisfy { $0.groove != nil && $0.bassline != nil })
        #expect(plan.segments.last?.endBar == 28)
        #expect(plan.formSeconds.map { abs($0 - Double(28 * 4) * 60 / song.tempo) < 1e-9 } == true)
    }
}
