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
                Text("Key \(model.key)")
                    .font(Design.Typography.numeric(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CHORDS").font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
                TextField("Dm7 G7 | Cmaj7 | Am7 | Fmaj7", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(Design.Typography.ui(14))
                    .frame(maxWidth: 520)
                Text(model.problem ?? (model.isDefault
                        ? "Nothing typed: the key's I–IV–V–I, a bar each. Bars are separated by |, chords in a bar share it."
                        : "Bars are separated by |; chords in a bar share its beats. Click a bar to hear it."))
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(model.problem == nil ? Design.Palette.inkSecondary : Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                // What voices them. Chords used to play on the bass sampler, an octave below where
                // they were written; now they go through whatever this names.
                InstrumentPicker(selected: model.instrument, choose: { model.setInstrument($0) }, label: "Voiced on")
                    .padding(.top, 4)
            }
            if let progression = model.progression {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(progression.bars.enumerated()), id: \.offset) { index, bar in
                            BarCard(index: index, bar: bar, model: model)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                if let error = model.lastError {
                    Text(error).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn)
                }
                Spacer()
                Button("Keep as a new version") { model.commit() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.ui(12, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .disabled(model.problem != nil)
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
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
