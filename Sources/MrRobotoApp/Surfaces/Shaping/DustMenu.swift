import Instrument
import SongGraph
import SwiftUI

/// The dust on a chop or a groove, as a menu on the surface the part lives in: the chip reads the
/// machine on top of its chain — Clean, SP-1200, MPC60 — and choosing another keeps a new version
/// of the part through it, the dry one a step back. Two clicks, where it used to be a surface.
///
/// The last item opens the rest of the chain — its nine parameters — in a popover, and the A/B
/// beside the menu (`DustMonitorChips`) plays the part dry, a true bypass, from the surface's own
/// play.
struct DustMenu: View {
    /// What the part plays through now.
    let passes: [Degradation]
    /// Whether there is a part to make dusty. An empty grid has nothing to put through a machine.
    var isEnabled = true
    /// The hue of the part, for the chip when it wears dust.
    var tint: Color? = nil
    /// Keeps the part through this machine.
    let choose: (DegradeSettings.Preset) -> Void
    /// The chain's model, for the popover. Nil where there is nothing behind the surface to open
    /// one on — a render, a test — and then the menu has no last item.
    var shape: (() -> SoundShaping?)? = nil

    @State private var shaping: SoundShaping?

    var body: some View {
        let chosen = Dust.preset(on: passes)
        ChipMenu(Dust.chip(passes)) {
            ForEach(DegradeSettings.Preset.allCases, id: \.self) { preset in
                MenuChoice(Dust.machineName(preset.rawValue), isOn: chosen == preset || (preset == .clean && passes.isEmpty),
                           help: Self.help(for: preset)) {
                    choose(preset)
                }
            }
            if let shape {
                Divider()
                Button("The rest of the chain…") { shaping = shape() }
                    .help("Every stage of the chain, each in its own unit, to move by hand. Every knob let go of is a version.")
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(isEnabled
              ? "The machine the part plays through, kept as a new version of it; the clean one stays a step back."
              : "Nothing to put through a machine yet")
        .accessibilityLabel("Dust: \(Dust.chip(passes))")
        .popover(item: $shaping, arrowEdge: .bottom) { model in
            ShapePopover(shaping: model)
        }
    }

    /// Each machine as the instrument's research describes it, for the item's tooltip.
    static func help(for preset: DegradeSettings.Preset) -> String {
        switch preset {
        case .clean: return "No chain at all: the part as it was cut or played."
        case .sp1200: return "12 bits at 26.04 kHz, unfiltered: the grit of an E-mu SP-1200."
        case .mpc60: return "12 bits, companded, at 40 kHz: the Akai MPC60's warmer floor."
        case .cassette: return "Tape: wow and flutter, hiss, a soft top end."
        case .vinyl: return "A record: crackle, a slow wobble, the dust of a pressing."
        case .radio: return "A small speaker and a saturating stage: band-limited and driven."
        }
    }
}

/// The A/B beside a Dust menu: Chain plays the part as its version says it sounds, Dry plays it
/// with no chain on it at all — a true bypass, not the chain set to clean, which is what makes the
/// comparison worth making. Drawn only once the part carries a chain; dry against dry is nothing.
struct DustMonitorChips: View {
    @Binding var hearsDry: Bool
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            chip("Chain", isOn: !hearsDry) { hearsDry = false }
                .help("Hear the part through its chain, as the song plays it")
            chip("Dry", isOn: hearsDry) { hearsDry = true }
                .help("Dry is a true bypass: the part with no chain on it at all")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("A/B: \(hearsDry ? "dry" : "through the chain")")
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StudioChip(isOn: isOn, tint: tint) { ChipText(title, isOn: isOn, size: 11.5) }
        }
        .buttonStyle(.plain)
    }
}
