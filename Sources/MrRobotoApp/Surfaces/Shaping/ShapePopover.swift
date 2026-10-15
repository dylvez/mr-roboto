import Instrument
import SwiftUI

/// The Shape popover: a drum voice's knobs and the chain over it, or the nine stages of the chain
/// on a chop or a groove, each with its real unit set beside it — because the person using this is
/// checking a 909's sweep against a 909 by ear, and "0.62" is not something you can check.
///
/// It opens from a voice's name on the Grid ("Shape the kick…") and from a Dust menu's last item
/// ("The rest of the chain…"). Nothing here decides what a control *is*; that is `SoundControl`,
/// and the view only decides how loudly to say it: the two prominent controls of a set are drawn a
/// size larger. Every knob let go of is a version, so there is no Keep and no Revert — by the time
/// either could be pressed, the move is already kept, and the footer says so.
///
/// A voice a recording plays shows its level and the chain, and nothing else: a recording has no
/// circuits, and the popover does not pretend it has.
struct ShapePopover: View {
    @Bindable var shaping: SoundShaping

    /// A slider past this is not more precise, only longer.
    static let width: CGFloat = 400
    /// Past this the popover scrolls rather than growing to the chain's full height.
    static let maximumHeight: CGFloat = 640

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                if shaping.subject.isPart { partStatus } else if let recording = shaping.recordedAs { recordedNote(recording) }
                let voice = shaping.voiceControls
                if !voice.isEmpty { section("Voice", voice) }
                chain
                if !shaping.chainFindings.isEmpty { findings }
                footer
            }
            .padding(Design.Metric.inset)
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
        .background(Design.Palette.panel)
    }

    /// The lane of what is being shaped: a drum voice's own, as the Grid paints its row, or a chop's
    /// or a groove's part colour. The chosen chips and the prominent sliders wear it.
    private var hue: Color? {
        if case .part(let type) = shaping.subject { return PartHue.index(for: type).map { Design.Palette.lane($0, .ink) } }
        return LaneClass(shaping.draft.voice.drumVoice).color(.ink)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shaping.subjectName)
                .font(Design.Typography.prose(16, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
                .lineLimit(1)
            Text(shaping.provenance)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
        }
    }

    /// Where the dry part is: still rendering, could not be read, or what the chain goes over.
    @ViewBuilder
    private var partStatus: some View {
        if let failure = shaping.dryFailure {
            Text("The dry part could not be rendered, so nothing plays. \(failure)")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if shaping.dryPart == nil {
            Text("Rendering the dry part…")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    /// A voice a recording plays has no circuits: what it is, said once, and no synthesizer's words.
    private func recordedNote(_ recording: String) -> some View {
        Text("A recording: \(recording). Its level is here, and the chain puts dust on it as on any voice.")
            .font(Design.Typography.prose(12))
            .foregroundStyle(Design.Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The chain

    private var chain: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SmallLabel("Chain", color: Design.Palette.inkTertiary)
                presets
                if shaping.subject.isPart {
                    Spacer(minLength: 4)
                    // A chop or a groove that already carries dust: edit the chain it has, or stack
                    // another over it. Stacking is allowed, and it is what the critic below flags.
                    if !shaping.beneath.isEmpty || shaping.stacksPass {
                        chip("Change its dust", isOn: !shaping.stacksPass) { shaping.setStacking(false) }
                            .help("Edit the machine on top of the chain")
                        chip("Add more dust", isOn: shaping.stacksPass) { shaping.setStacking(true) }
                            .help("Put another machine over the chain it has; the Sampler says what a second quantiser costs")
                    }
                }
            }
            if !shaping.beneath.isEmpty {
                Text("Over \(Dust.spoken(shaping.beneath)), which this version already plays through.")
                    .font(Design.Typography.prose(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            rows(shaping.chainControls)
        }
    }

    /// The chain's named machines, as a menu: the one the draft is at, or the one it left.
    private var presets: some View {
        let matching = shaping.draft.degrade.matchingPreset
        let title = matching.map { Dust.machineName($0.rawValue) }
            ?? (shaping.draft.degrade.isBypass ? "Clean" : "\(Dust.machineName(shaping.draft.chainBase.rawValue)) · moved")
        return ChipMenu(title) {
            ForEach(DegradeSettings.Preset.allCases, id: \.self) { preset in
                MenuChoice(Dust.machineName(preset.rawValue), isOn: matching == preset,
                           help: DustMenu.help(for: preset)) {
                    shaping.apply(preset)
                }
            }
        }
        .help("A named machine's whole parameter set, kept at once; the knobs below move from it.")
        .accessibilityLabel("Chain preset: \(title)")
    }

    // MARK: Controls

    private func section(_ title: String, _ controls: [SoundControl]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel(title, color: Design.Palette.inkTertiary)
            rows(controls)
        }
    }

    private func rows(_ controls: [SoundControl]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controls) { control in
                row(control)
            }
        }
    }

    /// One control: its name and its value in a real unit, the way back once it has left the
    /// preset, the slider, and — drawn rather than hidden in a tooltip, because a tooltip is a thing
    /// you find and this is a thing you need to have read — what it is really wired to.
    private func row(_ control: SoundControl) -> some View {
        let prominent = control.isProminent
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(control.labelName)
                    .font(prominent ? Design.Typography.ui(13, weight: .semibold) : Design.Typography.label)
                    .foregroundStyle(prominent ? Design.Palette.ink : Design.Palette.inkSecondary)
                Spacer()
                Text(control.readout)
                    .font(Design.Typography.numeric(prominent ? 12 : 11))
                    .foregroundStyle(prominent ? Design.Palette.inkSecondary : Design.Palette.inkTertiary)
                resetChip(control)
            }
            slider(control)
            if let honestly = control.honestly {
                Text(honestly)
                    .font(Design.Typography.prose(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("\(control.name): \(control.readout)")
        .contextMenu { Button("Back to the preset") { shaping.reset(control.parameter) } }
    }

    /// The way back to the preset, visible beside the readout once the knob has left it.
    @ViewBuilder
    private func resetChip(_ control: SoundControl) -> some View {
        if !shaping.isAtPreset(control.parameter) {
            Button { shaping.reset(control.parameter) } label: {
                StudioChip(height: Design.Metric.tagHeight, horizontalPadding: 0) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(Design.Typography.ui(10))
                        .frame(width: Design.Metric.tagHeight)
                }
            }
            .buttonStyle(.plain)
            .help("Back to the preset: puts \(control.name) where the machine had it, and plays it.")
            .accessibilityLabel("\(control.name) back to the preset")
        }
    }

    private func slider(_ control: SoundControl) -> some View {
        Slider(value: binding(control), in: control.range) { editing in
            // A knob turn is audible while held; the version is written when it is let go, so a
            // drag leaves one new version behind rather than sixty.
            if !editing { shaping.commit() }
        }
        .controlSize(.small)
        .tint(control.isProminent ? (hue ?? Design.Palette.accent) : Design.Palette.lineStrong)
        .accessibilityLabel(control.name)
        .accessibilityValue(control.readout)
    }

    private func binding(_ control: SoundControl) -> Binding<Double> {
        Binding(get: { control.value },
                set: { shaping.setValue($0, for: control.parameter) })
    }

    // MARK: The critic

    /// The chain critic, flagging and never fixing: one line per finding, in the Sampler's words.
    private var findings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shaping.chainFindings) { finding in
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

    // MARK: Footer

    /// What a knob let go of became. The one time a draft outlives a release is when the host
    /// refused it, and then the draft is offered again rather than left looking kept.
    private var footer: some View {
        HStack(spacing: 10) {
            if let failure = shaping.chainFailure {
                Text("Chain unavailable — auditioning dry. \(failure)")
                    .font(Design.Typography.prose(12))
                    .foregroundStyle(Design.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if shaping.lastCommitWasRefused, shaping.isDirty {
                Text("This move could not be kept; the reason is in the rail.")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.danger)
                Button("Try again") { shaping.commit() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .help("Hands the same move to the host again as a new version.")
            } else if shaping.isDirty {
                Text("Kept as a version when you let go")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else if shaping.lastKept != nil {
                Text(keptLine)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .help("Every knob let go of is a new version of the same part; the ledger lists them and any one of them can be gone back to from there.")
            } else {
                Text("Every knob let go of is a version")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }

    /// "Last move kept as a new version of Kick · 3 this session". The popover has no song to
    /// count versions in, so it counts its own rather than guessing at the ledger's number.
    private var keptLine: String {
        let name = shaping.lastKept.map(PartLabel.title(of:)) ?? shaping.subjectName
        return "Last move kept as a new version of \(name) · \(shaping.keptCount) this session"
    }

    // MARK: A chip

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StudioChip(isOn: isOn, tint: hue) { ChipText(label, isOn: isOn, size: 11.5) }
        }
        .buttonStyle(.plain)
    }
}

extension SoundControl {
    /// The control's name as its label is set: sentence case ("Bit depth") where the machine's
    /// own name is in capitals. The name itself stays the panel's, for help and accessibility.
    var labelName: String {
        name.prefix(1).uppercased() + name.dropFirst().lowercased()
    }
}
