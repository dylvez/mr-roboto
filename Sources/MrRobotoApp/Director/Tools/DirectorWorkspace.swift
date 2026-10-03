import MusicTheory
import AudioEngine
import Foundation
import Instrument
import Performance
import SongGraph

// The seam between the Director and the app's own state.
//
// `AppState` is the frame's, not the Director's, and the Director must not be the reason it grows
// a method. So the tools talk to this protocol instead, which names exactly the six things they
// need; `AppState` already has all six, so its conformance below is empty.
//
// What this protocol deliberately does not have, and what the Director will need later:
//   - opening a surface (`openSurface(_:title:bound:)`) — B3's job, when the Director starts
//     choosing a surface rather than filling one.
//   - the shared audio engine (`engine()`), for auditioning through the real rig rather than
//     through the `DirectorAudition` seam below.
//   - `director: [Proposal]`, the array the conversation rail already renders.
// None of those are added here, because adding them means editing `AppState`.

/// Everything the tool layer reads from, and writes to, in the running app.
@MainActor
public protocol DirectorWorkspace: AnyObject, Sendable {
    /// The open song, or nil when nothing is open.
    var song: Song? { get }
    /// The library as last read from disk.
    var library: Library { get }
    /// Where media is written. Nil in tests and previews, and the tools say so rather than crash.
    var store: LibraryStore? { get }

    func version(_ id: VersionID) -> PartVersion?

    /// Appends a version to the open song. False when there is no song to append to.
    @discardableResult
    func record(_ version: PartVersion) -> Bool

    /// Replaces the open song's sections. False when there is no song.
    @discardableResult
    func arrange(_ sections: [Section]) -> Bool

    /// Brings a library item into the open song as a version. Nil, with a line in the rail, when
    /// it cannot be.
    @discardableResult
    func adopt(_ payload: LibraryDragPayload) -> VersionID?

    /// Carries a merge move out on a version: audio rendered into the song's package, a written
    /// part moved by arithmetic, recorded as a version derived from the original. An untouched move
    /// returns the version itself.
    func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion

    /// A line in the conversation rail.
    func note(_ text: String, detail: String?)

    // M4: the room.

    /// Who the song has in the room. Empty means everyone.
    var castIDs: [PersonaID] { get }
    /// Sets the song's cast. False when there is no song.
    @discardableResult
    func setCast(_ ids: [PersonaID]) -> Bool
    /// The house voice the Lyricist reads against.
    var voice: LyricCorpus { get }
    /// A line in the rail in a persona's own name.
    func speak(_ persona: String, _ text: String, detail: String?)
    /// A section of the song bounced offline and metered, for the Engineer. Nil when this
    /// workspace has nothing to render with.
    func bounce(section: SectionID?) async throws -> MixObservation?
    /// Opens a Compare of two personas' readings that disagree. Returns the surface's title, or
    /// nil when this workspace has no bench.
    func openDisagreement(_ card: DisagreementCard) -> String?

    // M5: takes.

    /// A take's audio, placed in the song. Nil when this workspace cannot read it.
    func takeAudio(of version: PartVersion) -> Comp.TakeAudio?
    /// The transport clock the song plays at.
    var clock: TransportClock { get }

    // M6: the mix.

    /// The song's plan, as the transport would play it.
    var playback: SongPlayback { get }
    /// The song (or a section) bounced through the newest mix and read, every strip apart. Nil
    /// when this workspace cannot render.
    func mixObservation(section: SectionID?) async throws -> MixObservation?
    /// A mix version. Nil, with the reason in the rail, when it cannot be.
    func recordMix(_ mix: Mix, note: String) -> PartVersion?
    /// M6: "master", "stems", "midi" or "lyrics" written to the song's export folder; the files.
    func export(_ what: String) async throws -> [URL]

    // M7: the record.

    /// An album read from the library's songs (the open one as it is now).
    func observe(album: Album) -> AlbumObservation
    /// The clearances of every sampled source across the album's songs.
    func clearances(of album: Album) -> [SampleClearance]
    /// A new order and gaps, with a note in the rail.
    @discardableResult
    func sequence(_ order: [SongID], gaps: [SongID: Double]?, in album: AlbumID, because: String) -> Bool
    /// The release folder and its report.
    func release(album: AlbumID) async throws -> (URL, Export.AlbumReport)
    /// Two library songs on one grid, rendered and saved as a new song, which is opened.
    func makeMashup(_ request: MashupRequest) async throws -> Song
    /// A library song's stem, or some of its bars, fitted to the open song and added to it; with the
    /// plan's sentences and flags.
    func addSource(_ request: SourceRequest) async throws -> (version: PartVersion, sentences: [String], flags: [String])
    /// What the crate is doing to a record, or why it last failed.
    func crateStatus(of record: RecordID) -> String?
    /// Queues a record's separation in the crate. False when it cannot be.
    func separateRecord(_ record: RecordID) -> Bool
    /// Corrects a record's beat grid in the crate, and returns the record as corrected.
    func correctGrid(_ record: RecordID, _ move: GridMove) throws -> Record
    /// Queues the second beat tracker on a record read before its beats were kept. False when it cannot be.
    func listenForSecondTracker(_ record: RecordID) -> Bool
    /// A source the open song holds, fitted again from its untouched record.
    func refitSource(_ part: PartID, semitones: Int?, atBar: Int?, tighten: Bool?) async throws -> PartVersion
    /// A song from an idea: an empty open song set up in place, or a new one opened. Nil when there is nowhere to.
    func startSong(title: String, tempo: Double, key: Key?, machine: String) -> Song?
    /// Plays a version for the user, now. False when this workspace has nothing to play through.
    func hear(_ version: PartVersion) async -> Bool

    // Writing: the song's own settings, an instrument, a comp kept, another song opened.

    /// The song's settings, each through the frame's own setter. False when nothing changed: the
    /// same value, a value the setter will not take, or no song open.
    @discardableResult func setTitle(_ title: String) -> Bool
    @discardableResult func setArtist(_ artist: String) -> Bool
    /// What the song is about, in a sentence; empty clears it.
    @discardableResult func setBrief(_ brief: String) -> Bool
    @discardableResult func setTempo(_ bpm: Double) -> Bool
    @discardableResult func setKey(_ key: Key?) -> Bool
    @discardableResult func setTimeSignature(_ signature: TimeSignature) -> Bool
    /// The pitched instrument a part plays on, or the song's when `part` is nil. False when the
    /// preset is unknown, no song is open, or it already plays on that preset.
    @discardableResult func setInstrument(_ id: String, for part: PartID?) -> Bool
    /// A groove made from a chop, put on the chop's slices and in its place in the form, as the
    /// Chop lane's Make the groove does. The names of the sections it took over.
    @discardableResult func playGroove(_ groove: PartID, onChop chop: PartID) -> [String]
    /// A chop levelled at its source, or put back as recorded (`AppState.levelChop`). The level
    /// it now plays at, or nil when nothing moved.
    func levelChop(_ chop: PartID, asRecorded: Bool) -> Double?
    /// Rendered audio kept in the open song's package, for a version to point at. Nil, with the
    /// reason in the rail, when there is nowhere to keep it.
    func keepAudio(_ planar: [[Float]], sampleRate: Double) -> MediaRef?
    /// Opens a song from the library, the open one kept first. Nil when the library does not hold it.
    @discardableResult func openSong(_ id: SongID) -> Song?

    // Memory: what the band has said, kept across songs.

    /// Replaces the library's record of what the band has said. Quiet: a log that could not be
    /// written is not worth a line in the rail.
    func keepSaid(_ records: [SaidRecord])

    /// Places the open song in a genre by a profile's id, name or alias; "" to leave it to be
    /// guessed. False with no song open or no such genre.
    @discardableResult func setGenre(_ name: String) -> Bool

    // Developing: the loop arranged, as one move.

    /// Develops the open song in the form given, or the one it would choose, and brings the
    /// master to its loudness when this workspace can render. Nil when nothing in the song plays.
    func develop(form: [(name: String, bars: Int)]?) async -> DevelopmentResult?
    /// The song as it was before it was last developed. False when there is nothing to put back.
    @discardableResult func putBackDevelopment() -> Bool

    // One section at a time.

    /// A section taken to another intensity, kept. Nil when the song has no such section.
    func shade(section: SectionID, to intensity: Double) -> Shading?
    /// A section bounced through the mix and read, LUFS. Nil when this workspace cannot render.
    func loudness(section: SectionID) async -> Double?
    /// A Compare opened on a section as it is and as it stood before. Nil when it has not changed
    /// since the song was opened, or this workspace has no frame to open one in.
    func compareSection(_ section: SectionID) async -> AppState.SectionComparison?

    // Another way: a part played another way in the sections named, and options to hear.

    /// Versions, the form and the section levels kept as one move: a variation written for a
    /// section and the section that now plays it. Nothing joins the form by itself. False when
    /// no song is open or it would not take them.
    @discardableResult
    func keep(_ versions: [PartVersion], arranged sections: [Section], mix: Mix?, saying: String, detail: String?) -> Bool
    /// A Compare opened on a question, its rows the candidates. False when this workspace has no
    /// bench to open one on.
    @discardableResult
    func openCompare(_ brief: CompareBrief) -> Bool
}

extension DirectorWorkspace {
    /// What the crate is doing to a record, or why it last failed. Nil when nothing, and where
    /// there is no crate.
    public func crateStatus(of record: RecordID) -> String? { nil }

    /// Queues a record's separation in the crate. False where there is no crate.
    public func separateRecord(_ record: RecordID) -> Bool { false }

    /// Where there is no crate, no grid is corrected.
    public func correctGrid(_ record: RecordID, _ move: GridMove) throws -> Record { throw CrateError.noLibrary }

    public func listenForSecondTracker(_ record: RecordID) -> Bool { false }

    /// The house calls in force for the open song.
    public var houseBook: HouseBook { HouseBook.of(library, song: song) }

    public func keepSaid(_ records: [SaidRecord]) {}

    /// The open song's genre, set or guessed.
    public var genre: GenreBook.Reading? { GenreBook.standard.genre(of: song) }

    /// The lens the band reads the open song through, when its genre is known.
    public var genreLens: GenreLens? { genre.map { GenreLens($0.profile) } }
}

/// `AppState` seen through the six things the Director needs.
///
/// A one-line `extension AppState: DirectorWorkspace {}` would do — `AppState` already has every
/// member — but it would be a retroactive `Sendable` conformance declared outside the file that
/// owns the class, which Swift 6 warns about and a future language mode makes an error. An adapter
/// costs six forwarding lines and says out loud what the Director is allowed to touch.
@MainActor
public final class AppStateWorkspace: DirectorWorkspace {
    private let app: AppState

    public init(_ app: AppState) { self.app = app }

    public var song: Song? { app.song }
    public var library: Library { app.library }
    public var store: LibraryStore? { app.store }

    public func keepSaid(_ records: [SaidRecord]) { app.keepSaid(records) }

    public func setGenre(_ name: String) -> Bool { app.setGenre(name, by: .director) }

    public func develop(form: [(name: String, bars: Int)]?) async -> DevelopmentResult? {
        await app.developAndMaster(form: form, by: .director)
    }

    @discardableResult
    public func putBackDevelopment() -> Bool { app.putBackDevelopment(by: .director) }

    public func shade(section: SectionID, to intensity: Double) -> Shading? {
        app.shade(section, to: intensity, by: .director)
    }

    public func loudness(section: SectionID) async -> Double? {
        let plan = app.playback
        guard plan.isPlayable,
              let stems = try? await SectionBounce.render(plan, section: section, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                          onlyTheMix: true) else { return nil }
        let lufs = MixMeter.integratedLoudness(stems.mix, sampleRate: stems.sampleRate)
        return lufs.isFinite ? lufs : nil
    }

    public func compareSection(_ section: SectionID) async -> AppState.SectionComparison? {
        await app.compareSection(section)
    }

    public func keep(_ versions: [PartVersion], arranged sections: [Section], mix: Mix?, saying: String, detail: String?) -> Bool {
        app.keepSurfaceWork()
        guard let song = app.song else { return false }
        var versions = versions
        if let mix { versions.append(app.mixVersion(mix, in: song, by: .persona("Director"), note: saying)) }
        guard app.keep(versions, arranged: sections) else { return false }
        app.refreshSurfaces(of: mix == nil ? [.structure] : [.structure, .mixer, .master])
        app.note(.director, saying, detail: detail)
        return true
    }

    public func openCompare(_ brief: CompareBrief) -> Bool {
        let surface = app.openSurface(.compare, title: brief.title, bound: brief.reference.version.map { [$0] } ?? [])
        app.file(.compare(brief), for: surface)
        // The bench holds one Compare: this is a new question on it.
        SurfaceWiring.shared.discardModel(for: surface)
        return true
    }

    public func version(_ id: VersionID) -> PartVersion? { app.version(id) }

    /// A version the band wrote. What the surfaces hold is kept first — an edit made while the
    /// turn ran lands before this, not over it — and a surface open on the part moves to what was
    /// written. Surfaces used to keep editing from the version they opened on, so the next keystroke
    /// on the Lyrics surface put the old words back over the Director's.
    @discardableResult
    public func record(_ version: PartVersion) -> Bool {
        app.keepSurfaceWork()
        guard app.record(version) else { return false }
        app.refreshSurfaces(showing: version.partID, now: version.id)
        return true
    }

    /// The form, the same way: Structure's unkept edit is kept first, then the band's form is
    /// what it shows.
    @discardableResult
    public func arrange(_ sections: [Section]) -> Bool {
        app.keepSurfaceWork()
        return app.arrange(sections, by: .director)
    }

    @discardableResult
    public func adopt(_ payload: LibraryDragPayload) -> VersionID? { app.adopt(payload) }

    public func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion {
        try await MergeAdapter(app: app, service: SurfaceWiring.shared.service(for: app)).render(version, move: move, by: .persona("Director"))
    }

    public func note(_ text: String, detail: String?) { app.note(.session, text, detail: detail) }

    public var castIDs: [PersonaID] { (app.song?.cast ?? []).map { PersonaID($0) } }

    @discardableResult
    public func setCast(_ ids: [PersonaID]) -> Bool { app.setCast(ids, by: .director) }

    public var voice: LyricCorpus { app.voice }

    public func speak(_ persona: String, _ text: String, detail: String?) { app.note(.persona(persona), text, detail: detail) }

    public func bounce(section: SectionID?) async throws -> MixObservation? {
        let plan = app.playback
        guard plan.isPlayable else { return nil }
        let stems = try await SectionBounce.render(plan, section: section, kitsDirectory: AuditionService.defaultKitsDirectory)
        return stems.observation
    }

    public func openDisagreement(_ card: DisagreementCard) -> String? {
        let id = app.openSurface(.compare, title: card.title, bound: card.reference.map { [$0] } ?? [])
        app.file(.compare(card.brief), for: id)
        return card.title
    }

    public func takeAudio(of version: PartVersion) -> Comp.TakeAudio? {
        BoothAdapter(app: app, service: SurfaceWiring.shared.service(for: app)).audio(of: version)
    }

    public var clock: TransportClock { app.clock }

    public var playback: SongPlayback { app.playback }

    public func mixObservation(section: SectionID?) async throws -> MixObservation? {
        guard app.playback.isPlayable else { return nil }
        return try await MixReader.observe(plan: app.playback, mix: nil, section: section, song: app.song,
                                           kitsDirectory: AuditionService.defaultKitsDirectory)
    }

    /// Signed as the Director, and the Mixer moves to it: an open Mixer committing its own older
    /// mix on the next fader move used to undo the Director's cut.
    public func recordMix(_ mix: Mix, note: String) -> PartVersion? {
        app.keepSurfaceWork()
        guard let version = MixAdapter(app: app, author: .persona("Director"))
            .commit(mix, base: Guidance.mixes(in: app.song ?? Song(title: "")).last, note: note) else { return nil }
        app.refreshSurfaces(of: [.mixer, .master])
        return version
    }

    public func observe(album: Album) -> AlbumObservation { app.observe(album: album) }

    public func clearances(of album: Album) -> [SampleClearance] { app.sources(of: album) }

    @discardableResult
    public func sequence(_ order: [SongID], gaps: [SongID: Double]?, in album: AlbumID, because: String) -> Bool {
        app.sequence(order, gaps: gaps, in: album, because: because, by: .director)
    }

    public func makeMashup(_ request: MashupRequest) async throws -> Song { try await app.makeMashup(request) }

    public func addSource(_ request: SourceRequest) async throws -> (version: PartVersion, sentences: [String], flags: [String]) {
        let pick = try app.sourcePick(request)
        let sentences = app.sentences(for: pick, request: request)
        let version = try await app.addSource(request, by: .persona("Director"))
        return (version, sentences, pick.plan.flags)
    }

    public func refitSource(_ part: PartID, semitones: Int?, atBar: Int?, tighten: Bool?) async throws -> PartVersion {
        try await app.refitSource(part, semitones: semitones, atBar: atBar, tighten: tighten, by: .persona("Director"))
    }

    public func crateStatus(of record: RecordID) -> String? { app.crate.status(of: record) ?? app.crate.failures[record] }

    public func correctGrid(_ record: RecordID, _ move: GridMove) throws -> Record {
        try app.correctGrid(record, move, by: .director)
    }

    public func listenForSecondTracker(_ record: RecordID) -> Bool {
        guard app.crate.canRead else { return false }
        app.listenForSecondTracker(record)
        return app.crate.isQueued(.listen, for: record)
    }

    public func separateRecord(_ record: RecordID) -> Bool {
        guard app.library.record(record) != nil, app.crate.canRead else { return false }
        app.separateRecord(record)
        return app.crate.isQueued(.separate, for: record)
    }

    public func startSong(title: String, tempo: Double, key: Key?, machine: String) -> Song? {
        app.startSong(title: title, tempo: tempo, key: key, machine: machine)
    }

    public func hear(_ version: PartVersion) async -> Bool {
        let player = SurfaceWiring.shared.player(for: app)
        await player.play(version)
        return player.isPlaying(version)
    }

    // The Director's own moves, signed as the Director: the rail says who changed the tempo, and
    // the ledger who picked the instrument.
    @discardableResult public func setTitle(_ title: String) -> Bool { app.setTitle(title, by: .director) }
    @discardableResult public func setArtist(_ artist: String) -> Bool { app.setArtist(artist, by: .director) }
    @discardableResult public func setBrief(_ brief: String) -> Bool { app.setBrief(brief, by: .director) }
    @discardableResult public func setTempo(_ bpm: Double) -> Bool { app.setTempo(bpm, by: .director) }
    @discardableResult public func setKey(_ key: Key?) -> Bool { app.setKey(key, by: .director) }
    @discardableResult public func setTimeSignature(_ signature: TimeSignature) -> Bool { app.setTimeSignature(signature, by: .director) }
    @discardableResult public func setInstrument(_ id: String, for part: PartID?) -> Bool {
        app.setInstrument(id, for: part, by: .persona("Director"))
    }
    public func levelChop(_ chop: PartID, asRecorded: Bool) -> Double? {
        app.keepSurfaceWork()
        return app.levelChop(chop, to: asRecorded ? 0 : nil, by: .persona("Director"))
    }

    @discardableResult public func playGroove(_ groove: PartID, onChop chop: PartID) -> [String] {
        app.keepSurfaceWork()
        return app.playGroove(groove, onChop: chop, by: .persona("Director"), source: .director)
    }

    /// Kept in the song's package the way the Booth keeps a take — a song not yet saved is saved
    /// first, so it has a package to keep it in.
    public func keepAudio(_ planar: [[Float]], sampleRate: Double) -> MediaRef? {
        app.keepAudio(planar, sampleRate: sampleRate, what: "the comp")
    }

    /// Opened as the Director's own move, so the frame does not stop the turn that asked for it.
    @discardableResult
    public func openSong(_ id: SongID) -> Song? {
        if app.song?.id == id { return app.song }
        guard app.library.song(id) != nil else { return nil }
        app.openSong(id, by: .director)
        return app.song?.id == id ? app.song : nil
    }

    public func release(album id: AlbumID) async throws -> (URL, Export.AlbumReport) {
        guard let album = app.library.album(id) else { throw Export.ReleaseFailure.noAlbum }
        let base = app.exportDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Mr. Roboto/Exports", isDirectory: true)
        let folder = base.appendingPathComponent(Export.safe(album.title), isDirectory: true)
        let result = try await Export.release(app, album: id, to: folder)
        return (result.folder, result.report)
    }

    public func export(_ what: String) async throws -> [URL] {
        guard let song = app.song else { throw DirectorToolFailure(tool: "export", reason: "No song is open.") }
        let directory = app.exportDirectory ?? Export.defaultDirectory(for: song)
        switch what {
        case "master":
            let result = try await Export.master(app, to: directory)
            return [result.wav, result.report]
        case "stems":
            return try await Export.stems(app, to: directory)
        case "midi":
            return [try Export.midi(app, to: directory)]
        case "lyrics":
            return [try Export.lyrics(app, to: directory)]
        default:
            throw DirectorToolFailure(tool: "export", reason: "\"\(what)\" is not master, stems, midi or lyrics.")
        }
    }
}

/// Something that can make a noise. Kept separate from the workspace because on this machine —
/// and on any CI box — there is no output device, and the honest answer is a sentence rather than
/// a thrown error.
@MainActor
public protocol DirectorAudition: AnyObject, Sendable {
    /// Plays a rendered performance. Returns what happened, for the tool's own result.
    func audition(_ request: DirectorAuditionRequest) async -> DirectorAuditionOutcome
}

/// What to play. Small structured data, like everything else here: the performance is on the
/// workbench, and this names it.
public struct DirectorAuditionRequest: Sendable, Equatable {
    /// A workbench handle: a groove, or a chop played across its pads.
    public var handle: String
    public var bars: Int
    public var tempo: Double

    public init(handle: String, bars: Int, tempo: Double) {
        self.handle = handle
        self.bars = bars
        self.tempo = tempo
    }
}

/// Whether it played, and what to say if it did not.
public struct DirectorAuditionOutcome: Sendable, Equatable, Codable {
    public var played: Bool
    public var detail: String

    public init(played: Bool, detail: String) {
        self.played = played
        self.detail = detail
    }

    /// The answer on a machine with no audio device, which is most automated ones.
    public static let silent = DirectorAuditionOutcome(
        played: false,
        detail: "There is no audio output on this machine, so nothing was played. Everything else about the groove is still true.")
}

/// A workspace with nothing behind it: a song held in memory, no library directory, notes kept in
/// an array. Tests use this, and so does anything that wants the tool layer without the frame.
@MainActor
public final class DirectorScratchWorkspace: DirectorWorkspace {
    public private(set) var song: Song?
    public private(set) var library: Library

    public func keepSaid(_ records: [SaidRecord]) { library.said = records }

    public func setGenre(_ name: String) -> Bool {
        guard song != nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { song?.genre = nil; return true }
        if trimmed.lowercased() == GenreBook.none { song?.genre = GenreBook.none; return true }
        guard let profile = GenreBook.standard.profile(named: trimmed) else { return false }
        song?.genre = profile.id
        return true
    }
    public let store: LibraryStore?

    /// The form and the mix from before the last development, as the frame keeps them.
    private var beforeDevelopment: (sections: [Section], mix: Mix?)?

    /// Nothing to render with, so the arrangement is kept and no loudness is read.
    public func develop(form: [(name: String, bars: Int)]?) async -> DevelopmentResult? {
        guard var current = song,
              let development = Develop.plan(for: current, form: form, genre: GenreBook.standard.genre(of: current)?.profile) else { return nil }
        let before = (current.sections, Guidance.mix(in: current))
        guard (try? current.append(contentsOf: development.versions)) != nil else { return nil }
        current.sections = development.sections
        song = current
        if let mix = development.mix { _ = recordMix(mix, note: "Each section's level, for the arrangement") }
        beforeDevelopment = before
        return DevelopmentResult(development: development, loudness: nil)
    }

    /// Kept, with nothing to render through: the lanes, the intensity and the levels.
    public func shade(section: SectionID, to intensity: Double) -> Shading? {
        guard var current = song, let index = current.sections.firstIndex(where: { $0.id == section }),
              let shading = Develop.shade(section, to: intensity, in: current) else { return nil }
        guard (try? current.append(contentsOf: shading.versions)) != nil else { return nil }
        current.sections[index] = shading.section
        song = current
        if let mix = shading.mix { _ = recordMix(mix, note: "\(shading.section.name)'s levels") }
        return shading
    }

    public func loudness(section: SectionID) async -> Double? { nil }

    public func compareSection(_ section: SectionID) async -> AppState.SectionComparison? { nil }

    public func keep(_ versions: [PartVersion], arranged sections: [Section], mix: Mix?, saying: String, detail: String?) -> Bool {
        guard var current = song, (try? current.append(contentsOf: versions)) != nil else { return false }
        current.sections = sections
        song = current
        if let mix { _ = recordMix(mix, note: saying) }
        return true
    }

    /// Every Compare a tool asked for. Nothing opens: there is no bench.
    public private(set) var compares: [CompareBrief] = []

    public func openCompare(_ brief: CompareBrief) -> Bool {
        compares.append(brief)
        return false
    }

    @discardableResult
    public func putBackDevelopment() -> Bool {
        guard let before = beforeDevelopment, song != nil else { return false }
        beforeDevelopment = nil
        song?.sections = before.sections
        if let current = song, Guidance.mix(in: current) != before.mix { _ = recordMix(before.mix ?? .unity, note: "The mix as it was") }
        return true
    }

    /// Every line the tools wrote, in order.
    public private(set) var notes: [(text: String, detail: String?)] = []

    public init(song: Song? = nil, library: Library = Library(), store: LibraryStore? = nil) {
        self.song = song
        self.library = library
        self.store = store
    }

    public func version(_ id: VersionID) -> PartVersion? {
        song?.version(id) ?? library.ideas.first { $0.id == id }
    }

    @discardableResult
    public func record(_ version: PartVersion) -> Bool {
        guard var current = song else { return false }
        do {
            try current.append(version)
            // As the frame does: a new part joins the sections that have none of its kind. The
            // scratch workspace used to skip this, so a test passed on a song the app would have
            // stacked three bass lines in.
            _ = AppState.joinForm(with: version, in: &current)
            song = current
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func arrange(_ sections: [Section]) -> Bool {
        guard song != nil else { return false }
        song?.sections = sections
        return true
    }

    /// Nothing behind it: an idea can be adopted from the library it was given, a sample or a
    /// record cannot (there is no package to copy media into).
    @discardableResult
    public func adopt(_ payload: LibraryDragPayload) -> VersionID? {
        guard song != nil, payload.kind == .idea,
              let idea = library.ideas.first(where: { $0.id.rawValue == payload.id }) else { return nil }
        let version = PartVersion(partID: PartID(), kind: idea.kind, author: idea.author,
                                  operation: Operation.adopted, note: "from idea: \(idea.note ?? "")")
        return record(version) ? version.id : nil
    }

    /// Written parts move by arithmetic here; audio needs a package, which this workspace has not.
    public func merge(_ version: PartVersion, move: MergeMove) async throws -> PartVersion {
        guard move.movesPitch || move.movesTime else { return version }
        let moved: PartKind
        switch version.kind {
        case .bassline(let line): moved = .bassline(MergeRender.bassline(line, move: move))
        case .progression(let p): moved = .progression(MergeRender.progression(p, move: move))
        case .groove: return version
        default: throw DirectorToolFailure(tool: "merge", reason: "This workspace has nowhere to render audio into.")
        }
        let derived = version.deriving(moved, by: .user, operation: Operation.merge, note: move.sentence)
        return record(derived) ? derived : version
    }

    public func note(_ text: String, detail: String?) {
        notes.append((text, detail))
    }

    public var castIDs: [PersonaID] { (song?.cast ?? []).map { PersonaID($0) } }

    @discardableResult
    public func setCast(_ ids: [PersonaID]) -> Bool {
        guard song != nil else { return false }
        song?.cast = ids.isEmpty ? nil : ids.map(\.rawValue)
        return true
    }

    public var voice: LyricCorpus { LyricCorpus(library.voice ?? []) }

    /// Every line a persona spoke, in order.
    public private(set) var spoken: [(persona: String, text: String, detail: String?)] = []

    public func speak(_ persona: String, _ text: String, detail: String?) { spoken.append((persona, text, detail)) }

    /// Nothing to render with.
    public func bounce(section: SectionID?) async throws -> MixObservation? { nil }

    /// Every card a convening opened.
    public private(set) var disagreements: [DisagreementCard] = []

    public func openDisagreement(_ card: DisagreementCard) -> String? {
        disagreements.append(card)
        return card.title
    }

    /// Audio a test hands in, by version.
    public var takeAudio: [VersionID: Comp.TakeAudio] = [:]

    public func takeAudio(of version: PartVersion) -> Comp.TakeAudio? { takeAudio[version.id] }

    public var clock: TransportClock {
        TransportClock(tempo: song?.tempo ?? 120, timeSignature: song?.timeSignature ?? .fourFour, sampleRate: 48_000)
    }

    public var playback: SongPlayback { SongPlayback.plan(for: song) { _ in nil } }

    /// A reading a test hands in.
    public var mixObservation: MixObservation?

    public func mixObservation(section: SectionID?) async throws -> MixObservation? { mixObservation }

    public func observe(album: Album) -> AlbumObservation {
        var songs = library.songs
        if let song, !songs.contains(where: { $0.id == song.id }) { songs.append(song) }
        return AlbumObservation.of(album, songs: songs)
    }

    public func clearances(of album: Album) -> [SampleClearance] { album.clearances }

    /// Every order the tools set, in order.
    public private(set) var sequenced: [(order: [SongID], because: String)] = []

    @discardableResult
    public func sequence(_ order: [SongID], gaps: [SongID: Double]?, in id: AlbumID, because: String) -> Bool {
        guard let index = library.albums.firstIndex(where: { $0.id == id }) else { return false }
        library.albums[index].songs = order
        if let gaps { for (song, gap) in gaps { library.albums[index].gaps[song] = gap } }
        sequenced.append((order, because))
        return true
    }

    public func release(album: AlbumID) async throws -> (URL, Export.AlbumReport) {
        throw DirectorToolFailure(tool: "release", reason: "This workspace has nowhere to render audio into.")
    }

    public func makeMashup(_ request: MashupRequest) async throws -> Song {
        throw DirectorToolFailure(tool: "mashup", reason: "This workspace has nowhere to render audio into.")
    }

    public func addSource(_ request: SourceRequest) async throws -> (version: PartVersion, sentences: [String], flags: [String]) {
        throw DirectorToolFailure(tool: "adopt", reason: "This workspace has nowhere to render audio into.")
    }

    public func refitSource(_ part: PartID, semitones: Int?, atBar: Int?, tighten: Bool?) async throws -> PartVersion {
        throw DirectorToolFailure(tool: "adopt", reason: "This workspace has nowhere to render audio into.")
    }

    public func startSong(title: String, tempo: Double, key: Key?, machine: String) -> Song? {
        // The frame's new song, form and all, at the frame's tempo range.
        let clamped = tempo.isFinite ? min(AppState.tempoRange.upperBound, max(AppState.tempoRange.lowerBound, tempo)) : 120
        var fresh = song.flatMap { $0.versions.allSatisfy { $0.type == .sound } ? $0 : nil }
            ?? Song.new(title: title.isEmpty ? "Untitled" : title, key: key, tempo: clamped)
        if !title.isEmpty { fresh.title = title }
        fresh.tempo = clamped
        fresh.key = key
        try? fresh.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: machine)), author: .persona("Director"), operation: Operation.written, note: "The drum machine"))
        song = fresh
        return fresh
    }

    public private(set) var heard: [VersionID] = []
    public func hear(_ version: PartVersion) async -> Bool { heard.append(version.id); return false }

    // The song's settings, held to the frame's rules: the same range, the same meters, and false
    // for a value that changes nothing.

    @discardableResult
    public func setTitle(_ title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, !name.isEmpty, name != current.title else { return false }
        song?.title = name
        return true
    }

    @discardableResult
    public func setArtist(_ artist: String) -> Bool {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = song, name != current.artist else { return false }
        song?.artist = name
        return true
    }

    @discardableResult
    public func setBrief(_ brief: String) -> Bool {
        guard var current = song, current.setBrief(brief) else { return false }
        song = current
        return true
    }

    @discardableResult
    public func setTempo(_ bpm: Double) -> Bool {
        guard let current = song, bpm.isFinite else { return false }
        let clamped = min(AppState.tempoRange.upperBound, max(AppState.tempoRange.lowerBound, bpm))
        guard abs(clamped - current.tempo) > 0.001 else { return false }
        song?.tempo = clamped
        return true
    }

    @discardableResult
    public func setKey(_ key: Key?) -> Bool {
        guard let current = song, key != current.key else { return false }
        song?.key = key
        return true
    }

    @discardableResult
    public func setTimeSignature(_ signature: TimeSignature) -> Bool {
        guard let current = song, signature != current.timeSignature,
              signature.beatsPerBar >= 1, [1, 2, 4, 8, 16].contains(signature.beatUnit) else { return false }
        song?.timeSignature = signature
        return true
    }

    /// A scratch workspace reads no audio, so it has no bar to measure.
    public func levelChop(_ chop: PartID, asRecorded: Bool) -> Double? { nil }

    /// As the frame does it: the pick, then the chop's place in the form.
    @discardableResult
    public func playGroove(_ groove: PartID, onChop chop: PartID) -> [String] {
        guard var current = song, current.versions.contains(where: { $0.partID == chop && $0.type == .sample }) else {
            return []
        }
        let chopName = current.versions.last { $0.partID == chop }.map(PartLabel.title(of:)) ?? "the chop"
        let name = current.versions.last { $0.partID == groove }.map(PartLabel.title(of:)) ?? "the groove"
        let pick = PartVersion(partID: PartID(), kind: .sound(Sound(instrument: ChopSound.id(for: chop), forPart: groove)),
                               author: .persona("Director"), operation: Operation.written,
                               note: "\(chopName)'s slices for \(name)")
        guard (try? current.append(pick)) != nil else { return [] }
        let swapped = AppState.sections(of: current, playing: groove, inPlaceOf: chop)
        current.sections = swapped.sections
        song = current
        return swapped.took
    }

    /// As the frame does it: a `.sound` part, one pick a version of the last.
    @discardableResult
    public func setInstrument(_ id: String, for part: PartID?) -> Bool {
        guard let spec = InstrumentVoiceSpec.preset(id: id), let current = song,
              SongPlayback.instrumentID(for: part, in: current) != spec.id else { return false }
        let kind = PartKind.sound(Sound(instrument: spec.id, forPart: part))
        if let previous = current.versions.last(where: { version in
            if case .sound(let sound) = version.kind, sound.forPart == part { return InstrumentVoiceSpec.preset(id: sound.instrument) != nil }
            return false
        }) {
            return record(previous.deriving(kind, by: .persona("Director"), operation: Operation.written, note: spec.name))
        }
        return record(PartVersion(partID: PartID(), kind: kind, author: .persona("Director"), operation: Operation.written, note: spec.name))
    }

    /// Audio a tool kept, by the reference it was given. There is no package, so the reference is
    /// made up and the audio is held here for a test to read.
    public private(set) var kept: [MediaRef: [[Float]]] = [:]

    public func keepAudio(_ planar: [[Float]], sampleRate: Double) -> MediaRef? {
        guard song != nil,
              let hash = ContentHash(hex: (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")) else { return nil }
        let ref = MediaRef(hash: hash, fileExtension: "wav")
        kept[ref] = planar
        return ref
    }

    /// The open song goes back into the library, as a save would put it, and the other comes out.
    @discardableResult
    public func openSong(_ id: SongID) -> Song? {
        if song?.id == id { return song }
        guard let found = library.song(id) else { return nil }
        if let song { library.upsert(song) }
        song = found
        return found
    }

    public func export(_ what: String) async throws -> [URL] {
        guard let current = song, what == "midi" || what == "lyrics" else {
            throw DirectorToolFailure(tool: "export", reason: "This workspace has nowhere to render audio into; it writes MIDI and lyrics only.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("roboto-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if what == "lyrics" {
            guard let sheet = Export.lyricSheet(for: current) else { throw Export.Failure.noWords }
            let url = directory.appendingPathComponent("\(current.title) — lyrics.txt")
            try Data(sheet.utf8).write(to: url)
            return [url]
        }
        let url = directory.appendingPathComponent("\(current.title).mid")
        try MIDIExport.file(for: current).write(to: url)
        return [url]
    }

    public func recordMix(_ mix: Mix, note: String) -> PartVersion? {
        guard let current = song else { return nil }
        let base = Guidance.mixes(in: current).last
        let version = PartVersion(partID: base?.partID ?? PartID(), kind: .mix(mix), author: .user, parents: base.map { [$0.id] } ?? [],
                                  operation: Operation.mix, note: note)
        return record(version) ? version : nil
    }
}
