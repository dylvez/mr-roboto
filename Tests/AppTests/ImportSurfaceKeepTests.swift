import AVFAudio
import Analysis
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The Import surface's model when things go wrong or wait: a separation that fails or is
// cancelled, a promote with nothing selected, the provenance form between sessions, and what the
// frame is told is still unkept.
//
// A short generated tone rather than the reference track. None of this needs three minutes of
// audio to be true, and a machine without the track should still run every one of these.

// MARK: - Fixtures

enum ImportKeepFixture {

    static func temporaryDirectory(_ label: String = "keep") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrRobotoImportKeep-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two seconds of a quiet sine, so the waveform, the durations and the package are real.
    static func writeTone(to url: URL, seconds: Double = 2, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(2 * .pi * 220 * Double(frame) / sampleRate) * 0.4)
        }
        try file.write(from: buffer)
    }

    /// A believable report at 120 bpm: a key, a grid with a downbeat every four beats, one section.
    static func report(path: String, duration: Double, bpm: Double = 120) -> AnalysisReport {
        var report = AnalysisReport(sourcePath: path, duration: duration)
        report.key = KeyEstimate(key: Key(tonic: NoteName(.d), mode: .ionian), duration: duration)
        var beats: [Double] = []
        var downbeats: [Double] = []
        var time = 0.0
        var index = 0
        while time < duration {
            beats.append(time)
            if index % 4 == 0 { downbeats.append(time) }
            time += 60 / bpm
            index += 1
        }
        report.beats = BeatTrackingResult(beats: beats, downbeats: downbeats, bpm: bpm)
        report.structure = StructureAnalysis(sections: [Analysis.TimeRange(start: 0, end: duration)])
        report.loudness = LoudnessAnalysis(integrated: -13.4, truePeak: -0.8)
        report.capabilities = [.key, .beats, .structure, .loudness]
        report.provenance = [.key: "stub", .beats: "stub"]
        return report
    }

    /// A tone on disk and the stub host that will import it, over a library in `directory`.
    static func toneAndHost(in directory: URL) throws -> (source: URL, host: StubImportHost) {
        let source = directory.appendingPathComponent("Tone.wav")
        try writeTone(to: source)
        let library = LibraryStore(directoryURL: directory.appendingPathComponent("Library"))
        let info = try AudioFileInfo.read(source)
        let host = StubImportHost(library: library, report: report(path: source.path, duration: info.duration))
        return (source, host)
    }

    /// Waits for `condition`, a millisecond at a time, for at most `limit` milliseconds.
    @MainActor
    static func settle(_ limit: Int = 5_000, until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<limit where !condition() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Import surface: failing, waiting and keeping")
struct ImportSurfaceKeepTests {

    @Test("a separation that fails keeps the record on screen and says why")
    func separationFailureKeepsTheRecord() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("separation-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        var (source, host) = try ImportKeepFixture.toneAndHost(in: directory)
        host.separationFailure = "demucs is not installed"
        let model = ImportModel(host: host)
        await model.run(source)
        let songID = try #require(model.draft?.song.id)
        #expect(model.canSeparateStems)

        model.separateStems()
        await model.waitForCompletion()

        // Ready, with the record still there — not the drop target with a reason on it.
        #expect(model.state == .ready(songID))
        #expect(model.draft != nil)
        #expect(!model.waveform.isEmpty)
        #expect(model.stems.isEmpty)
        #expect(model.canSeparateStems, "the record is there to try again")
        #expect(model.lastError?.contains("demucs is not installed") == true)
        #expect(model.phaseLog.suffix(3) == [.separating, .failed, .ready])
        #expect(!model.hasUnkeptChanges)
    }

    @Test("cancelling a separation keeps the record too")
    func separationCancellationKeepsTheRecord() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("separation-cancels")
        defer { try? FileManager.default.removeItem(at: directory) }
        var (source, host) = try ImportKeepFixture.toneAndHost(in: directory)
        host.separationHold = .seconds(30)
        let model = ImportModel(host: host)
        await model.run(source)
        let songID = try #require(model.draft?.song.id)

        model.separateStems()
        try await ImportKeepFixture.settle { model.state.phase == .separating }
        #expect(model.state.isCancellable)
        #expect(model.hasUnkeptChanges, "a separation in flight is work the song does not have")

        model.cancel()
        await model.waitForCompletion()

        #expect(model.state == .ready(songID))
        #expect(model.draft != nil)
        #expect(model.stems.isEmpty)
        #expect(model.lastError == nil, "a cancel is not a failure")
        #expect(model.phaseLog.suffix(3) == [.separating, .cancelled, .ready])
        #expect(!model.hasUnkeptChanges)
    }

    @Test("pressing Promote with nothing selected says so in the failure note, and a real selection clears it")
    func promoteErrorReachesLastError() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("promote")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, host) = try ImportKeepFixture.toneAndHost(in: directory)
        let model = ImportModel(host: host)
        await model.run(source)

        model.selection = nil
        model.pressPromote()
        #expect(model.lastError == ImportModelError.noSelection.description)
        #expect(model.promoted.isEmpty)

        model.selection = try #require(model.range(ofBar: 0))
        #expect(model.selectionLabel == "Bar 1")
        model.pressPromote()
        #expect(model.lastError == nil)
        #expect(model.promoted.count == 1)
        try await ImportKeepFixture.settle { !model.hasUnkeptChanges }
    }

    @Test("hasUnkeptChanges is true while the import runs, while a promotion is in flight, and while the form is edited")
    func unkeptChangesFollowTheWork() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("unkept")
        defer { try? FileManager.default.removeItem(at: directory) }
        var (source, host) = try ImportKeepFixture.toneAndHost(in: directory)
        host.analysisHold = .milliseconds(100)
        let model = ImportModel(host: host)
        #expect(!model.hasUnkeptChanges, "an empty drop target holds nothing")

        model.drop(source)
        try await ImportKeepFixture.settle { model.hasUnkeptChanges }
        #expect(model.state.isBusy)
        await model.waitForCompletion()
        #expect(model.state.phase == .ready)
        #expect(!model.hasUnkeptChanges, "an import that has written its versions is kept")

        // A promotion is unkept until the host has taken it and the package has been re-saved.
        let bar = try #require(model.range(ofBar: 0))
        try model.promote(bar)
        #expect(model.hasUnkeptChanges)
        try await ImportKeepFixture.settle { !model.hasUnkeptChanges }
        #expect(!host.log.committed.isEmpty)

        // An edited form is unkept until Keep, and kept once the write lands.
        model.provenance.label = "Vessel"
        #expect(model.hasUnkeptProvenance)
        #expect(model.hasUnkeptChanges)
        model.keepProvenance()
        try await ImportKeepFixture.settle { !model.hasUnkeptChanges }
        #expect(model.keptProvenance == model.provenance)
        #expect(model.lastError == nil)
    }

    @Test("the provenance form is kept in the record and the seed note, and comes back when the song is reopened")
    func provenanceRoundTrips() async throws {
        let directory = ImportKeepFixture.temporaryDirectory("provenance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (source, host) = try ImportKeepFixture.toneAndHost(in: directory)
        let model = ImportModel(host: host)
        await model.run(source)
        #expect(model.provenance.title == "Tone", "the file's name is the record's until the form says otherwise")
        #expect(!model.hasUnkeptProvenance)

        let form = ImportProvenance(title: "Arrival", artist: "Interior Season",
                                    label: "Vessel", year: "2026",
                                    rightsHolder: "Interior Season", note: "own recording; cleared by email",
                                    clearance: .cleared)
        model.provenance = form
        #expect(model.hasUnkeptProvenance)
        model.keepProvenance()
        try await ImportKeepFixture.settle { !model.hasUnkeptChanges }
        #expect(model.lastError == nil)
        #expect(model.keptProvenance == form)

        // On disk: the row has the title and artist, the seed note has the whole form.
        let reloaded = try host.library.load()
        let record = try #require(reloaded.records.first)
        #expect(record.title == "Arrival")
        #expect(record.artist == "Interior Season")
        let song = try #require(reloaded.songs.first)
        let note = try #require(song.seeds.first?.note)
        #expect(note.hasPrefix("imported from \(source.path) — Interior Season – Arrival (Vessel, 2026)"), "\(note)")
        #expect(note.contains("\nlabel: Vessel\n"))
        #expect(note.contains("\nrights: Interior Season\n"))
        #expect(note.contains("\nnote: own recording; cleared by email\n"))
        #expect(note.hasSuffix("\nclearance: cleared"))

        // Reopened from the library, the form is exactly what was kept — and reads as kept.
        let reader = ImportModel(host: host)
        reader.open(song, record: record)
        await reader.waitForCompletion()
        #expect(reader.state == .ready(song.id))
        #expect(reader.provenance == form)
        #expect(!reader.hasUnkeptProvenance)

        // And what Album ▸ Clearances would read from it.
        let clearance = reader.provenance.clearanceRecord(for: record.id)
        #expect(clearance.status == .cleared)
        #expect(clearance.record == record.id)
        #expect(clearance.source == "Interior Season – Arrival (Vessel, 2026)")
        #expect(clearance.note == "rights: Interior Season; own recording; cleared by email")
    }

    @Test("a seed note round-trips the form without a record row, and an older note still reads")
    func seedNoteReadsBack() {
        let form = ImportProvenance(title: "Arrival", artist: "Interior Season", label: "Vessel", year: "2026",
                                    rightsHolder: "Interior Season", note: "own recording", clearance: .notRequired)
        let seed = Seed(kind: .importedRecord(RecordID()), note: form.seedNote(sourcePath: "/x/Arrival.mp3"))
        #expect(ImportProvenance.restored(from: seed, record: nil) == form)
        #expect(ImportProvenance.sourcePath(in: seed.note) == "/x/Arrival.mp3")

        // Empty fields are left out, and the clearance is always said.
        let bare = ImportProvenance().seedNote(sourcePath: "/x/Tone.wav")
        #expect(bare == "imported from /x/Tone.wav\nclearance: uncleared")

        // A note from before the field lines: the citation on one line, the clearance in brackets.
        let media = MediaRef.placeholder(for: URL(fileURLWithPath: "/x/Arrival.mp3"))
        let record = Record(title: "Arrival", artist: "Interior Season", media: media)
        let older = Seed(kind: .importedRecord(record.id),
                         note: "imported from /x/Arrival.mp3 — Interior Season – Arrival (Vessel, 2026) [clearance: pending]")
        let restored = ImportProvenance.restored(from: older, record: record)
        #expect(restored.title == "Arrival")
        #expect(restored.artist == "Interior Season")
        #expect(restored.clearance == .pending)
        #expect(restored.label.isEmpty && restored.year.isEmpty)
        #expect(ImportProvenance.sourcePath(in: older.note) == "/x/Arrival.mp3")
    }

    @Test("the app's host keeps the seed through the frame when the song is open, and the row in the library")
    func adapterKeepsThroughTheFrame() async throws {
        let directory = WiringFixture.temporaryDirectory("import-keep")
        defer { WiringFixture.remove(directory) }
        var song = WiringFixture.song()
        let record = Record(title: "Arrival", artist: "Vessel", media: WiringFixture.media)
        song.seeds.append(Seed(kind: .importedRecord(record.id), note: "imported from /x/Arrival.wav"))
        let app = WiringFixture.app(in: directory, song: song)
        app.autosaveDelay = nil
        let store = try #require(app.store)
        let host: any ImportHosting = ImportAdapter(app: app, service: WiringFixture.silentService(),
                                                   live: LiveImportHost(library: store))

        let form = ImportProvenance(title: "Arrival", artist: "Vessel", label: "Vessel", year: "2026", clearance: .cleared)
        var seed = try #require(song.seeds.first)
        seed.note = form.seedNote(sourcePath: "/x/Arrival.wav")
        try await host.keepProvenance(record, seed: seed, in: song)

        // The open song took the seed and is unsaved for it: the frame saves it, not the surface.
        #expect(app.song?.seeds.first?.note == seed.note)
        #expect(app.hasUnsavedChanges)
        // The row reached library.json, and the frame's mirror of it.
        #expect(try store.load().records.map(\.id) == [record.id])
        #expect(app.library.records.first?.title == "Arrival")
        // Nothing wrote the package: the song on disk is still the frame's to save.
        #expect(try store.songStores().isEmpty)
    }
}
