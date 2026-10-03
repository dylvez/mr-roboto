import Analysis
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A record's grid corrected: the tempo halved for a tracker that counted double time, the downbeat
// moved by a beat, the second tracker's grid taken. Kept on the record, read through by everything
// that reads it, and one press from as it was read.

@MainActor
enum GridFixture {
    static let rate = 48_000.0

    /// A library with "Twice" in its crate: twenty bars of clicks at 100 bpm from 0.5 s, read by a
    /// tracker that counted double time — 200 bpm, a bar every 1.2 s — with a second tracker's beats
    /// at 100 kept. Separated into a drums stem; and a song open at 100 bpm in D.
    static func app(_ label: String) throws -> (app: AppState, directory: URL, record: Record) {
        let directory = WiringFixture.temporaryDirectory(label)
        let store = LibraryStore(directoryURL: directory)
        try store.save(Library())
        let seconds = 0.5 + 20 * 2.4 + 0.5
        let file = directory.appendingPathComponent("twice.wav")
        try BoothAdapter.write(MashupFixture.clicks(bpm: 100, downbeat: 0.5, seconds: seconds), sampleRate: rate, to: file)
        let media = try store.addMedia(copying: file, kind: .record)
        // Beats up to the last bar's downbeat, bars as an import counts them: forty of 1.2 s.
        var read = MashupFixture.analysis(bpm: 200, downbeat: 0.5, seconds: 48.4, key: Key(tonic: NoteName(.d)), sections: [])
        read.duration = seconds
        let grid = BeatGrid(beats: read.beats.map(\.time), bars: read.downbeats)
        let bars = (0..<grid.barCount).compactMap { grid.bounds(ofBar: $0).map { SongGraph.TimeRange(start: $0.start, end: $0.end) } }
        read.bars = bars
        read.checkerBeats = MashupFixture.analysis(bpm: 100, downbeat: 0.5, seconds: 48.4, key: Key(tonic: NoteName(.d)), sections: []).beats
        read.beatCheck = BeatGridCheck(checker: "beat-this", agreement: 0.5, primaryBPM: 200, checkerBPM: 100, usedChecker: false)
        let drums = RecordStem(name: "drums", media: media, sampleRate: rate, channelCount: 1, duration: seconds, lufs: -20, relativeDB: 0,
                               barLevels: Array(repeating: -20, count: bars.count))
        let record = Record(title: "Twice", media: media,
                            analysis: PartVersion(partID: PartID(), kind: .analysis(read), author: .user, operation: Operation.imported),
                            stems: [drums])
        var library = Library(records: [record])
        library.records = [record]
        try store.saveDocument(library)
        let app = AppState(library: try store.load(), store: store, transportHost: StubTransportHost())
        app.autosaveDelay = nil
        app.open(Song.new(title: "At 100", key: Key(tonic: NoteName(.d)), tempo: 100))
        app.save()
        return (app, directory, record)
    }
}

@Suite("A record's grid, corrected", .serialized) @MainActor
struct GridCorrectionTests {

    @Test("read at double time its bars are half bars and a blank song takes 200; halved they are not, and Fit again re-tightens in one press")
    func halveAndRefit() async throws {
        let (app, directory, record) = try GridFixture.app("grid-halve")
        defer { WiringFixture.remove(directory) }
        let request = SourceRequest(record: record.id, stem: "drums", takesItsGrid: false)
        let before = try app.sourcePick(request)
        #expect(before.plan.move.tempoFactor == 0.5 && before.material.bars.count == 40, "200 read, halved to meet a song at 100")
        let loop = SourceRequest(record: record.id, stem: "drums", bars: 0..<2, takesItsGrid: false)
        #expect(try app.sourcePick(loop).plan.bars == 1, "its \"two bars\" are one bar of the record")
        #expect(try app.sourcePick(SourceRequest(record: record.id, stem: "drums", takesItsGrid: true)).material.tempo == 200,
                "a blank song taking its grid would be at 200")
        let added = try await app.addSource(request)
        #expect(Guidance.audio(of: added)?.fit?.grid == nil)

        let corrected = try app.correctGrid(record.id, .half)
        #expect(corrected.grid == RecordGrid(tempo: 0.5))
        #expect(try app.sourcePick(loop).plan.bars == 2 && abs((try app.sourcePick(loop).material.tempo ?? 0) - 100) < 0.01)
        #expect(corrected.reading?.bars.count == 20 && corrected.reading?.dominantTempo.map { abs($0 - 100) < 0.01 } == true)
        #expect(corrected.readingAsRead?.bars.count == 40, "the analysis itself is not rewritten")
        #expect(app.log.last?.text == "Twice's grid: halved" && app.log.last?.detail?.contains("200.0 bpm, 40 bars → 100.0 bpm, 20 bars") == true)
        #expect(app.log.last?.detail?.contains("Drums of Twice") == true, "the source fitted to the old bars is named")
        #expect(app.sourcesReadingAnOlderGrid().map(\.partID) == [added.partID])
        let model = SourcesModel(app: app)
        #expect(model.line(for: added).contains("its record's grid corrected since: fit again"))

        // One press: fitted again from the untouched record through the corrected grid.
        await model.refit(added.partID)
        let again = try #require(app.song?.latestVersion(of: added.partID))
        let fit = try #require(Guidance.audio(of: again)?.fit)
        #expect(again.parents == [added.id] && fit.grid == RecordGrid(tempo: 0.5) && abs(fit.ratio - 1) < 1e-6 && fit.tightened)
        #expect(app.sourcesReadingAnOlderGrid().isEmpty)
        let url = try app.store!.mediaURL(for: Guidance.audio(of: again)!.media, song: app.song!.id)
        let (worst, count) = try SourcesFixture.worstOffBeat(url, laidAt: Guidance.audio(of: again)!.alignmentOffset ?? 0)
        #expect(count > 70 && worst < 0.003, "every click on the song's beat: \(worst) s")
    }

    @Test("its stems are measured again against the new bars; the moves wrap, refuse what changes nothing, and go back as read")
    func moves() async throws {
        let (app, directory, record) = try GridFixture.app("grid-moves")
        defer { WiringFixture.remove(directory) }
        try app.correctGrid(record.id, .half)
        #expect(app.crate.isQueued(.measure, for: record.id) || app.crate.finished.contains { $0.kind == .measure })
        await app.crate.waitUntilIdle()
        #expect(app.library.record(record.id)?.stems?.first?.barLevels?.count == 20)

        #expect(app.refusal(of: .half, for: record.id) == .unchanged("Twice"))
        #expect(throws: GridError.unchanged("Twice")) { try app.correctGrid(record.id, .half) }
        try app.correctGrid(record.id, .later)
        try app.correctGrid(record.id, .later)
        #expect(app.library.record(record.id)?.grid == RecordGrid(tempo: 0.5, downbeat: 2))
        try app.correctGrid(record.id, .later)
        #expect(app.library.record(record.id)?.grid?.downbeat == -1, "three beats later is one earlier")
        #expect(app.library.record(record.id)?.reading?.downbeats.first.map { abs($0 - 2.3) < 1e-6 } == true)
        try app.correctGrid(record.id, .later)
        try app.correctGrid(record.id, .double)
        #expect(app.library.record(record.id)?.grid == nil, "every move undone is as read")

        try app.correctGrid(record.id, .secondTracker)
        #expect(app.library.record(record.id)?.reading?.dominantTempo.map { abs($0 - 100) < 0.01 } == true)
        try app.correctGrid(record.id, .asRead)
        #expect(app.library.record(record.id)?.grid == nil && app.refusal(of: .asRead, for: record.id) == .unchanged("Twice"))
        await app.crate.waitUntilIdle()
        #expect(app.library.record(record.id)?.stems?.first?.barLevels?.count == 40)

        // Read before the second tracker's beats were kept: it says to read it again.
        var library = app.library
        if case .analysis(var read) = library.records[0].analysis!.kind {
            read.checkerBeats = nil
            library.records[0].analysis = PartVersion(partID: PartID(), kind: .analysis(read), author: .user, operation: Operation.imported)
        }
        #expect(app.writeLibrary(library))
        #expect(app.refusal(of: .secondTracker, for: record.id) == .noSecondTracker("Twice"))
        #expect(GridError.noSecondTracker("Twice").description.contains("Listen with the Second Tracker"))
    }

    @Test("the second tracker listens alone: its beats join the reading, the first tracker's grid untouched, and its grid can be taken")
    func listen() async throws {
        let (app, directory, record) = try GridFixture.app("grid-listen")
        defer { WiringFixture.remove(directory) }
        var library = app.library
        if case .analysis(var read) = library.records[0].analysis!.kind {
            read.checkerBeats = nil
            read.beatCheck = nil
            library.records[0].analysis = PartVersion(partID: library.records[0].analysis!.partID, kind: .analysis(read), author: .user,
                                                      operation: Operation.imported)
        }
        #expect(app.writeLibrary(library))
        let before = try #require(app.library.record(record.id)?.readingAsRead)
        var host = StubImportHost(library: app.store!, report: ImportKeepFixture.report(path: "", duration: 49))
        host.checked = BeatTrackingResult(beats: stride(from: 0.5, to: 48.4, by: 0.6).map { $0 }, downbeats: [0.5, 3.5], bpm: 100)
        app.crate.host = host
        app.listenForSecondTracker(record.id)
        await app.crate.waitUntilIdle()
        let heard = try #require(app.library.record(record.id)?.readingAsRead)
        #expect(heard.beats == before.beats && heard.bars == before.bars && heard.tempo == before.tempo, "the first reading kept")
        #expect(heard.checkerBeats?.count == 80 && heard.beatCheck?.checkerBPM == 100)
        #expect(heard.beatCheck?.agreement.map { $0 > 0.4 && $0 < 0.8 } == true, "every other beat of the first's: \(heard.beatCheck?.agreement ?? -1)")
        #expect(app.log.last?.text == "Twice's second beat tracker has listened")
        let taken = try app.correctGrid(record.id, .secondTracker)
        #expect(taken.reading?.bars.count == 20 && taken.reading?.dominantTempo == 100)

        // Read again, a reading that comes back different says what it was.
        app.analyseRecord(record.id)
        await app.crate.waitUntilIdle()
        #expect(app.log.last?.text == "Twice is read")
        #expect(app.log.last?.detail?.contains("it was 200.0 bpm, 40 bars before") == true && app.log.last?.detail?.contains("still read through its correction, the second tracker's") == true)
    }

    @Test("a record still called by its file is renamed, the song made from it offered as the name")
    func rename() throws {
        let (app, directory, record) = try GridFixture.app("grid-rename")
        defer { WiringFixture.remove(directory) }
        #expect(app.suggestedName(for: record.id) == "Twice")
        #expect(app.flipAgain(record.id))
        app.setTitle("Twice, flipped")
        app.save()
        #expect(app.suggestedName(for: record.id) == "Twice, flipped")
        #expect(app.renameRecord(record.id, to: "  Twice, flipped "))
        #expect(app.library.record(record.id)?.title == "Twice, flipped" && app.log.last?.text == "Renamed Twice to Twice, flipped")
        #expect(!app.renameRecord(record.id, to: " ") && !app.renameRecord(record.id, to: "Twice, flipped"))
        #expect(try app.store!.loadDocumentOnly().records.first?.title == "Twice, flipped")
    }

    @Test("an import keeps the second tracker's beats when it checked rather than stood in")
    func keepsTheSecondTracker() {
        var report = ImportKeepFixture.report(path: "/x.wav", duration: 8)
        report.checkerBeats = BeatTrackingResult(beats: stride(from: 0.0, to: 8, by: 1).map { $0 }, downbeats: [0, 4], bpm: 60)
        report.beatCheck = BeatCheck(checker: "beat-this", agreement: 0.3, primaryBPM: 120, checkerBPM: 60, usedChecker: false)
        let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: 8)
        #expect(analysis.checkerBeats?.count == 8 && analysis.checkerBeats?.filter(\.isDownbeat).map(\.time) == [0, 4])
        #expect(analysis.beats.count == 16, "the first tracker's grid is still the one read")
    }

    @Test("a song's own record corrected in the crate: a stem of the song is read through the correction")
    func songOfACorrectedRecord() throws {
        let (app, directory, record) = try GridFixture.app("grid-song")
        defer { WiringFixture.remove(directory) }
        // A song flipped from the record, before the correction: its stems are the record's.
        let open = try #require(app.song)
        #expect(app.flipAgain(record.id))
        app.save()
        let flipped = try #require(app.song)
        app.open(open)
        try app.correctGrid(record.id, .half)
        let pick = try app.sourcePick(SourceRequest(song: flipped.id, stem: "drums", takesItsGrid: false))
        #expect(pick.material.bars.count == 20 && abs(pick.plan.move.ratio - 1) < 1e-6 && pick.fit.grid == RecordGrid(tempo: 0.5))
    }

    @Test("fix_grid corrects it for the band and names what to fit again; read_library says the trackers disagree")
    func band() async throws {
        let (app, directory, record) = try GridFixture.app("grid-band")
        defer { WiringFixture.remove(directory) }
        let added = try await app.addSource(SourceRequest(record: record.id, stem: "drums", takesItsGrid: false))
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)),
                                            workspace: AppStateWorkspace(app))
        func json(_ result: ClaudeToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]) ?? [:]
        }
        let read = json(await toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object([]))))
        let entry = try #require((read["records"] as? [[String: Any]])?.first)
        #expect(entry["trackers_agree"] as? Double == 0.5 && entry["second_tracker_tempo"] as? Double == 100)
        #expect(entry["second_tracker_kept"] as? Bool == true && entry["grid"] == nil && entry["tempo"] as? Double == 200)

        let fixed = await toolbox.run(ClaudeToolUse(id: "f", name: "fix_grid", input: .object([
            .init("record", .string("Twice")), .init("move", .string("second_tracker")),
        ])))
        #expect(!fixed.isError, "\(fixed.content)")
        let out = json(fixed)
        #expect(out["grid"] as? String == "the second tracker's" && out["bars"] as? Int == 20)
        #expect(out["fit_again"] as? [String] == [added.partID.description])
        #expect(app.log.last?.text == "Twice's grid: the second tracker's")

        // A record read before the second tracker's beats were kept: it listens, and the band is told to ask again.
        var library = app.library
        if case .analysis(var read) = library.records[0].analysis!.kind {
            read.checkerBeats = nil
            library.records[0].analysis = PartVersion(partID: PartID(), kind: .analysis(read), author: .user, operation: Operation.imported)
        }
        library.records[0].grid = nil
        #expect(app.writeLibrary(library))
        var host = StubImportHost(library: app.store!, report: ImportKeepFixture.report(path: "", duration: 49))
        host.checked = BeatTrackingResult(beats: stride(from: 0.5, to: 48.4, by: 0.6).map { $0 }, downbeats: [0.5], bpm: 100)
        app.crate.host = host
        let listening = await toolbox.run(ClaudeToolUse(id: "q", name: "fix_grid", input: .object([
            .init("record", .string("Twice")), .init("move", .string("second_tracker")),
        ])))
        #expect(listening.isError && listening.content.contains("listening to it now"))
        await app.crate.waitUntilIdle()
        #expect(app.library.records[0].readingAsRead?.checkerBeats?.count == 80)

        let wrong = await toolbox.run(ClaudeToolUse(id: "w", name: "fix_grid", input: .object([
            .init("record", .string("Twice")), .init("move", .string("triple")),
        ])))
        #expect(wrong.isError && wrong.content.contains("half, double, later, earlier, second_tracker, as_read"))
    }
}
