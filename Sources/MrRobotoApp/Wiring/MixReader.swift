import Foundation
import Performance
import SongGraph

/// A mix, read: the song (or a section) bounced through the mix, and each strip bounced alone,
/// so the Engineer has the loudness, the true peak and the masking pairs. Used by the tools and
/// by a Check re-reading after a move.
enum MixReader {

    /// The strips a plan plays, with their labels.
    @MainActor
    static func strips(of plan: SongPlayback, song: Song?) -> [(part: PartID, label: String)] {
        MixerModel.rows(of: plan, song: song, mix: plan.mix ?? .unity).map { ($0.part, $0.label) }
    }

    /// The observation of a plan through `mix`, with every strip bounced apart.
    @MainActor
    static func observe(plan: SongPlayback, mix: Mix?, section: SectionID?, song: Song?, kitsDirectory: URL) async throws -> MixObservation {
        var whole = plan
        whole.mix = mix ?? plan.mix
        let target = whole.isArranged ? section : nil
        let stems = try await SectionBounce.render(whole, section: target, kitsDirectory: kitsDirectory, onlyTheMix: true)
        var solos: [(part: PartID, label: String, planar: [[Float]])] = []
        for strip in strips(of: plan, song: song) {
            var solo = whole
            var soloMix = whole.mix ?? .unity
            soloMix.strips = soloMix.strips.map { var s = $0; s.isSoloed = s.part == strip.part; s.isMuted = false; return s }
            var own = soloMix.strip(for: strip.part, label: strip.label)
            own.isSoloed = true
            soloMix.set(own)
            solo.mix = soloMix
            // Read for its bands, not delivered: the master's limiter is left off a solo, as it is
            // off a stem, rather than run once per strip over the whole song.
            let rendered = try await SectionBounce.render(solo, section: target, kitsDirectory: kitsDirectory,
                                                          onlyTheMix: true, mastered: false)
            solos.append((strip.part, strip.label, rendered.mix))
        }
        return MixObservation.measure(label: song?.title ?? stems.label, mix: stems.mix, sampleRate: stems.sampleRate, strips: solos)
    }
}
