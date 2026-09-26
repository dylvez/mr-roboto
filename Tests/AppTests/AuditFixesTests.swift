import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Two more audits: what the Director's tools do against the frame's own rules, and what is heard
// against what exports. Each test is one of what they found, fixed.

@Suite("A new part joins the form only where its kind is missing", .serialized) @MainActor
struct FormJoinTests {
    @Test("a second groove does not play on top of the first; its surface offers it instead, and a tune fills every section")
    func joins() {
        let (app, directory, _) = CompletenessFixture.app("join")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Glass", tempo: 120))
        let first = TransportFixture.grooveVersion()
        #expect(app.record(first))
        #expect(app.song!.sections.allSatisfy { $0.stitch.contains(part: first.partID) }, "the first groove fills every section")

        let second = TransportFixture.grooveVersion()
        #expect(app.record(second))
        #expect(!app.song!.sections.contains { $0.stitch.contains(part: second.partID) }, "not stacked on the first")
        #expect(app.audibility(of: second.partID) == .silent("In no section, so the form never plays it", fix: .addToEverySection(second.partID)))

        app.apply(.addToEverySection(second.partID))
        #expect(app.song!.sections.allSatisfy { $0.stitch.contains(part: second.partID) && !$0.stitch.contains(part: first.partID) },
                "used instead, in every section")

        let tune = TransportFixture.melodyVersion()
        #expect(app.record(tune))
        #expect(app.song!.sections.allSatisfy { $0.stitch.contains(part: tune.partID) }, "a kind no section had goes everywhere")
    }
}

@Suite("The Director's tools, held to the frame's rules", .serialized) @MainActor
struct DirectorRulesTests {
    @Test("new chords are the song's harmony's next version, heard where the old ones were")
    func chordsAreOnePart() async throws {
        let song = FormFixture.build(tempo: 92).song
        let old = try #require(song.versions.last { $0.type == .progression })
        let workspace = DirectorScratchWorkspace(song: song)
        let result = await WritingFixture.run(WritingFixture.toolbox(workspace), "set_progression",
                                              #"{"chords":"Dm7 G7 | Cmaj7","key":"C major"}"#)
        #expect(!result.isError, "\(result.content)")
        let newest = try #require(workspace.song?.versions.last { $0.type == .progression })
        #expect(newest.partID == old.partID && newest.parents == [old.id] && newest.id != old.id)
    }

    @Test("a version the band writes moves the surface open on its part to it; a mix is signed as the Director")
    func surfacesFollow() throws {
        let rig = WritingFixture.rig()
        defer { rig.clean() }
        let words = PartVersion(partID: PartID(), kind: .lyric(Lyricist.lyric(from: "[Verse]\nfirst words")), author: .user,
                                operation: Operation.written, note: "Lyric")
        #expect(rig.app.record(words))
        let surface = try #require(rig.app.perform(Guidance.dockAction(for: .lyrics, in: rig.app.song)))
        #expect(rig.app.bound(for: surface) == [words.id])
        let workspace = AppStateWorkspace(rig.app)
        let rewritten = words.deriving(.lyric(Lyricist.lyric(from: "[Verse]\nthe Director's words")), by: .persona("Lyricist"),
                                       operation: Operation.written, note: "Lyric")
        #expect(workspace.record(rewritten))
        #expect(rig.app.bound(for: surface) == [rewritten.id], "the Lyrics surface now edits what was written, not v1")

        let mix = try #require(workspace.recordMix(Mix.unity, note: "Master confirmed"))
        #expect(mix.author == .persona("Director"))
        #expect(rig.app.log.last(where: { $0.text.hasPrefix("Mix → mix") })?.source == .director, "the rail says who")
    }

    @Test("start_song holds the tempo to the frame's range; the scratch workspace starts with the frame's form")
    func tempoAndForm() {
        let (app, directory, _) = CompletenessFixture.app("start-tempo")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(app.startSong(title: "Fast", tempo: 1_000, key: nil, machine: SynthMachine.tr808.id)?.tempo == AppState.tempoRange.upperBound)
        let scratch = DirectorScratchWorkspace(song: nil)
        let started = scratch.startSong(title: "Glass", tempo: 5, key: nil, machine: SynthMachine.tr808.id)
        #expect(started?.tempo == AppState.tempoRange.lowerBound && started?.sections.map(\.name) == ["Intro", "Verse", "Hook"])
    }

    @Test("set_mix will not guess between two strips that answer to one name")
    func ambiguousStrip() async throws {
        let built = FormFixture.build(tempo: 92)
        var song = built.song
        let twin = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1)], sound: "finger")
        let second = PartVersion(partID: PartID(), kind: .bassline(twin), author: .persona("Bassist"),
                                 operation: Operation.written, note: "Palladino line")
        try song.append(second)
        song.sections = [Section(name: "Verse", stitch: [built.groove, built.bass, second.partID].lanes, lengthInBars: 2)]
        let workspace = DirectorScratchWorkspace(song: song)
        let result = await WritingFixture.run(WritingFixture.toolbox(workspace), "set_mix",
                                              #"{"part":"Palladino line","gain_db":-3,"band_hz":0,"band_db":0,"reason":"under the kick"}"#)
        #expect(result.isError && result.content.contains("2 strips answer to"), "\(result.content)")
        #expect(result.content.contains(second.partID.description), "the ids to choose between")
    }
}

@Suite("What exports is what plays", .serialized) @MainActor
struct ExportMatchesPlaybackTests {
    private let resolver = TransportFixture.resolver(URL(fileURLWithPath: "/dev/null"))

    @Test("a song with no form renders as long as it plays: its audio to the end, its longest loop once")
    func unarrangedLength() {
        let take = TransportFixture.audioVersion(role: .take, duration: 6)
        let song = TransportFixture.song([TransportFixture.grooveVersion(), take], sections: [])
        let plan = SongPlayback.plan(for: song, mediaURL: resolver)
        #expect(!plan.isArranged)
        #expect(SectionBounce.naturalBars(of: plan) >= 3, "six seconds at 120 is three bars, not one")
    }

    @Test("stems are written for the strips the mix is heard with: not a muted one, only the soloed")
    func stemsFollowTheMix() throws {
        let built = FormFixture.build(tempo: 92)
        var song = built.song
        song.sections = [Section(name: "Verse", stitch: [built.groove, built.bass].lanes, lengthInBars: 2)]
        var plan = SongPlayback.plan(for: song, mediaURL: resolver)
        #expect(Set(Export.heardStrips(of: plan, song: song).map(\.part)) == [built.groove, built.bass])
        var mix = Mix.unity
        var bass = mix.strip(for: built.bass, label: "Bass")
        bass.isMuted = true
        mix.set(bass)
        plan.mix = mix
        #expect(Export.heardStrips(of: plan, song: song).map(\.part) == [built.groove], "muted, not in the mix")
        bass.isMuted = false
        bass.isSoloed = true
        mix.set(bass)
        plan.mix = mix
        #expect(Export.heardStrips(of: plan, song: song).map(\.part) == [built.bass], "soloed, the only one heard")
    }

    @Test("a whole-song render moves the mix at each section, as the transport does, when the mix sets gains by section")
    func sectionBoundaries() {
        let built = FormFixture.build(tempo: 120)
        var song = built.song
        song.sections = [Section(name: "Verse", stitch: [built.groove].lanes, lengthInBars: 4),
                         Section(name: "Hook", stitch: [built.groove].lanes, lengthInBars: 2)]
        var plan = SongPlayback.plan(for: song, mediaURL: resolver)
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)
        #expect(SectionBounce.sectionBoundaries(of: plan, clock: clock, sampleRate: 48_000).isEmpty, "no gains by section, one piece")
        var mix = Mix.unity
        mix.sectionGains = [SectionGain(section: song.sections[1].id, part: built.groove, gainDB: -40)]
        plan.mix = mix
        let boundaries = SectionBounce.sectionBoundaries(of: plan, clock: clock, sampleRate: 48_000)
        #expect(boundaries.count == 1 && boundaries[0].section == song.sections[1].id)
        #expect(boundaries[0].frame == 48_000 * 8, "the Hook starts at bar 5: eight seconds in")
    }
}

@Suite("Surfaces keep on what the song holds, not on what they opened on", .serialized) @MainActor
struct NewestBaseTests {
    @Test("dust added while the Grid was open survives the Grid's next keep; a machine picked there is the song's")
    func gridKeepsTheDust() throws {
        let (app, directory, _) = CompletenessFixture.app("newest-grid")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(CompletenessFixture.song("Arrival"))
        let groove = try #require(Guidance.grooves(in: app.song!).last)
        let id = try #require(app.perform(SurfaceAction(surface: .grid, title: "Grid", bound: [groove.id])))
        let item = try #require(app.bench.items.first { $0.id == id })
        let grid = SurfaceWiring.shared.gridModel(for: item, app: app)
        grid.autoKeep.delay = nil

        // Sound, meanwhile, puts the groove through an SP-1200.
        let chain = [DegradeSettings(preset: .sp1200).degradation(from: .sp1200)]
        let dusty = try #require(Dust.version(dirtying: groove, through: chain, by: .user))
        #expect(app.record(dusty))

        grid.toggle(.closedHat, step: 3)
        let kept = grid.commit()
        #expect(kept.parents == [dusty.id], "built on the dusty version, not on the one the grid opened")
        #expect(kept.kind.degradation == chain, "and the dust is still on it")

        grid.setMachine(SynthMachine.preset(id: "tr909")!)
        #expect(SongPlayback.machineID(for: groove.partID, in: app.song!) == "tr909", "the song plays the groove on it")
    }
}

@Suite("With no stems, a bar of the record is the way on") @MainActor
struct RecordChopTests {
    @Test("an imported record with no stems is offered a chop of its own bar, and the path's Chop step has somewhere to go")
    func chopTheRecord() throws {
        let song = GuidanceFixture.imported().song
        let titles = Guidance.proposals(for: song).map(\.title)
        #expect(titles.contains("Separate the stems"))
        #expect(titles.contains("Chop a bar of the record"), "\(titles)")
        let chop = WorkPath.action(.chop, in: song)
        guard case .chopBar? = chop?.prepare else { Issue.record("the Chop step goes nowhere: \(String(describing: chop))"); return }
    }
}
