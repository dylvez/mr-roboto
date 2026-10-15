import Foundation
import Instrument
import SongGraph

/// `AppState` seen through `SoundShapingHost`.
///
/// Three members, and two of them are a bridge rather than a delegation:
///
/// * **`audition`** is the rendered voice or part — floats and a rate — which is exactly what the
///   shared `AuditionService` plays. Fire-and-forget, interrupted by the next one, as the protocol says.
/// * **`record`** is `AppState.record(_:)` unchanged, including its `false` for "the host refused
///   it", which is what lets the popover keep the edit as a draft rather than pretending. A dirtied
///   part that lands is then put to the chain critic, and what it finds goes to the rail in the
///   Sampler's name: stacking a second lossy chain is flagged, never silently allowed.
/// * **`dryAudio`** and **`kitHit`** read the song's side: a chop's bar off disk, a groove bounced
///   on the song's machine, one hit of the kit as the song has shaped it.
@MainActor
final class SoundShapingAdapter: SoundShapingHost {

    private let app: AppState
    private let service: AuditionService

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
    }

    func audition(_ audition: SoundAudition) {
        let planar = audition.planar
        let rate = audition.sampleRate
        Task { [service] in await service.play(planar: planar, sampleRate: rate) }
    }

    /// The part with no chain on it: a chop's bar read off disk, a groove bounced on the song's
    /// machine at the song's tempo. The same two sources the transport and the Compare read.
    func dryAudio(of version: PartVersion) async throws -> SoundAudition {
        let label = PartLabel.title(of: version)
        switch version.kind {
        case .sample(let sample):
            guard let store = app.store else {
                throw SoundShapingUnavailable(what: "this session has no library directory, so \(label) cannot be read")
            }
            let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: app.song)?.bars ?? [],
                                                tempo: sample.detectedTempo ?? app.song?.tempo)
            let url = try store.mediaURL(for: sample.media, song: app.song?.id)
            let span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: region.start, to: region.end).levelled(by: sample.gainDB)
            }.value
            guard let first = span.planar.first, !first.isEmpty else {
                throw SoundShapingUnavailable(what: "\(label) is empty between "
                    + String(format: "%.2f s and %.2f s", region.start, region.end))
            }
            return SoundAudition(planar: span.planar, sampleRate: span.sampleRate, label: label, isDry: true)
        case .groove(let groove):
            let machine = app.song.map { SongPlayback.machine(for: version.partID, in: $0) } ?? .tr808
            let tempo = app.song?.tempo ?? 90
            let meter = app.song?.timeSignature ?? .fourFour
            let hits = Dust.hits(for: groove, tempo: tempo, timeSignature: meter)
            guard !hits.isEmpty else { throw SoundShapingUnavailable(what: "\(label) has no hits in it") }
            let seconds = Dust.duration(of: groove, tempo: tempo, timeSignature: meter) + Dust.tail
            let bounce = try await service.bounce(hits, machine: machine, seconds: seconds)
            return SoundAudition(planar: bounce.planar, sampleRate: bounce.sampleRate, label: label, isDry: true)
        default:
            throw SoundShapingUnavailable(what: "a \(version.type.rawValue) has no sound to put through the chain")
        }
    }

    func newest(of part: PartID) -> PartVersion? {
        app.song?.versions.last { $0.partID == part }
    }

    // MARK: A drum voice, as the song has it

    var songMachine: String? {
        app.song.map { SongPlayback.machineID(in: $0) }
    }

    func keptVoice(_ voice: SynthVoiceKind, on machine: String) -> PartVersion? {
        app.song.flatMap { SongPlayback.voiceEdit(of: voice, on: machine, in: $0) }
    }

    func recording(of voice: SynthVoiceKind, on machine: String) -> String? {
        SynthMachine.preset(id: machine).flatMap { RecordedKits.recordedVoices(of: $0)[voice] }
    }

    /// One hit, bounced on the kit the song plays with this voice's chain taken off: the chain is
    /// the popover's to put on, and a hit that came with it would go through it twice.
    func kitHit(of voice: SynthVoiceKind, on machine: SynthMachine) async throws -> SoundAudition {
        var shaped = app.song.map { SongPlayback.shaped(machine, in: $0) } ?? machine
        if let index = shaped.voices.firstIndex(where: { $0.kind == voice }) { shaped.voices[index].dust = nil }
        let hit = VoiceSampler.Hit(voice.drumVoice, velocity: 100, at: 0)
        let bounce = try await service.bounce([hit], machine: shaped, seconds: Self.longestHit)
        // To where it has died away: a kick is not four seconds of audition.
        let floor: Float = 1e-4
        let end = bounce.planar.map { channel in (channel.lastIndex { abs($0) > floor } ?? 0) + 1 }.max() ?? 0
        guard end > 1 else {
            throw SoundShapingUnavailable(what: "\(shaped.name) played nothing for its \(voice.rawValue)")
        }
        return SoundAudition(planar: bounce.planar.map { Array($0.prefix(end)) }, sampleRate: bounce.sampleRate,
                             label: "\(shaped.name) \(voice.rawValue)", isDry: true)
    }

    /// As long as a recorded crash is given to ring.
    static let longestHit: Double = 6

    func record(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        // A drum voice kept is a different kit: the samplers holding the old one load the new on
        // their next use, and the transport plays the voice as it was kept.
        if SoundState(version) != nil { Task { [service] in await service.drumKitsChanged() } }
        for finding in Dust.findings(for: version) {
            let persona = Cast.standard.persona(finding.persona)?.bible.name ?? finding.persona.rawValue.capitalized
            app.note(.persona(persona), finding.headline, detail: "\(finding.why) \(finding.measurement.description)")
        }
        return true
    }
}

// MARK: - Opening a popover

/// Where a Shape popover's model comes from: a surface is handed one of these and asks it for a
/// voice or a part, the way it is handed `MIDIControl` for Record. Nil where there is no app
/// behind the surface — a render, a test — and then the surface offers no popover.
@MainActor
final class ShapingSource {
    private let app: AppState
    private let service: AuditionService

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
    }

    /// A drum voice of a machine, at the song's newest edit of it.
    func voice(_ kind: SynthVoiceKind, on machine: String) -> SoundShaping {
        SoundShaping(host: SoundShapingAdapter(app: app, service: service), voice: kind, machine: machine)
    }

    /// The chain on a chop or a groove, on the part's newest version.
    func chain(on version: PartVersion) -> SoundShaping {
        SoundShaping(host: SoundShapingAdapter(app: app, service: service), part: version)
    }
}
