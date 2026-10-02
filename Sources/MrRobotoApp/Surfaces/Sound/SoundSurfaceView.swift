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
        // Sound is the surface most at risk from a bigger bench, because it is a column of sliders
        // and a slider gains nothing past about 400 points. So the room is spent on saying what is
        // being edited and in what units — see `SoundLayout` for the argument — and the controls
        // themselves are capped.
        GeometryReader { geometry in
            let layout = SoundLayout(size: geometry.size)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header(layout)
                Divider().overlay(Design.Palette.line)
                if layout.showsVoiceReadout { VoiceReadout(surface: surface, layout: layout) }
                if surface.subject.isPart { partStatus }
                if surface.panel == .voice, let recording = surface.recordedAs { recordedNote(recording) }
                if surface.panel == .chain, !surface.subject.isPart { voiceChainNote }
                if surface.panel == .chain { chainPresets }
                controls(layout)
                if !surface.chainFindings.isEmpty { findings }
                Spacer(minLength: 0)
                footer
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private func header(_ layout: SoundLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(surface.title)
                    .font(Design.Typography.prose(16, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                Spacer()
                // With a readout the A/B moves into it at a size you can hit; without one it stays
                // here, because two chips in a corner is still better than no A/B at all.
                if !layout.showsLargeMonitorSwitch { monitorSwitch }
            }
            if surface.subject.isPart {
                // A chop or a groove has no voice to edit: the chain is the whole panel. What there
                // is instead is the choice between editing the chain it has and stacking another.
                HStack(spacing: 6) {
                    chip("Change its dust", isOn: !surface.stacksPass) { surface.setStacking(false) }
                    chip("Add more dust", isOn: surface.stacksPass) { surface.setStacking(true) }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(SoundPanel.allCases, id: \.self) { panel in
                        chip(panel.title, isOn: surface.panel == panel) { surface.panel = panel }
                    }
                    Divider().frame(height: 14).overlay(Design.Palette.line)
                    voicePicker
                }
            }
        }
    }

    /// Where the dry part is: still rendering, could not be read, or what the chain goes over.
    @ViewBuilder
    private var partStatus: some View {
        if let failure = surface.dryFailure {
            Text("The dry part could not be rendered, so nothing plays. \(failure)")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if surface.dryPart == nil {
            Text("Rendering the dry part…")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.inkTertiary)
        } else if !surface.beneath.isEmpty {
            Text("Over \(Dust.describe(surface.beneath)), which this version already plays through.")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
    }

    /// The chain critic, flagging and never fixing: one line per finding, in the Sampler's words.
    private var findings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(surface.chainFindings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.headline)
                        .font(Design.Typography.ui(12, weight: .semibold))
                        .foregroundStyle(finding.severity == .warn ? Design.Palette.warn : Design.Palette.inkSecondary)
                    Text(finding.why)
                        .font(Design.Typography.prose(12))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Design.Palette.warnSoft, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
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
        .help(surface.subject.isPart
              ? "Dry is a true bypass: the part with no chain on it at all."
              : "Dry is a true bypass: the synthesizer's own samples, untouched.")
    }

    /// A voice a recording plays has no circuits: what it is, and what there is to turn.
    private func recordedNote(_ recording: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("A recording: \(recording)")
                .font(Design.Typography.ui(12.5, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
            Text("Tune, decay and tone are a synthesizer's knobs, and this is not one. Its level is here; dust goes on the groove that plays it.")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: SoundLayout.maximumControlWidth, alignment: .leading)
    }

    /// A single voice's chain is an audition: the song takes dust on a groove or a chop, where the
    /// chain is applied to what is played. Said, so nobody keeps one expecting to hear it.
    private var voiceChainNote: some View {
        Text("A chain on one voice is heard here and not in the song. For dust the song plays, open Sound on the groove.")
            .font(Design.Typography.prose(12))
            .foregroundStyle(Design.Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: SoundLayout.maximumControlWidth, alignment: .leading)
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

    private func controls(_ layout: SoundLayout) -> some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            // Two prominent levers side by side once there is width for both at their capped size,
            // stacked at the window minimum.
            LazyVGrid(columns: Self.grid(layout.prominentColumns), alignment: .leading,
                      spacing: Design.Metric.gutter) {
                ForEach(surface.prominentControls) { control in
                    prominentRow(control, layout)
                }
            }
            if surface.panel == .voice || surface.showsFullChain {
                quietGrid(surface.quietControls, layout)
            } else {
                Button("The rest of the chain") { surface.showsFullChain = true }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.accent)
            }
        }
    }

    private static func grid(_ columns: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Design.Metric.gutter),
              count: max(1, columns))
    }

    private func prominentRow(_ control: SoundControl, _ layout: SoundLayout) -> some View {
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
                resetChip(control)
            }
            slider(control)
            if let honestly = control.honestly {
                Text(honestly)
                    .font(Design.Typography.prose(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The cap. A slider is not more precise for being longer, and six of them drawn at 1233
        // points is the ugliness this whole exercise is meant to avoid.
        .frame(maxWidth: layout.controlWidth, alignment: .leading)
        .help(control.honestly ?? "\(control.name): \(control.readout)")
        .contextMenu { Button("Back to the preset") { surface.reset(control.parameter) } }
    }

    /// The way back to the preset, visible beside the readout once the knob has left it. It was
    /// right-click only before, which is a way back you have to know about.
    @ViewBuilder
    private func resetChip(_ control: SoundControl) -> some View {
        if !surface.isAtPreset(control.parameter) {
            Button { surface.reset(control.parameter) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(Design.Typography.ui(10))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .frame(width: Design.Metric.tagHeight, height: Design.Metric.tagHeight)
                    .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                    .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the preset: puts \(control.name) where the machine had it, and plays it.")
            .accessibilityLabel("\(control.name) back to the preset")
        }
    }

    private func quietGrid(_ controls: [SoundControl], _ layout: SoundLayout) -> some View {
        LazyVGrid(columns: Self.grid(layout.quietColumns), alignment: .leading, spacing: 12) {
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
                        resetChip(control)
                    }
                    slider(control)
                    // What the control is really wired to, drawn rather than hidden in a tooltip —
                    // a tooltip is a thing you find, and this is a thing you need to have read.
                    if layout.showsInlineUnits, let honestly = control.honestly {
                        Text(honestly)
                            .font(Design.Typography.prose(11))
                            .foregroundStyle(Design.Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: layout.controlWidth, alignment: .leading)
                // Narrow, the wiring line is tooltip-only, so the tooltip is always there; and a
                // control with nothing to confess still names itself and its value.
                .help(control.honestly ?? "\(control.name): \(control.readout)")
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
        .accessibilityLabel(control.name)
        .accessibilityValue(control.readout)
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
                    machineCard(preset, isOn: surface.draft.degrade.matchingPreset == preset) {
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
            // A knob let go of is a version: that is how this surface was designed ("auditioned on
            // every knob"), and it is why there is no Keep and no Revert here — by the time either
            // could be pressed, the move is already kept. What the footer does instead is say so.
            // The one time a draft outlives a release is when the host refused it, and then the
            // draft is offered again rather than left looking kept.
            if surface.lastCommitWasRefused, surface.isDirty {
                Text("This move could not be kept; the reason is in the rail.")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.warn)
                Button("Try again") { surface.commit() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .help("Hands the same move to the host again as a new version.")
            } else if surface.isDirty {
                Text("Kept as a version when you let go")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else if surface.lastKept != nil {
                Text(keptLine)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .help("Every knob let go of is a new version of the same part; the ledger lists them and any one of them can be gone back to from there.")
            } else {
                Text("No change since this version")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .frame(height: Design.Metric.chipHeight)
    }

    /// "Last move kept as a new version of Kick · 3 this session". The panel has no song to count
    /// versions in, so it counts its own rather than guessing at the ledger's number.
    private var keptLine: String {
        let name = surface.lastKept.map(PartLabel.title(of:)) ?? surface.subjectName
        let count = surface.keptCount
        return "Last move kept as a new version of \(name) · \(count) this session"
    }

    // MARK: A machine card

    /// A chain preset as the machine it models: its picture over its name. Falls back to the plain
    /// chip when the picture is not bundled.
    @ViewBuilder
    private func machineCard(_ preset: DegradeSettings.Preset, isOn: Bool, action: @escaping () -> Void) -> some View {
        let name = Dust.machineName(preset.rawValue)
        if Art.image(Art.machine(preset.rawValue)) == nil {
            chip(name, isOn: isOn, action: action)
        } else {
            Button(action: action) {
                VStack(spacing: 3) {
                    ArtImage(Art.machine(preset.rawValue), width: 64, height: 40)
                    Text(name)
                        .font(Design.Typography.ui(11, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line,
                                lineWidth: Design.Metric.hairline)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name)
        }
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

// MARK: - The voice readout

/// What the Sound surface does with height it did not ask for.
///
/// The surface's argument is that you are checking a 909's sweep against a 909 by ear, and that a
/// knob position is not something you can check — so every control already carries its value in a
/// real unit. The trouble was that those units were set at 11 and 12 points beside a slider, which
/// is a footnote, and the thing being edited was named once in a 16-point title.
///
/// Given the room, both move up: the voice is named at the size of the thing you are working on,
/// the two prominent knobs' real units are set beside it in the numeric face, and the A/B — a true
/// bypass, and the most useful control on the panel — becomes a pair of controls you can hit rather
/// than two chips in the corner.
///
/// This is the whole of Sound's answer to a bigger bench. Nothing else here grows.
private struct VoiceReadout: View {
    @Bindable var surface: SoundSurface
    let layout: SoundLayout

    var body: some View {
        HStack(alignment: .top, spacing: Design.Metric.gutter) {
            VStack(alignment: .leading, spacing: 4) {
                Text(surface.panel == .chain ? "CHAIN ON" : "EDITING")
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Text(surface.subject.isPart ? surface.subjectName : surface.draft.voice.rawValue)
                    .font(Design.Typography.prose(layout.readoutNameSize, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                    .lineLimit(1)
                Text(provenance)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.Metric.gutter)
            // The two prominent knobs, in the units you would measure them in.
            HStack(alignment: .top, spacing: 22) {
                ForEach(surface.prominentControls) { control in
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(control.name)
                            .font(Design.Typography.label)
                            .tracking(1.1)
                            .foregroundStyle(Design.Palette.inkTertiary)
                        Text(control.readout)
                            .font(Design.Typography.numeric(layout.readoutValueSize))
                            .foregroundStyle(Design.Palette.ink)
                    }
                }
            }
            Divider().frame(height: layout.readoutHeight - 28).overlay(Design.Palette.line)
            monitor
        }
        .padding(.horizontal, Design.Metric.inset)
        .frame(height: layout.readoutHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    /// Where this sound came from: the machine, and the chain preset when one is doing something.
    private var provenance: String {
        if surface.subject.isPart {
            let passes = surface.chainPasses
            return passes.isEmpty ? "dry · chain off" : Dust.describe(passes)
        }
        let machine = surface.draft.synthMachine.name
        guard !surface.draft.degrade.isBypass else { return "\(machine) · chain off" }
        return "\(machine) · \(surface.draft.degrade.matchingPreset?.rawValue ?? "chain")"
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("A/B")
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            HStack(spacing: 6) {
                ForEach(SoundMonitor.allCases, id: \.self) { side in
                    Button { surface.monitor = side } label: {
                        Text(side == .chain ? "Chain" : "Dry")
                            .font(Design.Typography.ui(13, weight: surface.monitor == side ? .semibold : .regular))
                            .foregroundStyle(surface.monitor == side ? Design.Palette.accent : Design.Palette.inkSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: Design.Metric.controlHeight)
                            .background(surface.monitor == side ? Design.Palette.accentSoft : Design.Palette.panel,
                                        in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Metric.corner)
                                    .stroke(surface.monitor == side ? Design.Palette.accent : Design.Palette.line,
                                            lineWidth: Design.Metric.hairline)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Dry is a true bypass")
                .font(Design.Typography.ui(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}
