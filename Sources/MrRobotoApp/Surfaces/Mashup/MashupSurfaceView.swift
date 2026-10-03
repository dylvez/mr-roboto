import Performance
import SongGraph
import SwiftUI

/// Two songs side by side, the stems each gives, whose grid they meet on, and the plan in
/// sentences. Preview is eight bars; Make is the whole thing as a new song.
struct MashupSurfaceView: View {
    @Bindable var model: MashupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                side(.a)
                side(.b)
            }
            meeting
            planLines
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Mashup").font(Design.Typography.prose(16, weight: .medium))
            Text(model.plan.map { plan in
                "\(plan.target.key?.name ?? "no key") · \(Int((plan.target.tempo ?? 0).rounded())) bpm · \(plan.lengthInBars) bars · \(model.chosenCount) of \(Mashups.maximumStems) stems"
            } ?? "two songs from the library, on one grid")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
        }
    }

    // MARK: A side

    private func side(_ side: MashupModel.Side) -> some View {
        let song = model.song(side)
        let source = model.source(side)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BoothLabel(side == .a ? "Song A" : "Song B")
                if model.backbone == side {
                    Text("SETS THE TEMPO").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.accent)
                        .help("Both songs meet on this one's tempo and bars")
                }
            }
            Picker("Song", selection: Binding(get: { (side == .a ? model.a : model.b)?.description ?? "" },
                                              set: { id in
                                                  let chosen = model.candidates.first { $0.id.description == id }?.id
                                                  if side == .a { model.a = chosen } else { model.b = chosen }
                                              })) {
                Text("Choose a song…").tag("")
                ForEach(model.candidates) { candidate in Text(candidate.title).tag(candidate.id.description) }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
            // Choosing a song picks its stems afresh and drops the nudges. That is `chooseDefaults`,
            // and it is right — the picks were for another song — but it happens without a word.
            .help("Which song this side is. Choosing another picks its stems afresh and forgets any nudge by ear.")

            if let song, let source {
                Text("\(source.key?.name ?? "no key") · \(Int((source.tempo ?? song.tempo).rounded())) bpm · \(StructureModel.clock(source.duration)) · first downbeat at \(String(format: "%.2f", source.firstDownbeat)) s")
                    .font(Design.Typography.numeric(11.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                FlowRow(spacing: 6) {
                    ForEach(model.available(side), id: \.self) { stem in
                        BoothChip(stem == Mashups.full ? "Full record" : stem.capitalized, isOn: model.stems(side).contains(stem)) { model.toggle(stem, on: side) }
                            .help(stem == Mashups.full ? "The whole record, in place of its stems" : "The \(stem) stem on its own")
                    }
                }
                if model.available(side) == [Mashups.full] {
                    Text("No stems yet, so this side can only give the whole record. Separate the stems on this song's Record surface to take the voice or the drums alone.")
                        .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("−") { model.nudge(side, by: -1) }
                        .help("A semitone down, by ear, from where the key arithmetic put it")
                        .accessibilityLabel("Down a semitone")
                    Text(semitoneLine(side)).font(Design.Typography.numeric(11.5)).lineLimit(1).fixedSize().frame(minWidth: 170, alignment: .leading)
                    Button("+") { model.nudge(side, by: 1) }
                        .help("A semitone up, by ear, from where the key arithmetic put it")
                        .accessibilityLabel("Up a semitone")
                    if model.semitones(side) != nil {
                        Button("By the key") { model.resetSemitones(side) }
                            .help("Back to what the key arithmetic chose, forgetting the nudge")
                    }
                    Spacer()
                    if model.backbone != side {
                        Button("Use this song's tempo") { model.setBackbone(side) }
                            .help("Put both songs on \(song.title)'s tempo and bars. The stem picks, the nudges and the bar shift start over for the new grid.")
                    }
                }
                .font(Design.Typography.ui(12))
                .controlSize(.small)
            } else if model.candidates.isEmpty {
                Text("No song in the library has been analysed yet. Import two records first; each becomes a song that knows its bars and key.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import a Record…") { model.importRecord() }
                    .font(Design.Typography.ui(12))
                    .controlSize(.small)
                    .help("File ▸ Flip a Record…: choose an audio file, and the Record surface makes a song of it that knows its bars and key.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
            .stroke(model.backbone == side ? Design.Palette.accent.opacity(0.45) : Design.Palette.line, lineWidth: Design.Metric.hairline))
    }

    private func semitoneLine(_ side: MashupModel.Side) -> String {
        guard let move = model.plan?.move(side) else { return "pitch as it is" }
        let amount = move.semitones == 0 ? "pitch as it is" : String(format: "%+d semitones", move.semitones)
        return model.semitones(side) == nil ? "\(amount), by the key" : "\(amount), by ear"
    }

    // MARK: Where they meet

    /// The shift, clamped on the way in: the stepper cannot leave the range, but a typed number can.
    private var barShift: Binding<Int> {
        Binding(get: { model.barShift }, set: { model.barShift = MashupModel.clampedBarShift($0) })
    }

    private var meeting: some View {
        HStack(spacing: 12) {
            BoothLabel("They meet")
            if Design.isOffscreenRender {
                RenderedStepper { Text(meetLine).font(Design.Typography.ui(12.5)) }
                    .fixedSize()
                RenderedField(text: "\(model.barShift)", placeholder: "bars", font: Design.Typography.numeric(11.5), alignment: .trailing)
                    .frame(width: 56)
            } else {
            Stepper(value: barShift, in: MashupModel.barShiftRange) {
                Text(meetLine).font(Design.Typography.ui(12.5))
            }
            .fixedSize()
            .help("Slide the other song along the grid a bar at a time. Below zero it starts before the grid does.")
            // Typed as well as stepped: sixty-four clicks is no way to reach bar 65.
            TextField("bars", value: barShift, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.numeric(11.5))
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .help("The shift in bars, typed: \(MashupModel.barShiftRange.lowerBound) to \(MashupModel.barShiftRange.upperBound). Return keeps it.")
                .accessibilityLabel("Bar shift")
            }
            Text("bars").font(Design.Typography.ui(11, weight: .regular)).foregroundStyle(Design.Palette.inkTertiary)
            Spacer()
        }
    }

    private var meetLine: String {
        let other = model.song(model.backbone == .a ? .b : .a)?.title ?? "the other song"
        let spine = model.song(model.backbone)?.title ?? "the other song"
        if model.barShift == 0 { return "\(other)'s first bar on \(spine)'s first bar" }
        if model.barShift > 0 { return "\(other)'s first bar on bar \(model.barShift + 1) of \(spine)" }
        return "\(other) starts \(-model.barShift) bar\(model.barShift == -1 ? "" : "s") before \(spine)"
    }

    private var planLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            BoothLabel("The plan")
            if let plan = model.plan {
                ForEach(plan.sentences, id: \.self) { sentence in
                    Text(sentence).font(Design.Typography.prose(13)).foregroundStyle(Design.Palette.ink)
                }
                ForEach(plan.flags, id: \.self) { flag in
                    Text(flag).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                }
            } else {
                Text("Choose two different songs and the plan is written here: what moves, by how much, and where they meet.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
            }
        }
    }

    // MARK: Hear it, make it

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if Design.isOffscreenRender {
                    RenderedField(text: model.title, placeholder: "\(model.song(.a)?.title ?? "A") × \(model.song(.b)?.title ?? "B")")
                        .frame(width: 260)
                    RenderedStepper { Text("from bar \(model.previewBar)").font(Design.Typography.numeric(11.5)) }
                        .fixedSize()
                } else {
                TextField("\(model.song(.a)?.title ?? "A") × \(model.song(.b)?.title ?? "B")", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.Typography.ui(12.5))
                    .frame(width: 260)
                    .help("The new song's title. Empty, it is A × B.")
                Stepper(value: $model.previewBar, in: 1...max(1, model.plan?.lengthInBars ?? 1)) {
                    Text("from bar \(model.previewBar)").font(Design.Typography.numeric(11.5))
                }
                .fixedSize()
                .help("Where the preview starts")
                }
                Button(model.isPreviewing ? "Rendering…" : "Preview 8 Bars") { Task { await model.preview() } }
                    .disabled(model.blocker != nil || model.isPreviewing || model.isMaking)
                    .help("Eight bars from there, through the plan, played now")
                Button("Stop") { model.stopPreview() }
                    .help("Stop the preview")
                Spacer()
                // Says what it does: the whole mashup rendered as a new song, which is then the
                // open song. There is no stopping it once it has started, so the name should
                // not read as a smaller thing than it is.
                FrameButton(title: model.isMaking ? "Making…" : "Make the song and open it", emphasis: .accent,
                            isEnabled: model.blocker == nil && !model.isMaking) {
                    Task { await model.make() }
                }
                .help("Render the whole mashup as a new song in the library and open it in place of the one you have open. It cannot be stopped once started.")
            }
            .font(Design.Typography.ui(12.5))
            if let progress = model.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction).frame(width: 220).tint(Design.Palette.accent)
                    Text(progress.what).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkSecondary)
                }
            }
            Text(model.lastError ?? model.blocker ?? "The new song's stems sit on the grid; mix it, add your own drums or bass, arrange it like any other. Both records stay sources to clear.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(model.lastError != nil ? Design.Palette.warn : Design.Palette.inkTertiary)
        }
    }
}
