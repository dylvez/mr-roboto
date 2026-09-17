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

    // MARK: Models

    func importModel(for item: BenchItem, app: AppState) -> ImportModel {
        prune(app)
        if let existing = imports[item.id] { return existing }
        guard let store = app.store else {
            // No library directory (tests, previews). The surface is still a drop target; it simply
            // has nowhere to write, which its own failure path already says out loud.
            let adapter = ImportAdapter(app: app, service: service(for: app),
                                        live: LiveImportHost(library: LibraryStore(directoryURL: Self.scratchLibrary)))
            let model = ImportModel(host: adapter)
            importAdapters[item.id] = adapter
            imports[item.id] = model
            return model
        }
        let adapter = ImportAdapter(app: app, service: service(for: app),
                                    live: LiveImportHost(library: store))
        let model = ImportModel(host: adapter)
        importAdapters[item.id] = adapter
        imports[item.id] = model
        return model
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
                                   bound: app.bound(for: item.id).first)
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

    // MARK: Housekeeping

    /// Forget everything the bench no longer holds. Called on every lookup, which is at most three
    /// items, and is what makes a closed surface's engine work and its draft go away together.
    private func prune(_ app: AppState) {
        let open = Set(app.bench.items.map(\.id))
        imports = imports.filter { open.contains($0.key) }
        importAdapters = importAdapters.filter { open.contains($0.key) }
        grids = grids.filter { open.contains($0.key) }
        gridAdapters = gridAdapters.filter { open.contains($0.key) }
        sounds = sounds.filter { open.contains($0.key) }
        soundAdapters = soundAdapters.filter { open.contains($0.key) }
        chops = chops.filter { open.contains($0.key) }
    }

    /// Whether anything is still held for this surface. For a test; the app never asks.
    func holds(_ id: SurfaceID) -> Bool {
        imports[id] != nil || grids[id] != nil || sounds[id] != nil || chops[id] != nil
    }

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
/// wondering what it was editing. So the panel says which it is doing.
struct SoundSurfacePanel: View {
    @Bindable var surface: SoundSurface
    let hasSelection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasSelection {
                EmptyNote(title: "Nothing selected: this is a new sound.",
                          detail: "Select a sound part in the parts ledger to edit that one. Otherwise "
                          + "every knob here is shaping a new part from the machine preset, and the "
                          + "first commit starts it.")
                    .padding(.horizontal, Design.Metric.inset)
                    .padding(.top, Design.Metric.inset)
            }
            SoundSurfaceView(surface: surface)
        }
        .background(Design.Palette.panel)
    }
}
