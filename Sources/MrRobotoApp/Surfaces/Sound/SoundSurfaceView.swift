import Instrument
import SwiftUI

/// The Sound surface as a panel in the bench.
///
/// Two prominent levers, the rest quiet underneath, and every value's real unit set in the numeric
/// face beside it — because the person using this is checking a 909's sweep against a 909 by ear,
/// and "0.62" is not something you can check.
///
/// Every colour, face and metric comes from `Design`. Nothing here decides what a control *is*;
/// that is `SoundControl`, and the view only decides how loudly to say it.
struct SoundSurfaceView: View {
    @Bindable var surface: SoundSurface

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            Divider().overlay(Design.Palette.line)
            if surface.panel == .chain { chainPresets }
            controls
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metric.inset)
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(surface.title)
                    .font(Design.Typography.prose(16, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                Spacer()
                monitorSwitch
            }
            HStack(spacing: 6) {
                ForEach(SoundPanel.allCases, id: \.self) { panel in
                    chip(panel.title, isOn: surface.panel == panel) { surface.panel = panel }
                }
                Divider().frame(height: 14).overlay(Design.Palette.line)
                voicePicker
            }
        }
    }

    /// The A/B. `DRY` is a true bypass, not the chain set to clean — the chain can only ever
    /// compress, so the comparison is level-matched by construction and worth making.
    private var monitorSwitch: some View {
        HStack(spacing: 6) {
            Text("A/B")
                .font(Design.Typography.label)
                .tracking(0.6)
                .foregroundStyle(Design.Palette.inkTertiary)
            ForEach(SoundMonitor.allCases, id: \.self) { side in
                chip(side == .chain ? "Chain" : "Dry", isOn: surface.monitor == side) {
                    surface.monitor = side
                }
            }
        }
        .help("Dry is a true bypass: the synthesizer's own samples, untouched.")
    }

    private var voicePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(surface.draft.availableVoices, id: \.self) { voice in
                    chip(voice.rawValue, isOn: surface.draft.voice == voice) {
                        surface.select(voice)
                    }
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            ForEach(surface.prominentControls) { control in
                prominentRow(control)
            }
            if surface.panel == .voice || surface.showsFullChain {
                quietGrid(surface.quietControls)
            } else {
                Button("The rest of the chain") { surface.showsFullChain = true }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.accent)
            }
        }
    }

    private func prominentRow(_ control: SoundControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(control.name)
                    .font(Design.Typography.ui(13, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Design.Palette.ink)
                Spacer()
                Text(control.readout)
                    .font(Design.Typography.numeric(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            slider(control)
            if let honestly = control.honestly {
                Text(honestly)
                    .font(Design.Typography.prose(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .contextMenu { Button("Back to the preset") { surface.reset(control.parameter) } }
    }

    private func quietGrid(_ controls: [SoundControl]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Design.Metric.gutter),
                            GridItem(.flexible(), spacing: Design.Metric.gutter)],
                  alignment: .leading, spacing: 12) {
            ForEach(controls) { control in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(control.name)
                            .font(Design.Typography.label)
                            .tracking(0.6)
                            .foregroundStyle(Design.Palette.inkSecondary)
                        Spacer()
                        Text(control.readout)
                            .font(Design.Typography.numeric(11))
                            .foregroundStyle(Design.Palette.inkTertiary)
                    }
                    slider(control)
                }
                .help(control.honestly ?? "")
                .contextMenu { Button("Back to the preset") { surface.reset(control.parameter) } }
            }
        }
    }

    private func slider(_ control: SoundControl) -> some View {
        Slider(value: binding(control), in: control.range) { editing in
            // A knob turn is audible while held; the version is written when it is let go, so a
            // drag leaves one new version behind rather than sixty.
            if !editing { surface.commit() }
        }
        .controlSize(.small)
        .tint(control.isProminent ? Design.Palette.accent : Design.Palette.lineStrong)
    }

    private func binding(_ control: SoundControl) -> Binding<Double> {
        Binding(get: { control.value },
                set: { surface.setValue($0, for: control.parameter) })
    }

    // MARK: Chain presets

    private var chainPresets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
                .font(Design.Typography.label)
                .tracking(0.6)
                .foregroundStyle(Design.Palette.inkTertiary)
            HStack(spacing: 6) {
                ForEach(DegradeSettings.Preset.allCases, id: \.self) { preset in
                    chip(preset.rawValue, isOn: surface.draft.degrade.matchingPreset == preset) {
                        surface.apply(preset)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let failure = surface.chainFailure {
                Text("Chain unavailable — auditioning dry. \(failure)")
                    .font(Design.Typography.prose(12))
                    .foregroundStyle(Design.Palette.warn)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Design.Palette.warnSoft, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            }
            Spacer()
            if surface.isDirty {
                Button("Revert") { surface.revert() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
                Button("Keep as a new version") { surface.commit() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
            } else {
                Text("No change since this version")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .frame(height: Design.Metric.chipHeight)
    }

    // MARK: A chip

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Design.Typography.ui(12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .padding(.horizontal, 9)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line,
                                lineWidth: Design.Metric.hairline)
                )
        }
        .buttonStyle(.plain)
    }
}
