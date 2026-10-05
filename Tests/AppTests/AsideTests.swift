import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Taking a part away without deleting it: set aside, it is out of every section and out of what
// plays, is drawn and is suggested, listed in Parts, and brought back into the sections it left.

@Suite("A part set aside, and brought back", .serialized) @MainActor
struct AsideTests {

    static func arranged(_ label: String) -> (app: AppState, directory: URL, built: FormFixture.Built) {
        let directory = WiringFixture.temporaryDirectory(label)
        var built = FormFixture.build()
        built.song.sections = [Section(name: "Verse", stitch: [Lane(part: built.groove), Lane(part: built.bass)], lengthInBars: 4),
                               Section(name: "Hook", stitch: [Lane(part: built.groove), Lane(part: built.bass), Lane(part: built.progression)], lengthInBars: 4),
                               Section(name: "Outro", stitch: [Lane(part: built.groove)], lengthInBars: 2)]
        let app = FormFixture.app(built, in: directory)
        app.autosaveDelay = nil
        return (app, directory, built)
    }

    @Test("the graph: out of the sections it played in, remembered, back into those still there; a song from before round-trips")
    func graph() throws {
        let (_, directory, built) = Self.arranged("aside-graph")
        defer { WiringFixture.remove(directory) }
        var song = built.song
        // The Hook holds the bass at its first version, as a developed section does.
        let pin = try #require(song.versions(of: built.bass).first?.id)
        song.sections[1].stitch[1] = Lane(part: built.bass, pin: pin)
        let arranged = song.sections
        let old = try SongGraphCodec.encodeSong(song)
        #expect(!String(decoding: old, as: UTF8.self).contains("asides"))
        let bass = built.bass
        let hook = song.sections[1].id
        let set = song.setAside(bass, note: "too busy")
        let twice = song.setAside(bass)
        #expect(set && !twice && song.isAside(bass) && song.aside(bass)?.sections.count == 2)
        #expect(song.sections.allSatisfy { !$0.stitch.contains(part: bass) })
        #expect(song.latestVersion(of: bass) != nil, "nothing is deleted")
        let heard = song.withoutAsides
        #expect(heard.latestVersion(of: bass) == nil && heard.versions.count == song.versions.count - 1)
        let decoded = try SongGraphCodec.decodeSong(from: try SongGraphCodec.encodeSong(song))
        #expect(decoded == song && decoded.aside(bass)?.note == "too busy")

        var exact = song
        exact.bringBack(bass)
        #expect(exact.sections == arranged, "back where it was, in each section's order, held where it was held")

        song.sections.remove(at: 0)
        let back = song.bringBack(bass)
        #expect(back == [hook], "the Verse is gone; the Hook takes it back")
        #expect(song.asides == nil && song.sections[0].stitch[1] == Lane(part: bass, pin: pin))
        let none = song.bringBack(bass)
        #expect(none == nil)
    }

    @Test("the Producer counts what is in the song: a part set aside is neither a part nor one in no section")
    func producer() throws {
        let (_, directory, built) = Self.arranged("aside-producer")
        defer { WiringFixture.remove(directory) }
        var song = built.song
        let bass = try #require(song.latestVersion(of: built.bass).map(PartLabel.title(of:)))
        // The bass taken out of every section by hand is in no section, and the Producer says so.
        var unstitched = song
        for index in unstitched.sections.indices { unstitched.sections[index].stitch.removeAll { $0.part == built.bass } }
        #expect(SongObservation.of(unstitched).orphanedParts.contains(bass))
        // Set aside, it is out of the song: not one of its parts, and not waiting for a section.
        let before = SongObservation.of(song)
        let set = song.setAside(built.bass, note: "too busy")
        #expect(set)
        let after = SongObservation.of(song)
        #expect(!after.orphanedParts.contains(bass), "\(after.orphanedParts)")
        #expect(after.orphanedParts == before.orphanedParts && after.partCount == before.partCount - 1)
    }

    @Test("set aside it does not play, has no row in Structure, no fader, and the band does not suggest it; brought back it does")
    func app() throws {
        let (app, directory, built) = Self.arranged("aside-app")
        defer { WiringFixture.remove(directory) }
        let hadBass = app.playback.segments.contains { $0.voices.contains { $0.part == built.bass } }
        #expect(hadBass)
        let mixRows = { MixerModel.rows(of: app.playback, song: app.song, mix: Mix()).map(\.part) }
        #expect(mixRows().contains(built.bass))

        #expect(app.setAside(built.bass, note: "trying it without"))
        #expect(app.log.last?.text == "Set Palladino line aside" && app.log.last?.detail?.hasPrefix("Out of the 2 sections it played in") == true)
        #expect(!app.playback.segments.contains { $0.voices.contains { $0.part == built.bass } })
        #expect(!StructureModel.layers(in: try #require(app.song)).contains { $0.id == built.bass })
        #expect(!mixRows().contains(built.bass))
        #expect(!Develop.loop(of: try #require(app.song)).contains { $0.partID == built.bass })
        #expect(!FormTools.defaultStitch(in: try #require(app.song)).contains(part: built.bass))
        #expect(!app.nextQuestion.options.contains { $0.title.contains("Palladino") })
        let groups = LedgerGroups.groups(for: try #require(app.song))
        #expect(groups.last?.title == LedgerGroups.asideTitle && groups.last?.parts.map(\.id) == [built.bass])
        let others = Array(groups.dropLast())
        #expect(!others.contains { group in group.parts.contains { $0.id == built.bass } })
        #expect(app.asideVersions.map(\.partID) == [built.bass])

        // A new version of it, made while it is aside, stays aside and joins nothing.
        let bass = try #require(app.song?.latestVersion(of: built.bass))
        #expect(app.record(bass.deriving(bass.kind, by: .user, operation: "edit", note: "Palladino line")))
        #expect(app.song?.isAside(built.bass) == true && app.song?.sections.allSatisfy { !$0.stitch.contains(part: built.bass) } == true)

        #expect(app.bringBack(built.bass))
        #expect(app.log.last?.text == "Brought Palladino line back" && app.log.last?.detail == "It plays in Verse, Hook again.")
        #expect(app.playback.segments.contains { $0.voices.contains { $0.part == built.bass } })
        let reopenedGroups = LedgerGroups.groups(for: try #require(app.song))
        #expect(mixRows().contains(built.bass) && reopenedGroups.last?.title != LedgerGroups.asideTitle)
        #expect(!app.bringBack(built.bass))

        // Saved and opened again, the song keeps what is aside.
        #expect(app.setAside(built.progression))
        app.save()
        let reopened = try app.store!.songStore(for: built.song.id).load()
        #expect(reopened.isAside(built.progression) && reopened.aside(built.progression)?.sections.count == 1)
    }

    @Test("a song with no form: the newest groove plays until it is set aside, then the one before it")
    func unarranged() throws {
        let directory = WiringFixture.temporaryDirectory("aside-flat")
        defer { WiringFixture.remove(directory) }
        var built = FormFixture.build()
        let second = PartVersion(partID: PartID(), kind: built.song.latestVersion(of: built.groove)!.kind, author: .user,
                                 operation: Operation.written, note: "Second groove")
        try built.song.append(second)
        let app = FormFixture.app(built, in: directory)
        #expect(app.playback.voices.contains { $0.part == second.partID })
        #expect(app.setAside(second.partID))
        #expect(app.playback.voices.contains { $0.part == built.groove } && !app.playback.voices.contains { $0.part == second.partID })
    }

    @Test("the band: a reference chop joins no section and is set aside; set_aside takes a part out and brings it back; read_song says so")
    func band() async throws {
        let (app, directory, built) = Self.arranged("aside-band")
        defer { WiringFixture.remove(directory) }
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func json(_ result: ClaudeToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? [:]
        }
        let out = json(await toolbox.run(ClaudeToolUse(id: "a", name: "set_aside", input: .object([
            .init("part", .string(built.bass.description)), .init("back", .bool(false)), .init("reason", .string("the user wants it sparse")),
        ]))))
        #expect(out["set_aside"] as? Bool == true && (out["sections"] as? [String])?.isEmpty == true)
        #expect(app.song?.aside(built.bass)?.note == "the user wants it sparse" && app.log.last?.text == "Set Palladino line aside")
        let song = json(await toolbox.run(ClaudeToolUse(id: "r", name: "read_song", input: .object([]))))
        let bass = (song["versions"] as? [[String: Any]])?.first { $0["part"] as? String == built.bass.description }
        #expect(bass?["set_aside"] as? Bool == true && bass?["aside_because"] as? String == "the user wants it sparse")
        let again = await toolbox.run(ClaudeToolUse(id: "b", name: "set_aside", input: .object([
            .init("part", .string(built.bass.description)), .init("back", .bool(false)), .init("reason", .string("")),
        ])))
        #expect(again.isError && again.content.contains("set aside already"))
        let back = json(await toolbox.run(ClaudeToolUse(id: "c", name: "set_aside", input: .object([
            .init("part", .string(built.bass.description)), .init("back", .bool(true)), .init("reason", .string("")),
        ]))))
        #expect(back["sections"] as? [String] == ["Verse", "Hook"])

        // A chop cut only to read: recorded, in no section, set aside as reference.
        let chop = try #require(app.song?.latestVersion(of: built.dryChop))
        let reference = chop.spawning(chop.kind, by: .persona("Sampler"), operation: Operation.chop, note: "The string stem's attacks, mapped")
        #expect(AppStateWorkspace(app).recordReference(reference, note: "The string stem's attacks, mapped"))
        #expect(app.song?.isAside(reference.partID) == true && app.song?.aside(reference.partID)?.note == "reference: The string stem's attacks, mapped")
        #expect(app.song?.aside(reference.partID)?.sections.isEmpty == true, "it never joined a section, so it has none to go back to")
        #expect(app.song?.sections.allSatisfy { !$0.stitch.contains(part: reference.partID) } == true)
    }
}

@Suite("A song made of records: its path and the band's question", .serialized) @MainActor
struct AssembledPathTests {

    @Test("a song of sources is assembled: sources, drums, chords, bass, tune, arrange, mix; the band asks for drums, then another record")
    func path() async throws {
        let directory = WiringFixture.temporaryDirectory("assembled")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 2)
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        app.open(Song.new(title: "From the crate"))
        let start = app.nextQuestion
        #expect(start.options.first?.title == "Start from a record in the crate", "\(start.options.map(\.title))")

        let first = try #require(app.library.records.first)
        _ = try await app.addSource(SourceRequest(record: first.id, stem: "vocals"))
        let song = try #require(app.song)
        #expect(WorkPath.of(song) == .assembled)
        let (path, steps) = WorkPath.steps(for: song, active: nil, canPerform: { _ in true })
        #expect(path == .assembled && steps.map(\.kind) == [.sources, .groove, .chords, .bass, .tune, .arrange, .mix])
        #expect(steps.first?.count == 1 && steps.first { $0.isNext }?.kind == .groove)
        #expect(WorkPath.stepKind(for: .sources, bound: [], in: song, path: path) == .sources)

        let working = app.nextQuestion
        #expect(working.options.first?.title == "Add drums", "\(working.options.map(\.title))")
        #expect(working.options.contains { $0.title == "Bring in a stem from another record" })
        #expect(working.observation.contains("nothing keeping time") || working.options.first?.rationale.contains("nothing keeping time") == true)

        // With a drums source in, drums are not asked for.
        _ = try await app.addSource(SourceRequest(record: app.library.records[1].id, stem: "drums"))
        #expect(!app.nextQuestion.options.contains { $0.title == "Add drums" })
        #expect(NextAdvisor.keepsTime(try #require(app.song)))
    }
}
