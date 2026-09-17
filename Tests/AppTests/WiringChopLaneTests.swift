import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

/// The Import → Chop lane hand-off, end to end, with a real file in a real library.
///
/// This is the seam the four agents could not build between them, and the one nothing else here
/// covers: a `.sample` part version carries a media hash and slice markers, not audio and not a
/// region, so opening a lane on a promoted bar means finding the file, working out which span was
/// promoted, and reading it. Every step of that is on disk, so this test puts it there.
@Suite("Wiring: opening a Chop lane on a promoted bar", .serialized) @MainActor
struct WiringChopLaneTests {

    private static let sampleRate: Double = 48_000
    private static let bpm: Double = 96
    private static var barLength: Double { 4 * 60 / bpm }

    /// Twelve bars of a plain four-on-the-floor kick, which is enough for a lane to find onsets in.
    private static func record() -> [Float] {
        let beat = 60 / bpm
        let total = Int(12 * barLength * sampleRate)
        var out = [Float](repeating: 0, count: total)
        var time = 0.0
        while time < Double(total) / sampleRate {
            let start = Int(time * sampleRate)
            for i in 0..<Int(0.12 * sampleRate) where start + i < total {
                let t = Double(i) / sampleRate
                out[start + i] += Float(sin(2 * .pi * 70 * t) * exp(-t * 26) * 0.8)
            }
            time += beat
        }
        return out
    }

    @Test("a promoted bar opens a lane on its own audio, sliced and ready to play")
    func laneOpensOnThePromotedBar() async throws {
        let directory = WiringFixture.temporaryDirectory("library")
        defer { WiringFixture.remove(directory) }
        let store = LibraryStore(directoryURL: directory)

        // A record on disk, hashed into the library exactly as `ImportModel` puts it there.
        let source = directory.appendingPathComponent("record.wav")
        try ChopAudio.writeWAV([Self.record()], to: source, sampleRate: Self.sampleRate)
        let media = try store.addMedia(copying: source, kind: .record)

        // The song the import made: the whole-track analysis, and a promoted bar 5.
        let bars = (0..<12).map {
            SongGraph.TimeRange(start: Double($0) * Self.barLength, end: Double($0 + 1) * Self.barLength)
        }
        let beats = stride(from: 0.0, to: 12 * Self.barLength, by: 60 / Self.bpm).enumerated().map {
            BeatMarker(time: $0.element, isDownbeat: $0.offset % 4 == 0)
        }
        var song = Song(title: "Arrival", tempo: Self.bpm)
        try song.append(PartVersion(partID: PartID(),
                                    kind: .analysis(MusicAnalysis(duration: 12 * Self.barLength,
                                                                  beats: beats, bars: bars)),
                                    author: .user, operation: Operation.imported))
        let bar = bars[4]
        let promoted = PartVersion(partID: PartID(),
                                   kind: .sample(Sample(media: media,
                                                        slices: [SliceMarker(position: bar.start)],
                                                        detectedTempo: Self.bpm)),
                                   author: .user, operation: Operation.chop,
                                   note: "Bar 5 of Arrival")
        try song.append(promoted)

        let app = AppState(library: Library(), song: song, store: store,
                           transportHost: StubTransportHost())

        // The hand-off: Import promotes, the lane opens on that version.
        let id = app.adoptPromotedRegion(promoted, from: song)
        let lane = try #require(app.bench.items.first { $0.kind == .chopLane })
        #expect(id == lane.id)
        #expect(app.bound(for: lane.id) == [promoted.id])

        let binding = ChopLaneBinding(item: lane, app: app, service: WiringFixture.silentService())
        await binding.waitForLoad()
        guard case .ready(let surface) = binding.state else {
            Issue.record("the lane never resolved: \(binding.state)")
            return
        }

        // It opened on the promoted bar, not on the whole record.
        #expect(abs(surface.source.sourceOffset - bar.start) < 1e-6)
        #expect(abs(surface.source.duration - Self.barLength) < 0.01)
        #expect(surface.source.isWellFormed)
        #expect(surface.source.sampleRate == Self.sampleRate)
        #expect(surface.source.tempo == Self.bpm)
        #expect(surface.source.media == media)
        // The part it belongs to, so a commit is a new version of the promoted bar rather than a
        // second part with the same audio.
        #expect(surface.source.partID == promoted.partID)
        // And it came up sliced and bound, which is what "ready to play" means.
        #expect(surface.sliceCount >= 4, "the bar produced \(surface.sliceCount) slices")
        #expect(surface.bound == [promoted.id])
        #expect(surface.grid(at: 0) != nil || surface.source.grid != nil)
    }

    @Test("a bar whose media is gone says so rather than opening an empty lane")
    func missingMediaIsReported() async throws {
        let directory = WiringFixture.temporaryDirectory("library")
        defer { WiringFixture.remove(directory) }
        var song = WiringFixture.song()
        let promoted = WiringFixture.promotedBar()
        try song.append(promoted)
        let app = WiringFixture.app(in: directory, song: song)

        let id = app.openSurface(.chopLane, title: "Bar 5", bound: [promoted.id])
        let item = try #require(app.bench.items.first { $0.id == id })
        let binding = ChopLaneBinding(item: item, app: app, service: WiringFixture.silentService())

        await binding.waitForLoad()
        guard case .failed(let reason) = binding.state else {
            Issue.record("a missing file resolved to \(binding.state)")
            return
        }
        #expect(reason.contains("missing") || reason.lowercased().contains("media"))
    }
}

private extension ChopLaneSurface {
    /// A grid line at or after `seconds`, if the lane drew any.
    func grid(at seconds: Double) -> Double? { gridLines.first { $0 >= seconds } }
}
