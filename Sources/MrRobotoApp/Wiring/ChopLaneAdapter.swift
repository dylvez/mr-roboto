import Foundation
import Instrument
import Performance
import SongGraph

/// `AppState` seen through `ChopLaneHost`.
///
/// The lane splits making a sound into two calls on purpose — `prepareAudition` on an edit,
/// `audition` on the touch — so the touch itself does no work. That split is kept here: a rendered
/// kit is written and handed to the shared sampler as soon as the lane produces one, and a pad
/// press only posts hits.
///
/// The one complication the shared engine introduces is that the sampler holds *one* kit, so a Grid
/// step or another lane can displace this lane's. `AuditionService.currentKitID` says whose kit is
/// loaded, and a touch that finds someone else's re-installs its own first. That costs one prepare
/// after a surface switch rather than playing the wrong sound.
@MainActor
final class ChopLaneAdapter: ChopLaneHost {

    private let app: AppState
    private let service: AuditionService
    /// Names this lane's kit in the shared sampler, and its folder in the kit cache.
    private let kitID: String
    /// The last kit the lane rendered, kept so a displaced sampler can be put back.
    private var kit: ChopKit?

    init(app: AppState, service: AuditionService, surface: SurfaceID) {
        self.app = app
        self.service = service
        self.kitID = "chop-\(surface.rawValue.uuidString)"
    }

    var song: Song? { app.song }

    /// Take the rendered chop and make it playable.
    ///
    /// Installing it touches the disk and the sample cache, so it happens on a task rather than
    /// blocking the main actor; `prepareAudition` is documented as never being on the touch path,
    /// which is what makes that safe. A failure therefore reaches the rail rather than this call's
    /// `throws` — the one place the protocol's shape and the shared engine's do not quite meet.
    func prepareAudition(_ newKit: ChopKit) throws {
        kit = newKit
        Task { [service, app, kitID] in
            do {
                try await service.prepare(chop: newKit, id: kitID)
            } catch {
                app.note(.session, "The chop could not be made playable", detail: "\(error)")
            }
        }
    }

    func audition(_ hits: [VoiceSampler.Hit]) {
        guard !hits.isEmpty else { return }
        Task { [service, kit, kitID] in
            if await service.currentKitID != kitID, let kit {
                try? await service.prepare(chop: kit, id: kitID)
            }
            await service.play(hits)
        }
    }

    func stopAudition() {
        Task { [service] in await service.stop() }
    }

    /// A chop or a re-groove left the lane. The ledger takes it, and a re-groove opens the Grid on
    /// it — the second half of the Gate A workflow, and the reason `commitRegroove` exists.
    @discardableResult
    func record(_ version: PartVersion) -> Bool {
        guard app.record(version) else { return false }
        // A groove cut from a kept chop opens once it is on the chop (`madeGroove`), so the Grid
        // never opens on a machine the song is about to stop playing it on.
        if case .groove = version.kind,
           !version.parents.contains(where: { app.version($0)?.type == .sample }) {
            openGrid(on: version)
        }
        return true
    }

    /// The groove plays on the chop's slices, in the sections the chop played in. The rail says
    /// where, because the form changed without a surface on it.
    func madeGroove(_ groove: PartVersion, fromChop chop: PartID) {
        let took = app.playGroove(groove.partID, onChop: chop)
        if !took.isEmpty {
            let name = PartLabel.title(of: groove)
            app.note(.session, "\(name) plays in \(AppState.listed(took)) in place of the looped bar",
                     detail: "It plays the chop's own slices. Structure puts the loop back.")
        }
        openGrid(on: groove)
    }

    /// A re-groove opens the Grid on it: the second half of the Gate A workflow.
    private func openGrid(on groove: PartVersion) {
        let title = groove.note.map { String($0.prefix(60)) } ?? "Re-groove"
        app.openSurface(.grid, title: title, bound: [groove.id])
    }
}
