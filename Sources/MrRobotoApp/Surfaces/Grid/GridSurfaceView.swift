import AppKit
import Instrument
import Performance
import SongGraph
import SwiftUI

/// The Grid surface: a step grid over a groove, played by the groove engine.
///
/// Two prominent levers and no more: **swing**, in the MPC's own percentage, and **ghost level**.
/// Tempo, the machine and the feel are pickers; the tiers are a segmented brush; the loop's length
/// and its voices are menus beside the things they change; everything else is the grid itself. The
/// Beatmaker reads the groove under it, the way the Bassist reads the line under the Piano roll.
public struct GridSurfaceView: View {
    @Bindable public var model: GridModel

    public init(model: GridModel) {
        self.model = model
    }

    public var body: some View {
        // The grid is the surface, so it is what the panel's spare width and height are spent on:
        // steps across, voice rows down. Everything else keeps the size it was designed at, and the
        // notes under the grid take whatever height is left.
        GeometryReader { geometry in
            let layout = GridLayout(size: geometry.size,
                                    voices: model.voices.count, steps: model.stepCount)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                levers
                StepGrid(model: model, layout: layout)
                GridNotes(model: model, layout: layout)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                pickers(layout)
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SurfaceKind.grid.rawValue.uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Text(model.title)
                    .font(Design.Typography.prose(16, weight: .medium))
                    .lineLimit(1)
            }
            // The loop's length sits by its name: "Motown, 104 · 2 bars" is what the groove is.
            LengthMenu(model: model)
            Spacer(minLength: 8)
            // No Keep button: the groove keeps itself a moment after the last edit. What is shown
            // here is whether it has, and the way back.
            model.statusBar
                .fixedSize()
        }
    }

    // MARK: The two levers

    private var levers: some View {
        HStack(alignment: .top, spacing: 30) {
            SwingLever(model: model)
            GhostLever(model: model)
            Spacer()
        }
    }

    // MARK: Pickers

    /// One row from the default window up. Narrower than that the five controls cannot share a row,
    /// so they take two, and the brush's caption goes into its tooltip to pay for the second.
    @ViewBuilder
    private func pickers(_ layout: GridLayout) -> some View {
        if layout.pickersWrap {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 18) {
                    TierBrush(model: model, showsCaption: false)
                    tempo
                    Spacer(minLength: 0)
                }
                HStack(alignment: .top, spacing: 18) {
                    machine
                    FeelMenu(model: model)
                    ClearControl(model: model)
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 18) {
                TierBrush(model: model, showsCaption: true)
                tempo
                machine
                FeelMenu(model: model)
                ClearControl(model: model)
                Spacer(minLength: 0)
            }
        }
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Tempo")
            HStack(spacing: 6) {
                Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: GridModel.tempoRange)
                    .frame(width: 110)
                    .tint(Design.Palette.accent)
                    .help("The groove's audition tempo: what this grid loops at. The song's own tempo is set from the header.")
                    .accessibilityLabel("Audition tempo")
                Text("\(Int(model.tempo.rounded())) bpm")
                    .font(Design.Typography.numeric(12))
                    .frame(width: 56, alignment: .leading)
            }
        }
    }

    /// The picker's tag for the chop, which is not a machine id.
    private static let chopTag = "chop"

    private var machine: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel(model.chopKit == nil ? "Machine" : "Kit")
            Picker("", selection: Binding(get: { model.playsOnChop ? Self.chopTag : model.machine.id },
                                          set: { id in
                                              if id == Self.chopTag {
                                                  model.playOnChop()
                                              } else if let m = SynthMachine.preset(id: id) {
                                                  model.setMachine(m)
                                              }
                                          })) {
                if let chop = model.chopKit {
                    // "Chop" first: a long bar name is cut at the end, and the kind is what matters.
                    Text("Chop · \(chop.name)").tag(Self.chopTag)
                    Divider()
                }
                ForEach(model.machines) { machine in
                    Text(machine.name).tag(machine.id)
                }
            }
            .labelsHidden()
            .frame(width: model.chopKit == nil ? 120 : 160)
            .font(Design.Typography.ui(12))
            .help(model.chopKit.map { "The kit every step plays on: \($0.name)'s own slices, or a machine" }
                  ?? "The kit every step plays on")
            .accessibilityLabel("Drum kit")
        }
    }
}

// MARK: - Length

/// How many bars the loop is. A menu rather than four chips because it is changed once a groove and
/// then left, and because each choice says what it will do to what is painted.
private struct LengthMenu: View {
    @Bindable var model: GridModel

    var body: some View {
        Menu {
            ForEach(GridModel.lengthChoices, id: \.self) { count in
                Toggle(title(for: count), isOn: Binding(get: { model.bars == count },
                                                        set: { _ in model.setBars(count) }))
            }
            Divider()
            Button(doubleTitle) { model.doubleLength() }
                .disabled(!model.canDoubleLength)
        } label: {
            GridChipLabel(Self.bars(model.bars), trailingSymbol: "chevron.down")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How long the loop is. Longer repeats what is there into the new bars, ready to vary; shorter drops the bars past the end. ⌘Z undoes either.")
        .accessibilityLabel("Length: \(Self.bars(model.bars))")
    }

    static func bars(_ count: Int) -> String { count == 1 ? "1 bar" : "\(count) bars" }

    /// Each length says what choosing it does to the pattern, since both directions change it.
    private func title(for count: Int) -> String {
        let name = Self.bars(count)
        if count > model.bars { return "\(name) — repeats the \(Self.bars(model.bars)) there" }
        if count < model.bars {
            let first = count + 1
            let dropped = first == model.bars ? "bar \(first)" : "bars \(first)–\(model.bars)"
            return "\(name) — drops \(dropped)"
        }
        return name
    }

    private var doubleTitle: String {
        "Double — copy what is here once more (\(Self.bars(model.bars * 2)))"
    }
}

// MARK: - Voices

/// The label column's heading: the voices that are not rows yet. A voice the current machine has no
/// sound for is still offered — another kit may play it — and the item says so.
private struct AddVoiceMenu: View {
    @Bindable var model: GridModel

    var body: some View {
        Menu {
            ForEach(model.addableVoices, id: \.rawValue) { voice in
                Button(title(for: voice)) { model.addVoice(voice) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(Design.Typography.ui(9, weight: .bold))
                Text("Voice")
                    .font(Design.Typography.ui(11, weight: .medium))
            }
            .foregroundStyle(model.addableVoices.isEmpty ? Design.Palette.inkTertiary : Design.Palette.accent)
            .frame(height: GridLayout.rulerHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.addableVoices.isEmpty)
        .help(model.addableVoices.isEmpty
              ? "Every voice is already a row"
              : "Add an empty row for another voice. Right-click a voice's name to clear or remove its row.")
        .accessibilityLabel("Add a voice row")
    }

    private func title(for voice: DrumVoice) -> String {
        let name = GridModel.name(of: voice)
        guard model.machineSounds(voice) else { return "\(name) — the \(model.machine.name) has no sound for it" }
        return name
    }
}

// MARK: - Feel

/// A pocket from the library, loaded outright. It used to ask first and leave a "put back" chip
/// behind; ⌘Z does both now, so the menu simply does what it says.
private struct FeelMenu: View {
    @Bindable var model: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Feel")
            Menu {
                ForEach(model.feelLibrary.feels) { feel in
                    // Choosing the checked feel again loads it again: the way back to it untouched.
                    Toggle(feel.name, isOn: Binding(get: { model.feelName == feel.name },
                                                    set: { _ in model.load(feel) }))
                }
            } label: {
                GridChipLabel(model.feelName ?? "Choose a feel", trailingSymbol: "chevron.down")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("A pocket from the library: its pattern, swing, velocities and tempo, over what is here. ⌘Z puts back what was there.")
            .accessibilityLabel("Feel: \(model.feelName ?? "none")")
        }
    }
}

// MARK: - Clearing

/// Clear everything, as two presses: the first arms, the second does it. ⌘Z would put a pattern
/// back, but a whole pattern is still too much to lose to one click beside the feel menu.
private struct ClearControl: View {
    @Bindable var model: GridModel
    @State private var isArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Clear")
            HStack(spacing: 4) {
                if isArmed {
                    GridChip("Clear every row", emphasis: .warn) {
                        model.clearAll()
                        isArmed = false
                    }
                    .help("Every step becomes a rest. Swing, velocities, machine and tempo stay. ⌘Z puts the steps back.")
                    GridChip("Leave it") { isArmed = false }
                        .help("Leave the pattern as it is")
                } else {
                    GridChip("Clear all") { isArmed = true }
                        .help(model.isPainted ? "Asks once, then clears every row" : "Nothing painted to clear")
                        .disabled(!model.isPainted)
                        .opacity(model.isPainted ? 1 : 0.4)
                }
            }
        }
        // Nothing left to clear — an undo or a feel emptied it — and the question is moot.
        .onChange(of: model.isPainted) { _, painted in if !painted { isArmed = false } }
    }
}

/// The face of the surface's chip, shared by the chips you press and the menus that open from one.
private struct GridChipLabel: View {
    enum Emphasis { case plain, warn }

    let title: String
    var isOn = false
    var emphasis: Emphasis = .plain
    var trailingSymbol: String?

    init(_ title: String, isOn: Bool = false, emphasis: Emphasis = .plain, trailingSymbol: String? = nil) {
        self.title = title
        self.isOn = isOn
        self.emphasis = emphasis
        self.trailingSymbol = trailingSymbol
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn || emphasis == .warn ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(Design.Typography.ui(8, weight: .bold))
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: Design.Metric.chipHeight)
        .background(background, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
            .stroke(border, lineWidth: Design.Metric.hairline))
        .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch emphasis {
        case .warn: return Design.Palette.warn
        case .plain: return isOn ? Design.Palette.accent : Design.Palette.inkSecondary
        }
    }

    private var background: Color {
        switch emphasis {
        case .warn: return Design.Palette.warnSoft
        case .plain: return isOn ? Design.Palette.accentSoft : Design.Palette.panelAlt
        }
    }

    private var border: Color {
        switch emphasis {
        case .warn: return Design.Palette.warn.opacity(0.35)
        case .plain: return isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line
        }
    }
}

/// The surface's own chip, as every surface has one: a lever you press, lit when it is on, in the
/// warn colour when it is the destructive half of a two-step.
private struct GridChip: View {
    let title: String
    var isOn = false
    var emphasis: GridChipLabel.Emphasis = .plain
    let action: () -> Void

    init(_ title: String, isOn: Bool = false, emphasis: GridChipLabel.Emphasis = .plain,
         action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.emphasis = emphasis
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            GridChipLabel(title, isOn: isOn, emphasis: emphasis)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Levers

private struct SwingLever: View {
    @Bindable var model: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GridLabel("Swing")
            HStack(spacing: 10) {
                Slider(value: Binding(get: { model.swingPercent }, set: { model.setSwing(percent: $0) }),
                       in: GridModel.straightPercent...GridModel.maximumPercent)
                    .frame(width: 220)
                    .tint(Design.Palette.accent)
                    .help("How late the second sixteenth of each pair lands, as the MPC counts it: 50 % straight, 66.67 % triplet, 75 % the machines' most")
                    .accessibilityLabel("Swing")
                // The figure every machine quotes. 50 straight, 66.67 triplet, 75 the maximum.
                Text(String(format: "%.4g%%", model.swingPercent))
                    .font(Design.Typography.numeric(14))
                    .frame(width: 58, alignment: .leading)
            }
            HStack(spacing: 8) {
                DetentButton(title: "straight") { model.snapSwingToStraight() }
                    .help("Swing to 50 %: no swing")
                DetentButton(title: "triplet") { model.snapSwingToTriplet() }
                    .help("Swing to 66.67 %: the second sixteenth on the last triplet")
                Text(String(format: "factor %.3f", model.swing.factor))
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }
}

private struct GhostLever: View {
    @Bindable var model: GridModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GridLabel("Ghost level")
            HStack(spacing: 10) {
                Slider(value: Binding(get: { model.ghostLevel }, set: { model.setGhostLevel($0) }), in: 0...1)
                    .frame(width: 180)
                    .tint(Design.Palette.accent)
                    .help("How loud a ghost note is, as a share of a normal hit")
                    .accessibilityLabel("Ghost level")
                Text("\(model.velocities.ghost)")
                    .font(Design.Typography.numeric(14))
                    .frame(width: 34, alignment: .leading)
            }
            Text("ghost \(model.velocities.ghost) · normal \(model.velocities.normal) · accent \(model.velocities.accent)")
                .font(Design.Typography.numeric(10.5))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

private struct DetentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(10.5, weight: .regular))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Design.Palette.panelAlt)
                .foregroundStyle(Design.Palette.inkSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tier brush

private struct TierBrush: View {
    @Bindable var model: GridModel
    /// The gestures, spelled out under the chips. At the window minimum there is no height for it,
    /// and it is the chips' tooltip instead.
    let showsCaption: Bool

    private static let tiers: [VelocityTier] = [.accent, .normal, .ghost]
    private static let gestures = "Click a step to paint it with the brush; click again for a rest. ⌥-click walks normal → accent → ghost → rest; drag to paint a run."

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridLabel("Brush")
            HStack(spacing: 4) {
                ForEach(TierBrush.tiers, id: \.self) { tier in
                    Button { model.brush = tier } label: {
                        Text(tier.rawValue)
                            .font(Design.Typography.ui(11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(model.brush == tier ? Design.Palette.accent : Design.Palette.panelAlt)
                            .foregroundStyle(model.brush == tier ? Design.Palette.panel : Design.Palette.inkSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    }
                    .buttonStyle(.plain)
                    .help(showsCaption ? "Clicks and drags paint \(tier.rawValue) hits"
                                       : "Clicks and drags paint \(tier.rawValue) hits. \(Self.gestures)")
                    .accessibilityLabel("\(tier.rawValue) brush")
                    .accessibilityAddTraits(model.brush == tier ? .isSelected : [])
                }
            }
            // The gestures, since none of them is labelled on the grid itself. Capped in width so
            // it wraps to a height the layout can count on rather than to whatever is left.
            if showsCaption {
                Text(Self.gestures)
                    .font(Design.Typography.ui(10.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }
}

// MARK: - The grid

/// The voice names in a column of their own, and the steps beside them. The names stay put when a
/// long loop scrolls sideways, so a row is never a run of cells with no voice.
private struct StepGrid: View {
    @Bindable var model: GridModel
    let layout: GridLayout

    var body: some View {
        // The rows only scroll at the window minimum with many voices; the steps only scroll once
        // the loop is too long for its cells to keep a hittable width. A scroll view is only built
        // when one is needed.
        verticalScroll {
            HStack(alignment: .top, spacing: GridLayout.stepSpacing) {
                labelColumn
                steps
            }
        }
        .frame(height: layout.gridAreaHeight, alignment: .top)
    }

    @ViewBuilder
    private func verticalScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if layout.gridScrolls {
            ScrollView(.vertical) { content() }
        } else {
            content()
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: GridLayout.rowSpacing) {
            AddVoiceMenu(model: model)
                .frame(width: layout.labelWidth, height: GridLayout.rulerHeight, alignment: .leading)
            ForEach(model.voices, id: \.rawValue) { voice in
                VoiceLabel(model: model, voice: voice, width: layout.labelWidth, height: layout.rowHeight)
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        if layout.stepsScroll {
            ScrollView(.horizontal, showsIndicators: true) {
                stepContent
                    .padding(.bottom, GridLayout.scrollerAllowance)
            }
            .frame(height: layout.gridHeight)
        } else {
            stepContent
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: GridLayout.rowSpacing) {
            ruler
            ForEach(model.voices, id: \.rawValue) { voice in
                StepRow(model: model, voice: voice, layout: layout)
            }
        }
        .frame(width: layout.stepsContentWidth, alignment: .leading)
        .overlay(alignment: .topLeading) { barLines }
    }

    /// Bar numbers where a bar starts, beats between. Left-aligned on the step they count, so "2.3"
    /// can run over the empty steps after it rather than be cut to fit one.
    private var ruler: some View {
        HStack(spacing: GridLayout.stepSpacing) {
            ForEach(Array(0..<model.stepCount), id: \.self) { step in
                let leads = step == 0 || model.startsBar(step: step)
                Text(model.rulerLabel(step: step))
                    .font(Design.Typography.numeric(9, weight: leads ? .semibold : .regular))
                    .foregroundStyle(leads ? Design.Palette.ink : Design.Palette.inkTertiary)
                    .fixedSize()
                    .padding(.leading, 2)
                    .frame(width: layout.stepWidth, height: GridLayout.rulerHeight, alignment: .leading)
            }
        }
    }

    /// A line in the gap before each bar after the first, the ruler's height and every row's. Drawn
    /// over the rows rather than as a cell border, so it is the same line in every row and never
    /// takes a point from a cell.
    private var barLines: some View {
        let height = layout.gridHeight - (layout.stepsScroll ? GridLayout.scrollerAllowance : 0)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: model.stepsPerBar, to: model.stepCount, by: max(1, model.stepsPerBar))),
                    id: \.self) { step in
                Rectangle()
                    .fill(Design.Palette.inkTertiary)
                    .frame(width: GridLayout.stepSpacing, height: height)
                    .offset(x: layout.barLineX(beforeStep: step))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A voice's name: press to hear it, right-click to clear or remove its row. A voice the machine has
/// no sound for says so beside its name, since its hits will paint and keep but play nothing here.
private struct VoiceLabel: View {
    @Bindable var model: GridModel
    let voice: DrumVoice
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let name = GridModel.name(of: voice)
        let sounds = model.machineSounds(voice)
        Button { model.audition(voice) } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(sounds ? Design.Palette.ink : Design.Palette.inkTertiary)
                    .lineLimit(1)
                if !sounds {
                    Image(systemName: "speaker.slash")
                        .font(Design.Typography.ui(9, weight: .medium))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sounds
              ? "Hear the \(name) at the brush's velocity. Right-click to clear the row or remove it."
              : "The \(model.machine.name) has no sound for the \(name): the row paints and keeps, but plays nothing on this machine. Right-click to clear or remove it.")
        .accessibilityLabel(sounds ? "Hear the \(name)" : "\(name), silent on the \(model.machine.name)")
        .contextMenu {
            Button("Clear the \(name) row") { model.clear(voice) }
            Button("Remove the \(name) row") { model.removeVoice(voice) }
                .disabled(!model.canRemoveVoice)
        }
    }
}

/// One voice's steps. A tap paints the brush tier (⌥-tap walks the tiers instead); a drag paints or
/// erases the run it crosses, which is the same gesture every machine with a step grid has had
/// since the MPC60.
private struct StepRow: View {
    @Bindable var model: GridModel
    let voice: DrumVoice
    let layout: GridLayout

    @State private var isPainting = false

    var body: some View {
        let name = GridModel.name(of: voice)
        HStack(spacing: GridLayout.stepSpacing) {
            ForEach(Array(0..<model.stepCount), id: \.self) { step in
                StepCellView(cell: model.cell(voice, step: step),
                             isBeat: step % model.stepsPerBeat == 0,
                             isSwung: model.isSwung(step: step),
                             width: layout.stepWidth,
                             height: layout.rowHeight)
                    .onTapGesture {
                        // A plain click paints what the brush says; ⌥ walks the tiers, which is
                        // what a bare click used to do.
                        if NSEvent.modifierFlags.contains(.option) {
                            model.cycle(voice, step: step)
                        } else {
                            model.toggle(voice, step: step)
                        }
                    }
                    .help("\(name), \(position(of: step)): \(model.tier(voice, step: step).rawValue)")
            }
        }
        .frame(width: layout.stepsContentWidth, height: layout.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(paintGesture)
    }

    /// "step 5", or "bar 2, step 5" once there is more than one bar to be in.
    private func position(of step: Int) -> String {
        let inBar = step % model.stepsPerBar + 1
        guard model.bars > 1 else { return "step \(inBar)" }
        return "bar \(step / model.stepsPerBar + 1), step \(inBar)"
    }

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let step = layout.step(atX: value.location.x) else { return }
                if isPainting {
                    model.continuePaint(voice, step: step)
                } else {
                    // The first cell of the drag decides paint or erase for the whole gesture.
                    let origin = layout.step(atX: value.startLocation.x) ?? step
                    model.beginPaint(voice, step: origin)
                    isPainting = true
                    if step != origin { model.continuePaint(voice, step: step) }
                }
            }
            .onEnded { _ in
                model.endPaint()
                isPainting = false
            }
    }
}

private struct StepCellView: View {
    let cell: GridCell
    let isBeat: Bool
    let isSwung: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Metric.corner)
            .fill(fill)
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .strokeBorder(isBeat ? Design.Palette.lineStrong : Design.Palette.line,
                                  lineWidth: Design.Metric.hairline)
            )
            .overlay(alignment: .bottom) {
                // Swung steps carry a mark, so the lever's effect is visible on the grid and not
                // only in the number beside it.
                if isSwung && cell.tier != .rest {
                    Rectangle()
                        .fill(Design.Palette.accent.opacity(0.8))
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
    }

    /// Each tier reads differently: an accent is solid ink, a normal hit is the accent at two
    /// thirds, a ghost is a whisper. Nothing depends on colour alone.
    private var fill: Color {
        switch cell.tier {
        case .rest: return isBeat ? Design.Palette.panelAlt : Design.Palette.panel
        case .ghost: return Design.Palette.accent.opacity(0.22)
        case .normal: return Design.Palette.accent.opacity(0.62)
        case .accent: return Design.Palette.accent
        }
    }
}

// MARK: - Under the grid

/// What sits between the grid and the pickers: a failure if there is one, the Beatmaker's reading
/// (or, on an empty grid, how to start), and where the loaded feel came from. It takes whatever
/// height the panel has left and scrolls only when that is not enough.
private struct GridNotes: View {
    @Bindable var model: GridModel
    let layout: GridLayout
    /// Held here rather than in the panel, so it survives the switch between fitting and scrolling.
    @State private var showsHolds = false

    var body: some View {
        // Everything if it fits; at the window minimum, one line that still leads with the first
        // flag; and only past that, everything in a scroll.
        ViewThatFits(in: .vertical) {
            notes
            compact
            ScrollView(.vertical) { notes }
        }
    }

    /// A failure outranks the Beatmaker when there is only one line to say anything in.
    @ViewBuilder
    private var compact: some View {
        if let error = model.lastError {
            Text(error)
                .font(Design.Typography.ui(12, weight: .regular))
                .foregroundStyle(Design.Palette.warn)
                .lineLimit(1)
                .help(error)
        } else if model.isPainted {
            BeatmakerLine(model: model)
        } else {
            Text("Nothing painted yet — click a step, or pick a feel below.")
                .font(Design.Typography.ui(12, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.lastError { GridFailureNote(text: error) }
            if model.isPainted {
                BeatmakerReadings(model: model, showsHolds: $showsHolds)
            } else {
                emptyNote
            }
            if let line = model.provenanceLine { ProvenanceLine(text: line) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var emptyNote: some View {
        HStack(spacing: 16) {
            if layout.showsEmptyArt { ArtImage("empty-grid", width: 135, height: GridLayout.emptyArtHeight) }
            Text("Nothing painted yet. Click a step to start, or pick a feel below and it lays a pocket down to edit. The Beatmaker reads the groove here once there is one.")
                .font(Design.Typography.ui(12.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Beatmaker, present on its surface: every rule it fires against the groove on screen, the
/// flags first and in the warn colour, the ones that hold folded away behind a count until asked
/// for. It reads after every edit, so a flag goes the moment the edit that answers it is made.
private struct BeatmakerReadings: View {
    @Bindable var model: GridModel
    @Binding var showsHolds: Bool

    var body: some View {
        let flags = model.flags
        let holds = model.holds
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let emblem = Art.emblem(forPersona: "Beatmaker") { ArtImage(emblem, width: 18) }
                    GridLabel("The Beatmaker")
                }
                .help("The Beatmaker reads the groove on screen after every edit, rule by rule: what is flagged first, then what holds.")
                Text(summary(flags: flags.count))
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(flags.isEmpty ? Design.Palette.inkTertiary : Design.Palette.warn)
                if !holds.isEmpty {
                    Button { showsHolds.toggle() } label: {
                        HStack(spacing: 3) {
                            Text(showsHolds ? "Only the flags" : "\(holds.count) that hold")
                                .font(Design.Typography.ui(11, weight: .medium))
                            Image(systemName: showsHolds ? "chevron.up" : "chevron.down")
                                .font(Design.Typography.ui(8, weight: .bold))
                        }
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsHolds ? "Show only what the Beatmaker flags" : "Show what holds as well as what is flagged")
                    .accessibilityLabel(showsHolds ? "Show only the flags" : "Show the \(holds.count) readings that hold")
                }
            }
            ForEach(flags) { ReadingLine(reading: $0) }
            if showsHolds {
                ForEach(holds) { ReadingLine(reading: $0) }
            }
        }
    }

    private func summary(flags: Int) -> String {
        switch flags {
        case 0: return "Nothing to flag."
        case 1: return "One thing to look at."
        default: return "\(flags) things to look at."
        }
    }
}

/// The Beatmaker in one line, for a panel with room for no more: its name, the first flag cut to
/// the width, and how many more there are. The tooltip holds every flag in full.
private struct BeatmakerLine: View {
    @Bindable var model: GridModel

    var body: some View {
        let flags = model.flags
        HStack(spacing: 6) {
            if let emblem = Art.emblem(forPersona: "Beatmaker") { ArtImage(emblem, width: 16) }
            GridLabel("The Beatmaker")
            if let first = flags.first {
                Image(systemName: "exclamationmark.triangle")
                    .font(Design.Typography.ui(9, weight: .bold))
                    .foregroundStyle(Design.Palette.warn)
                Text(first.says)
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.warn)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if flags.count > 1 {
                    Text("+\(flags.count - 1) more")
                        .font(Design.Typography.ui(11, weight: .medium))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize()
                }
            } else {
                Text("Nothing to flag.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
        .help(flags.isEmpty ? "The Beatmaker has nothing to flag in this groove."
                            : flags.map(\.says).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingLine: View {
    let reading: PersonaReading

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: reading.holds ? "checkmark" : "exclamationmark.triangle")
                .font(Design.Typography.ui(9, weight: .bold))
                .foregroundStyle(reading.holds ? Design.Palette.inkTertiary : Design.Palette.warn)
                .frame(width: 12)
            Text(reading.says)
                .font(Design.Typography.prose(12.5))
                .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((reading.holds ? "Holds: " : "Flag: ") + reading.says)
    }
}

// MARK: - Small pieces

private struct GridLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(Design.Palette.inkTertiary)
    }
}

private struct ProvenanceLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.prose(13))
            .foregroundStyle(Design.Palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GridFailureNote: View {
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
