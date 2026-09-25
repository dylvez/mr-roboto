import AudioEngine
import Foundation
import Performance
import SongGraph

/// What the Mixer and the Master need from the frame: the song and its plan, a preview on the
/// strips, a version recorded, the meters, and a bounce through a mix.
@MainActor
public protocol MixHosting: AnyObject {
    var song: Song? { get }
    var playback: SongPlayback { get }
    var isPlaying: Bool { get }
    /// The album's targets when the song is on one, else −14 / −1.
    var targets: Master { get }
    /// The mix on the strips now, no version.
    func preview(_ mix: Mix)
    /// A mix version, with `base` as its parent. Nil, with the reason in the rail, when it cannot be.
    func commit(_ mix: Mix, base: PartVersion?, note: String) -> PartVersion?
    /// The strips' meters right now, 0…1.
    func meters(for parts: [PartID]) async -> [PartID: (peak: Float, rms: Float)]
    /// A section (or the song) bounced through a mix: planar audio at its rate.
    func bounce(mix: Mix, section: SectionID?) async throws -> (planar: [[Float]], sampleRate: Double)
    func note(_ text: String, detail: String?)
}

@MainActor
final class MixAdapter: MixHosting {
    private let app: AppState

    init(app: AppState) { self.app = app }

    var song: Song? { app.song }
    var playback: SongPlayback { app.playback }
    var isPlaying: Bool { app.transport.isPlaying }

    var targets: Master {
        guard let song = app.song, let album = app.library.albums.first(where: { $0.songs.contains(song.id) }) else { return Master() }
        return Master(gainDB: 0, ceilingDBTP: album.targets.truePeakDBTP, targetLUFS: album.targets.integratedLUFS)
    }

    func preview(_ mix: Mix) { app.previewMix(mix) }

    func commit(_ mix: Mix, base: PartVersion?, note: String) -> PartVersion? {
        guard let song = app.song else {
            app.note(.session, "No song open to mix")
            return nil
        }
        let partID = base?.partID ?? Guidance.mixes(in: song).last?.partID ?? PartID()
        let version = PartVersion(partID: partID, kind: .mix(mix), author: .user, parents: base.map { [$0.id] } ?? [],
                                  operation: Operation.mix, note: note)
        return app.record(version) ? version : nil
    }

    func meters(for parts: [PartID]) async -> [PartID: (peak: Float, rms: Float)] {
        guard app.transport.isPlaying, let engine = try? await app.engine() else { return [:] }
        return await Self.read(parts, on: engine)
    }

    @AudioActor
    private static func read(_ parts: [PartID], on engine: Engine) -> [PartID: (peak: Float, rms: Float)] {
        guard let graph = try? engine.mixGraph() else { return [:] }
        var out: [PartID: (peak: Float, rms: Float)] = [:]
        for part in parts { out[part] = graph.meter(for: part) }
        return out
    }

    func bounce(mix: Mix, section: SectionID?) async throws -> (planar: [[Float]], sampleRate: Double) {
        var plan = app.playback
        plan.mix = mix
        let stems = try await SectionBounce.render(plan, section: plan.isArranged ? section : nil,
                                                   kitsDirectory: AuditionService.defaultKitsDirectory,
                                                   onlyTheMix: true)
        return (stems.mix, stems.sampleRate)
    }

    func note(_ text: String, detail: String?) { app.note(.session, text, detail: detail) }
}
