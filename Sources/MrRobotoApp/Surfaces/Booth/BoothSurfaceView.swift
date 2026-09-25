import SongGraph
import SwiftUI

/// The Booth: the section to sing to, the input's level, Record and Stop.
///
/// There is no Arm. The model has an armed state, but the only thing that can read the input is a
/// recorder on the running transport, so a level cannot be shown before Record starts the song —
/// and an Arm that changed a word in the header and nothing else was a control that did nothing.
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
        case .idle: return "Idle · next is take \(model.nextPass)"
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
            inputPicker
            VStack(alignment: .leading, spacing: 3) {
                LevelBar(level: model.level)
                    .frame(width: 260, height: 10)
                    .help(model.state == .recording ? "The input's peak, buffer by buffer." : "The input's level shows while a take records; the recorder is the only thing that hears it.")
                    .accessibilityLabel("Input level")
                    .accessibilityValue(model.state == .recording ? String(format: "%.0f percent", model.level * 100) : "not recording")
                // Said under the meter, so an empty bar before the first take is not read as no input.
                Text(model.state == .recording ? "Input level" : "Input level · shows while recording")
                    .font(Design.Typography.ui(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            HStack(spacing: 8) {
                Toggle("Punch out at the section's end", isOn: $model.punchesOut).toggleStyle(.checkbox)
                    .font(Design.Typography.ui(12))
                    .tint(Design.Palette.accent)
                    .help("Stops the take by itself on the section's last bar.")
            }
            BoothLabel("Transport")
            HStack(spacing: 8) {
                if model.state == .recording {
                    // No bare Space here: the app's transport already owns Space, and two controls
                    // on one key stop different things depending on which one wins.
                    Button("Stop") { Task { await model.stopRecording(stopSong: true) } }
                        .help("Ends the take and stops the song.")
                    Button("Stop and keep playing") { Task { await model.stopRecording() } }
                        .help("Ends the take; the song plays on.")
                } else {
                    Button("Record") { Task { await model.record() } }
                        .keyboardShortcut("r", modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .tint(Design.Palette.warn)
                        .help("Starts a take now, and the song with it if it is stopped. Press R.")
                    KeyHint("R")
                }
            }
            .font(Design.Typography.ui(12.5))
            Text(model.isPlaying ? "The song is playing; Record starts a take now." : "Record starts the song and the take together.")
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
        .frame(width: 320, alignment: .topLeading)
    }

    /// The device by name, the channel on a device with more than one, and what the take will say.
    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Device", selection: Binding(
                get: { model.input.deviceUID ?? "" },
                set: { uid in model.input = InputChoice(deviceUID: uid.isEmpty ? nil : uid, channel: model.input.channel) })) {
                Text("System default").tag("")
                ForEach(model.inputs) { device in
                    Text("\(device.name) · \(device.inputChannels) in").tag(device.uid)
                }
            }
            .labelsHidden()
            .font(Design.Typography.ui(12))
            .frame(width: 260, alignment: .leading)
            if let device = model.inputDevice, device.inputChannels > 1 {
                FlowRow(spacing: 6) {
                    ForEach(0..<min(device.inputChannels, 16), id: \.self) { channel in
                        BoothChip("Input \(channel + 1)", isOn: model.input.channel == channel) { model.input.channel = channel }
                    }
                    BoothChip("All \(device.inputChannels)", isOn: model.input.channel == nil) { model.input.channel = nil }
                }
            }
            Text(model.inputLine)
                .font(Design.Typography.ui(11))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(2)
                .frame(width: 300, alignment: .leading)
        }
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

/// A key drawn as a key cap beside the control it presses, because a shortcut on a button in a
/// panel is invisible otherwise: only a menu shows its key equivalent.
struct KeyHint: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(Design.Typography.numeric(10.5, weight: .medium))
            .foregroundStyle(Design.Palette.inkSecondary)
            .frame(minWidth: Design.Metric.tagHeight, minHeight: Design.Metric.tagHeight)
            .padding(.horizontal, 4)
            .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
            .help("Press \(key) to record.")
            .accessibilityHidden(true)
    }
}
