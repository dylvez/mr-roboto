import AudioEngine
import Foundation
import MusicTheory
import Observation
import SongGraph

// MARK: - Session log

/// One line in the conversation rail.
///
/// Every line says who said it, and the four voices are different things rather than four labels:
///
/// * **you** — something you asked for, or a surface reporting what your edit did.
/// * **session** — the app itself: a save, a surface retired to make room, a failure. Nothing here
///   is ever written by a model, which is what makes it the place an honest error goes.
/// * **director** — the Director's own reply to something you typed. One band member, always
///   called the same thing, so a line that decides is distinguishable from a line that reports.
/// * **persona(name)** — a member of the band, by their own name. `.director` deliberately is not
///   `.persona("Director")`: the Director is the one that turns a sentence into work, and a
///   persona is one that has an opinion about the work. The rail draws them differently and the
///   accent follows `isBand`, so a persona's line needs nothing new here to land correctly.
public struct SessionEntry: Identifiable, Sendable, Equatable {
    /// Who the line is attributed to.
    public enum Source: Sendable, Equatable, Hashable {
        case you
        case session
        case director
        case persona(String)

        /// What the rail prints above the line. A persona is called by its name and nothing else —
        /// "Cass", not "Persona: Cass" — because that is how you would refer to them.
        public var label: String {
            switch self {
            case .you: return "You"
            case .session: return "Session"
            case .director: return "Director"
            case .persona(let name): return name.isEmpty ? "The band" : name
            }
        }

        /// Whether a model wrote this line. The rail marks these, so "the app said it" and "the
        /// band said it" are never confusable — the one distinction the whole log exists to keep.
        public var isBand: Bool {
            switch self {
            case .you, .session: return false
            case .director, .persona: return true
            }
        }
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
    /// The song holds nothing this transport can sound: no groove with a hit in it, no take, no
    /// stems. Pressing play says which, rather than lighting up and playing silence.
    case nothingToPlay(SongPlayback.Silence)

    public var isPlaying: Bool { self == .playing }
    public var isBusy: Bool { self == .starting }

    /// Why it is not playing, when there is a reason worth putting on screen.
    public var silence: SongPlayback.Silence? {
        if case .nothingToPlay(let silence) = self { return silence }
        return nil
    }
}

/// No player was attached to this `AppState`. The app attaches one in `live()`; a test that means
/// to drive the transport injects a double. Reaching this is a wiring mistake, and it says so.
public struct SongPlaybackUnavailable: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "this session has no player attached" }
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
        // Eight player nodes, not the default four. A node is taken by every audio track and by
        // every dusty source that has to be bounced — and a section may now hold several of those
        // at once, where before the plan could name one dusty groove and one chop in the whole
        // song. Running out is not silent but it is fatal to the part: `LiveSongPlayer` throws
        // rather than dropping it.
        let engine = try await Engine(playerCount: 8)
        // The remembered input device, before the engine runs: the input node's device is best set while it is stopped.
        let uid = InputSettings().choice.deviceUID
        if uid != nil { try? await engine.setInputDevice(uid: uid) }
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
    public internal(set) var library: Library

    /// Whether the library directory had anything in it. The sidebar's empty state reads this.
    public internal(set) var libraryStatus: LibraryStatus

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
    /// `closeSurface` and `setPinned` so every change is logged. The bench draws the one you are
    /// working in, plus anything pinned — see `Bench.visible`.
    public let bench: Bench

    // MARK: Regions

    /// Which of the three flanking regions are folded away, remembered between launches. The frame
    /// reads this for its widths and for its own window minimum.
    public let regions: RegionVisibility

    /// Which surfaces' one-line primers you have dismissed. See `Primer`.
    public let primers: PrimerStore

    /// Which part versions each open surface was opened against. `BenchItem` deliberately carries only
    /// what the frame draws, so the binding lives here; a surface reads it with `bound(for:)`.
    public private(set) var bindings: [SurfaceID: [VersionID]] = [:]

    /// Which album an open Album surface shows. Albums are not versions, so they are not in
    /// `bindings`; the surface reads this the way a part surface reads `bound(for:)`.
    public internal(set) var albumBindings: [SurfaceID: AlbumID] = [:]

    /// Work a surface was asked to start the moment the wiring builds it.
    ///
    /// Some preparations cannot be done by the frame: separating a record takes a minute, reports as
    /// it goes and belongs on the surface that shows the result. So `perform(_:)` opens the surface
    /// and leaves the request here; `SurfaceWiring` hands it to the model on the next build and
    /// takes it, so it fires exactly once.
    public private(set) var requests: [SurfaceID: SurfaceAction.Preparation] = [:]

    /// The controls the Director put on a surface it opened, at most two per surface.
    ///
    /// Stored beside the binding rather than inside `BenchItem` for the same reason the binding is:
    /// `BenchItem` carries what the frame *draws*, and a lever is something the surface draws. A
    /// surface you opened yourself has none, which is correct — you already know what you came to
    /// move.
    public private(set) var surfaceLevers: [SurfaceID: [SurfaceLever]] = [:]

    /// What an answer surface is showing, when the surface is one of the two that needs more than a
    /// binding to be drawn.
    ///
    /// Stored here for exactly the reason `bindings` and `surfaceLevers` are: `BenchItem` carries
    /// what the frame draws, and a comparison's reference, columns and rationales — or a critic's
    /// measurement and its two fixes — are things the *surface* draws. Nothing derives one: an
    /// answer is filed by whoever asked the question, and forgotten when its surface goes.
    public private(set) var answers: [SurfaceID: SurfaceAnswer] = [:]

    /// What this surface is answering, or nothing. A Compare with no brief falls back to reading its
    /// binding, which is the honest degraded case rather than an empty panel — see `SurfaceWiring`.
    public func answer(for id: SurfaceID) -> SurfaceAnswer? { answers[id] }

    /// Files what an answer surface is showing. Internal, like `setLevers`: a Compare exists because
    /// somebody asked a question, and nothing else in the frame gets to invent one.
    func file(_ answer: SurfaceAnswer, for id: SurfaceID) { answers[id] = answer }

    /// The levers on a surface, or nothing.
    public func levers(for id: SurfaceID) -> [SurfaceLever] { surfaceLevers[id] ?? [] }

    /// Set by `AppStateStage` when the Director opens a surface. Not public: a lever exists because
    /// an answer put it there, and nothing else in the frame gets to invent one.
    func setLevers(_ levers: [SurfaceLever], for id: SurfaceID) {
        surfaceLevers[id] = levers.isEmpty ? nil : levers
    }

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
    /// Where the rail and the Director's tool calls are kept on disk. Nil with no library.
    @ObservationIgnored public private(set) var sessions: SessionRecorder?

    /// Proposals from the band, when there is one.
    ///
    /// Empty through the whole of Gate A, and that is the point: the rail already renders
    /// `[Proposal]`, so when the Director starts answering, its replies land in this array and the
    /// rail does not change. Until then `proposals` derives the same shape from the song graph.
    public var director: [Proposal] = []

    /// The band, when this session has one.
    ///
    /// Nil in tests and previews, and the rail draws the composer disabled and says why rather than
    /// hiding it — the same honesty rule the empty states follow. `live()` attaches one; a test
    /// attaches a Director over a scripted transport.
    public private(set) var band: DirectorSession?

    /// Installs the band. Called once, by `live()` or by a test.
    public func attach(band session: DirectorSession) { band = session }

    /// The personas' side of the band: the cast, the critics, and the four calls they are driven
    /// through (`PersonaDirecting`).
    ///
    /// Held here rather than made where it is used because `CompareModel` and `CheckModel` hold
    /// their hosts weakly — nothing else would keep it alive — and because a persona's line belongs
    /// to the session rather than to a surface.
    @ObservationIgnored private(set) var conductor: BandDirector?
    @ObservationIgnored public private(set) var inbox: InboxWatcher?
    /// M6: where exports go instead of ~/Music/Mr. Roboto/Exports/<song>; a test sets it.
    @ObservationIgnored public var exportDirectory: URL?

    func attach(conductor: BandDirector) { self.conductor = conductor }

    // MARK: Transport

    public private(set) var transport: TransportState = .stopped
    /// Whether playback should loop. The frame owns the flag; the sources honour it, through
    /// `SongPlayback.loops`.
    public private(set) var isLooping = false

    /// What the transport would play, from the song graph.
    ///
    /// Recomputed whenever the song changes rather than on every render, because resolving a
    /// `MediaRef` touches the file system and the transport bar reads this to decide what to say.
    public private(set) var playback = SongPlayback()

    /// Transport seconds, followed while playing. 0 when stopped.
    public private(set) var playhead: Double = 0

    @ObservationIgnored private let transportHost: TransportHost
    @ObservationIgnored private var playbackHost: SongPlaybackHost?
    /// The poll that makes the readout, the section strip and the play control follow the engine
    /// rather than follow what was last asked of it.
    @ObservationIgnored private var following: Task<Void, Never>?

    // MARK: Init

    /// - Parameters:
    ///   - library: the library to start with. `live()` reads one from disk instead.
    ///   - song: the song to open immediately, if any.
    ///   - store: where `save()` writes and `reloadLibrary()` reads.
    ///   - transportHost: the audio. Inject a double in tests.
    ///   - regions: which flanking regions are folded away. Defaults to what `UserDefaults`
    ///     remembers; a test injects one over a scratch suite rather than writing the app's own.
    public init(library: Library = Library(),
                song: Song? = nil,
                store: LibraryStore? = nil,
                status: LibraryStatus? = nil,
                transportHost: TransportHost = LiveTransportHost(),
                regions: RegionVisibility? = nil,
                primers: PrimerStore? = nil) {
        self.library = library
        self.store = store
        self.sessions = store.map { SessionRecorder(libraryDirectory: $0.directoryURL) }
        self.transportHost = transportHost
        self.bench = Bench()
        self.regions = regions ?? RegionVisibility()
        self.primers = primers ?? PrimerStore()
        self.libraryStatus = status ?? store.map { library.isEmpty ? .empty($0.directoryURL) : .loaded($0.directoryURL) } ?? .unset
        if let song {
            openSongWithoutLogging(song)
        } else {
            // With nothing open the transport still has an honest answer ready, rather than an
            // empty plan that only says so once you have pressed play.
            refreshPlayback()
        }
    }

    /// The app's own state: the library under Application Support, read now.
    public static func live() -> AppState {
        let store = LibraryStore(directoryURL: AppState.defaultLibraryDirectory)
        let state = AppState(store: store, status: .empty(store.directoryURL))
        state.reloadLibrary()
        // The transport plays through the same engine and the same sampler the surfaces audition
        // through. `SurfaceWiring` owns that service, so this is where the two halves meet.
        state.attach(playback: LiveSongPlayer(service: SurfaceWiring.shared.service(for: state)))
        // The band. Building it touches nothing and reaches nowhere: the client has no key until it
        // is asked for one, the workbench holds no audio, and the toolbox is a list of schemas. The
        // key is looked up once, off the launch path, so the composer can say "the band needs a key"
        // before anybody types a sentence into it rather than after.
        let band = DirectorSession.live(for: state)
        state.attach(band: band)
        // The cast and the critics, wired to the same frame. Nothing here reaches the network: a
        // persona's opinion is a pure function of a proposal, and a critic's is a pure function of
        // a measurement.
        state.attach(conductor: BandDirector(app: state))
        Task { await band.refreshKeyStatus() }
        // The inbox: captures from the phone, and anything dropped in the folder.
        let inbox = InboxWatcher(folders: InboxWatcher.defaultFolders) { [weak state] url in
            guard let state else { return false }
            if case .failed(let why) = state.importFromInbox(url) {
                state.note(.session, "The inbox could not take \(url.lastPathComponent)", detail: why)
                return false
            }
            return true
        }
        state.attach(inbox: inbox)
        inbox.start()
        return state
    }

    /// The inbox watcher, kept for the life of the session.
    public func attach(inbox: InboxWatcher) { self.inbox = inbox }

    /// Installs what actually plays the song. The app does this in `live()`; a test injects a
    /// double so `AppState`'s transitions can be asserted with no audio device anywhere.
    public func attach(playback host: SongPlaybackHost) {
        playbackHost = host
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

    /// Opens a `.roboto` package from anywhere — a double-click in Finder, a drop on the Dock icon.
    ///
    /// A song's media is resolved through the library, so a package living somewhere else would open
    /// with its audio missing. One already in the library (matched by the id inside it, not by its
    /// file name) simply opens; any other is copied into the library first, and the rail says so,
    /// because putting a file somewhere is something you should hear about.
    @discardableResult
    public func openPackage(at url: URL) -> Bool {
        let song: Song
        do {
            song = try SongStore(packageURL: url).load()
        } catch {
            note(.session, "Could not read \(url.lastPathComponent)", detail: error.localizedDescription)
            return false
        }
        if library.song(song.id) != nil {
            openSong(song.id)
            return true
        }
        guard let store else {
            note(.session, "No library to copy \(url.lastPathComponent) into")
            return false
        }
        // The library finds packages through its `library.json`; a library that has never been saved
        // has none, and would not see the package it was just handed.
        if !store.exists {
            do {
                try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
                try store.save(library)
            } catch {
                note(.session, "Could not start a library to copy \(url.lastPathComponent) into",
                     detail: error.localizedDescription)
                return false
            }
            reloadLibrary()
            if library.song(song.id) != nil {
                openSong(song.id)
                return true
            }
        }
        var destination = store.directoryURL.appendingPathComponent(url.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = store.directoryURL.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent) \(suffix).\(SongStore.packageExtension)")
            suffix += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            note(.session, "Could not copy \(url.lastPathComponent) into the library", detail: error.localizedDescription)
            return false
        }
        reloadLibrary()
        note(.session, "Copied \(song.title) into the library", detail: destination.path)
        guard library.song(song.id) != nil else {
            note(.session, "\(song.title) was copied but the library did not pick it up", detail: destination.path)
            return false
        }
        openSong(song.id)
        return true
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
        surfaceLevers.removeAll()
        answers.removeAll()
        // Proposals are about the song that was open. Carrying them across would offer work on a
        // part the new song does not hold; `canPerform` would filter them, but silently, and a
        // Director's answer that vanishes without a word is worse than one that is cleared.
        director.removeAll()
        openSongWithoutLogging(song)
        restoreRail(for: song)
        note(.you, "Opened \(song.title)", detail: provenanceSummary(of: song))
        if let opening = Guidance.opening(song) { perform(opening) }
    }

    /// One change to the open song that is not a version — a seed added, a title changed. Marks
    /// the song unsaved and re-reads what the transport can play.
    func updateSong(_ change: (inout Song) -> Void) {
        guard var current = song else { return }
        change(&current)
        song = current
        hasUnsavedChanges = true
        refreshPlayback()
    }

    private func openSongWithoutLogging(_ song: Song) {
        self.song = song
        selectedVersion = song.versions.last?.id
        activeSection = song.sections.first?.id
        hasUnsavedChanges = false
        refreshPlayback()
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
            // A stem that just landed, or a groove that just committed, is playable now: the bar
            // should not need a reopen to notice.
            refreshPlayback()
            if version.type == .mix, transport.isPlaying, let host = playbackHost {
                // M6: a mix move lands on the strips while the song plays.
                let mix = playback.mix, section = activeSection
                Task { await host.mixChanged(mix, section: section) }
            }
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

    /// Replaces the song's form. Sections are the one thing in a song that is edited in place
    /// rather than versioned: they are an ordering of versions, not a version, and the versions
    /// they name are never touched. Returns false with nothing open.
    @discardableResult
    public func arrange(_ sections: [Section]) -> Bool {
        guard var current = song else {
            note(.session, "No song open; nothing to arrange")
            return false
        }
        let cleaned = sections.map { section -> Section in
            var section = section
            section.lengthInBars = max(1, section.lengthInBars)
            // A lane whose part the song does not hold at all is dropped; one whose *pin* has
            // gone is kept, because `version(playing:)` falls back to the part.
            section.stitch = section.stitch.filter { current.latestVersion(of: $0.part) != nil }
            return section
        }
        guard cleaned != current.sections else { return true }
        current.sections = cleaned
        song = current
        hasUnsavedChanges = true
        if activeSection.map({ id in cleaned.contains { $0.id == id } }) != true {
            activeSection = cleaned.first?.id
        }
        refreshPlayback()
        let bars = cleaned.reduce(0) { $0 + $1.lengthInBars }
        note(.you, cleaned.isEmpty ? "Cleared the arrangement" : "Arranged \(cleaned.count) section\(cleaned.count == 1 ? "" : "s")",
             detail: cleaned.isEmpty ? nil : cleaned.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " · ") + " · \(bars) bars")
        return true
    }

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
            albumBindings[retired.id] = nil
            surfaceLevers[retired.id] = nil
            answers[retired.id] = nil
            note(.session, "Closed \(retired.kind.rawValue) to make room", detail: retired.title)
        }
        return id
    }

    public func closeSurface(_ id: SurfaceID) {
        guard let item = bench.items.first(where: { $0.id == id }) else { return }
        bench.close(id)
        bindings[id] = nil
        albumBindings[id] = nil
        surfaceLevers[id] = nil
        answers[id] = nil
        note(.you, "Closed \(item.kind.rawValue)", detail: item.title)
    }

    public func setPinned(_ pinned: Bool, for id: SurfaceID) {
        guard let item = bench.items.first(where: { $0.id == id }), item.isPinned != pinned else { return }
        bench.setPinned(pinned, for: id)
        note(.you, "\(pinned ? "Pinned" : "Unpinned") \(item.kind.rawValue)", detail: item.title)
    }

    /// The versions a surface was opened against.
    public func bound(for id: SurfaceID) -> [VersionID] { bindings[id] ?? [] }

    /// Brings an open surface forward so it fills the bench. Not an event — you are moving between
    /// things that are already open — so nothing is logged.
    public func focusSurface(_ id: SurfaceID) { bench.focus(id) }

    /// What a dock chip does: bring this kind of surface forward if it is already open, otherwise
    /// open it on the most useful thing the song has for it.
    ///
    /// The difference matters now that one surface fills the bench. Pressing a lit chip used to
    /// reopen — which, if the binding had moved on, retired something to make room for a near-twin.
    /// Now it is the switcher: the dock is how you move between surfaces.
    /// Pressing the chip of the kind you are already in steps to the next one of that kind, so two
    /// lanes open on different bars are both reachable from the dock rather than only the newest.
    public func showSurface(_ kind: SurfaceKind) {
        let ofKind = bench.items.filter { $0.kind == kind }
        guard let newest = ofKind.last else {
            perform(Guidance.dockAction(for: kind, in: song))
            return
        }
        if let active = bench.activeID, let index = ofKind.firstIndex(where: { $0.id == active }) {
            focusSurface(ofKind[(index + 1) % ofKind.count].id)
        } else {
            focusSurface(newest.id)
        }
    }

    /// Renames an open surface in place, keeping its pin, its position on the bench and whatever you
    /// are currently working in. A surface that only learns its title after it loads something
    /// ("Bar 9 of Arrival") calls this; it is not an event, so nothing is logged.
    public func retitleSurface(_ id: SurfaceID, to title: String) {
        guard let item = bench.items.first(where: { $0.id == id }), item.title != title else { return }
        bench.rename(id, to: title)
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
        let who: String
        switch source {
        case .you: who = "you"
        case .session: who = "session"
        case .director: who = "director"
        case .persona(let name): who = name.isEmpty ? "band" : name
        }
        sessions?.append(SessionRecord(at: Date(), who: who, text: text, detail: detail, song: song?.title, songID: song?.id.description))
    }

    /// Entries put back from an earlier session, above whatever is there. Not recorded again.
    func prependToLog(_ entries: [SessionEntry]) { log.insert(contentsOf: entries, at: 0) }

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
        case .stopped, .unavailable, .nothingToPlay: await startTransport()
        }
    }

    /// Re-reads what the song has that can be played. Cheap, but it resolves media on disk, so it
    /// is called when the song changes rather than from a view body.
    public func refreshPlayback() {
        playback = SongPlayback.plan(for: song) { [store, song] ref in
            guard let store else { return nil }
            return try? store.mediaURL(for: ref, song: song?.id)
        }.looping(isLooping)
    }

    /// Play what the song actually has.
    ///
    /// Three outcomes, and each is a different thing:
    ///
    /// * **nothing playable** — the song holds no groove with a hit in it and no audio whose media
    ///   is on disk. The transport says which and does not start. This is the case the old
    ///   implementation got wrong: it started a clock, nothing was scheduled against it, and the bar
    ///   lit up as though it were playing.
    /// * **playable, and the graph is there** — the plan is handed to the player (which schedules a
    ///   `GroovePlayer` and/or the take and stems as `ScheduledSource`s on the one engine), then the
    ///   transport is started, then the frame begins following the engine's own position.
    /// * **playable, but no audio device** — the engine's error, verbatim, in `.unavailable`.
    public func startTransport() async {
        guard transport != .playing, transport != .starting else { return }
        refreshPlayback()
        let plan = playback
        guard plan.isPlayable else {
            let silence = plan.silence ?? SongPlayback.Silence(headline: "Nothing to play", detail: "")
            transport = .nothingToPlay(silence)
            note(.session, silence.headline, detail: silence.detail)
            return
        }
        transport = .starting
        do {
            guard let playbackHost else { throw SongPlaybackUnavailable() }
            // The sources are added to the engine *before* the transport starts, so `startTransport`
            // hands each of them its `Transport` and schedules the first look-ahead window before a
            // single frame is rendered.
            try await playbackHost.begin(plan, clock: clock)
            try await transportHost.start(clock: clock)
            transport = .playing
            playhead = 0
            follow()
            note(.you, "Play",
                 detail: plan.summary + String(format: " · %.0f bpm · %@",
                                               clock.tempo, clock.timeSignature.description))
            await noteUnmixedParts(in: plan)
        } catch {
            await playbackHost?.end()
            transport = .unavailable("\(error)")
            note(.session, "The transport could not start", detail: "\(error)")
        }
    }

    /// Says so when the graph ran out of strips. Those parts are audible — they play straight into
    /// the main mixer — but nothing on the Mixer moves them, and a fader that does nothing is worse
    /// than a sentence saying why.
    private func noteUnmixedParts(in plan: SongPlayback) async {
        let unmixed = await playbackHost?.unmixedParts() ?? []
        guard !unmixed.isEmpty else { return }
        let names = unmixed.compactMap { part in song?.versions.last { $0.partID == part } }
            .map(PartLabel.title(of:))
        note(.session, "\(count(unmixed.count, "part")) plays unmixed",
             detail: (names.isEmpty ? "" : names.joined(separator: ", ") + " — ")
                 + "the graph holds \(MixGraph.slotCount) strips and this song plays "
                 + "\(plan.parts.count). They sound, but the Mixer cannot level, pan or solo them.")
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// M6: a mix on the strips right now, without a version — a fader while it is held. The
    /// version is written when it is let go.
    public func previewMix(_ mix: Mix) {
        guard transport.isPlaying, let host = playbackHost else { return }
        let section = activeSection
        Task { await host.mixChanged(mix, section: section) }
    }

    public func stopTransport() async {
        guard transport != .stopped else { return }
        following?.cancel()
        following = nil
        await transportHost.stop()
        await playbackHost?.end()
        transport = .stopped
        playhead = 0
        note(.you, "Stop")
    }

    public func toggleLoop() {
        isLooping.toggle()
        playback = playback.looping(isLooping)
        note(.you, isLooping ? "Loop on" : "Loop off",
             detail: transport.isPlaying ? "Takes effect the next time you press play." : nil)
    }

    // MARK: Following what is actually playing

    /// Polls the player and moves the readout, the section strip and — when the plan runs out — the
    /// play control itself. This is what makes the bar report the engine rather than report the last
    /// thing it was asked to do.
    private func follow() {
        following?.cancel()
        following = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let host = self.playbackHost, self.transport.isPlaying else { return }
                let reading = await host.reading()
                guard !Task.isCancelled, self.transport.isPlaying else { return }
                self.playhead = reading.seconds
                self.followSection(atSeconds: reading.seconds)
                if !reading.isRunning {
                    await self.stopTransport()
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Which section the playhead is in, from the sections' own bar lengths laid end to end.
    public func section(atSeconds seconds: Double) -> SectionID? {
        guard let song, !song.sections.isEmpty else { return nil }
        let beatsPerBar = Double(max(1, clock.timeSignature.beatsPerBar))
        var bar = Int((clock.beat(forSeconds: max(0, seconds)) / beatsPerBar).rounded(.down))
        // Looping, the form comes round: bar 46 of a 46-bar song is its first bar again.
        if isLooping, song.lengthInBars > 0 { bar %= song.lengthInBars }
        var start = 0
        for section in song.sections {
            start += max(1, section.lengthInBars)
            if bar < start { return section.id }
        }
        return song.sections.last?.id
    }

    /// Lights the section the playhead is in. Deliberately not `setActiveSection`: following
    /// playback is not something you did, and the rail should not fill with it.
    private func followSection(atSeconds seconds: Double) {
        guard let id = section(atSeconds: seconds), activeSection != id else { return }
        activeSection = id
        if let host = playbackHost, playback.mix?.sectionGains.isEmpty == false {
            // M6: the section's gain overrides follow the playhead.
            let mix = playback.mix
            Task { await host.mixChanged(mix, section: id) }
        }
    }

    /// Bar and beat, 1-based, the way a transport reads: `"12.3"`.
    public var positionText: String {
        let position = clock.position(forSeconds: max(0, playhead))
        return "\(max(1, position.bar + 1)).\(Int(position.beat) + 1)"
    }

    /// Elapsed time: `"1:04"`.
    public var elapsedText: String {
        let total = Int(max(0, playhead).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Library {
    /// Nothing in any of the five drawers.
    var isEmpty: Bool {
        songs.isEmpty && albums.isEmpty && ideas.isEmpty && records.isEmpty && samples.isEmpty
    }
}
