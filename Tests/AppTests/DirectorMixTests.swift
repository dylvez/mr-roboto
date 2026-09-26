import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M6 X8, scripted: "the bass is fighting the kick" and "master it". read_mix bounces the song
// through the mix for real; set_mix and master are checked by the Engineer and become versions.

private enum MixProofFixture {
    /// Arrival with a groove and a line, a verse, and no mix yet. The fixture's every-kind
    /// song carries one mix version; the count of mixes before is what the proofs compare to.
    @MainActor
    @discardableResult
    static func arrange(_ app: AppState) -> Int {
        var song = FormFixture.build(tempo: 92).song
        let parts = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: parts, lengthInBars: 2)]
        app.open(song)
        return Guidance.mixes(in: song).count
    }
}

@Suite("Director: the mix, scripted", .serialized)
struct DirectorMixProofTests {

    @Test("The bass is fighting the kick")
    func theMaskingProof() async throws {
        let workspace = SendableBox<AppStateWorkspace?>(nil)
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_mix", #"{"section":""}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call(
            "t2", "set_mix", #"{"part":"Palladino line","gain_db":0,"band_hz":80,"band_db":-3,"reason":"kick and bass within 4 dB at 60–120 Hz; the kick owns it"}"#)))
        replies.append({
            let mixes = await DirectorTurnFixture.versions(workspace.value, ofType: .mix)
            return DirectorTurnFixture.call("t3", "open_surface",
                #"{"surface":"Mixer","title":"Arrival","bound":["\#(mixes.last ?? "")"],"reference":null,"finding":null,"because":"The strips as the move left them.","levers":[]}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Read the verse: the kick owns 60–120 Hz by a few dB and the bass sits under it. One move: Palladino line −3 dB at 80 Hz, "
            + "a mix version you can revert. The Mixer is open on it; read again and the gap should be wider.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        workspace.value = rig.workspace
        let before = await MainActor.run { MixProofFixture.arrange(rig.app) }

        let turn = await rig.director.direct("the bass is fighting the kick")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_mix", "set_mix", "open_surface"])
        let reading = try await rig.transport.request(1).bodyJSON().jsonText
        #expect(reading.contains("integrated_lufs") && reading.contains("true_peak_dbtp") && reading.contains("masking"), "\(reading.prefix(500))")
        #expect(reading.contains("Palladino line") && reading.contains("Boom-bap pocket"))
        try await MainActor.run {
            let song = try #require(rig.app.song)
            let mixes = Guidance.mixes(in: song)
            #expect(mixes.count == before + 1, "\(mixes.map { $0.note ?? "" })")
            #expect(mixes.last?.note?.hasPrefix("Palladino line EQ 80 Hz -3.0 dB (") == true, "\(mixes.last?.note ?? "")")
            let mix = try #require(Guidance.mix(in: song))
            let bass = Guidance.basslines(in: song).last!.partID
            #expect(mix.strip(for: bass)?.eq[1].frequency == 80 && mix.strip(for: bass)?.eq[1].gainDB == -3)
            #expect(rig.app.bench.items.contains { $0.kind == .mixer })
        }
        #expect(turn.say.contains("−3 dB at 80 Hz") || turn.say.contains("-3 dB at 80 Hz"))
    }

    @Test("Master it")
    func theMasterProof() async throws {
        let workspace = SendableBox<AppStateWorkspace?>(nil)
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_mix", #"{"section":""}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call(
            "t2", "master", #"{"target_lufs":-14,"ceiling_dbtp":-1,"gain_db":6,"reason":"read_mix: −20 LUFS against −14, 6 LU under"}"#)))
        replies.append({
            let mixes = await DirectorTurnFixture.versions(workspace.value, ofType: .mix)
            return DirectorTurnFixture.call("t3", "open_surface",
                #"{"surface":"Master","title":"Arrival","bound":["\#(mixes.last ?? "")"],"reference":null,"finding":null,"because":"The readings against the target.","levers":[]}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Master set: target −14 LUFS, ceiling −1 dBTP, the gain up 6 dB by the gap. The Master surface reads the bounce; the ceiling is over every export.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        workspace.value = rig.workspace
        await MainActor.run { MixProofFixture.arrange(rig.app) }

        let turn = await rig.director.direct("master it")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_mix", "master", "open_surface"])
        try await MainActor.run {
            let song = try #require(rig.app.song)
            let mix = try #require(Guidance.mix(in: song))
            #expect(mix.master.targetLUFS == -14 && mix.master.ceilingDBTP == -1 && mix.master.gainDB == 6)
            #expect(Guidance.mixes(in: song).last?.note?.hasPrefix("master +6.0 dB") == true, "\(Guidance.mixes(in: song).last?.note ?? "")")
            // The master is the Mixer's own tab now: asking for the Master opens the Mixer on it.
            #expect(rig.app.bench.items.contains { $0.kind == .mixer })
            #expect(!rig.app.bench.items.contains { $0.kind == .master })
        }
        // The Engineer refuses a ceiling at zero, and the refusal names the counter.
        let box = rig.director
        _ = box
    }

    @Test("set_mix and master are refused by the Engineer with the counter, and a bad strip name lists the strips")
    func refusals() async throws {
        let workspace = await MainActor.run { () -> DirectorScratchWorkspace in
            var song = FormFixture.build(tempo: 92).song
            song.sections = []
            return DirectorScratchWorkspace(song: song)
        }
        let box = await MainActor.run { DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace) }
        let boost = await box.run(ClaudeToolUse(id: "b", name: "set_mix", input: .object([
            .init("part", .string("Boom-bap pocket")), .init("gain_db", .double(0)), .init("band_hz", .double(3_000)), .init("band_db", .double(4)), .init("reason", .string("cut through"))])))
        #expect(boost.isError && boost.content.contains("cut-before-boost"), "\(boost.content)")
        let two = await box.run(ClaudeToolUse(id: "t", name: "set_mix", input: .object([
            .init("part", .string("Palladino line")), .init("gain_db", .double(-3)), .init("band_hz", .double(80)), .init("band_db", .double(-6)), .init("reason", .string("both"))])))
        #expect(two.isError && two.content.contains("one-move-at-a-time"))
        let unknown = await box.run(ClaudeToolUse(id: "u", name: "set_mix", input: .object([
            .init("part", .string("Vocal")), .init("gain_db", .double(-3)), .init("band_hz", .double(0)), .init("band_db", .double(0)), .init("reason", .string("x"))])))
        #expect(unknown.isError && unknown.content.contains("Palladino line"))
        let zero = await box.run(ClaudeToolUse(id: "z", name: "master", input: .object([
            .init("target_lufs", .double(-14)), .init("ceiling_dbtp", .double(0)), .init("gain_db", .double(0)), .init("reason", .string("loud"))])))
        #expect(zero.isError && zero.content.contains("master-ceiling"))
        let ok = await box.run(ClaudeToolUse(id: "k", name: "set_mix", input: .object([
            .init("part", .string("Palladino line")), .init("gain_db", .double(-3)), .init("band_hz", .double(0)), .init("band_db", .double(0)), .init("reason", .string("2 dB under the kick"))])))
        #expect(!ok.isError, "\(ok.content)")
        let mixes = await MainActor.run { Guidance.mixes(in: workspace.song!) }
        #expect(mixes.last?.note == "Palladino line -3.0 dB (2 dB under the kick)", "\(mixes.last?.note ?? "")")
        // With no bounce behind it, read_mix still reads the strips and says there is no reading.
        let read = await box.run(ClaudeToolUse(id: "r", name: "read_mix", input: .object([.init("section", .string(""))])))
        #expect(!read.isError && read.content.contains("no reading") && read.content.contains("\"gain_db\":-3"), "\(read.content)")
    }

    @Test("the master tool sets the ending: a fade over the last bars, kept as a mix version, read back; 0 stops, -1 keeps")
    func ending() async throws {
        let workspace = await MainActor.run { DirectorScratchWorkspace(song: FormFixture.build(tempo: 92).song) }
        let box = await MainActor.run { DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace) }
        func master(_ fade: Int) async -> ClaudeToolResult {
            await box.run(ClaudeToolUse(id: "m\(fade)", name: "master", input: .object([
                .init("target_lufs", .double(-14)), .init("ceiling_dbtp", .double(-1)), .init("gain_db", .double(0)),
                .init("reason", .string("an ending")), .init("fade_out_bars", .int(fade))])))
        }
        let faded = await master(4)
        #expect(!faded.isError && faded.content.contains("fade out over 4 bars"), "\(faded.content)")
        var last = await MainActor.run { Guidance.mixes(in: workspace.song!).last }
        guard case .mix(let mix)? = last?.kind else { Issue.record("no mix"); return }
        #expect(mix.master.fadeOutBars == 4)
        let read = await box.run(ClaudeToolUse(id: "r", name: "read_mix", input: .object([.init("section", .string(""))])))
        #expect(read.content.contains("\"fade_out_bars\":4"), "\(read.content)")
        _ = await master(-1)
        last = await MainActor.run { Guidance.mixes(in: workspace.song!).last }
        guard case .mix(let kept)? = last?.kind else { Issue.record("no mix"); return }
        #expect(kept.master.fadeOutBars == 4, "-1 keeps the ending it has")
        let stopped = await master(0)
        #expect(stopped.content.contains("no fade"), "\(stopped.content)")
    }
}
