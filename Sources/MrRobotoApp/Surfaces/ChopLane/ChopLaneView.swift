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
        // The lane is laid out against the room it is actually handed rather than against its own
        // content: the plate takes the height the pads do not need, and the pad grid's column count
        // comes from the real width. `ChopLaneLayout` is the whole decision, as a value.
        GeometryReader { geometry in
            let layout = ChopLaneLayout(size: geometry.size, sliceCount: surface.sliceCount)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                // The caption is drawn inside the plate's budgeted height rather than as a row of
                // its own: the layout's chrome sum is pinned by its tests, and a line of small
                // print is not worth a shorter pad bank.
                VStack(alignment: .leading, spacing: 4) {
                    ChopLanePlate(surface: surface)
                    plateCaption
                }
                .frame(height: layout.plateHeight)
                ChopLanePads(surface: surface, layout: layout)
                levers
                ChopLaneInspector(surface: surface)
                if let error = surface.lastError {
                    Text(error)
                        .font(Design.Typography.ui(11))
                        .foregroundStyle(Design.Palette.warn)
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        // The card above names the lane and the bar, and the sensitivity row counts the slices: this
        // row is the lane's own controls, not a second title. The bar as cut plays from the card's
        // "Play this bar, chopped"; a second button here that did the same under another name was
        // one of three play buttons with three names.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            levelControl
            Spacer()
            Button("Stop") { surface.stop() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .help("Stop whatever this lane is playing: the bar, a pad, or the re-groove")
            // The chop keeps itself a moment after the last edit, like every surface.
            surface.statusBar
                .fixedSize()
        }
    }

    /// The chop's level: what it plays at over its recording, with the way back; or, for a quiet
    /// bar that plays as recorded, the one press that brings it up. Nothing for a bar that is loud
    /// enough as it is, which is nearly every bar of a mastered record.
    @ViewBuilder
    private var levelControl: some View {
        if let gain = surface.level.gainDB {
            Text("LEVEL")
                .font(Design.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(String(format: "%+.1f dB", gain))
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.accent)
                .help("The bar plays this much louder than it was recorded: its pads here, its loop and a groove on its slices in the song.")
            Button("As recorded") { surface.playAsRecorded() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .help("Play the bar at its recording's own level again. A new version of the chop; the mix does not move.")
        } else if let asks = surface.level.asks {
            Text("LEVEL")
                .font(Design.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text("quiet as recorded")
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Button(String(format: "Level it %+.1f dB", asks)) { surface.levelBar() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
                .help("Bring the bar up to where an instrument sits, at the chop: its pads here, its loop and a groove on its slices in the song. A new version of the chop; the mix does not move.")
        }
    }

    /// How the plate is worked, said once under it. Everything named here exists: there is no
    /// keyboard delete, so the line does not claim one.
    private var plateCaption: some View {
        Text("Drag a marker to move it · double-click the bar to add one · a pad's … menu deletes one · Esc cancels a drag")
            .font(Design.Typography.ui(11))
            .foregroundStyle(Design.Palette.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
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
                // The detector's threshold is a number to repeat, not to read: it is in the tooltip.
                    .help("Onset threshold δ \(String(format: "%.1f", surface.onsetThreshold)): lower finds more slices")
            }
            Slider(value: $surface.sensitivity, in: 0...1)
                .controlSize(.small)
                .tint(Design.Palette.accent)
                .help("How finely the bar is cut. Higher finds more onsets; it re-slices as it moves.")
                .accessibilityLabel("Sensitivity")
            // The warning names what the dial would drop — markers, overrides, trims — because
            // `resliceFromDetection` drops all three and a warning about one of them is a lie
            // about the other two.
            Text(surface.resliceWarning ?? "Higher finds more slices, ghost notes included.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(surface.resliceWarning == nil
                                 ? Design.Palette.inkSecondary : Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
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
                .help("Whose rhythm the chop is played in. As cut plays the bar as it was.")
                .accessibilityLabel("Feel")
                Button("Play in this feel") { surface.playRegroove() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(surface.feel == nil
                                     ? Design.Palette.inkTertiary : Design.Palette.accent)
                    .disabled(surface.feel == nil)
                    .help(surface.feel == nil
                          ? "Pick a feel first"
                          : "Hear the chop in this feel at this tempo")
                // Making a groove sits beside Play in this feel on purpose: what is made is what was just heard.
                // It is a button because it is a new part, not an edit to this one.
                Button("Make the groove") { surface.keepRegroove() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .semibold))
                    .foregroundStyle(surface.canKeepRegroove
                                     ? Design.Palette.accent : Design.Palette.inkTertiary)
                    .disabled(!surface.canKeepRegroove)
                    .help(surface.whyRegrooveCannotBeKept
                          ?? "Make a groove that plays these slices in this feel, at the song's tempo, in place of the looped bar. The Grid opens on it.")
            }
            HStack(spacing: 8) {
                Text("Preview tempo")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                Slider(value: $surface.tempo, in: 60...180, step: 1)
                    .controlSize(.small)
                    .tint(Design.Palette.accent)
                    .help("The tempo Play in this feel plays at. The song plays the groove at its own tempo.")
                    .accessibilityLabel("Preview tempo")
            }
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
///
/// A press has to travel `dragThreshold` before it is a drag, so a plain click on the plate moves
/// nothing. A double-click adds a marker where it lands, and Escape lets go of a drag without
/// moving the marker.
struct ChopLanePlate: View {
    @Bindable var surface: ChopLaneSurface

    /// How far the mouse travels before a press is a drag rather than a click.
    static let dragThreshold: CGFloat = 4

    /// Set by Escape mid-drag. The gesture keeps reporting until the mouse goes up, and without
    /// this the next report would quietly begin a fresh drag on the marker that was just let go.
    @State private var dragCancelled = false
    /// Escape reaches the plate only while it has focus, so a drag takes focus as it starts.
    @FocusState private var isFocused: Bool

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
            .onTapGesture(count: 2) { location in
                surface.addMarker(at: ChopLaneWaveform.time(atX: location.x,
                                                            width: size.width, duration: duration))
            }
            .gesture(
                DragGesture(minimumDistance: Self.dragThreshold)
                    .onChanged { value in
                        guard !dragCancelled else { return }
                        let time = ChopLaneWaveform.time(atX: value.startLocation.x,
                                                         width: size.width, duration: duration)
                        if surface.drag == nil, let nearest = nearestSlice(to: time) {
                            isFocused = true
                            surface.beginDrag(slice: nearest)
                        }
                        surface.dragMarker(to: ChopLaneWaveform.time(atX: value.location.x,
                                                                     width: size.width,
                                                                     duration: duration))
                    }
                    .onEnded { _ in
                        if dragCancelled {
                            dragCancelled = false
                        } else {
                            surface.endDrag()
                        }
                    }
            )
        }
        .background(Design.Palette.plate)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onExitCommand {
            guard surface.drag != nil else { return }
            surface.cancelDrag()
            dragCancelled = true
        }
        .accessibilityLabel("The bar's waveform, with a marker at the start of each slice")
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
            // Counted from 1, as a person counts pads; the index stays 0-based underneath.
            context.draw(Text("\(slice.index + 1)")
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
/// edits rather than on touches. The selected pad also carries a small … menu with the things a
/// right-click offers on every pad — the override and the marker's deletion — so neither is a
/// gesture you have to know about.
///
/// The column count is `layout.padColumns`, from the lane's real width, and the pads then share that
/// width exactly. The old `.adaptive(minimum: 104)` was a fixed rule in adaptive clothing: it packed
/// as many 104-point pads as fit and left whatever was over as a ragged gutter, which at 1269 points
/// was a whole pad's worth of nothing.
struct ChopLanePads: View {
    @Bindable var surface: ChopLaneSurface
    let layout: ChopLaneLayout

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: ChopLaneLayout.padSpacing),
              count: max(1, layout.padColumns))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: layout.padsScroll) {
            LazyVGrid(columns: columns, spacing: ChopLaneLayout.padSpacing) {
                ForEach(surface.chop.slices) { slice in
                    pad(for: slice.index)
                }
            }
        }
        // Only the pads scroll, and only when the slices genuinely do not fit — at the window
        // minimum with sixteen of them. Everywhere else this is an ordinary block.
        .scrollDisabled(!layout.padsScroll)
        .frame(height: layout.padAreaHeight)
    }

    private func pad(for index: Int) -> some View {
        let classification = surface.classification(forSlice: index)
        let selected = surface.selectedSlice == index
        let edit = surface.edit(forSlice: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .font(Design.Typography.numeric(10))
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                if !edit.isNeutral {
                    Text(trimSummary(edit))
                        .font(Design.Typography.numeric(9))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                if selected {
                    padMenu(for: index)
                }
            }
            Text(classification?.kind.rawValue ?? "—")
                .font(Design.Typography.ui(13, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
            // A taller pad puts the air between the name and the confidence bar rather than under
            // the bar: the bar stays on the pad's floor, where it reads as a level.
            Spacer(minLength: 0)
            confidence(classification)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: layout.padHeight, alignment: .topLeading)
        .background(selected ? Design.Palette.accentSoft : Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(selected ? Design.Palette.accent : Design.Palette.line,
                        lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .contentShape(Rectangle())
        .onTapGesture { surface.audition(slice: index) }
        .help("Play slice \(index + 1). Right-click to call it something else or to delete its marker.")
        .contextMenu { padMenuItems(for: index) }
    }

    /// The … on the selected pad: the context menu, visible.
    private func padMenu(for index: Int) -> some View {
        Menu {
            padMenuItems(for: index)
        } label: {
            Image(systemName: "ellipsis")
                .font(Design.Typography.ui(11, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Call slice \(index + 1) something else, give it back to the classifier, or delete its marker")
        .accessibilityLabel("Slice \(index + 1) options")
    }

    /// The override and the marker's deletion. One list, reached two ways.
    @ViewBuilder
    private func padMenuItems(for index: Int) -> some View {
        // The override. The classifier is wrong sometimes by design, so the correction is one
        // gesture away from the thing being corrected.
        ForEach(SliceClass.allCases, id: \.rawValue) { kind in
            Button(kind.rawValue) { surface.override(slice: index, as: kind) }
                .help("Call slice \(index + 1) a \(kind.rawValue), whatever the classifier heard")
        }
        if surface.overrides[index] != nil {
            Divider()
            Button("Back to the classifier") { surface.clearOverride(slice: index) }
                .help("Drop the override and let the classifier name slice \(index + 1) again")
        }
        Divider()
        Button("Delete marker") { surface.removeMarker(slice: index) }
            .help("Remove the marker that starts slice \(index + 1); its audio joins the slice before it")
    }

    private func trimSummary(_ edit: ChopLaneSurface.SliceEdit) -> String {
        var parts: [String] = []
        if edit.tuneCents != 0 { parts.append(ChopLaneReadout.pitch(edit.tuneCents)) }
        if edit.gainDB != 0 { parts.append(ChopLaneReadout.gain(edit.gainDB)) }
        if edit.reverse { parts.append("rev") }
        if edit.stretchRatio != nil { parts.append(ChopLaneReadout.stretch(edit.stretchRatio)) }
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
///
/// Each slider has its value written beside it, with its unit, because a slider with no readout
/// is a slider you cannot repeat. Double-clicking the readout puts that one control back where it
/// started; "reset" puts the whole slice back.
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
        .frame(height: ChopLaneLayout.inspectorHeight, alignment: .leading)
    }

    private func controls(for index: Int) -> some View {
        let edit = surface.edit(forSlice: index)
        return HStack(spacing: 12) {
            Text("SLICE \(index)")
                .font(Design.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Design.Palette.inkTertiary)
            slider("pitch", binding: tuneBinding(index), range: Self.tuneRange,
                   readout: ChopLaneReadout.pitch(edit.tuneCents),
                   isNeutral: edit.tuneCents == 0,
                   help: "Pitch, in cents. Double-click the value to put it back to 0¢.") {
                surface.setTune(0, slice: index)
            }
            slider("gain", binding: gainBinding(index), range: Self.gainRange,
                   readout: ChopLaneReadout.gain(edit.gainDB),
                   isNeutral: edit.gainDB == 0,
                   help: "Gain, in decibels. Double-click the value to put it back to 0 dB.") {
                surface.setGain(0, slice: index)
            }
            slider("stretch", binding: stretchBinding(index), range: ChopLaneSurface.stretchRange,
                   readout: ChopLaneReadout.stretch(edit.stretchRatio),
                   isNeutral: edit.stretchRatio == nil,
                   help: "Output length over input length. Double-click the value to play the slice at its natural length.") {
                surface.setStretch(nil, slice: index)
            }
            Toggle("reverse", isOn: reverseBinding(index))
                .toggleStyle(.checkbox)
                .font(Design.Typography.ui(11))
                .help("Play the slice backwards")
            plainButton("reset", tint: Design.Palette.inkSecondary) {
                surface.resetSlice(index)
            }
            .help("Put every trim on this slice back where it started")
            Spacer()
            plainButton("audition", tint: Design.Palette.accent) {
                surface.audition(slice: index)
            }
            .help("Play this slice")
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

    private func slider(_ name: String, binding: Binding<Double>, range: ClosedRange<Double>,
                        readout: String, isNeutral: Bool, help: String,
                        reset: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Design.Typography.ui(11))
                .foregroundStyle(Design.Palette.inkSecondary)
            Slider(value: binding, in: range)
                .controlSize(.mini)
                .frame(minWidth: 64, maxWidth: 92)
                .tint(Design.Palette.accent)
                .help(help)
                .accessibilityLabel(name)
            // A fixed width so the row does not breathe as the number changes length.
            Text(readout)
                .font(Design.Typography.numeric(10))
                .foregroundStyle(isNeutral ? Design.Palette.inkTertiary : Design.Palette.ink)
                .lineLimit(1)
                .frame(width: 50, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: reset)
                .help(help)
                .accessibilityLabel("\(name) \(readout)")
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

// MARK: - Readouts

/// The numbers beside the inspector's sliders, and on a pad's trim summary, spelled one way.
///
/// Pure, so the wording is checkable without a view: a sign on anything that is not zero, the
/// unit on everything, and one decimal on gain because a dB is coarse enough to want one.
enum ChopLaneReadout {
    /// "+120¢", "-1200¢", "0¢".
    static func pitch(_ cents: Float) -> String {
        let whole = Int(cents.rounded())
        return whole == 0 ? "0¢" : String(format: "%+d¢", whole)
    }

    /// "+3.5 dB", "-6.0 dB", "0.0 dB".
    static func gain(_ dB: Float) -> String {
        let tenths = (dB * 10).rounded() / 10
        return tenths == 0 ? "0.0 dB" : String(format: "%+.1f dB", tenths)
    }

    /// "×1.50"; nil is the natural length, "×1.00".
    static func stretch(_ ratio: Double?) -> String {
        String(format: "×%.2f", ratio ?? 1)
    }
}
