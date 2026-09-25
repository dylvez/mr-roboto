import Analysis
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Tests for the Import surface's *model*. Nothing here constructs a view: a surface that only works
// when it is on screen is a surface nobody can check.
//
// Analysis and separation are stubbed. That is not a dodge — the real providers take twenty seconds
// a track and need an analysis session this shell has no business starting — but the *file* is real,
// so the waveform, the durations and the package on disk are all genuine.

// MARK: - Fixtures

/// The reference track. Absent on a machine that has no copy; every test that wants it skips.
private let arrivalURL = URL(fileURLWithPath:
    "/Users/dylanfulmer/Documents/projects/vessel/public/assets/audio/interiorseason/Arrival.mp3")

private var arrivalIsAvailable: Bool {
    FileManager.default.fileExists(atPath: arrivalURL.path)
}

/// A temporary library directory, removed when the returned token is discarded by the caller.
private func makeTemporaryLibrary() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MrRobotoImportTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A believable report: a key, a beat grid with downbeats, sections, activity and loudness.
private func makeReport(path: String, duration: Double, bpm: Double = 96) -> AnalysisReport {
    var report = AnalysisReport(sourcePath: path, duration: duration)
    report.key = KeyEstimate(key: Key(tonic: NoteName(.a), mode: .aeolian), duration: duration)

    let beatInterval = 60 / bpm
    var beats: [Double] = []
    var downbeats: [Double] = []
    var time = 0.0
    var index = 0
    while time < duration {
        beats.append(time)
        if index % 4 == 0 { downbeats.append(time) }
        time += beatInterval
        index += 1
    }
    report.beats = BeatTrackingResult(beats: beats, downbeats: downbeats, bpm: bpm)
    report.structure = StructureAnalysis(sections: [
        Analysis.TimeRange(start: 0, end: duration / 3),
        Analysis.TimeRange(start: duration / 3, end: 2 * duration / 3),
        Analysis.TimeRange(start: 2 * duration / 3, end: duration),
    ])
    report.loudness = LoudnessAnalysis(integrated: -13.4, truePeak: -0.8)
    report.instruments = Analysis.InstrumentActivity(presence: [
        .drums: [Analysis.TimeRange(start: 0, end: duration)],
        .bass: [Analysis.TimeRange(start: duration / 4, end: duration)],
    ])
    report.capabilities = [.key, .beats, .structure, .loudness, .instrumentActivity]
    report.provenance = [.key: "stub", .beats: "stub", .structure: "stub",
                         .loudness: "stub", .instrumentActivity: "stub"]
    return report
}

// MARK: - A stub host

/// Records what the surface asked for, so a test can check "plays on touch" without an audio device.
final class ImportHostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _auditions: [(url: URL, start: Double, end: Double)] = []
    private var _committed: [PartVersion] = []
    private var _steps: [ImportStep] = []

    var auditions: [(url: URL, start: Double, end: Double)] { lock.withLock { _auditions } }
    var committed: [PartVersion] { lock.withLock { _committed } }
    var steps: [ImportStep] { lock.withLock { _steps } }

    func audition(_ url: URL, _ start: Double, _ end: Double) {
        lock.withLock { _auditions.append((url, start, end)) }
    }

    func commit(_ version: PartVersion) { lock.withLock { _committed.append(version) } }
    func step(_ step: ImportStep) { lock.withLock { _steps.append(step) } }
}

struct StubImportHost: ImportHosting {
    let library: LibraryStore
    let report: AnalysisReport
    /// How long analysis pretends to take. Long enough to cancel in the cancellation test, zero
    /// everywhere else.
    var analysisHold: Duration? = nil
    var stems: [StemName: URL] = [:]
    /// How long separation pretends to take, so a cancel can land in the middle of it.
    var separationHold: Duration? = nil
    /// What separation fails with, when it is meant to fail.
    var separationFailure: String? = nil
    let log = ImportHostLog()

    func analyze(_ url: URL, progress: @escaping @Sendable (ImportStep) -> Void) async throws -> AnalysisReport {
        progress(ImportStep(detail: "stub: listening"))
        if let analysisHold { try await Task.sleep(for: analysisHold) }
        try Task.checkCancellation()
        progress(ImportStep(fraction: 1, detail: "stub: done"))
        return report
    }

    func separate(_ url: URL, into directory: URL,
                  progress: @escaping @Sendable (ImportStep) -> Void,
                  stemDidLand: @escaping @Sendable (StemName, URL) -> Void) async throws -> [StemName: URL] {
        if let separationHold { try await Task.sleep(for: separationHold) }
        if let separationFailure { throw StubImportHostError.separation(separationFailure) }
        for (name, fileURL) in stems.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            stemDidLand(name, fileURL)
            progress(ImportStep(fraction: 0.5, detail: name.rawValue))
        }
        return stems
    }

    func audition(_ url: URL, from start: Double, to end: Double) async {
        log.audition(url, start, end)
    }

    func didCommit(_ version: PartVersion, in song: Song) async {
        log.commit(version)
    }
}

enum StubImportHostError: Error, CustomStringConvertible {
    case separation(String)

    var description: String {
        switch self {
        case .separation(let reason): return reason
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Import surface")
struct ImportSurfaceTests {

    @Test("the model walks its states on a real file and leaves a song package",
          .enabled(if: arrivalIsAvailable, "Arrival.mp3 is not on this machine"))
    func transitionsOnARealFile() async throws {
        let libraryURL = makeTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let info = try AudioFileInfo.read(arrivalURL)
        let host = StubImportHost(library: LibraryStore(directoryURL: libraryURL),
                                  report: makeReport(path: arrivalURL.path, duration: info.duration))
        let model = ImportModel(host: host)

        await model.run(arrivalURL)

        #expect(model.phaseLog == [.reading, .analyzing, .analyzed, .writing, .ready])
        #expect(model.state.phase == .ready)

        // The waveform is real: it came out of the file, not out of the stub.
        #expect(!model.waveform.isEmpty)
        #expect(abs(model.waveform.duration - info.duration) < 0.5)
        #expect(!model.downbeats.isEmpty)

        // The readings the surface shows.
        #expect(model.detectedTempo == 96)
        #expect(model.detectedKey != nil)
        #expect(model.barCount > 0)
        #expect(model.sections.count == 3)
        #expect(model.instruments.count == 2)
        #expect(model.loudness?.integrated == -13.4)

        // The package exists and reads back with its media.
        let store = LibraryStore(directoryURL: libraryURL)
        let reloaded = try store.load()
        #expect(reloaded.songs.count == 1)
        #expect(reloaded.records.count == 1)
        try store.verifyMedia(for: reloaded)

        let song = try #require(reloaded.songs.first)
        #expect(song.versions.contains { $0.type == .analysis })
        #expect(song.versions.contains { $0.type == .audio })
        #expect(song.seeds.count == 1)
        #expect(model.packageURL != nil)
    }

    @Test("progress is honest: the analysis pass admits it cannot say how far along it is",
          .enabled(if: arrivalIsAvailable, "Arrival.mp3 is not on this machine"))
    func progressIsHonest() async throws {
        let libraryURL = makeTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let info = try AudioFileInfo.read(arrivalURL)
        var host = StubImportHost(library: LibraryStore(directoryURL: libraryURL),
                                  report: makeReport(path: arrivalURL.path, duration: info.duration))
        host.analysisHold = .milliseconds(120)
        let model = ImportModel(host: host)

        let task = Task { await model.run(arrivalURL) }
        var sawIndeterminate = false
        for _ in 0..<4_000 {
            if model.state.phase == .analyzing, model.progress.isIndeterminate { sawIndeterminate = true; break }
            if model.state.phase == .ready { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await task.value

        #expect(sawIndeterminate, "the analysis phase should report no fraction, not a made-up one")
        #expect(model.progress.fraction == 1)
        #expect(model.progress.phase == .ready)
    }

    @Test("cancelling mid-analysis leaves no partial song behind",
          .enabled(if: arrivalIsAvailable, "Arrival.mp3 is not on this machine"))
    func cancellationLeavesNothing() async throws {
        let libraryURL = makeTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let info = try AudioFileInfo.read(arrivalURL)
        var host = StubImportHost(library: LibraryStore(directoryURL: libraryURL),
                                  report: makeReport(path: arrivalURL.path, duration: info.duration))
        host.analysisHold = .seconds(30)
        let model = ImportModel(host: host)

        model.drop(arrivalURL)
        var reachedAnalysis = false
        for _ in 0..<10_000 {
            if model.state.phase == .analyzing { reachedAnalysis = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(reachedAnalysis)
        #expect(model.state.isCancellable)

        model.cancel()
        await model.waitForCompletion()

        #expect(model.state == .cancelled)
        #expect(model.phaseLog.last == .cancelled)
        #expect(model.draft == nil)
        #expect(model.packageURL == nil)
        #expect(model.promoted.isEmpty)

        // Nothing reached the library: no document, no packages, no record media.
        let store = LibraryStore(directoryURL: libraryURL)
        #expect(!store.exists)
        #expect(try store.songStores().isEmpty)
        let recordMedia = (try? store.storedMedia(kind: .record)) ?? []
        #expect(recordMedia.isEmpty)
    }

    @Test("a promoted region becomes a sample part version with its provenance intact",
          .enabled(if: arrivalIsAvailable, "Arrival.mp3 is not on this machine"))
    func promotedRegionCarriesProvenance() async throws {
        let libraryURL = makeTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        let info = try AudioFileInfo.read(arrivalURL)
        let host = StubImportHost(library: LibraryStore(directoryURL: libraryURL),
                                  report: makeReport(path: arrivalURL.path, duration: info.duration))
        let model = ImportModel(host: host)
        model.provenance = ImportProvenance(title: "Arrival", artist: "Interior Season",
                                            label: "Vessel", year: "2026",
                                            rightsHolder: "Interior Season", note: "own recording",
                                            clearance: .cleared)

        await model.run(arrivalURL)
        let draft = try #require(model.draft)

        let region = try #require(model.range(ofBar: 8))
        let version = try model.promote(region, named: "Bar 9")

        // Provenance: who, from what, by which operation, and out of which seed.
        #expect(version.author == .user)
        #expect(version.operation == Operation.chop)
        #expect(version.parents == [draft.takeVersion.id])
        #expect(version.origin == draft.seed.id)
        #expect(version.partID != draft.takeVersion.partID, "a promoted region is a new part, not a new take")

        // The payload points back at the record it was cut from.
        guard case .sample(let sample) = version.kind else {
            Issue.record("a promoted region should be a .sample part")
            return
        }
        #expect(sample.sourceRecord == draft.record.id)
        #expect(sample.media == draft.record.media)
        #expect(sample.detectedTempo == 96)
        #expect(!sample.slices.isEmpty, "the region should carry the downbeats inside it")
        #expect(sample.slices.allSatisfy { $0.position >= region.start && $0.position < region.end })

        // The citation a clearance sheet and a persona both quote.
        let note = try #require(version.note)
        #expect(note.contains("Interior Season – Arrival (Vessel, 2026)"))

        let clearance = model.provenance.clearanceRecord(for: draft.record.id)
        #expect(clearance.status == .cleared)
        #expect(clearance.record == draft.record.id)
        #expect(clearance.source == "Interior Season – Arrival (Vessel, 2026)")

        // It is in the song, it reached the host, and it auditioned on touch. Both of those are
        // notifications on their own tasks, so give them a turn to land.
        #expect(model.draft?.song.version(version.id) != nil)
        #expect(model.boundVersions.contains(version.id))
        for _ in 0..<500 where host.log.committed.isEmpty || host.log.auditions.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(host.log.committed.map(\.id) == [version.id])
        #expect(host.log.auditions.contains { abs($0.start - region.start) < 0.001 })
    }

    @Test("stem lanes appear as they land and solo wins over mute",
          .enabled(if: arrivalIsAvailable, "Arrival.mp3 is not on this machine"))
    func stemLanesAppearProgressively() async throws {
        let libraryURL = makeTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: libraryURL) }

        // The "stems" are copies of the record: real audio, so the lanes get real durations.
        let stemsDirectory = libraryURL.appendingPathComponent("stems", isDirectory: true)
        try FileManager.default.createDirectory(at: stemsDirectory, withIntermediateDirectories: true)
        var stems: [StemName: URL] = [:]
        for name in [StemName.drums, .bass] {
            let target = stemsDirectory.appendingPathComponent("\(name.rawValue).mp3")
            try? FileManager.default.copyItem(at: arrivalURL, to: target)
            stems[name] = target
        }

        let info = try AudioFileInfo.read(arrivalURL)
        var host = StubImportHost(library: LibraryStore(directoryURL: libraryURL),
                                  report: makeReport(path: arrivalURL.path, duration: info.duration))
        host.stems = stems
        let model = ImportModel(host: host)
        model.separatesStems = true

        await model.run(arrivalURL)

        #expect(model.phaseLog == [.reading, .analyzing, .analyzed, .separating, .writing, .ready])
        #expect(model.stems.map(\.name) == [.bass, .drums])
        #expect(model.stems.allSatisfy { ($0.duration ?? 0) > 0 })
        #expect(model.audibleStems == [.bass, .drums])

        model.toggleSolo(.drums)
        #expect(model.audibleStems == [.drums], "a solo silences everything that is not soloed")
        model.toggleMute(.drums)
        #expect(model.audibleStems.isEmpty)

        // The stems reached the package as their own versions, derived from the take.
        let reloaded = try LibraryStore(directoryURL: libraryURL).load()
        let song = try #require(reloaded.songs.first)
        let stemVersions = song.versions.filter { version in
            if case .audio(let audio) = version.kind { return audio.role == .stem }
            return false
        }
        let take = try #require(song.versions.first { version in
            if case .audio(let audio) = version.kind { return audio.role == .take }
            return false
        })
        #expect(stemVersions.count == 2)
        #expect(stemVersions.allSatisfy { $0.operation == Operation.separate })
        #expect(stemVersions.allSatisfy { $0.parents == [take.id] })
    }
}
