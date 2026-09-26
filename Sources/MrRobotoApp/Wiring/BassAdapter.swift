import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// `AppState` and the audition service, seen through `PianoRollHosting`.
///
/// A touch plays one note on the bass sampler; "play line" plays the whole line once on its own;
/// a commit goes through `AppState.record(_:)`, and the Bassist's readings of the committed line
/// go to the rail in its own name, so what it thinks is said where the band speaks.
@MainActor
final class BassAdapter: PianoRollHosting {
    private let app: AppState
    private let service: AuditionService
    /// The roll's bench item, whose binding follows what it keeps.
    private let surface: SurfaceID?

    init(app: AppState, service: AuditionService, surface: SurfaceID? = nil) {
        self.app = app
        self.service = service
        self.surface = surface
    }

    func newest(of part: PartID) -> PartVersion? {
        app.song?.versions.last { $0.partID == part }
    }

    func audition(note: Int, velocity: Int, duration: Double, sound: String) async {
        await prepare(sound)
        await service.playBass([VoiceSampler.Hit(note: note, velocity: velocity, at: 0, duration: duration)])
    }

    func play(_ bassline: Bassline, tempo: Double, timeSignature: TimeSignature) async {
        await prepare(bassline.sound ?? "finger")
        let timeline = GrooveTimeline.tempo(tempo, timeSignature: timeSignature)
        let hits = BasslinePlayer.hits(for: bassline, on: timeline, offsetBeats: 0)
        await service.playBass(hits)
    }

    func stop() async { await service.stop() }

    func auditionMelody(note: Int, velocity: Int, duration: Double, instrument: String) async {
        guard await prepareInstrument(instrument) else { return }
        await service.playInstrument([VoiceSampler.Hit(note: note, velocity: velocity, at: 0, duration: duration)])
    }

    func playMelody(_ notes: [NoteEvent], tempo: Double, timeSignature: TimeSignature, instrument: String) async {
        guard !notes.isEmpty, await prepareInstrument(instrument) else { return }
        let secondsPerBeat = 60 / max(1, tempo)
        await service.playInstrument(notes.map { note in
            VoiceSampler.Hit(note: note.pitch.midi, velocity: note.velocity,
                             at: note.start * secondsPerBeat, duration: note.duration * secondsPerBeat)
        })
    }

    func setInstrument(_ id: String, for part: PartID?) { app.setInstrument(id, for: part) }

    /// Loads an instrument preset, saying so in the rail when it cannot.
    private func prepareInstrument(_ id: String) async -> Bool {
        let spec = InstrumentVoiceSpec.preset(id: id) ?? .rhodes
        guard await service.currentInstrumentID != spec.id else { return true }
        do {
            try await service.prepare(instrument: spec)
            return true
        } catch {
            app.note(.session, "Could not load the \(spec.name)", detail: "\(error)")
            return false
        }
    }

    /// What the Bassist said last, so a line kept a moment after every edit does not put the same
    /// sentence in the rail each time.
    private var lastSaid: String?

    func commit(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        if let surface { app.surfaceKept(version, on: surface) }
        // What the Bassist says about what was kept, in the rail, in its name.
        if let song = app.song, case .bassline(let line) = version.kind,
           let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
            let chords = Guidance.progressions(in: song).last.flatMap { version -> [ChordSpan]? in
                if case .progression(let p) = version.kind { return p.spans }
                return nil
            } ?? []
            // A line longer than its groove is read against the groove repeated under it, as it
            // plays; read against one bar of kick, bars two to eight would have nothing under them.
            let heard = line.lengthInBars.map { groove.tiled(toBars: $0) } ?? groove
            let observation = BassObservation(label: PartLabel.title(of: version), bassline: line, groove: heard,
                                              chords: chords, tempo: song.tempo, timeSignature: song.timeSignature)
            let readings = Bassist().read(observation)
            let flags = readings.filter { !$0.holds }
            // Only what went wrong, and only when it changes: the readings are on the surface
            // already, and a line kept as you go would otherwise be a line in the rail each time.
            let line = flags.map(\.says).joined(separator: " ")
            if !flags.isEmpty, line != lastSaid {
                app.note(.persona("Bassist"), line, detail: PartLabel.title(of: version))
            }
            lastSaid = flags.isEmpty ? nil : line
        }
        return true
    }

    private func prepare(_ sound: String) async {
        let voice = BassVoiceSpec.all.first { $0.id == sound } ?? .finger
        guard await service.currentBassID != voice.id else { return }
        do { try await service.prepare(bass: voice) } catch {
            app.note(.session, "Could not load the \(voice.name) bass", detail: "\(error)")
        }
    }
}

/// `AppState` seen through `ChordsHosting`: a chord sounds on the bass sampler, a commit is recorded.
@MainActor
final class ChordsAdapter: ChordsHosting {
    private let app: AppState
    private let service: AuditionService
    /// The sheet's bench item, whose binding follows what it keeps.
    private let surface: SurfaceID?

    init(app: AppState, service: AuditionService, surface: SurfaceID? = nil) {
        self.app = app
        self.service = service
        self.surface = surface
    }

    func newest(of part: PartID) -> PartVersion? {
        app.song?.versions.last { $0.partID == part }
    }

    var instrument: String { instrument(for: nil) }

    func instrument(for part: PartID?) -> String {
        app.song.map { SongPlayback.instrumentID(for: part, in: $0) } ?? InstrumentVoiceSpec.rhodes.id
    }

    func setInstrument(_ id: String, for part: PartID?) { app.setInstrument(id, for: part) }

    func audition(pitches: [Int], duration: Double) async {
        await audition(pitches: pitches, duration: duration, for: nil)
    }

    func audition(pitches: [Int], duration: Double, for part: PartID?) async {
        // Chords play on their part's pitched instrument, as the song plays them. They used to go
        // through the bass sampler, which put a four-note voicing through a monophonic sub an
        // octave below where it was written; then on the song's, whatever the part had picked.
        let spec = InstrumentVoiceSpec.preset(id: instrument(for: part)) ?? .rhodes
        if await service.currentInstrumentID != spec.id {
            do { try await service.prepare(instrument: spec) } catch {
                app.note(.session, "Could not load the \(spec.name)", detail: "\(error)")
                return
            }
        }
        await service.playInstrument(pitches.map { VoiceSampler.Hit(note: $0, velocity: 92, at: 0, duration: duration) })
    }

    func commit(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        if let surface { app.surfaceKept(version, on: surface) }
        return true
    }

    /// The bass line the chords are played over, so the Harmonist's reading on the surface can say
    /// whether the bass agrees — the same newest line the rail's reading uses.
    var bassline: Bassline? {
        guard let song = app.song, let version = Guidance.basslines(in: song).last,
              case .bassline(let line) = version.kind else { return nil }
        return line
    }
}
