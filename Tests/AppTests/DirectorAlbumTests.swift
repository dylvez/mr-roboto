import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M7 L5, scripted: "put the record in order" and "release it".

@MainActor
private enum RecordFixture {
    /// Three saved songs on one album, in an order the Peer will want changed: the opener's
    /// hook comes at 41 seconds; Fluorescent's would come at 27.
    static func album(in app: AppState) -> AlbumID {
        var ids: [SongID] = []
        for (title, key, tempo) in [("Arrival", Key(tonic: NoteName(.d)), 92.0), ("Exit Interview", Key(tonic: NoteName(.b), mode: .aeolian), 96.0),
                                    ("Fluorescent", Key(tonic: NoteName(.g)), 140.0)] {
            var song = FormFixture.build(tempo: tempo).song
            song.title = title
            song.key = key
            let stitch = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
            song.sections = [Section(name: "Verse", stitch: stitch, lengthInBars: 16), Section(name: "Hook", stitch: stitch, lengthInBars: 4)]
            app.open(song)
            app.save()
            ids.append(song.id)
        }
        let album = app.createAlbum(title: "Soft Machine", artist: "Vessel")!
        for id in ids { app.addSong(id, to: album) }
        return album
    }
}

@Suite("Director: the record, scripted", .serialized)
struct DirectorAlbumProofTests {

    @Test("Put the record in order")
    func theOrderProof() async throws {
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_album", #"{"album":""}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call(
            "t2", "sequence", #"{"album":"Soft Machine","order":["Fluorescent","Arrival","Exit Interview"],"gaps":[],"reason":"the Peer: Fluorescent's hook comes at 27 seconds, Arrival's at 42"}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Fluorescent opens now — its hook comes at 27 seconds, Arrival's came at 42 — then Arrival, then Exit Interview. "
            + "One pair still shares a key, Arrival into Exit Interview, which the Producer allows once. Three minutes with the gaps: an EP, and it should say so.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        let album = await MainActor.run { RecordFixture.album(in: rig.app) }

        let turn = await rig.director.direct("put the record in order")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_album", "sequence"])
        let reading = try await rig.transport.request(1).bodyJSON().jsonText
        #expect(reading.contains("hook_seconds") && reading.contains("key_distance") && reading.contains("Arrival opens"), "\(reading.prefix(600))")
        try await MainActor.run {
            let record = try #require(rig.app.library.album(album))
            #expect(record.songs.compactMap { rig.app.library.song($0)?.title } == ["Fluorescent", "Arrival", "Exit Interview"])
            #expect(rig.app.log.contains { $0.text.hasPrefix("Sequenced") })
        }
        #expect(turn.say.contains("27 seconds"))
    }

    @Test("Release it")
    func theReleaseProof() async throws {
        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "release", #"{"album":""}"#)))
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Released: three tracks, each at −14 LUFS within a LU, true peaks under −1 dBTP, cover.png and album.json in the folder. "
            + "Three sampled sources are still uncleared.")))
        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        let out = rig.directory.appendingPathComponent("exports", isDirectory: true)
        let album = await MainActor.run { () -> AlbumID in
            rig.app.exportDirectory = out
            return RecordFixture.album(in: rig.app)
        }
        let turn = await rig.director.direct("release it")
        #expect(turn.ending == .answered)
        #expect(turn.calls == ["release"])
        let result = try await rig.transport.request(1).bodyJSON().jsonText
        #expect(result.contains("01 — Arrival.wav") && result.contains("LUFS"), "\(result.prefix(500))")
        let folder = out.appendingPathComponent("Soft Machine", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cover.png").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("album.json").path))
        try await MainActor.run {
            let record = try #require(rig.app.library.album(album))
            #expect(record.releases.count == 3)
        }
    }

    @Test("sequence is refused with the counter when the order breaks a rule, and names the tracks when one is missing")
    func refusals() async throws {
        let workspace = await MainActor.run { () -> DirectorScratchWorkspace in
            var songs: [Song] = []
            for (title, key, tempo) in [("A", Key(tonic: NoteName(.d)), 90.0), ("B", Key(tonic: NoteName(.d)), 92.0), ("C", Key(tonic: NoteName(.b), mode: .aeolian), 94.0)] {
                var song = FormFixture.build(tempo: tempo).song
                song.title = title
                song.key = key
                let stitch = [Guidance.grooves(in: song).last!].lanes
                song.sections = [Section(name: "Verse", stitch: stitch, lengthInBars: 4), Section(name: "Hook", stitch: stitch, lengthInBars: 4)]
                songs.append(song)
            }
            let album = Album(title: "Three in D", artist: "Vessel", songs: songs.map(\.id))
            return DirectorScratchWorkspace(song: nil, library: Library(songs: songs, albums: [album]))
        }
        let box = await MainActor.run { DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace) }
        // A, B and C in a row: two pairs of neighbours share a signature.
        let twoPairs = await box.run(ClaudeToolUse(id: "s", name: "sequence", input: .object([
            .init("album", .string("Three in D")), .init("order", .array([.string("A"), .string("B"), .string("C")])), .init("gaps", .array([])), .init("reason", .string("as they came"))])))
        #expect(twoPairs.isError && twoPairs.content.contains("same-key-neighbours"), "\(twoPairs.content)")
        let missing = await box.run(ClaudeToolUse(id: "m", name: "sequence", input: .object([
            .init("album", .string("Three in D")), .init("order", .array([.string("A"), .string("B")])), .init("gaps", .array([])), .init("reason", .string("x"))])))
        #expect(missing.isError && missing.content.contains("A, B, C"))
        let read = await box.run(ClaudeToolUse(id: "r", name: "read_album", input: .object([.init("album", .string(""))])))
        #expect(!read.isError && read.content.contains("Three in D"), "\(read.content)")
        let released = await box.run(ClaudeToolUse(id: "x", name: "release", input: .object([.init("album", .string(""))])))
        #expect(released.isError)
    }
}
