import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M3 Gate A: the library is real. Ideas kept and adopted, samples saved and dropped, records
// flipped again and chopped from a second song, albums sequenced with their clearances — every
// write to `library.json` alone, every adoption a copy into the song.

@MainActor
enum LibraryFixture {

    /// A real library directory, a real store, and an app over it with audio that never reaches a device.
    static func app(_ directory: URL) -> AppState {
        AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                 status: .empty(directory), transportHost: StubTransportHost())
    }

    /// A short mono tone on disk, so records and samples have real bytes to hash and copy.
    static func tone(in directory: URL, seconds: Double = 0.5, frequency: Double = 220) throws -> URL {
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = Float(0.4 * sin(2 * .pi * frequency * Double(frame) / 44_100))
        }
        try file.write(from: buffer)
        return url
    }

    /// A record in the library: its media in `records/`, analysed by the guidance fixture's analysis.
    static func record(_ title: String, in directory: URL, store: LibraryStore, frequency: Double = 220) throws -> Record {
        let url = try tone(in: directory, frequency: frequency)
        let media = try store.addMedia(copying: url, kind: .record)
        let analysis = PartVersion(partID: PartID(), kind: .analysis(GuidanceFixture.analysis()), author: .user,
                                   operation: Operation.imported, note: "analysis of \(title)")
        return Record(title: title, artist: "Vessel", media: media, analysis: analysis)
    }

    /// A song saved into the library with a kicking groove and a real dusty chop cut from `record`.
    static func songWithChop(_ title: String, record: Record, app: AppState) throws -> (song: Song, groove: VersionID, chop: VersionID) {
        var song = Song(title: title, artist: "Vessel", key: Key(tonic: NoteName(.d), mode: .ionian), tempo: 92)
        let seed = Seed(kind: .importedRecord(record.id))
        song.seeds.append(seed)
        let built = FormFixture.build()
        let groove = try #require(built.song.latestVersion(of: built.groove))
        try song.append(groove)
        let chop = PartVersion(partID: PartID(),
                               kind: .sample(Sample(media: record.media, slices: [SliceMarker(position: 0.1)], detectedTempo: 92,
                                                    sourceRecord: record.id, degradation: [Dust.pass(.sp1200, mix: 0.6)])),
                               author: .user, operation: Operation.chop, note: "Bar 1 of \(record.title)", origin: seed.id)
        try song.append(chop)
        app.open(song)
        app.save()
        return (song, groove.id, chop.id)
    }

    static func directory(_ label: String) -> URL { GuidanceFixture.temporaryDirectory("library-\(label)") }
}

@Suite("Library: ideas", .serialized) @MainActor
struct LibraryIdeaTests {

    @Test("a groove kept as an idea from one song is adopted into another and plays; the origin is untouched")
    func keepAndAdopt() throws {
        let directory = LibraryFixture.directory("ideas")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        let (origin, groove, _) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)

        let idea = try #require(app.keepAsIdea(groove))
        #expect(app.library.ideas.count == 1)
        #expect(app.library.ideas[0].id == idea)
        #expect(app.library.ideas[0].note?.contains("from Arrival") == true)
        #expect(app.library.ideas[0].kind == origin.version(groove)?.kind)
        #expect(app.song?.versions.count == origin.versions.count, "keeping versions nothing in the song")
        #expect(!app.hasUnsavedChanges, "a library write does not dirty the song")

        // A fresh session sees it, and the song it came from is exactly as it was on disk.
        let later = LibraryFixture.app(directory)
        later.reloadLibrary()
        #expect(later.library.ideas.count == 1)
        #expect(later.library.song(origin.id)?.versions.count == origin.versions.count)

        // Adopted into another song: a new version of a new part, operation adopted, and it plays.
        later.open(Song(title: "Second"))
        let adopted = try #require(later.adopt(LibraryDragPayload(kind: .idea, id: idea.rawValue, title: "Groove")))
        let version = try #require(later.song?.version(adopted))
        #expect(version.operation == Operation.adopted)
        #expect(version.parents.isEmpty)
        #expect(version.kind == origin.version(groove)?.kind)
        #expect(version.note?.hasPrefix("from idea") == true)
        #expect(later.playback.groove != nil)
        #expect(later.library.song(origin.id)?.versions.count == origin.versions.count)

        // Dropped on the bench it opens in the Grid.
        later.open(Song(title: "Third"))
        #expect(later.receive(LibraryDragPayload(kind: .idea, id: idea.rawValue, title: "Groove"), at: .bench))
        #expect(later.bench.items.last?.kind == .grid)
        #expect(later.bound(for: later.bench.items.last!.id).count == 1)
    }

    @Test("with no song open there is nothing to adopt into, and the rail says so")
    func nothingOpen() throws {
        let directory = LibraryFixture.directory("ideas-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = LibraryFixture.app(directory)
        #expect(!app.receive(LibraryDragPayload(kind: .idea, id: UUID(), title: "x"), at: .bench))
        #expect(app.log.last?.text.contains("Open a song first") == true)
    }
}

@Suite("Library: samples", .serialized) @MainActor
struct LibrarySampleTests {

    @Test("a dusty chop saved to Samples keeps its chain, tempo and source; dropped on another song it opens the Chop lane")
    func saveAndDrop() throws {
        let directory = LibraryFixture.directory("samples")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (_, _, chop) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)

        let saved = try #require(app.saveToSamples(chop))
        let entry = try #require(app.library.sample(saved))
        #expect(entry.name.contains("Arrival"))
        #expect(entry.sample.degradation.count == 1)
        #expect(entry.sample.detectedTempo == 92)
        #expect(entry.sample.sourceRecord == record.id)
        #expect(FileManager.default.fileExists(atPath: store.samplesDirectoryURL.appendingPathComponent(entry.sample.media.fileName).path),
                "the sample's audio was copied into samples/")
        #expect(LibrarySidebar.sampleDetail(entry).contains("92 bpm"))

        let later = LibraryFixture.app(directory)
        later.reloadLibrary()
        #expect(later.library.samples.count == 1)
        later.open(Song(title: "Second", tempo: 92))
        #expect(later.receive(LibraryDragPayload(kind: .sample, id: saved.rawValue, title: entry.name), at: .bench))
        let version = try #require(later.song?.versions.last)
        #expect(version.type == .sample)
        #expect(version.operation == Operation.adopted)
        #expect(later.bench.items.last?.kind == .chopLane)
        #expect(later.bound(for: later.bench.items.last!.id) == [version.id])
        #expect(later.playback.chop != nil, "a dusty chop plays from the transport")
        #expect(LibrarySidebar.recordDetail(record).contains("D major"))
    }

    @Test("only a chop can be saved as a sample")
    func onlyChops() throws {
        let directory = LibraryFixture.directory("samples-refuse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        let (_, groove, _) = try LibraryFixture.songWithChop("Arrival", record: record, app: app)
        #expect(app.saveToSamples(groove) == nil)
        #expect(app.library.samples.isEmpty)
    }
}

@Suite("Library: records, again", .serialized) @MainActor
struct LibraryRecordTests {

    @Test("a record flips again into a new song with its analysis and its take, without re-import")
    func flipAgain() throws {
        let directory = LibraryFixture.directory("flip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))

        #expect(app.flipAgain(record.id))
        let song = try #require(app.song)
        #expect(song.title == "Arrival")
        #expect(song.key?.name == "D major")
        #expect(song.tempo == GuidanceFixture.bpm)
        #expect(song.versions.map(\.type) == [.analysis, .audio])
        #expect(song.seeds.count == 1)
        #expect(Guidance.canShowRecord(in: song))
        #expect(app.bench.items.first?.kind == .importRecord, "the record opens on its surface")
        let steps = WorkPath.steps(for: song, active: nil, canPerform: app.canPerform).steps
        #expect(steps.first { $0.kind == .stems }?.isNext == true, "separating the stems is next")

        app.save()
        #expect(app.flipAgain(record.id))
        #expect(app.song?.title == "Arrival flip 2")
    }

    @Test("a second record adopted into a song chops by its own analysis, not the song's")
    func secondRecord() throws {
        let directory = LibraryFixture.directory("second-record")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        var record = try LibraryFixture.record("Motown", in: directory, store: store, frequency: 330)
        // The second record's bars are half the length of the fixture's, so the two analyses differ.
        var analysis = GuidanceFixture.analysis()
        analysis.bars = analysis.bars.map { SongGraph.TimeRange(start: $0.start, end: $0.start + $0.duration / 2) }
        record.analysis = PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user, operation: Operation.imported)
        #expect(app.writeLibrary(Library(records: [record])))

        // A song with its own record and analysis.
        let built = GuidanceFixture.imported()
        app.open(built.song)
        let ownBar = try #require(Guidance.barToChop(of: built.take, in: built.song))

        #expect(app.receive(LibraryDragPayload(kind: .record, id: record.id.rawValue, title: record.title), at: .bench))
        let song = try #require(app.song)
        let take = try #require(song.versions.last { Guidance.audio(of: $0)?.role == .take && Guidance.audio(of: $0)?.media == record.media })
        #expect(take.operation == Operation.adopted)
        #expect(song.seeds.count == built.song.seeds.count + 1)
        #expect(song.versions.filter { $0.type == .analysis }.count == 2)

        // Each take reads its own analysis.
        #expect(Guidance.analysis(for: take, in: song)?.bars.first?.duration == analysis.bars.first?.duration)
        #expect(Guidance.analysis(for: built.take, in: song)?.bars.first?.duration == ownBar.range.duration)
        #expect(Guidance.sourceRecord(of: take, in: song) == record.id)

        // And the drop cut a bar of the new record into the Chop lane, from the new record's bars.
        let lane = try #require(app.bench.items.last)
        #expect(lane.kind == .chopLane)
        let chop = try #require(app.bound(for: lane.id).first.flatMap { song.version($0) })
        guard case .sample(let sample) = chop.kind else { Issue.record("not a sample"); return }
        #expect(sample.media == record.media)
        #expect(sample.sourceRecord == record.id)
        #expect(chop.parents == [take.id])

        // Dropped again, the record is not brought in twice.
        let count = song.versions.count
        #expect(app.receive(LibraryDragPayload(kind: .record, id: record.id.rawValue, title: record.title), at: .ledger))
        #expect(app.song?.versions.count == count)
    }
}

@Suite("Library: albums", .serialized) @MainActor
struct LibraryAlbumTests {

    @Test("an album of two songs lists both sources of their samples with a clearance state each, and survives a reload")
    func albumAndClearances() throws {
        let directory = LibraryFixture.directory("albums")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let arrival = try LibraryFixture.record("Arrival", in: directory, store: store)
        let motown = try LibraryFixture.record("Bernadette", in: directory, store: store, frequency: 330)
        #expect(app.writeLibrary(Library(records: [arrival, motown])))
        let (first, _, _) = try LibraryFixture.songWithChop("First", record: arrival, app: app)
        let (second, _, _) = try LibraryFixture.songWithChop("Second", record: motown, app: app)

        let album = try #require(app.createAlbum(title: "Interior Season", artist: "Vessel"))
        #expect(app.addSong(first.id, to: album))
        #expect(app.addSong(second.id, to: album))
        #expect(!app.addSong(first.id, to: album) || app.library.album(album)?.songs.count == 2, "a song is in an album once")
        #expect(app.library.album(album)?.songs == [first.id, second.id])
        #expect(app.moveSong(second.id, in: album, to: 0))
        #expect(app.library.album(album)?.songs == [second.id, first.id])

        var sources = app.sources(of: app.library.album(album)!)
        #expect(sources.map(\.source).sorted() == ["Vessel – Arrival", "Vessel – Bernadette"])
        #expect(sources.allSatisfy { $0.status == .uncleared })
        #expect(app.setClearance(.cleared, forSource: "Vessel – Arrival", record: arrival.id, in: album))
        sources = app.sources(of: app.library.album(album)!)
        #expect(sources.first { $0.record == arrival.id }?.status == .cleared)
        #expect(sources.first { $0.record == motown.id }?.status == .uncleared)

        let later = LibraryFixture.app(directory)
        later.reloadLibrary()
        let reloaded = try #require(later.library.album(album))
        #expect(reloaded.title == "Interior Season")
        #expect(reloaded.songs == [second.id, first.id])
        #expect(later.sources(of: reloaded).first { $0.record == arrival.id }?.status == .cleared)
        #expect(later.removeSong(first.id, from: album))
        #expect(later.library.album(album)?.songs == [second.id])

        // The surface opens on it and resolves to a real view; opening it again focuses the one open.
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let surface = try #require(later.openAlbum(album))
        #expect(later.bench.items.last?.kind == .album)
        #expect(later.album(for: surface)?.id == album)
        #expect(!registry.resolve(later.bench.items.last!, app: later).isPlaceholder)
        #expect(later.openAlbum(album) == surface)
        #expect(later.bench.items.filter { $0.kind == .album }.count == 1)
        later.closeSurface(surface)
        #expect(later.albumBindings[surface] == nil)
    }
}

@Suite("Library: drops", .serialized) @MainActor
struct LibraryDropTests {

    @Test("a song row opens the song; a section drop stitches what plays and only adopts what does not")
    func drops() throws {
        let directory = LibraryFixture.directory("drops")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directoryURL: directory)
        let app = LibraryFixture.app(directory)
        let record = try LibraryFixture.record("Arrival", in: directory, store: store)
        #expect(app.writeLibrary(Library(records: [record])))
        let (first, groove, chop) = try LibraryFixture.songWithChop("First", record: record, app: app)
        let idea = try #require(app.keepAsIdea(groove))
        let sample = try #require(app.saveToSamples(chop))
        // A dry chop too, which is adopted but never stitched.
        let dry = PartVersion(partID: PartID(), kind: .sample(Sample(media: record.media, slices: [], detectedTempo: 92)),
                              author: .user, operation: Operation.chop, note: "dry")
        #expect(app.record(dry))
        let drySample = try #require(app.saveToSamples(dry.id, name: "Dry bar"))

        var second = Song(title: "Second", tempo: 92)
        second.sections = [Section(name: "Verse", stitch: [], lengthInBars: 8)]
        app.open(second)
        app.save()
        let verse = second.sections[0].id

        // A drop aimed at a section is placed there and nowhere else: making a part puts it in
        // every section, but saying where you want it is saying where you want it.
        #expect(app.receive(LibraryDragPayload(kind: .idea, id: idea.rawValue, title: "Groove"), at: .section(verse)))
        #expect(app.song?.sections[0].stitch.count == 1)
        #expect(app.receive(LibraryDragPayload(kind: .sample, id: sample.rawValue, title: "Chop"), at: .section(verse)))
        #expect(app.song?.sections[0].stitch.count == 2)
        #expect(app.receive(LibraryDragPayload(kind: .sample, id: drySample.rawValue, title: "Dry"), at: .section(verse)))
        #expect(app.song?.sections[0].stitch.count == 2, "a dry chop does not play, so it is not stitched")
        #expect(app.song?.versions.count == 3, "but it was adopted")
        #expect(app.log.last?.text.contains("not stitched") == true)
        #expect(app.playback.isArranged && app.playback.segments[0].groove != nil && app.playback.segments[0].chop != nil)

        // A song row opens the song.
        #expect(app.receive(LibraryDragPayload(kind: .song, id: first.id.rawValue, title: first.title), at: .bench))
        #expect(app.song?.id == first.id)
    }
}
