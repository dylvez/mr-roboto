import AudioEngine
import Foundation
import Instrument
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

        /// Who a version's author is, on the rail: you, the Director, or a band member by name.
        /// The rail used to call every kept version yours, so a groove the Beatmaker wrote read
        /// as something you had done.
        public init(_ author: Author) {
            switch author {
            case .user: self = .you
            case .persona(let name): self = name == "Director" ? .director : .persona(name)
            }
        }

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
        let engine = try await Engine(playerCount: SongPlayback.playerNodes)
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

    /// The instruments imported into this library, as the pickers offer them. The registry
    /// `InstrumentVoiceSpec.preset(id:)` reads is process-wide; this is the observable copy.
    public internal(set) var importedInstruments: [InstrumentVoiceSpec] = []
    /// The recordings that stand in for the kits' hand percussion, on or off; nil when none were
    /// ever brought in. `RecordedPercussion.current` is the process-wide copy kits are built with.
    public internal(set) var recordedPercussion: RecordedPercussion?

    // MARK: Song

    /// The song in the frame. Nil before one is opened; the header, ledger and transport all read it.
    public private(set) var song: Song?

    /// The accented row in the parts ledger, and what most surfaces open against.
    public private(set) var selectedVersion: VersionID?

    /// The lit block in the transport's section strip.
    public private(set) var activeSection: SectionID?

    /// True when the song has versions that are not on disk yet. The header's Save is quiet otherwise.
    public internal(set) var hasUnsavedChanges = false

    /// How long the song sits unsaved before the frame saves it itself. Nil turns autosave off.
    ///
    /// A version is append-only and an arrangement has its own Keep, so nothing here is a change
    /// you would want to lose by *not* saving; what you would lose is the work, if the app went
    /// down between a commit and a ⌘S. So the frame saves a few seconds after the last change,
    /// quietly — the Save button and the "unsaved" mark still say where you stand. A test that
    /// wants the write now sets this short; one that wants to assert on "unsaved" leaves it long.
    @ObservationIgnored public var autosaveDelay: Duration? = .seconds(4)
    @ObservationIgnored private var autosave: Task<Void, Never>?
    /// The sung parts being stretched to a new tempo ahead of the next play (`stretchSungParts`).
    @ObservationIgnored var stretching: Task<Void, Never>?

    /// Where the frame remembers the little it remembers between launches: the last song opened.
    @ObservationIgnored let defaults: UserDefaults

    /// What deleting a song does with its package: the system Trash, where Finder can put it back.
    /// A test moves it somewhere it can look instead.
    @ObservationIgnored var trash: (URL) throws -> URL? = LibraryStore.systemTrash

    /// The song the frame opens on launch, when the library still holds it.
    public static let lastOpenedSongKey = "frame.lastOpenedSong"

    /// Set by File ▸ New Song: the song has nothing in it yet and the one thing worth doing first
    /// is naming it and giving it a tempo and a key, so the header opens the song's settings
    /// unasked. The header takes it, so it fires once.
    public var wantsSongSettings = false

    // MARK: Bench

    /// One surface of each kind, open until you close it. Owned here, mutated through `openSurface`,
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
    /// Options waved away with "Not this", for the song that is open: "stage|kind".
    public internal(set) var nextDismissed: Set<String> = []

    /// What the open song was before it was last developed, for putting it back. Held for the
    /// session and for that song: see `AppState.develop`.
    public internal(set) var beforeDevelopment: BeforeDevelopment?

    /// True while a development is being written.
    public internal(set) var isDeveloping = false

    /// True while the master is being brought to a loudness: the song bounced and read, which
    /// takes seconds a minute of song. The song plays and can be worked on meanwhile.
    public internal(set) var isMastering = false
    @ObservationIgnored private var storedNextPreferences: NextPreferences?
    /// What you choose when the band asks what next, remembered across launches.
    public var nextPreferences: NextPreferences {
        if let stored = storedNextPreferences { return stored }
        let made = NextPreferences(defaults: defaults)
        storedNextPreferences = made
        return made
    }

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
    /// Whether the transport clicks while it plays. The frame owns the flag, as it does the loop.
    public private(set) var isClicking = false

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
    ///   - defaults: where the last opened song is remembered. A test injects a scratch suite.
    public init(library: Library = Library(),
                song: Song? = nil,
                store: LibraryStore? = nil,
                status: LibraryStatus? = nil,
                transportHost: TransportHost = LiveTransportHost(),
                regions: RegionVisibility? = nil,
                primers: PrimerStore? = nil,
                defaults: UserDefaults = .standard) {
        self.library = library
        self.store = store
        self.sessions = store.map { SessionRecorder(libraryDirectory: $0.directoryURL) }
        self.transportHost = transportHost
        self.bench = Bench()
        self.regions = regions ?? RegionVisibility()
        self.primers = primers ?? PrimerStore()
        self.defaults = defaults
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
        // The wiring holds the surfaces' models, so it is what knows which of them has unkept work,
        // and what keeps it.
        state.hasUnkeptChanges = { SurfaceWiring.shared.hasUnkeptChanges(for: $0) }
        state.keepAllSurfaces = { [weak state] in
            guard let state else { return }
            SurfaceWiring.shared.keepAll(on: state.bench)
        }
        state.keepSurface = { item in _ = SurfaceWiring.shared.keeper(for: item)?.keepNow() }
        state.finishRunningWork = { [weak state] keeping in
            guard let state else { return }
            SurfaceWiring.shared.finishRunningWork(on: state, keeping: keeping)
        }
        state.discardSurfaceModel = { SurfaceWiring.shared.discardModel(for: $0) }
        state.startFreshPart = { [weak state] item, type in
            guard let state, type == .melody else { return }
            SurfaceWiring.shared.pianoRollModel(for: item, app: state).startFreshTune()
        }
        state.showMasterTab = { [weak state] id in
            guard let state, let item = state.bench.items.first(where: { $0.id == id }) else { return }
            SurfaceWiring.shared.mixerModel(for: item, app: state).tab = .master
        }
        // Where you left off. A launch used to land on an empty bench every time, with the song
        // you were in one click away in the sidebar; that click was the whole of most launches.
        state.reopenLastSong()
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
        loadImportedInstruments()
        loadRecordedPercussion()
        guard store.exists else {
            library = Library()
            libraryStatus = .empty(directory)
            return
        }
        do {
            let (loaded, unreadable) = try store.loadReporting()
            library = loaded
            libraryStatus = loaded.isEmpty ? .empty(directory) : .loaded(directory)
            // Said, and left as they are on disk: a song this build cannot read is not deleted, and
            // no longer stops every other song from opening.
            if !unreadable.isEmpty {
                note(.session, "\(unreadable.count) song\(unreadable.count == 1 ? "" : "s") could not be read, and \(unreadable.count == 1 ? "was" : "were") left as \(unreadable.count == 1 ? "it was" : "they were")",
                     detail: unreadable.map { "\($0.package): \($0.reason)" }.joined(separator: "\n"))
            }
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
    public func openSong(_ id: SongID, by source: SessionEntry.Source = .you) {
        guard let found = library.song(id) else {
            note(.session, "That song is not in the library")
            return
        }
        open(found, by: source)
    }

    /// Opens a song. Clears the bench — surfaces are bound to versions of the song that was open —
    /// selects the newest version, and puts the song itself on the bench.
    ///
    /// That last step is the difference between opening a song and being handed an empty room. A
    /// song *is* something: a record with a waveform, a key, a tempo and its stems, or failing that
    /// the newest thing anyone made in it. `Guidance.opening(_:)` decides which, and a song holding
    /// nothing Gate A can show opens on nothing rather than on a surface with a shrug in it.
    ///
    /// - Parameter source: who opened it. A switch the Director made itself is not news to the
    ///   band: telling it would stop the turn in flight — the one that asked for the song — and
    ///   start its thread over before it could read what it opened.
    public func open(_ requested: Song, by source: SessionEntry.Source = .you) {
        // Reopening the song that is open — its row in the sidebar, pressed again — is not a way
        // to throw its work away: the library's copy of it is only as new as the last save, so
        // the one in the frame is the one that opens.
        // What is on screen is the open song's: keep it before anything is switched.
        keepSurfaceWork()
        let song = self.song?.id == requested.id ? (self.song ?? requested) : requested
        // What is running for the song being left ends with it — the take kept in the song it was
        // sung in — and the transport stops: the old song used to go on playing under the new one.
        if let current = self.song, current.id != song.id {
            finishRunningWork(true)
            haltTransport()
        }
        let stillUnsaved = hasUnsavedChanges && self.song?.id == song.id
        // The song that was open keeps its work. Opening another one used to drop whatever had not
        // been saved, without a word — the one place in the frame where a click lost something.
        if hasUnsavedChanges, self.song?.id != song.id {
            save()
            // A save that failed leaves the song open rather than dropping what it could not write.
            if store != nil, hasUnsavedChanges, let current = self.song {
                note(.session, "\(current.title) could not be saved, so it stays open",
                     detail: lastSaveError.map { "\($0) Save again, or close it without saving." })
                return
            }
        }
        if let previous = self.song, previous.id != song.id, source != .director { band?.songChanged() }
        leaveSong()
        openSongWithoutLogging(song)
        if stillUnsaved {
            hasUnsavedChanges = true
            scheduleAutosave()
        }
        defaults.set(song.id.rawValue.uuidString, forKey: Self.lastOpenedSongKey)
        restoreRail(for: song)
        note(source, "Opened \(song.title)", detail: provenanceSummary(of: song))
        if let opening = Guidance.opening(song) { perform(opening) }
    }

    /// Closes the open song: saved if it needs it, the bench cleared, nothing in the frame. File ▸
    /// Close Song, and what deleting the open song does first.
    /// - Parameter saving: false when the song is about to be thrown away.
    public func closeSong(saving: Bool = true) {
        guard let current = song else { return }
        if saving { keepSurfaceWork() }
        finishRunningWork(saving)
        // Thrown away: its surfaces' pending keeps go with it, rather than firing into whatever
        // opens next.
        if !saving { for item in bench.items { discardSurfaceModel(item.id) } }
        if saving, hasUnsavedChanges {
            save()
            if store != nil, hasUnsavedChanges {
                note(.session, "\(current.title) could not be saved, so it stays open",
                     detail: lastSaveError.map { "\($0) Save again, or delete it." })
                return
            }
        }
        haltTransport()
        band?.songChanged()
        leaveSong()
        song = nil
        selectedVersion = nil
        activeSection = nil
        hasUnsavedChanges = false
        autosave?.cancel()
        defaults.removeObject(forKey: Self.lastOpenedSongKey)
        refreshPlayback()
        note(.you, "Closed \(current.title)")
    }

    /// Everything that was about the song that was open: the bench, its bindings, the answers.
    private func leaveSong() {
        for item in bench.items { bench.close(item.id) }
        // The last song's failed save is not the next song's: it used to sit beside its Save.
        lastSaveError = nil
        bindings.removeAll()
        // The Album surfaces closed with the bench; their bindings go with them.
        albumBindings.removeAll()
        requests.removeAll()
        surfaceLevers.removeAll()
        answers.removeAll()
        // Proposals are about the song that was open. Carrying them across would offer work on a
        // part the new song does not hold; `canPerform` would filter them, but silently, and a
        // Director's answer that vanishes without a word is worse than one that is cleared.
        director.removeAll()
        nextDismissed.removeAll()
    }

    /// Whether the library may be written: not while `library.json` could not be read, when what is
    /// in memory is an empty stand-in and writing it would erase every album, idea, record and
    /// sample the file holds.
    public var libraryIsWritable: Bool {
        if case .failed = libraryStatus { return false }
        return true
    }

    /// The song the last launch was in, when the library still holds it.
    public var lastOpenedSong: Song? {
        guard let raw = defaults.string(forKey: Self.lastOpenedSongKey), let uuid = UUID(uuidString: raw) else { return nil }
        return library.song(SongID(rawValue: uuid))
    }

    /// Opens the song the last launch was in, if there is one. Quiet otherwise: a first launch, or
    /// a song since deleted, lands on the empty bench as before.
    @discardableResult
    public func reopenLastSong() -> Bool {
        guard song == nil, let last = lastOpenedSong else { return false }
        open(last)
        return true
    }

    /// One change to the open song that is not a version — a seed added, a title changed. Marks
    /// the song unsaved and re-reads what the transport can play.
    func updateSong(_ change: (inout Song) -> Void) {
        guard var current = song else { return }
        change(&current)
        song = current
        hasUnsavedChanges = true
        refreshPlayback()
        scheduleAutosave()
    }

    /// Saves the song a little after the last change, once. Every change to the song passes
    /// through here, so a burst of commits is one write, after the burst.
    private func scheduleAutosave() {
        autosave?.cancel()
        guard let delay = autosaveDelay, store != nil else { return }
        autosave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.hasUnsavedChanges else { return }
            self.save(quietly: true)
        }
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
    /// - Parameter quietly: true when the frame is saving on its own (autosave, a song switch), so
    ///   the rail does not fill with saves you did not ask for. A failure is never quiet.
    public func save(quietly: Bool = false) {
        keepSurfaceWork()
        autosave?.cancel()
        guard let store else {
            note(.session, "Nowhere to save to", detail: "This session has no library directory.")
            return
        }
        guard let song else {
            note(.session, "No song open to save")
            return
        }
        // A library whose `library.json` could not be read is not written over from the empty copy
        // it left in memory: the open song goes into its own package, and nothing else is touched.
        guard libraryIsWritable else {
            do {
                try store.songStore(for: song.id).save(song)
                hasUnsavedChanges = false
                lastSaveError = nil
                if !quietly { note(.you, "Saved \(song.title)", detail: "Its own package only: the library could not be read.") }
            } catch {
                lastSaveError = "\(error)"
                note(.session, "Save failed", detail: "The library could not be read, so nothing is written to it. \(error)")
            }
            return
        }
        do {
            var updated = library
            updated.upsert(song)
            try store.save(updated)
            library = updated
            hasUnsavedChanges = false
            lastSaveError = nil
            libraryStatus = .loaded(store.directoryURL)
            if !quietly { note(.you, "Saved \(song.title)", detail: store.directoryURL.path) }
        } catch {
            lastSaveError = "\(error)"
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
    /// - Parameter joiningForm: whether a *new* playable part is put into every section. True is
    ///   the point — a part you make is in the song — and false is for the one caller that is about
    ///   to place it deliberately: a library row dropped on a section means *that* section, and
    ///   adding it everywhere first would both contradict the drop and stitch the part twice.
    @discardableResult
    public func record(_ version: PartVersion, joiningForm: Bool = true) -> Bool {
        guard var current = song else {
            note(.session, "No song open; nothing to record into")
            return false
        }
        do {
            try current.append(version)
            // A part you have just made is in the song. Before this it was not: the form named
            // parts, a new part was in no section, and so writing chords into an arranged song
            // produced something you could draw, keep and audition and never hear — with nothing
            // anywhere saying why. You take it out of a section if you meant it somewhere else.
            let joined = joiningForm ? Self.joinForm(with: version, in: &current) : 0
            song = current
            hasUnsavedChanges = true
            selectedVersion = version.id
            // A stem that just landed, or a groove that just committed, is playable now: the bar
            // should not need a reopen to notice.
            refreshPlayback()
            scheduleAutosave()
            if version.type == .mix, transport.isPlaying, let host = playbackHost {
                // M6: a mix move lands on the strips while the song plays.
                let mix = playback.mix, section = activeSection
                Task { await host.mixChanged(mix, section: section) }
            }
            note(SessionEntry.Source(version.author), "\(version.operation.capitalized) → \(version.type.rawValue)\(versionNumber(of: version.id).map { " v\($0)" } ?? "")",
                 detail: provenanceLine(for: version))
            if joined > 0 {
                note(.session, "\(PartLabel.title(of: version)) plays in the song",
                     detail: "Added to \(count(joined, "section")). Open Structure to take it out of one.")
            }
            return true
        } catch {
            note(.session, "Could not record that version", detail: "\(error)")
            return false
        }
    }

    /// Several versions and the form, kept as one move: how an arrangement lands. One read of the
    /// song by the transport and one save, and no line in the rail per version — the caller says
    /// what was done, once. Nothing joins the form by itself: the form given is the form.
    @discardableResult
    func keep(_ versions: [PartVersion], arranged sections: [Section]) -> Bool {
        guard var current = song else {
            note(.session, "No song open; nothing to arrange")
            return false
        }
        do {
            try current.append(contentsOf: versions)
        } catch {
            note(.session, "Could not keep the arrangement", detail: "\(error)")
            return false
        }
        current.sections = sections.map { section in
            var section = section
            section.lengthInBars = max(1, section.lengthInBars)
            section.stitch = section.stitch.filter { current.latestVersion(of: $0.part) != nil }
            return section
        }
        song = current
        hasUnsavedChanges = true
        if activeSection.map({ id in current.sections.contains { $0.id == id } }) != true {
            activeSection = current.sections.first?.id
        }
        refreshPlayback()
        scheduleAutosave()
        return true
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
    public func arrange(_ sections: [Section], by source: SessionEntry.Source = .you) -> Bool {
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
        scheduleAutosave()
        let bars = cleaned.reduce(0) { $0 + $1.lengthInBars }
        var detail = cleaned.isEmpty ? nil : cleaned.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " · ") + " · \(bars) bars"
        // What is playing was scheduled from the form as it was; the new one is heard from the
        // next play, and the strip and the fade follow the one that is sounding until then.
        if transport.isPlaying { detail = (detail.map { $0 + ". " } ?? "") + "Heard the next time you press play." }
        note(source, cleaned.isEmpty ? "Cleared the arrangement" : "Arranged \(cleaned.count) section\(cleaned.count == 1 ? "" : "s")",
             detail: detail)
        return true
    }

    public func setActiveSection(_ id: SectionID?) {
        guard activeSection != id else { return }
        activeSection = id
        if let id, let section = song?.section(id) { note(.you, "Moved to \(section.name)") }
    }

    // MARK: Bench

    /// Opens a surface on the bench, or turns the one of its kind that is already open to what is
    /// bound. Returns the id, which is also the key for `bound(for:)`.
    /// Whether an open surface is holding work that has not been kept. The wiring knows, because
    /// it holds the models; a test with no wiring answers no for everything.
    @ObservationIgnored var hasUnkeptChanges: (BenchItem) -> Bool = { _ in false }

    /// Keeps what every open surface is holding, now. Every editing surface keeps itself a moment
    /// after an edit; this is the moment brought forward, for whenever the frame is about to read
    /// the song. The wiring installs it; a test with no wiring has nothing to keep.
    @ObservationIgnored var keepAllSurfaces: () -> Void = {}

    /// Keeps one surface's work, before it closes.
    @ObservationIgnored var keepSurface: (BenchItem) -> Void = { _ in }

    /// Finishes what is running for the song being left — a take, a controller capture, an
    /// audition — keeping what was made when asked. The wiring installs it.
    @ObservationIgnored var finishRunningWork: (_ keeping: Bool) -> Void = { _ in }

    /// A stop handed to the engine by a song switch, which could not wait for it; the next start
    /// waits for it instead.
    @ObservationIgnored private var pendingStop: Task<Void, Never>?

    /// The transport stopped now, the engine's own stop following: a song switch cannot wait on
    /// it, and the song being left must not go on sounding — or being followed — under the next.
    private func haltTransport() {
        guard transport != .stopped else { return }
        following?.cancel()
        following = nil
        transport = .stopped
        playhead = 0
        playbackStartBar = 0
        countInTargetBar = nil
        runningLoopSeconds = nil
        runningForm = nil
        runningClock = nil
        let transportHost = self.transportHost, playbackHost = self.playbackHost
        pendingStop = Task { @MainActor in
            await transportHost.stop()
            await playbackHost?.end()
        }
    }

    /// Lets go of a surface's model so the next draw rebuilds it from its binding.
    @ObservationIgnored var discardSurfaceModel: (SurfaceID) -> Void = { _ in }

    /// Turns an open Mixer to its Master tab. The wiring installs it.
    @ObservationIgnored var showMasterTab: (SurfaceID) -> Void = { _ in }

    /// What is on screen goes into the song before the frame reads it.
    public func keepSurfaceWork() { keepAllSurfaces() }

    /// Opens a surface of `kind` on `bound`, or — when one of that kind is already open — turns
    /// that one to it and brings it forward. There is one of each kind, and nothing is closed to make
    /// room; what the open one was showing is kept first (`turn`), and if the song will not take
    /// it the surface stays where it was and says so.
    @discardableResult
    public func openSurface(_ kind: SurfaceKind, title: String, bound: [VersionID] = [],
                            id: SurfaceID = SurfaceID()) -> SurfaceID {
        if let open = bench.items.first(where: { $0.kind == kind }) {
            if self.bound(for: open.id) == bound {
                retitleSurface(open.id, to: title)
            } else {
                _ = turn(open, to: bound, title: title)
            }
            focusSurface(open.id)
            return open.id
        }
        bench.open(BenchItem(id: id, kind: kind, title: title))
        bindings[id] = bound
        note(.you, "Opened \(kind.rawValue)", detail: title)
        return id
    }

    /// Whether closing this surface would lose something. The ✕ asks before it does.
    public func closingWouldLoseWork(_ id: SurfaceID) -> Bool {
        guard let item = bench.items.first(where: { $0.id == id }) else { return false }
        return hasUnkeptChanges(item)
    }

    /// Closes every surface on the bench.
    /// - Parameter keepingUnkept: true leaves the surfaces holding unkept work open and says so —
    ///   what a menu item does, having no way to ask; the dock's control asks and passes false.
    public func closeAllSurfaces(keepingUnkept: Bool = false) {
        var kept: [BenchItem] = []
        for item in bench.items {
            if keepingUnkept, hasUnkeptChanges(item) { kept.append(item) } else { closeSurface(item.id) }
        }
        if !kept.isEmpty {
            note(.session, "\(kept.count) surface\(kept.count == 1 ? " is" : "s are") still open: unkept work",
                 detail: kept.map { "\($0.kind.rawValue): \($0.title)" }.joined(separator: ", ") + ". Keep it, or close each with its ✕.")
        }
    }

    public func closeSurface(_ id: SurfaceID) {
        guard let item = bench.items.first(where: { $0.id == id }) else { return }
        keepSurface(item)
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

    /// What a dock chip does: bring this kind of surface forward, as you left it, if it is open;
    /// otherwise open it on the most useful thing the song has for it. The dock is how you move
    /// between surfaces, and a surface's title is how you move between its parts.
    public func showSurface(_ kind: SurfaceKind) {
        guard let open = bench.items.first(where: { $0.kind == kind }) else {
            perform(Guidance.dockAction(for: kind, in: song))
            return
        }
        focusSurface(open.id)
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

    /// Turns an open surface to another part of the song, in place: the surface's own switcher.
    ///
    /// What it was showing is kept first, and when the song will not take it the surface stays
    /// where it is — switching must not be how an edit is lost. Then the surface is bound to what
    /// the part's ledger row would open it on, retitled, and its model let go of so the next draw
    /// builds it from the new binding. Its place on the bench and its pin stay.
    @discardableResult
    public func switchSurface(_ id: SurfaceID, to choice: PartChoice) -> Bool {
        guard let item = bench.items.first(where: { $0.id == id }), item.kind.showsParts(of: choice.surface),
              turn(item, to: choice.bound, title: choice.title) else { return false }
        select(choice.version)
        return true
    }

    /// Turns an open surface to a part of its kind that does not exist yet — "New groove", "New
    /// melody" — by opening it on nothing, which is how each of these surfaces starts one. Nothing
    /// is added to the song until something is written: an empty grid is not a groove.
    @discardableResult
    public func startNewPart(_ fresh: FreshPart, on id: SurfaceID) -> Bool {
        guard let item = bench.items.first(where: { $0.id == id }), item.kind.freshParts.contains(fresh),
              turn(item, to: [], title: fresh.title) else { return false }
        startFreshPart(item, fresh.type)
        select(nil)
        note(.you, "\(fresh.title) in \(item.kind.rawValue)")
        return true
    }

    /// What a new part of `type` needs of its surface beyond an empty binding: a Piano roll's
    /// melody mode. The wiring installs it.
    @ObservationIgnored var startFreshPart: (BenchItem, PartType) -> Void = { _, _ in }

    /// Keeps what the surface was showing — and stays when the song will not take it, because
    /// turning must not be how an edit is lost — then binds it to `bound`, retitles it, and lets go
    /// of its model so the next draw builds it from the new binding. Its place and pin stay.
    func turn(_ item: BenchItem, to bound: [VersionID], title: String) -> Bool {
        keepSurfaceWork()
        if hasUnkeptChanges(item) {
            note(.session, "\(item.kind.rawValue) stayed on \(item.title)",
                 detail: "The song would not take its last edits. Keep or undo them, then switch.")
            return false
        }
        bindings[item.id] = bound
        surfaceLevers[item.id] = nil
        answers[item.id] = nil
        bench.rename(item.id, to: title)
        discardSurfaceModel(item.id)
        return true
    }

    /// A surface kept a version, so its binding follows it: the kept version replaces the one of
    /// its part the surface was bound to, or joins the binding when it was bound to none. A Chords
    /// surface opened on nothing, or a Piano roll opened on a groove, was bound to nothing of the
    /// part it made. A restore of that part, or the band's next version of it, then never reached
    /// the surface, and its next keep put the old music back.
    public func surfaceKept(_ version: PartVersion, on surface: SurfaceID) {
        guard let song, bench.items.contains(where: { $0.id == surface }) else { return }
        var bound = self.bound(for: surface)
        if let at = bound.firstIndex(where: { song.version($0)?.partID == version.partID }) {
            bound[at] = version.id
        } else {
            bound.append(version.id)
        }
        bindings[surface] = bound
    }

    // MARK: Rail

    /// Adds a line to the conversation rail. Surfaces use this to say what they did, in your voice.
    public func note(_ text: String, detail: String? = nil) { note(.you, text, detail: detail) }

    /// Lines the app wrote while the rail was folded away, not yet looked at.
    ///
    /// The rail starts collapsed, and it is where a failed save, a refused export or a stem
    /// that could not be read is reported. A line written into a folded column is a line nobody
    /// reads; so the strip counts them, in the warning colour, until the rail is opened.
    public private(set) var unseenSessionNotes = 0

    /// The rail was opened, or its lines were otherwise read.
    public func markRailSeen() { unseenSessionNotes = 0 }

    /// Why the last save failed, or nil. The header says it beside the Save button, because a
    /// save that fails in a folded rail is a save you believe happened.
    public private(set) var lastSaveError: String?

    /// What the frame is doing that takes a while — "Exporting the master…" — or nil. The header
    /// shows it with a spinner. An export used to run with nothing on screen at all: press the
    /// menu item, and for twenty seconds nothing, then a Finder window.
    public private(set) var busy: String?

    /// Runs long work with the header saying what it is. One thing at a time: a second request
    /// while one runs is refused, with a line saying so.
    public func whileBusy<T>(_ what: String, _ work: () async throws -> T) async rethrows -> T? {
        guard busy == nil else {
            note(.session, "Still \(busy!.lowercased())", detail: "Wait for it to finish before \(what.lowercased())")
            return nil
        }
        busy = what
        defer { busy = nil }
        return try await work()
    }

    /// Adds a line attributed to the app rather than to you.
    public func note(_ source: SessionEntry.Source, _ text: String, detail: String? = nil) {
        log.append(SessionEntry(source: source, text: text, detail: detail))
        if source == .session, regions.isCollapsed(.rail) { unseenSessionNotes += 1 }
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

    /// The clock of what is sounding: the one the running transport was started at, else the
    /// song's. A tempo or meter set while the song plays is heard on the next play; until then the
    /// readout, the section strip, the section levels, the fade and a take sung now are measured
    /// against what is playing. They used to read the new tempo at once, and a song sped up
    /// mid-play faded out 16 seconds early and silent to its end.
    public var soundingClock: TransportClock {
        (transport.isPlaying ? runningClock : nil) ?? clock
    }

    /// Space, and the transport's play/stop control.
    public func toggleTransport() async {
        switch transport {
        case .playing, .starting: await stopTransport()
        case .stopped, .unavailable, .nothingToPlay: await startTransport()
        }
    }

    /// A chop part as the transport would read it, its media resolved in this song's package.
    func chopTrack(_ chop: PartID) -> SongPlayback.ChopTrack? {
        guard let song else { return nil }
        return SongPlayback.chopTrack(of: chop, in: song) { [store] ref in
            try? store?.mediaURL(for: ref, song: song.id)
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
        await startTransport(fromBar: 0)
    }

    /// The song bar the running transport started from: 0 for the top. Every reading of the
    /// player is this many bars later in the song than the engine says, and the frame adds it.
    public private(set) var playbackStartBar = 0

    /// Seconds from the song's top to where the transport started.
    private var playbackOffsetSeconds: Double {
        guard playbackStartBar != 0 else { return 0 }
        return soundingClock.seconds(forBar: playbackStartBar)
    }

    /// The bar a counted-in start counts in to, while that run lasts; nil for a plain start.
    public private(set) var countInTargetBar: Int?
    /// Whether the running plan loops, and the length of one pass in transport seconds. Read from
    /// the plan that was started, not from the Loop toggle, which only takes effect on the next play.
    private var runningLoopSeconds: Double?
    /// The form the running transport was started on. The engine plays that one until it stops;
    /// the section strip, per-section gains and the fade follow it rather than an edit made
    /// since, which would light the Verse while the Intro plays and fade the wrong bars.
    @ObservationIgnored private var runningForm: [Section]?
    /// The clock the running transport was started at (`soundingClock`).
    @ObservationIgnored private var runningClock: TransportClock?

    /// The sections that are sounding: the running form while the transport plays, else the song's.
    private var soundingForm: [Section] {
        (transport.isPlaying ? runningForm : nil) ?? song?.sections ?? []
    }

    /// The song's fade-out, in song seconds, when the song has one and plays to its end: a loop
    /// never ends, so it never fades.
    public var fadeSpan: ClosedRange<Double>? {
        guard runningLoopSeconds == nil, song != nil, playback.isArranged else { return nil }
        let bars = soundingForm.reduce(0) { $0 + max(1, $1.lengthInBars) }
        return FadeOut.span(bars: playback.mix?.master.fadeOutBars, songBars: bars, clock: soundingClock)
    }

    /// The fade gain last handed to the player, so it is told only when it moves.
    @ObservationIgnored private var lastFadeGain: Double = 1

    /// Whether the running transport comes round at the end of its form.
    public var isRunningALoop: Bool { transport.isPlaying && runningLoopSeconds != nil }

    /// True while the transport is counting in, before the bar it was started for — any section's,
    /// not only the first: the readout used to say "In 1" only when counting in to bar 1.
    public var isCountingIn: Bool {
        guard transport.isPlaying else { return false }
        guard let target = countInTargetBar else { return playhead < 0 }
        return playhead < soundingClock.seconds(forBar: target) - 1e-6
    }

    /// Plays from a bar of the song rather than the top: the sections from there on, and the takes
    /// where they fall. Playback only ever began at bar 1, so hearing the hook meant sitting
    /// through everything before it, and the Booth recorded from bar 1 whatever section you had
    /// picked. Double-clicking a section in the transport strip, ⇧Space, and Record in the Booth
    /// all come here.
    public func startTransport(fromBar bar: Int) async {
        await startTransport(fromBar: bar, countIn: 0, click: nil)
    }

    /// From `bar`, after `countIn` bars of click. `click` true keeps the click going for the whole
    /// of playback (the Booth's Click); nil leaves it to the transport's own toggle.
    public func startTransport(fromBar bar: Int, countIn: Int, click: Bool?, leavingOut silenced: PartID? = nil) async {
        guard transport != .playing, transport != .starting else { return }
        if let pendingStop {
            self.pendingStop = nil
            await pendingStop.value
        }
        // Play what is on screen: an edit a moment old is in the song before the plan is read.
        keepSurfaceWork()
        refreshPlayback()
        // A counted-in run is a take: one pass. Looped, the count-in bars came round with every
        // pass and a take sung on the second pass landed past the song's end.
        let base = countIn > 0 ? playback.looping(false) : playback
        var plan = base.starting(atBar: max(0, bar), countIn: countIn)
        // The click is the transport's, added to the run it plays and to nothing else. It used to
        // live on the song's plan, which every export and reading renders, so a song exported with
        // Click on had the metronome in the master and in every stem.
        plan = plan.clicking((click ?? false) || isClicking)
        // The Booth's own section, while it records: the take being replaced is not sung over.
        if let silenced { plan.tracks.removeAll { $0.part == silenced } }
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
            // A fade the last play left the master in is not this play's.
            lastFadeGain = 1
            await playbackHost.fade(1)
            try await transportHost.start(clock: clock)
            playbackStartBar = plan.startsAtBar
            runningForm = song?.sections
            runningClock = clock
            countInTargetBar = countIn > 0 ? max(0, bar) : nil
            runningLoopSeconds = plan.loops ? plan.formSeconds : nil
            transport = .playing
            playhead = playbackOffsetSeconds
            followSection(atSeconds: playhead)
            follow()
            // Named for the bar it plays from, not the count-in bar before it.
            let target = max(0, bar)
            let from = target > 0 ? (song?.sections.first { sectionStartBar($0.id) == target }?.name ?? "bar \(target + 1)") : nil
            note(.you, from.map { "Play from \($0)" } ?? "Play",
                 detail: plan.summary + String(format: " · %.0f bpm · %@",
                                               clock.tempo, clock.timeSignature.description))
            await noteUnmixedParts(in: plan)
            let failures = await playbackHost.chopFailures()
            if !failures.isEmpty {
                note(.session, "A groove played on the 808 instead of its chop",
                     detail: failures.joined(separator: " · "))
            }
        } catch {
            await playbackHost?.end()
            transport = .unavailable("\(error)")
            note(.session, "The transport could not start", detail: "\(error)")
        }
    }

    /// Plays from the first bar of a section. A section the song does not hold plays from the top.
    public func startTransport(fromSection id: SectionID?) async {
        await startTransport(fromSection: id, countInBars: 0, click: nil)
    }

    /// The Booth's Record: from the section's first bar, after a count-in, with or without a click.
    public func startTransport(fromSection id: SectionID?, countInBars: Int, click: Bool?,
                               leavingOut silenced: PartID? = nil) async {
        if transport == .playing || transport == .starting { await stopTransport() }
        // The form on screen, before its bars are counted: a section resized a moment ago in
        // Structure is kept first, or the section would start where it used to.
        keepSurfaceWork()
        await startTransport(fromBar: id.flatMap(sectionStartBar) ?? 0, countIn: countInBars, click: click,
                             leavingOut: silenced)
    }

    /// The transport's Click, on or off. Like the loop, it takes effect the next time you press play.
    public func toggleClick() {
        isClicking.toggle()
        note(.you, isClicking ? "Click on" : "Click off",
             detail: transport.isPlaying ? "Takes effect the next time you press play." : nil)
    }

    /// ⇧Space: from the section that is lit in the strip.
    public func playFromActiveSection() async {
        await startTransport(fromSection: activeSection)
    }

    /// The bar a section starts on, from the sections' lengths laid end to end. Nil when the song
    /// does not hold it.
    public func sectionStartBar(_ id: SectionID) -> Int? {
        guard let song else { return nil }
        var bar = 0
        for section in song.sections {
            if section.id == id { return bar }
            bar += max(1, section.lengthInBars)
        }
        return nil
    }

    /// Puts a newly made part into the form, and says how many sections took it.
    ///
    /// Only a **new** part: a new version of a part already in the form is heard there anyway,
    /// because a lane follows its part. Only a kind the transport sounds, and only one that sounds
    /// *yet* — a dry chop joins when it is dusted, which is a new version of the same part, so the
    /// check is on the version rather than on the kind alone. An unarranged song is untouched: it
    /// already plays the newest of everything.
    static func joinForm(with version: PartVersion, in song: inout Song) -> Int {
        guard !song.sections.isEmpty, StructureModel.plays(version) else { return 0 }
        guard !song.sections.contains(where: { $0.stitch.contains(part: version.partID) }) else { return 0 }
        // Only the first version of the part that sounds. A part that sounded before and is in no
        // section now was taken out, or was offered instead of another and not used; its next edit
        // is not an invitation back. An empty groove painted in, or a chop cut, still joins here.
        guard !song.versions.contains(where: { $0.partID == version.partID && $0.id != version.id
                                                && StructureModel.plays($0) }) else { return 0 }
        // Into the sections that have none of its kind: a new groove fills a section with no drums,
        // but does not start playing on top of the groove a section already has. It used to join
        // every section, so three bass lines written to compare all played at once. Where every
        // section already has one, the part's own surface offers to use it instead.
        // And, in a song that has been developed, only into the sections that kind of part plays
        // in: an intro arranged without its bass is not where the next bass line goes.
        var joined = 0
        for index in song.sections.indices where !plays(kind: version.type, in: song.sections[index], of: song)
            && Develop.wants(version.type, in: song.sections[index], of: song) {
            song.sections[index].stitch.append(Lane(part: version.partID))
            joined += 1
        }
        return joined
    }

    /// Whether a section already plays a part of this kind.
    static func plays(kind: PartType, in section: Section, of song: Song) -> Bool {
        section.stitch.contains { lane in song.versions.last { $0.partID == lane.part }?.type == kind }
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
        // By the rule the plan's own mix follows: a solo on a part nothing plays silences nothing.
        var heard = playback
        heard.mix = mix
        heard.settingAsideSilentSolos()
        let applied = heard.mix ?? mix
        Task { await host.mixChanged(applied, section: section) }
    }

    public func stopTransport() async {
        guard transport != .stopped else { return }
        following?.cancel()
        following = nil
        await transportHost.stop()
        await playbackHost?.end()
        transport = .stopped
        playhead = 0
        playbackStartBar = 0
        countInTargetBar = nil
        runningLoopSeconds = nil
        runningForm = nil
        runningClock = nil
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
                // The engine counts from where it started; the song counts from its top. Looping, it
                // comes round: the engine's seconds never do, so the readout used to count on past
                // the song's end while the strip lit the Verse again.
                var seconds = reading.seconds
                if let cycle = self.runningLoopSeconds, cycle > 0 { seconds = seconds.truncatingRemainder(dividingBy: cycle) }
                self.playhead = seconds + self.playbackOffsetSeconds
                self.followSection(atSeconds: self.playhead)
                // The ending, as it plays: the same curve the master exports with. Read every
                // tick, so a fade chosen while the song plays is heard on this pass.
                let fade = self.fadeSpan.map { FadeOut.gain(at: self.playhead, span: $0) } ?? 1
                if abs(fade - self.lastFadeGain) > 0.002 || (fade == 0) != (self.lastFadeGain == 0) {
                    self.lastFadeGain = fade
                    await host.fade(fade)
                }
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
        let sections = soundingForm
        guard !sections.isEmpty else { return nil }
        let length = sections.reduce(0) { $0 + max(1, $1.lengthInBars) }
        let clock = soundingClock
        let beatsPerBar = Double(max(1, clock.timeSignature.beatsPerBar))
        var bar = Int((clock.beat(forSeconds: max(0, seconds)) / beatsPerBar).rounded(.down))
        // Looping, the form comes round: bar 46 of a 46-bar song is its first bar again — or,
        // started from bar 12, its twelfth: a loop from a section runs that section to the end.
        let from = min(playbackStartBar, max(0, length - 1))
        if runningLoopSeconds != nil, length > from, bar >= from { bar = from + (bar - from) % (length - from) }
        var start = 0
        for section in sections {
            start += max(1, section.lengthInBars)
            if bar < start { return section.id }
        }
        return sections.last?.id
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
        let clock = soundingClock
        if isCountingIn {
            // Counting in: the bars left before the section, the way a drummer counts them.
            let target = countInTargetBar.map { clock.seconds(forBar: $0) } ?? 0
            let left = Int(((target - playhead) / clock.secondsPerBar).rounded(.up))
            return "In \(max(1, left))"
        }
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
