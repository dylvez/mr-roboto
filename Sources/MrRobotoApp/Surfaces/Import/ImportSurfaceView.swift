import SongGraph
import SwiftUI
import UniformTypeIdentifiers

/// The Import surface: a drop target that turns into a described record.
///
/// Every colour, face and measurement comes from `Design`. The surface keeps to the catalog's rule
/// of at most two prominent levers: **Separate stems** and **Promote region** are the two; the
/// clearance fields, the stem lanes and the readings are all quiet furniture around them.
public struct ImportSurfaceView: View {
    @Bindable public var model: ImportModel

    public init(model: ImportModel) {
        self.model = model
    }

    public var body: some View {
        // The layout is computed from the panel, not from inside the scroll view: the content below
        // is scrollable, so its own height is unbounded and could never tell the waveform or the
        // stem lanes how much room the record actually has.
        GeometryReader { geometry in
            let layout = ImportLayout(size: geometry.size,
                                      sectionLanes: model.instruments.count + 1)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                switch model.state {
                case .empty, .cancelled, .failed:
                    DropWell(model: model, layout: layout)
                default:
                    content(layout)
                }
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The card above names the surface and the record.
            Spacer()
            if model.state.isBusy {
                ImportProgressStrip(progress: model.progress,
                                    canCancel: model.state.isCancellable,
                                    cancel: { model.cancel() })
            }
        }
    }

    // MARK: Body

    private func content(_ layout: ImportLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                WaveformPanel(model: model, layout: layout)
                ReadingsRow(model: model)
                if !model.sections.isEmpty { SectionsStrip(model: model, layout: layout) }
                PromoteBar(model: model)
                StemLanesPanel(model: model, layout: layout)
                ProvenancePanel(model: model)
                if let error = model.lastError { FailureNote(text: error) }
            }
        }
    }
}

// MARK: - Drop well

private struct DropWell: View {
    @Bindable var model: ImportModel
    let layout: ImportLayout
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            ArtImage("empty-drop-record", width: 240, height: 160)
            Text("Drop a record here, or choose one")
                .font(Design.Typography.prose(17))
                .foregroundStyle(Design.Palette.ink)
            Text("An audio file becomes a song package: key, tempo, bars, sections and a take.")
                .font(Design.Typography.ui(12.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .multilineTextAlignment(.center)
            // ⌘I, the same key File ▸ Import Record answers to, so the two ways in agree.
            Button("Choose a File…") {
                if let url = FilePanels.chooseAudio() { model.drop(url) }
            }
            .font(Design.Typography.ui(12.5))
            .keyboardShortcut("i", modifiers: .command)
            .help("Choose an audio file to import (⌘I)")
            // The toggle sits where the drop happens: it arms separation for the file about to be
            // dropped, and a switch you cannot reach until the drop is over is not a switch.
            ImportToggleChip("Separate stems", isOn: $model.separatesStems,
                             help: "Also split the dropped record into drums, bass, vocals and other. About twelve seconds more.")
            if case .cancelled = model.state {
                Text("Cancelled. Nothing was written.")
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            if case .failed(let reason) = model.state {
                Text(reason)
                    .font(Design.Typography.ui(12))
                    .foregroundStyle(Design.Palette.warn)
                    .multilineTextAlignment(.center)
            }
        }
        // The well is the panel when there is nothing else in it: a 220-point box floating at the
        // top of 665 points of bench reads as a surface that failed to load, not as a drop target.
        .frame(maxWidth: .infinity, minHeight: layout.dropWellHeight)
        .padding(Design.Metric.inset)
        .background(isTargeted ? Design.Palette.accentSoft : Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .strokeBorder(style: StrokeStyle(lineWidth: Design.Metric.hairline, dash: [4, 4]))
                .foregroundStyle(isTargeted ? Design.Palette.accent : Design.Palette.lineStrong)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.drop(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - Progress

private struct ImportProgressStrip: View {
    let progress: ImportProgress
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(progress.detail)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                // An indeterminate step says so and shows the clock, rather than inventing a number.
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Design.Palette.accent)
                        .frame(width: 160)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.linear).tint(Design.Palette.accent).frame(width: 120)
                        Text(String(format: "%.0f s", progress.elapsed))
                            .font(Design.Typography.numeric(11))
                            .foregroundStyle(Design.Palette.inkTertiary)
                    }
                }
            }
            if canCancel {
                Button("Cancel", action: cancel)
                    .font(Design.Typography.ui(12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.Palette.warn)
            }
        }
    }
}

// MARK: - Waveform

private struct WaveformPanel: View {
    @Bindable var model: ImportModel
    let layout: ImportLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PanelLabel("Waveform")
                // The one gesture this panel takes is invisible until it is said: nothing on the
                // plate suggests a drag, and the lever below it is disabled until one happens.
                Text("Drag across the waveform to choose the bars to chop; they play when you let go.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    if let selection = model.selection, model.waveform.duration > 0 {
                        selectionOverlay(selection, width: geometry.size.width)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
            }
            // Just under a third of the panel. You pick a region here by eye, against the downbeat
            // marks drawn over the trace; 132 points showed that the file had audio in it and not
            // where a bar started.
            .frame(height: layout.waveformHeight)
            .background(Design.Palette.plate)
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waveform of \(model.title)")
            .accessibilityValue(model.selectionLabel.map { "\($0) selected" } ?? "No region selected")
            .accessibilityHint("Drag across it to choose a region; the region plays when you let go.")
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let peaks = model.waveform.peaks
        guard !peaks.isEmpty, size.width > 0 else { return }
        let middle = size.height / 2
        let columnWidth = size.width / CGFloat(peaks.count)
        var path = Path()
        for (index, peak) in peaks.enumerated() {
            let x = CGFloat(index) * columnWidth
            let high = middle - CGFloat(peak.high) * middle
            let low = middle - CGFloat(peak.low) * middle
            path.move(to: CGPoint(x: x, y: min(high, low)))
            path.addLine(to: CGPoint(x: x, y: max(high, low) + 0.5))
        }
        context.stroke(path, with: .color(Design.Palette.trace), lineWidth: max(0.6, columnWidth))

        // Downbeats: the marks that make a waveform a grid rather than a picture.
        let duration = model.waveform.duration
        guard duration > 0 else { return }
        var marks = Path()
        for time in model.downbeats {
            let x = size.width * CGFloat(time / duration)
            marks.move(to: CGPoint(x: x, y: 0))
            marks.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(marks, with: .color(Design.Palette.accent.opacity(0.55)),
                       lineWidth: Design.Metric.hairline)
    }

    private func selectionOverlay(_ selection: SongGraph.TimeRange, width: CGFloat) -> some View {
        let duration = model.waveform.duration
        let start = width * CGFloat(selection.start / duration)
        let end = width * CGFloat(selection.end / duration)
        return Rectangle()
            .fill(Design.Palette.accent.opacity(0.22))
            .frame(width: max(1, end - start))
            .offset(x: start)
            .allowsHitTesting(false)
    }

    /// Dragging picks a region and plays it on release: the surface's "plays on touch".
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard width > 0 else { return }
                let a = model.waveform.time(atPosition: Double(value.startLocation.x / width))
                let b = model.waveform.time(atPosition: Double(value.location.x / width))
                model.selection = SongGraph.TimeRange(start: min(a, b), end: max(a, b))
            }
            .onEnded { _ in model.auditionSelection() }
    }
}

// MARK: - Readings

private struct ReadingsRow: View {
    let model: ImportModel

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            Reading("Key", model.detectedKey?.name ?? "—")
            Reading("Tempo", model.detectedTempo.map { String(format: "%.1f bpm", $0) } ?? "—")
            Reading("Bars", model.barCount == 0 ? "—" : "\(model.barCount)")
            Reading("Form", model.sections.isEmpty ? "—" : "\(model.sections.count)")
            Reading("Loudness", model.loudness.map { String(format: "%.1f LUFS", $0.integrated) } ?? "—")
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct Reading: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(value)
                .font(Design.Typography.numeric(13))
                .foregroundStyle(Design.Palette.ink)
        }
    }
}

// MARK: - Sections and instrument activity

private struct SectionsStrip: View {
    let model: ImportModel
    let layout: ImportLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("Sections and instrument activity")
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 4) {
                    laneRow(ranges: model.sections.map { SongGraph.TimeRange(start: $0.start, end: $0.end) },
                            label: "form", colour: Design.Palette.accent, width: geometry.size.width)
                    ForEach(model.instruments, id: \.instrument) { activity in
                        laneRow(ranges: activity.ranges, label: activity.instrument.rawValue,
                                colour: Design.Palette.inkSecondary, width: geometry.size.width)
                    }
                }
            }
            .frame(height: layout.sectionStripHeight)
        }
    }

    private func laneRow(ranges: [SongGraph.TimeRange], label: String, colour: Color, width: CGFloat) -> some View {
        let duration = max(0.001, model.waveform.duration)
        let lanes = max(1, width - layout.laneLabelWidth - 8)
        return HStack(spacing: 8) {
            Text(label)
                .font(Design.Typography.ui(10.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: layout.laneLabelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Design.Palette.panelAlt)
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                    let lead = lanes * CGFloat(range.start / duration)
                    let span = lanes * CGFloat(range.duration / duration)
                    Rectangle()
                        .fill(colour.opacity(0.35))
                        .frame(width: max(1, span))
                        .offset(x: lead)
                }
            }
            .frame(height: layout.sectionBarHeight)
        }
    }
}

// MARK: - Promote

private struct PromoteBar: View {
    @Bindable var model: ImportModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.pressPromote()
            } label: {
                Text("Promote region to a part")
                    .font(Design.Typography.ui(13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: Design.Metric.controlHeight)
                    .background(Design.Palette.accent)
                    .foregroundStyle(Design.Palette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            }
            .buttonStyle(.plain)
            .disabled(model.selection == nil)
            .opacity(model.selection == nil ? 0.4 : 1)
            // A disabled lever says what would enable it, not just that it is off.
            .help(model.selectionLabel.map { "Cut \($0) into a new sample part and open it in the Chop lane" }
                  ?? "Drag across the waveform to choose a region first")

            // What a drag on the waveform produced, so the selection is a thing with a name before
            // it is a thing that was promoted.
            if let selection = model.selection, let label = model.selectionLabel {
                Text("\(label) · \(String(format: "%.1f s", selection.duration))")
                    .font(Design.Typography.numeric(11.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }

            // Two ways to the same place. The button runs separation on the record already on
            // screen, which is the case a song opened from the library is always in. The chip arms
            // it for the import that is running: `run` reads the flag when the analysis finishes,
            // so up to then the choice is still open, and after that there is nothing to choose.
            if model.canSeparateStems {
                Button {
                    model.separateStems()
                } label: {
                    Text("Separate stems")
                        .font(Design.Typography.ui(13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: Design.Metric.controlHeight)
                        .foregroundStyle(Design.Palette.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.Metric.corner)
                                .stroke(Design.Palette.ink, lineWidth: Design.Metric.hairline)
                        )
                }
                .buttonStyle(.plain)
                .help("Split this record into drums, bass, vocals and other, into this song's package")
            } else if model.canStillChooseStems {
                ImportToggleChip("Separate stems", isOn: $model.separatesStems,
                                 help: "Also split this record into drums, bass, vocals and other once the analysis finishes")
            }

            Spacer()

            if !model.promoted.isEmpty {
                Text("\(model.promoted.count) promoted")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
        }
    }
}

// MARK: - A toggle as a chip

/// An on/off chip in the bench's chip style — the same face `BoothChip` wears, drawn here so this
/// surface does not depend on another surface's private furniture. An untinted native switch was
/// the one control on the panel in the system's colours rather than the instrument's.
private struct ImportToggleChip: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    init(_ title: String, isOn: Binding<Bool>, help: String) {
        self.title = title
        _isOn = isOn
        self.help = help
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Stems

private struct StemLanesPanel: View {
    let model: ImportModel
    let layout: ImportLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("Stems")
            if model.stems.isEmpty, model.state.phase == .separating {
                ArtImage("wait-separating", width: 180, height: 120)
            }
            if model.stems.isEmpty {
                Text(emptyLine)
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else {
                ForEach(model.stems) { lane in
                    StemLaneRow(lane: lane, model: model, layout: layout)
                }
            }
        }
    }

    /// The empty state names the lever that fills it rather than explaining the absence — and names
    /// the lever that is actually on screen, which depends on where the import is.
    private var emptyLine: String {
        if model.state.phase == .separating { return "Separating — lanes appear as each stem lands." }
        if model.canSeparateStems { return "No stems yet. Separate stems, above, splits this record into four." }
        if model.canStillChooseStems {
            return model.separatesStems
                ? "Stems will be separated once the analysis finishes."
                : "No stems yet. Turn on Separate stems, above, to split this record when the analysis finishes."
        }
        return "No stems."
    }
}

private struct StemLaneRow: View {
    let lane: StemLane
    let model: ImportModel
    let layout: ImportLayout

    var body: some View {
        HStack(spacing: 10) {
            Text(lane.name.rawValue)
                .font(Design.Typography.ui(12.5))
                .frame(width: layout.laneLabelWidth, alignment: .leading)
            LaneButton(title: "S", isOn: lane.isSoloed, help: "Solo \(lane.name.rawValue)",
                       label: "Solo \(lane.name.rawValue)") { model.toggleSolo(lane.name) }
            LaneButton(title: "M", isOn: lane.isMuted, help: "Mute \(lane.name.rawValue)",
                       label: "Mute \(lane.name.rawValue)") { model.toggleMute(lane.name) }
            Button { model.audition(stem: lane.name) } label: {
                Text("audition")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Play the \(lane.name.rawValue) stem over the selected region, or its first eight seconds")
            .accessibilityLabel("Audition \(lane.name.rawValue)")
            Spacer()
            Text(lane.duration.map { String(format: "%.1f s", $0) } ?? "—")
                .font(Design.Typography.numeric(11))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
        // Four lanes at 28 points each read as a list of file names. Given the room they are the
        // four things the record was split into, and each one is something you can aim at.
        .frame(height: layout.stemLaneHeight)
        .opacity(model.audibleStems.contains(lane.name) ? 1 : 0.45)
    }
}

/// A one-letter console button. The letter is the console's convention; the help and the
/// accessibility label say the word.
private struct LaneButton: View {
    let title: String
    let isOn: Bool
    let help: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11, weight: .semibold))
                .frame(width: 24, height: 20)
                .background(isOn ? Design.Palette.accent : Design.Palette.panelAlt)
                .foregroundStyle(isOn ? Design.Palette.panel : Design.Palette.inkSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Provenance

private struct ProvenancePanel: View {
    @Bindable var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PanelLabel("Provenance and clearance")
                Spacer()
                // The form writes nothing by itself: it is kept, like an arrangement, and until it
                // is the surface says so. Before the record is on disk there is nothing to keep it
                // into; an edit made while the stems are still landing waits for the run to end.
                if model.hasUnkeptProvenance {
                    Text(model.state.phase == .ready ? "Not kept yet" : "Keep it once the import finishes")
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                FrameButton(title: "Keep", emphasis: .outlined,
                            isEnabled: model.hasUnkeptProvenance && model.state.phase == .ready) {
                    model.keepProvenance()
                }
                .help(keepHelp)
                .accessibilityLabel("Keep provenance")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Field("Source title", text: $model.provenance.title)
                    Field("Artist", text: $model.provenance.artist)
                }
                GridRow {
                    Field("Label", text: $model.provenance.label)
                    Field("Year", text: $model.provenance.year)
                }
                GridRow {
                    Field("Rights holder", text: $model.provenance.rightsHolder)
                    Picker("Clearance", selection: $model.provenance.clearance) {
                        ForEach(ClearanceStatus.allCases, id: \.self) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    .font(Design.Typography.ui(12))
                }
                GridRow {
                    Field("Note", text: $model.provenance.note)
                        .gridCellColumns(2)
                }
            }
            if !model.provenance.citation.isEmpty {
                Text(model.provenance.citation)
                    .font(Design.Typography.prose(13))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            // Where it goes, so the form is not a field that leads nowhere: the row names the source
            // an album's clearance sheet lists; the seed note carries the rest of the form.
            Text("Kept in the library's record and the song's seed note. Album ▸ Clearances names its sources from the record.")
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
        .padding(Design.Metric.inset)
        .background(Design.Palette.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private var keepHelp: String {
        if model.state.phase != .ready { return "The import writes the form when the record is on disk" }
        if !model.hasUnkeptProvenance { return "The record already has this form" }
        return "Write the form to the library's record and the song's seed note"
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Design.Typography.ui(12.5, weight: .regular))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Design.Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .strokeBorder(Design.Palette.line, lineWidth: Design.Metric.hairline)
                )
        }
    }
}

// MARK: - Small pieces

private struct PanelLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(Design.Palette.inkTertiary)
    }
}

private struct FailureNote: View {
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
