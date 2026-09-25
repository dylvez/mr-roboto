import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The workflow, made shorter: a new song has a shape, the dock grows with the song, a chop is
// heard as soon as it is cut, and a surface says whether its part is heard at all.

@Suite("Workflow: a new song has a shape") @MainActor
struct StartingFormTests {

    @Test("a new song starts with an intro, a verse and a hook, and the first groove plays in all three")
    func startingForm() {
        let (app, directory, _) = CompletenessFixture.app("starting-form")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Sketch"))
        #expect(app.song?.sections.map(\.name) == ["Intro", "Verse", "Hook"])
        #expect(!app.playback.isArranged, "nothing is stitched yet: an empty form is a shape, not an arrangement")

        let groove = TransportFixture.grooveVersion()
        #expect(app.record(groove))
        #expect(app.song?.sections.allSatisfy { $0.stitch.contains { $0.part == groove.partID } } == true)
        #expect(app.playback.isArranged)
        #expect(app.playback.segments.map(\.name) == ["Intro", "Verse", "Hook"])
    }

    @Test("the path counts an arrangement by what its sections play, not by their number")
    func pathCountsStitchedSections() {
        var song = Song.new(title: "Sketch")
        #expect(WorkPath.count(.arrange, in: song) == 0)
        let groove = TransportFixture.grooveVersion()
        try? song.append(groove)
        song.sections[1].stitch = [Lane(part: groove.partID)]
        #expect(WorkPath.count(.arrange, in: song) == 1)
    }
}

@Suite("Workflow: the dock grows with the song")
struct DockGrowsTests {

    @Test("the words, the Booth and the Mixer join the dock once there is a form that plays")
    func laterSurfaces() {
        var song = Song.new(title: "Sketch")
        #expect(Guidance.laterSurfaces(for: song).isEmpty)
        let groove = TransportFixture.grooveVersion()
        try? song.append(groove)
        #expect(Guidance.laterSurfaces(for: song).isEmpty, "a groove in no section is not yet a form")
        song.sections[0].stitch = [Lane(part: groove.partID)]
        #expect(Guidance.laterSurfaces(for: song) == [.lyrics, .booth, .mixer])
        #expect(Guidance.dockShortcut(for: .grid) == "⌘3")
        #expect(Guidance.dockShortcut(for: .booth) == "⌘0")
    }
}

@Suite("Workflow: what you make, you hear") @MainActor
struct AudibilityTests {

    private let media = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")

    @Test("a dry chop plays in the song and in the form, as cut")
    func dryChopPlays() {
        let chop = PartVersion(partID: PartID(),
                               kind: .sample(Sample(media: GuidanceFixture.media("c"), slices: [SliceMarker(position: 0.5)],
                                                    detectedTempo: 120)),
                               author: .user, operation: Operation.chop, note: "Bar 5 of drums stem")
        let song = TransportFixture.song([chop], sections: [])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(media))
        #expect(plan.chop != nil, "cut is enough; dust is a choice about its sound")
        #expect(plan.chop?.passes.isEmpty == true)
        #expect(StructureModel.plays(chop))
    }

    @Test("a part in no section says so, and one move puts it in every section")
    func notInTheForm() throws {
        let (app, directory, _) = CompletenessFixture.app("audibility")
        defer { try? FileManager.default.removeItem(at: directory) }
        let groove = TransportFixture.grooveVersion()
        let chords = TransportFixture.progressionVersion()
        var song = TransportFixture.song([groove, chords], sections: [
            Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8),
            Section(name: "Hook", stitch: [Lane(part: groove.partID)], lengthInBars: 8),
        ])
        song.title = "Heard"
        app.open(song)

        #expect(app.audibility(of: groove.partID) == .plays("in every section"))
        guard case .silent(_, let fix)? = app.audibility(of: chords.partID) else {
            Issue.record("the chords are in no section"); return
        }
        #expect(fix == .addToEverySection(chords.partID))
        app.apply(try #require(fix))
        #expect(app.audibility(of: chords.partID) == .plays("in every section"))
    }

    @Test("in an unarranged song an older groove says the newest has replaced it")
    func olderGrooveInAFlatSong() {
        let (app, directory, _) = CompletenessFixture.app("audibility-flat")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TransportFixture.grooveVersion()
        let second = TransportFixture.grooveVersion()
        app.open(TransportFixture.song([first, second], sections: []))
        #expect(app.audibility(of: second.partID) == .plays("in the song"))
        guard case .silent(let why, let fix)? = app.audibility(of: first.partID) else {
            Issue.record("the older groove is not heard"); return
        }
        #expect(why.contains("newest groove"))
        #expect(fix == .openStructure)
    }

    @Test("parts that are not the playing kind say nothing")
    func nothingForLyrics() {
        let (app, directory, _) = CompletenessFixture.app("audibility-lyric")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lyric = PartVersion(partID: PartID(), kind: .lyric(Lyric(lines: [])), author: .user, operation: Operation.written)
        app.open(TransportFixture.song([lyric]))
        #expect(app.audibility(of: lyric.partID) == nil)
    }

    @Test("a section in a stitched form lists where a part plays")
    func listed() {
        #expect(AppState.listed(["Verse"]) == "Verse")
        #expect(AppState.listed(["Verse", "Hook"]) == "Verse and Hook")
        #expect(AppState.listed(["Intro", "Verse", "Hook"]) == "Intro, Verse and Hook")
    }
}

@Suite("Workflow: every surface has an owner to ask")
struct SurfaceOwnerTests {

    @Test("the surfaces that are someone's work name them; the answers and the cast do not")
    func owners() {
        #expect(SurfaceKind.grid.owner == PersonaID("beatmaker"))
        #expect(SurfaceKind.chords.owner == PersonaID("harmonist"))
        #expect(SurfaceKind.mixer.owner == PersonaID("engineer"))
        #expect(SurfaceKind.compare.owner == nil)
        for kind in SurfaceKind.allCases {
            if let owner = kind.owner { #expect(Cast.standard.persona(owner) != nil, "\(kind.rawValue)'s owner is in the cast") }
        }
    }
}

@Suite("Workflow: the Master is the Mixer's tab") @MainActor
struct MasterRedirectTests {

    @Test("asking for the Master opens the Mixer and turns it to its Master tab")
    func masterOpensTheMixer() {
        let (app, directory, _) = CompletenessFixture.app("master-redirect")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Mixed"))
        var turned: [SurfaceID] = []
        app.showMasterTab = { turned.append($0) }
        let id = app.perform(SurfaceAction(surface: .master, title: "Mixed"))
        #expect(id != nil)
        #expect(app.bench.items.first { $0.id == id }?.kind == .mixer)
        #expect(turned == [id!])
    }
}

@Suite("Workflow: the masking overlay reads where two parts meet")
struct OverlaySectionTests {

    @Test("the first section that plays both, else the whole song")
    func meeting() {
        let a = PartID(), b = PartID()
        var song = Song(title: "Meet", tempo: 100)
        song.sections = [Section(name: "Intro", stitch: [Lane(part: a)], lengthInBars: 4),
                         Section(name: "Verse", stitch: [Lane(part: a), Lane(part: b)], lengthInBars: 8)]
        #expect(MixerModel.meetingSection(of: a, b, in: song) == song.sections[1].id)
        song.sections[1].stitch = [Lane(part: b)]
        #expect(MixerModel.meetingSection(of: a, b, in: song) == nil, "they never meet: read the whole song")
    }
}

@Suite("Song settings: put back what the popover opened with")
struct SettingsPutBackTests {
    @Test("the line names only what Put back would change, in the words the settings use")
    func differences() {
        var song = Song.new(title: "Glass", key: Key(tonic: NoteName(.d), mode: .aeolian), tempo: 88)
        let opened = SongSettingsPopover.Settings(song)
        #expect(opened.differences(from: SongSettingsPopover.Settings(song)).isEmpty)
        song.tempo = 92.5
        song.key = nil
        song.title = "Glass House"
        #expect(opened.differences(from: SongSettingsPopover.Settings(song)) == "“Glass”, 88 bpm, D minor")
    }
}
