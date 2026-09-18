import Analysis
import Foundation
import MusicTheory
import SongGraph

/// Carrying a `MergeMove` out: audio through Signalsmith, written parts by arithmetic.
///
/// Nothing here touches the graph. It takes planar floats or a part and gives back the moved
/// version of the same; recording the result as a version, with the original one parent back, is
/// the app's job. The audio path is deterministic (a fixed seed), so a render today and the same
/// render tomorrow are the same bytes — the property `SliceStretch` was built around.
public enum MergeRender {

    /// The tonal preset: 480 ms blocks at a 60 ms hop. Measured on a 98 Hz tone (`MergeRenderTests`):
    /// the library's 120 ms default lands a −2 semitone shift 26 cents sharp, because a bass note
    /// is a fraction of a bin at that block length; at 480 ms every shift from −5 to +5 is within
    /// ±3 cents. Transients blur at this length, which is why drums take the percussive preset.
    public static let tonalPreset = SignalsmithTimeStretcher.Preset.custom(block: 0.48, interval: 0.06)

    /// The stretcher a move needs: tonal for harmony and bass, percussive for drums.
    public static func stretcher(for move: MergeMove) -> SignalsmithTimeStretcher {
        SignalsmithTimeStretcher(preset: move.keepsTransients ? .percussive : tonalPreset,
                                 preserveFormants: move.preservesFormants, seed: 1)
    }

    /// Planar audio moved as the plan says: shifted by `semitones`, stretched by `ratio`.
    /// An untouched move returns the input as it is, bit for bit.
    public static func audio(_ planar: [[Float]], sampleRate: Double, move: MergeMove) throws -> [[Float]] {
        guard !move.isUntouched else { return planar }
        return try stretcher(for: move)
            .stretch(planar: planar, sampleRate: sampleRate, ratio: move.ratio, pitchShift: Double(move.semitones))
    }

    /// A chop's slice markers, re-timed with the stretch (T3) and re-based on a media that holds
    /// only the region: a marker at `position` inside `region` lands at `(position − region.start) × ratio`.
    public static func slices(_ slices: [SliceMarker], region: SongGraph.TimeRange, ratio: Double) -> [SliceMarker] {
        slices.filter { $0.position >= region.start && $0.position < region.end }
            .map { SliceMarker(position: ($0.position - region.start) * ratio, label: $0.label) }
    }

    /// A bass line moved by arithmetic (K3): every pitch by `semitones`, the key with it.
    public static func bassline(_ line: Bassline, move: MergeMove) -> Bassline {
        guard move.semitones != 0 else { return line }
        return Bassline(notes: line.notes.map { note in
            var moved = note
            moved.pitch = note.pitch.transposed(by: move.semitones)
            return moved
        }, sound: line.sound, key: move.key ?? line.key)
    }

    /// A progression moved by arithmetic: every chord by `semitones`, the key with it.
    public static func progression(_ progression: Progression, move: MergeMove) -> Progression {
        guard move.semitones != 0 else { return progression }
        let bars = progression.bars.map { bar in
            ProgressionBar(chords: bar.chords.map { ChordSpan(chord: $0.chord.transposed(by: move.semitones), beats: $0.beats) })
        }
        return Progression(key: move.key ?? progression.key, bars: bars)
    }
}
