import SongGraph
import SwiftUI

/// The Booth: the section to sing to, the input's level, arm, Record and Stop.
struct BoothSurfaceView: View {
    @Bindable var model: BoothModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                controls
                takesList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.song?.title ?? "Booth").font(Design.Typography.prose(16, weight: .medium))
            Text(stateLine)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(model.state == .recording ? Design.Palette.warn : Design.Palette.inkSecondary)
            Spacer()
            if let bars = model.sectionBars {
                Text("bars \(bars.lowerBound + 1)–\(bars.upperBound) · \(StructureModel.clock(model.clock.seconds(forBar: bars.lowerBound)))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }

    private var stateLine: String {
        switch model.state {
        case .idle: return "Idle"
        case .armed: return "Armed · next is take \(model.nextPass)"
        case .recording: return "Recording take \(model.nextPass)"
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoothLabel("Section")
            FlowRow(spacing: 6) {
                ForEach(model.sections) { section in
                    BoothChip(section.name, isOn: model.section == section.id) { model.section = section.id }
                }
                BoothChip("Whole song", isOn: model.section == nil) { model.section = nil }
            }
            BoothLabel("Input")
            LevelBar(level: model.level)
                .frame(width: 260, height: 10)
            HStack(spacing: 8) {
                Toggle("Punch out at the section's end", isOn: $model.punchesOut).toggleStyle(.checkbox)
                    .font(Design.Typography.ui(12))
            }
            BoothLabel("Transport")
            HStack(spacing: 8) {
                if model.state == .recording {
                    Button("Stop") { Task { await model.stopRecording(stopSong: true) } }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("Stop and keep playing") { Task { await model.stopRecording() } }
                } else {
                    Button(model.state == .armed ? "Disarm" : "Arm") { model.state == .armed ? model.disarm() : model.arm() }
                    Button("Record") { Task { await model.record() } }
                        .keyboardShortcut("r", modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .tint(Design.Palette.warn)
                }
            }
            .font(Design.Typography.ui(12.5))
            Text(model.isPlaying ? "The song is playing; Record starts a take now." : "Record starts the song and the take together.")
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
        .frame(width: 320, alignment: .topLeading)
    }

    private var takesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoothLabel("Takes this song")
            if model.takes.isEmpty {
                Text("None yet. Pick a section, press Record, sing it, press Stop.")
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(model.takes) { version in
                if let audio = Guidance.audio(of: version), let take = audio.take {
                    HStack(spacing: 10) {
                        Text(PartLabel.title(of: version)).font(Design.Typography.ui(13, weight: .medium))
                        Text(sectionName(take.section))
                            .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                        Spacer()
                        Text(String(format: "bar %d · %.1f s · %@", take.startBar + 1, audio.duration, take.input ?? "input"))
                            .font(Design.Typography.numeric(11)).foregroundStyle(Design.Palette.inkTertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sectionName(_ id: SectionID?) -> String {
        guard let id, let section = model.sections.first(where: { $0.id == id }) else { return "whole song" }
        return section.name
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else {
            Text("Every take stays. The band reads them in Takes and offers a fix as a new version; nothing here is tuned or moved.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

private struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Design.Palette.panelAlt)
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.9 ? Design.Palette.warn : Design.Palette.accent)
                    .frame(width: geometry.size.width * CGFloat(min(1, level)))
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
    }
}

struct BoothChip: View {
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
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct BoothLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}
