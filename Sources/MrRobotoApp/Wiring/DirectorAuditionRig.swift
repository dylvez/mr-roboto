import Foundation
import Instrument
import Performance
import SongGraph

/// The `audition` tool, wired to the rig that actually makes a sound.
///
/// `AuditionTool` has always been honest about silence: with no `DirectorAudition` behind it, it
/// returns `played: false` and the sentence about there being no audio device, and the prompt tells
/// the Director to repeat that honestly. That was true and it was also the only thing it could say,
/// because the app passed `nil`. This is what it passes instead.
///
/// The whole job is one hop: a groove handle names a performance on the workbench, the performance
/// names the chop it was played from, the chop names the audio it was cut out of, and the map that
/// performance carries renders that audio into a kit the shared sampler can play. Four lookups and a
/// render — no second engine, no second sampler, and no copy of the graph.
///
/// Two things it deliberately does not do:
///
/// * **It does not throw.** A machine with no output device, a handle that has gone, a kit that will
///   not render: all of them are a sentence in the tool's result, because the tool's whole contract
///   is that it says honestly whether it made a sound. An error here would make the model think the
///   groove was bad.
/// * **It does not stop the transport.** Auditioning is the band playing you something; the
///   `AuditionService` shares its engine with the transport by design, and interrupting a playing
///   song to demonstrate a bar would be the agent taking the instrument out of your hands.
@MainActor
final class DirectorAuditionRig: DirectorAudition {

    private let workbench: DirectorWorkbench
    private let service: AuditionService
    /// Weak: the rig lives in the Director's toolbox, and the toolbox must not keep the frame alive.
    private weak var app: AppState?

    init(workbench: DirectorWorkbench, service: AuditionService, app: AppState?) {
        self.workbench = workbench
        self.service = service
        self.app = app
    }

    func audition(_ request: DirectorAuditionRequest) async -> DirectorAuditionOutcome {
        let kitID = "director-\(request.handle)"
        do {
            let stored = try await workbench.groove(request.handle)
            let chop = try await workbench.chop(stored.plan.chop)
            let audio = try await workbench.audio(chop.audio)
            // `performance.map` rather than the map that went in: the re-groove extends it with pads
            // for whatever it had to stretch, and rendering the original would leave those silent.
            let kit = try stored.performance.map.render(source: audio.planar)
            try await service.prepare(chop: kit, id: kitID)

            let seconds = DirectorAuditionRig.seconds(bars: request.bars, tempo: request.tempo,
                                                      beatsPerBar: stored.plan.timeSignature.beatsPerBar)
            let hits = stored.performance.hits.filter { $0.time < seconds + 1e-6 }
            guard !hits.isEmpty else {
                return DirectorAuditionOutcome(
                    played: false,
                    detail: "That groove has no hits in its first \(request.bars) bar(s), so nothing was played.")
            }
            await service.play(hits)
            if let failure = await service.lastFailure {
                app?.note(.session, "The band could not play that", detail: failure)
                return DirectorAuditionOutcome(
                    played: false,
                    detail: "Nothing came out: \(failure). Everything else about the groove is still true.")
            }
            app?.note(.director, "Played \(request.handle)",
                      detail: String(format: "%d bar(s) at %.0f bpm, %d hits", request.bars,
                                     request.tempo, hits.count))
            return DirectorAuditionOutcome(
                played: true,
                detail: String(format: "Played %d bar(s) of %@ at %.0f bpm — %d hits through the "
                                     + "chop's own pads on the app's engine.",
                               request.bars, request.handle, request.tempo, hits.count))
        } catch {
            return DirectorAuditionOutcome(
                played: false,
                detail: "Nothing was played: \(error). Everything else about the groove is still true.")
        }
    }

    /// How much of a performance `bars` bars is, in seconds.
    static func seconds(bars: Int, tempo: Double, beatsPerBar: Int) -> Double {
        guard tempo > 0 else { return 0 }
        return Double(max(1, bars)) * Double(max(1, beatsPerBar)) * 60 / tempo
    }
}
