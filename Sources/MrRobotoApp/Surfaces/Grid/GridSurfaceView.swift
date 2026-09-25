import AppKit
import Instrument
import Performance
import SongGraph
import SwiftUI

/// The Grid surface: a step grid over a groove, played by the groove engine.
///
/// Two prominent levers and no more: **swing**, in the MPC's own percentage, and **ghost level**.
/// Tempo, the machine and the feel are pickers; the tiers are a segmented brush; everything else is
/// the grid itself.
public struct GridSurfaceView: View {
    @Bindable public var model: GridModel

    public init(model: GridModel) {
        self.model = model
    }

    public var body: some View {
        // The grid is the surface, so it is what the panel's spare width and height are spent on:
        // steps across, voice rows down. Everything else keeps the size it was designed at.
        GeometryReader { geometry in
            let layout = GridLayout(size: geometry.size,
                                    voices: model.voices.count, steps: model.stepCount)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                levers
                StepGrid(model: model, layout: layout)
                pickers
                if model.groove.patterns.allSatisfy({ $0.steps.allSatisfy { $0 == .rest } }) {
                    HStack(spacing: 16) {
                        ArtImage("empty-grid", width: 150, height: 100)
                        Text("Nothing painted yet. Click a step to start, or pick a feel below and it lays a pocket down to edit.")
                            .font(Design.Typography.ui(12.5, weight: .regular))
                            .foregroundStyle(Design.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let line = model.provenanceLine { ProvenanceLine(text: line) }
                if let error = model.lastError { GridFailureNote(text: error) }
                Spacer(minLength: 0)
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(SurfaceKind.grid.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(model.title)
                .font(Design.Typography.prose(16, weight: .medium))
            Spacer()
            if let kept = model.lastKept, !model.hasUnkeptChanges { KeptNote(version: kept) }
            KeepButton(isEnabled: model.hasUnkeptChanges) { _ = model.commit() }
        }
    }

    // MARK: The two levers

    private var levers: some View {
        HStack(alignment: .top, spacing: 30) {
            SwingLever(model: model)
            GhostLever(model: model)
            Spacer()
        }
    }

    // MARK: Pickers

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                TierBrush(model: model)

                VStack(alignment: .leading, spacing: 3) {
                    GridLabel("Tempo")
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: GridModel.tempoRange)
                            .frame(width: 130)
                            .tint(Design.Palette.accent)
                            .help("The groove's audition tempo: what this grid loops at. The song's own tempo is set from the header.")
                            .accessibilityLabel("Audition tempo")
                        Text("\(Int(model.tempo.rounded())) bpm")
                            .font(Design.Typography.numeric(12))
                            .frame(width: 56, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    GridLabel("Machine")
                    Picker("", selection: Binding(get: { model.machine.id },
                                                  set: { id in
                                                      if let m = SynthMachine.preset(id: id) { model.setMachine(m) }
                                                  })) {
                        ForEach(model.machines) { machine in
                            Text(machine.name).tag(machine.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .font(Design.Typography.ui(12))
                    .help("The kit every step plays on")
                }

                VStack(alignment: .leading, spacing: 3) {
                    GridLabel("Feel")
                    // While a feel waits for the word the picker shows it as chosen, so the menu
                    // and the question under it agree about what is about to happen.
                    Picker("", selection: Binding(get: { model.pendingFeel?.name ?? model.feelName ?? "" },
                                                  set: { name in model.chooseFeel(named: name) })) {
                        Text("—").tag("")
                        ForEach(model.feelLibrary.feels) { feel in
                            Text(feel.name).tag(feel.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .font(Design.Typography.ui(12))
                    .help("A pocket from the library: its pattern, swing, velocities and tempo. Asks first when steps are painted; — puts back what was there before the last feel.")
                }

                ClearControl(model: model)

                Spacer()
            }
            feelNote
        }
    }

    /// What the feel picker is about to do, or what it just did: the question a staged feel is
    /// waiting on, or the way back from the last one loaded.
    @ViewBuilder
    private var feelNote: some View {
        if let feel = model.pendingFeel {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Design.Palette.warn)
                Text("Load \(feel.name)? It replaces what is painted, and the swing, velocities and tempo with it.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                GridChip("Replace what is painted", emphasis: .warn) { model.confirmPendingFeel() }
                    .help("Load \(feel.name) over the pattern that is here")
                GridChip("Keep mine") { model.cancelPendingFeel() }
                    .help("Leave the pattern as it is")
            }
        } else if model.canRestore {
            HStack(spacing: 10) {
                Text("\(model.feelName ?? "The feel") replaced what was painted.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                GridChip("Put back what was there") { model.restoreBeforeFeel() }
                    .help("The pattern, levers and tempo as they stood before the last feel was loaded. Drops what is painted now.")
            }
        }
    }
}

// MARK: - Clearing

/// Clear everything, as two presses: the first arms, the second does it, and Keep disarms. A whole
/// pattern is too much to lose to one click beside the feel picker.
private struct ClearControl: View {
    @Bindable var model: GridModel
    @State private var isArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Clear")
            HStack(spacing: 4) {
                if isArmed {
                    GridChip("Clear every row", emphasis: .warn) {
                        model.clearAll()
                        isArmed = false
                    }
                    .help("Every step becomes a rest. Swing, velocities, machine and tempo stay.")
                    GridChip("Keep") { isArmed = false }
                        .help("Leave the pattern as it is")
                } else {
                    GridChip("Clear all") { isArmed = true }
                        .help(model.isPainted ? "Asks once, then clears every row" : "Nothing painted to clear")
                        .disabled(!model.isPainted)
                        .opacity(model.isPainted ? 1 : 0.4)
                }
            }
        }
        // Nothing left to clear — a restore or a feel emptied it — and the question is moot.
        .onChange(of: model.isPainted) { _, painted in if !painted { isArmed = false } }
    }
}

/// The surface's own chip, as every surface has one: a lever you press, lit when it is on, in the
/// warn colour when it is the destructive half of a two-step.
private struct GridChip: View {
    enum Emphasis { case plain, warn }

    let title: String
    var isOn = false
    var emphasis: Emphasis = .plain
    let action: () -> Void

    init(_ title: String, isOn: Bool = false, emphasis: Emphasis = .plain, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.emphasis = emphasis
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn || emphasis == .warn ? .semibold : .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(background, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(border, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch emphasis {
        case .warn: return Design.Palette.warn
        case .plain: return isOn ? Design.Palette.accent : Design.Palette.inkSecondary
        }
    }

    private var background: Color {
        switch emphasis {
        case .warn: return Design.Palette.warnSoft
        case .plain: return isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt
        }
    }

    private var border: Color {
        switch emphasis {
        case .warn: return Design.Palette.warn.opacity(0.35)
        case .plain: return isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line
        }
    }
}

// MARK: - Levers

private struct SwingLever: View {
    @Bindable var model: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GridLabel("Swing")
            HStack(spacing: 10) {
                Slider(value: Binding(get: { model.swingPercent }, set: { model.setSwing(percent: $0) }),
                       in: GridModel.straightPercent...GridModel.maximumPercent)
                    .frame(width: 220)
                // The figure every machine quotes. 50 straight, 66.67 triplet, 75 the maximum.
                Text(String(format: "%.4g%%", model.swingPercent))
                    .font(Design.Typography.numeric(14))
                    .frame(width: 58, alignment: .leading)
            }
            HStack(spacing: 8) {
                DetentButton(title: "straight") { model.snapSwingToStraight() }
                DetentButton(title: "triplet") { model.snapSwingToTriplet() }
                Text(String(format: "factor %.3f", model.swing.factor))
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }
}

private struct GhostLever: View {
    @Bindable var model: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GridLabel("Ghost level")
            HStack(spacing: 10) {
                Slider(value: Binding(get: { model.ghostLevel }, set: { model.setGhostLevel($0) }), in: 0...1)
                    .frame(width: 180)
                Text("\(model.velocities.ghost)")
                    .font(Design.Typography.numeric(14))
                    .frame(width: 34, alignment: .leading)
            }
            Text("ghost \(model.velocities.ghost) · normal \(model.velocities.normal) · accent \(model.velocities.accent)")
                .font(Design.Typography.numeric(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

private struct DetentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(10.5, weight: .regular))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Design.Palette.panelAlt)
                .foregroundStyle(Design.Palette.inkSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tier brush

private struct TierBrush: View {
    @Bindable var model: GridModel

    private static let tiers: [VelocityTier] = [.accent, .normal, .ghost]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Brush")
            HStack(spacing: 4) {
                ForEach(TierBrush.tiers, id: \.self) { tier in
                    Button { model.brush = tier } label: {
                        Text(tier.rawValue)
                            .font(Design.Typography.ui(11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(model.brush == tier ? Design.Palette.accent : Design.Palette.panelAlt)
                            .foregroundStyle(model.brush == tier ? Design.Palette.panel : Design.Palette.inkSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    }
                    .buttonStyle(.plain)
                    .help("Clicks and drags paint \(tier.rawValue) hits")
                    .accessibilityLabel("\(tier.rawValue) brush")
                    .accessibilityAddTraits(model.brush == tier ? .isSelected : [])
                }
            }
            // The gestures, since none of them is labelled on the grid itself.
            Text("Click a step to paint it with the brush; click again for a rest. ⌥-click walks normal → accent → ghost → rest; drag to paint a run.")
                .font(Design.Typography.ui(10.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The grid

private struct StepGrid: View {
    @Bindable var model: GridModel
    let layout: GridLayout

    var body: some View {
        ScrollView(.vertical, showsIndicators: layout.gridScrolls) {
            VStack(alignment: .leading, spacing: GridLayout.rowSpacing) {
                ruler
                ForEach(model.voices, id: \.rawValue) { voice in
                    GridRowView(model: model, voice: voice,
                                rowHeight: layout.rowHeight, labelWidth: layout.labelWidth)
                }
            }
        }
        // The rows only scroll at the window minimum, where five voices at a legible height do not
        // fit under the levers. At the default window they simply fill the panel.
        .scrollDisabled(!layout.gridScrolls)
        .frame(height: layout.gridAreaHeight)
    }

    private var ruler: some View {
        HStack(spacing: GridLayout.stepSpacing) {
            Color.clear.frame(width: layout.labelWidth, height: GridLayout.rulerHeight)
            ForEach(Array(0..<model.stepCount), id: \.self) { step in
                Text(step % model.stepsPerBeat == 0 ? "\(step / model.stepsPerBeat + 1)" : "")
                    .font(Design.Typography.numeric(9))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(maxWidth: .infinity, minHeight: GridLayout.rulerHeight)
            }
        }
    }
}

/// One voice's row. A tap paints the brush tier (⌥-tap walks the tiers instead); a drag paints or
/// erases the run it crosses, which is the same gesture every machine with a step grid has had
/// since the MPC60.
private struct GridRowView: View {
    @Bindable var model: GridModel
    let voice: DrumVoice
    let rowHeight: CGFloat
    let labelWidth: CGFloat

    @State private var isPainting = false

    var body: some View {
        HStack(spacing: GridLayout.stepSpacing) {
            Button { model.audition(voice) } label: {
                Text(voice.rawValue)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    .foregroundStyle(Design.Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Hear the \(voice.rawValue) at the brush's velocity. Right-click to clear the row.")
            .accessibilityLabel("Hear the \(voice.rawValue)")
            .contextMenu {
                Button("Clear the \(voice.rawValue) row") { model.clear(voice) }
            }

            GeometryReader { geometry in
                HStack(spacing: GridLayout.stepSpacing) {
                    ForEach(Array(0..<model.stepCount), id: \.self) { step in
                        StepCellView(cell: model.cell(voice, step: step),
                                     isBeat: step % model.stepsPerBeat == 0,
                                     isSwung: model.isSwung(step: step),
                                     height: rowHeight)
                            .onTapGesture {
                                // A plain click paints what the brush says; ⌥ walks the tiers,
                                // which is what a bare click used to do.
                                if NSEvent.modifierFlags.contains(.option) {
                                    model.cycle(voice, step: step)
                                } else {
                                    model.toggle(voice, step: step)
                                }
                            }
                            .help("\(voice.rawValue) step \(step + 1): \(model.tier(voice, step: step).rawValue)")
                    }
                }
                .contentShape(Rectangle())
                .gesture(paintGesture(width: geometry.size.width))
            }
            .frame(height: rowHeight)
        }
    }

    private func paintGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let step = stepIndex(atX: value.location.x, width: width) else { return }
                if isPainting {
                    model.continuePaint(voice, step: step)
                } else {
                    // The first cell of the drag decides paint or erase for the whole gesture.
                    let origin = stepIndex(atX: value.startLocation.x, width: width) ?? step
                    model.beginPaint(voice, step: origin)
                    isPainting = true
                    if step != origin { model.continuePaint(voice, step: step) }
                }
            }
            .onEnded { _ in
                model.endPaint()
                isPainting = false
            }
    }

    /// The cells share the row's width equally, so the index under a point is arithmetic.
    private func stepIndex(atX x: CGFloat, width: CGFloat) -> Int? {
        let count = model.stepCount
        guard count > 0, width > 0 else { return nil }
        let index = Int((x / width) * CGFloat(count))
        guard index >= 0, index < count else { return nil }
        return index
    }
}

private struct StepCellView: View {
    let cell: GridCell
    let isBeat: Bool
    let isSwung: Bool
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Metric.corner)
            .fill(fill)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .strokeBorder(isBeat ? Design.Palette.lineStrong : Design.Palette.line,
                                  lineWidth: Design.Metric.hairline)
            )
            .overlay(alignment: .bottom) {
                // Swung steps carry a mark, so the lever's effect is visible on the grid and not
                // only in the number beside it.
                if isSwung && cell.tier != .rest {
                    Rectangle()
                        .fill(Design.Palette.accent.opacity(0.8))
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
    }

    /// Each tier reads differently: an accent is solid ink, a normal hit is the accent at two
    /// thirds, a ghost is a whisper. Nothing depends on colour alone.
    private var fill: Color {
        switch cell.tier {
        case .rest: return isBeat ? Design.Palette.panelAlt : Design.Palette.panel
        case .ghost: return Design.Palette.accent.opacity(0.22)
        case .normal: return Design.Palette.accent.opacity(0.62)
        case .accent: return Design.Palette.accent
        }
    }
}

// MARK: - Small pieces

private struct GridLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(Design.Palette.inkTertiary)
    }
}

private struct ProvenanceLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.prose(13))
            .foregroundStyle(Design.Palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GridFailureNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.ui(12, weight: .regular))
            .foregroundStyle(Design.Palette.warn)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Palette.warnSoft)
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}
