import Foundation
import SongGraph

/// `AppState` seen through `SoundSurfaceHost`.
///
/// Three members, and two of them are a bridge rather than a delegation:
///
/// * **`selectedPart`** is the one place the two vocabularies genuinely differ. The surface wants
///   `PartVersion?`; `AppState` has `selectedVersion: VersionID?` plus `version(_:)`. That is
///   resolved here rather than by widening `AppState`, and it is also filtered: a surface opened on
///   a bar of audio must not be handed a melody row to derive a sound from, so anything that is not
///   a `.sound` payload reads as nothing selected and the panel says what to pick.
/// * **`audition`** is the rendered voice — floats and a rate — which is exactly what the shared
///   `AuditionService` plays. Fire-and-forget, interrupted by the next one, as the protocol says.
/// * **`record`** is `AppState.record(_:)` unchanged, including its `false` for "the host refused
///   it", which is what lets the surface keep the edit as a draft rather than pretending.
@MainActor
final class SoundAdapter: SoundSurfaceHost {

    private let app: AppState
    private let service: AuditionService

    /// What the surface was opened against, when it was opened against something. Nil falls back to
    /// whatever is accented in the parts ledger, so the Surfaces menu opens a useful panel.
    private let bound: VersionID?

    init(app: AppState, service: AuditionService, bound: VersionID? = nil) {
        self.app = app
        self.service = service
        self.bound = bound
    }

    var selectedPart: PartVersion? {
        guard let id = bound ?? app.selectedVersion, let version = app.version(id) else { return nil }
        guard case .sound = version.kind else { return nil }
        return version
    }

    func audition(_ audition: SoundAudition) {
        let samples = audition.samples
        let rate = audition.sampleRate
        Task { [service] in await service.play(samples, sampleRate: rate) }
    }

    @discardableResult
    func record(_ version: PartVersion) -> Bool {
        app.record(version)
    }
}
