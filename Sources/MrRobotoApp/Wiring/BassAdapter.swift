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

    func audition(pitches: [Int], duration: Double) async {
        if await service.currentBassID != BassVoiceSpec.finger.id {
            do { try await service.prepare(bass: .finger) } catch {
                app.note(.session, "Could not load the Finger bass", detail: "\(error)")
                return
            }
        }
        await service.playBass(pitches.map { VoiceSampler.Hit(note: $0, velocity: 92, at: 0, duration: duration) })
    }

    func commit(_ version: PartVersion) async -> Bool { app.record(version) }
}
