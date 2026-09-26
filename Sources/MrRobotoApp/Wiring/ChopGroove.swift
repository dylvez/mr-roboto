import Analysis
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// A groove played on a chop's slices, the way the song plays it.
///
/// This is the Chop lane's re-groove done again from what the song holds. The chop's bar is read
/// from its media and cut where the lane's kept markers say. Each slice is the class the lane
/// called it. The groove's steps are laid on those slices at the song's tempo. The pads are built
/// by the lane's own `ChopLaneSurface.map`, so the slice the lane called the kick is the one the
/// song plays.
///
/// Pad trims are not included, because `Sample` does not hold them (see
/// `ChopLaneSurface.commitChop`).
enum ChopGroove {

    /// A chop ready to be played on. It is rebuilt once per transport start, and each section's
    /// pass is re-grooved from it.
    struct Prepared: Sendable {
        var map: ChopMap
        var classifications: [SliceClassification]
        var overrides: [Int: SliceClass]
        /// The bar as it plays, through the chop's own chain: how the lane's pads sound.
        var playing: [[Float]]
        var sampleRate: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case empty(String)
        case noSlices(String)

        var description: String {
            switch self {
            case .empty(let name): return "\(name) holds no audio to play the groove on"
            case .noSlices(let name): return "\(name) has no slices to play the groove on"
            }
        }
    }

    /// The chop, read from its media and cut the way it was kept.
    static func prepare(_ track: SongPlayback.ChopTrack) throws -> Prepared {
        let span = try AudioRegion.read(track.url, from: track.region.start, to: track.region.end)
        return try prepare(track, dry: span.planar, sampleRate: span.sampleRate)
    }

    /// The same, from audio already in hand: the bar, dry, as `AudioRegion` reads it.
    static func prepare(_ track: SongPlayback.ChopTrack, dry: [[Float]], sampleRate: Double) throws -> Prepared {
        let mono = ChopAudio.mono(dry)
        guard !mono.isEmpty, sampleRate > 0 else { throw Failure.empty(track.name) }
        let duration = Double(mono.count) / sampleRate
        // The markers inside the bar, in the bar's own time. The overrides are read from this
        // filtered list, so each class stays with its marker even if one is dropped.
        let kept = track.slices
            .filter { $0.position >= track.region.start && $0.position - track.region.start < duration }
            .sorted { $0.position < $1.position }
        let cut: [Double]
        let overrides: [Int: SliceClass]
        if kept.count > 1 {
            cut = kept.map { $0.position - track.region.start }
            overrides = ChopLaneSurface.overrides(from: kept)
        } else {
            // A bar that was promoted and never cut. The lane would open it on a fresh detection
            // at its default sensitivity, so the song cuts it the same way.
            var detector = SpectralFluxOnsetDetector()
            detector.threshold = ChopLaneSurface.threshold(forSensitivity: ChopLaneSurface.defaultSensitivity)
            cut = detector.onsets(in: mono, sampleRate: sampleRate)
            overrides = [:]
        }
        // No grid: the kept markers already sit where the lane snapped them.
        let chop = Chopper().slice(atOnsets: cut, signal: mono, sampleRate: sampleRate,
                                   sourceOffset: track.region.start, detectedTempo: track.tempo)
        guard chop.count > 0 else { throw Failure.noSlices(track.name) }
        let classifications = SliceClassifier().classify(chop, in: mono, overrides: overrides)
        let map = ChopLaneSurface.map(of: chop, classifications: classifications, name: track.name)
        let playing = try Dust.render(dry, sampleRate: sampleRate, passes: track.passes)
        return Prepared(map: map, classifications: classifications, overrides: overrides,
                        playing: playing, sampleRate: sampleRate)
    }

    /// The chop as a kit a step touch can play. Every drum voice is named on the pad the song
    /// would play for it: the loudest slice of the class `Regroove` gives that voice. A class the
    /// chop has no slice of borrows the slice that scored closest to it, as the song does.
    static func padKit(_ chop: Prepared) throws -> ChopKit {
        var map = chop.map
        let policy = Regroove.Policy(overrides: chop.overrides)
        for voice in SynthVoiceKind.allCases.map(\.drumVoice) + [.perc] {
            guard let kind = policy.kind(for: voice) else { continue }
            let own = chop.classifications.filter { $0.kind == kind }.max { $0.peak < $1.peak }
            let closest = own ?? chop.classifications.max { $0.scores[kind] < $1.scores[kind] }
            guard let slice = closest, let note = map.note(forSlice: slice.sliceIndex) else { continue }
            map.setVoice(voice, note: note)
        }
        return try map.render(source: chop.playing)
    }

    /// `passes` passes of the groove on the chop, starting at time 0 and played at `tempo`. The
    /// result is the hits, plus the kit they play on. The kit is the performance's own map, which
    /// carries any stretched variants the placements needed.
    static func perform(_ groove: Groove, on chop: Prepared, tempo: Double, timeSignature: TimeSignature,
                        passes: Int) throws -> (hits: [VoiceSampler.Hit], kit: ChopKit) {
        let repeats = max(1, passes)
        let grid = BeatGrid.regular(bpm: tempo, timeSignature: timeSignature,
                                    bars: repeats * max(1, groove.bars) + 1)
        let performance = try Regroove(policy: Regroove.Policy(overrides: chop.overrides))
            .perform(chop.map, classifications: chop.classifications, groove: groove, grid: grid,
                     startBar: 0, repeats: repeats)
        let kit = try performance.map.render(source: chop.playing, stretch: SliceStretch())
        return (performance.hits, kit)
    }
}
