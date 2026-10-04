import AVFAudio
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Listening in the Library: a record from a bar or a run of its bars looped, a stem of it, an idea
// or a sample alone, a song from a preview made once and kept in the caches; one thing at a time,
// giving way to the song's transport.

/// The app's side, written down instead of sounded: this shell has no audio device.
@MainActor
final class StubListening: LibraryListeningHost {
    struct Played: Equatable {
        var id: String
        var frames: Int
        var sampleRate: Double
        var loops: Bool
        var label: String
        var seconds: Double?
        var first: Float
    }

    var store: LibraryStore?
    var played: [Played] = []
    var versions: [(id: String, type: PartType, tempo: Double)] = []
    var stops = 0
    var sounding: String?
    var previewURL: URL?
    var previewsAsked: [SongID] = []

    func mediaURL(_ media: MediaRef) -> URL? { try? store?.mediaURL(for: media) }

    func play(planar: [[Float]], sampleRate: Double, loops: Bool, id: String, label: String, seconds: Double?) async {
        played.append(Played(id: id, frames: planar.first?.count ?? 0, sampleRate: sampleRate, loops: loops, label: label,
                             seconds: seconds, first: planar.first?.first ?? 0))
        sounding = id
    }

    func play(_ version: PartVersion, standingIn song: Song, id: String, label: String) async {
        versions.append((id, version.type, song.tempo))
        sounding = id
    }

    func stop() async {
        stops += 1
        sounding = nil
    }

    func isSounding(_ id: String) -> Bool { sounding == id }

    var phrases: [(id: String, instrument: String, notes: [NoteEvent])] = []
    var grooves: [(id: String, machine: String, tempo: Double)] = []

    func play(phrase notes: [NoteEvent], instrument: String, tempo: Double, id: String, label: String) async {
        phrases.append((id, instrument, notes))
        sounding = id
    }

    func play(groove: Groove, machine: SynthMachine, tempo: Double, id: String, label: String) async {
        grooves.append((id, machine.id, tempo))
        sounding = id
    }

    struct NoPreview: Error {}

    func songPreview(_ song: Song, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        previewsAsked.append(song.id)
        progress(0.5)
        guard let previewURL else { throw NoPreview() }
        return previewURL
    }
}

@MainActor
enum ListeningFixture {
    struct Built {
        var app: AppState
        var model: LibraryBrowserModel
        var host: StubListening
        var record: Record
        var directory: URL
    }

    /// A four-second record of eight half-second bars, ramping up so a slice says where it starts,
    /// with a drums stem, in a real library folder.
    static func built(_ label: String, open song: Song? = nil) throws -> Built {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-listening-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LibraryStore(directoryURL: directory)
        let mix = try store.addMedia(copying: try ramp(in: directory, seconds: 4), kind: .record)
        let drums = try store.addMedia(copying: try ramp(in: directory, seconds: 4, scale: 0.5), kind: .record)
        let reading = MusicAnalysis(duration: 4, keys: [KeyRange(start: 0, end: 4, key: Key(parsing: "A minor")!)],
                                    bars: (0..<8).map { TimeRange(start: Double($0) * 0.5, end: Double($0 + 1) * 0.5) },
                                    tempo: [TempoRange(start: 0, end: 4, bpm: 120)])
        let record = Record(title: "Drifter", media: mix,
                            analysis: PartVersion(partID: PartID(), kind: .analysis(reading), author: .user, operation: Operation.analyzed),
                            stems: [RecordStem(name: "drums", media: drums, sampleRate: 44_100, channelCount: 1, duration: 4)])
        var library = Library(records: [record])
        if let song { library.songs = [song] }
        let app = AppState(library: library, song: song, store: store, status: .loaded(directory), transportHost: StubTransportHost())
        app.autosaveDelay = nil
        let host = StubListening()
        host.store = store
        let model = LibraryBrowserModel(app: app, memory: .inMemory(), listening: host)
        return Built(app: app, model: model, host: host, record: record, directory: directory)
    }

    /// Four bars of a kick and a hat at 120: eight seconds of something to hear.
    static func grooveSong() -> Song {
        TransportFixture.song([TransportFixture.grooveVersion()], sections: [Section(name: "Song", stitch: [], lengthInBars: 4)])
    }

    /// Mono, 44.1 kHz, each sample its own time in seconds times `scale`.
    static func ramp(in directory: URL, seconds: Double, scale: Double = 0.1) throws -> URL {
        let url = directory.appendingPathComponent("ramp-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = Float(Double(frame) / 44_100 * scale) }
        try file.write(from: buffer)
        return url
    }
}

@Suite("Listening in the Library", .serialized) @MainActor
struct LibraryListeningTests {

    @Test("a record plays whole, or from a bar, and stops on a second press")
    func record() async throws {
        let built = try ListeningFixture.built("record")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let preview = built.model.preview
        let item = LibraryItemID.record(built.record.id)
        await preview.play(item)
        let whole = try #require(built.host.played.last)
        #expect(whole.frames == 4 * 44_100 && !whole.loops && whole.label == "Drifter")
        #expect(whole.id == LibraryPreview.id(item) && preview.isSounding(item))
        #expect(preview.record == nil, "a row's play button hears it without drawing it")
        await preview.show(record: built.record.id)
        #expect(preview.recordBars.count == 8 && preview.waveform?.duration == 4)

        await preview.play(item, fromBar: 2)
        let fromBar = try #require(built.host.played.last)
        #expect(fromBar.frames == 3 * 44_100, "from bar 3, a second in, to the end")
        #expect(abs(fromBar.first - 0.1) < 0.001, "it starts where bar 3 does")
        #expect(fromBar.seconds == 3)

        await preview.toggle(item)
        #expect(built.host.stops == 1 && !preview.isSounding(item) && preview.state == .idle)
    }

    @Test("bars chosen either way round loop, and go into the song as a clip of those bars")
    func bars() async throws {
        let song = Song(title: "Night Bus", key: Key(parsing: "C major"), tempo: 85)
        let built = try ListeningFixture.built("bars", open: song)
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let preview = built.model.preview
        let item = LibraryItemID.record(built.record.id)
        await preview.show(record: built.record.id)
        preview.choose(bars: 5, through: 2)
        #expect(preview.bars == 2..<6 && preview.barsName == "Bars 3–6")
        await preview.play(item, looping: true)
        let loop = try #require(built.host.played.last)
        #expect(loop.loops && loop.seconds == nil && loop.frames == 2 * 44_100 && loop.label == "Bars 3–6 of Drifter")
        #expect(abs(loop.first - 0.1) < 0.001)
        let started = try #require(preview.soundingNow)
        #expect(abs((preview.position(at: started.started.addingTimeInterval(2.5)) ?? 0) - 1.5) < 1e-9, "half a second into its second time round")

        preview.choose(bars: 7, through: 7)
        #expect(preview.bars == 7..<8 && preview.barsName == "Bar 8")
        preview.choose(bars: 0, through: 40)
        #expect(preview.bars == 0..<8, "no further than the record's bars")
        await preview.choose(stem: "drums")
        preview.choose(bars: 4, through: 5)
        preview.addBarsToSong()
        #expect(built.app.askedSource == AskedSource(origin: .record(built.record.id), stem: "drums", bars: 4..<6))
        #expect(built.app.bench.active?.kind == .sources)
    }

    @Test("a stem is heard and drawn on its own, under its own name")
    func stem() async throws {
        let built = try ListeningFixture.built("stem")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        let preview = built.model.preview
        let item = LibraryItemID.record(built.record.id)
        await preview.show(record: built.record.id)
        #expect(preview.stems == ["drums"])
        await preview.choose(stem: "drums")
        await preview.play(item, fromBar: 4)
        let heard = try #require(built.host.played.last)
        #expect(heard.id == LibraryPreview.id(item, stem: "drums") && heard.label == "Drifter, drums")
        #expect(abs(heard.first - 1.0) < 0.001, "the stem's own samples, from bar 5: two seconds at half the scale")
        #expect(preview.isSounding(item), "a stem of the record is the record sounding")
        await preview.show(record: nil)
        #expect(preview.stem == nil && preview.bars == nil && preview.waveform == nil)
    }

    @Test("a record whose audio is gone says so and plays nothing")
    func missing() async throws {
        let built = try ListeningFixture.built("missing")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        try FileManager.default.removeItem(at: try LibraryStore(directoryURL: built.directory).mediaURL(for: built.record.media))
        await built.model.preview.play(.record(built.record.id))
        #expect(built.host.played.isEmpty)
        #expect(built.model.preview.state == .failed("Drifter's audio is not in the library folder."))
    }

    @Test("an idea and a sample play alone, at the open song's tempo or their own")
    func ideasAndSamples() async throws {
        let shelf = LibraryIndexFixture.shelf()
        let host = StubListening()
        let app = AppState(library: shelf.library, song: nil, transportHost: StubTransportHost())
        let model = LibraryBrowserModel(app: app, memory: .inMemory(), listening: host)
        await model.preview.play(.sample(shelf.chop.id))
        #expect(host.versions.last?.type == .sample && host.versions.last?.tempo == 100, "its own tempo")
        #expect(model.preview.isSounding(.sample(shelf.chop.id)))
        await model.preview.play(.idea(shelf.idea.id))
        #expect(host.versions.last?.type == .progression && host.versions.last?.tempo == 120)
        #expect(model.preview.canHear(.idea(shelf.idea.id)) && !model.preview.canHear(.album(shelf.album.id)))
    }

    @Test("a song plays from its preview, asked for once per play, and a song with nothing to hear says so")
    func songs() async throws {
        let built = try ListeningFixture.built("songs")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        var song = Song(title: "Quiet", tempo: 120)
        try song.append(TransportFixture.grooveVersion())
        var library = built.app.library
        library.songs = [song]
        built.app.library = library
        built.host.previewURL = try ListeningFixture.ramp(in: built.directory, seconds: 2)
        await built.model.preview.play(.song(song.id))
        #expect(built.host.previewsAsked == [song.id])
        #expect(built.host.played.last?.frames == 2 * 44_100 && built.host.played.last?.label == "Quiet")
        #expect(built.model.preview.isSounding(.song(song.id)))

        built.host.previewURL = nil
        await built.model.preview.play(.song(song.id))
        if case .failed = built.model.preview.state {} else { Issue.record("a preview that could not be made is said") }
    }

    @Test("choosing a song starts its preview, and playing it waits for that one rather than making another")
    func madeOnChoosing() async throws {
        let built = try ListeningFixture.built("choosing")
        defer { try? FileManager.default.removeItem(at: built.directory) }
        var song = Song(title: "Quiet", tempo: 120)
        try song.append(TransportFixture.grooveVersion())
        built.app.library = Library(songs: [song], records: built.app.library.records)
        built.host.previewURL = try ListeningFixture.ramp(in: built.directory, seconds: 1)
        built.model.preview.prepare(song: song.id)
        #expect(built.model.preview.making?.song == song.id)
        built.model.preview.prepare(song: song.id)
        await built.model.preview.play(.song(song.id))
        #expect(built.host.previewsAsked == [song.id], "made once")
        #expect(built.host.played.last?.label == "Quiet")
        #expect(built.model.preview.making == nil)
    }

    @Test("the song's transport starting silences what the Library is playing")
    func handover() async throws {
        let song = ListeningFixture.grooveSong()
        let built = try ListeningFixture.built("handover", open: song)
        defer { try? FileManager.default.removeItem(at: built.directory) }
        await built.model.preview.play(.record(built.record.id))
        #expect(built.host.sounding != nil)
        await built.app.startTransport()
        #expect(built.host.stops == 1 && built.host.sounding == nil)
        #expect(built.model.preview.soundingNow == nil)
        // Nothing of the Library's sounding: the transport starts without a word from it.
        await built.app.stopTransport()
        await built.app.startTransport()
        #expect(built.host.stops == 1)
    }
}

@Suite("Song previews", .serialized) @MainActor
struct SongPreviewTests {

    @Test("a preview is named by the song and what it holds, and a changed song makes a new one")
    func naming() throws {
        var song = Song(title: "Quiet", tempo: 120)
        try song.append(TransportFixture.grooveVersion())
        let first = try SongPreviews.fileName(for: song)
        #expect(first.hasPrefix(song.id.rawValue.uuidString + "-") && first.hasSuffix("-r\(SongPreviews.renderVersion).m4a"))
        #expect(try SongPreviews.fileName(for: song) == first, "the same song, the same name")
        song.tempo = 96
        #expect(try SongPreviews.fileName(for: song) != first)
        #expect(try SongPreviews.fileName(for: Song(title: "Quiet", tempo: 120)) != first, "another song")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent(first), other = directory.appendingPathComponent("\(UUID().uuidString)-0000-r1.m4a")
        let kept = directory.appendingPathComponent(try SongPreviews.fileName(for: song))
        for url in [old, other, kept] { try Data([0]).write(to: url) }
        #expect(SongPreviews.cached(song, in: directory) == kept)
        SongPreviews.forgetOlder(than: kept, of: song, in: directory)
        #expect(!FileManager.default.fileExists(atPath: old.path), "the song's older preview goes")
        #expect(FileManager.default.fileExists(atPath: other.path), "another song's stays")
    }

    @Test("a render made a piece at a time is the render made at once, and cancelling it stops it")
    func paced() async throws {
        let song = ListeningFixture.grooveSong()
        let kits = FileManager.default.temporaryDirectory.appendingPathComponent("previews-kits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: kits) }
        let plan = SongPreviews.plan(for: song, store: nil)
        let whole = try await SectionBounce.render(plan, section: nil, kitsDirectory: kits, onlyTheMix: true)
        let seen = ProgressLog()
        let paced = try await SectionBounce.render(plan, section: nil, kitsDirectory: kits, onlyTheMix: true,
                                                   pacing: .init(frames: 12_000, progress: { seen.add($0) }))
        #expect(paced.mix == whole.mix, "sample for sample")
        #expect(seen.values.count > 10 && seen.values.last == 1)

        let directory = kits.appendingPathComponent("out", isDirectory: true)
        let making = Task { try await SongPreviews.make(song, store: nil, in: directory, kitsDirectory: kits) }
        making.cancel()
        await #expect(throws: CancellationError.self) { try await making.value }
        #expect(SongPreviews.cached(song, in: directory) == nil, "nothing written")
    }

    @Test("a song's preview is as long as its master, and is made once")
    func length() async throws {
        let song = ListeningFixture.grooveSong()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)", isDirectory: true)
        let kits = directory.appendingPathComponent("kits", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await SongPreviews.make(song, store: nil, in: directory, kitsDirectory: kits)
        let master = try await SectionBounce.render(SongPreviews.plan(for: song, store: nil), section: nil, kitsDirectory: kits, onlyTheMix: true)
        let (planar, rate) = try BoothAdapter.planar(url)
        let previewSeconds = Double(planar.first?.count ?? 0) / rate
        let masterSeconds = Double(master.mix.first?.count ?? 0) / master.sampleRate
        #expect(abs(previewSeconds - masterSeconds) < 0.05, "\(previewSeconds) against \(masterSeconds)")
        #expect((planar.first ?? []).contains { abs($0) > 0.01 }, "and it is not silence")
        let made = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try await SongPreviews.make(song, store: nil, in: directory, kitsDirectory: kits) == url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == made, "not made again")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size < Int(masterSeconds * 48_000 * 2 * 4) / 4, "compressed, a fraction of the render")
    }
}

/// Progress reported from the render, read after it.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double] = []
    func add(_ value: Double) { lock.withLock { seen.append(value) } }
    var values: [Double] { lock.withLock { seen } }
}
