import Foundation
import SongGraph

/// `AppState` seen through `StructureHosting`: the sections go to `AppState.arrange(_:)`, and
/// play is the transport, so the form is heard exactly the way the space bar plays it.
@MainActor
final class StructureAdapter: StructureHosting {
    private let app: AppState

    init(app: AppState) { self.app = app }

    func arrange(_ sections: [Section]) -> Bool { app.arrange(sections) }

    func play() async {
        await app.stopTransport()
        await app.startTransport()
    }

    func stop() async { await app.stopTransport() }

    func receive(_ payload: LibraryDragPayload, into section: SectionID) async -> Bool {
        app.receive(payload, at: .section(section))
    }

    func openLyrics() { app.perform(Guidance.dockAction(for: .lyrics, in: app.song)) }

    func development() -> Development? { app.development() }

    func develop() async { await app.developAndMaster() }

    var isDeveloping: Bool { app.isDeveloping }

    var isMastering: Bool { app.isMastering }

    var canPutBackDevelopment: Bool { app.canPutBackDevelopment }

    func putBackDevelopment() { app.putBackDevelopment() }
}
