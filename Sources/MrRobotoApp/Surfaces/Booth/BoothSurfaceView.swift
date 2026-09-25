import SongGraph
import SwiftUI

/// The Booth: the one place you sing. Record and the count-in along the top, the words on the
/// left, and the chosen section's takes on the right with the comp — so a take is sung to the
/// words, lands in its lane when it stops, and is comped without leaving.
///
/// There is no Arm. The model has an armed state, but the only thing that can read the input is a
/// recorder on the running transport, so a level cannot be shown before Record starts the song —
/// and an Arm that changed a word in the header and nothing else was a control that did nothing.
struct BoothSurfaceView: View {
    @Bindable var model: BoothModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            recordRow
            sectionRow
            settingsRow
            // The panes take what the controls leave, and each scrolls inside itself: at the
            // bench's minimum that is about two hundred points, and a lyric or an evening's takes
            // is longer than that.
            GeometryReader { geometry in
                let layout = BoothLayout(width: geometry.size.width)
                HStack(alignment: .top, spacing: layout.gutter) {
                    wordsPane.frame(width: layout.wordsWidth)
                    takesPane.frame(width: layout.takesWidth)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .padding(.top, 4)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        // A take kept by another surface, the words rewritten on the Lyrics surface: the song
        // moved, so the lanes are read again. The words need nothing — they are read from the song.
        .onChange(of: model.song?.versions.count ?? 0) { model.songChanged() }
        // A section removed on the Structure surface is not a version, but the Booth must not
        // go on offering it.
        .onChange(of: model.sections.map(\.id)) { model.songChanged() }
    }

    // MARK: The top

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.song?.title ?? "Booth")
                .font(Design.Typography.prose(16, weight: .medium))
                .lineLimit(1)
            Text(stateLine)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(model.state == .recording ? Design.Palette.warn : Design.Palette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let bars = model.sectionBars {
                Text("bars \(bars.lowerBound + 1)–\(bars.upperBound) · \(StructureModel.clock(model.clock.seconds(forBar: bars.lowerBound)))")
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var stateLine: String {
        switch model.state {
        case .idle: return "Idle · next is take \(model.nextPass)"
        case .armed: return "Armed · next is take \(model.nextPass)"
        case .recording: return model.countInLine != nil ? "Counting in · take \(model.nextPass)" : "Recording take \(model.nextPass)"
        }
    }

    /// Record or Stop, the count while it counts, and the input's level.
    private var recordRow: some View {
        HStack(alignment: .center, spacing: 10) {
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
                    .help(recordHelp)
                KeyHint("R")
            }
            if let count = model.countInLine {
                Text(count)
                    .font(Design.Typography.prose(15, weight: .medium))
                    .foregroundStyle(Design.Palette.accent)
                    .lineLimit(1)
                    .accessibilityLabel(count)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 3) {
                LevelBar(level: model.level)
                    .frame(minWidth: 90, maxWidth: 220)
                    .frame(height: 10)
                    .help(model.state == .recording ? "The input's peak, buffer by buffer." : "The input's level shows while a take records; the recorder is the only thing that hears it.")
                    .accessibilityLabel("Input level")
                    .accessibilityValue(model.state == .recording ? String(format: "%.0f percent", model.level * 100) : "not recording")
                // Said under the meter, so an empty bar before the first take is not read as no input.
                Text(model.state == .recording ? "Input level" : "Input level · shows while recording")
                    .font(Design.Typography.ui(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(Design.Typography.ui(12.5))
        .frame(minHeight: Design.Metric.chipHeight)
    }

    private var recordHelp: String {
        if model.isPlaying { return "Starts a take now, over the song as it plays. Press R." }
        let counted = model.countInBars == 0 ? "" : " after \(model.countInBars) bar\(model.countInBars == 1 ? "" : "s") of click"
        return "Starts the song at the section and the take with it\(counted). Press R."
    }

    /// The section the take is for, each with how many takes it has.
    private var sectionRow: some View {
        FlowRow(spacing: 6) {
            BoothLabel("Section").frame(height: Design.Metric.chipHeight)
            ForEach(model.sections) { section in
                let count = model.takes(of: section.id).count
                BoothChip(count > 0 ? "\(section.name) · \(count)" : section.name, isOn: model.section == section.id) {
                    model.section = section.id
                }
                .help(count > 0 ? "\(section.name): \(count) take\(count == 1 ? "" : "s") so far" : "\(section.name): no takes yet")
                .disabled(model.state == .recording)
            }
            BoothChip("Whole song", isOn: model.section == nil) { model.section = nil }
                .help("Records against the whole song, from the top, with no punch-out.")
                .disabled(model.state == .recording)
        }
    }

    /// How Record starts the song, when it stops, and what it hears. Wraps at the bench's minimum.
    private var settingsRow: some View {
        FlowRow(spacing: 14) {
            HStack(spacing: 6) {
                BoothLabel("Count-in")
                ForEach(BoothModel.countInChoices, id: \.self) { bars in
                    BoothChip(bars == 0 ? "Off" : "\(bars) bar\(bars == 1 ? "" : "s")", isOn: model.countInBars == bars) {
                        model.countInBars = bars
                    }
                    .accessibilityLabel(bars == 0 ? "No count-in" : "Count in \(bars) bar\(bars == 1 ? "" : "s")")
                }
            }
            .frame(height: Design.Metric.chipHeight)
            .help("Bars of click before the section's first bar when Record starts the song.")
            Toggle("Click", isOn: $model.click)
                .toggleStyle(.checkbox)
                .tint(Design.Palette.accent)
                .font(Design.Typography.ui(12))
                .frame(height: Design.Metric.chipHeight)
                .help("Keeps the click going through the whole take, not just the count-in.")
            Toggle("Punch out", isOn: $model.punchesOut)
                .toggleStyle(.checkbox)
                .tint(Design.Palette.accent)
                .font(Design.Typography.ui(12))
                .frame(height: Design.Metric.chipHeight)
                .help("Stops the take by itself on the section's last bar.")
            inputPicker
                .frame(height: Design.Metric.chipHeight)
            if model.input.isFallingBack(in: model.inputs) {
                // Only when it matters: the remembered interface is not plugged in, so the take
                // will come from somewhere else and should say so before it is sung.
                Text(model.inputLine)
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The device by name and, on a device with more than one, the channel.
    private var inputPicker: some View {
        HStack(spacing: 6) {
            BoothLabel("Input")
            Picker("Input device", selection: Binding(
                get: { model.input.deviceUID ?? "" },
                set: { uid in model.input = InputChoice(deviceUID: uid.isEmpty ? nil : uid, channel: model.input.channel) })) {
                Text("System default").tag("")
                ForEach(model.inputs) { device in
                    Text("\(device.name) · \(device.inputChannels) in").tag(device.uid)
                }
            }
            .labelsHidden()
            .font(Design.Typography.ui(12))
            .frame(maxWidth: 200)
            .help("Where the take comes from: \(model.inputLine)")
            .accessibilityLabel("Input device")
            if let device = model.inputDevice, device.inputChannels > 1 {
                Picker("Input channel", selection: Binding(
                    get: { model.input.channel ?? -1 },
                    set: { channel in model.input.channel = channel < 0 ? nil : channel })) {
                    ForEach(0..<min(device.inputChannels, 16), id: \.self) { channel in
                        Text("Input \(channel + 1)").tag(channel)
                    }
                    Text("All \(device.inputChannels)").tag(-1)
                }
                .labelsHidden()
                .font(Design.Typography.ui(12))
                .fixedSize()
                .help("Which of \(device.name)'s inputs the take comes from; all of them records every channel.")
                .accessibilityLabel("Input channel")
            }
        }
    }

    // MARK: The panes

    /// The song's newest lyric, read-only: the words are written on the Lyrics surface. When a
    /// stanza there is labelled with the chosen section's name, it is what you sing, so it comes
    /// first and the rest of the lyric waits under it, faint.
    private var wordsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BoothLabel("Words")
                Spacer(minLength: 4)
                if let lyric = model.lyric, model.hasWords {
                    Text(PartLabel.title(of: lyric))
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let hint = model.sectionWordsHint {
                Text(hint)
                    .font(Design.Typography.ui(11, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasWords {
                ScrollsInside {
                    Group {
                        if let words = model.sectionWords {
                            VStack(alignment: .leading, spacing: 14) {
                                SungWords(rows: words.stanza.enumerated().map { index, line in
                                    BoothModel.WordsLine(label: index == 0 ? words.name : nil, line: line)
                                })
                                if !words.rest.isEmpty {
                                    Hairline()
                                    SungWords(rows: words.rest, faint: true)
                                }
                            }
                        } else {
                            SungWords(rows: model.wordsLines)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
            } else {
                EmptyNote(title: "No words yet.",
                          detail: "Words are written on the Lyrics surface (⌘9). The song's newest lyric shows here while you sing.")
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// The chosen section's takes, as lanes, with the comp on top.
    private var takesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BoothLabel("\(sectionName) takes")
                    .lineLimit(1)
                let count = model.lanes?.takes.count ?? 0
                if count > 0 {
                    Text("\(count)")
                        .font(Design.Typography.numeric(11))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                Spacer(minLength: 4)
                if let lanes = model.lanes, !lanes.takes.isEmpty {
                    MakeCompButton(model: lanes)
                }
            }
            if let lanes = model.lanes, !lanes.takes.isEmpty {
                ScrollsInside {
                    TakesLanes(model: lanes, titleWidth: 136)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                EmptyNote(title: model.lanes == nil ? "Takes are comped on the Takes surface." : "No takes of \(sectionPhrase) yet.",
                          detail: "Press Record and sing it. Each take you stop lands here as a lane; press a bar on a lane "
                              + "to take that bar from it, then Make the comp.")
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var sectionName: String {
        guard let id = model.section, let section = model.sections.first(where: { $0.id == id }) else { return "Whole-song" }
        return section.name
    }

    private var sectionPhrase: String {
        guard let id = model.section, let section = model.sections.first(where: { $0.id == id }) else { return "the whole song" }
        return "the \(section.name)"
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError ?? model.lanes?.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn).lineLimit(2)
        } else {
            Text("Every take stays, untouched. The band flags what it hears on the bar it hears it; a fix is a new version.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary).lineLimit(2)
        }
    }
}

/// How the Booth splits the room under its controls: the words a readable column on the left,
/// the takes everything else. Values rather than modifiers so a test can hold them to the bench's
/// real sizes (`SurfaceGeometry`).
struct BoothLayout: Equatable {
    let gutter: CGFloat
    /// Wide enough for a sung line at the words' size to wrap once at most; no wider, because a
    /// line of words across a wide bench is harder to follow than two.
    let wordsWidth: CGFloat
    let takesWidth: CGFloat

    init(width: CGFloat, gutter: CGFloat = Design.Metric.gutter) {
        self.gutter = gutter
        let room = max(0, width - gutter)
        wordsWidth = min(room, clamped(room * 0.4, 200, 360))
        takesWidth = max(0, room - wordsWidth)
    }
}

/// A lyric's lines as the Lyrics surface reads them back — stressed syllables heavier and darker —
/// at a size to read from a step back, with a microphone in the way. A line is one run of text, so
/// it wraps in a narrow pane instead of running off it. A stanza's label sits above its first line;
/// faint words are the ones not being sung now.
struct SungWords: View {
    let rows: [BoothModel.WordsLine]
    var faint = false

    init(rows: [BoothModel.WordsLine], faint: Bool = false) {
        self.rows = rows
        self.faint = faint
    }

    init(lines: [LyricLine]) { self.init(rows: lines.map { BoothModel.WordsLine(label: nil, line: $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let label = row.label {
                    Text(label.uppercased())
                        .font(Design.Typography.label)
                        .tracking(1.1)
                        .foregroundStyle(faint ? Design.Palette.inkTertiary : Design.Palette.accent)
                        .accessibilityLabel("Stanza: \(label)")
                }
                if row.line.syllables.isEmpty {
                    // A blank line is the gap between stanzas.
                    Color.clear.frame(height: 10)
                } else {
                    Text(Self.sung(row.line, faint: faint))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func sung(_ line: LyricLine, faint: Bool = false) -> AttributedString {
        var sung = AttributedString()
        for (index, syllable) in line.syllables.enumerated() {
            let stressed = syllable.stress != .unstressed
            var piece = AttributedString((index > 0 && syllable.startsWord ? " " : "") + syllable.text)
            piece.font = Design.Typography.prose(faint ? 13 : 15, weight: stressed ? .semibold : .regular)
            piece.foregroundColor = faint
                ? (stressed ? Design.Palette.inkSecondary : Design.Palette.inkTertiary)
                : (stressed ? Design.Palette.ink : Design.Palette.inkSecondary)
            sung += piece
        }
        return sung
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
