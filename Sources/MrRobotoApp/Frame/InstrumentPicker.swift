import Instrument
import SwiftUI

/// The song's pitched instrument, chosen. Chords and melodies play through whatever this names, so
/// it sits on both surfaces that sound one, and choosing here records a `.sound` part the way the
/// drum machine does — the choice belongs to the song, not to the surface that set it.
struct InstrumentPicker: View {
    let selected: String
    let choose: (String) -> Void
    var label = "Instrument"

    /// Grouped as a keyboard's bank list: keys, then the struck things, then pads and leads.
    private static let families = ["keys", "bell", "pad", "pluck", "lead"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoothLabel(label)
            FlowRow(spacing: 6) {
                ForEach(Self.families, id: \.self) { family in
                    ForEach(InstrumentVoiceSpec.all.filter { $0.family == family }, id: \.id) { spec in
                        BoothChip(spec.name, isOn: spec.id == selected) { choose(spec.id) }
                    }
                }
            }
            if let spec = InstrumentVoiceSpec.preset(id: selected) {
                Text(Self.describe(spec))
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the preset is, in its own terms: the engine and the one thing that shapes it.
    static func describe(_ spec: InstrumentVoiceSpec) -> String {
        switch spec.engine {
        case .fm:
            // The modulators are what shape it: their ratios say harmonic or bell-like at a glance.
            let carriers = spec.algorithm == .twinPairs ? [0, 2] : [0]
            let modulators = spec.operators.enumerated()
                .filter { $0.element.level > 0 && !carriers.contains($0.offset) }
                .map { String(format: "%g", $0.element.ratio) }
            let velocity = spec.velocityLayers.count > 1 ? " Velocity changes the timbre." : ""
            return "FM, \(spec.algorithm.title), modulated at \(modulators.joined(separator: " and ")).\(velocity)"
        case .subtractive:
            let shapes = Set(spec.oscillators.map(\.waveform.rawValue)).sorted().joined(separator: " + ")
            let filter = spec.filterEnvelopeOctaves > 0
                ? String(format: "filter opens %.1f octaves over %.2f s", spec.filterEnvelopeOctaves, spec.filterEnvelope.attack + spec.filterEnvelope.decay)
                : "filter fixed"
            return "Subtractive: \(shapes), \(filter), attack \(String(format: "%.0f ms", spec.amplitude.attack * 1_000))."
        }
    }
}
