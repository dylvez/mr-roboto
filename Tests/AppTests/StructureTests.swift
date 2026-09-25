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
    /// The fixture speaks in **parts**, because a stitch does. It used to hold version ids, which
    /// is what a section named before a lane followed its part.
    struct Built {
        var song: Song
        var groove: PartID
        var bass: PartID
        var progression: PartID
        var dryChop: PartID
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
        let progression = built.song.versions.first { $0.type == .progression }!.partID
        return Built(song: built.song, groove: grooveVersion.partID, bass: bassVersion.partID,
                     progression: progression, dryChop: built.sample!.partID)
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
    func arrange(_ sections: [Section]) -> Bool {
        guard !refuses else { return false }
        arranged.append(sections)
        return true
    }
    func play() async { played += 1 }
    func stop() async {}
    func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool { false }
    var lyricsOpened = 0
    func openLyrics() { lyricsOpened += 1 }
}

@Suite("Structure: each section says what it sings") @MainActor
struct StructureWordsTests {
    @Test("a section shows its labelled stanza, one with none says so and opens Lyrics, and a song with no words shows nothing")
    func words() throws {
        var song = Song.new(title: "Glass", tempo: 88)
        let host = StubStructureHost()
        #expect(StructureModel(host: host, song: song).words(for: song.sections[0].id) == nil, "no words, no row")
        try song.append(PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nI put the coffee on at six\nI watched it make itself\nit made itself\n\n[Hook]\nsoft machine")),
                                    author: .user, operation: Operation.written, note: "Lyric"))
        let model = StructureModel(host: host, song: song)
        let intro = song.sections[0], verse = song.sections[1], hook = song.sections[2]
        #expect(model.words(for: intro.id) == .unlabelled(name: intro.name))
        #expect(model.words(for: verse.id) == .sings(label: "Verse", lines: ["I put the coffee on at six", "I watched it make itself", "it made itself"]))
        #expect(model.words(for: hook.id) == .sings(label: "Hook", lines: ["soft machine"]))
        model.openLyrics()
        #expect(host.lyricsOpened == 1)
    }
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
        #expect(model.layers.contains { $0.id == built.dryChop && $0.plays }, "a chop plays as cut, dry or dusty")
        #expect(model.isEmpty)

        let verse = model.add(.verse)
        #expect(verse.lengthInBars == 16)
        #expect(verse.stitch == [built.groove, built.bass, built.progression, built.dryChop].lanes,
                "the newest groove, bass line, chords and chop")
        #expect(verse.stitch.allSatisfy { $0.pin == nil }, "a new section follows its parts")
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
        #expect(model.kinds(of: verse) == ["Groove", "Bass", "Chords", "Chop"],
                "what the block says it plays, in words rather than anonymous dots")
        #expect(try #require(model.layer(built.dryChop)).silentReason == nil, "a dry chop plays")
        let melody = try #require(model.layers.first { $0.type == .melody })
        #expect(melody.silentReason == "empty")
    }

    @Test("a section names what it leaves out, and one move puts it in")
    func missingKinds() throws {
        let (model, built) = model()
        let verse = model.add(name: "Verse", bars: 16, stitch: [built.groove].lanes)

        #expect(model.missing(from: verse) == [.bassline, .progression, .sample])
        #expect(model.missingText(from: verse) == "bass, chords and chop")

        model.fill(verse.id)
        let filled = try #require(model.sections.first { $0.id == verse.id })
        #expect(model.missing(from: filled).isEmpty)
        #expect(filled.stitch.contains(part: built.progression), "the chords are in the form now")
        #expect(model.missingText(from: filled) == nil)
        #expect(model.kinds(of: filled) == ["Groove", "Bass", "Chords", "Chop"])
    }

    @Test("two bass parts in one section both stay: a form plays everything it names")
    func twoOfAKind() throws {
        let (model, built) = model()
        let otherBass = try #require(model.layers.first { $0.type == .bassline && $0.id != built.bass }).id
        let verse = model.add(name: "Verse", bars: 8, stitch: [built.groove, built.bass].lanes)

        // This used to replace: a `Segment` held one bass line and sounded the last a stitch named,
        // so lighting two chips would have been a lie. A section sounds every lane it holds now.
        model.toggle(otherBass, in: verse.id)
        let after = try #require(model.sections.first { $0.id == verse.id })
        #expect(after.stitch.map(\.part) == [built.groove, built.bass, otherBass])

        // And a part is in a section once or not at all — toggling takes it out again.
        model.toggle(otherBass, in: verse.id)
        #expect(try #require(model.sections.first { $0.id == verse.id }).stitch
                == [built.groove, built.bass].lanes)
    }

    @Test("a part is named once: a stitch that repeats one is tidied when the surface opens")
    func aPartIsNamedOnce() throws {
        let host = StubStructureHost()
        var built = FormFixture.build()
        // A form cannot play the same part twice — it is one lane, one strip, one sampler.
        built.song.sections = [Section(name: "Loop",
                                       stitch: [built.groove, built.bass, built.bass].lanes,
                                       lengthInBars: 16)]
        let model = StructureModel(host: host, song: built.song)

        let loop = try #require(model.sections.first)
        #expect(loop.stitch == [built.groove, built.bass].lanes)
        #expect(model.isDirty, "tidying is a change, and Keep writes it back")
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
        #expect(!model.sections[3].stitch.contains(part: built.groove))
        model.toggle(built.groove, in: verse.id)
        #expect(model.sections[3].stitch.contains(part: built.groove))

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
            Section(name: "Intro", stitch: [groove].lanes, lengthInBars: 4),
            Section(name: "Verse", stitch: [groove, bass, PartID()].lanes, lengthInBars: 8),
            Section(name: "Rest", stitch: [], lengthInBars: 0),
        ]))
        let song = try #require(app.song)
        #expect(song.sections.count == 3)
        #expect(song.sections[1].stitch == [groove, bass].lanes, "a part the song does not hold is dropped")
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

    @Test("a part you make is in the song: writing chords into an arranged song is heard in it")
    func aNewPartJoinsTheForm() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-joins")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        #expect(app.arrange([Section(name: "Verse", stitch: [built.groove].lanes, lengthInBars: 8),
                             Section(name: "Hook", stitch: [built.groove].lanes, lengthInBars: 8)]))
        #expect(app.playback.summary.contains("Chords") == false)

        // Write chords. This is the case that made three days of "I can only hear the drums": the
        // part was made, kept, drawn and auditionable, and belonged to no section, so the song did
        // not play it and nothing said why.
        let chords = PartVersion(partID: PartID(),
                                 kind: .progression(Progression(key: Key(tonic: NoteName(.c)),
                                                                bars: [ProgressionBar(Chord(.c, .majorSeventh))])),
                                 author: .user, operation: Operation.written)
        #expect(app.record(chords))

        #expect(app.song?.sections.allSatisfy { $0.stitch.contains(part: chords.partID) } == true)
        #expect(app.playback.summary.contains("Chords"))
        #expect(app.playback.segments.allSatisfy { $0.progression != nil })

        // A new *version* of a part already in the form changes nothing about the form: a lane
        // follows its part, so there is nothing to add.
        let before = app.song?.sections.map(\.stitch)
        #expect(app.record(chords.deriving(chords.kind, by: .user, operation: Operation.edit)))
        #expect(app.song?.sections.map(\.stitch) == before)

        // And a kind the transport cannot sound is not forced into the form.
        let lyric = PartVersion(partID: PartID(), kind: .lyric(Lyric(lines: [])), author: .user,
                                operation: Operation.written)
        #expect(app.record(lyric))
        #expect(app.song?.sections.allSatisfy { !$0.stitch.contains(part: lyric.partID) } == true)
    }

    @Test("the form says what no section plays, and adds it everywhere in one move")
    func theFormNamesWhatSitsOut() throws {
        let host = StubStructureHost()
        var built = FormFixture.build()
        // A form arranged before the chords were written: exactly the shape a song reaches by
        // arranging early, which is what the app tells you to do.
        built.song.sections = [Section(name: "Verse", stitch: [built.groove].lanes, lengthInBars: 8),
                               Section(name: "Hook", stitch: [built.groove].lanes, lengthInBars: 8)]
        let model = StructureModel(host: host, song: built.song)

        #expect(model.orphanedText == "bass, chords and chop")
        model.fillAll()
        #expect(model.orphanedText == nil)
        #expect(model.sections.allSatisfy { $0.stitch.contains(part: built.progression) })
        #expect(model.sections.allSatisfy { $0.stitch.contains(part: built.bass) })
    }

    @Test("the form follows an edit: keep a new version of what a section plays and it plays that")
    func theFormFollowsAnEdit() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-follows")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        #expect(app.arrange([Section(name: "Verse", stitch: [built.groove].lanes, lengthInBars: 8)]))

        let before = try #require(app.playback.segments.first?.grooveVersion)
        let original = try #require(app.song?.latestVersion(of: built.groove))
        #expect(before == original.id)

        // One more hat, kept. This is what every surface does — `deriving` keeps the part and mints
        // a new version id — and it is what used to leave the form playing the version from before
        // the edit, silently, with nothing anywhere saying so.
        guard case .groove(var groove) = original.kind else { Issue.record("not a groove"); return }
        groove.patterns[2].steps[1] = .normal
        let edited = original.deriving(.groove(groove), by: .user, operation: Operation.edit, note: "One more hat")
        #expect(app.record(edited))

        #expect(app.song?.sections.first?.stitch == [built.groove].lanes, "the form was not touched")
        #expect(app.playback.segments.first?.grooveVersion == edited.id,
                "the section still plays the version from before the edit")
    }

    @Test("a pinned lane holds its version while the part moves on")
    func aPinnedLaneHolds() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-pin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        let original = try #require(app.song?.latestVersion(of: built.groove))
        #expect(app.arrange([Section(name: "Verse",
                                     stitch: [Lane(part: built.groove, pin: original.id)],
                                     lengthInBars: 8)]))

        guard case .groove(var groove) = original.kind else { Issue.record("not a groove"); return }
        groove.patterns[2].steps[1] = .normal
        #expect(app.record(original.deriving(.groove(groove), by: .user, operation: Operation.edit)))

        #expect(app.playback.segments.first?.grooveVersion == original.id,
                "a pin is the one way to say: this section keeps this take")
    }

    @Test("a section of nothing but chords plays them: the form sounds the harmony, not just the drums")
    func chordsAlone() throws {
        let directory = GuidanceFixture.temporaryDirectory("structure-chords")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        #expect(app.arrange([Section(name: "Verse", stitch: [built.progression].lanes, lengthInBars: 8)]))
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
        let lyric = try #require(built.song.versions.first { $0.type == .lyric }).partID
        #expect(app.arrange([Section(name: "Verse", stitch: [lyric].lanes, lengthInBars: 8)]))
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
        #expect(model.sections.allSatisfy { $0.stitch.contains(part: groove) && $0.stitch.contains(part: bass) })
        // The chop plays as cut.
        #expect(model.layers.contains { $0.id == chop && $0.plays })
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
