import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M5 R9, scripted: "how was that take?" → read_take → the two flags said back with their numbers
// and the offer named. The take is in the song's package, read through the real workspace.

@Suite("Director: the take, scripted", .serialized)
struct DirectorTakeProofTests {

    @Test("How was that take?")
    func theTakeProof() async throws {
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_take", #"{"take":""}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Two flags on Take 1 of the verse. Bar 2, +31 cents: the F♯ reads sharp of the note in D major — the Engineer offers "
            + "a correction of −31 cents with the formants held, or the retake. Bar 2 came in 60 ms late on the A — the Lyricist "
            + "offers to move it 60 ms earlier, or the retake. Taking either makes a new version with the take underneath; "
            + "nothing has been changed.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }

        try await MainActor.run {
            let app = rig.app
            var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 120)
            song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4)]
            app.open(song)
            app.save()
            let store = try #require(app.store)
            let package = try store.songStore(for: song.id)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sung-\(UUID().uuidString).wav")
            try BoothAdapter.write(SungTake.planar(), sampleRate: SungTake.rate, to: scratch)
            let media = try package.addMedia(copying: scratch)
            let audio = Audio(media: media, role: .take, sampleRate: SungTake.rate, channelCount: 1, duration: 2.2, alignmentOffset: SungTake.alignment,
                              take: Take(section: song.sections[0].id, startBar: 1, input: "MacBook Pro Microphone", pass: 1))
            #expect(app.record(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1, Verse")))
        }

        let turn = await rig.director.direct("how was that take?")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_take"])
        let result = try await rig.transport.request(1).bodyJSON().jsonText
        #expect(result.contains("Bar 2, +3") && result.contains("cents"), "\(result.prefix(400))")
        #expect(result.contains("ms late") && result.contains("Correct it by"))
        #expect(result.contains("Retake bar 2"))
        #expect(turn.say.contains("cents") && turn.say.contains("ms"))
        try await MainActor.run {
            // Nothing was changed: one version, the take, and no Check opened by the tool.
            let song = try #require(rig.app.song)
            #expect(song.versions.count == 1)
            #expect(rig.app.bench.items.allSatisfy { $0.kind != .check })
        }
    }
}
