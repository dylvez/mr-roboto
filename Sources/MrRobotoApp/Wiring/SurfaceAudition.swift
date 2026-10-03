import AudioEngine
import Foundation
import SongGraph

// What the play control in a surface's header plays. One answer per kind, resolved here so the
// header, ⌥Space and the transport bar agree.

/// The thing a surface would play, named.
@MainActor
struct SurfaceAudition {
    /// What the player is asked about: is this the thing sounding?
    var id: String
    /// "this groove", "the selection", "the song".
    var label: String
    var play: @MainActor (PartPlayer) async -> Void
}

extension SurfaceWiring {

    /// The player, on the shared rig. One per process, like the service it plays through.
    func player(for app: AppState) -> PartPlayer {
        if let partPlayer { return partPlayer }
        let built = PartPlayer(app: app, service: service(for: app))
        partPlayer = built
        return built
    }

    /// Which version of a surface's primer to show, when a surface has modes.
    func primerVariant(for item: BenchItem, app: AppState) -> String? {
        guard item.kind == .pianoRoll else { return nil }
        return pianoRollModel(for: item, app: app).mode == .melody ? "melody" : nil
    }

    /// What this surface plays from its header. Nil when it has nothing of its own to sound and
    /// the song is not what it is about (an album, the cast, an answer surface with its own buttons).
    func audition(for item: BenchItem, app: AppState) -> SurfaceAudition? {
        let id = "surface:\(item.id)"
        let clock = app.clock
        let bound = app.bound(for: item.id).compactMap { app.version($0) }
        func song(_ label: String = "the song") -> SurfaceAudition? {
            guard app.song != nil else { return nil }
            return SurfaceAudition(id: id, label: label) { await $0.playSong(id: id, label: app.song?.title ?? "The song") }
        }
        func version(_ version: PartVersion?, _ label: String) -> SurfaceAudition? {
            guard let version, PartPlayer.canPlay(version) else { return nil }
            // The version's own id, so its row in the ledger lights with the header.
            return SurfaceAudition(id: version.id.description, label: label) { await $0.play(version) }
        }

        switch item.kind {
        case .grid:
            // The working pattern, kept or not.
            let model = gridModel(for: item, app: app)
            let groove = model.groove
            guard groove.patterns.contains(where: { $0.steps.contains { $0 != .rest } }) else { return nil }
            let machine = model.machine
            return SurfaceAudition(id: id, label: "this groove") { player in
                let seconds = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature) + 0.5
                await player.play(id: id, label: item.title, seconds: seconds) { await player.play(groove, machine: machine, clock: clock) }
            }
        case .pianoRoll:
            let model = pianoRollModel(for: item, app: app)
            let line = model.bassline
            guard !line.notes.isEmpty else { return nil }
            let seconds = clock.seconds(forBeat: line.notes.map { $0.start + $0.duration }.max() ?? 0) + 0.5
            // A tune plays on its instrument, as the roll's own touch does, not on the bass.
            if model.mode == .melody {
                let notes = line.notes, instrument = model.instrument
                return SurfaceAudition(id: id, label: "this tune") { player in
                    await player.play(id: id, label: item.title, seconds: seconds) {
                        await player.playOnInstrument(notes, instrument: instrument, clock: clock)
                    }
                }
            }
            return SurfaceAudition(id: id, label: "this line") { player in
                await player.play(id: id, label: item.title, seconds: seconds) { await player.play(line.notes, sound: line.sound, clock: clock) }
            }
        case .chords:
            let model = chordsModel(for: item, app: app)
            guard let progression = model.progression, !progression.chords.isEmpty else { return nil }
            let part = model.part
            return SurfaceAudition(id: id, label: "these chords") { player in
                let seconds = clock.seconds(forBeat: progression.bars.reduce(0) { $0 + $1.beats }) + 0.5
                let song = app.song
                await player.play(id: id, label: item.title, seconds: seconds) { await player.play(progression, in: song, for: part, clock: clock) }
            }
        case .chopLane:
            guard case .ready(let surface) = chopBinding(for: item, app: app).state else { return version(bound.first, "this chop") }
            return SurfaceAudition(id: id, label: "this bar, chopped") { player in
                await player.play(id: id, label: item.title, seconds: clock.secondsPerBar + 0.5) { surface.auditionBar() }
            }
        case .importRecord:
            let model = importModel(for: item, app: app)
            if let selection = model.selection {
                return SurfaceAudition(id: id, label: "the selection") { player in
                    await player.play(id: id, label: "\(item.title), selection", seconds: selection.duration) { model.auditionSelection() }
                }
            }
            return version(app.song.flatMap(Guidance.take(in:)), "the record")
        case .merge:
            let model = mergeModel(for: item, app: app)
            guard model.plan != nil else { return nil }
            return SurfaceAudition(id: id, label: "both, as planned") { player in
                await player.play(id: id, label: item.title, seconds: nil) { model.playBoth() }
            }
        case .sources:
            let model = sourcesModel(for: item, app: app)
            guard model.unheard == nil else { return nil }
            return SurfaceAudition(id: id, label: "8 bars from bar \(model.previewBar)") { player in
                await player.play(id: id, label: "Sources preview", seconds: nil) { await model.preview() }
            }
        case .mashup:
            let model = mashupModel(for: item, app: app)
            guard model.blocker == nil else { return nil }
            return SurfaceAudition(id: id, label: "8 bars from bar \(model.previewBar)") { player in
                await player.play(id: id, label: "Mashup preview", seconds: nil) { await model.preview() }
            }
        case .takes:
            let model = takesModel(for: item, app: app)
            return version(model.comp ?? model.takes.last, model.comp != nil ? "the comp" : "the newest take")
        case .sound:
            return version(bound.first { PartPlayer.canPlay($0) }, "this sound") ?? song()
        case .structure:
            // The form you are looking at, which means the working copy: an arrangement with
            // unkept edits is kept first, as `StructureModel.play()` was written to do, so what
            // plays is what is on screen and not what was last kept. The footer says so.
            guard app.song != nil else { return nil }
            let model = structureModel(for: item, app: app)
            return SurfaceAudition(id: id, label: "the form") { player in
                model.keep()
                await player.playSong(id: id, label: app.song?.title ?? "The song")
            }
        case .booth, .mixer, .master, .lyrics:
            return song()
        case .album, .cast, .compare, .check:
            return nil
        }
    }
}
