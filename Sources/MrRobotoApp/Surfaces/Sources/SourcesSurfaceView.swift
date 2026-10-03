import Performance
import SongGraph
import SwiftUI

/// A record from the library on one side, the open song on the other: which stem, all of it or
/// some bars, where it lands, and the plan in sentences. Preview is eight bars against the song;
/// Add renders it into the song. Below, the sources the song already holds, each fitted again in
/// one press.
struct SourcesSurfaceView: View {
    @Bindable var model: SourcesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                picker
                placement
            }
            planLines
            inSong
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        // A section split or removed in Structure, or the open song changed: let go of what went.
        .onChange(of: model.songSections.map(\.id)) { model.follow() }
        .onChange(of: model.song?.id) { model.follow() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Sources").font(Design.Typography.prose(16, weight: .medium))
            Text(model.song.map { song in
                "into \(song.title) · \(song.key?.name ?? "no key") · \(Int(song.tempo.rounded())) bpm · \(model.inSong.count) from other records"
            } ?? "open a song to bring stems into")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
        }
    }

    // MARK: What to take

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoothLabel("From")
            Picker("Song", selection: Binding(get: { model.from?.description ?? "" },
                                              set: { id in model.from = model.candidates.first { $0.id.description == id }?.id })) {
                Text("Choose a song…").tag("")
                ForEach(model.candidates) { candidate in Text(candidate.title).tag(candidate.id.description) }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
            .help("A song in the library that holds a record and its analysis. Choosing another picks its stem afresh.")

            if let line = model.sourceLine {
                Text(line).font(Design.Typography.numeric(11.5)).foregroundStyle(Design.Palette.inkSecondary)
                FlowRow(spacing: 6) {
                    ForEach(model.available, id: \.self) { stem in
                        BoothChip(stem == Mashups.full ? "Full record" : stem.capitalized, isOn: model.stem == stem) { model.choose(stem: stem) }
                            .help(stem == Mashups.full ? "The whole record, as it was imported" : "The \(stem) stem on its own")
                    }
                }
                if model.available == [Mashups.full] {
                    Text("No stems yet, so this song can only give the whole record. Separate its stems on its Record surface to take the voice or the drums alone.")
                        .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.isDrums {
                    HStack(spacing: 6) {
                        Button("−") { model.nudge(by: -1) }
                            .help("A semitone down, by ear, from where the key arithmetic put it")
                            .accessibilityLabel("Down a semitone")
                        Text(semitoneLine).font(Design.Typography.numeric(11.5)).lineLimit(1).fixedSize().frame(minWidth: 150, alignment: .leading)
                        Button("+") { model.nudge(by: 1) }
                            .help("A semitone up, by ear, from where the key arithmetic put it")
                            .accessibilityLabel("Up a semitone")
                        if model.semitones != nil {
                            Button("By the key") { model.resetSemitones() }
                                .help("Back to what the key arithmetic chose")
                        }
                    }
                    .font(Design.Typography.ui(12))
                    .controlSize(.small)
                } else {
                    Text("Drums are stretched to the song's tempo and never pitch-shifted.")
                        .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                }
            } else if model.candidates.isEmpty {
                Text("No other song in the library has been analysed yet. Import a record first; it becomes a song that knows its bars and key, and its stems can be separated there.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
    }

    private var semitoneLine: String {
        guard let semitones = model.plannedSemitones else { return "pitch as it is" }
        let amount = semitones == 0 ? "pitch as it is" : String(format: "%+d semitones", semitones)
        return model.semitones == nil ? "\(amount), by the key" : "\(amount), by ear"
    }

    // MARK: Where it goes

    private var placement: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoothLabel("Into the song")
            HStack(spacing: 6) {
                BoothChip("The whole stem", isOn: !model.isClip) { model.isClip = false }
                    .help("The whole stem runs along the song and plays in the sections you choose.")
                BoothChip("Some bars, looped", isOn: model.isClip) { model.isClip = true }
                    .help("Some bars of the record, fitted to whole bars of the song, looped like a chop from the start of each section that plays them.")
            }

            if model.isClip {
                HStack(spacing: 8) {
                    Text("Bars").font(Design.Typography.ui(12.5))
                    stepper(value: $model.fromBar, in: 1...max(1, model.barsInRecord), label: "\(model.fromBar)")
                    Text("to").font(Design.Typography.ui(12.5))
                    stepper(value: $model.toBar, in: 1...max(1, model.barsInRecord), label: "\(model.toBar)")
                    Text("of \(model.barsInRecord)").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Its bar 1 on bar").font(Design.Typography.ui(12.5))
                    stepper(value: $model.atBar, in: SourcesModel.atBarRange, label: "\(model.atBar)")
                    Text("of the song").font(Design.Typography.ui(12.5))
                }
                .help("Where the record's first bar lands. Zero and below: it is already under way when the song starts.")
            }

            if model.isBlankSong {
                Toggle("The song takes its key and tempo", isOn: $model.takesItsGrid)
                    .toggleStyle(.checkbox)
                    .font(Design.Typography.ui(12))
                    .help("The song has nothing in it yet: it can take this record's key, tempo and form rather than moving the record to its own.")
            } else if model.choosesSections {
                BoothLabel("Plays in")
                FlowRow(spacing: 6) {
                    ForEach(model.songSections) { section in
                        BoothChip(section.name, isOn: model.sections.contains(section.id)) { model.toggle(section.id) }
                            .help("Whether \(section.name) plays it. Structure changes this later, section by section.")
                    }
                }
            } else {
                Text("The song's form names nothing yet, so this plays along with everything else; the form it is given later carries it.")
                    .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
    }

    @ViewBuilder
    private func stepper(value: Binding<Int>, in range: ClosedRange<Int>, label: String) -> some View {
        if Design.isOffscreenRender {
            RenderedStepper { Text(label).font(Design.Typography.numeric(11.5)) }.fixedSize()
        } else {
            Stepper(value: value, in: range) { Text(label).font(Design.Typography.numeric(11.5)).frame(minWidth: 22, alignment: .trailing) }
                .fixedSize()
        }
    }

    private var planLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            BoothLabel("The plan")
            if model.sentences.isEmpty {
                Text(model.unheard ?? "Choose a song and a stem and the plan is written here: what moves, by how much, and where it lands.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
            } else {
                ForEach(model.sentences, id: \.self) { sentence in
                    Text(sentence).font(Design.Typography.prose(13)).foregroundStyle(Design.Palette.ink)
                }
                ForEach(model.flags, id: \.self) { flag in
                    Text(flag).font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.warn)
                }
            }
        }
    }

    // MARK: Already in the song

    @ViewBuilder
    private var inSong: some View {
        if !model.inSong.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                BoothLabel("In this song")
                ForEach(model.inSong) { version in
                    HStack(spacing: 8) {
                        Text(PartLabel.title(of: version)).font(Design.Typography.ui(12.5, weight: .medium)).lineLimit(1)
                        Text(model.line(for: version)).font(Design.Typography.numeric(11)).foregroundStyle(Design.Palette.inkSecondary).lineLimit(1)
                        Spacer()
                        if model.refitting == version.partID {
                            Text("Fitting…").font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
                        }
                        Group {
                            if model.fit(of: version)?.stem != "drums" {
                                Button("−") { Task { await model.refit(version.partID, semitones: -1) } }
                                    .help("Fitted again a semitone down, from the untouched record")
                                    .accessibilityLabel("Fit a semitone down")
                                Button("+") { Task { await model.refit(version.partID, semitones: 1) } }
                                    .help("Fitted again a semitone up, from the untouched record")
                                    .accessibilityLabel("Fit a semitone up")
                            }
                            if model.fit(of: version)?.atBar != nil {
                                Button("◀ bar") { Task { await model.refit(version.partID, bars: -1) } }
                                    .help("Laid a bar earlier")
                                Button("bar ▶") { Task { await model.refit(version.partID, bars: 1) } }
                                    .help("Laid a bar later")
                            }
                            Button("Fit again") { Task { await model.refit(version.partID) } }
                                .help("Fitted again to the song's key and tempo as they are now, from the untouched record")
                        }
                        .disabled(model.refitting != nil)
                    }
                    .font(Design.Typography.ui(11.5))
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Hear it, add it

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stepper(value: $model.previewBar, in: 1...max(1, model.song?.lengthInBars ?? 1), label: "from bar \(model.previewBar)")
                    .help("Where the preview starts, in the song's bars")
                Toggle("With the song", isOn: $model.withSong)
                    .toggleStyle(.checkbox)
                    .help("The song as it plays now under the source, or the source alone")
                Button(model.isPreviewing ? "Rendering…" : "Preview 8 Bars") { Task { await model.preview() } }
                    .disabled(model.unheard != nil || model.isPreviewing || model.isAdding)
                    .help("Eight bars from there, through the fit, played now")
                Button("Stop") { model.stopPreview() }
                    .help("Stop the preview")
                Spacer()
                FrameButton(title: model.isAdding ? "Adding…" : "Add to \(model.song?.title ?? "the song")", emphasis: .accent,
                            isEnabled: model.blocker == nil && !model.isAdding) {
                    Task { await model.add() }
                }
                .help("Render it through the fit into the open song and play it in the sections chosen. The record is untouched; it can be fitted again from here.")
            }
            .font(Design.Typography.ui(12.5))
            if let progress = model.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction).frame(width: 220).tint(Design.Palette.accent)
                    Text(progress.what).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.inkSecondary)
                }
            }
            Text(model.lastError ?? model.lastAdded ?? model.blocker ?? "Any number of records, one at a time. Each stays a source to clear.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(model.lastError != nil ? Design.Palette.warn : Design.Palette.inkTertiary)
        }
    }
}
