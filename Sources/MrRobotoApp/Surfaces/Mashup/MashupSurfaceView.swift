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
                    Text("THE GRID").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.accent)
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

            if let song, let source {
                Text("\(source.key?.name ?? "no key") · \(Int((source.tempo ?? song.tempo).rounded())) bpm · \(StructureModel.clock(source.duration)) · first downbeat at \(String(format: "%.2f", source.firstDownbeat)) s")
                    .font(Design.Typography.numeric(11.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                FlowRow(spacing: 6) {
                    ForEach(model.available(side), id: \.self) { stem in
                        BoothChip(stem == Mashups.full ? "Full record" : stem.capitalized, isOn: model.stems(side).contains(stem)) { model.toggle(stem, on: side) }
                    }
                }
                if model.available(side) == [Mashups.full] {
                    Text("No stems yet. Separate them on this song's Record surface to take the voice or the drums alone.")
                        .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                }
                HStack(spacing: 6) {
                    Button("−") { model.nudge(side, by: -1) }
                    Text(semitoneLine(side)).font(Design.Typography.numeric(11.5)).lineLimit(1).fixedSize().frame(minWidth: 170, alignment: .leading)
                    Button("+") { model.nudge(side, by: 1) }
                    if model.semitones(side) != nil { Button("By the key") { model.resetSemitones(side) } }
                    Spacer()
                    if model.backbone != side { Button("Make this the grid") { model.setBackbone(side) } }
                }
                .font(Design.Typography.ui(12))
                .controlSize(.small)
            } else if model.candidates.isEmpty {
                Text("No song in the library has been analysed yet. Import two records first; each becomes a song that knows its bars and key.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
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

    private var meeting: some View {
        HStack(spacing: 12) {
            BoothLabel("They meet")
            Stepper(value: $model.barShift, in: -64...256) {
                Text(meetLine).font(Design.Typography.ui(12.5))
            }
            .fixedSize()
            Spacer()
        }
    }

    private var meetLine: String {
        let other = model.song(model.backbone == .a ? .b : .a)?.title ?? "the other song"
        let spine = model.song(model.backbone)?.title ?? "the grid"
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
                TextField("\(model.song(.a)?.title ?? "A") × \(model.song(.b)?.title ?? "B")", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.Typography.ui(12.5))
                    .frame(width: 260)
                Stepper(value: $model.previewBar, in: 1...max(1, model.plan?.lengthInBars ?? 1)) {
                    Text("from bar \(model.previewBar)").font(Design.Typography.numeric(11.5))
                }
                .fixedSize()
                Button(model.isPreviewing ? "Rendering…" : "Preview 8 Bars") { Task { await model.preview() } }
                    .disabled(model.blocker != nil || model.isPreviewing || model.isMaking)
                Button("Stop") { model.stopPreview() }
                Spacer()
                Button(model.isMaking ? "Making…" : "Make the Song") { Task { await model.make() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.blocker != nil || model.isMaking)
            }
            .font(Design.Typography.ui(12.5))
            if let progress = model.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction).frame(width: 220)
                    Text(progress.what).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkSecondary)
                }
            }
            Text(model.lastError ?? model.blocker ?? "The new song's stems sit on the grid; mix it, add your own drums or bass, arrange it like any other. Both records stay sources to clear.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(model.lastError != nil ? Design.Palette.warn : Design.Palette.inkTertiary)
        }
    }
}
