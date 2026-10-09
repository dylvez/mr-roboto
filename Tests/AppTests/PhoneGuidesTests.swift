import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The guides for the phone: every section of the open song, with a count-in of click in front,
// and a manifest the phone reads to offer them.

@Suite("Guides for the phone", .serialized) @MainActor
struct PhoneGuidesTests {

    @Test("every section goes out with its count-in in front, and the manifest says which and how long")
    func export() async throws {
        let directory = LibraryFixture.directory("guides")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory), status: .empty(directory), transportHost: StubTransportHost())
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 2), Section(name: "Hook", stitch: ids, lengthInBars: 1)]
        app.open(song)
        let folder = directory.appendingPathComponent("Guides", isDirectory: true)
        // Another song's guides are already there, and stay.
        try PhoneGuides.write(PhoneGuides.Manifest(writtenAt: "before", songs: [
            .init(title: "Other", tempo: 90, beatsPerBar: 4, beatUnit: 4, sections: []),
        ]), at: folder)

        let result = try await PhoneGuides.export(app, to: folder, countInBars: 1)
        #expect(result.folder.lastPathComponent == "Arrival" && result.entry.sections.count == 2)
        let manifest = try #require(PhoneGuides.readManifest(at: folder))
        #expect(manifest.songs.map(\.title) == ["Arrival", "Other"])
        let entry = try #require(manifest.songs.first { $0.title == "Arrival" })
        #expect(entry.sections.map(\.name) == ["Verse", "Hook"] && entry.tempo == 120 && entry.beatsPerBar == 4)
        let verse = entry.sections[0]
        #expect(verse.bars == 2 && verse.countInBars == 1 && abs(verse.countInSeconds - 2) < 1e-9, "one bar at 120 is two seconds")
        #expect(verse.file == "Arrival/Verse.m4a")

        // The file: a bar of count-in, two bars of song, half a second of tail.
        let file = folder.appendingPathComponent(verse.file)
        let read = try BoothAdapter.planar(file)
        let rate = read.sampleRate
        let lane = read.planar[0]
        let seconds = Double(lane.count) / rate
        #expect(abs(seconds - (2 + 4 + 0.5)) < 0.05, "\(seconds)")
        #expect(abs(verse.seconds - seconds) < 0.05)
        // The count-in is click and nothing else: a hit on each beat, silence between.
        let beat = Int(0.5 * rate)
        for b in 0..<4 {
            let at = b * beat
            #expect(lane[at..<(at + Int(0.02 * rate))].contains { abs($0) > 0.3 }, "a click on beat \(b + 1)")
            let between = lane[(at + Int(0.1 * rate))..<(at + beat - Int(0.01 * rate))]
            #expect(!between.contains { abs($0) > 0.02 }, "silence after the click on beat \(b + 1)")
        }
        #expect(lane[Int(2 * rate)..<Int(6 * rate)].contains { abs($0) > 0.05 }, "the song plays after the count-in")
        #expect(app.log.contains { $0.text.contains("Guides for the phone: 2 sections of Arrival") })

        // Rendered again with two bars of count-in, the song's entry is replaced, not added to.
        _ = try await PhoneGuides.export(app, to: folder, countInBars: 2)
        let again = try #require(PhoneGuides.readManifest(at: folder))
        #expect(again.songs.count == 2)
        #expect(again.songs.first { $0.title == "Arrival" }?.sections[0].countInBars == 2)
        #expect(abs((again.songs.first { $0.title == "Arrival" }?.sections[0].countInSeconds ?? 0) - 4) < 1e-9)
    }

    @Test("a song with no sections has nothing to guide, and says so")
    func noSections() async throws {
        let directory = LibraryFixture.directory("guides-none")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory), status: .empty(directory), transportHost: StubTransportHost())
        app.open(FormFixture.build(tempo: 120).song)
        await #expect(throws: PhoneGuides.Failure.self) {
            _ = try await PhoneGuides.export(app, to: directory.appendingPathComponent("Guides"), countInBars: 1)
        }
    }

    @Test("the count-in is the Booth's click: the accent on the one, the rest lighter, in every channel")
    func countIn() {
        let clock = TransportClock(tempo: 60, timeSignature: TimeSignature(beatsPerBar: 3))
        let lanes = PhoneGuides.countIn(bars: 2, clock: clock, sampleRate: 48_000, channels: 2)
        #expect(lanes.count == 2 && lanes[0] == lanes[1] && lanes[0].count == 6 * 48_000)
        func peak(beat: Int) -> Float { lanes[0][(beat * 48_000)..<(beat * 48_000 + 600)].map(abs).max() ?? 0 }
        #expect(peak(beat: 0) > peak(beat: 1) && peak(beat: 3) > peak(beat: 4), "the one is louder")
        #expect(abs(peak(beat: 0) - 0.95) < 0.01 && abs(peak(beat: 1) - 0.7) < 0.01)
        #expect(lanes[0][(48_000 + 2_000)..<(2 * 48_000 - 10)].allSatisfy { $0 == 0 }, "silence between the beats")
    }
}
