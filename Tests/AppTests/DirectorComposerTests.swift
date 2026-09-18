import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// The five ways a turn ends badly, and the one rule that covers all of them: none of them may leave
// the app in a half-state. After every one of these the composer is idle, the streaming draft is
// gone, the rail is one line longer, and whatever the turn managed to record is still in the song.

@Suite("Director: every way a turn ends", .serialized) @MainActor
struct DirectorEndingTests {

    /// A Director over a script, with a frame behind it.
    struct Rig {
        var app: AppState
        var session: DirectorSession
        var directory: URL

        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    static func rig(_ replies: [DirectorScriptedTransport.Reply],
                    keySource: any ClaudeKeySource = DirectorTestClient.key,
                    transport: (any ClaudeTransport)? = nil,
                    maxRounds: Int = 12) -> Rig {
        let directory = GuidanceFixture.temporaryDirectory("director-ending")
        let app = AppState(library: Library(), song: nil,
                           store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        app.open(Song(title: "Arrival", tempo: 90))

        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let toolbox = DirectorTools.toolbox(
            workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
            workspace: AppStateWorkspace(app),
            audition: DirectorSilentAudition(),
            stage: stage, pad: pad)
        let client = ClaudeClient(keySource: keySource,
                                  transport: transport ?? DirectorScriptedTransport(replies),
                                  sleeper: DirectorRecordingSleeper(), retry: .none)
        let director = Director(client: client, toolbox: toolbox, stage: stage, pad: pad,
                                maxRounds: maxRounds)
        let session = DirectorSession(director: director, app: app)
        app.attach(band: session)
        return Rig(app: app, session: session, directory: directory)
    }

    /// Runs one turn through the session and waits for it to land.
    static func send(_ rig: Rig, _ text: String) async {
        await rig.session.refreshKeyStatus()
        rig.session.composing = text
        rig.session.send()
        // The session's turn is an unstructured task; wait on the actor rather than on a clock.
        while rig.session.isWorking { await Task.yield() }
    }

    // MARK: No key

    @Test("With no key nothing is sent, the app says so in its own voice, and your sentence stays")
    func noKey() async {
        let rig = Self.rig([], keySource: ClaudeFixedKey.none)
        defer { rig.clean() }

        await rig.session.refreshKeyStatus()
        #expect(!rig.session.keyStatus.hasKey)
        #expect(rig.session.footnote == ClaudeError.missingAPIKey.sentence)

        rig.session.composing = "chop the drums"
        rig.session.send()

        #expect(rig.session.composing == "chop the drums", "losing what you typed is not an option")
        #expect(!rig.session.isWorking)
        let last = rig.app.log.last
        #expect(last?.source == .session, "the app is the one with the news, not the band")
        #expect(last?.text == ClaudeError.missingAPIKey.sentence)
        #expect(!(last?.text.contains("sk-ant") ?? false))
    }

    @Test("A Director with a key but no frame behind the turn still answers rather than throwing")
    func noKeyThroughTheActor() async {
        let rig = Self.rig([], keySource: ClaudeFixedKey.none)
        defer { rig.clean() }
        let turn = await rig.session.director.direct("anything")
        #expect(turn.ending == .noKey)
        #expect(turn.opened.isEmpty)
        #expect(turn.say == ClaudeError.missingAPIKey.sentence)
    }

    // MARK: A refusal

    @Test("A refusal is an answer in the band's voice, and nothing is left offered")
    func refusal() async {
        let rig = Self.rig([.events(DirectorSSE.start()
                                    + DirectorSSE.refusal(category: "cyber",
                                                          explanation: "The band declined that one."))])
        defer { rig.clean() }

        await Self.send(rig, "do something unwise")

        let last = rig.app.log.last
        #expect(last?.source == .director, "a refusal is the band speaking, not an app error")
        #expect(last?.text == "The band declined that one.")
        #expect(rig.app.director.isEmpty)
        #expect(!rig.session.isWorking)
        #expect(rig.session.streaming.isEmpty)
        #expect(rig.session.composing.isEmpty)
    }

    // MARK: Cancellation

    @Test("Escape mid-stream leaves the app idle, the song intact and one honest line in the rail")
    func cancelled() async throws {
        let started = SendableBox<Bool>(false)
        let transport = DirectorStallingTransport(
            prefix: DirectorSSE.start() + DirectorSSE.text("Cutting bar nine"),
            started: { started.value = true })
        let rig = Self.rig([], transport: transport)
        defer { rig.clean() }

        let versionsBefore = rig.app.versions.count
        await rig.session.refreshKeyStatus()
        rig.session.composing = "chop it"
        rig.session.send()
        while !started.value { await Task.yield() }

        rig.session.cancel()
        while rig.session.isWorking { await Task.yield() }

        let last = rig.app.log.last
        #expect(last?.source == .session)
        #expect(last?.text == "Stopped.")
        #expect(rig.session.streaming.isEmpty, "the half-written reply is gone")
        #expect(rig.session.activity == nil)
        #expect(!rig.session.isWorking)
        // The song graph is append-only, so a cancelled turn cannot have left it half-written.
        #expect(rig.app.versions.count == versionsBefore)
        #expect(rig.app.director.isEmpty)
    }

    // MARK: A tool that fails

    @Test("A tool failure is handed back to the band, and the rail says once that it happened")
    func toolFailure() async {
        // chop_bar on a handle that was never loaded: a real failure from a real tool.
        let rig = Self.rig([
            .events(DirectorSSE.start()
                    + DirectorSSE.toolUse(id: "t1", name: "chop_bar",
                                          jsonPieces: [#"{"audio":"audio-9","bar":0,"start_seconds":null,"end_seconds":null,"method":"onsets","division":4}"#])
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Nothing has been imported yet, so there is nothing to cut.")),
        ])
        defer { rig.clean() }

        await Self.send(rig, "chop bar one")

        // The band recovered: its own sentence is the answer, and the app adds one line saying a
        // call failed on the way. Neither of them is a crash and neither of them is silence.
        let lines = rig.app.log.suffix(2)
        #expect(lines.first?.source == .director)
        #expect(lines.first?.text.contains("nothing to cut") == true)
        #expect(lines.last?.source == .session)
        #expect(lines.last?.text.contains("failed on the way") == true)
        #expect(lines.last?.detail?.contains("chop_bar") == true)
        #expect(!rig.session.isWorking)
    }

    // MARK: The round limit

    @Test("A turn that runs out of rounds says what it did and what it did not, and can be carried on")
    func roundLimit() async {
        let turn = DirectorSSE.start()
            + DirectorSSE.text("Reading the song first.")
            + DirectorSSE.toolUse(id: "t", name: "read_song", jsonPieces: ["{}"], index: 1)
            + DirectorSSE.end(stopReason: "tool_use")
        let rig = Self.rig(Array(repeating: .events(turn), count: 3), maxRounds: 3)
        defer { rig.clean() }

        await Self.send(rig, "go round in circles")

        let last = rig.app.log.last
        #expect(last?.source == .director)
        // What the model was in the middle of saying, rather than a round count. The count is in
        // the detail, where it belongs, beside the things the user can act on.
        #expect(last?.text.contains("Reading the song first.") == true)
        let detail = last?.detail ?? ""
        #expect(detail.contains("3 rounds"))
        #expect(detail.contains("read the song"), "it should say what it did: \(detail)")
        #expect(detail.contains("nothing shown or offered yet"), "and what it did not: \(detail)")
        #expect(detail.contains("carry on"))
        #expect(!rig.session.isWorking)
        #expect(rig.session.streaming.isEmpty)
    }

    // MARK: Streaming

    @Test("The reply arrives in pieces, and the rail has it before the turn is over")
    func streaming() async {
        let body = DirectorSSE.start()
            + DirectorSSE.text("Cut bar nine into eight pieces")
            + DirectorSSE.end()
        let rig = Self.rig([.events(body, chunkSize: 24)])
        defer { rig.clean() }

        let seen = SendableBox<[String]>([])
        await rig.session.refreshKeyStatus()
        let turn = await rig.session.director.direct("chop it") { event in
            if case .say(let piece) = event {
                seen.value = seen.value + [piece]
            }
        }
        #expect(!seen.value.isEmpty, "the reply streamed rather than arriving whole")
        #expect(seen.value.joined() == "Cut bar nine into eight pieces")
        #expect(turn.say == "Cut bar nine into eight pieces")
    }

    // MARK: The ledger

    @Test("What the session spent is a line under the composer, and nothing before the first turn")
    func costIsVisibleAndQuiet() async {
        let rig = Self.rig([.events(DirectorSSE.reply("Done.", inputTokens: 1200,
                                                      outputTokens: 60, cacheRead: 800))])
        defer { rig.clean() }

        await rig.session.refreshKeyStatus()
        #expect(rig.session.spendLine == nil, "an empty ledger is not a number worth showing")
        #expect(rig.session.footnote == rig.session.keyStatus.sentence)

        await Self.send(rig, "hello")

        let line = rig.session.spendLine
        #expect(line != nil)
        #expect(line?.contains("1 turn") == true)
        #expect(line?.contains("cached") == true)
        #expect(rig.session.footnote == line)
        // The same line rides on the turn, so a test and a person read the same number.
        #expect(rig.app.log.last?.detail == line)
    }

    // MARK: The composer

    @Test("An empty field does not send, and a turn in flight does not start a second one")
    func theComposerGuardsItself() async {
        let rig = Self.rig([.events(DirectorSSE.reply("Done."))])
        defer { rig.clean() }
        await rig.session.refreshKeyStatus()

        rig.session.composing = "   "
        #expect(!rig.session.canSend)
        rig.session.send()
        #expect(rig.app.log.last?.source != .you || rig.app.log.last?.text != "   ")

        rig.session.composing = "go"
        #expect(rig.session.canSend)
        rig.session.send()
        rig.session.composing = "again"
        rig.session.send()
        #expect(rig.session.composing == "again", "the second press did nothing")
        while rig.session.isWorking { await Task.yield() }
    }

    @Test("Every activity line is in the user's words rather than the tool's")
    func activityLines() {
        for name in DirectorTools.allNames {
            let line = DirectorSession.activity(for: name)
            #expect(line != "\(name)…", "\(name) has no sentence")
            #expect(line.hasSuffix("…"))
        }
        #expect(DirectorSession.activity(for: "something_new") == "something_new…")
    }
}

// MARK: - The toolbox the frame sends

@Suite("Director: the toolbox with a frame behind it") @MainActor
struct DirectorStageToolboxTests {

    private func toolbox(stage: (any DirectorStage)?) -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                              workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song()),
                              audition: DirectorSilentAudition(),
                              stage: stage,
                              pad: stage == nil ? nil : DirectorStagePad())
    }

    @Test("The two surface tools are appended, never inserted, so the cached prefix survives")
    func appended() {
        let app = FrameFixture.state()
        let bare = toolbox(stage: nil)
        let full = toolbox(stage: AppStateStage(app))

        #expect(bare.names == DirectorTools.names)
        #expect(full.names == DirectorTools.allNames)
        #expect(Array(full.names.prefix(bare.names.count)) == bare.names)
        #expect(DirectorTools.stageNames == ["open_surface", "propose"])

        // Every schema before the fourteenth is byte-identical either way, which is the whole
        // reason the list is appended rather than reordered.
        let bareSchemas = bare.tools.map { $0.definition.inputSchema.jsonText }
        let fullSchemas = full.tools.map { $0.definition.inputSchema.jsonText }
        #expect(Array(fullSchemas.prefix(bareSchemas.count)) == bareSchemas)
    }

    @Test("Both surface tools are described and legal where every other tool is")
    func wellFormed() {
        let app = FrameFixture.state()
        let full = toolbox(stage: AppStateStage(app))
        for tool in full.tools.suffix(2) {
            let schema = tool.definition.inputSchema
            #expect(schema["additionalProperties"]?.boolValue == false)
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            guard case .object(let properties)? = schema["properties"] else {
                Issue.record("\(tool.name) has no properties")
                continue
            }
            // Optional properties are absent from `required` rather than nullable — see
            // `DirectorToolboxTests.schemasAreAcceptable`, which carries the API's own refusals.
            #expect(required.isSubset(of: Set(properties.keys)),
                    "\(tool.name) requires a property it does not have")
            #expect(required.contains("surface"), "\(tool.name) must always be told which surface")
            #expect(required.contains("bound"), "\(tool.name) must always be told what to bind")
            #expect(tool.definition.description.count > 40)
            for member in properties.members {
                #expect((member.value["description"]?.stringValue ?? "").count > 10,
                        "\(tool.name).\(member.key)")
            }
        }
    }

    @Test("The catalog the model is offered is the catalog the frame has")
    func theCatalogMatches() {
        let app = FrameFixture.state()
        let full = toolbox(stage: AppStateStage(app))
        let open = full.tool(named: "open_surface")
        let values = open?.definition.inputSchema["properties"]?["surface"]?["enum"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(values == SurfaceKind.allCases.map(\.rawValue))
    }
}
