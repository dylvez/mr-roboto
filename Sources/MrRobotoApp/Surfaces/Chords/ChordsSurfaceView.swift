import MusicTheory
import Performance
import SongGraph
import SwiftUI

/// The lead sheet: a line of symbols in, bars with Roman numerals out, each bar playable.
struct ChordsSurfaceView: View {
    @Bindable var model: ChordsModel

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
                Spacer()
                KeyField(model: model)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CHORDS").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
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
                // The typo, if there is one, with its mark; the way the line reads otherwise.
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
                // The genre's own progressions, in the sheet's key, a press away.
                let offered = model.genreProgressions
                if !offered.isEmpty {
                    HStack(spacing: 6) {
                        Text(offered[0].genre.uppercased()).font(Design.Typography.label).tracking(1.1)
                            .foregroundStyle(Design.Palette.inkTertiary)
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
                        Text("ANOTHER WAY").font(Design.Typography.label).tracking(1.1)
                            .foregroundStyle(Design.Palette.inkTertiary)
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
            if let progression = model.progression {
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
                                BarCard(index: index, bar: bar, model: model)
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
            Text(label.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let emblem = Art.emblem(forPersona: "Harmonist") { ArtImage(emblem, width: 18) }
                Text("THE HARMONIST")
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            ForEach(model.orderedReadings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: reading.holds ? "checkmark" : "exclamationmark.triangle")
                        .font(Design.Typography.ui(9, weight: .bold))
                        .foregroundStyle(reading.holds ? Design.Palette.inkTertiary : Design.Palette.warn)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(reading.says)
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.warn)
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
            Text("KEY").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index + 1)")
                .font(Design.Typography.numeric(10))
                .foregroundStyle(Design.Palette.inkTertiary)
            HStack(spacing: 10) {
                ForEach(Array(bar.chords.enumerated()), id: \.offset) { _, span in
                    Button { model.audition(span.chord) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(span.chord.symbol(preferring: model.key.signature.preference))
                                .font(Design.Typography.ui(17, weight: .semibold))
                                .foregroundStyle(Design.Palette.ink)
                            Text(model.numeral(of: span.chord))
                                .font(Design.Typography.numeric(11))
                                .foregroundStyle(Design.Palette.accent)
                            Text(String(format: "%g beats", span.beats))
                                .font(Design.Typography.numeric(9.5))
                                .foregroundStyle(Design.Palette.inkTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 96, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}
