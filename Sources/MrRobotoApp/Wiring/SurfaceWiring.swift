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
        let adapter = GridAdapter(app: app, service: service(for: app))
        let tempo = app.song?.tempo ?? 120
        let signature = app.song?.timeSignature ?? .fourFour
        let model: GridModel
        if let version = boundGroove(for: item, app: app) {
            model = GridModel(host: adapter, version: version, tempo: tempo, timeSignature: signature)
        } else {
            model = GridModel(host: adapter, tempo: tempo, timeSignature: signature)
        }
        gridAdapters[item.id] = adapter
        grids[item.id] = model
        return model
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
        if let existing = rolls[item.id] { return existing }
        let adapter = BassAdapter(app: app, service: service(for: app))
        let song = app.song
        let tempo = song?.tempo ?? 90
        let signature = song?.timeSignature ?? .fourFour
        let key = Guidance.analysis(in: song)?.dominantKey ?? song?.key ?? Key(tonic: NoteName(.c))
        var basslineVersion: PartVersion?
        var grooveVersion: PartVersion?
        for id in app.bound(for: item.id) {
            guard let version = app.version(id) else { continue }
            switch version.kind {
            case .bassline: basslineVersion = basslineVersion ?? version
            case .groove: grooveVersion = grooveVersion ?? version
            default: break
            }
        }
        if grooveVersion == nil, let song { grooveVersion = Guidance.grooves(in: song).last }
        var groove: Groove?
        if let grooveVersion, case .groove(let g) = grooveVersion.kind { groove = g }
        let chords = song.flatMap { Guidance.progressions(in: $0).last }.flatMap { version -> [ChordSpan]? in
            if case .progression(let p) = version.kind { return p.spans }
            return nil
        } ?? []
        let model = PianoRollModel(host: adapter, groove: groove, grooveVersion: grooveVersion?.id,
                                   chords: chords, key: key, tempo: tempo, timeSignature: signature,
                                   kickDecaySeconds: Self.kickDecay(in: song), bassline: basslineVersion,
                                   surfaceID: item.id)
        let levers = app.levers(for: item.id)
        model.adoptLevers(lag: levers.first { $0.quantity == .lag }?.value,
                          density: levers.first { $0.quantity == .density }?.value)
        bassAdapters[item.id] = adapter
        rolls[item.id] = model
        return model
    }

    /// A lead sheet: on a bound progression, editing it; otherwise a new one in the song's key.
    func chordsModel(for item: BenchItem, app: AppState) -> ChordsModel {
        prune(app)
        if let existing = chordSheets[item.id] { return existing }
        let adapter = ChordsAdapter(app: app, service: service(for: app))
        let song = app.song
        let key = Guidance.analysis(in: song)?.dominantKey ?? song?.key ?? Key(tonic: NoteName(.c))
        let bound = app.bound(for: item.id).compactMap { app.version($0) }.first { $0.type == .progression }
        let model = ChordsModel(host: adapter, key: key, beatsPerBar: song?.timeSignature.beatsPerBar ?? 4,
                                progression: bound, surfaceID: item.id)
        chordsAdapters[item.id] = adapter
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

    /// How long the song's kick rings, from its newest kit sound's decay, for the Bassist's R9.
    /// 0 when the song has no kit sound: the 808's default kick is well under the 400 ms line.
    nonisolated static func kickDecay(in song: Song?) -> Double {
        guard let song else { return 0 }
        for version in song.versions.reversed() {
            guard case .sound(let sound) = version.kind, let machine = SynthMachine.preset(id: sound.instrument),
                  let kick = machine.voices.first(where: { $0.kind == .kick }) else { continue }
            return kick.tone.decaySeconds(decay: kick.controls.decay)
        }
        return 0
    }

    // MARK: Housekeeping

    /// Forget everything the bench no longer holds. Called on every lookup, which is at most three
    /// items, and is what makes a closed surface's engine work and its draft go away together.
    func prune(_ app: AppState) {
        let open = Set(app.bench.items.map(\.id))
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
        compares = compares.filter { open.contains($0.key) }
        compareAdapters = compareAdapters.filter { open.contains($0.key) }
        checks = checks.filter { open.contains($0.key) }
        checkAdapters = checkAdapters.filter { open.contains($0.key) }
    }

    /// Whether anything is still held for this surface. For a test; the app never asks.
    func holds(_ id: SurfaceID) -> Bool {
        imports[id] != nil || grids[id] != nil || sounds[id] != nil || chops[id] != nil
            || rolls[id] != nil || chordSheets[id] != nil || structures[id] != nil || merges[id] != nil || compares[id] != nil || checks[id] != nil
    }

    /// The Chop lane this surface is drawing, when it has one. The only way a critic's marks reach
    /// a lane — `PersonaDirecting.mark(_:on:)` goes through here, and nothing else writes one.
    func chopBinding(holding id: SurfaceID) -> ChopLaneBinding? { chops[id] }

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
        return Guidance.sounds(in: song).reversed()
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
