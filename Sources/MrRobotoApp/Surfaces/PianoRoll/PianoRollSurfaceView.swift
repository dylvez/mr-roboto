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
            // The lane fills whatever is left when everything fits, the lane counted at its floor:
            // every row of the register at the smallest row it draws. When it does not — a bench
            // at the window's smallest, the Bassist with a lot to say — the work scrolls under the
            // title and the keep line stays in view; it used to push the keep line off the bench.
            ViewThatFits(in: .vertical) {
                work(laneFills: true)
                ScrollsInside { work(laneFills: false) }
            }
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private func work(laneFills: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            levers
            lengthRow
            if !model.tuneWays.isEmpty { waysRow }
            // Where the work scrolls, the lane is drawn at its floor (`NoteLaneLayout.minimumHeight`).
            // A fixed 240 for the lane and its caption together ran a tune's lowest rows under the kicks.
            if laneFills {
                NoteLane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NoteLane(model: model, fills: false)
                    .frame(maxWidth: .infinity)
            }
            readings
        }
    }

    private var header: some View {
        // The card above carries the roll's title, and follows it; this row is what it writes.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // What this roll is writing. The same grid either way.
            SegmentedChoice(options: PianoRollModel.Mode.allCases, selection: model.mode, title: \.title) { model.setMode($0) }
            // In melody mode the primer, behind the `?`, says how a tune is drawn.
            if model.mode == .melody {
                EmptyView()
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
                // The primer and the lane's own caption both say this; Studio says it once.
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

    /// The writer's levers. They wrap onto a second line on a narrow bench rather than running off
    /// its edge: a row wider than the bench is what used to push the frame's own columns aside.
    private var bassLevers: some View {
        FlowRow(spacing: 18, lineSpacing: 12) {
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
                // Played by hand, then programmed: sixteen chips in one row was a wall.
                ForEach(BassVoiceSpec.Family.allCases, id: \.self) { family in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(family == .played ? "Played" : "Synth")
                            .font(Design.Typography.ui(10.5, weight: .medium))
                            .foregroundStyle(Design.Palette.inkTertiary)
                            .frame(width: 56, alignment: .leading)
                        FlowRow(spacing: 4) {
                            ForEach(BassVoiceSpec.all.filter { $0.family == family }) { voice in
                                RollChip(voice.name, isOn: model.sound == voice.id) { model.setSound(voice.id) }
                                    .help(voice.summary)
                            }
                        }
                    }
                }
                // Recordings brought in from SFZ packs, played as the bass.
                let imported = model.importedSounds
                if !imported.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Imported")
                            .font(Design.Typography.ui(10.5, weight: .medium))
                            .foregroundStyle(Design.Palette.inkTertiary)
                            .frame(width: 56, alignment: .leading)
                        FlowRow(spacing: 4) {
                            ForEach(imported) { voice in
                                RollChip(voice.name, isOn: model.sound == voice.id) { model.setSound(voice.id) }
                                    .help(voice.summary)
                            }
                        }
                    }
                }
                if let voice = BassVoiceSpec.resolve(id: model.sound), !voice.summary.isEmpty {
                    Text(voice.summary)
                        .font(Design.Typography.ui(11))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How long the line is, in bars, and the one-press way to make a phrase of an idea. The same
    /// in both modes: a tune is as free of the groove's length as a bass line is.
    private var lengthRow: some View {
        HStack(alignment: .center, spacing: 10) {
            RollLabel("Length")
            HStack(spacing: 4) {
                ForEach(lengthOptions, id: \.self) { bars in
                    RollChip("\(bars)", isOn: model.lengthInBars == bars) { model.setLength(bars) }
                        .help(lengthHelp(bars))
                        .accessibilityLabel("\(bars) bar\(bars == 1 ? "" : "s")")
                }
            }
            Text(model.lengthInBars == 1 ? "bar" : "bars")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
            RollChip("Double", isOn: false) { model.double() }
                .disabled(!model.canDouble)
                .opacity(model.canDouble ? 1 : 0.4)
                .help(model.canDouble
                      ? "Copy the line into as many bars again after it: \(model.lengthInBars) becomes \(model.lengthInBars * 2)"
                      : "The roll stops at \(PianoRollModel.longestLine) bars")
                .accessibilityLabel("Double the line")
            RollChip("Tighten", isOn: false) { model.tighten() }
                .disabled(!model.canTighten)
                .opacity(model.canTighten ? 1 : 0.4)
                .help(tightenHelp)
                .accessibilityLabel("Tighten the line to the grid")
            if let groove = model.groove, groove.bars != model.lengthInBars {
                Text(model.lengthInBars > groove.bars
                     ? "The groove is \(groove.bars) bar\(groove.bars == 1 ? "" : "s"); its kick repeats under every bar of the line."
                     : "Shorter than the groove's \(groove.bars) bars: the line repeats inside it.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The tune played another way without being written again: what the Melodist's "nothing of
    /// its own" points at.
    private var waysRow: some View {
        HStack(alignment: .center, spacing: 10) {
            RollLabel("Another way")
            HStack(spacing: 4) {
                ForEach(model.tuneWays, id: \.self) { treatment in
                    RollChip(Develop.tuneTitle(treatment, twice: true), isOn: false) { model.play(as: treatment) }
                        .help(treatment.about.prefix(1).uppercased() + treatment.about.dropFirst() + ". ⌘Z puts it back.")
                        .accessibilityLabel("Another way: \(treatment.word)")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var tightenHelp: String {
        if model.writesFromLevers && !model.isHandEdited {
            return "The writer's line sits where the levers put it. Tighten is for a line you played or drew."
        }
        guard model.canTighten else { return "Every note is already on the sixteenth grid" }
        let lag = model.mode == .bass && model.lagMS != 0 ? String(format: ", %+.0f ms behind it as the lever says", model.lagMS) : ""
        return "Every note onto the nearest sixteenth\(lag); ends on the grid too. ⌘Z puts the feel back."
    }

    /// The choices, with a length the line arrived with shown too when it is not one of them.
    private var lengthOptions: [Int] {
        var options = PianoRollModel.lengthChoices
        if !options.contains(model.lengthInBars) { options.append(model.lengthInBars); options.sort() }
        return options
    }

    private func lengthHelp(_ bars: Int) -> String {
        if bars < model.lengthInBars {
            return "Make the line \(bars) bar\(bars == 1 ? "" : "s") long. Notes past the end go; ⌘Z brings them back."
        }
        if model.writesFromLevers && !model.isHandEdited && model.groove != nil {
            return "Make the line \(bars) bar\(bars == 1 ? "" : "s") long; the writer writes all of it"
        }
        return "Make the line \(bars) bar\(bars == 1 ? "" : "s") long; the new bars start empty"
    }

    @ViewBuilder
    private var readings: some View {
        // The panel belongs to whoever reads this mode. In melody mode that is nobody, and an
        // empty Bassist panel saying "nothing to read" reads as a fault rather than as a gap.
        personaReadings(model.readingPersona)
    }

    private func personaReadings(_ persona: String) -> some View {
        let hue = MemberHue.color(forPersona: persona)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: persona) { MemberEmblem(name: emblem, hue: hue, width: 18) }
                SmallLabel("The \(persona)", color: hue ?? Design.Palette.inkTertiary)
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
                        .foregroundStyle(reading.holds ? (hue == nil ? Design.Palette.inkTertiary : Design.Palette.ok) : Design.Palette.warn)
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
        HStack(spacing: 10) {
            model.statusBar
            if !model.isTouched, model.base == nil, !model.notes.isEmpty {
                // The writer's draft is a proposal: play it, change it, or take it as it is.
                Text("Not in the song until you touch it.")
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                FrameButton(title: "Add to song", emphasis: .accent) { model.useThisLine() }
                    .help("Put the line as written into the song. Any edit or lever does the same.")
            } else {
                Text(model.isHandEdited ? "Edited by hand" : "As written")
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
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
        Button(action: action) {
            // The one primary action, filled with the accent.
            StudioChip(tone: .primary) { ChipText("Keep as a new version", isOn: true, size: 12) }
        }
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
        .foregroundStyle(Design.Palette.emphasis)
        .help("Kept as \(PartLabel.title(of: version))")
        .accessibilityLabel("Kept as \(PartLabel.title(of: version))")
    }
}

// MARK: - The lane

/// The notes over the bar, with the kicks under them. Beats across, pitches down (high at the
/// top). Drag a note to move it, its right edge to lengthen it; click a note to select it and
/// Delete removes it (double-click does too); click an empty cell to add.
struct NoteLane: View {
    @Bindable var model: PianoRollModel
    /// Whether the lane takes whatever height the surface has spare. Where the work scrolls it does
    /// not, and the lane is drawn at its floor.
    var fills = true

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
            return "\(note.pitch.name()) at \(place(of: note)) selected — Delete removes it, Escape clears the selection. Drag to move, drag the right edge to lengthen."
        }
        return "Click a note to select it; Delete or a double-click removes it. Drag to move, drag the right edge to lengthen; click an empty cell to add a note."
    }

    private var lane: some View {
        // Never shorter than every row of the register at the smallest row the lane draws, with
        // the kicks under them. Squeezed below that, the lowest pitches went under the kick lane.
        let floor = NoteLaneLayout.minimumHeight(rows: model.register.count)
        return GeometryReader { geometry in
            let register = model.register
            let layout = NoteLaneLayout(size: geometry.size, rows: register.count, beats: model.totalBeats)

            HStack(alignment: .top, spacing: 0) {
                labels(register: register, layout: layout)
                    .frame(width: NoteLaneLayout.labelWidth, height: layout.height, alignment: .topLeading)
                let content = grid(register: register, layout: layout)
                    .frame(width: layout.gridWidth, height: layout.height, alignment: .topLeading)
                // Only a line that overflows gets a scroll view: a bar or two fits, and a
                // scroll view around it would be one more thing between a click and its note.
                if layout.scrolls {
                    ScrollView(.horizontal, showsIndicators: true) { content }
                        .frame(width: layout.visibleWidth, height: layout.height)
                } else {
                    content
                }
            }
        }
        .frame(minHeight: floor, idealHeight: floor, maxHeight: fills ? .infinity : floor)
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

    /// The pitch names down the left, which stay put while a long line scrolls under them.
    private func labels(register: ClosedRange<Int>, layout: NoteLaneLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(register.reversed().enumerated()), id: \.element) { row, midi in
                if midi % 12 == 0 {
                    Text(Pitch(midi: midi).name())
                        .font(Design.Typography.numeric(9))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .frame(width: NoteLaneLayout.labelWidth - 4, height: NoteLaneLayout.labelHeight, alignment: .trailing)
                        .offset(y: layout.labelTop(ofRow: row))
                }
            }
            Text("kick")
                .font(Design.Typography.numeric(9))
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: NoteLaneLayout.labelWidth - 4, height: NoteLaneLayout.labelHeight, alignment: .trailing)
                .offset(y: layout.kickLabelTop)
        }
    }

    /// The rows, the bars, the chords, the kicks and the notes, across the whole line.
    private func grid(register: ClosedRange<Int>, layout: NoteLaneLayout) -> some View {
        let chords = HarmonyMap(chords: model.chords, totalBeats: model.totalBeats)
        return ZStack(alignment: .topLeading) {
            // Rows: the register, black keys shaded, a line over every C.
            ForEach(Array(register.reversed().enumerated()), id: \.element) { row, midi in
                let isBlack = [1, 3, 6, 8, 10].contains(midi % 12)
                let isC = midi % 12 == 0
                Rectangle()
                    .fill(isBlack ? Design.Palette.panelAlt : Design.Palette.panel)
                    .frame(width: layout.gridWidth, height: layout.rowHeight)
                    .overlay(alignment: .top) {
                        if isC { Rectangle().fill(Design.Palette.lineStrong).frame(height: Design.Metric.hairline) }
                    }
                    .offset(y: layout.top(ofRow: row))
            }
            // Each chord lays its colour faintly down the lane while it lasts, so where the harmony
            // moves under the line can be seen without reading the names.
            ForEach(chords.spans.indices, id: \.self) { i in
                let span = chords.spans[i]
                if let hue = HarmonyHue.color(for: span.chord, in: model.key) {
                    LinearGradient(colors: [hue.opacity(0.11), hue.opacity(0.035)], startPoint: .top, endPoint: .bottom)
                        .frame(width: max(1, CGFloat(span.end - span.start) * layout.beatWidth), height: layout.rowsHeight)
                        .offset(x: CGFloat(span.start) * layout.beatWidth)
                        .allowsHitTesting(false)
                }
            }
            // Beat lines, the bar lines heavier and numbered, so bar nine of a long line is findable
            // once the lane has scrolled; the chord's name over each change.
            ForEach(0..<Int(model.totalBeats), id: \.self) { beat in
                let isBar = beat % model.beatsPerBar == 0
                Rectangle()
                    .fill(isBar ? Design.Palette.lineStrong : Design.Palette.line)
                    .frame(width: Design.Metric.hairline, height: layout.rowsHeight)
                    .offset(x: CGFloat(beat) * layout.beatWidth)
            }
            if model.bars > 1 {
                ForEach(0..<model.bars, id: \.self) { bar in
                    Text("\(bar + 1)")
                        .font(Design.Typography.numeric(9))
                        .foregroundStyle(Design.Palette.inkTertiary)
                        .offset(x: CGFloat(bar * model.beatsPerBar) * layout.beatWidth + 3, y: layout.rowsHeight - 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            ForEach(chords.spans.indices, id: \.self) { i in
                let span = chords.spans[i]
                let hue = HarmonyHue.color(for: span.chord, in: model.key)
                let symbol = model.symbol(of: span.chord)
                if let hue, let words = HarmonyHue.color(for: span.chord, in: model.key, .ink) {
                    // The chord as a band across the top in its step's colour, its name on it.
                    Text(symbol)
                        .font(Design.Typography.ui(10.5, weight: .semibold))
                        .foregroundStyle(words)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .frame(width: max(1, CGFloat(span.end - span.start) * layout.beatWidth - 2), height: 15, alignment: .leading)
                        .background(Design.Palette.wash(hue, 0.2), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(alignment: .top) {
                            Rectangle().fill(hue).frame(height: 2)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .offset(x: CGFloat(span.start) * layout.beatWidth + 1, y: 1)
                        .allowsHitTesting(false)
                } else {
                    Text(symbol)
                        .font(Design.Typography.ui(10.5, weight: .medium))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .offset(x: CGFloat(span.start) * layout.beatWidth + 3, y: 1)
                }
            }
            // Kick lane: the groove's kicks repeated across the whole line, as the song plays them.
            // It starts under the lowest row, never over it. The kicks are the kick's own red, as the
            // Grid paints it.
            Rectangle()
                .fill(Design.Palette.panelAlt)
                .frame(width: layout.gridWidth, height: NoteLaneLayout.kickLaneHeight)
                .offset(y: layout.kickLaneTop)
            ForEach(model.kickBeats, id: \.self) { beat in
                RoundedRectangle(cornerRadius: 1)
                    .fill(LaneClass.kick.color)
                    .frame(width: 3, height: NoteLaneLayout.kickLaneHeight - 6)
                    .shadow(color: LaneClass.kick.color.opacity(0.6), radius: 3)
                    .offset(x: CGFloat(beat) * layout.beatWidth - 1, y: layout.kickLaneTop + 3)
            }
            // Empty-cell clicks add a note, on the pitch whose row is under the pointer.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: layout.gridWidth, height: layout.rowsHeight)
                .onTapGesture { location in
                    isFocused = true
                    let beat = Double(location.x / layout.beatWidth)
                    let midi = register.upperBound - layout.row(atY: location.y)
                    model.addNote(pitch: midi, at: beat)
                }
            // The notes. The selected one is outlined in ink so it reads apart from its
            // neighbours, not only by a shade of the accent. A note on the chord under it is lit and
            // glows; one between the chord's notes is drawn hollow, so what the Melodist counts as
            // "on the chord" is there to be seen.
            ForEach(Array(model.notes.enumerated()), id: \.offset) { index, note in
                let row = register.upperBound - note.pitch.midi
                let isGhost = note.velocity < 56
                let isSelected = model.selectedNote == index
                let onChord = chords.chord(at: note.start + 0.001).pitchClasses.contains(note.pitch.pitchClass)
                let lit = onChord
                RoundedRectangle(cornerRadius: 2)
                    .fill(Design.Palette.accent.opacity(isGhost ? (lit ? 0.35 : 0.14) : (lit ? 0.95 : 0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? Design.Palette.ink : Design.Palette.accent,
                                      lineWidth: isSelected ? 2 : (lit ? Design.Metric.hairline : 1.2)))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Design.Palette.panel.opacity(0.6)).frame(width: 3)
                    }
                    .shadow(color: lit && !isGhost ? Design.Palette.accent.opacity(0.55) : .clear, radius: 4)
                    .frame(width: max(6, CGFloat(note.duration) * layout.beatWidth - 1), height: max(4, layout.rowHeight - 1))
                    .offset(x: CGFloat(note.start) * layout.beatWidth, y: layout.top(ofRow: row))
                    .onTapGesture(count: 2) { model.deleteNote(at: index) }
                    .onTapGesture {
                        isFocused = true
                        model.select(index)
                        model.audition(note)
                    }
                    .gesture(noteDrag(index: index, note: note, beatWidth: layout.beatWidth, rowHeight: layout.rowHeight))
                    .help("\(note.pitch.name()) · \(place(of: note)) · \(String(format: "%.2f", note.duration)) beats · click to select, Delete to remove")
                    .accessibilityLabel("\(note.pitch.name()) at \(place(of: note))\(isSelected ? ", selected" : "")")
            }
        }
    }

    /// Where a note starts, as a player counts: "bar 3, beat 2.50". A line longer than a bar
    /// named only by its beat — beat 27.50 — is a sum to do before you know where you are.
    private func place(of note: NoteEvent) -> String {
        let perBar = Double(model.beatsPerBar)
        let bar = Int(note.start / perBar)
        let beat = note.start - Double(bar) * perBar
        return "bar \(bar + 1), beat \(String(format: "%.2f", beat + 1))"
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
            StudioChip(isOn: isOn) { ChipText(title, isOn: isOn, size: 11.5) }
        }
        .buttonStyle(.plain)
    }
}

private struct RollLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        SmallLabel(text, color: Design.Palette.inkTertiary)
    }
}
