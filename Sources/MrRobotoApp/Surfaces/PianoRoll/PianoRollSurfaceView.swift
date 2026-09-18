import Instrument
import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// The Piano roll: the bass line over the bar, the groove's kicks under it, the Bassist's readings
/// under that.
struct PianoRollSurfaceView: View {
    @Bindable var model: PianoRollModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            levers
            NoteLane(model: model)
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
            readings
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.title)
                .font(Design.Typography.prose(16, weight: .medium))
            if model.groove == nil {
                Text("No groove to sit under: this line is on the grid.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
            } else if model.usesDefaultChords {
                Text("No chords stated — written to the key's I–IV–V–I.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            Spacer()
            Button("Play line") { model.playLine() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
            Button("Stop") { model.stop() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
    }

    private var levers: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Hands")
                HStack(spacing: 4) {
                    ForEach(BassLineage.allCases, id: \.self) { lineage in
                        RollChip(lineage.name, isOn: model.lineage == lineage) { model.setLineage(lineage) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Behind the kick")
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.lagMS }, set: { model.setLag($0) }), in: -25...90)
                        .frame(width: 160)
                    Text(String(format: "%+.0f ms", model.lagMS))
                        .font(Design.Typography.numeric(12))
                        .frame(width: 54, alignment: .leading)
                }
                Text("20–65 is the window; 40 the default")
                    .font(Design.Typography.numeric(10))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Density")
                Slider(value: Binding(get: { model.density }, set: { model.setDensity($0) }), in: 0...1)
                    .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Sound")
                HStack(spacing: 4) {
                    ForEach(BassVoiceSpec.all) { voice in
                        RollChip(voice.name, isOn: model.sound == voice.id) { model.setSound(voice.id) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Line")
                HStack(spacing: 4) {
                    RollChip("Rewrite", isOn: false) { model.rewrite() }
                        .help("Another line from the same levers")
                    RollChip("Alternate early", isOn: model.earlyAlternation) { model.setEarlyAlternation(!model.earlyAlternation) }
                        .help("Every other note up to 25 ms ahead — the one early pattern on record")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: "Bassist") { ArtImage(emblem, width: 18) }
                RollLabel("The Bassist")
            }
            if model.readings.isEmpty {
                Text("Nothing to read without a groove under it.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            ForEach(model.readings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: reading.holds ? "checkmark" : "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(reading.holds ? Design.Palette.inkTertiary : Design.Palette.warn)
                        .frame(width: 12)
                    Text(reading.says)
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.lastError {
                Text(error).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn)
            }
            Spacer()
            Text(model.isHandEdited ? "Edited by hand" : "As written")
                .font(Design.Typography.ui(11.5))
                .foregroundStyle(Design.Palette.inkTertiary)
            Button("Keep as a new version") { model.commit() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
                .disabled(model.notes.isEmpty)
        }
    }
}

// MARK: - The lane

/// The notes over the bar, with the kicks under them. Beats across, pitches down (high at the
/// top). Drag a note to move it, its right edge to lengthen it; double-click to delete; click an
/// empty cell to add.
private struct NoteLane: View {
    @Bindable var model: PianoRollModel

    static let labelWidth: CGFloat = 34
    static let kickLaneHeight: CGFloat = 18
    static let minimumRowHeight: CGFloat = 9

    @State private var drag: Drag?

    private struct Drag {
        var index: Int
        var originalStart: Double
        var originalPitch: Int
        var originalDuration: Double
        var resizing: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let register = model.register
            let rows = register.count
            let width = geometry.size.width - Self.labelWidth
            let laneHeight = geometry.size.height - Self.kickLaneHeight - 4
            let rowHeight = max(Self.minimumRowHeight, laneHeight / CGFloat(rows))
            let beatWidth = width / CGFloat(max(1, model.totalBeats))
            let chords = HarmonyMap(chords: model.chords, totalBeats: model.totalBeats)

            ZStack(alignment: .topLeading) {
                // Rows: the register, black keys shaded, the chord's root row lit softly.
                ForEach(Array(register.reversed().enumerated()), id: \.element) { row, midi in
                    let isBlack = [1, 3, 6, 8, 10].contains(midi % 12)
                    let isC = midi % 12 == 0
                    Rectangle()
                        .fill(isBlack ? Design.Palette.panelAlt : Design.Palette.panel)
                        .frame(width: width, height: rowHeight)
                        .overlay(alignment: .top) {
                            if isC { Rectangle().fill(Design.Palette.lineStrong).frame(height: Design.Metric.hairline) }
                        }
                        .offset(x: Self.labelWidth, y: CGFloat(row) * rowHeight)
                    if isC {
                        Text(Pitch(midi: midi).name())
                            .font(Design.Typography.numeric(9))
                            .foregroundStyle(Design.Palette.inkTertiary)
                            .frame(width: Self.labelWidth - 4, alignment: .trailing)
                            .offset(y: CGFloat(row) * rowHeight - 2)
                    }
                }
                // Beat lines, the bar lines heavier; the chord's name over each change.
                ForEach(0..<Int(model.totalBeats), id: \.self) { beat in
                    let isBar = beat % model.beatsPerBar == 0
                    Rectangle()
                        .fill(isBar ? Design.Palette.lineStrong : Design.Palette.line)
                        .frame(width: Design.Metric.hairline, height: laneHeight)
                        .offset(x: Self.labelWidth + CGFloat(beat) * beatWidth)
                }
                ForEach(chords.spans.indices, id: \.self) { i in
                    let span = chords.spans[i]
                    Text(span.chord.symbol(preferring: model.key.signature.preference))
                        .font(Design.Typography.ui(10.5, weight: .medium))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .offset(x: Self.labelWidth + CGFloat(span.start) * beatWidth + 3, y: 1)
                }
                // Kick lane.
                Rectangle()
                    .fill(Design.Palette.panelAlt)
                    .frame(width: width, height: Self.kickLaneHeight)
                    .offset(x: Self.labelWidth, y: laneHeight + 4)
                Text("kick")
                    .font(Design.Typography.numeric(9))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(width: Self.labelWidth - 4, alignment: .trailing)
                    .offset(y: laneHeight + 6)
                ForEach(model.kickBeats, id: \.self) { beat in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Design.Palette.ink.opacity(0.7))
                        .frame(width: 3, height: Self.kickLaneHeight - 6)
                        .offset(x: Self.labelWidth + CGFloat(beat) * beatWidth - 1, y: laneHeight + 7)
                }
                // Empty-cell clicks add a note.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: width, height: laneHeight)
                    .offset(x: Self.labelWidth)
                    .onTapGesture { location in
                        let beat = Double((location.x - Self.labelWidth) / beatWidth)
                        let row = Int(location.y / rowHeight)
                        let midi = register.upperBound - row
                        model.addNote(pitch: midi, at: beat)
                    }
                // The notes.
                ForEach(Array(model.notes.enumerated()), id: \.offset) { index, note in
                    let row = register.upperBound - note.pitch.midi
                    let isGhost = note.velocity < 56
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isGhost ? Design.Palette.accent.opacity(0.35) : Design.Palette.accent.opacity(0.85))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Design.Palette.accent, lineWidth: Design.Metric.hairline))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Design.Palette.panel.opacity(0.6)).frame(width: 3)
                        }
                        .frame(width: max(6, CGFloat(note.duration) * beatWidth - 1), height: max(4, rowHeight - 1))
                        .offset(x: Self.labelWidth + CGFloat(note.start) * beatWidth, y: CGFloat(row) * rowHeight)
                        .onTapGesture(count: 2) { model.deleteNote(at: index) }
                        .onTapGesture { model.audition(note) }
                        .gesture(noteDrag(index: index, note: note, beatWidth: beatWidth, rowHeight: rowHeight))
                        .help("\(note.pitch.name()) · beat \(String(format: "%.2f", note.start + 1)) · \(String(format: "%.2f", note.duration)) beats")
                }
            }
        }
    }

    private func noteDrag(index: Int, note: NoteEvent, beatWidth: CGFloat, rowHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if drag == nil {
                    let noteWidth = CGFloat(note.duration) * beatWidth
                    drag = Drag(index: index, originalStart: note.start, originalPitch: note.pitch.midi,
                                originalDuration: note.duration, resizing: value.startLocation.x > noteWidth - 8)
                }
                guard let d = drag else { return }
                if d.resizing {
                    model.resizeNote(at: d.index, toDuration: d.originalDuration + Double(value.translation.width / beatWidth))
                } else {
                    let start = d.originalStart + Double(value.translation.width / beatWidth)
                    let pitch = d.originalPitch - Int((value.translation.height / rowHeight).rounded())
                    model.moveNote(at: d.index, toStart: start, pitch: pitch)
                }
            }
            .onEnded { _ in drag = nil }
    }
}

/// The surface's own chip: the Sound surface's, so a lever reads the same on every surface.
private struct RollChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    init(_ title: String, isOn: Bool, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

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

private struct RollLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(Design.Palette.inkTertiary)
    }
}
