import Performance
import SwiftUI

/// The Chop lane, drawn.
///
/// Reading order down the panel: the bar, the pads, the two levers, then everything else. The
/// waveform and the pad grid are the surface; the levers are the controls; the inspector is the
/// small print. Nothing here holds state that is not in the model — the view is a projection.
public struct ChopLaneView: View {
    @Bindable var surface: ChopLaneSurface

    public init(surface: ChopLaneSurface) {
        self.surface = surface
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            ChopLanePlate(surface: surface)
                .frame(minHeight: 168)
            ChopLanePads(surface: surface)
            levers
            ChopLaneInspector(surface: surface)
            if let error = surface.lastError {
                Text(error)
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.warn)
            }
        }
        .padding(Design.Metric.inset)
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ChopLaneSurface.kind.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(surface.headline)
                .font(Design.Typography.prose(15.5))
                .foregroundStyle(Design.Palette.ink)
            Spacer()
            Button("Play bar") { surface.auditionBar() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.accent)
            Button("Stop") { surface.stop() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
    }

    // MARK: The two levers
    //
    // The catalog's rule: at most two prominent at once. Sensitivity and feel. The tempo sits
    // under the feel because it is the feel's argument, not a lever of its own.

    private var levers: some View {
        HStack(alignment: .top, spacing: Design.Metric.gutter) {
            sensitivityLever
            feelLever
        }
    }

    private var sensitivityLever: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("SENSITIVITY")
                    .font(Design.Typography.label)
                    .tracking(0.8)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                Text("\(surface.sliceCount) slices")
                    .font(Design.Typography.numeric(12))
                    .foregroundStyle(Design.Palette.accent)
                Text("δ \(surface.onsetThreshold, format: .number.precision(.fractionLength(1)))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            Slider(value: $surface.sensitivity, in: 0...1)
                .controlSize(.small)
                .tint(Design.Palette.accent)
            Text(surface.handEdited
                 ? "Moving this re-slices the bar and drops your marker edits."
                 : "Higher finds more slices, ghost notes included.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(surface.handEdited
                                 ? Design.Palette.warn : Design.Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var feelLever: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RE-GROOVE")
                    .font(Design.Typography.label)
                    .tracking(0.8)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                Text("\(Int(surface.tempo.rounded())) bpm")
                    .font(Design.Typography.numeric(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            HStack(spacing: 8) {
                Picker("", selection: $surface.feelName) {
                    Text("as cut").tag(String?.none)
                    ForEach(surface.suggestedFeels) { feel in
                        Text(feel.name).tag(String?.some(feel.name))
                    }
                }
                .labelsHidden()
                .font(Design.Typography.ui(12))
                Button("Play") { surface.playRegroove() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(surface.feel == nil
                                     ? Design.Palette.inkTertiary : Design.Palette.accent)
                    .disabled(surface.feel == nil)
            }
            Slider(value: $surface.tempo, in: 60...180, step: 1)
                .controlSize(.small)
                .tint(Design.Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The plate

/// The waveform of the bar on the Design palette's dark plate, with the slice markers on it.
///
/// A marker is dragged with a press-and-move on the plate; the nearest marker to where the press
/// started is the one that moves. While it is moving the plate says two things at once: a dim tick
/// where the pointer actually is, and the bright marker where it will land. That difference *is*
/// the snap, made visible rather than merely felt, and the label beside it names what it caught —
/// "onset", or a grid position like "2e".
struct ChopLanePlate: View {
    @Bindable var surface: ChopLaneSurface

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let duration = max(1e-9, surface.source.duration)
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize, duration: duration)
                }
                snapReadout(size: size, duration: duration)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = ChopLaneWaveform.time(atX: value.startLocation.x,
                                                         width: size.width, duration: duration)
                        if surface.drag == nil, let nearest = nearestSlice(to: time) {
                            surface.beginDrag(slice: nearest)
                        }
                        surface.dragMarker(to: ChopLaneWaveform.time(atX: value.location.x,
                                                                     width: size.width,
                                                                     duration: duration))
                    }
                    .onEnded { _ in surface.endDrag() }
            )
        }
        .background(Design.Palette.plate)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private func nearestSlice(to time: Double) -> Int? {
        surface.chop.slices
            .min { abs($0.startSeconds - time) < abs($1.startSeconds - time) }?
            .index
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, duration: Double) {
        let buckets = max(1, Int(size.width))
        let columns = ChopLaneWaveform.envelope(surface.source.mono, buckets: buckets)
        let middle = size.height / 2

        // Grid lines first, behind everything: they are reference, not content.
        for line in surface.gridLines {
            let x = ChopLaneWaveform.x(atTime: line, width: size.width, duration: duration)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
                                  $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Design.Palette.lineStrong.opacity(0.18)),
                           lineWidth: Design.Metric.hairline)
        }

        var wave = Path()
        for (index, column) in columns.enumerated() {
            let x = Double(index) + 0.5
            let top = middle - middle * 0.9 * Double(column.maximum)
            let bottom = middle - middle * 0.9 * Double(column.minimum)
            wave.move(to: CGPoint(x: x, y: top))
            wave.addLine(to: CGPoint(x: x, y: max(bottom, top + 0.5)))
        }
        context.stroke(wave, with: .color(Design.Palette.trace), lineWidth: 1)

        // Slice markers.
        for slice in surface.chop.slices {
            let x = ChopLaneWaveform.x(atTime: slice.startSeconds,
                                       width: size.width, duration: duration)
            let selected = surface.selectedSlice == slice.index
            let colour = selected ? Design.Palette.accent : Design.Palette.trace.opacity(0.75)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
                                  $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(colour), lineWidth: selected ? 2 : 1)
            context.draw(Text("\(slice.index)")
                            .font(Design.Typography.numeric(9))
                            .foregroundColor(colour),
                         at: CGPoint(x: x + 7, y: 9), anchor: .leading)
        }

        // The drag: where the pointer is, and where the marker will land.
        if let drag = surface.drag {
            let freeX = ChopLaneWaveform.x(atTime: drag.free, width: size.width, duration: duration)
            context.stroke(Path { $0.move(to: CGPoint(x: freeX, y: 0))
                                  $0.addLine(to: CGPoint(x: freeX, y: size.height)) },
                           with: .color(Design.Palette.trace.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let landedX = ChopLaneWaveform.x(atTime: drag.time,
                                             width: size.width, duration: duration)
            context.stroke(Path { $0.move(to: CGPoint(x: landedX, y: 0))
                                  $0.addLine(to: CGPoint(x: landedX, y: size.height)) },
                           with: .color(Design.Palette.accent), lineWidth: 2)
            if drag.isSnapped {
                // A filled cap on the snapped marker: the same shape the free tick does not have.
                context.fill(Path(ellipseIn: CGRect(x: landedX - 3.5, y: size.height - 11,
                                                    width: 7, height: 7)),
                             with: .color(Design.Palette.accent))
            }
        }

        // Gate B's critic marks. Nothing in Gate A puts one here.
        for mark in surface.marks {
            let from = ChopLaneWaveform.x(atTime: mark.start, width: size.width, duration: duration)
            let to = max(from + 2, ChopLaneWaveform.x(atTime: mark.end,
                                                      width: size.width, duration: duration))
            context.fill(Path(CGRect(x: from, y: size.height - 4, width: to - from, height: 4)),
                         with: .color(Design.Palette.warn))
        }
    }

    // MARK: What it snapped to

    @ViewBuilder
    private func snapReadout(size: CGSize, duration: Double) -> some View {
        if let drag = surface.drag {
            let x = ChopLaneWaveform.x(atTime: drag.time, width: size.width, duration: duration)
            HStack(spacing: 4) {
                Text(drag.snapped.map { $0.kind == .onset ? "onset" : "grid" } ?? "free")
                    .font(Design.Typography.label)
                    .tracking(0.6)
                if let snapped = drag.snapped {
                    Text(snapped.label)
                        .font(Design.Typography.numeric(10))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(drag.isSnapped ? Design.Palette.accent : Design.Palette.plate.opacity(0.8))
            .foregroundStyle(drag.isSnapped ? Design.Palette.paper : Design.Palette.inkTertiary)
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .offset(x: min(max(0, x + 6), max(0, size.width - 84)), y: 24)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - The pads

/// Which slice is on which pad, what it was called, and how sure the classifier was.
///
/// Touching a pad plays it. That is the whole interaction, and it is why the kit is refreshed on
/// edits rather than on touches.
struct ChopLanePads: View {
    @Bindable var surface: ChopLaneSurface

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(surface.chop.slices) { slice in
                pad(for: slice.index)
            }
        }
    }

    private func pad(for index: Int) -> some View {
        let classification = surface.classification(forSlice: index)
        let selected = surface.selectedSlice == index
        let edit = surface.edit(forSlice: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(index)")
                    .font(Design.Typography.numeric(10))
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                if !edit.isNeutral {
                    Text(trimSummary(edit))
                        .font(Design.Typography.numeric(9))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
            }
            Text(classification?.kind.rawValue ?? "—")
                .font(Design.Typography.ui(13, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
            confidence(classification)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Design.Palette.accentSoft : Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(selected ? Design.Palette.accent : Design.Palette.line,
                        lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .contentShape(Rectangle())
        .onTapGesture { surface.audition(slice: index) }
        .contextMenu {
            // The override. The classifier is wrong sometimes by design, so the correction is one
            // gesture away from the thing being corrected.
            ForEach(SliceClass.allCases, id: \.rawValue) { kind in
                Button(kind.rawValue) { surface.override(slice: index, as: kind) }
            }
            if surface.overrides[index] != nil {
                Divider()
                Button("Back to the classifier") { surface.clearOverride(slice: index) }
            }
            Divider()
            Button("Delete marker") { surface.removeMarker(slice: index) }
        }
    }

    private func trimSummary(_ edit: ChopLaneSurface.SliceEdit) -> String {
        var parts: [String] = []
        if edit.tuneCents != 0 { parts.append("\(Int(edit.tuneCents))¢") }
        if edit.gainDB != 0 { parts.append(String(format: "%+.0f dB", edit.gainDB)) }
        if edit.reverse { parts.append("rev") }
        if let ratio = edit.stretchRatio { parts.append(String(format: "×%.2f", ratio)) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func confidence(_ classification: SliceClassification?) -> some View {
        let value = classification?.confidence ?? 0
        let overridden = classification?.isOverride ?? false
        HStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Design.Palette.line)
                    Rectangle()
                        .fill(overridden ? Design.Palette.ink : Design.Palette.accent)
                        .frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 2)
            Text(overridden ? "yours" : "\(Int((value * 100).rounded()))%")
                .font(Design.Typography.numeric(9))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

// MARK: - The small print

/// Per-slice pitch, gain, reverse and stretch, plus the re-groove's overflow rule. Secondary by
/// construction: one selected slice at a time, and nothing here competes with the two levers.
struct ChopLaneInspector: View {
    @Bindable var surface: ChopLaneSurface

    private static let tuneRange = -2400.0...2400.0
    private static let gainRange = -24.0...12.0

    var body: some View {
        Group {
            if let index = surface.selectedSlice, surface.chop.slices.indices.contains(index) {
                controls(for: index)
            } else {
                Text("Touch a pad to hear it and to edit it.")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .frame(height: 26, alignment: .leading)
    }

    private func controls(for index: Int) -> some View {
        HStack(spacing: 12) {
            Text("SLICE \(index)")
                .font(Design.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Design.Palette.inkTertiary)
            slider("pitch", binding: tuneBinding(index), range: Self.tuneRange)
            slider("gain", binding: gainBinding(index), range: Self.gainRange)
            slider("stretch", binding: stretchBinding(index),
                   range: ChopLaneSurface.stretchRange)
            Toggle("reverse", isOn: reverseBinding(index))
                .toggleStyle(.checkbox)
                .font(Design.Typography.ui(11))
            plainButton("reset", tint: Design.Palette.inkSecondary) {
                surface.resetSlice(index)
            }
            Spacer()
            plainButton("audition", tint: Design.Palette.accent) {
                surface.audition(slice: index)
            }
        }
    }

    private func reverseBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { surface.edit(forSlice: index).reverse },
                set: { surface.setReverse($0, slice: index) })
    }

    private func tuneBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { Double(surface.edit(forSlice: index).tuneCents) },
                set: { surface.setTune(Float($0), slice: index) })
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { Double(surface.edit(forSlice: index).gainDB) },
                set: { surface.setGain(Float($0), slice: index) })
    }

    private func stretchBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { surface.edit(forSlice: index).stretchRatio ?? 1 },
                set: { surface.setStretch($0 == 1 ? nil : $0, slice: index) })
    }

    private func slider(_ name: String, binding: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Design.Typography.ui(11))
                .foregroundStyle(Design.Palette.inkSecondary)
            Slider(value: binding, in: range)
                .controlSize(.mini)
                .frame(width: 92)
        }
    }

    private func plainButton(_ name: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(name, action: action)
            .buttonStyle(.plain)
            .font(Design.Typography.ui(11))
            .foregroundStyle(tint)
    }
}
