import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// Everything a bench item needs to become a working surface, and where it is kept.
///
/// The registry's builder is `(BenchItem, AppState) -> AnyView` and SwiftUI calls it on every
/// render, so the models cannot be built in it: a surface holds the edit in progress (an import
/// mid-analysis, a half-painted pattern, a dragged marker) and rebuilding it per frame would erase
/// that sixty times a second. So the models live here, keyed by the surface's id, for exactly as
/// long as the bench holds the item — the bench's own rule (three open, oldest unpinned retired) is
/// what decides when they go.
///
/// The adapters live here too, and for a second reason: `SoundSurface` and `ChopLaneSurface` hold
/// their host `weak`, deliberately, so a surface never keeps the app alive. Something has to own
/// the adapter, and this is it.
@MainActor
final class SurfaceWiring {

    /// The one wiring the app's registry builds against.
    static let shared = SurfaceWiring()

    /// The audition rig every surface shares. Built lazily around the frame's engine, so launching
    /// on a machine with no output device still gets you a window.
    private(set) var service: AuditionService?

    private var imports: [SurfaceID: ImportModel] = [:]
    private var importAdapters: [SurfaceID: ImportAdapter] = [:]
    private var grids: [SurfaceID: GridModel] = [:]
    private var gridAdapters: [SurfaceID: GridAdapter] = [:]
    private var sounds: [SurfaceID: SoundSurface] = [:]
    private var soundAdapters: [SurfaceID: SoundAdapter] = [:]
    private var chops: [SurfaceID: ChopLaneBinding] = [:]
    private var rolls: [SurfaceID: PianoRollModel] = [:]
    private var bassAdapters: [SurfaceID: BassAdapter] = [:]
    private var chordSheets: [SurfaceID: ChordsModel] = [:]
    private var chordsAdapters: [SurfaceID: ChordsAdapter] = [:]
    private var structures: [SurfaceID: StructureModel] = [:]
    private var merges: [SurfaceID: MergeModel] = [:]
    private var lyricSheets: [SurfaceID: LyricsModel] = [:]
    private var booths: [SurfaceID: BoothModel] = [:]
    private var takeSheets: [SurfaceID: TakesModel] = [:]
    private var mixers: [SurfaceID: MixerModel] = [:]
    private var mashups: [SurfaceID: MashupModel] = [:]
    private var sourceSheets: [SurfaceID: SourcesModel] = [:]
    private var masters: [SurfaceID: MasterModel] = [:]
    private var libraries: [SurfaceID: LibraryBrowserModel] = [:]
    // The two answer surfaces. What they draw is filed on `AppState` by whoever asked the question
    // (see `SurfaceAnswer`); what is kept here is the built model and the host it plays through,
    // for exactly as long as the bench holds the item — the same rule as the four above.
    var compares: [SurfaceID: CompareFilling] = [:]
    var compareAdapters: [SurfaceID: CompareAdapter] = [:]
    var checks: [SurfaceID: CheckFilling] = [:]
    var checkAdapters: [SurfaceID: CheckAdapter] = [:]

    init() {}

    // MARK: The shared audition rig

    /// The audition service for this app, created on first use against the frame's engine.
    ///
    /// One per process, not one per surface: the whole reason this type exists is that four
    /// surfaces that each built their own engine would be four graphs contending for one device.
    func service(for app: AppState) -> AuditionService {
        if let service { return service }
        let built = AuditionService(engine: { [app] in try await app.engine() })
        service = built
        return built
    }

    /// Hands the wiring a service rather than letting it build one against the frame's engine. For a
    /// test that needs the rig on its own kit cache and engine; the app never calls this.
    func use(_ service: AuditionService) { self.service = service }

    private var midiControl: MIDIControl?
    var partPlayer: PartPlayer?

    /// The controller, on the shared rig. One per process, like the service it plays through.
    func midi(for app: AppState) -> MIDIControl {
        if let midiControl { return midiControl }
        let built = MIDIControl(app: app, service: service(for: app))
        built.mixer = { [unowned self] in self.mixer(for: app) }
        midiControl = built
        return built
    }

    private var headlessMixer: MixerModel?

    /// The Mixer a controller moves: an open Mixer surface's model, else one kept here on the
    /// song's newest mix, rebuilt when that mix moved on without it.
    func mixer(for app: AppState) -> MixerModel {
        prune(app)
        if let open = mixers.values.first { return open }
        let newest = app.song.flatMap { Guidance.mixes(in: $0).last }
        if let headlessMixer, headlessMixer.base?.id == newest?.id { return headlessMixer }
        let built = MixerModel(host: MixAdapter(app: app), base: newest)
        headlessMixer = built
        return built
    }

    // MARK: Models

    /// The Import surface, in one of its two lives.
    ///
    /// Opened with nothing bound it is the drop target it has always been. Opened bound to the open
    /// song's take — which is what opening a song from the library now does — it *shows that song*:
    /// the same waveform, readings, stem lanes and Promote lever, reconstituted from the graph by
    /// `ImportModel.open(_:record:)`. Deciding that here rather than inside the model is the point of
    /// this file: the model is handed a song, not taught about the frame.
    func importModel(for item: BenchItem, app: AppState) -> ImportModel {
        prune(app)
        if let existing = imports[item.id] {
            resume(existing, item: item, app: app, adopting: false)
            return existing
        }
        let library = app.store ?? LibraryStore(directoryURL: Self.scratchLibrary)
        // With no library directory (tests, previews) the surface is still a drop target; it simply
        // has nowhere to write, which its own failure path already says out loud.
        let adapter = ImportAdapter(app: app, service: service(for: app),
                                    live: LiveImportHost(library: library))
        let model = ImportModel(host: adapter)
        importAdapters[item.id] = adapter
        imports[item.id] = model
        resume(model, item: item, app: app, adopting: app.store != nil)
        return model
    }

    /// Adopts the open song into a freshly built surface, and starts whatever the frame asked that
    /// surface to do — both on the next main-actor turn rather than now.
    ///
    /// The registry's builder runs inside a SwiftUI body, on every render. Touching the model or
    /// consuming an `AppState` request from in there is mutating observed state during a view update,
    /// which is how a frame turns into a render loop. So the work is scheduled, never done here, and
    /// nothing is scheduled at all unless there is something to do.
    private func resume(_ model: ImportModel, item: BenchItem, app: AppState, adopting: Bool) {
        let song = app.song
        let adopt = adopting && song != nil && adoptsSong(item, app: app)
        let requested = app.requests[item.id] != nil
        guard adopt || requested else { return }
        let record = song.flatMap { recordFor($0, in: app.library) }
        Task { @MainActor in
            if adopt, let song { model.open(song, record: record) }
            if case .separateStems = app.takeRequest(for: item.id) {
                // The adoption above has to land first: separation runs on the record the surface is
                // showing, and until the draft exists there is no record to run it on.
                await model.waitForCompletion()
                model.separateStems()
            }
        }
    }

    /// Whether this bench item is the open song's record rather than a blank import.
    private func adoptsSong(_ item: BenchItem, app: AppState) -> Bool {
        app.bound(for: item.id).contains { id in
            guard let version = app.version(id) else { return false }
            return version.type == .analysis || ImportModel.audio(version) != nil
        }
    }

    /// The library's own `Record` for a song, so the surface shows the imported title and artist
    /// rather than reconstructing them from the song.
    private func recordFor(_ song: Song, in library: Library) -> Record? {
        let seeded = song.seeds.compactMap { seed -> RecordID? in
            if case .importedRecord(let id) = seed.kind { return id }
            return nil
        }
        for id in seeded { if let record = library.record(id) { return record } }
        return nil
    }


    /// A grid, opened against a bound groove version when there is one.
    ///
    /// With nothing bound — the Surfaces menu, ⌘3 — it is an empty sixteen-step bar at the open
    /// song's tempo and meter, which is a grid you can immediately paint on rather than a box.
    func gridModel(for item: BenchItem, app: AppState) -> GridModel {
        prune(app)
        if let existing = grids[item.id] { return existing }
        let tempo = app.song?.tempo ?? 120
        let signature = app.song?.timeSignature ?? .fourFour
        let bound = boundGroove(for: item, app: app)
        // The machine the song plays this groove on — the grid always opened on the 808.
        let machine = app.song.map { SongPlayback.machine(for: bound?.partID, in: $0) } ?? .tr808
        // A groove on a chop opens on the chop's slices. One made from a chop and since put on a
        // machine is still offered its chop, one pick away.
        let playing = app.song.flatMap { song in
            bound.flatMap { ChopSound.part(of: SongPlayback.drumSoundID(for: $0.partID, in: song)) }
        }
        let offered = playing ?? app.song.flatMap { song in bound.flatMap { Self.chop(bound: $0, in: song) } }
        let adapter = GridAdapter(app: app, service: service(for: app), machine: machine, chop: playing,
                                  surface: item.id)
        let model: GridModel
        if let version = bound {
            model = GridModel(host: adapter, version: version, tempo: tempo, timeSignature: signature, machine: machine)
            model.recognise(version)
        } else {
            model = GridModel(host: adapter, tempo: tempo, timeSignature: signature, machine: machine)
        }
        model.houseCalls = app.houseBook.calls
        if let offered, let cut = app.song?.versions.last(where: { $0.partID == offered }) {
            model.offer(GridModel.ChopKit(part: offered, name: PartLabel.title(of: cut)), playing: playing != nil)
        }
        gridAdapters[item.id] = adapter
        model.genre = { [weak app] in GenreLens.of(app?.song) }
        grids[item.id] = model
        return model
    }

    /// The song's genre changed: every open surface that shows a persona's readings reads again.
    func genreChanged() {
        for model in grids.values { model.genreChanged() }
        for model in rolls.values { model.genreChanged() }
        for model in chordSheets.values { model.genreChanged() }
    }

    /// The chop a groove was made from: the sample its lineage starts at, found by walking its
    /// part's versions back to their first parent.
    static func chop(bound groove: PartVersion, in song: Song) -> PartID? {
        let first = song.versions.first { $0.partID == groove.partID } ?? groove
        for parent in first.parents {
            if let version = song.version(parent), version.type == .sample { return version.partID }
        }
        return nil
    }

    func soundSurface(for item: BenchItem, app: AppState) -> (SoundSurface, SoundAdapter) {
        prune(app)
        if let surface = sounds[item.id], let adapter = soundAdapters[item.id] { return (surface, adapter) }
        let adapter = SoundAdapter(app: app, service: service(for: app),
                                   bound: app.bound(for: item.id).first, surface: item.id)
        let surface = SoundSurface(id: item.id, host: adapter)
        soundAdapters[item.id] = adapter
        sounds[item.id] = surface
        return (surface, adapter)
    }

    func chopBinding(for item: BenchItem, app: AppState) -> ChopLaneBinding {
        prune(app)
        if let existing = chops[item.id] { return existing }
        let binding = ChopLaneBinding(item: item, app: app, service: service(for: app))
        chops[item.id] = binding
        return binding
    }

    /// A Piano roll: on a bound bass line, editing it; on a bound groove, writing a new line under
    /// it; on nothing, under the song's newest groove. The song's newest progression is the harmony
    /// either way, and its newest kit sound says how long the kick rings.
    func pianoRollModel(for item: BenchItem, app: AppState) -> PianoRollModel {
        prune(app)
        if let existing = rolls[item.id] {
            // The song it writes against, as it is now: the roll used to keep the chords, groove,
            // tempo and key it opened with for as long as it stayed open.
            let song = app.song
            let grooveVersion = existing.grooveVersion
                .flatMap { app.version($0)?.partID }
                .flatMap { part in song?.versions.last { $0.partID == part } }
                ?? song.flatMap { Guidance.grooves(in: $0).last }
            var groove: Groove?
            if let grooveVersion, case .groove(let g) = grooveVersion.kind { groove = g }
            existing.follow(groove: groove, grooveVersion: grooveVersion?.id, chords: Self.chords(in: song),
                            key: Self.key(of: song), tempo: song?.tempo ?? existing.tempo,
                            timeSignature: song?.timeSignature ?? existing.timeSignature,
                            kickDecaySeconds: Self.kickDecay(in: song))
            return existing
        }
        let adapter = BassAdapter(app: app, service: service(for: app), surface: item.id)
        let song = app.song
        let tempo = song?.tempo ?? 90
        let signature = song?.timeSignature ?? .fourFour
        let key = Self.key(of: song)
        var basslineVersion: PartVersion?
        var melodyVersion: PartVersion?
        var grooveVersion: PartVersion?
        // Which of the two was bound last: the one the roll was writing. A tune kept from a roll
        // opened on a bass line is bound after it, and the roll rebuilt used to open on the bass
        // line and lose the tune from view.
        var writingMelody = false
        for id in app.bound(for: item.id) {
            guard let version = app.version(id) else { continue }
            switch version.kind {
            case .bassline: basslineVersion = basslineVersion ?? version; writingMelody = false
            case .melody: melodyVersion = melodyVersion ?? version; writingMelody = true
            case .groove: grooveVersion = grooveVersion ?? version
            default: break
            }
        }
        // A tune plays on its own instrument — its newest pick, else the song's — and the roll
        // opens in melody mode on it, so the ledger row that is a melody opens as one.
        // A roll opened on no tune starts on the song's instrument, which is what a tune kept from it
        // will play on.
        let melodyInstrument = song.map { SongPlayback.instrumentID(for: melodyVersion?.partID, in: $0) }
        if grooveVersion == nil, let song { grooveVersion = Guidance.grooves(in: song).last }
        var groove: Groove?
        if let grooveVersion, case .groove(let g) = grooveVersion.kind { groove = g }
        let chords = Self.chords(in: song)
        let model = PianoRollModel(host: adapter, groove: groove, grooveVersion: grooveVersion?.id,
                                   chords: chords, key: key, tempo: tempo, timeSignature: signature,
                                   kickDecaySeconds: Self.kickDecay(in: song), bassline: basslineVersion,
                                   melody: melodyVersion, opensOnMelody: writingMelody, instrument: melodyInstrument,
                                   surfaceID: item.id)
        let levers = app.levers(for: item.id)
        model.adoptLevers(lag: levers.first { $0.quantity == .lag }?.value,
                          density: levers.first { $0.quantity == .density }?.value)
        bassAdapters[item.id] = adapter
        model.genre = { [weak app] in GenreLens.of(app?.song) }
        model.before = { [weak app] in app.map { SongsBefore.of($0.library, besides: $0.song?.id) } }
        model.house = { [weak app] in app?.houseBook }
        rolls[item.id] = model
        return model
    }

    /// The song's harmony as the roll writes to it: its newest progression's spans.
    static func chords(in song: Song?) -> [ChordSpan] {
        song.flatMap { Guidance.progressions(in: $0).last }.flatMap { version -> [ChordSpan]? in
            if case .progression(let p) = version.kind { return p.spans }
            return nil
        } ?? []
    }

    /// The key a roll or a lead sheet writes in: the one set in Song settings, else what the
    /// record's analysis heard, else C. Settings first, because setting the key is saying it.
    static func key(of song: Song?) -> Key {
        song?.key ?? Guidance.analysis(in: song)?.dominantKey ?? Key(tonic: NoteName(.c))
    }

    /// A lead sheet: on a bound progression, editing it; otherwise a new one in the song's key.
    func chordsModel(for item: BenchItem, app: AppState) -> ChordsModel {
        prune(app)
        if let existing = chordSheets[item.id] {
            existing.follow(beatsPerBar: app.song?.timeSignature.beatsPerBar ?? existing.beatsPerBar)
            return existing
        }
        let adapter = ChordsAdapter(app: app, service: service(for: app), surface: item.id)
        let song = app.song
        let key = Self.key(of: song)
        let bound = app.bound(for: item.id).compactMap { app.version($0) }.first { $0.type == .progression }
        let model = ChordsModel(host: adapter, key: key, beatsPerBar: song?.timeSignature.beatsPerBar ?? 4,
                                progression: bound, surfaceID: item.id)
        chordsAdapters[item.id] = adapter
        model.genre = { [weak app] in GenreLens.of(app?.song) }
        model.before = { [weak app] in app.map { SongsBefore.of($0.library, besides: $0.song?.id) } }
        model.house = { [weak app] in app?.houseBook }
        chordSheets[item.id] = model
        return model
    }

    /// The form: the song's sections as a working copy, kept through `AppState.arrange`.
    func structureModel(for item: BenchItem, app: AppState) -> StructureModel {
        prune(app)
        if let existing = structures[item.id] {
            existing.sync(with: app.song)
            return existing
        }
        let model = StructureModel(host: StructureAdapter(app: app), song: app.song, surfaceID: item.id)
        model.genre = { [weak app] in app?.genre?.profile }
        structures[item.id] = model
        return model
    }

    /// A merge of the two bound versions, planned against the open song's key and tempo.
    func mergeModel(for item: BenchItem, app: AppState) -> MergeModel {
        prune(app)
        if let existing = merges[item.id] { return existing }
        let adapter = MergeAdapter(app: app, service: service(for: app))
        let bound = app.bound(for: item.id).compactMap { app.version($0) }
        let model = MergeModel(host: adapter, a: bound.first, b: bound.dropFirst().first,
                               song: app.song, library: app.library, surfaceID: item.id)
        merges[item.id] = model
        return model
    }

    /// The Booth: recording against the song as it plays, on the active section.
    func boothModel(for item: BenchItem, app: AppState) -> BoothModel {
        prune(app)
        if let existing = booths[item.id] { return existing }
        let model = BoothModel(host: BoothAdapter(app: app, service: service(for: app)), surfaceID: item.id)
        booths[item.id] = model
        return model
    }

    /// The takes bound to the item, as lanes; the comp is kept through the same adapter.
    func takesModel(for item: BenchItem, app: AppState) -> TakesModel {
        prune(app)
        if let existing = takeSheets[item.id] {
            // Takes sung in the Booth while this surface is open join its lanes: every take of the
            // part it shows. Cheap when nothing is new — the model compares ids first.
            if let song = app.song, let part = existing.takes.first?.partID {
                existing.update(takes: Guidance.takes(in: song).filter { $0.partID == part }, song: song)
            }
            return existing
        }
        let bound = app.bound(for: item.id).compactMap { app.version($0) }
        let model = TakesModel(host: BoothAdapter(app: app, service: service(for: app)), takes: bound,
                               song: app.song, surfaceID: item.id)
        if let song = app.song, let part = bound.first?.partID,
           let comp = Guidance.comps(in: song).last(where: { $0.partID == part }) {
            model.adoptComp(comp, song: song)
        }
        takeSheets[item.id] = model
        return model
    }

    /// The Sources surface: a record's stem or bars pulled into the open song, previewed through
    /// the shared rig.
    func sourcesModel(for item: BenchItem, app: AppState) -> SourcesModel {
        prune(app)
        if let existing = sourceSheets[item.id] { return existing }
        let model = SourcesModel(app: app, service: service(for: app), surfaceID: item.id)
        sourceSheets[item.id] = model
        return model
    }

    /// The Library surface: its shelf, its queries and what is chosen, remembered in the app's defaults.
    func libraryModel(for item: BenchItem, app: AppState) -> LibraryBrowserModel {
        prune(app)
        if let existing = libraries[item.id] { return existing }
        let model = LibraryBrowserModel(app: app, memory: LibraryBrowserMemory(defaults: app.defaults))
        libraries[item.id] = model
        return model
    }

    /// The Mashup surface: two library songs on one grid, previewed through the shared rig.
    func mashupModel(for item: BenchItem, app: AppState) -> MashupModel {
        prune(app)
        if let existing = mashups[item.id] { return existing }
        let model = MashupModel(app: app, service: service(for: app), surfaceID: item.id)
        mashups[item.id] = model
        return model
    }

    /// The mix the Mixer and the Master work on: the song's newest, the one that plays — never the
    /// version the surface happened to open on. Rebuilt on a restore or a mix the band kept, the
    /// Mixer used to come back on its old binding, and the next fader move kept that old mix over
    /// everything since.
    private static func workingMix(in app: AppState) -> PartVersion? {
        app.song.flatMap { Guidance.mixes(in: $0).last }
    }

    /// The Mixer on the song's newest mix, or on unity.
    func mixerModel(for item: BenchItem, app: AppState) -> MixerModel {
        prune(app)
        if let existing = mixers[item.id] {
            existing.syncRows()
            return existing
        }
        let model = MixerModel(host: MixAdapter(app: app), base: Self.workingMix(in: app), surfaceID: item.id)
        mixers[item.id] = model
        return model
    }

    /// The Master on the song's newest mix, or on unity.
    func masterModel(for item: BenchItem, app: AppState) -> MasterModel {
        prune(app)
        if let existing = masters[item.id] { return existing }
        let model = MasterModel(host: MixAdapter(app: app), base: Self.workingMix(in: app), surfaceID: item.id)
        model.genre = { [weak app] in GenreLens.of(app?.song) }
        masters[item.id] = model
        return model
    }

    /// The words: on a bound lyric, editing it; otherwise a blank page, read against the house voice.
    func lyricsModel(for item: BenchItem, app: AppState) -> LyricsModel {
        prune(app)
        if let existing = lyricSheets[item.id] { return existing }
        let bound = app.bound(for: item.id).compactMap { app.version($0) }.first { $0.type == .lyric }
        let model = LyricsModel(host: LyricsAdapter(app: app, surface: item.id), lyric: bound, corpus: app.voice,
                                title: app.song?.title, surfaceID: item.id)
        model.genre = { [weak app] in GenreLens.of(app?.song) }
        lyricSheets[item.id] = model
        return model
    }

    /// How long the song's kick rings, from its newest kit sound's decay, for the Bassist's R9.
    /// 0 when the song has no kit sound: the 808's default kick is well under the 400 ms line.
    nonisolated static func kickDecay(in song: Song?) -> Double {
        guard let song else { return 0 }
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind, let preset = SynthMachine.preset(id: sound.instrument),
                  let kick = SongPlayback.shaped(preset, in: song).voices.first(where: { $0.kind == .kick }) else { continue }
            return kick.tone.decaySeconds(decay: kick.controls.decay)
        }
        return 0
    }

    // MARK: Housekeeping

    /// Forget everything the bench no longer holds. Called on every lookup, which is at most three
    /// items, and is what makes a closed surface's engine work and its draft go away together.
    /// Has a surface's model read its binding again, in place: a Chop lane whose chop was given
    /// another level reads its bar at it. Nothing to do for a surface with no model built.
    func reloadModel(for id: SurfaceID) {
        chops[id]?.load()
    }

    /// Lets go of a surface's model, so the next draw builds it again from its binding — after
    /// the frame changed what the surface is bound to (a version restored from Parts).
    func discardModel(for id: SurfaceID) {
        imports[id]?.abandon()
        imports[id] = nil; importAdapters[id] = nil
        grids[id] = nil; gridAdapters[id] = nil
        sounds[id] = nil; soundAdapters[id] = nil
        chops[id] = nil
        rolls[id] = nil; bassAdapters[id] = nil
        chordSheets[id] = nil; chordsAdapters[id] = nil
        structures[id] = nil
        merges[id] = nil
        lyricSheets[id] = nil
        takeSheets[id] = nil
        mixers[id] = nil
        masters[id] = nil
        libraries[id] = nil
        compares[id] = nil; compareAdapters[id] = nil
    }

    func prune(_ app: AppState) {
        let open = Set(app.bench.items.map(\.id))
        for (id, model) in imports where !open.contains(id) { model.abandon() }
        imports = imports.filter { open.contains($0.key) }
        importAdapters = importAdapters.filter { open.contains($0.key) }
        grids = grids.filter { open.contains($0.key) }
        gridAdapters = gridAdapters.filter { open.contains($0.key) }
        sounds = sounds.filter { open.contains($0.key) }
        soundAdapters = soundAdapters.filter { open.contains($0.key) }
        chops = chops.filter { open.contains($0.key) }
        rolls = rolls.filter { open.contains($0.key) }
        bassAdapters = bassAdapters.filter { open.contains($0.key) }
        chordSheets = chordSheets.filter { open.contains($0.key) }
        chordsAdapters = chordsAdapters.filter { open.contains($0.key) }
        structures = structures.filter { open.contains($0.key) }
        merges = merges.filter { open.contains($0.key) }
        lyricSheets = lyricSheets.filter { open.contains($0.key) }
        // A Booth closed mid-take keeps the take, as Stop would: the take is the singer's, and
        // letting the model go took the recording with it and left the input tapped.
        for (id, booth) in booths where !open.contains(id) { booth.finishTake(keeping: true) }
        booths = booths.filter { open.contains($0.key) }
        takeSheets = takeSheets.filter { open.contains($0.key) }
        mixers = mixers.filter { open.contains($0.key) }
        mashups = mashups.filter { open.contains($0.key) }
        sourceSheets = sourceSheets.filter { open.contains($0.key) }
        libraries = libraries.filter { open.contains($0.key) }
        masters = masters.filter { open.contains($0.key) }
        compares = compares.filter { open.contains($0.key) }
        compareAdapters = compareAdapters.filter { open.contains($0.key) }
        checks = checks.filter { open.contains($0.key) }
        checkAdapters = checkAdapters.filter { open.contains($0.key) }
    }

    /// Whether anything is still held for this surface. For a test; the app never asks.
    func holds(_ id: SurfaceID) -> Bool {
        imports[id] != nil || grids[id] != nil || sounds[id] != nil || chops[id] != nil
            || rolls[id] != nil || chordSheets[id] != nil || structures[id] != nil || merges[id] != nil || lyricSheets[id] != nil
            || compares[id] != nil || checks[id] != nil
    }

    /// The Chop lane this surface is drawing, when it has one. The only way a critic's marks reach
    /// a lane — `PersonaDirecting.mark(_:on:)` goes through here, and nothing else writes one.
    func chopBinding(holding id: SurfaceID) -> ChopLaneBinding? { chops[id] }

    /// The model behind a surface that edits a part, when it has been built. Nil for a surface
    /// that keeps nothing of its own (Sound and the Mixer keep every move as they make it; the rest
    /// hold nothing), and for one the bench has not drawn yet.
    func keeper(for item: BenchItem) -> (any KeepsAsItGoes)? {
        switch item.kind {
        case .grid: return grids[item.id]
        case .pianoRoll: return rolls[item.id]
        case .chords: return chordSheets[item.id]
        case .lyrics: return lyricSheets[item.id]
        case .structure: return structures[item.id]
        case .chopLane:
            if case .ready(let surface)? = chops[item.id]?.state { return surface }
            return nil
        default: return nil
        }
    }

    /// Whether a surface is holding work that has not been kept. With every editing surface
    /// keeping itself, this is a moment's window after an edit, a keep the song refused, an import
    /// still running, or a take being recorded.
    func hasUnkeptChanges(for item: BenchItem) -> Bool {
        switch item.kind {
        case .importRecord: return imports[item.id]?.hasUnkeptChanges ?? false
        case .booth: return booths[item.id]?.state == .recording
        case .sound: return sounds[item.id]?.isDirty ?? false
        default: return keeper(for: item)?.hasUnkeptChanges ?? false
        }
    }

    /// Keeps what every open surface is holding, now. The frame calls this before it reads the
    /// song — play, save, a song switch, a Director turn, quitting — so what is on screen is what
    /// is in the song. Returns false when any keep was refused.
    @discardableResult
    /// Everything running for the song being left, finished: a take kept or let go, the
    /// controller's capture the same, anything auditioning stopped.
    func finishRunningWork(on app: AppState, keeping: Bool) {
        for model in booths.values { model.finishTake(keeping: keeping) }
        for model in imports.values { model.abandon() }
        midiControl?.finishForSongChange(keeping: keeping)
        for sheet in takeSheets.values { sheet.stopAudition() }
        partPlayer?.stop()
    }

    func keepAll(on bench: Bench) -> Bool {
        var allKept = true
        for item in bench.items {
            if let keeper = keeper(for: item), keeper.hasUnkeptChanges, !keeper.keepNow() { allKept = false }
            // Sound keeps on a knob's release, and a draft it holds — a machine clicked, a knob
            // not yet let go — is kept here with the rest, before play, a save, a switch or quit.
            if item.kind == .sound, let sound = sounds[item.id], sound.isDirty, sound.commit() == nil { allKept = false }
        }
        return allKept
    }

    /// A title the surface keeps up to date itself, for the card's header, when its bench title can
    /// go stale: a Piano roll opened on a bass line and switched to melody mode is writing a tune.
    func liveTitle(for item: BenchItem) -> String? {
        switch item.kind {
        case .pianoRoll: return rolls[item.id]?.title
        default: return nil
        }
    }

    /// The part a surface is working on, when it has one: what its header's "heard" tag is about.
    /// The binding alone is not enough — a Piano roll opened under a groove is bound to the groove,
    /// and a new groove has no part until its first keep — so the models answer where they can.
    func part(for item: BenchItem, app: AppState) -> PartID? {
        switch item.kind {
        case .grid:
            if let model = grids[item.id] { return (model.versions.last ?? model.base)?.partID }
        case .pianoRoll:
            if let model = rolls[item.id] { return model.part }
            return nil
        case .chords:
            if let model = chordSheets[item.id] { return model.part }
        case .mixer, .master, .structure, .booth, .takes, .album, .cast, .mashup, .sources, .merge, .compare, .check, .lyrics, .library:
            return nil
        default:
            break
        }
        guard let song = app.song, let first = app.bound(for: item.id).first else { return nil }
        return song.version(first)?.partID
    }

    /// ⌘Z on the surface in front.
    func undo(for item: BenchItem) { keeper(for: item)?.undo() }
    func redo(for item: BenchItem) { keeper(for: item)?.redo() }
    func canUndo(for item: BenchItem) -> Bool { keeper(for: item)?.canUndo ?? false }
    func canRedo(for item: BenchItem) -> Bool { keeper(for: item)?.canRedo ?? false }

    /// The first bound version that actually holds a groove. A grid opened on a sample (say, from
    /// the ledger) is an empty grid rather than a crash.
    private func boundGroove(for item: BenchItem, app: AppState) -> PartVersion? {
        for id in app.bound(for: item.id) {
            guard let version = app.version(id), case .groove = version.kind else { continue }
            return version
        }
        return nil
    }

    /// Somewhere to put an import when the session has no library. Not the real library, and never
    /// written to unless an import actually completes.
    private static var scratchLibrary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/Scratch", isDirectory: true)
    }
}

// MARK: - The Sound panel

/// The Sound surface as a bench panel.
///
/// The surface itself is happy with nothing selected — it starts a new part from a machine preset,
/// which is a legitimate way to make a sound — but a panel that silently did that would leave you
/// wondering what it was editing. So the panel says which it is doing, and when the song *does* hold
/// sounds it offers them rather than telling you to go and find them in the ledger.
struct SoundSurfacePanel: View {
    @Bindable var surface: SoundSurface
    let hasSelection: Bool
    let app: AppState

    private var offers: [Proposal] {
        guard !hasSelection, let song = app.song else { return [] }
        return Guidance.shapeableSounds(in: song).reversed()
            .compactMap { PartActions.primary(for: $0, in: song) }
            .filter { app.canPerform($0.action) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasSelection {
                VStack(alignment: .leading, spacing: 12) {
                    EmptyNote(title: "Nothing selected: this is a new sound.",
                              detail: offers.isEmpty
                                  ? "Every knob here is shaping a new part from the machine preset, and the "
                                    + "first commit starts it. This song holds no sound to edit instead."
                                  : "Every knob here is shaping a new part from the machine preset. To edit "
                                    + "one this song already has instead:")
                    ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                        ProposalButton(proposal: offer, isLeading: index == 0) {
                            app.perform(offer.action)
                        }
                    }
                }
                .padding(.horizontal, Design.Metric.inset)
                .padding(.top, Design.Metric.inset)
            }
            SoundSurfaceView(surface: surface)
        }
        .background(Design.Palette.panel)
    }
}
