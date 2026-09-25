import SongGraph
import SwiftUI

/// The words: a page to type on, the lines read back with their stresses and scheme letters, and
/// the Lyricist's readings. A stanza is named after a section by a "[Verse]" line above it, and
/// the words can be set to one of the song's melodies, one syllable to a note.
struct LyricsSurfaceView: View {
    @Bindable var model: LyricsModel
    /// Where the caret is, so a label chip names the stanza being worked on.
    @State private var selection: TextSelection?

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
    private static let placeholder = "A line each; a blank line between stanzas; [Verse] above one names it."

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
                    TextEditor(text: $model.text, selection: $selection)
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
                        .help("The words, a line each; a blank line between stanzas; [Verse] on its own line names the stanza under it")
                        .accessibilityLabel("Words")
                }
            }
            // A page with an edge, so the place to type is visible before anything is typed.
            .background(Design.Palette.panel, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
            labelChips.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The song's section names, one press each, so the Booth can find the stanza for the section
    /// being sung. With no sections there is nothing to offer, and the page says how to type one.
    @ViewBuilder
    private var labelChips: some View {
        let choices = model.labelChoices
        if choices.isEmpty {
            Text("Type [Verse] above a stanza to name it after a section.")
                .font(Design.Typography.ui(11, weight: .regular))
                .foregroundStyle(Design.Palette.inkTertiary)
        } else {
            FlowRow(spacing: 6) {
                Text("Label a stanza")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(height: Design.Metric.chipHeight)
                ForEach(choices, id: \.self) { name in
                    BoothChip(name) { model.label(name, atRow: caretRow) }
                        .help("Write [\(name)] above the stanza the caret is in — or the first with no name — so the Booth shows it while the \(name) is sung. ⌘Z takes it back.")
                        .accessibilityLabel("Label a stanza \(name)")
                }
            }
        }
    }

    /// The row of the text the caret is on, label rows counted. Read through UTF-16 offsets
    /// clamped to the text, because an index kept from before the last edit need not belong to the
    /// string that is there now.
    private var caretRow: Int? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        let text = model.text
        let offset = min(max(0, range.lowerBound.utf16Offset(in: text)), text.utf16.count)
        return text.utf16.prefix(offset).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    /// The setting on top, and under it the lines and the readings, scrolling inside the column: a
    /// verse, a hook and five readings are taller than the bench's minimum, and a column that grew
    /// past it pushed the header and the keep line out of the surface.
    private var reading: some View {
        VStack(alignment: .leading, spacing: 12) {
            setting
            ScrollsInside { lines.frame(maxWidth: .infinity, alignment: .topLeading) }
        }
        .frame(minWidth: 280, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 6) {
            LyricLabel("Shape and scheme")
            let letters = model.schemeLetters
            let labels = model.stanzaLabels
            // Stressed syllables whose note is off the beat, by line and syllable.
            let offBeat = Set((model.observation?.setting?.offBeat ?? []).map { [$0.line, $0.syllable] })
            let isSet = model.lyric.alignedTo != nil
            ForEach(Array(model.lyric.lines.enumerated()), id: \.offset) { index, line in
                if let name = labels[index] {
                    Text(name.uppercased())
                        .font(Design.Typography.label)
                        .tracking(1.1)
                        .foregroundStyle(Design.Palette.accent)
                        .padding(.leading, 22)
                        .padding(.top, index == 0 ? 0 : 4)
                        .accessibilityLabel("Stanza: \(name)")
                }
                if line.syllables.isEmpty {
                    Color.clear.frame(height: 6)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(index < letters.count ? letters[index] : "")
                            .font(Design.Typography.numeric(11, weight: .medium))
                            .foregroundStyle(Design.Palette.accent)
                            .frame(width: 14)
                        HStack(spacing: 1) {
                            ForEach(Array(line.syllables.enumerated()), id: \.offset) { position, syllable in
                                SyllableMark(syllable: syllable, offBeat: offBeat.contains([index, position]),
                                             unset: isSet && syllable.noteIndex == nil)
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
    }

    /// Which melody the words are set to, and how they landed on it.
    private var setting: some View {
        VStack(alignment: .leading, spacing: 4) {
            SetToMelodyMenu(model: model)
            if let setting = model.setting {
                Text(setting.line)
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(setting.past > 0 ? Design.Palette.warn : Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(setting.past > 0
                          ? "The melody runs out of notes before the words do: the last syllables have nowhere to land."
                          : "One syllable to a note, in order. Notes past the last syllable are held or still to be written.")
            } else if model.setTo != nil {
                Text("Set to a melody this song no longer holds.")
                    .font(Design.Typography.ui(11, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
            }
        }
    }

    private var footer: some View {
        model.statusBar
    }
}

/// The melodies the words can be set to, one syllable to a note, and "Not set".
private struct SetToMelodyMenu: View {
    @Bindable var model: LyricsModel

    var body: some View {
        let choices = model.melodyChoices
        let set = model.setMelody
        Menu {
            ForEach(choices) { choice in
                Toggle(title(for: choice, set: set), isOn: Binding(
                    get: { model.setTo == choice.version },
                    set: { _ in model.setMelody(choice.version) }))
            }
            if !choices.isEmpty { Divider() }
            Toggle("Not set", isOn: Binding(get: { model.setTo == nil }, set: { _ in model.setMelody(nil) }))
        } label: {
            HStack(spacing: 4) {
                Text(set.map { "Set to \($0.title)" } ?? "Set to melody")
                    .font(Design.Typography.ui(11.5, weight: set == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(Design.Typography.ui(8, weight: .bold))
            }
            .foregroundStyle(set == nil ? Design.Palette.inkSecondary : Design.Palette.accent)
            .padding(.horizontal, 8)
            .frame(height: Design.Metric.chipHeight)
            .background(set == nil ? Design.Palette.panelAlt : Design.Palette.accentSoft,
                        in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(set == nil ? Design.Palette.line : Design.Palette.accent.opacity(0.35), lineWidth: Design.Metric.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(choices.isEmpty && model.setTo == nil)
        .help(choices.isEmpty && model.setTo == nil
              ? "The song has no melody to set the words to yet."
              : "Set the words to a melody, one syllable to a note, so the Lyricist can hear where the stresses land. Retyping keeps them set; ⌘Z takes it back.")
        .accessibilityLabel(set.map { "Set to melody: \($0.title)" } ?? "Set to melody: not set")
    }

    /// A melody's name, and — when the words are set to an older version of it — that choosing it
    /// sets them to what it is now.
    private func title(for choice: LyricsMelody, set: LyricsMelody?) -> String {
        guard let set, set.part == choice.part, set.version != choice.version else { return choice.title }
        return "\(choice.title) — newer than the version the words are set to"
    }
}

/// One syllable as the Lyricist reads it: stressed heavier with a rule under it, a stress that
/// lands off the beat in the warning colour, a syllable past the melody's last note faint.
private struct SyllableMark: View {
    let syllable: Syllable
    let offBeat: Bool
    let unset: Bool

    private var stressed: Bool { syllable.stress != .unstressed }

    private var ink: Color {
        if offBeat { return Design.Palette.warn }
        if unset { return Design.Palette.inkTertiary }
        return stressed ? Design.Palette.ink : Design.Palette.inkSecondary
    }

    private var rule: Color {
        if offBeat { return Design.Palette.warn }
        return stressed ? Design.Palette.accent.opacity(0.6) : Color.clear
    }

    var body: some View {
        Text(syllable.text)
            .font(Design.Typography.ui(12, weight: stressed ? .semibold : .regular))
            .foregroundStyle(ink)
            .padding(.leading, syllable.startsWord ? 5 : 0)
            .overlay(alignment: .bottom) {
                Rectangle().fill(rule).frame(height: 1.5).offset(y: 2)
            }
            .help(offBeat ? "A stressed syllable on a note that starts off the beat." : unset ? "Past the melody's last note." : "")
    }
}

private struct LyricLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Design.Typography.label).tracking(1.1).foregroundStyle(Design.Palette.inkTertiary)
    }
}
