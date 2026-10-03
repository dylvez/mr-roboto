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

    func shade(_ section: SectionID, to intensity: Double) { app.shade(section, to: intensity) }

    func hasEarlier(_ section: SectionID) -> Bool { !app.earlierStates(of: section).isEmpty }

    func addDrums(under groove: PartID) { app.addDrums(under: groove) }

    var drumMachineName: String { app.song.map { SongPlayback.machine(in: $0).name } ?? "drum machine" }

    func compare(_ section: SectionID) {
        Task { [app] in
            if await app.compareSection(section) == nil {
                app.note(.session, "Nothing to compare it with yet", detail: "The section has not changed since the song was opened.")
            }
        }
    }
}
