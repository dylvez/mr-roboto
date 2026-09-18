import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// B11, without the network: `arrange` states the form in a line and `stitch_section` adds one
// section with what it plays; both replace the song's sections and version nothing; the Structure
// surface opens for the Director on nothing; and "make this a two-minute song" produces sections
// the transport plays.

@MainActor
private enum FormToolFixture {
    struct Rig {
        var app: AppState
        var toolbox: DirectorToolbox
        var groove: VersionID
        var bass: VersionID
        var directory: URL
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A song at 92 with a kicking groove and a bass line under it, and the dry chop of the fixture.
    static func rig(tempo: Double = 92) throws -> Rig {
        let directory = GuidanceFixture.temporaryDirectory("form-tools")
        let built = FormFixture.build(tempo: tempo)
        let app = FormFixture.app(built, in: directory)
        let groove = built.groove
        let bass = built.bass
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4))
        let toolbox = DirectorTools.toolbox(workbench: workbench, workspace: AppStateWorkspace(app))
        return Rig(app: app, toolbox: toolbox, groove: groove, bass: bass, directory: directory)
    }

    static func json(_ result: ClaudeToolResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func sections(_ out: [String: Any]) -> [[String: Any]] { out["sections"] as? [[String: Any]] ?? [] }
}

@Suite("Director: arrange and stitch_section", .serialized) @MainActor
struct DirectorFormToolTests {

    @Test("the form is read as a line: names, bars, and the usual length when none is given")
    func parsing() throws {
        let parsed = try ArrangeTool.parse("intro 4 | Verse 16 | hook | verse, outro 2 bars", tool: "arrange")
        #expect(parsed.map(\.0) == ["Intro", "Verse", "Hook", "Verse", "Outro"])
        #expect(parsed.map(\.1) == [4, 16, 8, 16, 2])
        #expect(throws: DirectorToolFailure.self) { try ArrangeTool.parse(" | ", tool: "arrange") }
        #expect(throws: DirectorToolFailure.self) { try ArrangeTool.parse("16", tool: "arrange") }
        #expect(throws: DirectorToolFailure.self) { try ArrangeTool.parse("verse 0", tool: "arrange") }
        #expect(throws: DirectorToolFailure.self) { try ArrangeTool.parse("verse 500", tool: "arrange") }
    }

    @Test("arrange replaces the form with sections stitched from the newest parts; a repeated name shares its stitch")
    func arranges() async throws {
        let rig = try FormToolFixture.rig()
        defer { rig.clean() }
        let before = rig.app.song!.versions.count
        let result = await rig.toolbox.run(ClaudeToolUse(id: "a", name: "arrange", input: .object([
            .init("form", .string("intro 4 | verse 16 | hook 8 | verse 16 | hook 8 | outro 4")),
        ])))
        #expect(!result.isError, "\(result.content)")
        let out = FormToolFixture.json(result)
        let sections = FormToolFixture.sections(out)
        #expect(sections.map { $0["name"] as? String } == ["Intro", "Verse", "Hook", "Verse", "Hook", "Outro"])
        #expect(out["bars"] as? Int == 56)
        #expect((out["seconds"] as? Double).map { abs($0 - 56 * 4 * 60 / 92) < 1e-6 } == true)
        #expect(out["recorded"] as? Bool == true)
        #expect((out["detail"] as? String)?.contains("Structure") == true)
        for section in sections {
            let versions = section["versions"] as? [String] ?? []
            #expect(versions.contains(rig.groove.description) && versions.contains(rig.bass.description))
            #expect(section["plays"] as? Bool == true)
        }

        let song = try #require(rig.app.song)
        #expect(song.sections.count == 6)
        #expect(song.versions.count == before, "arranging versions nothing")
        #expect(song.sections[1].stitch == song.sections[3].stitch)
        #expect(rig.app.hasUnsavedChanges)
        #expect(rig.app.playback.isArranged)
        #expect(rig.app.playback.segments.count == 6)

        // Arranging again keeps a named section's stitch even after it was hand-edited.
        var edited = song.sections
        edited[1].stitch = [rig.groove]
        #expect(rig.app.arrange(edited))
        let again = await rig.toolbox.run(ClaudeToolUse(id: "b", name: "arrange", input: .object([
            .init("form", .string("verse 8 | hook 8")),
        ])))
        #expect(!again.isError)
        #expect(rig.app.song?.sections.map(\.name) == ["Verse", "Hook"])
        #expect(rig.app.song?.sections[0].stitch == [rig.groove], "the verse kept what it was stitched from")
        #expect(rig.app.song?.sections[1].stitch.contains(rig.bass) == true)
    }

    @Test("with nothing that plays, arrange refuses and says what would make it possible")
    func refusesAnEmptySong() async throws {
        let directory = GuidanceFixture.temporaryDirectory("form-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        app.open(Song(title: "Blank"))
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        let result = await toolbox.run(ClaudeToolUse(id: "a", name: "arrange", input: .object([.init("form", .string("verse 16"))])))
        #expect(result.isError)
        #expect(result.content.contains("nothing to arrange"))
        #expect(result.content.contains("Paint a groove"))
        #expect(app.song?.sections.isEmpty == true)
    }

    @Test("stitch_section adds one section where it is told, with the versions it names, and refuses what does not play")
    func stitches() async throws {
        let rig = try FormToolFixture.rig()
        defer { rig.clean() }
        #expect(rig.app.arrange([Section(name: "Verse", stitch: [rig.groove, rig.bass], lengthInBars: 16)]))

        // A bridge with no bass, after the verse.
        let result = await rig.toolbox.run(ClaudeToolUse(id: "s", name: "stitch_section", input: .object([
            .init("name", .string("Bridge")), .init("bars", .int(8)),
            .init("versions", .array([.string(rig.groove.description)])), .init("position", .int(1)),
        ])))
        #expect(!result.isError, "\(result.content)")
        #expect(rig.app.song?.sections.map(\.name) == ["Verse", "Bridge"])
        #expect(rig.app.song?.sections[1].stitch == [rig.groove])

        // An intro first, from the newest of everything.
        let intro = await rig.toolbox.run(ClaudeToolUse(id: "i", name: "stitch_section", input: .object([
            .init("name", .string("Intro")), .init("bars", .int(4)), .init("versions", .array([])), .init("position", .int(0)),
        ])))
        #expect(!intro.isError, "\(intro.content)")
        #expect(rig.app.song?.sections.map(\.name) == ["Intro", "Verse", "Bridge"])
        #expect(rig.app.song?.sections[0].stitch.contains(rig.bass) == true)

        // Past the end appends; a progression is not something a section plays; a dry chop neither.
        let progression = try #require(rig.app.song?.versions.first { $0.type == .progression })
        let refused = await rig.toolbox.run(ClaudeToolUse(id: "p", name: "stitch_section", input: .object([
            .init("name", .string("Outro")), .init("bars", .int(4)),
            .init("versions", .array([.string(progression.id.description)])), .init("position", .int(99)),
        ])))
        #expect(refused.isError)
        #expect(refused.content.contains("not something a section plays"))
        let dry = try #require(rig.app.song?.versions.first { $0.type == .sample })
        let dryRefused = await rig.toolbox.run(ClaudeToolUse(id: "d", name: "stitch_section", input: .object([
            .init("name", .string("Outro")), .init("bars", .int(4)),
            .init("versions", .array([.string(dry.id.description)])), .init("position", .int(99)),
        ])))
        #expect(dryRefused.isError)
        #expect(dryRefused.content.contains("dry chop"))
        #expect(dryRefused.content.contains("degrade_part"))
        #expect(rig.app.song?.sections.count == 3)

        let outro = await rig.toolbox.run(ClaudeToolUse(id: "o", name: "stitch_section", input: .object([
            .init("name", .string("Outro")), .init("bars", .int(4)), .init("versions", .array([])), .init("position", .int(99)),
        ])))
        #expect(!outro.isError)
        #expect(rig.app.song?.sections.last?.name == "Outro")
    }

    @Test("read_song reports the sections with their ids and versions, so the Director can restitch them")
    func readSongSections() async throws {
        let rig = try FormToolFixture.rig()
        defer { rig.clean() }
        #expect(rig.app.arrange([Section(name: "Verse", stitch: [rig.groove, rig.bass], lengthInBars: 16)]))
        let result = await rig.toolbox.run(ClaudeToolUse(id: "r", name: "read_song", input: .object([])))
        let out = FormToolFixture.json(result)
        let sections = FormToolFixture.sections(out)
        #expect(sections.count == 1)
        #expect(sections[0]["id"] as? String == rig.app.song?.sections[0].id.description)
        #expect(sections[0]["versions"] as? [String] == [rig.groove.description, rig.bass.description])
        #expect(out["length_in_bars"] as? Int == 16)
        #expect(out["time_signature"] as? String == "4/4")
    }
}

@Suite("Director: the Structure surface as an answer", .serialized) @MainActor
struct DirectorStructureChoiceTests {

    @Test("Structure opens on nothing, and refuses to be bound to a version")
    func unbound() throws {
        let directory = GuidanceFixture.temporaryDirectory("form-choice")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = FormFixture.build()
        let app = FormFixture.app(built, in: directory)
        let stage = AppStateStage(app)

        let choice = try DirectorSurfaceChoice.make(surface: .structure, title: "The form", fill: .parts([]),
                                                    because: "You asked for a two-minute song.", in: stage)
        #expect(choice.action.surface == .structure)
        #expect(choice.action.bound.isEmpty)
        #expect(app.canPerform(choice.action))

        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .structure, title: "The form", fill: .parts([built.groove]),
                                           because: "", in: stage)
        }
        // Every other part surface still needs something bound.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .grid, title: "Grid", fill: .parts([]), because: "", in: stage)
        }
    }
}

// MARK: - The proof

@Suite("Director: the Gate C proof", .serialized)
struct DirectorFormProofTests {

    @Test("Make this a two-minute song")
    func twoMinutes() async throws {
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_song", "{}")))
        // 92 bpm, 4/4: a bar is 2.61 s, two minutes is 46 bars.
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call(
            "t2", "arrange", #"{"form":"intro 4 | verse 16 | hook 8 | verse 8 | hook 8 | outro 2"}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call(
            "t3", "open_surface",
            #"{"surface":"Structure","title":"Two minutes of Arrival","bound":[],"reference":null,"finding":null,"because":"The form is the answer, and the transport plays it in order.","levers":[]}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Six sections, 46 bars: at 92 bpm a bar is 2.6 seconds, so 46 bars is two minutes. Intro 4, "
            + "verse 16, hook 8, verse 8, hook 8, outro 2, each on the groove and the bass line. Structure "
            + "is open; the space bar plays it through.")))

        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }

        try await MainActor.run {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            let groove = PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                     operation: Operation.written, note: "Boom-Bap Pocket")
            #expect(rig.app.record(groove))
        }

        let turn = await rig.director.direct("Make this a two-minute song")

        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_song", "arrange", "open_surface"])
        try await MainActor.run {
            let song = try #require(rig.app.song)
            #expect(song.sections.map(\.name) == ["Intro", "Verse", "Hook", "Verse", "Hook", "Outro"])
            #expect(song.lengthInBars == 46)
            #expect(song.sections.allSatisfy { !$0.stitch.isEmpty })
            #expect(song.versions.count == 1, "nothing was versioned")
            let plan = rig.app.playback
            #expect(plan.isArranged && plan.isPlayable)
            #expect(plan.segments.count == 6)
            // The rig's song is at 90, so the form is 46 bars of *its* clock; the two-minute
            // arithmetic is the model's and lives in its reply.
            let expected = Double(46 * song.timeSignature.beatsPerBar) * 60 / song.tempo
            #expect(plan.formSeconds.map { abs($0 - expected) < 1e-6 } == true, "\(plan.formSeconds ?? 0) s")
            #expect(rig.app.bench.items.contains { $0.kind == .structure })
        }
        #expect(turn.opened.count == 1)
        #expect(turn.opened.first?.surface == .structure)
        #expect(turn.say.contains("46 bars"))
    }
}
