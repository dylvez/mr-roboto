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
                if layout.showsVoiceReadout { VoiceReadout(surface: surface, layout: layout, lane: lane) }
                if surface.subject.isPart { partStatus }
                if surface.panel == .voice, let recording = surface.recordedAs { recordedNote(recording) }
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

    /// The lane of what is being shaped: a drum voice's own, as the Grid paints its row — a kick
    /// red, a tom magenta — or a chop's or a groove's part colour. Every chosen chip, the two
    /// prominent sliders and the drawn sound wear it.
    private var lane: Int? {
        if case .part(let type) = surface.subject { return PartHue.index(for: type) }
        return LaneClass(surface.draft.voice.drumVoice).rawValue
    }

    /// The same, as words: a chip's, a card's, a slider's.
    private var hue: Color? { lane.map { Design.Palette.lane($0, .ink) } }

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
                .foregroundStyle(Design.Palette.danger)
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
            Text("Tune, decay and tone are a synthesizer's knobs, and this is not one. Its level is here, and Chain puts dust on it as on any voice.")
                .font(Design.Typography.prose(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: SoundLayout.maximumControlWidth, alignment: .leading)
    }

    private var voicePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(surface.draft.availableVoices, id: \.self) { voice in
                    let isOn = surface.draft.voice == voice
                    let lane = LaneClass(voice.drumVoice)
                    Button { surface.select(voice) } label: {
                        StudioChip(isOn: isOn, tint: lane.color(.ink)) {
                            HStack(spacing: 5) {
                                Circle().fill(lane.color).frame(width: 6, height: 6)
                                ChipText(voice.rawValue, isOn: isOn, size: 12)
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
                Text(control.labelName)
                    .font(Design.Typography.ui(13, weight: .semibold))
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

    private func quietGrid(_ controls: [SoundControl], _ layout: SoundLayout) -> some View {
        LazyVGrid(columns: Self.grid(layout.quietColumns), alignment: .leading, spacing: 12) {
            ForEach(controls) { control in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(control.labelName)
                            .font(Design.Typography.label)
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
        .tint(control.isProminent ? (hue ?? Design.Palette.accent) : Design.Palette.lineStrong)
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
                    .foregroundStyle(Design.Palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Design.Palette.dangerSoft, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
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
                    .foregroundStyle(Design.Palette.danger)
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
                // A chip at a card's size: no outline, the machine in use on the selected fill.
                VStack(spacing: 3) {
                    ArtImage(Art.machine(preset.rawValue), width: 64, height: 40)
                    ChipText(name, isOn: isOn, size: 11)
                        .foregroundStyle(isOn ? (hue ?? Design.Palette.ink) : Design.Palette.inkSecondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(isOn ? (hue.map { Design.Palette.wash($0) } ?? Design.Palette.selected) : Design.Palette.fill,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
                .overlay {
                    if isOn, let hue {
                        RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous)
                            .strokeBorder(hue.opacity(0.6), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name)
        }
    }

    // MARK: A chip

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StudioChip(isOn: isOn, tint: hue) { ChipText(label, isOn: isOn, size: 12) }
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
    /// The lane of what is being shaped.
    var lane: Int? = nil

    /// The lane as words: the label over the name, the A/B's chosen side.
    private var hue: Color? { lane.map { Design.Palette.lane($0, .ink) } }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Metric.gutter) {
            VStack(alignment: .leading, spacing: 4) {
                SmallLabel(surface.panel == .chain ? "Chain on" : "Editing", color: hue ?? Design.Palette.inkTertiary)
                Text(surface.subject.isPart ? surface.subjectName : surface.draft.voice.rawValue)
                    .font(Design.Typography.prose(layout.readoutNameSize, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                    .lineLimit(1)
                Text(provenance)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            if let lane {
                VoiceScope(surface: surface, hue: Design.Palette.lane(lane, .plate))
                    .frame(minWidth: 120, maxWidth: 420, maxHeight: .infinity)
                    .padding(.vertical, 12)
            }
            Spacer(minLength: Design.Metric.gutter)
            // The two prominent knobs, in the units you would measure them in.
            HStack(alignment: .top, spacing: 22) {
                ForEach(surface.prominentControls) { control in
                    VStack(alignment: .trailing, spacing: 3) {
                        SmallLabel(control.labelName, color: Design.Palette.inkTertiary)
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
        .background {
            if let lane {
                let fill = Design.Palette.lane(lane)
                LinearGradient(colors: [fill.opacity(0.2), fill.opacity(0)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .groupedArea()
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
            SmallLabel("A/B", color: Design.Palette.inkTertiary)
            HStack(spacing: 6) {
                ForEach(SoundMonitor.allCases, id: \.self) { side in
                    Button { surface.monitor = side } label: {
                        StudioChip(isOn: surface.monitor == side, height: Design.Metric.controlHeight, horizontalPadding: 14, tint: hue) {
                            ChipText(side == .chain ? "Chain" : "Dry", isOn: surface.monitor == side, size: 13)
                        }
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

/// The sound being shaped, drawn: its loudness along its length on the dark plate, the clean sound
/// as a grey shadow and what the chain makes of it in the colour of what is being shaped — so a
/// shorter decay, a crusher's grit or a chop's dust is seen as well as heard.
private struct VoiceScope: View {
    let surface: SoundSurface
    let hue: Color

    @State private var dry: [Float] = []
    @State private var wet: [Float] = []

    /// What the drawing depends on: the draft, whether the dry part has arrived, and which pass is
    /// being edited.
    private struct Inputs: Equatable {
        var draft: SoundState
        var ready: Bool
        var stacks: Bool
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(hue.opacity(0.3)))
            context.fill(Self.shape(dry, in: size), with: .color(Design.Palette.inkQuiet.opacity(0.5)))
            var lit = context
            lit.addFilter(.shadow(color: hue.opacity(0.75), radius: 6))
            lit.fill(Self.shape(wet, in: size),
                     with: .linearGradient(Gradient(colors: [hue, hue.opacity(0.55)]),
                                           startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
        .background(Design.Palette.plate, in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
        .task(id: Inputs(draft: surface.draft, ready: surface.dryPart != nil, stacks: surface.stacksPass)) {
            // A knob dragged moves the draft at the display's rate; drawing waits for it to pause.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            dry = Self.peaks(surface.rendered(.dry))
            wet = Self.peaks(surface.rendered(.chain))
        }
        .help("The sound as it is now, in colour, over the clean sound in grey")
        .accessibilityHidden(true)
    }

    /// A waveform's outline, mirrored about the middle.
    static func shape(_ peaks: [Float], in size: CGSize) -> Path {
        var path = Path()
        guard peaks.count > 1 else { return path }
        let mid = size.height / 2
        let step = size.width / CGFloat(peaks.count - 1)
        path.move(to: CGPoint(x: 0, y: mid))
        for (i, v) in peaks.enumerated() { path.addLine(to: CGPoint(x: CGFloat(i) * step, y: mid - CGFloat(v) * (mid - 2))) }
        for (i, v) in peaks.enumerated().reversed() { path.addLine(to: CGPoint(x: CGFloat(i) * step, y: mid + CGFloat(v) * (mid - 2))) }
        path.closeSubpath()
        return path
    }

    /// The loudest sample in each of `count` slices, on a decibel scale from −54 dB to full: a drum
    /// dies away exponentially, and drawn on a straight scale its tail would be a line.
    static func peaks(_ samples: [Float], count: Int = 180) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let size = max(1, samples.count / count)
        return stride(from: 0, to: samples.count, by: size).map { start in
            let peak = samples[start..<min(samples.count, start + size)].reduce(Float(0)) { max($0, abs($1)) }
            let db = 20 * log10(max(peak, 1e-6))
            return max(0, min(1, (db + 54) / 54))
        }
    }
}

private extension SoundControl {
    /// The control's name as its label is set: sentence case ("Bit depth") where the machine's
    /// own name is in capitals. The name itself stays the panel's, for help and accessibility.
    var labelName: String {
        name.prefix(1).uppercased() + name.dropFirst().lowercased()
    }
}
