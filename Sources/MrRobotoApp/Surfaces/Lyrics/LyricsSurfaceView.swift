import SongGraph
import SwiftUI

/// The words: a page to type on, the lines read back with their stresses and scheme letters, and
/// the Lyricist's readings.
struct LyricsSurfaceView: View {
    @Bindable var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                page
                reading
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.title).font(Design.Typography.prose(16, weight: .medium))
            if let observation = model.observation {
                Text("\(observation.lineCount) lines · \(String(format: "%.1f", observation.syllablesPerLine)) syllables a line · \(observation.schemes.joined(separator: " / "))")
                    .font(Design.Typography.numeric(12))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            Spacer()
            Text(model.corpus.isEmpty ? "No house voice imported (File ▸ Import Voice…)" : "Read against \(model.corpus.lyrics.count) of this house's lyrics")
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }

    /// The hint reads the same in the live editor and in a test render: a placeholder in the
    /// page's own type, gone the moment there are words.
    private static let placeholder = "A line each; a blank line between stanzas."

    private var page: some View {
        VStack(alignment: .leading, spacing: 4) {
            LyricLabel("Words")
            Group {
                if Design.isOffscreenRender {
                    Text(model.text.isEmpty ? Self.placeholder : model.text)
                        .font(Design.Typography.prose(13))
                        .foregroundStyle(model.text.isEmpty ? Design.Palette.inkTertiary : Design.Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: $model.text)
                        .font(Design.Typography.prose(13))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .frame(minHeight: 200, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text(Self.placeholder)
                                    .font(Design.Typography.prose(13))
                                    .foregroundStyle(Design.Palette.inkTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .help("The words, a line each; a blank line between stanzas")
                        .accessibilityLabel("Words")
                }
            }
            // A page with an edge, so the place to type is visible before anything is typed.
            .background(Design.Palette.panel, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 6) {
            LyricLabel("Shape and scheme")
            let letters = model.schemeLetters
            ForEach(Array(model.lyric.lines.enumerated()), id: \.offset) { index, line in
                if line.syllables.isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(index < letters.count ? letters[index] : "")
                            .font(Design.Typography.numeric(11, weight: .medium))
                            .foregroundStyle(Design.Palette.accent)
                            .frame(width: 14)
                        HStack(spacing: 1) {
                            ForEach(Array(line.syllables.enumerated()), id: \.offset) { _, syllable in
                                Text(syllable.text)
                                    .font(Design.Typography.ui(12, weight: syllable.stress == .unstressed ? .regular : .semibold))
                                    .foregroundStyle(syllable.stress == .unstressed ? Design.Palette.inkSecondary : Design.Palette.ink)
                                    .padding(.leading, syllable.startsWord ? 5 : 0)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(syllable.stress == .unstressed ? Color.clear : Design.Palette.accent.opacity(0.6))
                                            .frame(height: 1.5).offset(y: 2)
                                    }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if !model.readings.isEmpty {
                LyricLabel("The Lyricist").padding(.top, 8)
                ForEach(Array(model.readings.enumerated()), id: \.offset) { _, reading in
                    Text(reading.says)
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(reading.holds ? Design.Palette.inkSecondary : Design.Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 420, alignment: .topLeading)
    }

    private var footer: some View {
        model.statusBar
    }
}

private struct LyricLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}
