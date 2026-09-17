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
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            switch model.state {
            case .empty, .cancelled, .failed:
                DropWell(model: model)
            default:
                content
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(SurfaceKind.importRecord.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(model.title)
                .font(Design.Typography.prose(16, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
            Spacer()
            if model.state.isBusy {
                ImportProgressStrip(progress: model.progress,
                                    canCancel: model.state.isCancellable,
                                    cancel: { model.cancel() })
            }
        }
    }

    // MARK: Body

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                WaveformPanel(model: model)
                ReadingsRow(model: model)
                if !model.sections.isEmpty { SectionsStrip(model: model) }
                PromoteBar(model: model)
                StemLanesPanel(model: model)
                ProvenancePanel(model: model)
                if let error = model.lastError { FailureNote(text: error) }
            }
        }
    }
}

// MARK: - Drop well

private struct DropWell: View {
    @Bindable var model: ImportModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Drop a record here")
                .font(Design.Typography.prose(17))
                .foregroundStyle(Design.Palette.ink)
            Text("An audio file becomes a song package: key, tempo, bars, sections and a take.")
                .font(Design.Typography.ui(12.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .multilineTextAlignment(.center)
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
        .frame(maxWidth: .infinity, minHeight: 220)
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
                        .frame(width: 160)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.linear).frame(width: 120)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("Waveform")
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
            .frame(height: 132)
            .background(Design.Palette.plate)
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
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
            Reading("Sections", model.sections.isEmpty ? "—" : "\(model.sections.count)")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("Sections and instrument activity")
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 4) {
                    laneRow(ranges: model.sections.map { SongGraph.TimeRange(start: $0.start, end: $0.end) },
                            label: "sections", colour: Design.Palette.accent, width: geometry.size.width)
                    ForEach(model.instruments, id: \.instrument) { activity in
                        laneRow(ranges: activity.ranges, label: activity.instrument.rawValue,
                                colour: Design.Palette.inkSecondary, width: geometry.size.width)
                    }
                }
            }
            .frame(height: CGFloat(model.instruments.count + 1) * 20)
        }
    }

    private func laneRow(ranges: [SongGraph.TimeRange], label: String, colour: Color, width: CGFloat) -> some View {
        let duration = max(0.001, model.waveform.duration)
        return HStack(spacing: 8) {
            Text(label)
                .font(Design.Typography.ui(10.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: 60, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Design.Palette.panelAlt)
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                    let lead = (width - 68) * CGFloat(range.start / duration)
                    let span = (width - 68) * CGFloat(range.duration / duration)
                    Rectangle()
                        .fill(colour.opacity(0.35))
                        .frame(width: max(1, span))
                        .offset(x: lead)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Promote

private struct PromoteBar: View {
    @Bindable var model: ImportModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                try? model.promoteSelection()
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

            Toggle(isOn: $model.separatesStems) {
                Text("Separate stems")
                    .font(Design.Typography.ui(13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(model.state.isBusy)

            Spacer()

            if !model.promoted.isEmpty {
                Text("\(model.promoted.count) promoted")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
        }
    }
}

// MARK: - Stems

private struct StemLanesPanel: View {
    let model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("Stems")
            if model.stems.isEmpty {
                Text(model.state.phase == .separating
                     ? "Separating — lanes appear as each stem lands."
                     : "No stems. Turn on Separate stems before dropping a record.")
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else {
                ForEach(model.stems) { lane in
                    StemLaneRow(lane: lane, model: model)
                }
            }
        }
    }
}

private struct StemLaneRow: View {
    let lane: StemLane
    let model: ImportModel

    var body: some View {
        HStack(spacing: 10) {
            Text(lane.name.rawValue)
                .font(Design.Typography.ui(12.5))
                .frame(width: 70, alignment: .leading)
            LaneButton(title: "S", isOn: lane.isSoloed) { model.toggleSolo(lane.name) }
            LaneButton(title: "M", isOn: lane.isMuted) { model.toggleMute(lane.name) }
            Button { model.audition(stem: lane.name) } label: {
                Text("audition")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.accent)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(lane.duration.map { String(format: "%.1f s", $0) } ?? "—")
                .font(Design.Typography.numeric(11))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
        .frame(height: Design.Metric.chipHeight)
        .opacity(model.audibleStems.contains(lane.name) ? 1 : 0.45)
    }
}

private struct LaneButton: View {
    let title: String
    let isOn: Bool
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
    }
}

// MARK: - Provenance

private struct ProvenancePanel: View {
    @Bindable var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel("Provenance and clearance")
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
        }
        .padding(Design.Metric.inset)
        .background(Design.Palette.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
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
