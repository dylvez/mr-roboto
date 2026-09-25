import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Synchronization

/// `AppState` seen through `GridHosting`.
///
/// The Grid asks for four things, and they are not all the same kind of thing:
///
/// * **`audition`** is a touch — one voice, now — so it goes to the shared `AuditionService`, which
///   is already started and already holding a kit. This is the path that has to be fast.
/// * **`setPattern`** is the looping groove player, which is `LiveGridHost`'s real work
///   (`GroovePlayer` re-reading the groove on each iteration is what "audible on the next pass"
///   means) and is delegated to it unchanged.
/// * **`loadMachine`** is both: the shared sampler needs the kit so a step touch sounds like the
///   chosen machine, and the pattern player needs it so a loop does. The audible-on-touch path is
///   the one whose failure is reported to the surface.
/// * **`commit`** goes through `AppState.record(_:)`, which appends the version, selects it, and
///   writes the rail's line.
final class GridAdapter: GridHosting {

    private let app: AppState
    private let service: AuditionService
    private let live: LiveGridHost
    /// The machine the grid last asked for. A grid opens on one before anything is loaded, so the
    /// first step touch prepares it rather than being silent.
    private let machine: Mutex<SynthMachine>

    init(app: AppState, service: AuditionService,
         live: LiveGridHost = LiveGridHost(), machine: SynthMachine = .tr808) {
        self.app = app
        self.service = service
        self.live = live
        self.machine = Mutex(machine)
    }

    func audition(_ voice: DrumVoice, velocity: Int) async {
        await ensureMachine()
        await service.play([VoiceSampler.Hit(voice, velocity: velocity, at: 0)])
    }

    func setPattern(_ groove: Groove, options: GrooveRenderOptions,
                    tempo: Double, timeSignature: TimeSignature) async {
        await live.setPattern(groove, options: options, tempo: tempo, timeSignature: timeSignature)
    }

    func loadMachine(_ newMachine: SynthMachine) async throws {
        machine.withLock { $0 = newMachine }
        // The audible path first: if this fails the surface should say so, because it is what a
        // step touch plays.
        try await service.prepare(machine: newMachine)
        do {
            try await live.loadMachine(newMachine)
        } catch {
            // The loop's own kit. A failure here means the pattern will not loop, not that the
            // grid is silent, so it is reported to the rail rather than thrown at the surface.
            await app.note(.session, "The pattern player could not load \(newMachine.name)",
                           detail: "\(error)")
        }
    }

    /// Whether the song took it. `record` says no when there is no song to take it, and the
    /// surface shows that rather than a version that went nowhere.
    func commit(_ version: PartVersion) async -> Bool {
        await app.record(version)
    }

    /// Loads the grid's machine if the shared sampler is not already holding it. Another surface
    /// (a chop pad) can have taken the sampler since the last touch; one prepare is cheaper than a
    /// wrong sound.
    private func ensureMachine() async {
        let wanted = machine.withLock { $0 }
        guard await service.currentKitID != wanted.id else { return }
        do {
            try await service.prepare(machine: wanted)
        } catch {
            await app.note(.session, "Could not load \(wanted.name)", detail: "\(error)")
        }
    }
}
