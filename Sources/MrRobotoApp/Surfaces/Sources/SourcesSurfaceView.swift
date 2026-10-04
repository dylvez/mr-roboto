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
            // What is chosen, its plan and what the song already holds scroll together, each at the
            // height it needs, so the preview and Add stay in reach under them. Squeezed into a
            // fixed column, a song with many sections ran "Plays in" out of its card and over the
            // plan, and one with many sources pushed Add off the bottom of the surface.
            scrolling {
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    HStack(alignment: .top, spacing: Design.Metric.gutter) {
                        picker
                        placement
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    planLines
                        .fixedSize(horizontal: false, vertical: true)
                    inSong
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
        // A section split or removed in Structure, or the open song changed: let go of what went.
        .onChange(of: model.songSections.map(\.id)) { model.follow() }
        .onChange(of: model.song?.id) { model.follow() }
        // A stem dropped on the song while the surface is open.
        .onChange(of: model.asked) { model.takeAsked() }
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
            Picker("From", selection: $model.from) {
                Text("Choose a record…").tag(SourceOrigin?.none)
                if !model.records.isEmpty {
                    Section("Records") {
                        ForEach(model.records) { record in Text(record.title).tag(SourceOrigin?.some(.record(record.id))) }
                    }
                }
                if !model.candidates.isEmpty {
                    Section("Songs") {
                        ForEach(model.candidates) { song in Text(song.title).tag(SourceOrigin?.some(.song(song.id))) }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
            .help("A record in the crate, or a song that holds one. Choosing another picks its stem afresh.")

            if let line = model.sourceLine {
                Text(line).font(Design.Typography.numeric(11.5)).foregroundStyle(Design.Palette.inkSecondary)
                FlowRow(spacing: 6) {
                    ForEach(model.available, id: \.self) { stem in
                        BoothChip(chipTitle(stem), isOn: model.stem == stem) { model.choose(stem: stem) }
                            .help(stem == Mashups.full ? "The whole record, as it was imported" : "The \(stem) stem on its own")
                    }
                }
                if model.available == [Mashups.full] {
                    Text(model.record != nil
                         ? "No stems yet, so this record can only give the whole of it. Separate it from its row in the library to take the voice or the drums alone."
                         : "No stems yet, so this song can only give the whole record. Separate its stems on its Record surface to take the voice or the drums alone.")
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
            } else if model.origins.isEmpty {
                ArtImage("empty-drop-record", width: 150, height: 100)
                Text("No record in the crate has been read yet. File ▸ Import Records… brings records in; each is read for its bars and key, and separated, in the background.")
                    .font(Design.Typography.ui(12)).foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import Records…") { model.importRecords() }
                    .font(Design.Typography.ui(12))
                    .controlSize(.small)
                    .help("File ▸ Import Records… (⌘I): records into the crate, read and separated in the background.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Design.Palette.panelAlt, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
    }

    /// "Vocals −2 dB": the stem, and how much of the record it is.
    private func chipTitle(_ stem: String) -> String {
        guard stem != Mashups.full else { return "Full record" }
        guard let share = model.share(of: stem) else { return stem.capitalized }
        return "\(stem.capitalized) \(String(format: "%+.0f", share)) dB"
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

            BoothChip(model.isTightened ? "Tight to the grid" : "As recorded, drift and all", isOn: model.isTightened) { model.toggleTighten() }
                .help("Tight: each of its bars stretched onto one of the song's, so it keeps time with a programmed kit. As recorded: one stretch for all of it, the record's own drift kept. Unless you choose, it is tight unless its bar lines look misread.")

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
                            let tight = model.fit(of: version)?.tightened ?? false
                            Button(tight ? "Loosen" : "Tighten") { Task { await model.refit(version.partID, tighten: !tight) } }
                                .help(tight ? "Fitted again with one stretch for all of it, the record's drift kept"
                                            : "Fitted again with each of its bars stretched onto one of the song's")
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

    /// The part of the surface that scrolls. A scroll view draws nothing in an offscreen render,
    /// which shows as much of the content as there is room for instead.
    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if Design.isOffscreenRender {
            content()
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { content() }
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
