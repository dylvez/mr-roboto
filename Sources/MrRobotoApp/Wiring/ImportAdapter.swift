import AVFAudio
import Analysis
import Foundation
import Instrument
import SongGraph

/// `AppState` seen through `ImportHosting`.
///
/// The long work — Music Understanding, Demucs, the library store — is `LiveImportHost`'s and is
/// delegated to it unchanged. Two things are the wiring's:
///
/// * **auditioning** goes to the shared `AuditionService` rather than to `LiveImportHost`'s own
///   private `AVAudioEngine`, so the app has one graph rather than one per surface. The span is
///   read off the main actor and handed over as floats.
/// * **`didCommit`** is the hand-off. A promoted region is a real part version, so it goes into the
///   parts ledger through `AppState.record(_:)` (which is also what writes the rail's line), and
///   then the Chop lane opens on it — the first half of the Gate A workflow.
struct ImportAdapter: ImportHosting {

    private let app: AppState
    private let live: LiveImportHost
    private let service: AuditionService

    /// The longest span an audition will read. Auditioning is a check on a region, not playback of
    /// a record; a drag across four minutes of a track is a mistake, not a request.
    static let maximumAuditionSeconds: Double = 30

    init(app: AppState, service: AuditionService, live: LiveImportHost) {
        self.app = app
        self.live = live
        self.service = service
    }

    var library: LibraryStore { live.library }

    func analyze(_ url: URL, progress: @escaping @Sendable (ImportStep) -> Void) async throws -> AnalysisReport {
        try await live.analyze(url, progress: progress)
    }

    func separate(_ url: URL, into directory: URL,
                  progress: @escaping @Sendable (ImportStep) -> Void,
                  stemDidLand: @escaping @Sendable (StemName, URL) -> Void) async throws -> [StemName: URL] {
        try await live.separate(url, into: directory, progress: progress, stemDidLand: stemDidLand)
    }

    func audition(_ url: URL, from start: Double, to end: Double) async {
        let span = min(max(0, end - start), Self.maximumAuditionSeconds)
        guard span > 0 else { return }
        guard let region = try? await Task.detached(priority: .userInitiated, operation: {
            try AudioRegion.read(url, from: start, to: start + span)
        }).value else { return }
        await service.play(planar: region.planar, sampleRate: region.sampleRate)
    }

    func stopAudition() async {
        await service.stop()
    }

    /// A promoted region left the surface. It reaches the ledger here, and the Chop lane opens on it.
    func didCommit(_ version: PartVersion, in song: Song) async {
        await app.adoptPromotedRegion(version, from: song)
    }

    /// The library read again, so the record and the song are in the frame's copy of it, and the
    /// song opened — the song you imported is the one you want to work in.
    func didFinishImport(_ song: SongID) async {
        await MainActor.run {
            app.reloadLibrary()
            if app.song?.id != song { app.openSong(song) }
        }
    }

    func isOpen(_ song: SongID) async -> Bool {
        await MainActor.run { app.song?.id == song }
    }

    /// The provenance form was kept. The record row is library-level and goes to `library.json`
    /// whichever song is open. The seed lives in the song: when that song is the one the frame has
    /// open, the frame's copy is the truth — it may hold versions the package does not yet — so
    /// the seed changes there, the way a title does, and the frame saves it. Otherwise the package
    /// on disk is the only copy and is written directly.
    ///
    /// The frame's library is a mirror of the disk, replaced wholesale rather than edited, so it is
    /// re-read afterwards and the sidebar shows the row as kept.
    func keepProvenance(_ record: Record, seed: Seed, in song: Song) async throws {
        let library = live.library
        if await app.adoptKeptSeed(seed, of: song.id) {
            try await Task.detached(priority: .userInitiated) {
                try ProvenanceWriter.write(record, seed: seed, in: song, savingPackage: false, to: library)
            }.value
        } else {
            try await live.keepProvenance(record, seed: seed, in: song)
        }
        await app.reloadLibrary()
    }
}

extension AppState {

    /// The frame's half of keeping a provenance form: the seed on the open song. True when that
    /// song is open and took it — the frame marks the song unsaved and saves it — and false when
    /// it is not open, in which case the package on disk is the only copy and the surface writes
    /// it.
    @discardableResult
    func adoptKeptSeed(_ seed: Seed, of songID: SongID) -> Bool {
        guard song?.id == songID else { return false }
        updateSong { open in
            if let index = open.seeds.firstIndex(where: { $0.id == seed.id }) {
                open.seeds[index] = seed
            } else {
                open.seeds.append(seed)
            }
        }
        return true
    }
}

extension AppState {

    /// The Import → Chop lane hand-off, in one place so the test can name it.
    ///
    /// `ImportModel` appends the promoted version to the *draft's* song, which is the song the
    /// import itself created; the frame's song is whatever is open. When the two are the same the
    /// version is already there and only needs selecting, otherwise it is recorded. Either way, a
    /// sample that made it into the ledger opens a Chop lane bound to it — promoting a bar and
    /// chopping it is one gesture, not two.
    @discardableResult
    func adoptPromotedRegion(_ version: PartVersion, from song: Song) -> SurfaceID? {
        // The import's song is not the one open any more: the work lands in its own song.
        if let open = self.song, open.id != song.id, library.song(song.id) != nil {
            record(version, intoLibrarySong: song.id)
            return nil
        }
        let landed: Bool
        if self.song?.version(version.id) != nil {
            select(version.id)
            landed = true
        } else {
            landed = record(version)
        }
        guard landed, case .sample = version.kind else { return nil }
        let title = version.note.map { String($0.prefix(60)) } ?? "Promoted region"
        return openSurface(.chopLane, title: title, bound: [version.id])
    }
}

/// Reading a span of an audio file as planar floats, off the main actor.
///
/// Separate from `ImportWaveform` (which reads peaks for drawing) and from `ChopAudio.readPlanar`
/// (which reads a whole file): an audition wants the samples of one region and nothing else, so a
/// four-minute record is never decoded to hear four bars of it.
enum AudioRegion {
    struct Span: Sendable {
        var planar: [[Float]]
        var sampleRate: Double
    }

    static func read(_ url: URL, from start: Double, to end: Double) throws -> Span {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return Span(planar: [], sampleRate: rate) }

        let total = Double(file.length) / rate
        let from = min(max(0, start), total)
        let to = min(max(from, end), total)
        let frames = AVAudioFrameCount(max(0, ((to - from) * rate).rounded()))
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0,
              let scratch = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: min(frames, 1 << 16)) else {
            return Span(planar: [], sampleRate: rate)
        }
        file.framePosition = AVAudioFramePosition((from * rate).rounded())

        // Read in chunks rather than in one call. `SampleCache` carries the measurement: a single
        // `read(into:frameCount:)` stops on an internal block boundary without throwing, so up to a
        // block goes missing from the end — inaudible on a decayed one-shot, audible on a bar whose
        // last slice ends exactly where the region does. The loop is here rather than in
        // `SampleCache.readAll` because that one fills a buffer sized to the rest of the file and a
        // region is a *span*: it must stop at `frames`, not at EOF.
        var planar = Array(repeating: [Float](), count: channels)
        for channel in 0..<channels { planar[channel].reserveCapacity(Int(frames)) }
        var filled: AVAudioFrameCount = 0
        while filled < frames {
            scratch.frameLength = 0
            try file.read(into: scratch, frameCount: min(frames - filled, scratch.frameCapacity))
            let produced = Int(scratch.frameLength)
            guard produced > 0, let data = scratch.floatChannelData else { break }
            let stride = scratch.stride
            for channel in 0..<channels {
                for frame in 0..<produced { planar[channel].append(data[channel][frame * stride]) }
            }
            filled += AVAudioFrameCount(produced)
        }
        return Span(planar: planar, sampleRate: rate)
    }
}
