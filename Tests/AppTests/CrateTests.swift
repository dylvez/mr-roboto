import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The crate: records brought into the library as raw material — read and separated once, in the
// background, their stems kept beside them for every song to take — and no song made of any of them.

@MainActor
enum CrateFixture {
    static let rate = 44_100.0
    /// Eight bars of 2 s at 120 bpm.
    static let seconds = 16.0

    /// A tone: silent until `from`, then a sine at `amplitude`.
    static func tone(_ frequency: Double, amplitude: Float, from: Double = 0, seconds: Double = seconds) -> [[Float]] {
        let frames = Int(seconds * rate), start = Int(from * rate)
        return [(0..<frames).map { frame in frame < start ? 0 : amplitude * Float(sin(2 * .pi * frequency * Double(frame) / rate)) }]
    }

    /// A library in `directory`, an app on it, `count` records on disk to import, and a stub that
    /// reads every one at 120 bpm in D and separates each into four stems: the voice loud from the
    /// top, the drums under it, the bass silent for three bars, the rest quiet.
    static func app(in directory: URL, records count: Int = 5, failing: String? = nil)
        throws -> (app: AppState, files: [URL], host: StubImportHost) {
        let store = LibraryStore(directoryURL: directory.appendingPathComponent("Library"))
        try store.save(Library())
        var files: [URL] = []
        for index in 0..<count {
            let file = directory.appendingPathComponent("Record \(index + 1).wav")
            try BoothAdapter.write(tone(200 + Double(index) * 30, amplitude: 0.5), sampleRate: rate, to: file)
            files.append(file)
        }
        let stems = directory.appendingPathComponent("stems", isDirectory: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        var made: [StemName: URL] = [:]
        for (name, planar) in [(StemName.vocals, tone(440, amplitude: 0.45)), (.drums, tone(110, amplitude: 0.15)),
                               (.bass, tone(55, amplitude: 0.3, from: 6)), (.other, tone(880, amplitude: 0.01))] {
            let url = stems.appendingPathComponent("\(name.rawValue).wav")
            try BoothAdapter.write(planar, sampleRate: rate, to: url)
            made[name] = url
        }
        var host = StubImportHost(library: store, report: ImportKeepFixture.report(path: files[0].path, duration: seconds), stems: made)
        host.separationFailure = failing
        let app = AppState(library: try store.load(), store: store, transportHost: StubTransportHost())
        app.autosaveDelay = nil
        app.crate.host = host
        return (app, files, host)
    }
}

@Suite("The crate: records in, read and separated in the background, no song made", .serialized) @MainActor
struct CrateTests {

    @Test("five files in: five rows at once, then each read, then each separated into records/; no song, and the disk agrees")
    func importFive() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-five")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory)
        #expect(app.importRecords(files, separating: true) == 5)
        #expect(app.crate.line?.hasPrefix("Bringing in Record 1") == true)
        await app.crate.waitUntilIdle()

        #expect(app.library.songs.isEmpty, "importing makes no song")
        #expect(app.library.records.map(\.title) == (1...5).map { "Record \($0)" })
        #expect(app.crate.finished.map(\.kind) == Array(repeating: .bring, count: 5) + Array(repeating: .analyse, count: 5)
                + Array(repeating: .separate, count: 5), "every file on the shelf, then every one read, then separated")
        #expect(app.crate.line == nil && app.crate.isIdle)

        let store = try #require(app.store)
        for record in app.library.records {
            let reading = try #require(record.reading)
            #expect(reading.bars.count == 8 && reading.dominantTempo == 120)
            let stems = try #require(record.stems)
            #expect(stems.map(\.name) == ["vocals", "drums", "bass", "other"])
            for stem in stems {
                let url = try store.mediaURL(for: stem.media)
                #expect(url.deletingLastPathComponent().lastPathComponent == LibraryStore.recordsDirectoryName)
                #expect(stem.barLevels?.count == 8 && abs(stem.duration - CrateFixture.seconds) < 0.01)
            }
            let bass = try #require(record.stem(named: "bass")), vocals = try #require(record.stem(named: "vocals"))
            #expect(bass.barLevels!.prefix(3).allSatisfy { $0 == RecordStems.floorDB } && bass.barLevels![3] > -20)
            #expect(RecordStems.firstPlayedBar(bass.barLevels!) == 3)
            #expect(vocals.relativeDB.map { abs($0 - (vocals.lufs! - (-13.4))) < 0.11 } == true, "against the record's loudness as read")
            #expect(record.stem(named: "other")!.relativeDB! < vocals.relativeDB! - 20, "the quiet one reads as hardly there")
        }
        // The disk holds what the frame does.
        let reread = try store.load()
        #expect(reread.records == app.library.records && reread.songs.isEmpty)
        #expect(!LibrarySidebar.recordDetail(app.library.records[0]).isEmpty && LibrarySidebar.recordDetail(app.library.records[0]).hasSuffix("4 stems"))
    }

    @Test("the same audio twice is one record; asked twice, a job is queued once")
    func once() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-once")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1)
        let copy = directory.appendingPathComponent("Same again.wav")
        try FileManager.default.copyItem(at: files[0], to: copy)
        app.importRecords([files[0], copy], separating: false)
        await app.crate.waitUntilIdle()
        #expect(app.library.records.count == 1)
        #expect(app.log.contains { $0.text == "Record 1 is already in the crate" })
        #expect(app.library.records[0].stems == nil, "not separated unasked")

        let id = app.library.records[0].id
        app.separateRecord(id)
        app.separateRecord(id)
        #expect(app.crate.isQueued(.separate, for: id))
        #expect(app.crate.waiting.filter { $0.record == id }.count + (app.crate.running?.record == id ? 1 : 0) == 1)
        await app.crate.waitUntilIdle()
        #expect(app.library.records[0].stems?.count == 4)
    }

    @Test("closing the song and every surface while it runs stops nothing; removing a record stops its own work")
    func carriesOn() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-carries")
        defer { WiringFixture.remove(directory) }
        let (app, files, stub) = try CrateFixture.app(in: directory, records: 3)
        var host = stub
        host.separationHold = .milliseconds(150)
        app.crate.host = host
        app.open(Song.new(title: "Something else"))
        app.openSurface(.sources, title: "Sources")
        app.importRecords(files, separating: true)
        app.closeAllSurfaces()
        app.closeSong(saving: false)
        // The third record goes while the queue is still on the others.
        while app.library.records.count < 3 || app.crate.running?.kind != .separate { await Task.yield() }
        let third = try #require(app.library.records.last)
        #expect(app.removeRecord(third.id))
        await app.crate.waitUntilIdle()
        #expect(app.library.records.count == 2 && app.library.records.allSatisfy { $0.stems?.count == 4 })
        #expect(!app.crate.finished.contains { $0.record == third.id && $0.kind == .separate })
    }

    @Test("a separation that fails keeps the record, read, with the reason on its row; asked again it is cleared")
    func failure() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-fail")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1, failing: "weightsDownloadFailed")
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        let record = try #require(app.library.records.first)
        #expect(record.reading != nil && record.stems == nil)
        #expect(app.crate.failures[record.id]?.contains("could not be downloaded") == true)
        #expect(app.log.contains { $0.text == "Separating Record 1 failed" })
        app.crate.host = StubImportHost(library: app.store!, report: ImportKeepFixture.report(path: files[0].path, duration: 16))
        app.separateRecord(record.id)
        #expect(app.crate.failures[record.id] == nil)
    }

    @Test("a record's stem into the open song through Sources: fitted from records/, the fit naming the record, fitted again")
    func source() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-source")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1)
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        let record = try #require(app.library.records.first)

        app.open(Song.new(title: "Built from records", key: Key(tonic: NoteName(.e)), tempo: 100))
        app.save()
        #expect(Sources.records(in: app.library).map(\.id) == [record.id])
        // The song's grid stands: E at 100, the record moved onto it.
        let request = SourceRequest(record: record.id, stem: "bass", atBar: 0, takesItsGrid: false)
        let pick = try app.sourcePick(request)
        #expect(pick.meter.beatsPerBar == 4 && abs(pick.plan.move.ratio - 1.2) < 1e-9 && pick.plan.move.semitones == 2)
        let version = try await app.addSource(request)
        let audio = try #require(Guidance.audio(of: version))
        let fit = try #require(audio.fit)
        #expect(fit.record == record.id && fit.song == nil && fit.media == record.stem(named: "bass")?.media)
        #expect(audio.sourceRecord == record.id && PartLabel.title(of: version) == "Bass of Record 1")
        #expect(!(app.song?.mediaReferences.contains(fit.media) ?? true), "the render is the song's; the stem stays the record's")

        let again = try await app.refitSource(version.partID, semitones: -1)
        #expect(Guidance.audio(of: again)?.fit?.record == record.id && Guidance.audio(of: again)?.fit?.semitones == -1)

        let clip = try await app.addSource(SourceRequest(record: record.id, stem: Mashups.full, bars: 3..<5, takesItsGrid: false))
        #expect(clip.type == .sample)
        #expect(throws: SourceError.noBars("Record 1", 8)) { try app.sourcePick(SourceRequest(record: record.id, stem: "bass", bars: 9..<10)) }
        #expect(throws: SourceError.noSuchRecord) { try app.sourcePick(SourceRequest(record: RecordID(), stem: "bass")) }
    }

    @Test("a stem dragged from the shelf onto a section lands in Sources, chosen, with that section; the wire form round-trips")
    func drag() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-drag")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1)
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        let record = try #require(app.library.records.first)

        let payload = LibraryDragPayload(kind: .stem, id: record.id.rawValue, title: "Bass of Record 1", stem: "bass")
        #expect(payload.description == "mrroboto:stem:\(record.id.rawValue.uuidString):bass")
        #expect(LibraryDragPayload(payload.description) == LibraryDragPayload(kind: .stem, id: record.id.rawValue, title: "", stem: "bass"))
        #expect(LibraryDragPayload("mrroboto:stem:\(record.id.rawValue.uuidString)") == nil, "a stem names its stem")
        #expect(LibraryDragPayload("mrroboto:record:\(record.id.rawValue.uuidString)")?.stem == nil)

        #expect(!app.receive(payload, at: .bench), "no song open: nothing to fit it into")
        var song = Song.new(title: "Two sections", tempo: 120)
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4), Section(name: "Chorus", stitch: [], lengthInBars: 4)]
        app.open(song)
        let chorus = try #require(app.song?.sections.last)
        #expect(app.receive(payload, at: .section(chorus.id)))
        #expect(app.bench.items.contains { $0.kind == .sources })
        #expect(app.askedSource == AskedSource(origin: .record(record.id), stem: "bass", section: chorus.id))
        let model = SourcesModel(app: app)
        #expect(app.askedSource == nil, "taken once")
        #expect(model.from == .record(record.id) && model.stem == "bass" && model.sections == [chorus.id])
        #expect(model.sourceTitle == "Record 1" && model.share(of: "bass") != nil && model.available.last == Mashups.full)
    }

    @Test("a song's own stems kept with its record — hard-linked, the song untouched — and a song started from it carries them")
    func gatherAndFlip() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-gather")
        defer { WiringFixture.remove(directory) }
        let (app, a, _) = try MashupFixture.app(in: directory)
        let record = try #require(app.library.records.first { $0.title == "Arrival" })
        #expect(record.stems == nil)
        #expect(app.songsHoldingStems(of: record.id).map(\.id) == [a.id])
        app.gatherStems(of: record.id, from: a.id)
        await app.crate.waitUntilIdle()

        let kept = try #require(app.library.record(record.id)?.stems)
        #expect(kept.map(\.name) == ["bass", "other"])
        let store = try #require(app.store)
        let shared = store.recordsDirectoryURL.appendingPathComponent(kept[0].media.fileName)
        let inSong = try store.songStore(for: a.id).mediaURL(for: kept[0].media)
        let links = try FileManager.default.attributesOfItem(atPath: shared.path)[.referenceCount] as? Int
        #expect(links == 2, "the same file under two names, no copy")
        #expect(FileManager.default.fileExists(atPath: inSong.path))
        #expect(app.songsHoldingStems(of: record.id).isEmpty, "it has its own now")

        // The record's own audio was the song's alone; it is the stems' too, so it is in records/ now.
        #expect(app.flipAgain(record.id))
        let flipped = try #require(app.song)
        let stems = Guidance.stems(in: flipped)
        #expect(stems.compactMap { Guidance.audio(of: $0)?.stem } == ["bass", "other"])
        #expect(stems.allSatisfy { Guidance.audio(of: $0).map { a in kept.contains { $0.media == a.media } } == true })
        app.save()
        #expect(flipped.mediaReferences.allSatisfy { store.hasMedia($0, song: flipped.id) }, "the flip's take and stems resolve to records/")
        #expect(try store.songStore(for: flipped.id).storedMedia().isEmpty, "and none of it was copied into its package")
    }

    @Test("stems separated on the Record surface are handed on, and the frame keeps them with the record")
    func recordSurface() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("crate-record-surface")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, stub) = try ImportKeepFixture.toneAndHost(in: directory)
        var host = stub
        let stems = directory.appendingPathComponent("vocals.wav")
        try ImportKeepFixture.writeTone(to: stems)
        host.stems = [.vocals: stems]
        let model = ImportModel(host: host)
        await model.run(source)
        model.separateStems()
        await model.waitForCompletion()
        let draft = try #require(model.draft)
        #expect(host.log.separated.map(\.record) == [draft.record.id] && host.log.separated.first?.stems == 1)

        // The frame's half: told of it, the crate takes the song's stems onto the record.
        let (app, a, _) = try MashupFixture.app(in: WiringFixture.temporaryDirectory("crate-adapter"))
        defer { WiringFixture.remove(app.store!.directoryURL) }
        let record = try #require(app.library.records.first { $0.title == "Arrival" })
        let adapter = ImportAdapter(app: app, service: WiringFixture.silentService(), live: LiveImportHost(library: app.store!))
        await adapter.didSeparate(record.id, in: try #require(app.library.song(a.id)))
        #expect(app.crate.isQueued(.gather, for: record.id))
        await app.crate.waitUntilIdle()
        #expect(app.library.record(record.id)?.stems?.map(\.name) == ["bass", "other"])
    }

    @Test("a crate stem chops at the first bar it plays, not at the top of the record")
    func chopsWhereItPlays() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-chop")
        defer { WiringFixture.remove(directory) }
        let (app, files, _) = try CrateFixture.app(in: directory, records: 1)
        app.importRecords(files, separating: true)
        await app.crate.waitUntilIdle()
        let record = try #require(app.library.records.first)
        #expect(app.flipAgain(record.id))
        let song = try #require(app.song)
        let bass = try #require(Guidance.stems(in: song).first { Guidance.audio(of: $0)?.stem == "bass" })
        #expect(Guidance.barToChop(of: bass, in: song)?.number == 4)
        let vocals = try #require(Guidance.stems(in: song).first { Guidance.audio(of: $0)?.stem == "vocals" })
        #expect(Guidance.barToChop(of: vocals, in: song)?.number == 1)
    }

    @Test("read_library lists a record's stems and what the crate is doing; adopt takes a record's stem, and queues one it lacks")
    func band() async throws {
        let directory = WiringFixture.temporaryDirectory("crate-band")
        defer { WiringFixture.remove(directory) }
        let (app, files, stub) = try CrateFixture.app(in: directory, records: 2)
        var host = stub
        app.importRecords([files[0]], separating: true)
        app.importRecords([files[1]], separating: false)
        await app.crate.waitUntilIdle()
        let separated = app.library.records[0], plain = app.library.records[1]
        app.open(Song.new(title: "The band's", key: Key(tonic: NoteName(.d)), tempo: 120))
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func json(_ result: ClaudeToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? [:]
        }
        let read = json(await toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object([]))))
        let records = read["records"] as? [[String: Any]] ?? []
        let first = try #require(records.first { $0["title"] as? String == "Record 1" })
        let stems = first["stems"] as? [[String: Any]] ?? []
        #expect(stems.compactMap { $0["name"] as? String } == ["vocals", "drums", "bass", "other", "full"])
        #expect(stems.first { $0["name"] as? String == "bass" }?["comes_in_at_bar"] as? Int == 4)
        #expect((records.first { $0["title"] as? String == "Record 2" }?["stems"] as? [[String: Any]])?.count == 1)

        let adopted = await toolbox.run(ClaudeToolUse(id: "a", name: "adopt", input: .object([
            .init("kind", .string("record")), .init("id", .string(separated.id.description)), .init("stem", .string("vocals")),
            .init("bars", .array([])), .init("at_bar", .int(0)), .init("tighten", .string("")),
        ])))
        #expect(!adopted.isError, "\(adopted.content)")
        #expect(app.song?.fittedSources.first.flatMap { Guidance.audio(of: $0)?.fit?.record } == separated.id)

        host.separationHold = .milliseconds(100)
        app.crate.host = host
        let missing = await toolbox.run(ClaudeToolUse(id: "m", name: "adopt", input: .object([
            .init("kind", .string("record")), .init("id", .string(plain.title)), .init("stem", .string("drums")),
        ])))
        #expect(missing.isError && missing.content.contains("queued"))
        #expect(app.crate.isQueued(.separate, for: plain.id))
        let status = json(await toolbox.run(ClaudeToolUse(id: "s", name: "read_library", input: .object([]))))
        #expect((status["records"] as? [[String: Any]])?.first { $0["title"] as? String == "Record 2" }?["status"] as? String != nil)
        await app.crate.waitUntilIdle()
        #expect(app.library.record(plain.id)?.stems?.count == 4)

        let take = await toolbox.run(ClaudeToolUse(id: "t", name: "adopt", input: .object([
            .init("kind", .string("record")), .init("id", .string(plain.id.description)), .init("stem", .string("")),
        ])))
        #expect(!take.isError && json(take)["type"] as? String == "audio", "no stem: the record's take and analysis, as before")
    }
}
