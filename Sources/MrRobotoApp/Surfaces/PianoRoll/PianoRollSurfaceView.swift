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
            // What this roll is writing. The same grid either way.
            HStack(spacing: 4) {
                ForEach(PianoRollModel.Mode.allCases, id: \.self) { mode in
                    RollChip(mode.title, isOn: model.mode == mode) { model.setMode(mode) }
                }
            }
            if model.mode == .melody {
                Text("Drawn by hand: nothing in the band writes a tune yet.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
            } else if model.groove == nil {
                Text("No groove yet — the line plays to the bar on its own. Open the Grid to paint one and this roll will sit under it.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.usesDefaultChords {
                Text("No chords stated — written to the key's I–IV–V–I.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            // The line plays from the surface's header, where every surface's play control is.
            Spacer()
        }
    }

    /// The writer's levers in bass mode; in melody mode nothing writes, so the row is the instrument
    /// and a line saying how a tune is drawn.
    @ViewBuilder
    private var levers: some View {
        if model.mode == .melody {
            HStack(alignment: .top, spacing: 18) {
                InstrumentPicker(selected: model.instrument) { model.setInstrument($0) }
                Text("Click an empty cell to add a note; drag to move; double-click to delete.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                bassLevers
                if model.leversAreHeld { heldLeversNote }
            }
        }
    }

    /// The line's hand edits are the user's. The levers keep moving — they describe the line you
    /// would get — but they do not write over the edits until this chip is pressed. The same rule
    /// the Chop lane applies to its sensitivity slider, made a step rather than a warning.
    private var heldLeversNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Design.Palette.warn)
            Text("Edited by hand. The levers would rewrite the whole line and drop those edits, so they are held until you say so.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
            RollChip("Rewrite anyway", isOn: false) { model.writeOverHandEdits() }
                .help("Replace the hand-edited line with one written from the levers as they stand")
                .accessibilityLabel("Rewrite the line from the levers, dropping the hand edits")
        }
    }

    private var bassLevers: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Hands")
                HStack(spacing: 4) {
                    ForEach(BassLineage.allCases, id: \.self) { lineage in
                        RollChip(lineage.name, isOn: model.lineage == lineage) { model.setLineage(lineage) }
                            .help("Write the line the way \(lineage.name) would")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                RollLabel("Behind the kick")
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.lagMS }, set: { model.setLag($0) }), in: -25...90)
                        .frame(width: 160)
                        .tint(Design.Palette.accent)
                        .help("How far the bass lands behind the kick, in milliseconds")
                        .accessibilityLabel("Lag behind the kick")
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
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.density }, set: { model.setDensity($0) }), in: 0...1)
                        .frame(width: 120)
                        .tint(Design.Palette.accent)
                        .help("How many attacks a bar the writer allows itself: sparse at the left, the lineage's ceiling at the right")
                        .accessibilityLabel("Density")
                    Text(String(format: "%.0f%%", model.density * 100))
                        .font(Design.Typography.numeric(12))
                        .frame(width: 38, alignment: .leading)
                }
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

    @ViewBuilder
    private var readings: some View {
        // The panel belongs to whoever reads this mode. In melody mode that is nobody, and an
        // empty Bassist panel saying "nothing to read" reads as a fault rather than as a gap.
        personaReadings(model.readingPersona)
    }

    private func personaReadings(_ persona: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: persona) { ArtImage(emblem, width: 18) }
                RollLabel("The \(persona)")
            }
            if model.readings.isEmpty {
                Text(model.mode == .melody ? "Two notes and I'll read the shape." : "Nothing to read without a groove under it.")
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
            if let kept = model.lastKept, !model.hasUnkeptChanges {
                KeptNote(version: kept)
            } else {
                Text(model.isHandEdited ? "Edited by hand" : "As written")
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            KeepButton(isEnabled: !model.notes.isEmpty && model.hasUnkeptChanges) { model.commit() }
        }
    }
}

// MARK: - The keep control and its answer

/// "Keep as a new version", as every editing surface offers it: greyed until something has
/// changed since the last keep, so pressing it twice cannot file the same thing twice.
struct KeepButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button("Keep as a new version", action: action)
            .buttonStyle(.plain)
            .font(Design.Typography.ui(12, weight: .semibold))
            .foregroundStyle(Design.Palette.accent)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .help(isEnabled ? "File what is on the surface as a new version of this part"
                            : "Nothing has changed since the last version was kept")
    }
}

/// What the footer says once a keep has landed and nothing has moved since: the version, by the
/// name the ledger will show it under.
struct KeptNote: View {
    let version: PartVersion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("Kept")
                .font(Design.Typography.ui(11.5, weight: .medium))
        }
        .foregroundStyle(Design.Palette.accent)
        .help("Kept as \(PartLabel.title(of: version))")
        .accessibilityLabel("Kept as \(PartLabel.title(of: version))")
    }
}

// MARK: - The lane

/// The notes over the bar, with the kicks under them. Beats across, pitches down (high at the
/// top). Drag a note to move it, its right edge to lengthen it; click a note to select it and
/// Delete removes it (double-click does too); click an empty cell to add.
private struct NoteLane: View {
    @Bindable var model: PianoRollModel

    static let labelWidth: CGFloat = 34
    static let kickLaneHeight: CGFloat = 18
    static let minimumRowHeight: CGFloat = 9

    @State private var drag: Drag?
    /// The lane takes keyboard focus on a click so Delete and Escape reach it. Without focus the
    /// keys go to whatever had it last, which is usually a text field on another surface.
    @FocusState private var isFocused: Bool

    private struct Drag {
        var index: Int
        var originalStart: Double
        var originalPitch: Int
        var originalDuration: Double
        var resizing: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            lane
            Text(caption)
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says what the gestures do, because none of them is labelled. The selected note is named so
    /// Delete is never a guess about what it will remove.
    private var caption: String {
        if let index = model.selectedNote, model.notes.indices.contains(index) {
            let note = model.notes[index]
            return "\(note.pitch.name()) at beat \(String(format: "%.2f", note.start + 1)) selected — Delete removes it, Escape clears the selection. Drag to move, drag the right edge to lengthen."
        }
        return "Click a note to select it; Delete or a double-click removes it. Drag to move, drag the right edge to lengthen; click an empty cell to add a note."
    }

    private var lane: some View {
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
                        isFocused = true
                        let beat = Double((location.x - Self.labelWidth) / beatWidth)
                        let row = Int(location.y / rowHeight)
                        let midi = register.upperBound - row
                        model.addNote(pitch: midi, at: beat)
                    }
                // The notes. The selected one is outlined in ink so it reads apart from its
                // neighbours in any theme, not only by a shade of the accent.
                ForEach(Array(model.notes.enumerated()), id: \.offset) { index, note in
                    let row = register.upperBound - note.pitch.midi
                    let isGhost = note.velocity < 56
                    let isSelected = model.selectedNote == index
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isGhost ? Design.Palette.accent.opacity(0.35) : Design.Palette.accent.opacity(0.85))
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(isSelected ? Design.Palette.ink : Design.Palette.accent,
                                          lineWidth: isSelected ? 2 : Design.Metric.hairline))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(Design.Palette.panel.opacity(0.6)).frame(width: 3)
                        }
                        .frame(width: max(6, CGFloat(note.duration) * beatWidth - 1), height: max(4, rowHeight - 1))
                        .offset(x: Self.labelWidth + CGFloat(note.start) * beatWidth, y: CGFloat(row) * rowHeight)
                        .onTapGesture(count: 2) { model.deleteNote(at: index) }
                        .onTapGesture {
                            isFocused = true
                            model.select(index)
                            model.audition(note)
                        }
                        .gesture(noteDrag(index: index, note: note, beatWidth: beatWidth, rowHeight: rowHeight))
                        .help("\(note.pitch.name()) · beat \(String(format: "%.2f", note.start + 1)) · \(String(format: "%.2f", note.duration)) beats · click to select, Delete to remove")
                        .accessibilityLabel("\(note.pitch.name()) at beat \(String(format: "%.2f", note.start + 1))\(isSelected ? ", selected" : "")")
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.delete) { model.deleteSelectedNote(); return .handled }
        .onKeyPress(.deleteForward) { model.deleteSelectedNote(); return .handled }
        .onKeyPress(.escape) {
            guard model.selectedNote != nil else { return .ignored }
            model.clearSelection()
            return .handled
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
