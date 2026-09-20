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

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
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

    func setInstrument(_ id: String) { app.setInstrument(id) }

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

    func commit(_ version: PartVersion) async -> Bool {
        guard app.record(version) else { return false }
        // What the Bassist says about what was kept, in the rail, in its name.
        if let song = app.song, case .bassline(let line) = version.kind,
           let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
            let chords = Guidance.progressions(in: song).last.flatMap { version -> [ChordSpan]? in
                if case .progression(let p) = version.kind { return p.spans }
                return nil
            } ?? []
            let observation = BassObservation(label: PartLabel.title(of: version), bassline: line, groove: groove,
                                              chords: chords, tempo: song.tempo, timeSignature: song.timeSignature)
            let readings = Bassist().read(observation)
            let flags = readings.filter { !$0.holds }
            let line = flags.isEmpty
                ? readings.first { $0.rule == "bassist.lag-budget" || $0.rule == "bassist.808-is-the-bass" }?.says
                    ?? "That sits where it should."
                : flags.map(\.says).joined(separator: " ")
            app.note(.persona("Bassist"), line, detail: PartLabel.title(of: version))
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

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
    }

    var instrument: String { app.song.map { SongPlayback.instrumentID(in: $0) } ?? InstrumentVoiceSpec.rhodes.id }

    func setInstrument(_ id: String) { app.setInstrument(id) }

    func audition(pitches: [Int], duration: Double) async {
        // Chords play on the song's pitched instrument. They used to go through the bass sampler,
        // which put a four-note voicing through a monophonic sub an octave below where it was written.
        let spec = app.song.map { InstrumentVoiceSpec.preset(id: SongPlayback.instrumentID(in: $0)) ?? .rhodes } ?? .rhodes
        if await service.currentInstrumentID != spec.id {
            do { try await service.prepare(instrument: spec) } catch {
                app.note(.session, "Could not load the \(spec.name)", detail: "\(error)")
                return
            }
        }
        await service.playInstrument(pitches.map { VoiceSampler.Hit(note: $0, velocity: 92, at: 0, duration: duration) })
    }

    func commit(_ version: PartVersion) async -> Bool { app.record(version) }
}
