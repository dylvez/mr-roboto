import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M2's proof, scripted: "give me a bass line under this, laid back like Pino" becomes three
// write_bassline calls and one Compare with the groove as the reference — with the same rig and
// the same late-written replies as the first proof, and no network.

@Suite("Director: the M2 proof", .serialized)
struct DirectorBassProofTests {

    @Test("Give me a bass line under this, laid back like Pino")
    func theBassProof() async throws {
        let workspace = SendableBox<AppStateWorkspace?>(nil)

        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_song", "{}")))
        // Three lines under the groove: Pino's default, further back, and a busier one.
        replies.append({
            let grooves = await DirectorTurnFixture.versions(workspace.value, ofType: .groove)
            return DirectorTurnFixture.calls([
                ("t2", "write_bassline", #"{"groove":"\#(grooves[0])","hands":"palladino","lag_ms":40,"density":0.4,"seed":1}"#),
                ("t3", "write_bassline", #"{"groove":"\#(grooves[0])","hands":"palladino","lag_ms":60,"density":0.4,"seed":2}"#),
                ("t4", "write_bassline", #"{"groove":"\#(grooves[0])","hands":"palladino","lag_ms":40,"density":0.8,"seed":3}"#),
            ])
        })
        // One asked for ahead of the kick, refused by the Bassist — and the model moves on rather
        // than writing it another way.
        replies.append({
            let grooves = await DirectorTurnFixture.versions(workspace.value, ofType: .groove)
            return DirectorTurnFixture.call(
                "t5", "write_bassline",
                #"{"groove":"\#(grooves[0])","hands":"palladino","lag_ms":-30,"density":0.4,"seed":4}"#)
        })
        replies.append({
            let grooves = await DirectorTurnFixture.versions(workspace.value, ofType: .groove)
            let lines = await DirectorTurnFixture.versions(workspace.value, ofType: .bassline)
            return DirectorTurnFixture.call(
                "t6", "open_surface",
                #"{"surface":"Compare","title":"Three lines under the pocket","bound":["\#(lines[0])","\#(lines[1])","\#(lines[2])"],"reference":"\#(grooves[0])","finding":null,"because":"Each sits behind the kick by a stated amount; the groove is what they sit under.","levers":[{"quantity":"lag","label":"Behind the kick","value":40}]}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Three lines in Pino's hands: 40 ms behind the kick, 60 behind, and a busier one at 40, "
            + "note-offs on the beat. The Bassist refused a fourth ahead of the kick — bass-before-drums "
            + "is the order listeners rated worst. The Compare is open against the groove.")))

        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        workspace.value = rig.workspace

        // The song holds a groove to sit under: the boom-bap pocket at its own tempo.
        try await MainActor.run {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            let groove = PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                     operation: Operation.written, note: "Boom-Bap Pocket")
            #expect(rig.app.record(groove))
        }

        let turn = await rig.director.direct("Give me a bass line under this, laid back like Pino")

        #expect(turn.ending == .answered)
        #expect(turn.calls.first == "read_song")
        #expect(turn.calls.filter { $0 == "write_bassline" }.count == 4, "three written, one refused")
        #expect(turn.calls.last == "open_surface")

        // Three lines landed, all the Bassist's, all under the groove.
        let grooves = await DirectorTurnFixture.versions(rig.workspace, ofType: .groove)
        let lines = try await MainActor.run { try #require(rig.app.song?.versions.filter { $0.type == .bassline }) }
        #expect(lines.count == 3, "the refused one was not written")
        for line in lines {
            #expect(line.author == .persona("Bassist"))
            #expect(line.parents.map(\.description) == [grooves[0]])
        }
        // The second sits further back than the first, as asked.
        let song = try await MainActor.run { try #require(rig.app.song) }
        let observed = lines.map { version -> Double in
            guard case .bassline(let line) = version.kind, case .groove(let groove) = song.version(VersionID(uuidString: grooves[0])!)!.kind else { return 0 }
            return BassObservation(label: "", bassline: line, groove: groove, chords: [], tempo: song.tempo).medianKickOffsetMS
        }
        // Three calls in one round run in parallel, so their order in the graph is not the script's.
        #expect(Set(observed.map { $0.rounded() }) == [40, 60], "\(observed)")

        // The refusal reached the model with the Bassist's reason.
        let refusal = try await rig.transport.request(3).bodyJSON().jsonText
        #expect(refusal.contains("rated worst"))
        #expect(refusal.contains("Nothing was written"))

        // One Compare: the groove at the top, three lines under it, a lag lever.
        if turn.opened.isEmpty {
            let last = try await rig.transport.request(4).bodyJSON().jsonText
            Issue.record("open_surface opened nothing; the model was told: \(last.suffix(600))")
        }
        #expect(turn.opened.count == 1)
        let compare = try #require(turn.opened.first)
        #expect(compare.surface == .compare)
        #expect(compare.fill.reference?.description == grooves[0])
        #expect(compare.fill.bound.count == 4)
        #expect(compare.levers.map(\.quantity) == [.lag])
        try await MainActor.run {
            let item = try #require(rig.app.bench.items.first { $0.kind == .compare })
            let brief = try #require(CompareBriefing.brief(for: item, app: rig.app))
            #expect(brief.features == CompareBriefing.bassFeatures, "the columns are the Bassist's")
            #expect(brief.candidates.allSatisfy { $0.proposedBy == .bassist })
            #expect(brief.reference.readings.isEmpty, "the groove has no numbers in the bass columns")
            #expect(brief.levers == [.lag])
            for action in turn.actions { #expect(rig.app.canPerform(action)) }
        }
        #expect(turn.say.contains("40 ms behind the kick"))
        #expect(turn.say.contains("rated worst"))
    }
}
