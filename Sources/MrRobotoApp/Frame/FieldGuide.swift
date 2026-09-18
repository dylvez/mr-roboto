import SwiftUI

/// Help ▸ Mr. Roboto Field Guide: every idiom, how they chain, and what each surface is for.
///
/// The same content as the primers and the path's tooltips, gathered in one place and drawn from the
/// same sources (`WorkPath`, `PathStep.Kind.meaning`, `Primer`), so the guide cannot drift from what
/// the frame actually says.
enum FieldGuide {

    struct Entry: Identifiable {
        let word: String
        let meaning: String
        var id: String { word }
    }

    /// The words that are not steps or surfaces, in the order you tend to meet them.
    static let words: [Entry] = [
        Entry(word: "Library", meaning: "Everything saved: songs, albums, imported records, your samples, and ideas that belong to no song yet."),
        Entry(word: "Song", meaning: "The document you work in. It keeps every version ever made for it, and its sections in order."),
        Entry(word: "Part", meaning: "One musical thing that changes over time — the drums stem, a chop, a groove. The Parts region lists them by stage."),
        Entry(word: "Version", meaning: "A snapshot of a part that never changes. It records who made it, from what, and how. An edit adds one; nothing is overwritten."),
        Entry(word: "Form", meaning: "The record's own intro, verse and chorus, as the analysis heard them. Not the same as your sections."),
        Entry(word: "Section", meaning: "A stretch of your song, such as “Verse, 8 bars”, pointing at the exact versions that play in it."),
        Entry(word: "Slice · Pad", meaning: "A slice is the span between two markers in a chop; its pad plays it."),
        Entry(word: "Feel", meaning: "A named timing template (Boom-Bap Pocket, Dilla, Trip-Hop…). A groove is a feel you have made your own."),
        Entry(word: "Swing", meaning: "How late the offbeats land, on the MPC's 50–75% scale."),
        Entry(word: "Sample", meaning: "A one-shot or loop in your library. A piece cut from a stem is a chop."),
        Entry(word: "Director", meaning: "Reads what you ask for, hands it to the right band member, and answers by opening a surface on real parts."),
        Entry(word: "Band", meaning: "The cast for this project: the Beatmaker for grooves and feels, the Sampler for chops and machines."),
        Entry(word: "Critic", meaning: "A rule that looks for one kind of problem. It flags and never fixes."),
        Entry(word: "Lever", meaning: "At most two controls the Director puts on a surface, so you can move the one thing it is asking about."),
    ]
}

struct FieldGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Field Guide")
                        .font(Design.Typography.ui(24, weight: .semibold))
                    Text("Everything in a song descends from something else. Each step below makes the thing the next one works on, and the strip at the top of the window shows where you are.")
                        .font(Design.Typography.prose(14))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach([WorkPath.flip, .beat], id: \.self) { path in
                    VStack(alignment: .leading, spacing: 10) {
                        SmallLabel("The \(path.title.lowercased()) path", color: Design.Palette.accent)
                        Text(path.summary)
                            .font(Design.Typography.prose(13.5))
                            .foregroundStyle(Design.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(path.steps, id: \.self) { step in
                            entry(glyph: step.glyph, word: step.title, meaning: step.meaning)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SmallLabel("Surfaces", color: Design.Palette.accent)
                    ForEach(SurfaceKind.allCases, id: \.self) { kind in
                        let primer = Primer.text(for: kind)
                        entry(glyph: nil, word: primer.title, meaning: primer.body)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SmallLabel("Words", color: Design.Palette.accent)
                    ForEach(FieldGuide.words) { word in
                        entry(glyph: nil, word: word.word, meaning: word.meaning)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 480, idealHeight: 720)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
    }

    private func entry(glyph: String?, word: String, meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let glyph { Image(systemName: glyph) } else { Text("") }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Design.Palette.inkSecondary)
            .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(word).font(Design.Typography.ui(14, weight: .semibold))
                Text(meaning)
                    .font(Design.Typography.prose(13.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
