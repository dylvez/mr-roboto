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
                        Text("Nothing painted yet. Click a step to start, or pick a feel above and it lays a pocket down to edit.")
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
            Button("Commit") { _ = model.commit() }
                .font(Design.Typography.ui(12))
                .buttonStyle(.plain)
                .foregroundStyle(Design.Palette.accent)
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
        HStack(spacing: 18) {
            TierBrush(model: model)

            VStack(alignment: .leading, spacing: 3) {
                GridLabel("Tempo")
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: 60...180)
                        .frame(width: 130)
                    Text(String(format: "%.0f", model.tempo))
                        .font(Design.Typography.numeric(12))
                        .frame(width: 30, alignment: .trailing)
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
            }

            VStack(alignment: .leading, spacing: 3) {
                GridLabel("Feel")
                Picker("", selection: Binding(get: { model.feelName ?? "" },
                                              set: { name in _ = model.loadFeel(named: name) })) {
                    Text("—").tag("")
                    ForEach(model.feelLibrary.feels) { feel in
                        Text(feel.name).tag(feel.name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .font(Design.Typography.ui(12))
            }

            Spacer()
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
                }
            }
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

/// One voice's row. A tap walks the cell's tier; a drag paints or erases the run it crosses,
/// which is the same gesture every machine with a step grid has had since the MPC60.
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

            GeometryReader { geometry in
                HStack(spacing: GridLayout.stepSpacing) {
                    ForEach(Array(0..<model.stepCount), id: \.self) { step in
                        StepCellView(cell: model.cell(voice, step: step),
                                     isBeat: step % model.stepsPerBeat == 0,
                                     isSwung: model.isSwung(step: step),
                                     height: rowHeight)
                            .onTapGesture { model.cycle(voice, step: step) }
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
