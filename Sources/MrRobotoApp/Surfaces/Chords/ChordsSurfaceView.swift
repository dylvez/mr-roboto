import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// The lead sheet: a line of symbols in, bars with Roman numerals out, each bar playable.
struct ChordsSurfaceView: View {
    @Bindable var model: ChordsModel
    /// The controller, for Record. Nil where there is none to record — a render, a preview.
    var midi: MIDIControl? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            // The sheet scrolls inside the surface: with the pickers under it, the bars and the
            // Harmonist's reading were below the edge of a window at its minimum.
            MixScroll(.vertical) { sheet }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                model.statusBar
                if !model.isTouched, model.base == nil, model.isDefault {
                    Text("Not in the song until you type.")
                        .font(Design.Typography.ui(11.5))
                        .foregroundStyle(Design.Palette.inkTertiary)
                    FrameButton(title: "Add to song", emphasis: .accent) { model.useTheseChords() }
                        .help("Put the key's I–IV–V–I into the song as its chords. Typing does the same.")
                }
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }
}

extension ChordsSurfaceView {
    /// Everything but the status line: the title and key, the line, what voices it, how it is
    /// played, the bars and the reading of them.
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.title).font(Design.Typography.prose(16, weight: .medium))
                if let midi {
                    TakeButton(midi: midi, target: model,
                               help: "Record from the controller: play a chord, and when your hand comes off the keys it is "
                                   + "written as the next bar, named and spelled in the key — the lowest key is its bass. "
                                   + "Nothing needs to play. Press again to stop; ⌘Z takes a chord back.",
                               line: model.isTaking ? model.takeLine : nil)
                }
                Spacer()
                KeyField(model: model)
            }
            ChordsControls(model: model)
            if let progression = model.progression {
                // How each chord is voiced, for the notes drawn beside it, and the span of all of
                // them, so a voice that climbs is seen to climb from one bar to the next.
                let voiced = Voicing.voicings(of: progression.bars.flatMap(\.chords).map(\.chord), as: model.voicing)
                let notes = voiced.flatMap { $0 }
                let range = notes.min().flatMap { low in notes.max().map { low...$0 } }
                VStack(alignment: .leading, spacing: 6) {
                    // A typo leaves the last good parse on screen. Dimmed and labelled, so the
                    // bars are never mistaken for the line that is in the field now.
                    if model.barsAreStale {
                        Label("These bars are the last line that read, not what is typed. Fix the line above and they follow.",
                              systemImage: "exclamationmark.triangle")
                            .font(Design.Typography.ui(11.5, weight: .regular))
                            .foregroundStyle(Design.Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Eight bars are wider than a bench at its narrowest; they scroll, with the
                    // scroller showing so a row cut at the edge says there is more.
                    MixScroll(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(progression.bars.enumerated()), id: \.offset) { index, bar in
                                let first = progression.bars.prefix(index).reduce(0) { $0 + $1.chords.count }
                                BarCard(index: index, bar: bar, model: model,
                                        voiced: Array(voiced.dropFirst(first).prefix(bar.chords.count)), range: range)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .opacity(model.barsAreStale ? 0.4 : 1)
                    .accessibilityHint(model.barsAreStale ? "Stale: the last line that read" : "")
                }
                HarmonistReadings(model: model)
                    .opacity(model.barsAreStale ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The sheet's controls, above the bars: the line of chords, what voices it and how it is
/// played. Its own view so a layout test can measure what the bars sit under.
struct ChordsControls: View {
    @Bindable var model: ChordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Chords", color: Design.Palette.inkTertiary)
            Group {
                if Design.isOffscreenRender {
                    RenderedField(text: model.text, placeholder: "Dm7 G7 | Cmaj7 | Am7 | Fmaj7", font: Design.Typography.ui(14))
                } else {
                    TextField("Dm7 G7 | Cmaj7 | Am7 | Fmaj7", text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(14))
                }
            }
            .frame(maxWidth: 520)
            // The typo, if there is one, with its mark; the way the line reads otherwise. Once
            // something is typed that is the primer's line, said here only where primers are.
            if model.problem != nil || model.isDefault {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.problem != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Design.Palette.warn)
                    }
                    Text(model.problem ?? (model.isDefault
                            ? "Nothing typed: the key's I–IV–V–I, a bar each. Bars are separated by |, chords in a bar share it."
                            : "Bars are separated by |; chords in a bar share its beats. Click a bar to hear it."))
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(model.problem == nil ? Design.Palette.inkSecondary : Design.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The genre's own progressions, in the sheet's key, a press away.
            let offered = model.genreProgressions
            if !offered.isEmpty {
                HStack(spacing: 6) {
                    SmallLabel(offered[0].genre, color: Design.Palette.inkTertiary)
                    ForEach(offered, id: \.roman) { entry in
                        FormChip(entry.roman, isOn: model.text == entry.text) { model.use(progression: entry.text) }
                            .help("\(entry.text) — \(entry.about)")
                    }
                }
                .padding(.top, 2)
            }
            // The same sheet said another way, a move a press away: what the Harmonist's
            // "nothing of its own" points at.
            let ways = model.anotherWays
            if !ways.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SmallLabel("Another way", color: Design.Palette.inkTertiary)
                    FlowRow(spacing: 4) {
                        ForEach(ways, id: \.move) { way in
                            FormChip(way.move.name, isOn: false) { model.use(way: way) }
                                .help("\(way.progression.symbols()) — \(way.says) ⌘Z puts it back.")
                                .accessibilityLabel("Another way: \(way.move.name)")
                        }
                    }
                }
                .padding(.top, 2)
            }
            // What voices them. Chords used to play on the bass sampler, an octave below where
            // they were written; now they go through whatever this names.
            InstrumentPicker(selected: model.instrument, choose: { model.setInstrument($0) }, label: "Voiced on")
                .padding(.top, 4)
            // How they are played: the two things a player decides that a lead sheet does not.
            PlayingPicker(model: model)
                .padding(.top, 4)
        }
    }
}

/// How the chords are played: the rhythm they are struck in and where their notes sit, each a row
/// of chips that wraps, with the line the top of the chords makes under them.
private struct PlayingPicker: View {
    let model: ChordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Played") {
                ForEach(KeysPattern.allCases) { pattern in
                    FormChip(pattern.name, isOn: model.pattern == pattern) { model.setPattern(pattern) }
                        .help(pattern.about.prefix(1).uppercased() + pattern.about.dropFirst())
                        .accessibilityLabel("Played \(pattern.name)")
                }
            }
            row("Voiced") {
                ForEach(KeysVoicing.allCases) { voicing in
                    FormChip(voicing.name, isOn: model.voicing == voicing) { model.setVoicing(voicing) }
                        .help(voicing.about.prefix(1).uppercased() + voicing.about.dropFirst())
                        .accessibilityLabel("Voiced \(voicing.name)")
                }
            }
            if !model.topLine.isEmpty, !model.barsAreStale {
                Text(String(format: "On top: %@. Voiced %@, the hand travels %.1f semitones a change.",
                            model.topLine, model.voicing.name.lowercased(), model.movement))
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = model.patternCaution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Chips: View>(_ label: String, @ViewBuilder chips: () -> Chips) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Design.Typography.label)
                .foregroundStyle(Design.Palette.inkTertiary)
                .frame(width: 58, alignment: .leading)
            FlowRow(spacing: 4) { chips() }
        }
    }
}

/// The Harmonist on the surface: its reading of the bars, under them, as the Bassist's sits under
/// the Piano roll. What did not hold comes first, in the warning colour, because that is what it
/// would say first; what holds follows, quieter. Refreshed on every parse, so it answers the line
/// as it is typed rather than after it is kept.
private struct HarmonistReadings: View {
    let model: ChordsModel

    var body: some View {
        let hue = MemberHue.color(forPersona: "Harmonist")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: "Harmonist") { MemberEmblem(name: emblem, hue: hue, width: 18) }
                SmallLabel("The Harmonist", color: hue ?? Design.Palette.inkTertiary)
            }
            ForEach(model.orderedReadings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: reading.holds ? "checkmark" : "exclamationmark.triangle")
                        .font(Design.Typography.ui(9, weight: .bold))
                        .foregroundStyle(reading.holds ? Design.Palette.ok : Design.Palette.warn)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(reading.says)
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.findingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(reading.holds ? reading.says : "Flag: \(reading.says)")
            }
        }
        .padding(.top, 4)
    }
}

/// The key, as a line you type: "D major", "F# minor", "E dorian". Read on Return or when the
/// field loses focus, not on every keystroke — "F" alone is F major, and a field that re-spelled
/// itself to "F major" while you were still typing "F# minor" would be fighting you.
private struct KeyField: View {
    @Bindable var model: ChordsModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SmallLabel("Key", color: Design.Palette.inkTertiary)
            Group {
                if Design.isOffscreenRender {
                    RenderedField(text: text.isEmpty ? model.key.name : text, placeholder: "D major")
                } else {
                    TextField("D major", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(12.5))
                }
            }
                .frame(width: 130)
                .focused($isFocused)
                .onSubmit { read() }
                .onChange(of: isFocused) { _, focused in if !focused { read() } }
                .help("The key the chords are read in: D major, F# minor, E dorian. Return applies it.")
                .accessibilityLabel("Key")
            if let problem = model.keyProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .lineLimit(1)
                    .accessibilityLabel("Key not read: \(problem)")
            }
        }
        .onAppear { text = model.key.name }
        // A key set from elsewhere — a bound progression's own — shows in the field too.
        .onChange(of: model.key) { _, key in text = key.name }
    }

    private func read() {
        // Nothing typed differently from the key that stands, and no problem to clear: leave it.
        guard text.trimmingCharacters(in: .whitespaces) != model.key.name || model.keyProblem != nil else { return }
        if model.setKey(parsing: text) { text = model.key.name }
    }
}

private struct BarCard: View {
    let index: Int
    let bar: ProgressionBar
    let model: ChordsModel
    /// Each chord's notes as voiced.
    var voiced: [[Int]] = []
    var range: ClosedRange<Int>? = nil

    var body: some View {
        let hues = bar.chords.map { HarmonyHue.color(for: $0.chord, in: model.key) }
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1)")
                .font(Design.Typography.numeric(10))
                .foregroundStyle(Design.Palette.inkTertiary)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(bar.chords.enumerated()), id: \.offset) { position, span in
                    Button { model.audition(span.chord) } label: {
                        ChordFace(span: span, model: model,
                                  voiced: position < voiced.count ? voiced[position] : [], range: range)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 96, alignment: .leading)
        .modifier(BarCell(hues: hues.compactMap { $0 }))
    }
}

/// One chord of a bar: its symbol, its numeral and how long it lasts. The numeral is in the colour
/// of its step, a chord from outside the key says it is borrowed, and the notes it is voiced on
/// stand beside it on a small plate with the top one in the display's white — the line the Played
/// row's caption spells out, seen moving from bar to bar.
private struct ChordFace: View {
    let span: ChordSpan
    let model: ChordsModel
    let voiced: [Int]
    let range: ClosedRange<Int>?

    var body: some View {
        let hue = HarmonyHue.color(for: span.chord, in: model.key, .ink)
        let tick = HarmonyHue.color(for: span.chord, in: model.key, .plate)
        let borrowed = hue != nil && HarmonyHue.reading(of: span.chord, in: model.key)?.inKey == false
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.symbol(of: span.chord))
                    .font(Design.Typography.ui(17, weight: .semibold))
                    .foregroundStyle(Design.Palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.numeral(of: span.chord))
                        .font(Design.Typography.numeric(11, weight: hue == nil ? .regular : .semibold))
                        .foregroundStyle(hue ?? Design.Palette.emphasis)
                    if borrowed {
                        Text("borrowed")
                            .font(Design.Typography.ui(9.5, weight: .medium))
                            .foregroundStyle(hue ?? Design.Palette.inkSecondary)
                            .help("Not all of its notes are in \(model.key.name): borrowed from outside the key")
                    }
                }
                Text(String(format: "%g beats", span.beats))
                    .font(Design.Typography.numeric(9.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            if let tick, let range, !voiced.isEmpty {
                VoicedNotes(notes: voiced, range: range, hue: tick)
                    .help("Voiced \(model.voicing.name.lowercased()): " + voiced.map { model.key.name(of: Pitch(midi: $0)) }.joined(separator: " · "))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A chord's notes as they are voiced, drawn as a keyboard turned on its side: one tick a note at
/// its height in the progression's whole span, on a plate, the top note in the display's white.
private struct VoicedNotes: View {
    let notes: [Int]
    let range: ClosedRange<Int>
    let hue: Color

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(max(1, range.upperBound - range.lowerBound + 2))
            let step = size.height / span
            let top = notes.max()
            for note in notes {
                let y = size.height - CGFloat(note - range.lowerBound + 1) * step
                let rect = CGRect(x: 0, y: y - 1.5, width: size.width, height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(note == top ? Design.Palette.lcdInk : hue))
            }
        }
        .frame(width: 12, height: 50)
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(Design.Palette.plate, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A bar's cell: a soft fill with no edge, a cell among cells, washed in the hues of its chords,
/// deepest at the top under a cap of the hue itself. The wash lies over the palette's tint ground,
/// so a numeral in its chord's colour reads on it on charcoal as on black and on white.
private struct BarCell: ViewModifier {
    var hues: [Color] = []

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous)
        if hues.isEmpty {
            content.background(Design.Palette.fill, in: shape)
        } else {
            content
                .background {
                    ZStack(alignment: .top) {
                        shape.fill(Design.Palette.tintGround)
                        LinearGradient(colors: hues.map { $0.opacity(0.34) }, startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(colors: [.black, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                        LinearGradient(colors: hues.count == 1 ? [hues[0], hues[0]] : hues,
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 3)
                    }
                    .clipShape(shape)
                }
        }
    }
}
