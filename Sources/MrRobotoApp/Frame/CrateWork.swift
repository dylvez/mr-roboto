import Analysis
import Foundation
import Performance
import SongGraph

// The crate: records as raw material on a shelf, each read and separated once, its stems kept
// beside it in the library's `records/` for every song to take from. Importing makes no song. The
// work runs one job at a time in the background, whatever surfaces or songs are opened or closed
// meanwhile — not through `whileBusy`, which is one slot and would refuse an export while a record
// separates.

/// One thing the crate does to one record.
public struct CrateJob: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Copy a file into `records/` and put a row on the shelf.
        case bring
        /// Key, beats and bars, form, loudness and who plays when.
        case analyse
        /// The second beat tracker alone, its beats added to the reading the record has.
        case listen
        /// Its stems' bar levels measured again, against bars its corrected grid reads.
        case measure
        /// The stems a song separated from it, kept beside it too, for every song to take.
        case gather
        /// Its stems, into `records/`, each read for its level.
        case separate
    }

    public let id: UUID
    public var kind: Kind
    /// The record; nil for a file not yet brought in.
    public var record: RecordID?
    /// The file to bring in.
    public var file: URL?
    /// For `gather`: the song holding the stems.
    public var song: SongID?
    public var title: String
    /// For `bring`: whether its separation is queued as well.
    public var separating: Bool

    public init(kind: Kind, record: RecordID? = nil, file: URL? = nil, song: SongID? = nil, title: String, separating: Bool = false) {
        id = UUID()
        self.kind = kind
        self.record = record
        self.file = file
        self.song = song
        self.title = title
        self.separating = separating
    }

    /// What it is, in the header's words.
    var doing: String {
        switch kind {
        case .bring: return "Bringing in \(title)"
        case .analyse: return "Reading \(title)"
        case .listen: return "Listening to \(title) with the second beat tracker"
        case .measure: return "Measuring \(title)'s stems against its new bars"
        case .gather: return "Keeping \(title)'s stems with it"
        case .separate: return "Separating \(title)"
        }
    }
}

/// The crate's queue. Owned by `AppState`; one job at a time, the quick ones first: every file is
/// on the shelf before any is read, and every record is read before any is separated, so the rows,
/// then their keys and tempos, appear as soon as they can.
@MainActor
@Observable
public final class CrateWork {
    public private(set) var waiting: [CrateJob] = []
    public private(set) var running: CrateJob?
    /// The running job's last tick.
    public private(set) var step: ImportStep?
    /// Why a record's last job failed, until it is asked for again.
    public private(set) var failures: [RecordID: String] = [:]
    /// Jobs finished, oldest first: what a test reads.
    public private(set) var finished: [CrateJob] = []

    @ObservationIgnored weak var app: AppState?
    /// Analysis and separation. A test installs a stub here; the app installs `makeHost`, built
    /// the first time a record is read. Without either the crate takes files in and says it cannot
    /// read them.
    @ObservationIgnored public var host: (any ImportHosting)?
    @ObservationIgnored public var makeHost: (() -> any ImportHosting)?

    /// Whether anything here can read or separate a record.
    public var canRead: Bool { host != nil || makeHost != nil }

    private var reader: (any ImportHosting)? {
        if host == nil, let makeHost { host = makeHost() }
        return host
    }
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public var isIdle: Bool { running == nil && waiting.isEmpty }

    /// The header's line: what runs, how far, and how much waits.
    public var line: String? {
        guard let running else { return nil }
        var pieces = [running.doing]
        if let fraction = step?.fraction, running.kind != .bring { pieces.append("\(Int((fraction * 100).rounded()))%") }
        if !waiting.isEmpty { pieces.append("\(waiting.count) more") }
        return pieces.joined(separator: " · ")
    }

    /// What the crate is doing to a record, for its row: nil when nothing.
    public func status(of record: RecordID) -> String? {
        if let running, running.record == record {
            switch running.kind {
            case .bring: return "coming in"
            case .analyse: return "reading…"
            case .listen: return "the second tracker listening…"
            case .measure: return "measuring its stems…"
            case .gather: return "taking its stems…"
            case .separate: return step?.fraction.map { "separating · \(Int(($0 * 100).rounded()))%" } ?? "separating…"
            }
        }
        if let job = waiting.first(where: { $0.record == record }) {
            switch job.kind {
            case .bring, .analyse: return "waiting to be read"
            case .listen: return "waiting for the second tracker"
            case .measure: return "waiting to measure its stems"
            case .gather: return "waiting for its stems"
            case .separate: return "waiting to separate"
            }
        }
        return nil
    }

    /// Whether a job of this kind is queued or running for the record.
    public func isQueued(_ kind: CrateJob.Kind, for record: RecordID) -> Bool {
        running.map { $0.kind == kind && $0.record == record } == true || waiting.contains { $0.kind == kind && $0.record == record }
    }

    // MARK: Asking

    func enqueue(_ job: CrateJob) {
        if let record = job.record {
            // Measuring again is asked after every correction, and one running was measuring
            // against the bars before it: only a waiting one stands for another.
            let asked = job.kind == .measure ? waiting.contains { $0.kind == .measure && $0.record == record } : isQueued(job.kind, for: record)
            guard !asked else { return }
            failures[record] = nil
        }
        waiting.append(job)
        pump()
    }

    /// Takes a record's waiting jobs off the queue and stops the one running, if it is the record's.
    public func cancel(_ record: RecordID) {
        waiting.removeAll { $0.record == record }
        if running?.record == record { task?.cancel() }
    }

    /// Returns once the queue is empty. Tests wait on it; so does a quit that chooses to.
    public func waitUntilIdle() async {
        while let task { await task.value }
    }

    // MARK: Running

    private func pump() {
        guard task == nil, let index = nextIndex() else { return }
        let job = waiting.remove(at: index)
        running = job
        step = nil
        task = Task { [weak self] in
            await self?.run(job)
            guard let self else { return }
            self.finished.append(job)
            self.running = nil
            self.step = nil
            self.task = nil
            self.pump()
        }
    }

    /// A tick from the running job; one that arrives after its job has finished is dropped.
    private func tick(_ step: ImportStep, for job: CrateJob) {
        if running?.id == job.id { self.step = step }
    }

    /// The quickest kind first, oldest first within a kind.
    private func nextIndex() -> Int? {
        for kind in CrateJob.Kind.allCases {
            if let index = waiting.firstIndex(where: { $0.kind == kind }) { return index }
        }
        return nil
    }

    private func run(_ job: CrateJob) async {
        guard let app else { return }
        do {
            switch job.kind {
            case .bring: try await bring(job, app: app)
            case .analyse: try await analyse(job, app: app)
            case .listen: try await listen(job, app: app)
            case .measure: try await measure(job, app: app)
            case .gather: try await gather(job, app: app)
            case .separate: try await separate(job, app: app)
            }
        } catch {
            // A separator may answer a cancel with an error of its own.
            guard !(error is CancellationError), !Task.isCancelled else {
                app.note(.session, "\(job.doing) stopped", detail: "Nothing was kept from it; ask again from its row in the library.")
                return
            }
            let reason = job.kind == .separate ? ImportModel.plain(separationError: error) : "\(error)"
            if let record = job.record { failures[record] = reason }
            app.note(.session, "\(job.doing) failed", detail: reason)
        }
    }

    private func store(_ app: AppState) throws -> LibraryStore {
        guard let store = app.store else { throw CrateError.noLibrary }
        guard app.libraryIsWritable else { throw CrateError.unwritable }
        return store
    }

    /// The file into `records/` by its hash, and a row on the shelf named for it. A file already
    /// there is not brought twice.
    private func bring(_ job: CrateJob, app: AppState) async throws {
        guard let file = job.file else { return }
        let store = try store(app)
        let (media, _) = try await Self.off {
            let info = try AudioFileInfo.read(file)
            return (try store.addMedia(copying: file, kind: .record), info)
        }
        try Task.checkCancellation()
        var library = app.library
        let id: RecordID
        if let existing = library.record(forMedia: media) {
            id = existing.id
            app.note(.session, "\(existing.title) is already in the crate", detail: "\(file.lastPathComponent) is the same audio, so it was not brought in twice.")
        } else {
            let record = Record(title: job.title, media: media)
            library.records.append(record)
            guard app.writeLibrary(library) else { throw CrateError.unwritable }
            id = record.id
            app.note(.session, "\(job.title) is in the crate", detail: "From \(file.path). It is read next\(job.separating ? ", then separated" : "").")
        }
        guard let record = app.library.record(id) else { return }
        if record.analysis == nil { enqueue(CrateJob(kind: .analyse, record: id, title: record.title)) }
        if job.separating, record.stems == nil { enqueue(CrateJob(kind: .separate, record: id, title: record.title)) }
    }

    /// The record read as an import reads it, the analysis kept on its row.
    private func analyse(_ job: CrateJob, app: AppState) async throws {
        guard let id = job.record, let host = reader else { throw CrateError.noReader }
        let store = try store(app)
        guard let record = app.library.record(id) else { return }
        let url = try store.mediaURL(for: record.media)
        let report = try await host.analyze(url) { [weak self] step in
            Task { @MainActor [weak self] in self?.tick(step, for: job) }
        }
        try Task.checkCancellation()
        let info = try await Self.off { try AudioFileInfo.read(url) }
        let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: info.duration)
        let version = PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user, operation: Operation.imported,
                                  note: "analysis of \(record.title)")
        // And how far it sits from concert pitch, so whatever is taken from it is brought to pitch.
        let tuning = (try? await Self.off { try RecordTuning.measure(url) }) ?? 0
        try keep(id, app: app) { $0.analysis = version; $0.tuning = tuning }
        var reading = [analysis.dominantKey?.name, analysis.dominantTempo.map { "\(Int($0.rounded())) bpm" },
                       analysis.bars.isEmpty ? nil : "\(analysis.bars.count) bars", RecordTuning.line(tuning)].compactMap { $0 }
        if let agreement = analysis.beatCheck?.agreement, agreement < 0.8 { reading.append("the two beat trackers disagree") }
        // Read again, a reading can come back different: said, so a grid that was good is not lost unnoticed.
        if let before = record.readingAsRead, AppState.gridLine(before) != AppState.gridLine(analysis) {
            reading.append("it was \(AppState.gridLine(before)) before")
        }
        if let grid = record.grid { reading.append("still read through its correction, \(grid.description)") }
        app.note(.session, "\(record.title) is read", detail: reading.joined(separator: " · "))
    }

    /// Its stems into `records/`, each read for how much of the record it is and where it plays.
    private func separate(_ job: CrateJob, app: AppState) async throws {
        guard let id = job.record, let host = reader else { throw CrateError.noReader }
        let store = try store(app)
        guard let record = app.library.record(id) else { return }
        let url = try store.mediaURL(for: record.media)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrRoboto/Crate/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = try await host.separate(url, into: scratch) { [weak self] step in
            Task { @MainActor [weak self] in self?.tick(step, for: job) }
        } stemDidLand: { _, _ in }
        try Task.checkCancellation()
        // Read again: the analysis may have landed, or been redone, while it separated.
        let bars = app.library.record(id)?.reading?.bars ?? []
        let recordLUFS = app.library.record(id)?.reading?.loudness?.integrated
        let stems = try await Self.off {
            let whole = recordLUFS ?? RecordStems.loudness(of: url)
            return try files.sorted { RecordStems.order($0.key.rawValue) < RecordStems.order($1.key.rawValue) }.map { pair in
                try RecordStems.keep(pair.value, named: pair.key.rawValue, in: store, bars: bars, recordLUFS: whole)
            }
        }
        try Task.checkCancellation()
        guard !stems.isEmpty else { throw CrateError.noStems }
        try keep(id, app: app) { $0.stems = stems }
        app.note(.session, "\(record.title) is separated", detail: RecordStems.line(stems))
    }

    /// The stems a song separated from the record, kept beside it: hard-linked into `records/` where
    /// the disk allows, so they take no more room, and copied where it does not. The song keeps its
    /// own and plays as it did.
    private func gather(_ job: CrateJob, app: AppState) async throws {
        guard let id = job.record, let songID = job.song else { return }
        let store = try store(app)
        guard let record = app.library.record(id) else { throw CrateError.gone }
        guard record.stems == nil else { return }
        guard let song = app.song?.id == songID ? app.song : app.librarySong(songID) else { throw CrateError.gone }
        let found = RecordStems.separated(from: record, in: song)
        guard !found.isEmpty else { throw CrateError.noStemsIn(song.title) }
        let bars = record.reading?.bars ?? []
        let recordLUFS = record.reading?.loudness?.integrated
        let recordMedia = record.media
        let stems = try await Self.off {
            let whole = recordLUFS ?? (try? store.mediaURL(for: recordMedia)).flatMap(RecordStems.loudness(of:))
            return try found.map { stem in
                let file = try store.mediaURL(for: stem.audio.media, song: songID)
                return try RecordStems.keep(stem.audio.media, at: file, named: stem.name, in: store, bars: bars, recordLUFS: whole)
            }
        }
        try Task.checkCancellation()
        try keep(id, app: app) { $0.stems = stems }
        app.note(.session, "\(record.title)'s stems are kept with the record",
                 detail: "From \(song.title): \(RecordStems.line(stems)). Any song can take them now.")
    }

    /// The second tracker's beats added to the record's reading, and how far the two agree; the
    /// first tracker's grid stays exactly as it was read.
    private func listen(_ job: CrateJob, app: AppState) async throws {
        guard let id = job.record, let host = reader else { throw CrateError.noReader }
        let store = try store(app)
        guard let record = app.library.record(id), let read = record.readingAsRead else { return }
        let url = try store.mediaURL(for: record.media)
        guard let (checker, checked) = try await host.checkBeats(url) else { throw CrateError.noSecondTracker }
        try Task.checkCancellation()
        let first = BeatTrackingResult(beats: read.beats.map(\.time), downbeats: read.downbeats, bpm: read.dominantTempo)
        guard let check = BeatCheck.reconcile(primary: first, checker: checker, checked: checked).check, !check.usedChecker else {
            throw CrateError.noSecondTracker
        }
        var heard = read
        heard.beatCheck = BeatGridCheck(checker: check.checker, agreement: check.agreement, primaryBPM: check.primaryBPM,
                                        checkerBPM: check.checkerBPM, usedChecker: false)
        let grid = checked.grid, downbeats = grid.downbeatIndices()
        heard.checkerBeats = grid.beats.enumerated().map { BeatMarker(time: $1, isDownbeat: downbeats.contains($0)) }
        let version = PartVersion(partID: record.analysis?.partID ?? PartID(), kind: .analysis(heard), author: .user,
                                  operation: Operation.imported, note: record.analysis?.note ?? "analysis of \(record.title)")
        try keep(id, app: app) { $0.analysis = version }
        app.note(.session, "\(record.title)'s second beat tracker has listened",
                 detail: String(format: "%.1f bpm against %.1f; %.0f%% of their beats agree. Its grid can be taken from the record's row now.",
                                check.checkerBPM ?? 0, read.dominantTempo ?? 0, (check.agreement ?? 0) * 100))
    }

    /// Changes the record as the library has it now and writes `library.json` alone.
    private func keep(_ id: RecordID, app: AppState, _ change: (inout Record) -> Void) throws {
        var library = app.library
        guard let index = library.records.firstIndex(where: { $0.id == id }) else { throw CrateError.gone }
        change(&library.records[index])
        guard app.writeLibrary(library) else { throw CrateError.unwritable }
    }

    private static func off<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }
}

public enum CrateError: Error, CustomStringConvertible, Equatable {
    case noLibrary
    case unwritable
    case noReader
    case noStems
    case noStemsIn(String)
    case noSecondTracker
    case gone

    public var description: String {
        switch self {
        case .noLibrary: return "This session has no library to keep records in."
        case .unwritable: return "The library could not be read, so nothing is written to it."
        case .noReader: return "Nothing here can read or separate a record."
        case .noStems: return "The separator gave back no stems."
        case .noStemsIn(let title): return "\(title) holds no stems separated from this record."
        case .noSecondTracker: return "There is no second beat tracker here, or it found no beats in this record."
        case .gone: return "The record left the library while it was being worked on."
        }
    }
}

/// How far a record sits from concert pitch, read once from the whole of it (`Tuning`).
enum RecordTuning {
    /// The record's cents above concert pitch; 0 when it is at pitch or has no pitch to read.
    nonisolated static func measure(_ url: URL) throws -> Double {
        let (planar, rate) = try BoothAdapter.planar(url)
        return Tuning.read(ChopAudio.mono(planar), sampleRate: rate)?.cents ?? 0
    }

    /// "28 cents flat of concert pitch", or nil for a record near enough to pitch to leave alone.
    static func line(_ cents: Double?) -> String? {
        guard let cents, abs(cents) >= SourceFitting.leastCents else { return nil }
        return String(format: "%.0f cents %@ of concert pitch", abs(cents), cents > 0 ? "sharp" : "flat")
    }
}

/// A record's stems as the crate keeps them.
enum RecordStems {
    /// The usual order: the voice, the drums, the bass, the rest.
    static func order(_ name: String) -> Int { ["vocals", "drums", "bass", "other"].firstIndex(of: name) ?? 9 }

    /// Below this a bar is silence: its level is kept as this.
    static let floorDB = -90.0

    /// A stem file into `records/`, read for its loudness, its share of the record and its level
    /// in each bar. Blocking.
    static func keep(_ file: URL, named name: String, in store: LibraryStore, bars: [SongGraph.TimeRange], recordLUFS: Double?) throws -> RecordStem {
        try measure(try store.addMedia(copying: file, kind: .record), file: file, named: name, bars: bars, recordLUFS: recordLUFS)
    }

    /// A stem a song already holds, into `records/` under the name it already has: a hard link to
    /// the song's file, or a copy where the two are on different disks. Blocking.
    static func keep(_ media: MediaRef, at file: URL, named name: String, in store: LibraryStore, bars: [SongGraph.TimeRange],
                     recordLUFS: Double?) throws -> RecordStem {
        let target = store.recordsDirectoryURL.appendingPathComponent(media.fileName)
        if !FileManager.default.fileExists(atPath: target.path), file.standardizedFileURL != target.standardizedFileURL {
            try FileManager.default.createDirectory(at: store.recordsDirectoryURL, withIntermediateDirectories: true)
            do { try FileManager.default.linkItem(at: file, to: target) } catch { try FileManager.default.copyItem(at: file, to: target) }
        }
        return try measure(media, file: target, named: name, bars: bars, recordLUFS: recordLUFS)
    }

    private static func measure(_ media: MediaRef, file: URL, named name: String, bars: [SongGraph.TimeRange], recordLUFS: Double?) throws -> RecordStem {
        let (planar, rate) = try BoothAdapter.planar(file)
        let frames = planar.first?.count ?? 0
        let measured = MixMeter.integratedLoudness(planar, sampleRate: rate)
        let lufs = measured.isFinite ? (measured * 10).rounded() / 10 : nil
        let relative = lufs.flatMap { stem in recordLUFS.map { ((stem - $0) * 10).rounded() / 10 } }
        return RecordStem(name: name, media: media, sampleRate: rate, channelCount: planar.count,
                          duration: rate > 0 ? Double(frames) / rate : 0, lufs: lufs, relativeDB: relative,
                          barLevels: bars.isEmpty ? nil : levels(planar, sampleRate: rate, bars: bars))
    }

    /// The stems a song separated from this record, newest of each name: separated from its take,
    /// not pulled in from elsewhere.
    static func separated(from record: Record, in song: Song) -> [(name: String, audio: Audio)] {
        let seeds = Set(song.seeds.compactMap { seed -> SeedID? in
            if case .importedRecord(let id) = seed.kind, id == record.id { return seed.id }
            return nil
        })
        let takes = song.versions.filter { version in
            guard let audio = Guidance.audio(of: version), audio.role == .take else { return false }
            return audio.media == record.media || version.origin.map(seeds.contains) == true
        }
        let takeIDs = Set(takes.map(\.id)), takeSeeds = Set(takes.compactMap(\.origin))
        var newest: [String: Audio] = [:]
        for version in song.versions where version.operation == Operation.separate {
            guard let audio = Guidance.audio(of: version), audio.role == .stem, audio.fit == nil, let name = audio.stem,
                  version.parents.contains(where: takeIDs.contains) || version.origin.map(takeSeeds.contains) == true else { continue }
            newest[name] = audio
        }
        return newest.sorted { order($0.key) < order($1.key) }.map { ($0.key, $0.value) }
    }

    /// RMS of each bar across the channels, dBFS to a tenth, `floorDB` for silence.
    static func levels(_ planar: [[Float]], sampleRate: Double, bars: [SongGraph.TimeRange]) -> [Double] {
        let frames = planar.first?.count ?? 0
        return bars.map { bar in
            let lower = max(0, min(frames, Int(bar.start * sampleRate))), upper = max(lower, min(frames, Int(bar.end * sampleRate)))
            guard upper > lower else { return floorDB }
            var sum = 0.0
            for lane in planar { for i in lower..<upper { sum += Double(lane[i] * lane[i]) } }
            let rms = (sum / Double((upper - lower) * max(1, planar.count))).squareRoot()
            return rms > 0 ? max(floorDB, (20 * log10(rms) * 10).rounded() / 10) : floorDB
        }
    }

    /// The whole record's loudness, when its analysis did not read it.
    static func loudness(of url: URL) -> Double? {
        guard let (planar, rate) = try? BoothAdapter.planar(url) else { return nil }
        let lufs = MixMeter.integratedLoudness(planar, sampleRate: rate)
        return lufs.isFinite ? lufs : nil
    }

    /// "vocals −1.8 dB · drums −9.0 dB · bass −11.2 dB · other −4.1 dB": how much of the record each is.
    static func line(_ stems: [RecordStem]) -> String {
        stems.map { stem in
            stem.relativeDB.map { String(format: "%@ %+.1f dB", stem.name, $0) } ?? (stem.lufs == nil ? "\(stem.name) silent" : stem.name)
        }.joined(separator: " · ")
    }

    /// The first bar where a stem plays at something like its usual level: within 10 dB of its
    /// loudest bars and held for the bar. Nil when it never does.
    static func firstPlayedBar(_ levels: [Double]) -> Int? {
        let sorted = levels.filter { $0 > floorDB }.sorted()
        guard !sorted.isEmpty else { return nil }
        let typical = sorted[Int(Double(sorted.count - 1) * 0.75)]
        return levels.firstIndex { $0 >= typical - 10 }
    }
}

/// Each crate stem's level bar by bar, by its media: what `Guidance.barToChop` reads to open a chop
/// on a bar the stem actually plays in. The frame adds to it whenever its library changes; process
/// wide, as the kits are. Only ever added to: media is named by its content, so an entry cannot go
/// stale, and a library read elsewhere cannot take one away from under a chop.
enum StemPresenceIndex {
    private nonisolated(unsafe) static var levels: [MediaRef: [Double]] = [:]
    private static let lock = NSLock()

    static func remember(_ library: Library) {
        let found = library.records.flatMap { $0.stems ?? [] }.compactMap { stem in stem.barLevels.map { (stem.media, $0) } }
        guard !found.isEmpty else { return }
        lock.withLock { for (media, bars) in found { levels[media] = bars } }
    }

    static func levels(of media: MediaRef) -> [Double]? { lock.withLock { levels[media] } }
}

extension AppState {

    /// Files into the crate: each copied into the library and given a row, then read, then — when
    /// asked — separated, one at a time in the background. No song is made.
    @discardableResult
    public func importRecords(_ files: [URL], separating: Bool) -> Int {
        guard store != nil else {
            note(.session, "Nowhere to keep records", detail: CrateError.noLibrary.description)
            return 0
        }
        for file in files {
            crate.enqueue(CrateJob(kind: .bring, file: file, title: file.deletingPathExtension().lastPathComponent, separating: separating))
        }
        if !files.isEmpty {
            note(.you, files.count == 1 ? "Importing \(files[0].lastPathComponent) into the crate" : "Importing \(files.count) records into the crate",
                 detail: separating ? "Each is read, then separated, in the background; the header says how far." : "Each is read in the background; separate one from its row when you want its stems.")
        }
        return files.count
    }

    /// A record in the crate read again, or for the first time.
    public func analyseRecord(_ id: RecordID) {
        guard let record = library.record(id) else { return }
        crate.enqueue(CrateJob(kind: .analyse, record: id, title: record.title))
    }

    /// A record in the crate called something else: its row, Sources and the band say the new name.
    /// Sources already fitted from it keep the name they were fitted under.
    @discardableResult
    public func renameRecord(_ id: RecordID, to title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let record = library.record(id), record.title != name else { return false }
        var updated = library
        guard let index = updated.records.firstIndex(where: { $0.id == id }) else { return false }
        updated.records[index].title = name
        guard writeLibrary(updated) else { return false }
        note(.you, "Renamed \(record.title) to \(name)")
        return true
    }

    /// A name for a record whose title is still its file's: the song first made from it, when that
    /// was called something else.
    public func suggestedName(for id: RecordID) -> String {
        guard let record = library.record(id) else { return "" }
        let made = library.songs.first { song in
            song.seeds.contains { if case .importedRecord(id) = $0.kind { return true }; return false }
                || Guidance.take(in: song).flatMap(Guidance.audio(of:))?.media == record.media
        }
        return made.map(\.title).flatMap { $0 == record.title ? nil : $0 } ?? record.title
    }

    /// The second beat tracker on a record read before its beats were kept, its reading kept.
    public func listenForSecondTracker(_ id: RecordID) {
        guard let record = library.record(id), record.readingAsRead != nil else { return }
        crate.enqueue(CrateJob(kind: .listen, record: id, title: record.title))
    }

    /// A record in the crate separated, its stems kept beside it.
    public func separateRecord(_ id: RecordID) {
        guard let record = library.record(id) else { return }
        crate.enqueue(CrateJob(kind: .separate, record: id, title: record.title))
    }

    /// The songs holding stems separated from a record that has none of its own: where they can
    /// be taken from. The open song's copy is read for the open song.
    public func songsHoldingStems(of id: RecordID) -> [Song] {
        guard let record = library.record(id), record.stems == nil else { return [] }
        return library.songs.compactMap { listed in
            let current = song?.id == listed.id ? song! : listed
            return RecordStems.separated(from: record, in: current).isEmpty ? nil : current
        }
    }

    /// A record's stems taken from a song that separated them, so every song can take them.
    public func gatherStems(of id: RecordID, from songID: SongID) {
        guard let record = library.record(id), record.stems == nil else { return }
        crate.enqueue(CrateJob(kind: .gather, record: id, song: songID, title: record.title))
    }

    /// A record read before tunings were kept is measured the first time something is taken from
    /// it, and the reading kept on its row.
    func tuneIfUnmeasured(_ origin: SourceOrigin) async {
        guard case .record(let id) = origin, let record = library.record(id), record.tuning == nil, record.reading != nil,
              let url = try? store?.mediaURL(for: record.media) else { return }
        let cents = (try? await Task.detached(priority: .userInitiated) { try RecordTuning.measure(url) }.value) ?? 0
        var updated = library
        guard let index = updated.records.firstIndex(where: { $0.id == id }), updated.records[index].tuning == nil else { return }
        updated.records[index].tuning = cents
        _ = writeLibrary(updated)
    }
}
