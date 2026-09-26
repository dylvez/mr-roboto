import SwiftUI

/// The band's question, whole: what the member asking sees, the question, the options with why
/// each, "Not this" on each, and the band's field for anything else. The band column carries it at
/// its top; an empty bench carries it in the middle while the column is folded away.
struct NextQuestionCard: View {
    let app: AppState
    let question: NextQuestion
    /// The asker's portrait and name above the question, where nothing else says who is asking.
    var showsAsker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsAsker {
                HStack(spacing: 8) {
                    if let emblem = Art.emblem(for: question.asker) { ArtImage(emblem, width: 26) }
                    SmallLabel("\(question.asker.label) asks")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(question.observation)
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                Text(question.question)
                    .font(Design.Typography.prose(15.5, weight: .medium))
                    .foregroundStyle(Design.Palette.ink)
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                NextOptionButton(option: option, isLeading: index == 0,
                                 take: { app.take(option, from: question) },
                                 decline: { app.decline(option, in: question) })
            }
            Button { app.askTheBand() } label: {
                Text("Something else… ask the band")
                    .font(Design.Typography.ui(12, weight: .medium))
                    .foregroundStyle(Design.Palette.accent)
            }
            .buttonStyle(.plain)
            .help("The band's field: say what you want in your own words")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The question in the dock, while the band column is folded: who asks and what, "Next" for the
/// best answer, and every answer, "Not this" and the band's field in a menu beside it. The question
/// is what the dock keeps longest: it is the persona asking, and the answers are one click away.
struct DockQuestion: View {
    let app: AppState
    let question: NextQuestion
    let option: NextOption
    /// How much the dock has room for: the question and the best answer's name, the question alone,
    /// the answer's name alone, or "Next" whose tooltip carries both.
    enum Room { case both, question, answer, button }
    var room: Room = .both

    var body: some View {
        HStack(spacing: 6) {
            if let emblem = Art.emblem(for: question.asker) {
                ArtImage(emblem, width: 22).help("\(question.asker.label) asks")
            }
            if room == .both || room == .question {
                Text(question.question)
                    .font(Design.Typography.ui(12.5, weight: .regular))
                    .foregroundStyle(Design.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .help("\(question.asker.label) asks: \(question.observation) \(question.question)")
            }
            Button { app.take(option, from: question) } label: {
                HStack(spacing: 8) {
                    SmallLabel(room == .both || room == .answer ? "Next" : "Next →", color: Design.Palette.accent)
                    if room == .both || room == .answer {
                        Text(option.title)
                            .font(Design.Typography.ui(12.5, weight: .medium))
                            .foregroundStyle(Design.Palette.accent)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: Design.Metric.controlHeight)
                .background(Design.Palette.accentSoft)
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.accent, lineWidth: Design.Metric.hairline))
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(option.title): \(option.rationale) (⌘])")
            more
        }
    }

    /// Every answer. A menu draws as a block in an offscreen render, so a render shows its chevron.
    @ViewBuilder
    private var more: some View {
        if Design.isOffscreenRender {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Palette.accent)
                .frame(width: 22, height: Design.Metric.controlHeight)
        } else {
            Menu {
                ForEach(question.options) { answer in
                    Button(answer.isYourUsual ? "\(answer.title) — your usual" : answer.title) { app.take(answer, from: question) }
                }
                Divider()
                Button("Not this: \(option.title)") { app.decline(option, in: question) }
                Button("Something else… ask the band") { app.askTheBand() }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Every answer, and the band's field")
            .accessibilityLabel("Answers")
        }
    }
}
