import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The first proof, end to end, against a recorded conversation.
//
// "Chop the drums from bar 9 and give me something slower and dustier" should open the Chop lane on
// bar 9 and a Compare with three candidates. There is no API key in this shell and no network in
// CI, so the model's half of the conversation is a script — but nothing under it is stubbed: the
// chopper cuts real audio, the classifier really classifies it, the feel library is the real one,
// the re-groove engine really runs, the versions really land in the song graph, and the surfaces
// really open on the bench.
//
// The one thing a script cannot do is know a UUID that does not exist yet. `create_part_version`
// mints version ids at run time and the round after it has to *use* them, so the last replies are
// written as closures that read the ids back out of the song — which is exactly what the model does
// when it reads the tool's result.

// MARK: - A transport whose replies can be written late

/// Replays replies in order, like `DirectorScriptedTransport`, except each one is produced when it
/// is asked for rather than when the script is written.
actor DirectorLateTransport: ClaudeTransport {
    private var replies: [@Sendable () async -> String]
    private(set) var requests: [ClaudeHTTPRequest] = []

    init(_ replies: [@Sendable () async -> String]) { self.replies = replies }

    /// A reply whose text is fixed.
    static func fixed(_ body: String) -> @Sendable () async -> String { { body } }

    var requestCount: Int { requests.count }
    func request(_ index: Int) -> ClaudeHTTPRequest { requests[index] }

    func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else {
            throw ClaudeError.transport("the script ran out after \(requests.count) request(s)")
        }
        let body = await replies.removeFirst()()
        return ClaudeHTTPResponse(status: 200, data: Data(body.utf8))
    }
}

/// A value written after the script is built and read while it is running.
///
/// The test's stand-in for the model reading a tool result: what does not exist when the
/// conversation is written does exist by the time the turn that uses it is sent.
final class SendableBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { self.stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

// MARK: - The fixture

enum DirectorTurnFixture {

    /// Twelve bars of the same break at 90 bpm, so bar 9 is a real bar with real audio in it.
    static func twelveBars() -> [[Float]] {
        let one = DirectorAudioFixture.bar()
        return one.map { channel in Array(repeating: channel, count: 12).flatMap { $0 } }
    }

    /// Four feels in common time whose names survive a trip through JSON. The script needs a
    /// reference read and three candidates, and they have to be feels the real library holds.
    static func feels() -> [String] {
        FeelLibrary.standard.feels
            .filter { $0.timeSignature == .fourFour }
            .map(\.name)
            .filter { name in name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" } }
            .prefix(4)
            .map { $0 }
    }

    /// Everything one turn needs: a frame over a real library, a record on disk, and a Director
    /// whose model is a script.
    struct Rig {
        var app: AppState
        var workspace: AppStateWorkspace
        var stage: AppStateStage
        var pad: DirectorStagePad
        var director: Director
        var transport: DirectorLateTransport
        var recordURL: URL
        var directory: URL

        func clean() {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: recordURL.deletingLastPathComponent())
        }
    }

    @MainActor
    static func rig(_ replies: [@Sendable () async -> String], bars: Int = 12) throws -> Rig {
        let directory = GuidanceFixture.temporaryDirectory("director-turn")
        let url = try DirectorAudioFixture.write(twelveBars(), named: "Arrival.wav")

        let app = AppState(library: Library(), song: nil,
                           store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        app.open(Song(title: "Arrival", artist: "Vessel", tempo: DirectorAudioFixture.tempo))

        let workspace = AppStateWorkspace(app)
        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: bars))
        let toolbox = DirectorTools.toolbox(workbench: workbench,
                                            workspace: workspace,
                                            audition: DirectorSilentAudition(),
                                            stage: stage,
                                            pad: pad)
        let transport = DirectorLateTransport(replies)
        let client = ClaudeClient(keySource: DirectorTestClient.key, transport: transport,
                                  sleeper: DirectorRecordingSleeper(), retry: .none)
        let director = Director(client: client, toolbox: toolbox, stage: stage, pad: pad)
        return Rig(app: app, workspace: workspace, stage: stage, pad: pad, director: director,
                   transport: transport, recordURL: url, directory: directory)
    }

    /// One round: the model calls one tool and stops.
    static func call(_ id: String, _ tool: String, _ json: String) -> String {
        DirectorSSE.start() + DirectorSSE.toolUse(id: id, name: tool, jsonPieces: [json])
            + DirectorSSE.end(stopReason: "tool_use")
    }

    /// Several calls in one round, which is what the model really does for parallel work.
    static func calls(_ pairs: [(String, String, String)]) -> String {
        var body = DirectorSSE.start()
        for (index, pair) in pairs.enumerated() {
            body += DirectorSSE.toolUse(id: pair.0, name: pair.1, jsonPieces: [pair.2], index: index)
        }
        return body + DirectorSSE.end(stopReason: "tool_use")
    }

    /// The version ids in the open song of one type, oldest first. `DirectorWorkspace` is
    /// `Sendable` and main-actor isolated, so a script closure can read through it safely.
    static func versions(_ workspace: AppStateWorkspace?, ofType type: PartType) async -> [String] {
        guard let workspace else { return [] }
        return await workspace.song?.versions.filter { $0.type == type }.map(\.id.description) ?? []
    }
}

// MARK: - The first proof

@Suite("Director: the first proof", .serialized)
struct DirectorFirstProofTests {

    @Test("Chop the drums from bar 9 and give me something slower and dustier")
    func theFirstProof() async throws {
        let feels = DirectorTurnFixture.feels()
        try #require(feels.count == 4, "the feel library needs four usable 4/4 feels")

        let path = SendableBox<String>("")
        let workspace = SendableBox<AppStateWorkspace?>(nil)

        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_song", "{}")))
        replies.append({ DirectorTurnFixture.call("t2", "import_record", #"{"path":"\#(path.value)"}"#) })
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t3", "analyse_record", #"{"audio":"audio-1"}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t4", "list_bars", #"{"audio":"audio-1","from_bar":6,"count":6}"#)))
        // Bar 9 as a person counts it is bar 8 as list_bars numbers them.
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t5", "chop_bar",
                                     #"{"audio":"audio-1","bar":8,"start_seconds":null,"end_seconds":null,"method":"onsets","division":4}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t6", "classify_slices", #"{"chop":"chop-1","overrides":null}"#)))
        // The straight read, then three slower ones. Four grooves, because the thing the candidates
        // are judged against has to be the same kind of thing they are.
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.calls([
            ("t7", "regroove_chop", #"{"chop":"chop-1","feel":"\#(feels[0])","tempo":90,"bars":1,"overlap":null,"rotate":null}"#),
            ("t8", "regroove_chop", #"{"chop":"chop-1","feel":"\#(feels[1])","tempo":78,"bars":1,"overlap":null,"rotate":null}"#),
            ("t9", "regroove_chop", #"{"chop":"chop-1","feel":"\#(feels[2])","tempo":78,"bars":1,"overlap":null,"rotate":null}"#),
            ("t10", "regroove_chop", #"{"chop":"chop-1","feel":"\#(feels[3])","tempo":74,"bars":1,"overlap":null,"rotate":null}"#),
        ])))
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.calls([
            ("t11", "create_part_version", #"{"from":"chop-1","note":"Bar 9 of Arrival, cut on its transients","persona":null,"parent":null}"#),
            ("t12", "create_part_version", #"{"from":"groove-1","note":"Bar 9 as it is, at 90","persona":null,"parent":null}"#),
            ("t13", "create_part_version", #"{"from":"groove-2","note":"Slower, on \#(feels[1])","persona":null,"parent":null}"#),
            ("t14", "create_part_version", #"{"from":"groove-3","note":"Slower and dustier, on \#(feels[2])","persona":null,"parent":null}"#),
            ("t15", "create_part_version", #"{"from":"groove-4","note":"Slowest, on \#(feels[3])","persona":null,"parent":null}"#),
        ])))
        // The two surfaces, written out of the ids the versions actually got.
        replies.append({
            let samples = await DirectorTurnFixture.versions(workspace.value, ofType: .sample)
            return DirectorTurnFixture.call(
                "t16", "open_surface",
                #"{"surface":"Chop lane","title":"Bar 9 of Arrival","bound":["\#(samples[0])"],"reference":null,"finding":null,"because":"The bar you asked for, cut on its own transients.","levers":null}"#)
        })
        replies.append({
            let grooves = await DirectorTurnFixture.versions(workspace.value, ofType: .groove)
            return DirectorTurnFixture.call(
                "t17", "open_surface",
                #"{"surface":"Compare","title":"Three slower reads","bound":["\#(grooves[1])","\#(grooves[2])","\#(grooves[3])"],"reference":"\#(grooves[0])","finding":null,"because":"Each one is bar 9 on a different feel, judged against the straight read at 90.","levers":[{"quantity":"tempo","label":"Slower","value":78},{"quantity":"dust","label":"Dustier","value":0.6}]}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Cut bar 9 into slices and played it three ways, against the straight read at 90. "
            + "The Compare is open; press one to hear it.")))

        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        path.value = rig.recordURL.path
        workspace.value = rig.workspace

        let turn = await rig.director.direct(
            "Chop the drums from bar 9 and give me something slower and dustier")

        // The work happened, in the order the work happens.
        #expect(turn.ending == .answered)
        #expect(Array(turn.calls.prefix(6)) == ["read_song", "import_record", "analyse_record",
                                                "list_bars", "chop_bar", "classify_slices"])
        #expect(turn.calls.filter { $0 == "regroove_chop" }.count == 4)
        #expect(turn.calls.filter { $0 == "create_part_version" }.count == 5)
        #expect(Array(turn.calls.suffix(2)) == ["open_surface", "open_surface"])

        // Five versions landed in the song graph: the chop, and four grooves off it.
        let samples = await DirectorTurnFixture.versions(rig.workspace, ofType: .sample)
        let grooves = await DirectorTurnFixture.versions(rig.workspace, ofType: .groove)
        #expect(samples.count == 1)
        #expect(grooves.count == 4)

        // Two surfaces, the right kinds, the right bindings.
        #expect(turn.opened.count == 2)
        let lane = try #require(turn.opened.first)
        #expect(lane.surface == .chopLane)
        #expect(lane.title == "Bar 9 of Arrival")
        #expect(lane.fill.bound.map(\.description) == samples)

        let compare = try #require(turn.opened.last)
        #expect(compare.surface == .compare)
        // Rule 4: what they are judged against is first, and is not one of them.
        #expect(compare.fill.reference?.description == grooves[0])
        #expect(compare.fill.bound.count == 4, "a reference and three candidates")
        guard case .compare(_, let candidates) = compare.fill else {
            Issue.record("the Compare was not filled as a comparison")
            return
        }
        #expect(candidates.count == 3)
        #expect(!candidates.map(\.description).contains(grooves[0]))
        // Rule 5: two levers, both quantities you can hear change.
        #expect(compare.levers.map(\.quantity) == [.tempo, .dust])

        try await MainActor.run {
            // The bench holds them, bound as asked, with the levers hung on the Compare.
            #expect(rig.app.bench.items.contains { $0.kind == .chopLane })
            let benchCompare = try #require(rig.app.bench.items.first { $0.kind == .compare })
            #expect(rig.app.bound(for: benchCompare.id).count == 4)
            #expect(rig.app.levers(for: benchCompare.id).count == 2)
            // Nothing unperformable got through: the frame's own gate agrees, afterwards.
            for action in turn.actions { #expect(rig.app.canPerform(action)) }
        }

        #expect(turn.say.contains("bar 9"))
        #expect(turn.detail?.contains("turn") == true, "the cost line rides on the answer")
        #expect(turn.spend.turnCount == 11, "one ledger entry per request")
    }

    @Test("A proposal the Director offers is performable, and replaces the derived ones")
    func proposalsLandInTheRail() async throws {
        let feels = DirectorTurnFixture.feels()
        let path = SendableBox<String>("")
        let workspace = SendableBox<AppStateWorkspace?>(nil)

        var replies: [@Sendable () async -> String] = []
        replies.append({ DirectorTurnFixture.call("t1", "import_record", #"{"path":"\#(path.value)"}"#) })
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t2", "analyse_record", #"{"audio":"audio-1"}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t3", "chop_bar",
                                     #"{"audio":"audio-1","bar":8,"start_seconds":null,"end_seconds":null,"method":"onsets","division":4}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t4", "classify_slices", #"{"chop":"chop-1","overrides":null}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t5", "regroove_chop",
                                     #"{"chop":"chop-1","feel":"\#(feels[0])","tempo":90,"bars":1,"overlap":null,"rotate":null}"#)))
        replies.append(DirectorLateTransport.fixed(
            DirectorTurnFixture.call("t6", "create_part_version",
                                     #"{"from":"groove-1","note":"Bar 9 on \#(feels[0])","persona":null,"parent":null}"#)))
        replies.append({
            let grooves = await DirectorTurnFixture.versions(workspace.value, ofType: .groove)
            return DirectorTurnFixture.call(
                "t7", "propose",
                #"{"surface":"Grid","title":"Open bar 9 in the Grid","bound":["\#(grooves[0])"],"reference":null,"finding":null,"because":"Eight slices on a pocket, at 90.","levers":[{"quantity":"swing","label":"Swing","value":58}],"persona":null}"#)
        })
        replies.append(DirectorLateTransport.fixed(
            DirectorSSE.reply("There it is. Open it when you want it.")))

        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        path.value = rig.recordURL.path
        workspace.value = rig.workspace

        let turn = await rig.director.direct("give me bar 9 on a pocket")

        #expect(turn.ending == .answered)
        #expect(turn.opened.isEmpty, "a proposal is offered, not opened")
        #expect(turn.proposals.count == 1)

        try await MainActor.run {
            #expect(rig.app.bench.items.allSatisfy { $0.kind != .grid })
            let offered = try #require(rig.app.proposals.first)
            #expect(offered.source == .director)
            #expect(offered.title == "Open bar 9 in the Grid")
            #expect(rig.app.canPerform(offered.action))
            // And it works when pressed, which is the only promise the list makes.
            let id = try #require(rig.app.perform(offered.action))
            #expect(rig.app.bench.items.first { $0.id == id }?.kind == .grid)
            #expect(rig.app.levers(for: id).map(\.quantity) == [.swing])
        }
    }

    @Test("A choice the frame could not carry out comes back as a tool error, not a wrong panel")
    func anImpossibleChoiceIsAnError() async throws {
        let replies: [@Sendable () async -> String] = [
            DirectorLateTransport.fixed(DirectorTurnFixture.call(
                "t1", "open_surface",
                #"{"surface":"Grid","title":"Nowhere","bound":["\#(UUID().uuidString)"],"reference":null,"finding":null,"because":"a guess","levers":null}"#)),
            DirectorLateTransport.fixed(
                DirectorSSE.reply("That version is not in this song; I will read it first.")),
        ]
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }

        let turn = await rig.director.direct("open something that is not there")

        #expect(turn.ending == .answered)
        #expect(turn.opened.isEmpty, "nothing was opened")
        await MainActor.run { #expect(rig.app.bench.items.allSatisfy { $0.kind != .grid }) }

        // The refusal went back to the model as a tool result it could act on, in the next request.
        let text = try await rig.transport.request(1).bodyJSON().jsonText
        #expect(text.contains("holds no version"))
        #expect(text.contains("is_error"))
    }
}
