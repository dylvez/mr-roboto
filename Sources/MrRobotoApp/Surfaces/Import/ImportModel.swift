import Analysis
import Foundation
import MusicTheory
import SongGraph

// MARK: - Surface identity

/// The Import surface's entry in the catalog. A plain value: the state lives on `ImportModel`, and
/// the model's state lives in the song graph, which is the surface rule this file exists to obey.
public struct ImportSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .importRecord }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Import") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

// MARK: - State

/// Where an import is. One case per thing that can be on screen, so the view never has to infer a
/// phase from a pile of optionals.
public enum ImportPhase: String, Sendable, Hashable, CaseIterable {
    case empty, reading, analyzing, analyzed, separating, writing, ready, cancelled, failed
}

public enum ImportState: Sendable, Equatable {
    /// The drop target.
    case empty
    /// Reading the header and the waveform.
    case reading(URL)
    /// Whole-track analysis; long, cancellable, no honest fraction for most of it.
    case analyzing(URL)
    /// The record is described: key, tempo, bars, sections, activity, loudness are on screen.
    case analyzed(URL)
    /// Stems are arriving one at a time.
    case separating(URL)
    /// Writing the package. Short, and the one step that is not cancellable.
    case writing(URL)
    /// A song package exists on disk.
    case ready(SongID)
    case cancelled
    case failed(String)

    public var phase: ImportPhase {
        switch self {
        case .empty: return .empty
        case .reading: return .reading
        case .analyzing: return .analyzing
        case .analyzed: return .analyzed
        case .separating: return .separating
        case .writing: return .writing
        case .ready: return .ready
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
    }

    /// True while the cancel button does something. The write is excluded: it is a single atomic
    /// save and a cancel there could only produce the half-written package this surface promises
    /// never to leave behind.
    public var isCancellable: Bool {
        switch self {
        case .reading, .analyzing, .separating: return true
        default: return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .reading, .analyzing, .separating, .writing: return true
        default: return false
        }
    }
}

/// What the progress bar is allowed to claim.
public struct ImportProgress: Sendable, Equatable {
    public var phase: ImportPhase
    /// 0…1 across the whole import, or nil when the running step cannot honestly say.
    public var fraction: Double?
    public var detail: String
    /// Seconds since the import began.
    public var elapsed: Double

    public init(phase: ImportPhase = .empty, fraction: Double? = nil, detail: String = "", elapsed: Double = 0) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
        self.elapsed = elapsed
    }

    /// True when the bar has to spin rather than fill.
    public var isIndeterminate: Bool { fraction == nil }
}

// MARK: - Provenance and clearance

/// Where a record came from and whether it may be used.
///
/// Sampling is the point of this app, so a record that cannot say where it came from is a liability
/// the album milestone inherits. The fields are filled on import, while the answer is still in front
/// of whoever dropped the file, not chased down a year later.
public struct ImportProvenance: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var label: String
    public var year: String
    public var rightsHolder: String
    public var note: String
    public var clearance: ClearanceStatus

    public init(title: String = "", artist: String = "", label: String = "", year: String = "",
                rightsHolder: String = "", note: String = "", clearance: ClearanceStatus = .uncleared) {
        self.title = title
        self.artist = artist
        self.label = label
        self.year = year
        self.rightsHolder = rightsHolder
        self.note = note
        self.clearance = clearance
    }

    /// "Artist – Title (Label, 1974)" — the one line a clearance letter, a sleeve note and a persona
    /// all quote. Empty fields drop out rather than leaving punctuation behind.
    public var citation: String {
        let head = [artist, title].filter { !$0.isEmpty }.joined(separator: " – ")
        let tail = [label, year].filter { !$0.isEmpty }.joined(separator: ", ")
        if head.isEmpty && tail.isEmpty { return "" }
        if tail.isEmpty { return head }
        if head.isEmpty { return "(\(tail))" }
        return "\(head) (\(tail))"
    }

    public var isEmpty: Bool { citation.isEmpty && rightsHolder.isEmpty && note.isEmpty }

    /// The album-level clearance record this record implies. `SongGraph` keeps clearances on
    /// `Album`, which the album milestone builds; until then the surface carries the value so
    /// nothing has to be re-entered when it does.
    public func clearanceRecord(for record: RecordID?) -> SampleClearance {
        SampleClearance(source: citation.isEmpty ? "unidentified source" : citation,
                        status: clearance,
                        record: record,
                        note: [rightsHolder.isEmpty ? nil : "rights: \(rightsHolder)",
                               note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: "; ").nilIfEmpty)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Stems

/// One separated stem as a lane in the surface.
public struct StemLane: Identifiable, Sendable, Equatable {
    public var name: StemName
    public var url: URL
    public var isSoloed: Bool
    public var isMuted: Bool
    /// The stem's own duration, once its header has been read.
    public var duration: Double?

    public var id: String { name.rawValue }

    public init(name: StemName, url: URL, isSoloed: Bool = false, isMuted: Bool = false, duration: Double? = nil) {
        self.name = name
        self.url = url
        self.isSoloed = isSoloed
        self.isMuted = isMuted
        self.duration = duration
    }
}

// MARK: - The draft

/// Everything an import has made but not yet written.
///
/// It exists so cancellation is trivially correct: nothing reaches the library until the draft is
/// complete, so a cancelled import has nothing to clean up. The alternative — writing as you go and
/// unwinding on cancel — is the one that leaves half a song on disk when the unwind itself fails.
public struct ImportDraft: Sendable {
    public var sourceURL: URL
    public var record: Record
    public var seed: Seed
    public var song: Song
    public var analysisVersion: PartVersion
    public var takeVersion: PartVersion
    public var analysis: MusicAnalysis
    public var info: AudioFileInfo
}

// MARK: - The model

/// The Import surface's model: a drop target that becomes a described record, then a song package.
///
/// It holds no state the graph could hold. The analysis, the take, the stems and every promoted
/// region are `PartVersion`s; the model's own properties are the things that are true only while the
/// surface is open — which phase the import is in, how far along it is, and which lane is soloed.
@MainActor
@Observable
public final class ImportModel {

    // MARK: Identity

    public let surfaceID = SurfaceID()

    public var surface: ImportSurface {
        ImportSurface(id: surfaceID, bound: boundVersions, title: title)
    }

    public var title: String {
        switch state {
        case .empty: return "Import"
        case .reading(let url), .analyzing(let url), .analyzed(let url),
             .separating(let url), .writing(let url):
            return url.deletingPathExtension().lastPathComponent
        case .ready: return draft?.song.title ?? "Import"
        case .cancelled: return "Import — cancelled"
        case .failed: return "Import — failed"
        }
    }

    public var boundVersions: [VersionID] {
        guard let draft else { return [] }
        return [draft.analysisVersion.id, draft.takeVersion.id] + promoted.map(\.id)
    }

    // MARK: State

    public private(set) var state: ImportState = .empty
    /// Every phase the import has been through, in order, once each per entry. The surface shows the
    /// last few as a trail; a test reads the whole thing.
    public private(set) var phaseLog: [ImportPhase] = []
    public private(set) var progress = ImportProgress()

    public private(set) var waveform = ImportWaveform.empty
    /// Downbeat times in seconds, marked on the waveform.
    public private(set) var downbeats: [Double] = []
    public private(set) var draft: ImportDraft?
    public private(set) var stems: [StemLane] = []
    public private(set) var promoted: [PartVersion] = []
    /// The package that was written, once there is one.
    public private(set) var packageURL: URL?
    public private(set) var lastError: String?

    /// The region the user has dragged out on the waveform, in seconds.
    public var selection: SongGraph.TimeRange?

    public var provenance = ImportProvenance()

    /// Whether dropping a file also runs Demucs. Off by default: separation is twelve seconds a
    /// track and not every import wants stems.
    public var separatesStems = false

    // MARK: Collaborators

    private let host: any ImportHosting
    private var runTask: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?

    public init(host: any ImportHosting) {
        self.host = host
    }

    // MARK: Derived readings

    public var analysis: MusicAnalysis? { draft?.analysis }
    public var detectedKey: Key? { draft?.analysis.dominantKey }
    public var detectedTempo: Double? { draft?.analysis.dominantTempo }
    public var barCount: Int { draft?.analysis.bars.count ?? 0 }
    public var sections: [SectionRange] { draft?.analysis.sections ?? [] }
    public var instruments: [SongGraph.InstrumentActivity] { draft?.analysis.instruments ?? [] }
    public var loudness: Loudness? { draft?.analysis.loudness }

    /// Stems that would sound right now, honouring solo over mute the way a console does.
    public var audibleStems: [StemName] {
        let soloed = stems.filter(\.isSoloed)
        let candidates = soloed.isEmpty ? stems : soloed
        return candidates.filter { !$0.isMuted }.map(\.name)
    }

    /// The bar a time in seconds falls in, for the waveform's ruler.
    public func bar(at seconds: Double) -> Int? {
        guard let bars = draft?.analysis.bars else { return nil }
        return bars.firstIndex { $0.contains(seconds) }
    }

    /// The time range of a whole bar, which is what "promote this bar" means.
    public func range(ofBar index: Int) -> SongGraph.TimeRange? {
        guard let bars = draft?.analysis.bars, bars.indices.contains(index) else { return nil }
        return bars[index]
    }

    // MARK: Running an import

    /// The drop handler. Starts the import and returns immediately; the surface stays live.
    public func drop(_ url: URL) {
        guard !state.isBusy else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.run(url)
        }
    }

    /// Awaits whatever `drop(_:)` started. Tests use this; so does a caller that wants to sequence
    /// two imports.
    public func waitForCompletion() async {
        await runTask?.value
    }

    /// The whole import, start to finish. Every long call is `await`ed off this actor; nothing here
    /// does work on the main actor except assigning what the view reads.
    public func run(_ url: URL) async {
        startedAt = ContinuousClock.now
        lastError = nil
        promoted = []
        stems = []
        packageURL = nil
        draft = nil
        phaseLog = []

        do {
            // 1. The file itself: header, then the waveform, both off the main actor.
            transition(to: .reading(url), detail: "reading \(url.lastPathComponent)")
            let info = try await offMainActor { try AudioFileInfo.read(url) }
            try Task.checkCancellation()
            let peaks = try await offMainActor { try ImportWaveform.read(url) }
            try Task.checkCancellation()
            waveform = peaks

            // 2. Analysis. The long one.
            transition(to: .analyzing(url), detail: "analysing")
            let report = try await host.analyze(url) { [weak self] step in
                Task { @MainActor [weak self] in self?.note(step) }
            }
            try Task.checkCancellation()

            // 3. The draft: a record, a seed, a song and the two versions that describe the record.
            let analysis = ImportAnalysisMapping.musicAnalysis(from: report, fallbackDuration: info.duration)
            downbeats = analysis.downbeats
            draft = makeDraft(url: url, info: info, report: report, analysis: analysis)
            transition(to: .analyzed(url), detail: "analysed", fraction: separatesStems ? 0.55 : 0.9)

            // 4. Stems, if asked for. They land in `<Name>.stems/` beside the source, outside the
            //    library, so a cancelled separation leaves the library untouched.
            if separatesStems {
                transition(to: .separating(url), detail: "separating")
                try await separate(url)
                try Task.checkCancellation()
            }

            // 5. The write. Short, atomic, and the first time anything touches the library.
            transition(to: .writing(url), detail: "writing the package", fraction: 0.95)
            let songID = try await commitDraft()
            transition(to: .ready(songID), detail: "ready", fraction: 1)
        } catch is CancellationError {
            cancelled()
        } catch {
            if Task.isCancelled {
                cancelled()
            } else {
                lastError = "\(error)"
                transition(to: .failed("\(error)"), detail: "\(error)")
            }
        }
    }

    /// Cancel. The running task is cancelled and every long call unwinds through `CancellationError`;
    /// nothing has been written, so nothing has to be undone.
    public func cancel() {
        guard state.isCancellable else { return }
        runTask?.cancel()
    }

    /// Back to the drop target, forgetting the draft. The package, if one was written, stays on disk
    /// — this clears the surface, not the library.
    public func reset() {
        runTask?.cancel()
        runTask = nil
        state = .empty
        phaseLog = []
        progress = ImportProgress()
        waveform = .empty
        downbeats = []
        draft = nil
        stems = []
        promoted = []
        packageURL = nil
        selection = nil
        lastError = nil
    }

    // MARK: Promoting a region

    /// Promotes a span of the record to a `.sample` part version: the way a bar reaches the Chop lane.
    ///
    /// The version's provenance is complete on purpose — parent take, originating seed, the record it
    /// was cut from and the citation the provenance fields hold — because the Chop lane, the clearance
    /// sheet and any persona that later cites this bar all read it from here.
    @discardableResult
    public func promote(_ range: SongGraph.TimeRange, named name: String? = nil) throws -> PartVersion {
        guard var draft else { throw ImportModelError.nothingToPromote }
        let analysis = draft.analysis

        // Slices at every downbeat inside the region, so the Chop lane opens on a grid rather than
        // on one undifferentiated blob.
        let slices = analysis.downbeats
            .filter { $0 >= range.start && $0 < range.end }
            .map { SliceMarker(position: $0, label: nil) }

        let sample = Sample(media: draft.record.media,
                            slices: slices,
                            rootPitch: nil,
                            detectedTempo: analysis.dominantTempo,
                            sourceRecord: draft.record.id)

        let label = name ?? defaultRegionName(for: range)
        let citation = provenance.citation
        let note = citation.isEmpty
            ? "\(label) of \(draft.record.title)"
            : "\(label) of \(draft.record.title) — \(citation)"

        let version = PartVersion(partID: PartID(),
                                  kind: .sample(sample),
                                  author: .user,
                                  parents: [draft.takeVersion.id],
                                  operation: Operation.chop,
                                  note: note,
                                  origin: draft.seed.id)
        try draft.song.append(version)
        self.draft = draft
        promoted.append(version)

        // Plays on touch: promoting a bar plays that bar.
        auditionRegion(range)

        let song = draft.song
        Task { [host] in await host.didCommit(version, in: song) }

        // If the package is already on disk, the new version belongs in it now, not at some later
        // save nobody remembers to make.
        if packageURL != nil {
            Task { [weak self] in await self?.resaveDraft() }
        }
        return version
    }

    /// Promotes the current selection.
    @discardableResult
    public func promoteSelection(named name: String? = nil) throws -> PartVersion {
        guard let selection else { throw ImportModelError.noSelection }
        return try promote(selection, named: name)
    }

    /// Promotes a whole detected bar.
    @discardableResult
    public func promoteBar(_ index: Int) throws -> PartVersion {
        guard let range = range(ofBar: index) else { throw ImportModelError.noSuchBar(index) }
        return try promote(range, named: "Bar \(index + 1)")
    }

    private func defaultRegionName(for range: SongGraph.TimeRange) -> String {
        if let first = bar(at: range.start), let last = bar(at: max(range.start, range.end - 0.001)) {
            return first == last ? "Bar \(first + 1)" : "Bars \(first + 1)–\(last + 1)"
        }
        return String(format: "%.2f–%.2f s", range.start, range.end)
    }

    // MARK: Auditioning

    /// Plays a region of the record. Every selection, every bar, every stem lane goes through here.
    public func auditionRegion(_ range: SongGraph.TimeRange) {
        guard let url = draft?.sourceURL ?? currentURL else { return }
        Task { [host] in await host.audition(url, from: range.start, to: range.end) }
    }

    public func auditionSelection() {
        guard let selection else { return }
        auditionRegion(selection)
    }

    /// Plays a stem over the current selection, or from the top when there is no selection.
    public func audition(stem name: StemName) {
        guard let lane = stems.first(where: { $0.name == name }) else { return }
        let range = selection ?? SongGraph.TimeRange(start: 0, end: min(8, lane.duration ?? 8))
        Task { [host] in await host.audition(lane.url, from: range.start, to: range.end) }
    }

    public func stopAudition() {
        Task { [host] in await host.stopAudition() }
    }

    // MARK: Stem lanes

    public func toggleSolo(_ name: StemName) {
        guard let index = stems.firstIndex(where: { $0.name == name }) else { return }
        stems[index].isSoloed.toggle()
        if stems[index].isSoloed { audition(stem: name) }
    }

    public func toggleMute(_ name: StemName) {
        guard let index = stems.firstIndex(where: { $0.name == name }) else { return }
        stems[index].isMuted.toggle()
        if !stems[index].isMuted { audition(stem: name) }
    }

    // MARK: - Internals

    private var currentURL: URL? {
        switch state {
        case .reading(let url), .analyzing(let url), .analyzed(let url),
             .separating(let url), .writing(let url):
            return url
        default:
            return draft?.sourceURL
        }
    }

    private func transition(to newState: ImportState, detail: String, fraction: Double? = nil) {
        state = newState
        if phaseLog.last != newState.phase { phaseLog.append(newState.phase) }
        progress = ImportProgress(phase: newState.phase,
                                  fraction: fraction ?? baselineFraction(for: newState.phase),
                                  detail: detail,
                                  elapsed: elapsed)
    }

    /// A tick from a long job, mapped onto the whole import's span.
    private func note(_ step: ImportStep) {
        let fraction: Double?
        switch state.phase {
        case .analyzing:
            fraction = step.fraction.map { 0.05 + 0.5 * $0 }
        case .separating:
            fraction = step.fraction.map { 0.55 + 0.4 * $0 }
        default:
            fraction = step.fraction
        }
        progress = ImportProgress(phase: state.phase, fraction: fraction, detail: step.detail, elapsed: elapsed)
    }

    /// What a phase is worth before its own job has reported anything. `nil` means "this step cannot
    /// say", which is the honest answer during a Music Understanding pass.
    private func baselineFraction(for phase: ImportPhase) -> Double? {
        switch phase {
        case .empty: return nil
        case .reading: return 0.02
        case .analyzing: return nil
        case .analyzed: return 0.55
        case .separating: return 0.55
        case .writing: return 0.95
        case .ready: return 1
        case .cancelled, .failed: return nil
        }
    }

    private var elapsed: Double {
        guard let startedAt else { return 0 }
        let span = startedAt.duration(to: .now).components
        return Double(span.seconds) + Double(span.attoseconds) / 1e18
    }

    private func cancelled() {
        // Nothing was written, by construction: the package is the last step and it is not
        // cancellable. So a cancel really is "as if it never happened".
        draft = nil
        stems = []
        promoted = []
        packageURL = nil
        waveform = .empty
        downbeats = []
        state = .cancelled
        if phaseLog.last != .cancelled { phaseLog.append(.cancelled) }
        progress = ImportProgress(phase: .cancelled, fraction: nil, detail: "cancelled", elapsed: elapsed)
    }

    private func makeDraft(url: URL, info: AudioFileInfo, report: AnalysisReport, analysis: MusicAnalysis) -> ImportDraft {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = provenance.title.isEmpty ? fallbackTitle : provenance.title
        let artist = provenance.artist

        // The media reference is filled in at write time, when the bytes are actually hashed into the
        // library; until then the draft carries a placeholder-free reference by hashing nothing.
        let record = Record(title: title, artist: artist, media: MediaRef.placeholder(for: url))
        let citation = provenance.citation
        let seedNote = citation.isEmpty
            ? "imported from \(url.path)"
            : "imported from \(url.path) — \(citation) [clearance: \(provenance.clearance.rawValue)]"
        let seed = Seed(kind: .importedRecord(record.id), note: seedNote)

        var song = Song(title: title,
                        artist: artist,
                        key: analysis.dominantKey,
                        tempo: analysis.dominantTempo ?? 120,
                        timeSignature: report.beatGrid?.timeSignature ?? .fourFour)
        song.seeds.append(seed)

        let analysisVersion = PartVersion(partID: PartID(), kind: .analysis(analysis), author: .user,
                                          operation: Operation.imported,
                                          note: "analysis of \(url.lastPathComponent)", origin: seed.id)
        let take = Audio(media: record.media, role: .take, stem: nil, sampleRate: info.sampleRate,
                         channelCount: info.channelCount, duration: info.duration)
        let takeVersion = PartVersion(partID: PartID(), kind: .audio(take), author: .user,
                                      operation: Operation.imported,
                                      note: "the record, as imported", origin: seed.id)
        try? song.append(analysisVersion)
        try? song.append(takeVersion)

        return ImportDraft(sourceURL: url, record: record, seed: seed, song: song,
                           analysisVersion: analysisVersion, takeVersion: takeVersion,
                           analysis: analysis, info: info)
    }

    private func separate(_ url: URL) async throws {
        let directory = url.deletingPathExtension().appendingPathExtension("stems")
        _ = try await host.separate(url, into: directory) { [weak self] step in
            Task { @MainActor [weak self] in self?.note(step) }
        } stemDidLand: { [weak self] name, fileURL in
            Task { @MainActor [weak self] in self?.stemDidLand(name, at: fileURL) }
        }
    }

    /// A lane appears the moment its file does, which is the whole point of reporting per stem: four
    /// lanes arriving one by one is progress you can hear, a spinner is not.
    private func stemDidLand(_ name: StemName, at url: URL) {
        let duration = try? AudioFileInfo.read(url).duration
        if let index = stems.firstIndex(where: { $0.name == name }) {
            stems[index].url = url
            stems[index].duration = duration
        } else {
            stems.append(StemLane(name: name, url: url, duration: duration))
            stems.sort { $0.name.rawValue < $1.name.rawValue }
        }
    }

    /// Writes the record media, the song package and every stem. The only step that touches disk.
    private func commitDraft() async throws -> SongID {
        guard var draft else { throw ImportModelError.nothingToWrite }
        let library = host.library
        let sourceURL = draft.sourceURL
        let lanes = stems

        // Hash the record into the library and fix up every reference that used the placeholder.
        let placeholder = draft.record.media
        let recordMedia = try await offMainActor { try library.addMedia(copying: sourceURL, kind: .record) }
        draft.record.media = recordMedia
        draft.song = Self.replacing(placeholder, with: recordMedia, in: draft.song)
        draft.takeVersion = draft.song.version(draft.takeVersion.id) ?? draft.takeVersion
        draft.record.analysis = draft.analysisVersion

        var libraryValue = try await offMainActor { () -> Library in
            library.exists ? try library.load() : Library()
        }
        libraryValue.records.append(draft.record)
        libraryValue.upsert(draft.song)
        let saved = libraryValue
        try await offMainActor { try library.save(saved) }

        let songID = draft.song.id
        let store = try await offMainActor { try library.songStore(for: songID) }
        packageURL = store.packageURL

        // Stems go into the song's own package, derived from the take.
        if !lanes.isEmpty {
            let take = draft.takeVersion
            var stemVersions: [PartVersion] = []
            for lane in lanes {
                let laneURL = lane.url
                let media = try await offMainActor { try store.addMedia(copying: laneURL) }
                let info = try await offMainActor { try AudioFileInfo.read(laneURL) }
                let audio = Audio(media: media, role: .stem, stem: lane.name.rawValue,
                                  sampleRate: info.sampleRate, channelCount: info.channelCount,
                                  duration: info.duration)
                stemVersions.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user,
                                                parents: [take.id], operation: Operation.separate,
                                                note: "\(lane.name.rawValue) stem of \(draft.record.title)",
                                                origin: draft.seed.id))
            }
            try draft.song.append(contentsOf: stemVersions)
            var updated = libraryValue
            updated.upsert(draft.song)
            let toSave = updated
            try await offMainActor { try library.save(toSave) }
        }

        self.draft = draft
        return songID
    }

    /// Saves the draft again after a promotion. Best effort: a failure here is reported, never fatal,
    /// because the version is already in the in-memory song and the next save picks it up.
    private func resaveDraft() async {
        guard let draft else { return }
        let library = host.library
        do {
            var libraryValue = try await offMainActor { () -> Library in
                library.exists ? try library.load() : Library()
            }
            libraryValue.upsert(draft.song)
            let toSave = libraryValue
            try await offMainActor { try library.save(toSave) }
        } catch {
            lastError = "\(error)"
        }
    }

    /// Rewrites every audio payload that referred to the placeholder so it points at the hashed media.
    private static func replacing(_ old: MediaRef, with new: MediaRef, in song: Song) -> Song {
        var rebuilt = Song(id: song.id, title: song.title, artist: song.artist, key: song.key,
                           tempo: song.tempo, timeSignature: song.timeSignature, sections: song.sections,
                           versions: [], seeds: song.seeds, experiments: song.experiments,
                           createdAt: song.createdAt)
        for version in song.versions {
            var kind = version.kind
            switch kind {
            case .audio(var audio) where audio.media == old:
                audio.media = new
                kind = .audio(audio)
            case .sample(var sample) where sample.media == old:
                sample.media = new
                kind = .sample(sample)
            default:
                break
            }
            try? rebuilt.append(PartVersion(id: version.id, partID: version.partID, kind: kind,
                                            createdAt: version.createdAt, author: version.author,
                                            parents: version.parents, operation: version.operation,
                                            note: version.note, origin: version.origin))
        }
        return rebuilt
    }

    /// Runs blocking work off the main actor and hands the result back on it.
    private func offMainActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }
}

// MARK: - Errors

public enum ImportModelError: Error, CustomStringConvertible, Sendable {
    case nothingToPromote
    case noSelection
    case noSuchBar(Int)
    case nothingToWrite

    public var description: String {
        switch self {
        case .nothingToPromote: return "there is no analysed record to promote a region of"
        case .noSelection: return "nothing is selected on the waveform"
        case .noSuchBar(let index): return "the analysis has no bar \(index)"
        case .nothingToWrite: return "there is no draft to write"
        }
    }
}

// MARK: - Placeholder media

extension MediaRef {
    /// A reference for media that has not been hashed into a store yet.
    ///
    /// The draft needs *a* reference so the take version can exist before the write; this one hashes
    /// the source path, so it is stable within a run and impossible to confuse with content-hashed
    /// media, and `ImportModel` replaces every occurrence at write time.
    static func placeholder(for url: URL) -> MediaRef {
        MediaRef(hash: ContentHash(of: Data(url.path.utf8)), fileExtension: url.pathExtension)
    }
}

// MARK: - Report → graph

/// Turns an `AnalysisReport` into the `MusicAnalysis` a part version carries.
///
/// The same mapping `m0 import` does, kept here because the CLI's copy is internal to that
/// executable. Both modules define `TimeRange`, `KeyRange` and `InstrumentActivity`, so everything
/// is module-qualified.
public enum ImportAnalysisMapping {
    public static func musicAnalysis(from report: AnalysisReport, fallbackDuration: Double) -> MusicAnalysis {
        let duration = report.duration ?? fallbackDuration
        let grid = report.beatGrid

        let keys = (report.key?.ranges ?? []).map {
            SongGraph.KeyRange(start: $0.start, end: $0.end, key: $0.key)
        }

        var beats: [BeatMarker] = []
        var bars: [SongGraph.TimeRange] = []
        var tempo: [TempoRange] = []
        if let grid {
            let downbeatIndices = grid.downbeatIndices()
            beats = grid.beats.enumerated().map {
                BeatMarker(time: $0.element, isDownbeat: downbeatIndices.contains($0.offset))
            }
            bars = (0..<grid.barCount).compactMap { index in
                grid.bounds(ofBar: index).map { SongGraph.TimeRange(start: $0.start, end: $0.end) }
            }
            if let bpm = report.beats?.bpm ?? grid.bpm {
                tempo = [TempoRange(start: 0, end: duration, bpm: bpm)]
            }
        }

        let sections = (report.structure?.sections ?? []).map {
            SectionRange(start: $0.start, end: $0.end, label: nil)
        }

        var instruments: [SongGraph.InstrumentActivity] = []
        if let activity = report.instruments {
            for instrument in Analysis.Instrument.allCases {
                let ranges = activity.presence[instrument] ?? []
                guard !ranges.isEmpty else { continue }
                instruments.append(SongGraph.InstrumentActivity(
                    instrument: instrument.instrumentKind,
                    ranges: ranges.map { SongGraph.TimeRange(start: $0.start, end: $0.end) }))
            }
        }

        let loudness = report.loudness.map {
            Loudness(integrated: $0.integrated, range: $0.range, truePeak: $0.truePeak)
        }

        let names = Set(report.provenance.values).sorted()
        let analyzer = names.isEmpty ? nil : names.joined(separator: "+")

        return MusicAnalysis(duration: duration, keys: keys, beats: beats, bars: bars, tempo: tempo,
                             sections: sections, instruments: instruments, loudness: loudness,
                             analyzer: analyzer)
    }
}

extension Analysis.Instrument {
    /// The song graph's name for the same class.
    public var instrumentKind: InstrumentKind {
        switch self {
        case .vocal: return .vocals
        case .drums: return .drums
        case .bass: return .bass
        case .other: return .other
        }
    }
}
