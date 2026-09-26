import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// An audit of the record as a whole — albums, releases, exports, merges, mashups. Each test is one
// of what it found, fixed.

@Suite("The record as a whole, audited", .serialized) @MainActor
struct AlbumAuditTests {

    @Test("a release again into the same folder clears the tracks the last one wrote, and nothing else")
    func releaseClearsTheLastOne() throws {
        let directory = LibraryFixture.directory("audit-release-clear")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = Export.AlbumReport(album: "Glass", artist: "Vessel", targetLUFS: -14, ceilingDBTP: -1, runningSeconds: 60,
                                        tracks: [.init(number: 1, title: "Arrival", file: "01 — Arrival.wav", gapBefore: 0,
                                                       durationSeconds: 30, integratedLUFS: -14, truePeakDBTP: -1, trimDB: 0,
                                                       mixVersion: nil, key: nil, tempo: 92)],
                                        clearances: [], notes: "", cover: "cover.png", releasedAt: "", albumID: nil)
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("album.json"))
        for name in ["01 — Arrival.wav", "cover.png", "liner notes.txt"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        Export.clearPreviousRelease(in: directory)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["album.json", "liner notes.txt"], "\(left)")
        #expect(Export.safe("..") == "Untitled" && Export.safe(".") == "Untitled")
    }

    @Test("a release with a track the library does not hold stops, and names the track")
    func missingTrackStops() async throws {
        let directory = LibraryFixture.directory("audit-release-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = LibraryFixture.app(directory)
        let album = Album(title: "Glass", songs: [SongID()])
        #expect(app.writeLibrary(Library(albums: [album])))
        do {
            _ = try await Export.release(app, album: album.id, to: directory.appendingPathComponent("out"))
            Issue.record("released with a missing track")
        } catch let failure as Export.ReleaseFailure {
            #expect("\(failure)".hasPrefix("Track 1 is a song the library does not hold"))
        }
    }

    @Test("a cleared source stays cleared when its record leaves the library")
    func clearanceSurvivesTheRecord() throws {
        let directory = LibraryFixture.directory("audit-clearance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (song, _, _) = try LibraryFixture.songWithChop("Flip", record: record, app: app)
        let album = Album(title: "Glass", songs: [song.id])
        var library = app.library
        library.upsert(album)
        #expect(app.writeLibrary(library))
        let source = try #require(app.sources(of: app.library.album(album.id)!).first)
        #expect(app.setClearance(.cleared, forSource: source.source, record: source.record, in: album.id))

        #expect(app.removeRecord(record.id))
        let after = try #require(app.sources(of: app.library.album(album.id)!).first)
        #expect(after.status == .cleared, "\(after)")
        #expect(after.source == source.source, "still named for the record it came from")
    }

    @Test("a merged chop keeps its pads' trims, each on its slice")
    func mergeKeepsTrims() {
        let sample = Sample(media: ChopLaneFixtures.media,
                            slices: [SliceMarker(position: 1), SliceMarker(position: 2.5), SliceMarker(position: 3)],
                            pads: [PadTrim(slice: 1, tuneCents: 300, reverse: true), PadTrim(slice: 0, gainDB: -6)])
        let pads = MergeAdapter.pads(sample, region: SongGraph.TimeRange(start: 2, end: 4))
        #expect(pads == [PadTrim(slice: 0, tuneCents: 300, reverse: true)], "slice 1 is the first kept; slice 0 fell outside")
    }

    @Test("a 6/8 song's MIDI file counts quarter notes, and reads back as it was written")
    func midiInEighths() throws {
        let file = MIDIFile(ticksPerBeat: 480, tempo: 120, beatsPerBar: 6, beatUnit: 8,
                            tracks: [.init(name: "Bass", notes: [.init(channel: 0, pitch: 40, velocity: 100, start: 480 * 6, length: 480)])])
        let bytes = [UInt8](file.data())
        #expect(Int(bytes[12]) << 8 | Int(bytes[13]) == 960, "an eighth is 480 ticks, so a quarter is 960")
        let back = try MIDIFile(data: file.data())
        #expect(back.ticksPerBeat == 480 && abs(back.tempo - 120) < 0.01 && back.beatUnit == 8)
        #expect(back.tracks.first?.notes.first?.start == 480 * 6, "bar 2 is still bar 2")
    }

    @Test("a master is never written over a file already there")
    func wavNeverOverwrites() throws {
        let directory = LibraryFixture.directory("audit-wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("master.wav")
        try Data("mine".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Export.writeWAV24([[0, 0.1, 0]], sampleRate: 48_000, to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
    }
}
