import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// The Merge surface: two lanes, the plan between them in sentences, and the section they become.
struct MergeSurfaceView: View {
    @Bindable var model: MergeModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            target
            lane(.a)
            lane(.b)
            flags
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.title).font(Design.Typography.prose(16, weight: .medium))
            if !model.isReady {
                // Says how to get here, not only what is missing: the surface opens from the
                // ledger's context menu and nowhere else.
                Text("A merge needs two parts. Right-click a chop, bass line, chords or groove in Parts and choose Merge with….")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Both") { model.playBoth() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .disabled(!model.isReady)
                .help("Both fragments together, each moved as the plan says")
            Button("Stop") { model.stop() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .help("Stop what is playing")
        }
    }

    private var target: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                MergeLabel("Into the key")
                HStack(spacing: 4) {
                    ForEach(model.keyOptions, id: \.self) { key in
                        MergeChip(key.name + (key == model.songKey ? " (song)" : ""),
                                  isOn: model.targetKey.map { $0.signature == key.signature && $0.mode == key.mode } == true) {
                            model.targetKey = key
                        }
                    }
                    if model.keyOptions.isEmpty {
                        Text("No key anywhere: nothing is transposed.")
                            .font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                MergeLabel("At the tempo")
                HStack(spacing: 4) {
                    ForEach(model.tempoOptions, id: \.self) { tempo in
                        MergeChip("\(Int(tempo))" + (tempo == model.songTempo?.rounded() ? " (song)" : ""),
                                  isOn: model.targetTempo.map { $0.rounded() == tempo } == true) {
                            model.targetTempo = tempo
                        }
                    }
                }
            }
        }
    }

    private func lane(_ lane: MergeModel.Lane) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MergeLabel(lane == .a ? "A" : "B")
                Text(model.summary(lane))
                    .font(Design.Typography.ui(13, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
                Spacer()
                if model.fragment(lane)?.kind != .groove, model.move(lane) != nil {
                    MergeChip("−1") { model.nudge(lane, by: -1) }
                        .help("A semitone down, by ear, from where the key arithmetic put it")
                        .accessibilityLabel("Down a semitone")
                    Text(String(format: "%+d st", model.move(lane)?.semitones ?? 0))
                        .font(Design.Typography.numeric(11.5))
                        .foregroundStyle(model.override(lane) == nil ? Design.Palette.inkSecondary : Design.Palette.accent)
                        .frame(width: 44)
                        .help(model.override(lane) == nil ? "Semitones moved, by the key" : "Semitones moved, by ear")
                    MergeChip("+1") { model.nudge(lane, by: 1) }
                        .help("A semitone up, by ear, from where the key arithmetic put it")
                        .accessibilityLabel("Up a semitone")
                    // "By the key", as Mashup says it: the same undo of the same hand on the same
                    // arithmetic, so it reads the same on both surfaces.
                    if model.override(lane) != nil {
                        MergeChip("By the key") { model.resetOverride(lane) }
                            .help("Back to what the key arithmetic chose, forgetting the nudge")
                    }
                }
                Button("Play") { model.play(lane) }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .medium))
                    .foregroundStyle(Design.Palette.accent)
                    .disabled(model.version(lane) == nil)
                    .help("This fragment alone, moved as the plan says")
            }
            if let move = model.move(lane) {
                Text(move.sentence)
                    .font(Design.Typography.prose(13))
                    .foregroundStyle(move.isUntouched ? Design.Palette.inkSecondary : Design.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    @ViewBuilder
    private var flags: some View {
        if let plan = model.plan, !plan.flags.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan.flags, id: \.self) { flag in
                    Text(flag).font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.warn)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let error = model.lastError {
                Text(error).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn)
            } else if let section = model.stitched {
                Text("Stitched as \(section.name), \(section.lengthInBars) bars. The transport plays it; Structure shows it.")
                    .font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
            } else if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Design.Palette.accent)
                    Text("Rendering…").font(Design.Typography.ui(11.5, weight: .regular)).foregroundStyle(Design.Palette.inkSecondary)
                }
            }
            Spacer()
            MergeLabel("Section")
            TextField("Verse", text: $model.sectionName)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.ui(12))
                .frame(width: 110)
            HStack(spacing: 4) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { bars in
                    MergeChip("\(bars)", isOn: model.bars == bars) { model.bars = bars }
                }
            }
            Button("Stitch as a section") { Task { await model.stitch() } }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
                .disabled(!model.isReady || model.isWorking)
                .help("Render both moves for keeps, as new versions derived from the originals, and add a section to the end of the form that plays them together")
        }
    }
}

private struct MergeChip: View {
    let title: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, isOn: Bool = false, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panel,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct MergeLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}
