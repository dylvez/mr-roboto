import AppKit
import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M7 Gate A: the album grown, read, drawn and released.

@MainActor
private enum AlbumFixture {
    /// Three saved songs: D major 92 with a mix at −6, B minor 96 at unity, G major 140 at +6.
    static func app(in directory: URL) -> (AppState, AlbumID) {
        let store = LibraryStore(directoryURL: directory)
        let app = AppState(library: Library(), song: nil, store: store, status: .empty(directory), transportHost: StubTransportHost())
        var ids: [SongID] = []
        for (title, key, tempo, gain) in [("Arrival", Key(tonic: NoteName(.d)), 92.0, -6.0), ("Exit Interview", Key(tonic: NoteName(.b), mode: .aeolian), 96.0, 0.0),
                                          ("Fluorescent", Key(tonic: NoteName(.g)), 140.0, 6.0)] {
            var song = FormFixture.build(tempo: tempo).song
            song.title = title
            song.key = key
            let stitch = [Guidance.grooves(in: song).last!.id, Guidance.basslines(in: song).last!.id]
            song.sections = [Section(name: "Verse", stitch: stitch, lengthInBars: 4), Section(name: "Hook", stitch: stitch, lengthInBars: 2)]
            var mix = Mix()
            mix.master = Master(gainDB: gain, ceilingDBTP: -1, targetLUFS: -14)
            try? song.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: String(format: "master %+.1f dB", gain)))
            app.open(song)
            app.save()
            ids.append(song.id)
        }
        let album = app.createAlbum(title: "Soft Machine", artist: "Vessel")!
        for id in ids { app.addSong(id, to: album) }
        return (app, album)
    }
}

@Suite("Album: grown, read and released", .serialized) @MainActor
struct AlbumTests {

    @Test("gaps, notes, a cover and releases round-trip through the library")
    func roundTrip() throws {
        let song = SongID(), other = SongID()
        var album = Album(title: "Soft Machine", artist: "Vessel", songs: [song, other])
        album.gaps[other] = 3.5
        album.notes = "Rooms and windows."
        album.cover = .drawn(CoverDesign(layout: .stack, paper: "#eef0f3", ink: "#0043ce"))
        album.releases[song] = TrackRelease(mixVersion: nil, integratedLUFS: -14.2, truePeakDBTP: -1.1, durationSeconds: 61, trimDB: 3.2)
        let data = try SongGraphCodec.makeEncoder().encode(Library(albums: [album]))
        let back = try SongGraphCodec.makeDecoder().decode(Library.self, from: data)
        let decoded = try #require(back.albums.first)
        #expect(decoded.gap(before: other) == 3.5 && decoded.gap(before: song) == Album.defaultGap)
        #expect(decoded.notes == "Rooms and windows." && decoded.cover.design?.layout == .stack)
        #expect(decoded.releases[song]?.trimDB == 3.2)
        // An album written before M7 — no gaps, notes, cover or releases in its JSON — still reads.
        var object = try #require(JSONSerialization.jsonObject(with: SongGraphCodec.makeEncoder().encode(Album(title: "Old"))) as? [String: Any])
        for key in ["gaps", "notes", "cover", "releases"] { object[key] = nil }
        let legacy = try SongGraphCodec.makeDecoder().decode(Album.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.gaps.isEmpty && legacy.cover.design?.layout == .band && legacy.title == "Old")
    }

    @Test("the record is read: keys on the circle, tempo ratios, running time, the opener's hook; the Producer and the Peer speak")
    func observation() throws {
        let directory = LibraryFixture.directory("album-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, id) = AlbumFixture.app(in: directory)
        let album = try #require(app.library.album(id))
        let observation = app.observe(album: album)
        #expect(observation.tracks.map(\.title) == ["Arrival", "Exit Interview", "Fluorescent"])
        #expect(observation.neighbours.count == 2)
        #expect(observation.neighbours[0].keyDistance == 0, "D major and B minor share a signature")
        #expect(observation.neighbours[1].keyDistance == 1, "B minor to G major is one step")
        #expect(abs(observation.neighbours[1].tempoRatio - 140.0 / 96.0) < 0.001 && observation.tempoJumps == 1)
        #expect(observation.sameKeyPairs == 1)
        let seconds = observation.tracks.map(\.seconds).reduce(0, +)
        #expect(abs(observation.runningSeconds - (seconds + 4)) < 1e-9, "two gaps of two seconds")
        #expect(observation.openerHookSeconds.map { abs($0 - 4 * 4 * 60 / 92) < 0.01 } == true, "the hook is bar 5 of Arrival at 92")
        let producer = Producer().read(observation)
        #expect(producer.first { $0.rule == "producer.album-length" }?.holds == false, "a minute is an EP")
        #expect(producer.first { $0.rule == "producer.same-key-neighbours" }?.holds == true)
        let peer = Peer().read(observation)
        #expect(peer.first { $0.rule == "peer.opener-hooks-early" }?.holds == true)
        #expect(peer.first { $0.rule == "peer.tempo-arc" }?.holds == true && peer.first { $0.rule == "peer.tempo-arc" }?.says.contains("One is a turn") == true)
        #expect(observation.palette.contains { $0.entry.hasPrefix("bass ·") && $0.tracks.count == 3 })
        // The Producer's and the Peer's verdicts on an order.
        #expect(Producer().consider(.sequence(minutes: 38, loudnessSpreadLU: 5, sameKeyPairs: 0, tempoJumps: 0, openerHookSeconds: 20)).refusedByRule == "producer.loudness-spread")
        #expect(Peer().consider(.sequence(minutes: 38, loudnessSpreadLU: 1, sameKeyPairs: 0, tempoJumps: 3, openerHookSeconds: 20)).refusedByRule == "peer.tempo-arc")
        #expect(Beatmaker().consider(.sequence(minutes: 38, loudnessSpreadLU: 1, sameKeyPairs: 0, tempoJumps: 0, openerHookSeconds: 20)).spoken.contains("Producer"))
        #expect(app.sequence([album.songs[2], album.songs[0], album.songs[1]], gaps: [album.songs[0]: 3], in: id, because: "the fast one first"))
        let resequenced = try #require(app.library.album(id))
        #expect(resequenced.songs.first == album.songs[2] && resequenced.gap(before: album.songs[0]) == 3)
        #expect(!app.sequence([album.songs[0]], in: id))
    }

    @Test("the release: three tracks within a LU of the target and of each other, under the ceiling, with a cover and a report")
    func release() async throws {
        let directory = LibraryFixture.directory("album-release")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (app, id) = AlbumFixture.app(in: directory)
        app.setGap(3, before: app.library.album(id)!.songs[1], in: id)
        let out = directory.appendingPathComponent("release", isDirectory: true)
        let result = try await Export.release(app, album: id, to: out)
        #expect(result.report.tracks.count == 3)
        for track in result.report.tracks {
            #expect(abs(track.integratedLUFS - -14) <= 1.0, "\(track.title) at \(track.integratedLUFS)")
            #expect(track.truePeakDBTP <= -1.0, "\(track.title) peaks at \(track.truePeakDBTP)")
            #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(track.file).path), "\(track.file)")
        }
        let levels = result.report.tracks.map(\.integratedLUFS)
        #expect(levels.max()! - levels.min()! <= 1.0, "\(levels)")
        #expect(result.report.tracks[0].trimDB > 3 && result.report.tracks[2].trimDB < result.report.tracks[0].trimDB, "the quiet one came up more")
        #expect(result.report.tracks.map(\.gapBefore) == [0, 3, 2])
        #expect(result.report.tracks[0].file == "01 — Arrival.wav")
        let cover = out.appendingPathComponent("cover.png")
        let image = try #require(NSImage(contentsOf: cover))
        let representation = try #require(image.representations.first)
        let wide = representation.pixelsWide, high = representation.pixelsHigh
        #expect(wide == 3_000 && high == 3_000, "\(wide) × \(high)")
        let report = try JSONDecoder().decode(Export.AlbumReport.self, from: Data(contentsOf: out.appendingPathComponent("album.json")))
        #expect(report.album == "Soft Machine" && report.runningSeconds > 0)
        let album = try #require(app.library.album(id))
        #expect(album.releases.count == 3)
        let reread = app.observe(album: album)
        #expect(reread.loudnessSpreadLU <= 1.0)
        #expect(Producer().read(reread).first { $0.rule == "producer.loudness-spread" }?.holds == true)
    }

    @Test("every cover layout renders to a square PNG")
    func covers() {
        for layout in CoverDesign.Layout.allCases {
            let png = CoverRenderer.png(CoverDesign(layout: layout), title: "Soft Machine", artist: "Vessel", pixels: 600)
            #expect(png != nil && (png?.count ?? 0) > 1_000, "\(layout)")
        }
    }
}
