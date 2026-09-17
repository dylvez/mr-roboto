import AudioEngine
import Foundation
import MusicTheory
import Observation
import SongGraph

// MARK: - Session log

/// One line in the conversation rail. In Gate A there is no agent, so the rail is the session's own
/// history: what you did, in order. Nothing here is ever written by a model.
public struct SessionEntry: Identifiable, Sendable, Equatable {
    /// Who the line is attributed to. `you` is something you asked for; `session` is the app
    /// reporting back (a save, a surface retired to make room, a failure).
    public enum Source: String, Sendable, Equatable {
        case you = "You"
        case session = "Session"
    }

    public let id: UUID
    public let at: Date
    public let source: Source
    public let text: String
    /// A second, quieter line: a path, a reason, a provenance.
    public let detail: String?

    public init(id: UUID = UUID(), at: Date = Date(), source: Source, text: String, detail: String? = nil) {
        self.id = id
        self.at = at
        self.source = source
        self.text = text
        self.detail = detail
    }
}

// MARK: - Library status

/// Whether the library directory has anything in it, and if not, why. The sidebar shows the honest
/// state rather than inventing a row.
public enum LibraryStatus: Equatable, Sendable {
    /// A library was read and has at least one entry.
    case loaded(URL)
    /// The directory is reachable but holds no `library.json`, or one with nothing in it.
    case empty(URL)
    /// The directory could not be read; the string is the reason, shown to the user verbatim.
    case failed(URL, String)
    /// No library directory was configured (tests, previews).
    case unset

    public var directory: URL? {
        switch self {
        case .loaded(let url), .empty(let url), .failed(let url, _): return url
        case .unset: return nil
        }
    }
}

// MARK: - Transport

/// What the transport is doing. `unavailable` carries the engine's own error text: this shell, CI, and
/// any machine without an output device land there, and the frame says so rather than pretending to play.
public enum TransportState: Equatable, Sendable {
    case stopped
    case starting
    case playing
    case unavailable(String)

    public var isPlaying: Bool { self == .playing }
    public var isBusy: Bool { self == .starting }
}

/// The audio the frame drives. `LiveTransportHost` owns the real `AudioEngine.Engine`; tests inject a
/// double so `AppState` transitions can be asserted on a machine with no audio device.
///
/// A surface that needs to audition asks `AppState.engine()` and schedules its own `ScheduledSource`;
/// the frame only starts and stops the transport.
@MainActor
public protocol TransportHost: AnyObject {
    /// The shared engine, created on first use. Throws if the graph cannot be built.
    func engine() async throws -> Engine
    /// Starts the engine (if needed) and the transport at this clock.
    func start(clock: TransportClock) async throws
    /// Stops the transport and the engine. Never throws: stopping is always allowed.
    func stop() async
}

/// The real thing: one `Engine`, built lazily so launching the app on a machine with no output device
/// does not fail until someone presses play.
@MainActor
public final class LiveTransportHost: TransportHost {
    private var built: Engine?

    public init() {}

    public func engine() async throws -> Engine {
        if let built { return built }
        let engine = try await Engine()
        built = engine
        return engine
    }

    public func start(clock: TransportClock) async throws {
        let engine = try await engine()
        try await engine.start()
        _ = try await engine.startTransport(clock: clock)
    }

    public func stop() async {
        guard let built else { return }
        await built.stop()
    }
}

// MARK: - AppState

/// Everything the frame owns and every surface is handed.
///
/// **What this object owns:** the current `Library` and `Song`, the `Bench` (which surfaces are open),
/// which part version is selected, which section is active, the audio transport, and the session log
/// the conversation rail renders.
///
/// **What it does not own:** anything inside a surface. A surface holds no state of its own (see the
/// `Surface` protocol); it reads `song`/`library`, auditions through `engine()`, and hands finished work
/// back with `record(_:)`, which appends an immutable version to the song graph. It never mutates a
/// version and never writes to disk — `save()` is the frame's.
///
/// **The whole API a surface needs:**
/// ```swift
/// app.song                      // the open song, nil until one is opened
/// app.library                   // ideas, songs, albums, records, samples
/// app.version(id)               // look up a part version by id
/// app.selectedVersion           // the accented row in the parts ledger
/// app.select(id)                // accent a different one
/// app.bound(for: surfaceID)     // the versions this surface was opened against
/// app.record(version)           // append a new version: selects it and logs it
/// app.note("what you did")      // add a line to the conversation rail
/// try await app.engine()        // the AudioEngine.Engine, for auditioning in place
/// app.openSurface(.grid, title: "Bar 9", bound: [id])   // open another surface on the bench
/// ```
/// Every method is main-actor isolated and synchronous unless it touches audio.
@MainActor
@Observable
public final class AppState {

    // MARK: Library

    /// The library as last read from disk. Replaced wholesale by `reloadLibrary()`; never mutated in place.
    public private(set) var library: Library

    /// Whether the library directory had anything in it. The sidebar's empty state reads this.
    public private(set) var libraryStatus: LibraryStatus

    /// The store the library was read from, and that `save()` writes back to. Nil in tests and previews.
    @ObservationIgnored public let store: LibraryStore?

    // MARK: Song

    /// The song in the frame. Nil before one is opened; the header, ledger and transport all read it.
    public private(set) var song: Song?

    /// The accented row in the parts ledger, and what most surfaces open against.
    public private(set) var selectedVersion: VersionID?

    /// The lit block in the transport's section strip.
    public private(set) var activeSection: SectionID?

    /// True when the song has versions that are not on disk yet. The header's Save is quiet otherwise.
    public private(set) var hasUnsavedChanges = false

    // MARK: Bench

    /// At most three open surfaces, oldest unpinned replaced. Owned here, mutated through `openSurface`,
    /// `closeSurface` and `setPinned` so every change is logged.
    public let bench: Bench

    /// Which part versions each open surface was opened against. `BenchItem` deliberately carries only
    /// what the frame draws, so the binding lives here; a surface reads it with `bound(for:)`.
    public private(set) var bindings: [SurfaceID: [VersionID]] = [:]

    /// Work a surface was asked to start the moment the wiring builds it.
    ///
    /// Some preparations cannot be done by the frame: separating a record takes a minute, reports as
    /// it goes and belongs on the surface that shows the result. So `perform(_:)` opens the surface
    /// and leaves the request here; `SurfaceWiring` hands it to the model on the next build and
    /// takes it, so it fires exactly once.
    public private(set) var requests: [SurfaceID: SurfaceAction.Preparation] = [:]

    /// Files a request. Internal to the guidance path; nothing else queues work for a surface.
    func file(_ preparation: SurfaceAction.Preparation, for id: SurfaceID) { requests[id] = preparation }

    /// Consumes the request for a surface, if any.
    public func takeRequest(for id: SurfaceID) -> SurfaceAction.Preparation? {
        guard let request = requests[id] else { return nil }
        requests[id] = nil
        return request
    }

    // MARK: Rail

    /// The conversation rail, oldest first.
    public private(set) var log: [SessionEntry] = []

    /// Proposals from the band, when there is one.
    ///
    /// Empty through the whole of Gate A, and that is the point: the rail already renders
    /// `[Proposal]`, so when the Director starts answering, its replies land in this array and the
    /// rail does not change. Until then `proposals` derives the same shape from the song graph.
    public var director: [Proposal] = []

    // MARK: Transport

    public private(set) var transport: TransportState = .stopped
    /// Whether playback should loop. The frame owns the flag; sources honour it.
    public private(set) var isLooping = false

    @ObservationIgnored private let transportHost: TransportHost

    // MARK: Init

    /// - Parameters:
    ///   - library: the library to start with. `live()` reads one from disk instead.
    ///   - song: the song to open immediately, if any.
    ///   - store: where `save()` writes and `reloadLibrary()` reads.
    ///   - transportHost: the audio. Inject a double in tests.
    public init(library: Library = Library(),
                song: Song? = nil,
                store: LibraryStore? = nil,
                status: LibraryStatus? = nil,
                transportHost: TransportHost = LiveTransportHost()) {
        self.library = library
        self.store = store
        self.transportHost = transportHost
        self.bench = Bench()
        self.libraryStatus = status ?? store.map { library.isEmpty ? .empty($0.directoryURL) : .loaded($0.directoryURL) } ?? .unset
        if let song { openSongWithoutLogging(song) }
    }

    /// The app's own state: the library under Application Support, read now.
    public static func live() -> AppState {
        let store = LibraryStore(directoryURL: AppState.defaultLibraryDirectory)
        let state = AppState(store: store, status: .empty(store.directoryURL))
        state.reloadLibrary()
        return state
    }

    /// `~/Library/Application Support/MrRoboto/Library`, created on demand. Songs are `.roboto` packages
    /// inside it; records and samples are stored by content hash alongside.
    public static var defaultLibraryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "MrRoboto/Library")
    }

    // MARK: Library

    /// Re-reads the library directory. Distinguishes "nothing there yet" from "could not be read": the
    /// first is an empty state that tells you how to import, the second shows the reason.
    public func reloadLibrary() {
        guard let store else { return }
        let directory = store.directoryURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            libraryStatus = .failed(directory, error.localizedDescription)
            return
        }
        guard store.exists else {
            library = Library()
            libraryStatus = .empty(directory)
            return
        }
        do {
            let loaded = try store.load()
            library = loaded
            libraryStatus = loaded.isEmpty ? .empty(directory) : .loaded(directory)
        } catch {
            libraryStatus = .failed(directory, "\(error)")
            note(.session, "Could not read the library", detail: "\(error)")
        }
    }

    /// Opens a song from the library by id. No-op if the library does not hold it.
    public func openSong(_ id: SongID) {
        guard let found = library.song(id) else {
            note(.session, "That song is not in the library")
            return
        }
        open(found)
    }

    /// Opens a song. Clears the bench — surfaces are bound to versions of the song that was open —
    /// selects the newest version, and puts the song itself on the bench.
    ///
    /// That last step is the difference between opening a song and being handed an empty room. A
    /// song *is* something: a record with a waveform, a key, a tempo and its stems, or failing that
    /// the newest thing anyone made in it. `Guidance.opening(_:)` decides which, and a song holding
    /// nothing Gate A can show opens on nothing rather than on a surface with a shrug in it.
    public func open(_ song: Song) {
        for item in bench.items { bench.close(item.id) }
        bindings.removeAll()
        requests.removeAll()
        openSongWithoutLogging(song)
        note(.you, "Opened \(song.title)", detail: provenanceSummary(of: song))
        if let opening = Guidance.opening(song) { perform(opening) }
    }

    private func openSongWithoutLogging(_ song: Song) {
        self.song = song
        selectedVersion = song.versions.last?.id
        activeSection = song.sections.first?.id
        hasUnsavedChanges = false
    }

    private func provenanceSummary(of song: Song) -> String {
        let parts = song.partIDs.count
        let sections = song.sections.count
        var pieces = ["\(parts) part\(parts == 1 ? "" : "s")", "\(song.versions.count) version\(song.versions.count == 1 ? "" : "s")"]
        if sections > 0 { pieces.append("\(sections) section\(sections == 1 ? "" : "s")") }
        return pieces.joined(separator: " · ")
    }

    /// Writes the open song and the library back to disk. Honest about failure: nothing is swallowed.
    public func save() {
        guard let store else {
            note(.session, "Nowhere to save to", detail: "This session has no library directory.")
            return
        }
        guard let song else {
            note(.session, "No song open to save")
            return
        }
        do {
            var updated = library
            updated.upsert(song)
            try store.save(updated)
            library = updated
            hasUnsavedChanges = false
            libraryStatus = .loaded(store.directoryURL)
            note(.you, "Saved \(song.title)", detail: store.directoryURL.path)
        } catch {
            note(.session, "Save failed", detail: "\(error)")
        }
    }

    // MARK: Versions

    /// Every version in the open song, oldest first. The parts ledger's rows.
    public var versions: [PartVersion] { song?.versions ?? [] }

    public func version(_ id: VersionID) -> PartVersion? { song?.version(id) ?? library.ideas.first { $0.id == id } }

    /// Where this version sits in its part's history, 1-based — the "v3" in the ledger.
    ///
    /// Counted in the order the graph recorded them, not by timestamp: two versions made inside the
    /// same millisecond (a chop that emits a dozen at once) would otherwise be ordered by UUID, and
    /// the ledger would renumber itself between launches.
    public func versionNumber(of id: VersionID) -> Int? {
        guard let song, let version = song.version(id) else { return nil }
        guard let index = song.versions.filter({ $0.partID == version.partID })
            .firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    /// Accents a row in the ledger. Pass nil to clear the selection.
    public func select(_ id: VersionID?) {
        guard selectedVersion != id else { return }
        selectedVersion = id
        guard let id, let version = version(id) else { return }
        note(.you, "Selected \(PartLabel.title(of: version))\(versionNumber(of: id).map { " v\($0)" } ?? "")",
             detail: provenanceLine(for: version))
    }

    /// Appends a new version to the open song, selects it and logs it. This is how a surface hands back
    /// work: derive from an existing version (`PartVersion.deriving` / `.spawning`) and record the result.
    /// An existing version is never mutated.
    @discardableResult
    public func record(_ version: PartVersion) -> Bool {
        guard var current = song else {
            note(.session, "No song open; nothing to record into")
            return false
        }
        do {
            try current.append(version)
            song = current
            hasUnsavedChanges = true
            selectedVersion = version.id
            note(.you, "\(version.operation.capitalized) → \(version.type.rawValue)\(versionNumber(of: version.id).map { " v\($0)" } ?? "")",
                 detail: provenanceLine(for: version))
            return true
        } catch {
            note(.session, "Could not record that version", detail: "\(error)")
            return false
        }
    }

    /// The second line of a ledger row: what made this version, who made it, and what from.
    public func provenanceLine(for version: PartVersion) -> String {
        var pieces = [version.operation, version.author.description]
        if let note = version.note, !note.isEmpty { pieces.append(note) }
        let parents = version.parents.compactMap { parent in versionNumber(of: parent).map { "v\($0)" } }
        if !parents.isEmpty { pieces.append("from \(parents.joined(separator: ", "))") }
        return pieces.joined(separator: " · ")
    }

    // MARK: Sections

    public func setActiveSection(_ id: SectionID?) {
        guard activeSection != id else { return }
        activeSection = id
        if let id, let section = song?.section(id) { note(.you, "Moved to \(section.name)") }
    }

    // MARK: Bench

    /// Opens a surface on the bench, retiring the oldest unpinned one when it is full (the `Bench`'s own
    /// rule). Returns the id, which is also the key for `bound(for:)`.
    @discardableResult
    public func openSurface(_ kind: SurfaceKind, title: String, bound: [VersionID] = [],
                            id: SurfaceID = SurfaceID()) -> SurfaceID {
        let retired = bench.open(BenchItem(id: id, kind: kind, title: title))
        bindings[id] = bound
        note(.you, "Opened \(kind.rawValue)", detail: title)
        if let retired, retired.id != id {
            bindings[retired.id] = nil
            note(.session, "Closed \(retired.kind.rawValue) to make room", detail: retired.title)
        }
        return id
    }

    public func closeSurface(_ id: SurfaceID) {
        guard let item = bench.items.first(where: { $0.id == id }) else { return }
        bench.close(id)
        bindings[id] = nil
        note(.you, "Closed \(item.kind.rawValue)", detail: item.title)
    }

    public func setPinned(_ pinned: Bool, for id: SurfaceID) {
        guard let item = bench.items.first(where: { $0.id == id }), item.isPinned != pinned else { return }
        bench.setPinned(pinned, for: id)
        note(.you, "\(pinned ? "Pinned" : "Unpinned") \(item.kind.rawValue)", detail: item.title)
    }

    /// The versions a surface was opened against.
    public func bound(for id: SurfaceID) -> [VersionID] { bindings[id] ?? [] }

    /// Renames an open surface in place, keeping its pin and its position on the bench. A surface that
    /// only learns its title after it loads something ("Bar 9 of Arrival") calls this; it is not an event,
    /// so nothing is logged.
    public func retitleSurface(_ id: SurfaceID, to title: String) {
        guard let item = bench.items.first(where: { $0.id == id }), item.title != title else { return }
        bench.open(BenchItem(id: id, kind: item.kind, title: title, isPinned: item.isPinned, openedAt: item.openedAt))
    }

    /// Changes what an open surface is bound to, after the surface has resolved its own versions.
    public func rebindSurface(_ id: SurfaceID, to versions: [VersionID]) {
        guard bench.items.contains(where: { $0.id == id }) else { return }
        bindings[id] = versions
    }

    // MARK: Rail

    /// Adds a line to the conversation rail. Surfaces use this to say what they did, in your voice.
    public func note(_ text: String, detail: String? = nil) { note(.you, text, detail: detail) }

    /// Adds a line attributed to the app rather than to you.
    public func note(_ source: SessionEntry.Source, _ text: String, detail: String? = nil) {
        log.append(SessionEntry(source: source, text: text, detail: detail))
    }

    // MARK: Transport

    /// The shared engine, for surfaces that audition in place. Built on first use; throws on a machine
    /// with no usable audio graph.
    public func engine() async throws -> Engine { try await transportHost.engine() }

    /// The clock the transport runs at: the open song's tempo and meter, or 120 4/4 with nothing open.
    public var clock: TransportClock {
        TransportClock(tempo: song?.tempo ?? 120, timeSignature: song?.timeSignature ?? .fourFour)
    }

    /// Space, and the transport's play/stop control.
    public func toggleTransport() async {
        switch transport {
        case .playing, .starting: await stopTransport()
        case .stopped, .unavailable: await startTransport()
        }
    }

    public func startTransport() async {
        guard transport != .playing, transport != .starting else { return }
        transport = .starting
        do {
            try await transportHost.start(clock: clock)
            transport = .playing
            note(.you, "Play", detail: String(format: "%.0f bpm · %@", clock.tempo, clock.timeSignature.description))
        } catch {
            transport = .unavailable("\(error)")
            note(.session, "The transport could not start", detail: "\(error)")
        }
    }

    public func stopTransport() async {
        guard transport != .stopped else { return }
        await transportHost.stop()
        transport = .stopped
        note(.you, "Stop")
    }

    public func toggleLoop() {
        isLooping.toggle()
        note(.you, isLooping ? "Loop on" : "Loop off")
    }
}

extension Library {
    /// Nothing in any of the five drawers.
    var isEmpty: Bool {
        songs.isEmpty && albums.isEmpty && ideas.isEmpty && records.isEmpty && samples.isEmpty
    }
}
