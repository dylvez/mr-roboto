import Instrument
import SwiftUI

/// A pitched instrument, chosen. Chords and melodies play through whatever this names, so it sits
/// on both surfaces that sound one; choosing records a `.sound` part the way the drum machine does.
///
/// One chip reading the instrument's name, and a menu under it: a submenu a family, the
/// recordings in each before the synthesized ones. It was fourteen family chips and then every
/// instrument of the browsed family in two more rows — a wall of pills over the lane, and a family
/// is how a player looks for a sound anyway: "a pad", "something plucked".
struct InstrumentPicker: View {
    let selected: String
    let choose: (String) -> Void
    var label = "Instrument"

    /// An imported instrument asked to be removed, waiting on the confirmation.
    @State private var removing: InstrumentVoiceSpec?

    @Environment(\.importedInstruments) private var imported
    @Environment(\.importInstrument) private var importInstrument
    @Environment(\.removeInstrument) private var removeInstrument

    /// Grouped as a keyboard's bank list: keys and organs, the struck things, guitars and basses,
    /// strings plucked and bowed, pads, winds and brass, then the synths.
    static let families: [(id: String, title: String)] = [
        ("keys", "Keys"), ("organ", "Organs"), ("bell", "Mallets & bells"), ("guitar", "Guitars"), ("bass", "Basses"),
        ("plucked", "Plucked strings"), ("strings", "Strings"), ("pad", "Pads & voices"), ("wind", "Winds"), ("brass", "Brass"),
        ("pluck", "Synth plucks"), ("lead", "Leads"), ("chip", "Chip"),
        (ImportedInstruments.family, "Imported"),
    ]

    /// The presets and whatever has been imported, in the families' order.
    private var instruments: [InstrumentVoiceSpec] { InstrumentVoiceSpec.all + imported }

    private var spec: InstrumentVoiceSpec? { InstrumentVoiceSpec.preset(id: selected) }

    /// The imports that can be taken out of the library again: a recording, not one of the
    /// sections built from recordings.
    private var removable: [InstrumentVoiceSpec] {
        imported.filter { $0.engine == .sampled && !$0.isEnsemble }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoothLabel(label)
            ChipMenu(spec?.name ?? "Choose an instrument") {
                ForEach(Self.families.filter { family in instruments.contains { $0.family == family.id } }, id: \.id) { entry in
                    Menu(familyTitle(entry)) {
                        // Recordings first, and said to be: a recorded cello and a synthesized one
                        // are different instruments with the same name.
                        let inFamily = instruments.filter { $0.family == entry.id }
                        section("Recorded", inFamily.filter { $0.engine == .sampled })
                        section("Synthesized", inFamily.filter { $0.engine != .sampled })
                    }
                }
                if importInstrument != nil || (removeInstrument != nil && !removable.isEmpty) {
                    Divider()
                }
                if removeInstrument != nil, !removable.isEmpty {
                    Menu("Remove from the Library") {
                        ForEach(removable, id: \.id) { spec in
                            Button("\(spec.name)…") { removing = spec }
                        }
                    }
                }
                if let importInstrument {
                    // Chosen as soon as it is in: importing from here is asking to play it here.
                    Button("Import SFZ…") {
                        if let id = importInstrument() { choose(id) }
                    }
                    .help("Bring in a sampled instrument from an SFZ pack. Its samples are copied into the library.")
                }
            }
            .help("What plays it: the presets by family, the recordings in each before the synthesized ones, "
                  + "and whatever has been imported from an SFZ pack.")
            .accessibilityLabel("\(label): \(spec?.name ?? "none chosen")")
            if let spec {
                // What it sounds like, as a player would say it; how it is made is in the tooltip.
                Text("\(spec.name): \(Self.character(spec))")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Self.describe(spec))
                // A synthesized piano, trumpet or string section, when the library has the real one.
                if spec.engine != .sampled, let recording = RecordedSounds.recording(for: spec.id, among: imported) {
                    BoothChip("Play it on the \(recording.name)") { choose(recording.id) }
                        .help("The \(spec.name) is synthesized. \(recording.name) is a recording in the library: \(Self.character(recording))")
                }
            }
        }
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

    /// The family, and the chosen instrument's name after it when it is in there, so the family
    /// it lives in — the one to look in for something like it — is found without opening each.
    private func familyTitle(_ entry: (id: String, title: String)) -> String {
        guard let spec, spec.family == entry.id else { return entry.title }
        return "\(entry.title) · \(spec.name)"
    }

    /// The instruments of one kind in a family, each with what it sounds like as its tooltip.
    @ViewBuilder
    private func section(_ title: String, _ specs: [InstrumentVoiceSpec]) -> some View {
        if !specs.isEmpty {
            Section(title) {
                ForEach(specs, id: \.id) { spec in
                    MenuChoice(spec.name, isOn: spec.id == selected, help: Self.character(spec)) { choose(spec.id) }
                }
            }
        }
    }

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
        case .drawbar:
            let bars = spec.drawbars
            let percussion = bars?.percussion.map { ", percussion on the \($0.harmonic == 2 ? "second" : "third") harmonic, \($0.fast ? "fast" : "slow")" } ?? ""
            let speaker = spec.insert.map { ", through \($0.phrase)" } ?? ""
            return "Tonewheel organ, drawbars \(bars?.text ?? "888000000")\(percussion)\(speaker)."
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
