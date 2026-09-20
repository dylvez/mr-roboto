import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate C, P12: the Director convenes the room. The cast tool reads and sets who is in it; convene
// puts a question to everyone in it, their readings reach the rail in their names, and a
// disagreement opens as a Compare. Then the scripted proof: "is this verse working?".

private func json(_ result: ClaudeToolResult) -> [String: Any] {
    guard let data = result.content.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

@MainActor
private enum RoomFixture {
    /// Arrival at 92 with a groove and a Palladino line, arranged verse 16 | hook 8 — so the hook
    /// arrives at 41 seconds, which is where the Peer starts.
    static func song() -> Song {
        // Two parts only, so the Producer has nothing to subtract: the groove and the line.
        let built = FormFixture.build(tempo: 92)
        var song = Song(title: "Arrival", artist: "Vessel", tempo: 92)
        let groove = built.song.version(built.groove)!
        let bass = built.song.version(built.bass)!
        try! song.append(PartVersion(partID: groove.partID, kind: groove.kind, author: groove.author, operation: Operation.written, note: groove.note))
        try! song.append(PartVersion(partID: bass.partID, kind: bass.kind, author: bass.author, operation: Operation.written, note: bass.note))
        let ids = song.versions.map(\.id)
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 16),
                         Section(name: "Hook", stitch: ids, lengthInBars: 8)]
        return song
    }
}

@Suite("Director: cast and convene", .serialized) @MainActor
struct DirectorCastToolTests {

    private func toolbox(_ workspace: DirectorScratchWorkspace) -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace)
    }

    @Test("cast reads the room, and add and remove change the song's list")
    func castTool() async throws {
        let workspace = DirectorScratchWorkspace(song: RoomFixture.song())
        let box = toolbox(workspace)
        let read = await box.run(ClaudeToolUse(id: "c1", name: "cast", input: .object([.init("action", .string("read")), .init("persona", .string(""))])))
        let roster = try #require(json(read)["cast"] as? [[String: Any]])
        #expect(roster.count == 9 && roster.allSatisfy { $0["in_room"] as? Bool == true })
        #expect(roster.map { $0["id"] as? String } == Cast.standard.ids.map(\.rawValue))

        let out = await box.run(ClaudeToolUse(id: "c2", name: "cast", input: .object([.init("action", .string("remove")), .init("persona", .string("bassist"))])))
        #expect((json(out)["detail"] as? String)?.contains("Bassist is out") == true)
        #expect(workspace.castIDs == Cast.standard.ids.filter { $0 != .bassist })
        let back = await box.run(ClaudeToolUse(id: "c3", name: "cast", input: .object([.init("action", .string("add")), .init("persona", .string("bassist"))])))
        #expect((json(back)["detail"] as? String)?.contains("Bassist is in") == true)
        #expect(workspace.castIDs.isEmpty, "everyone back in is the empty list")

        let bad = await box.run(ClaudeToolUse(id: "c4", name: "cast", input: .object([.init("action", .string("add")), .init("persona", .string("drummer"))])))
        #expect(bad.isError)
    }

    @Test("convene reads the song in every persona's units and the lines reach the rail in their names")
    func conveneTool() async throws {
        let workspace = DirectorScratchWorkspace(song: RoomFixture.song())
        let box = toolbox(workspace)
        let result = await box.run(ClaudeToolUse(id: "v1", name: "convene", input: .object([.init("question", .string("is this verse working?")), .init("section", .string("Verse")), .init("personas", .array([]))])))
        #expect(!result.isError, "\(result.content)")
        let json = json(result)
        let readings = try #require(json["readings"] as? [[String: Any]])
        let by = Dictionary(grouping: readings, by: { $0["persona"] as? String ?? "" })
        #expect(by["producer"]?.isEmpty == false && by["peer"]?.isEmpty == false && by["beatmaker"]?.isEmpty == false && by["bassist"]?.isEmpty == false)
        let hook = try #require(by["peer"]?.first { $0["rule"] as? String == "peer.hook-inside-thirty" })
        #expect(hook["holds"] as? Bool == false && (hook["value"] as? Double ?? 0) > 40, "the hook arrives at bar 16 of 92 bpm")
        #expect(hook["unit"] as? String == "seconds")
        // The rail: every persona that read spoke, in its own name.
        let speakers = Set(workspace.spoken.map(\.persona))
        #expect(speakers.isSuperset(of: ["Producer", "Peer", "Beatmaker", "Bassist"]), "\(speakers)")
        #expect(workspace.spoken.contains { $0.persona == "Peer" && $0.detail == "peer.hook-inside-thirty" })
        // No lyric and nothing to bounce, said rather than skipped silently.
        let detail = json["detail"] as? String ?? ""
        #expect(detail.contains("No lyric") && detail.contains("Nothing to bounce"), "\(detail)")
    }

    @Test("convene with the room cut down consults only who is in it")
    func conveneRespectsTheRoom() async throws {
        let workspace = DirectorScratchWorkspace(song: RoomFixture.song())
        workspace.setCast([.peer])
        let result = await box(workspace).run(ClaudeToolUse(id: "v2", name: "convene", input: .object([.init("question", .string("does the hook land?")), .init("section", .string("")), .init("personas", .array([]))])))
        let json = json(result)
        #expect((json["room"] as? [String]) == ["peer"])
        #expect((json["readings"] as? [[String: Any]])?.allSatisfy { $0["persona"] as? String == "peer" } == true)
    }

    @Test("asked of two: only they read and speak, the rail says who was asked, and a member left out still guards")
    func conveneAsksOnlyThoseNamed() async throws {
        let workspace = DirectorScratchWorkspace(song: RoomFixture.song())
        let result = await box(workspace).run(ClaudeToolUse(id: "v3", name: "convene", input: .object([
            .init("question", .string("quantise it hard")), .init("section", .string("")),
            .init("personas", .array([.string("peer"), .string("Producer")]))])))
        #expect(!result.isError, "\(result.content)")
        let json = json(result)
        #expect((json["asked"] as? [String]) == ["producer", "peer"], "in the room's order, whatever the case")
        #expect((json["not_asked"] as? [String])?.contains("beatmaker") == true && (json["room"] as? [String])?.count == 9)
        let readers = Set((json["readings"] as? [[String: Any]] ?? []).compactMap { $0["persona"] as? String })
        #expect(readers.isSubset(of: ["producer", "peer"]) && !readers.isEmpty, "\(readers)")
        // The rail: who was asked, and nobody else's opinion.
        #expect(workspace.spoken.contains { $0.persona == "Band" && $0.text == "Asked: Producer, Peer." && $0.detail == "7 in the room not consulted" })
        // Guards stay on: the Beatmaker was not asked, and still refuses a hard quantise, marked as a guard.
        let verdicts = try #require(json["verdicts"] as? [[String: Any]])
        let beatmaker = try #require(verdicts.first { $0["persona"] as? String == "beatmaker" }, "\(verdicts)")
        #expect(beatmaker["is_guard"] as? Bool == true && (beatmaker["verdict"] as? String)?.lowercased().contains("refus") == true, "\(beatmaker)")
        #expect(workspace.spoken.contains { $0.persona == "Beatmaker" && $0.detail?.hasPrefix("guard — not asked") == true })
        #expect(verdicts.allSatisfy { ($0["is_guard"] as? Bool == true) || ["producer", "peer"].contains($0["persona"] as? String ?? "") })
        #expect((json["detail"] as? String)?.contains("Asked producer, peer of 9") == true)

        // Someone named who is not in the room is said, and nobody asked at all is refused with who is.
        workspace.setCast([.peer, .producer])
        let absent = await box(workspace).run(ClaudeToolUse(id: "v4", name: "convene", input: .object([
            .init("question", .string("does the hook land?")), .init("section", .string("")), .init("personas", .array([.string("peer"), .string("engineer")]))])))
        let absentDetail = DirectorCastToolTests.detail(of: absent)
        #expect(absentDetail.contains("Engineer is not in the room"), "\(absentDetail)")
        let nobody = await box(workspace).run(ClaudeToolUse(id: "v5", name: "convene", input: .object([
            .init("question", .string("how loud?")), .init("section", .string("")), .init("personas", .array([.string("engineer")]))])))
        #expect(nobody.isError && nobody.content.contains("in the room"))
    }

    @Test("who a message is for: chips, names typed with an at sign, only members in the room, and everyone is nobody")
    func addressees() {
        let room: [(id: PersonaID, name: String)] = [(.beatmaker, "Beatmaker"), (.bassist, "Bassist"), (.engineer, "Engineer")]
        #expect(DirectorSession.addressees(in: "how is the low end?", chips: [], room: room).isEmpty)
        #expect(DirectorSession.addressees(in: "how is the low end?", chips: [.engineer], room: room) == [.engineer])
        #expect(DirectorSession.addressees(in: "@eng and @Bassist, how is the low end?", chips: [], room: room) == [.bassist, .engineer])
        #expect(DirectorSession.addressees(in: "@producer what do you think", chips: [], room: room).isEmpty, "not in the room")
        #expect(DirectorSession.addressees(in: "mail me @ 5", chips: [], room: room).isEmpty)
        #expect(DirectorSession.addressees(in: "all of you", chips: [.beatmaker, .bassist, .engineer], room: room).isEmpty, "everyone is the same as nobody chosen")
        #expect(DirectorSession.addressedText("how loud?", to: [.engineer, .bassist]) == "how loud?\n\nAsked of: engineer, bassist")
        #expect(DirectorSession.addressedText("how loud?", to: []) == "how loud?")
    }

    private func box(_ workspace: DirectorScratchWorkspace) -> DirectorToolbox { toolbox(workspace) }

    /// The detail line, read without the local `json` a test may have shadowed the helper with.
    static func detail(of result: ClaudeToolResult) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any]
        return object?["detail"] as? String ?? ""
    }

    @Test("a disagreement on a proposal opens as a Compare of the two verdicts")
    func disagreementOnAProposal() {
        // The Sampler agrees to an SP-1200 pass; the Engineer's declared disagreement with it is on
        // the chain's bandwidth. Two verdicts of different shapes make a card.
        let room = Cast([Sampler(), Engineer()])
        let proposal = PersonaProposal.applyDegrade(preset: "sp1200", sourceBandwidthHz: 20_000, sourceNoiseFloorDB: -80)
        let answered = room.ask(proposal).filter { if case .defer_ = $0.verdict { return false }; return true }.map { ($0.persona, $0.verdict) }
        #expect(answered.count == 1, "only the Sampler answers a chain proposal; one answer is not a disagreement")
        #expect(ConveneTool.disagreement(among: answered, proposal: proposal, readings: [], room: room, song: RoomFixture.song(), section: nil) == nil)

        // On readings: the Engineer's delivery loudness failing while the Producer's part count holds.
        let engineer = PersonaReading(rule: "engineer.delivery-loudness", feature: .integratedLUFS, value: -21, holds: false, says: "−21 LUFS. 7 LU under.")
        let producer = PersonaReading(rule: "producer.fewer-parts", feature: .partsPerSong, value: 2, holds: true, says: "Two parts.")
        let readings: [(PersonaID, PersonaReading)] = [(PersonaID.engineer, engineer), (PersonaID.producer, producer)]
        let card = ConveneTool.disagreement(among: [], proposal: .outOfScope(what: "x"), readings: readings,
                                            room: Cast([Producer(), Engineer()]), song: RoomFixture.song(), section: nil)
        guard let opened = card else { Issue.record("no card"); return }
        let between: [PersonaID] = [.engineer, .producer]
        #expect(opened.between == between)
        #expect(opened.about == "whether loudness is a decision or a delivery spec")
        let brief = opened.brief
        #expect(brief.candidates.count == 2)
        #expect(brief.candidates[0].rationale == engineer.says)
        #expect(brief.reference.kind.hasPrefix("settled by:"))
        let features: [Feature] = [.integratedLUFS, .partsPerSong]
        #expect(brief.features == features.sorted { $0.rawValue < $1.rawValue })
    }
}

@Suite("Director: the room, scripted", .serialized)
struct DirectorConveneProofTests {

    @Test("Is this verse working?")
    func theRoomProof() async throws {
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "convene", #"{"question":"is this verse working?","section":"Verse","personas":[]}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Three of them read it. The Peer: the hook arrives at 41 seconds, past the 30 a listener waits. The Producer: two parts, "
            + "nothing orphaned, the song is holding. The Engineer: the verse bounces well under −14 LUFS, peak under the ceiling. "
            + "The Engineer and the Producer disagree on whether loudness is a decision now or a delivery spec later — a Compare of "
            + "the two readings is open; the Engineer reads every bounce, the Producer decides at the last one.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }

        try await MainActor.run {
            let app = rig.app
            app.open(RoomFixture.song())
            #expect(app.setCast([.producer, .engineer, .peer]))
            #expect(app.playback.isArranged && app.playback.isPlayable)
        }

        let turn = await rig.director.direct("is this verse working?")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["convene"])

        let result = try await rig.transport.request(1).bodyJSON().jsonText
        try result.write(toFile: NSTemporaryDirectory() + "convene-proof.json", atomically: true, encoding: .utf8)
        let head = String(result.prefix(600))
        #expect(result.contains("peer.hook-inside-thirty"), "\(head)")
        #expect(result.contains("producer.fewer-parts"), "\(head)")
        #expect(result.contains("engineer.delivery-loudness"), "\(head)")
        #expect(result.contains("LUFS") && result.contains("dBFS"))

        try await MainActor.run {
            let app = rig.app
            let speakers = app.log.compactMap { entry -> String? in if case .persona(let name) = entry.source { return name }; return nil }
            #expect(Set(speakers).isSuperset(of: ["Peer", "Producer", "Engineer"]), "\(speakers)")
            #expect(!speakers.contains("Beatmaker"), "the Beatmaker is out of the room")
            // One Compare, the two readings that disagree, with what settles it at the top.
            let compares = app.bench.items.filter { $0.kind == .compare }
            #expect(compares.count == 1, "\(app.bench.items.map(\.title))")
            let item = try #require(compares.first)
            guard case .compare(let brief)? = app.answer(for: item.id) else { Issue.record("no brief filed"); return }
            #expect(brief.candidates.count == 2)
            #expect(brief.candidates.map(\.proposedBy).contains(.engineer))
            #expect(brief.reference.kind.hasPrefix("settled by:"))
            #expect(turn.say.contains("disagree"))
        }
    }
}
