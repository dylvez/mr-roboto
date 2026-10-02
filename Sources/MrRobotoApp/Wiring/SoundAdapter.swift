import Foundation
import Instrument
import SongGraph

/// `AppState` seen through `SoundSurfaceHost`.
///
/// Three members, and two of them are a bridge rather than a delegation:
///
/// * **`selectedPart`** is the one place the two vocabularies genuinely differ. The surface wants
///   `PartVersion?`; `AppState` has `selectedVersion: VersionID?` plus `version(_:)`. That is
///   resolved here rather than by widening `AppState`, and it is also filtered. What the surface was
///   *bound* to may be a `.sound`, or a `.sample` or `.groove` to put through the chain — dust is a
///   sound job, and this is where a chop gets one. What is merely *accented* in the ledger is only
///   taken when it is a `.sound`: opening Sound off the dock should not quietly start dirtying
///   whatever row happened to be selected. Anything else reads as nothing selected.
/// * **`audition`** is the rendered voice or part — floats and a rate — which is exactly what the
///   shared `AuditionService` plays. Fire-and-forget, interrupted by the next one, as the protocol says.
/// * **`record`** is `AppState.record(_:)` unchanged, including its `false` for "the host refused
///   it", which is what lets the surface keep the edit as a draft rather than pretending. A dirtied
///   part that lands is then put to the chain critic, and what it finds goes to the rail in the
///   Sampler's name: stacking a second lossy chain is flagged, never silently allowed.
@MainActor
final class SoundAdapter: SoundSurfaceHost {

    private let app: AppState
    private let service: AuditionService

    /// What the surface was opened against, when it was opened against something. Nil falls back to
    /// whatever is accented in the parts ledger, so the Surfaces menu opens a useful panel.
    private let bound: VersionID?
    /// The bench item, for the levers the Director hung on it.
    private let surface: SurfaceID?

    init(app: AppState, service: AuditionService, bound: VersionID? = nil, surface: SurfaceID? = nil) {
        self.app = app
        self.service = service
        self.bound = bound
        self.surface = surface
    }

    var selectedPart: PartVersion? {
        if let bound {
            guard let version = app.version(bound) else { return nil }
            switch version.kind {
            case .sound, .sample, .groove: return version
            default: return nil
            }
        }
        guard let id = app.selectedVersion, let version = app.version(id) else { return nil }
        guard case .sound = version.kind else { return nil }
        return version
    }

    var dustLever: Double? {
        guard let surface else { return nil }
        return app.levers(for: surface).first { $0.quantity == .dust }?.value
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
                throw SoundSurfaceUnavailable(what: "this session has no library directory, so \(label) cannot be read")
            }
            let region = ChopLaneBinding.region(of: sample, bars: Guidance.analysis(in: app.song)?.bars ?? [],
                                                tempo: sample.detectedTempo ?? app.song?.tempo)
            let url = try store.mediaURL(for: sample.media, song: app.song?.id)
            let span = try await Task.detached(priority: .userInitiated) {
                try AudioRegion.read(url, from: region.start, to: region.end)
            }.value
            guard let first = span.planar.first, !first.isEmpty else {
                throw SoundSurfaceUnavailable(what: "\(label) is empty between "
                    + String(format: "%.2f s and %.2f s", region.start, region.end))
            }
            return SoundAudition(planar: span.planar, sampleRate: span.sampleRate, label: label, isDry: true)
        case .groove(let groove):
            let machine = app.song.map { SongPlayback.machine(for: version.partID, in: $0) } ?? .tr808
            let tempo = app.song?.tempo ?? 90
            let meter = app.song?.timeSignature ?? .fourFour
            let hits = Dust.hits(for: groove, tempo: tempo, timeSignature: meter)
            guard !hits.isEmpty else { throw SoundSurfaceUnavailable(what: "\(label) has no hits in it") }
            let seconds = Dust.duration(of: groove, tempo: tempo, timeSignature: meter) + Dust.tail
            let bounce = try await service.bounce(hits, machine: machine, seconds: seconds)
            return SoundAudition(planar: bounce.planar, sampleRate: bounce.sampleRate, label: label, isDry: true)
        default:
            throw SoundSurfaceUnavailable(what: "a \(version.type.rawValue) has no sound to put through the chain")
        }
    }

    @discardableResult
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

    /// One hit, bounced on the kit the song plays: the same folder the transport's sampler holds.
    func kitHit(of voice: SynthVoiceKind, on machine: SynthMachine) async throws -> SoundAudition {
        let shaped = app.song.map { SongPlayback.shaped(machine, in: $0) } ?? machine
        let hit = VoiceSampler.Hit(voice.drumVoice, velocity: 100, at: 0)
        let bounce = try await service.bounce([hit], machine: shaped, seconds: Self.longestHit)
        // To where it has died away: a kick is not four seconds of audition.
        let floor: Float = 1e-4
        let end = bounce.planar.map { channel in (channel.lastIndex { abs($0) > floor } ?? 0) + 1 }.max() ?? 0
        guard end > 1 else {
            throw SoundSurfaceUnavailable(what: "\(shaped.name) played nothing for its \(voice.rawValue)")
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
