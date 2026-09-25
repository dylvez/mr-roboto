import MusicTheory
import SongGraph
import SwiftUI

/// The lead sheet: a line of symbols in, bars with Roman numerals out, each bar playable.
struct ChordsSurfaceView: View {
    @Bindable var model: ChordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.title).font(Design.Typography.prose(16, weight: .medium))
                Spacer()
                KeyField(model: model)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CHORDS").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
                TextField("Dm7 G7 | Cmaj7 | Am7 | Fmaj7", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.Typography.ui(14))
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
                // What voices them. Chords used to play on the bass sampler, an octave below where
                // they were written; now they go through whatever this names.
                InstrumentPicker(selected: model.instrument, choose: { model.setInstrument($0) }, label: "Voiced on")
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(progression.bars.enumerated()), id: \.offset) { index, bar in
                                BarCard(index: index, bar: bar, model: model)
                            }
                        }
                    }
                    .opacity(model.barsAreStale ? 0.4 : 1)
                    .accessibilityHint(model.barsAreStale ? "Stale: the last line that read" : "")
                }
            }
            Spacer(minLength: 0)
            HStack {
                if let error = model.lastError {
                    Text(error).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn)
                }
                Spacer()
                if let kept = model.lastKept, !model.hasUnkeptChanges { KeptNote(version: kept) }
                KeepButton(isEnabled: model.hasUnkeptChanges) { model.commit() }
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
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
            TextField("D major", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typography.ui(12.5))
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
