import AVFAudio
import Analysis
import AnalysisONNX
import Foundation
import SongGraph

// The Import surface's contract with whatever is hosting it.
//
// The frame and its `AppState` are being built alongside this surface, so the surface does not name
// them: it names the four things it actually needs — analysis, separation, a library to write into,
// and something that makes noise — and takes them as one small protocol. A stub of this protocol is
// all a test needs, and `LiveImportHost` is the one the app installs.

// MARK: - Progress

/// One honest progress tick from a long job.
///
/// `fraction` is optional on purpose. Music Understanding runs one ~20 s pass and reports nothing
/// while it does; a bar that invents a number for that is a lie, so the surface shows an
/// indeterminate bar with the elapsed time instead. Demucs *does* report, so separation has a real
/// fraction. Nothing here rounds a guess up to look busy.
public struct ImportStep: Sendable, Equatable {
    /// 0…1 within the step, or nil when the step genuinely cannot say.
    public var fraction: Double?
    /// What is happening, in words: "key", "htdemucs: separating", "writing vocals.wav".
    public var detail: String

    public init(fraction: Double? = nil, detail: String) {
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.detail = detail
    }
}

/// What the Import surface needs from its host.
///
/// Everything long is `async` and runs off the main actor; every long call honours task
/// cancellation, because the surface's cancel button is a cancelled task and nothing else.
public protocol ImportHosting: Sendable {
    /// Where song packages and record media go.
    var library: LibraryStore { get }

    /// Whole-track analysis: key, beats and downbeats, sections, instrument activity, loudness.
    func analyze(_ url: URL, progress: @escaping @Sendable (ImportStep) -> Void) async throws -> AnalysisReport

    /// Stem separation into `directory`. `stemDidLand` fires as each stem file is written, so the
    /// surface can show a lane the moment it exists rather than all four at the end.
    func separate(_ url: URL, into directory: URL,
                  progress: @escaping @Sendable (ImportStep) -> Void,
                  stemDidLand: @escaping @Sendable (StemName, URL) -> Void) async throws -> [StemName: URL]

    /// Play a region of a file. Every touch in this surface auditions; nothing waits for an agent.
    func audition(_ url: URL, from start: Double, to end: Double) async

    /// Silence whatever is auditioning.
    func stopAudition() async

    /// A new part version left the surface. The frame's parts ledger wants to know.
    func didCommit(_ version: PartVersion, in song: Song) async

    /// The import is on disk: the record in the library, its song in a package. The frame reads
    /// the library again and opens the song. It used to learn of neither — the song was not in the
    /// sidebar until Reload Library, and the next save of the open song dropped the record.
    func didFinishImport(_ song: SongID) async

    /// Whether the frame has this song open, and so owns its package: the surface then leaves the
    /// saving to the frame rather than writing an older copy over it.
    func isOpen(_ song: SongID) async -> Bool

    /// The provenance form was kept. `record` is the library row with its title and artist as the
    /// form has them; `seed` is the song's seed with the whole form in its note; `song` is the
    /// draft's song holding that seed. The host writes them where the library keeps them.
    func keepProvenance(_ record: Record, seed: Seed, in song: Song) async throws
}

extension ImportHosting {
    public func stopAudition() async {}
    public func didCommit(_ version: PartVersion, in song: Song) async {}
    public func didFinishImport(_ song: SongID) async {}
    public func isOpen(_ song: SongID) async -> Bool { false }

    /// Straight to `library`: the row into `library.json`, the seed into the song's package. The
    /// app's host does the second half through the frame instead, because the frame may hold the
    /// song open with versions the package does not have yet.
    public func keepProvenance(_ record: Record, seed: Seed, in song: Song) async throws {
        let library = self.library
        try await Task.detached(priority: .userInitiated) {
            try ProvenanceWriter.write(record, seed: seed, in: song, savingPackage: true, to: library)
        }.value
    }
}

/// The two files a kept provenance form touches, and nothing else.
///
/// `LibraryStore.save(_:)` rewrites every song package from whatever copy it is handed, which for
/// a form edit is a lot of disk for two fields and a real chance of putting a stale copy of an open
/// song over a fresher one. So the row goes through `saveDocument`, which writes `library.json`
/// alone, and the seed goes through the one package that holds it.
public enum ProvenanceWriter {
    /// Blocking; callers run it off the main actor.
    /// - Parameter savingPackage: false when the song is open in the frame, which then owns the
    ///   package and saves the seed itself.
    public static func write(_ record: Record, seed: Seed, in song: Song, savingPackage: Bool, to library: LibraryStore) throws {
        // The document alone, not every song: a song this build cannot read must not stop a form
        // from being kept, and nothing here writes a song but the one named.
        var document = library.exists ? try library.loadDocumentOnly() : Library()
        if let index = document.records.firstIndex(where: { $0.id == record.id }) {
            document.records[index] = record
        } else {
            document.records.append(record)
        }
        if savingPackage {
            var kept = song
            if let index = kept.seeds.firstIndex(where: { $0.id == seed.id }) {
                kept.seeds[index] = seed
            } else {
                kept.seeds.append(seed)
            }
            try library.songStore(for: song.id).save(kept)
        }
        try library.saveDocument(document)
    }
}

// MARK: - Errors

public enum ImportHostError: Error, CustomStringConvertible, Sendable {
    case notAudio(path: String, reason: String)
    case emptyFile(path: String)

    public var description: String {
        switch self {
        case .notAudio(let path, let reason): return "could not open \(path) as audio: \(reason)"
        case .emptyFile(let path): return "\(path) has no audio in it"
        }
    }
}

/// Sample rate, channels and duration without decoding the file.
public struct AudioFileInfo: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public var duration: Double

    public init(sampleRate: Double, channelCount: Int, duration: Double) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
    }

    /// Reads the header only. Cheap enough for the drop handler, but still not on the main actor.
    public static func read(_ url: URL) throws -> AudioFileInfo {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat
            guard file.length > 0, format.sampleRate > 0 else { throw ImportHostError.emptyFile(path: url.path) }
            return AudioFileInfo(sampleRate: format.sampleRate,
                                 channelCount: Int(format.channelCount),
                                 duration: Double(file.length) / format.sampleRate)
        } catch let error as ImportHostError {
            throw error
        } catch {
            throw ImportHostError.notAudio(path: url.path, reason: error.localizedDescription)
        }
    }
}

// MARK: - The live host

/// The host the app installs: Music Understanding through the provider registry, Demucs on MLX for
/// stems, an `AVAudioEngine` for auditioning, and a `LibraryStore` for the package.
///
/// The registry is `AnalysisProviders.app()`, built the same way `m0` builds it, so the app and the
/// CLI analyse a file with exactly the same providers — and the band separates with the same Demucs.
public struct LiveImportHost: ImportHosting {
    public let library: LibraryStore
    private let providers: AnalysisProviders
    private let auditioner: RegionAuditioner

    public init(library: LibraryStore, providers: AnalysisProviders? = nil) {
        self.library = library
        self.providers = providers ?? .app()
        auditioner = RegionAuditioner()
    }

    /// The capabilities are asked for one at a time rather than through `AnalysisProviders.analyze`
    /// so the surface can say which one is running. `MusicUnderstandingProvider` caches per file and
    /// its first call runs the whole pass, so this is still one ~20 s analysis, not five.
    /// The provider name the second beat tracker is registered under.
    public static let beatChecker = BeatThisTracker.name

    public func analyze(_ url: URL, progress: @escaping @Sendable (ImportStep) -> Void) async throws -> AnalysisReport {
        var report = AnalysisReport(sourcePath: url.path)
        let start = ContinuousClock.now

        // The second beat tracker listens alongside Music Understanding's pass, which it is much
        // shorter than, so checking the grid adds no wait. It is anything registered for beats as
        // `beatChecker` other than the selected tracker; a missing model is a check not made.
        let checker = providers.selection[.beats] == Self.beatChecker ? nil
            : providers.provider(named: Self.beatChecker, for: .beats) as? any BeatTracker
        let checking = checker.map { tracker in
            Task.detached(priority: .utility) { () -> Result<BeatTrackingResult, Error> in
                do { return .success(try await tracker.trackBeats(url: url)) } catch { return .failure(error) }
            }
        }
        defer { checking?.cancel() }

        // No fraction for the first call: that is where the one pass happens and nothing reports
        // from inside it.
        progress(ImportStep(detail: "Music Understanding: listening to the whole track"))

        let steps: [(AnalysisCapability, String)] = [
            (.key, "key"), (.beats, "beats and downbeats"), (.structure, "form"),
            (.loudness, "loudness"), (.instrumentActivity, "instrument activity"),
        ]
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            let (capability, label) = step
            var provider: (any AnalysisProvider)?
            // Each reading on its own: one that finds nothing — no key in a drum break, no form in a
            // two-bar loop — is a reading the record lacks, not a failed import. A single missing
            // reading used to throw away the other four and fail the import every time it was tried.
            do {
                switch capability {
                case .key:
                    if let p = try? providers.keyEstimator() { report.key = try await p.estimateKey(url: url); provider = p }
                case .beats:
                    if let p = try? providers.beatTracker() { report.beats = try await p.trackBeats(url: url); provider = p }
                case .structure:
                    if let p = try? providers.structureAnalyzer() { report.structure = try await p.analyzeStructure(url: url); provider = p }
                case .loudness:
                    if let p = try? providers.loudnessMeter() { report.loudness = try await p.measureLoudness(url: url); provider = p }
                case .instrumentActivity:
                    if let p = try? providers.instrumentActivityAnalyzer() {
                        report.instruments = try await p.analyzeInstrumentActivity(url: url)
                        provider = p
                    }
                default:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                report.notes.append("no \(label) found: \(error)")
            }
            if capability == .beats, let checker, let checking {
                switch await checking.value {
                case .success(let checked):
                    let (beats, check) = BeatCheck.reconcile(primary: report.beats, checker: checker.providerName, checked: checked)
                    report.beats = beats
                    report.beatCheck = check
                    if check?.usedChecker == true {
                        provider = checker
                        report.notes.append("\(checker.providerName) supplied the beat grid: the selected tracker found none")
                    }
                case .failure(let error):
                    report.notes.append("no second opinion on the beats: \(error)")
                }
            }
            if let provider {
                report.capabilities.insert(capability)
                report.provenance[capability] = provider.providerName
            } else if !report.notes.contains(where: { $0.hasPrefix("no \(label) found") }) {
                report.notes.append("no provider for \(capability.rawValue)")
            }
            // Only now is a fraction honest: a capability is either done or it is not.
            progress(ImportStep(fraction: Double(index + 1) / Double(steps.count), detail: label))
        }

        if report.duration == nil, let info = try? AudioFileInfo.read(url) { report.duration = info.duration }
        let elapsed = start.duration(to: .now)
        report.wallTime = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return report
    }

    public func separate(_ url: URL, into directory: URL,
                         progress: @escaping @Sendable (ImportStep) -> Void,
                         stemDidLand: @escaping @Sendable (StemName, URL) -> Void) async throws -> [StemName: URL] {
        let separator = try providers.stemSeparator()
        let options = StemSeparationOptions(outputDirectory: directory)
        let result = try await separator.separate(.file(url), options: options) { fraction in
            progress(ImportStep(fraction: fraction, detail: "separating"))
        }
        var written: [StemName: URL] = [:]
        for stem in result.stems {
            guard let fileURL = stem.fileURL else { continue }
            written[stem.name] = fileURL
            stemDidLand(stem.name, fileURL)
        }
        progress(ImportStep(fraction: 1, detail: "\(written.count) stems"))
        return written
    }

    public func audition(_ url: URL, from start: Double, to end: Double) async {
        await auditioner.play(url, from: start, to: end)
    }

    public func stopAudition() async {
        await auditioner.stop()
    }
}

// MARK: - Auditioning

/// Plays a span of a file through its own `AVAudioEngine`.
///
/// Deliberately separate from the transport `Engine`: auditioning a dropped record is not a
/// performance, it must not stop or reschedule whatever the transport is doing, and it has to work
/// before a song even exists. Every failure is swallowed — an audition that cannot start is a quiet
/// surface, never a crash, and a machine with no output device (a test runner) is one of those.
public actor RegionAuditioner {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false

    public init() {}

    public func play(_ url: URL, from start: Double, to end: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return }

        let total = Double(file.length) / rate
        let from = min(max(0, start), total)
        let to = min(max(from, end), total)
        let startFrame = AVAudioFramePosition(from * rate)
        let frames = AVAudioFrameCount(max(0, (to - from) * rate))
        guard frames > 0 else { return }

        if !attached {
            engine.attach(player)
            attached = true
        }
        player.stop()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else { return }
        }
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
        player.play()
    }

    public func stop() {
        guard attached else { return }
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}
