import Instrument
import SwiftUI

/// A pitched instrument, chosen. Chords and melodies play through whatever this names, so it sits
/// on both surfaces that sound one; choosing records a `.sound` part the way the drum machine does.
///
/// Families first, then the instruments in the one picked: forty-odd chips in one row was a wall,
/// and a family is how a player looks for a sound — "a pad", "something plucked".
struct InstrumentPicker: View {
    let selected: String
    let choose: (String) -> Void
    var label = "Instrument"

    /// The family whose instruments are showing; the selected instrument's until another is picked.
    @State private var browsing: String?
    /// An imported instrument asked to be removed, waiting on the confirmation.
    @State private var removing: InstrumentVoiceSpec?

    @Environment(\.importedInstruments) private var imported
    @Environment(\.importInstrument) private var importInstrument
    @Environment(\.removeInstrument) private var removeInstrument

    /// Grouped as a keyboard's bank list: keys and organs, the struck things, strings plucked and
    /// bowed, pads, winds and brass, then the synths.
    static let families: [(id: String, title: String)] = [
        ("keys", "Keys"), ("organ", "Organs"), ("bell", "Mallets & bells"), ("plucked", "Plucked strings"),
        ("strings", "Strings"), ("pad", "Pads & voices"), ("wind", "Winds"), ("brass", "Brass"),
        ("pluck", "Synth plucks"), ("lead", "Leads"), ("chip", "Chip"),
        (ImportedInstruments.family, "Imported"),
    ]

    /// The presets and whatever has been imported, in the families' order.
    private var instruments: [InstrumentVoiceSpec] { InstrumentVoiceSpec.all + imported }

    private var family: String {
        browsing ?? InstrumentVoiceSpec.preset(id: selected)?.family ?? Self.families[0].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoothLabel(label)
            FlowRow(spacing: 4) {
                ForEach(Self.families.filter { family in instruments.contains { $0.family == family.id } }, id: \.id) { entry in
                    FamilyChip(title: entry.title, isOn: entry.id == family,
                               holdsSelection: InstrumentVoiceSpec.preset(id: selected)?.family == entry.id) {
                        browsing = entry.id
                    }
                }
                if let importInstrument {
                    // Chosen as soon as it is in: importing from here is asking to play it here.
                    FamilyChip(title: "Import SFZ…", isOn: false, holdsSelection: false) {
                        if let id = importInstrument() {
                            browsing = ImportedInstruments.family
                            choose(id)
                        }
                    }
                    .help("Bring in a sampled instrument from an SFZ pack. Its samples are copied into the library.")
                }
            }
            FlowRow(spacing: 6) {
                ForEach(instruments.filter { $0.family == family }, id: \.id) { spec in
                    BoothChip(spec.name, isOn: spec.id == selected) { choose(spec.id) }
                        .help(Self.character(spec))
                        .contextMenu {
                            if spec.engine == .sampled, removeInstrument != nil {
                                Button("Remove \(spec.name) from the Library…") { removing = spec }
                            }
                        }
                }
            }
            if let spec = InstrumentVoiceSpec.preset(id: selected) {
                // What it sounds like, as a player would say it; how it is made is in the tooltip.
                Text("\(spec.name): \(Self.character(spec))")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Self.describe(spec))
            }
        }
        .onChange(of: selected) { _, _ in browsing = nil }
        .confirmationDialog("Remove \(removing?.name ?? "this instrument")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let spec = removing { removeInstrument?(spec.id) }
                removing = nil
            }
        } message: {
            Text("Its copied samples are deleted from the library. The SFZ pack it came from is not touched, and a song that played it goes back to its own instrument.")
        }
    }

    /// What the preset sounds like, in a player's words. "FM, two pairs, modulated at 1 and 14" was
    /// true and told nobody whether to reach for it.
    static func character(_ spec: InstrumentVoiceSpec) -> String {
        spec.summary.isEmpty ? describe(spec) : spec.summary
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
        case .pluckedString:
            let pluck = spec.pluck
            return String(format: "A plucked string: rings %.1f s at middle C, plucked %.0f%% along it.",
                          pluck?.decaySeconds ?? 0, (pluck?.pickPosition ?? 0) * 100)
        case .sampled:
            return spec.summary.isEmpty ? "Sampled: recordings from an SFZ pack." : spec.summary
        }
    }
}

extension EnvironmentValues {
    /// The instruments imported into the library, for the pickers. The frame sets it from
    /// `AppState.importedInstruments`, which is what makes a picker redraw after an import.
    @Entry var importedInstruments: [InstrumentVoiceSpec] = []
    /// File ▸ Import Instrument…, from a picker: the imported instrument's id, or nil if nothing was.
    @Entry var importInstrument: (@MainActor () -> String?)? = nil
    /// Removes an imported instrument from the library, after the picker has confirmed it.
    @Entry var removeInstrument: (@MainActor (String) -> Void)? = nil
}

/// One family in the picker: quiet until picked, with a dot when the chosen instrument is in it.
private struct FamilyChip: View {
    let title: String
    let isOn: Bool
    let holdsSelection: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if holdsSelection { Circle().fill(Design.Palette.accent).frame(width: 5, height: 5) }
                Text(title).font(Design.Typography.ui(11, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .foregroundStyle(isOn ? Design.Palette.ink : Design.Palette.inkSecondary)
            .background(isOn ? Design.Palette.panelAlt : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? Design.Palette.lineStrong : Color.clear, lineWidth: Design.Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(holdsSelection ? "\(title), holds the chosen instrument" : title)
    }
}
