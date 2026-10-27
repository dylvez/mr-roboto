import SongGraph
import SwiftUI

/// File ▸ New Song from Ideas…, or Make a Song from These: ideas laid out as a song before it is
/// made. Each row is a section named after its first idea; an idea joined to the row above plays
/// in that section with it. The tempo and key are the idea's that would lose most by moving, said,
/// and any idea's can be taken instead.
struct SongFromIdeasSheet: View {
    let app: AppState
    let request: SongFromIdeasRequest
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [[SongID]]
    @State private var title = ""
    /// The idea whose grid is taken; nil is the suggestion.
    @State private var grid: SongID?
    @State private var isWorking = false
    @State private var problem: String?

    init(app: AppState, request: SongFromIdeasRequest) {
        self.app = app
        self.request = request
        _rows = State(initialValue: request.ideas.map { [$0] })
    }

    private func idea(_ id: SongID) -> Song? { app.ideasToMakeSongsFrom.first { $0.id == id } }
    private var chosen: [Song] { rows.flatMap { $0 }.compactMap(idea) }
    private var grids: [IdeasGrid] { SongFromIdeas.grids(for: chosen) }
    private var taken: IdeasGrid? { grids.first { $0.idea == grid } ?? grids.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SmallLabel("A song from ideas")
                // An AppKit field draws as a blocked box in an offscreen render: its words instead.
                if Design.isOffscreenRender {
                    Text(title.isEmpty ? "Untitled" : title).font(Design.Typography.ui(14, weight: .medium))
                } else {
                    TextField("Untitled", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(14, weight: .medium))
                }
                Text("Each row is a section named after its idea; an idea joined to the one above plays in its section. The ideas are copied in and left as they are.")
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sections
            addRow
            if let taken { gridRow(taken) }
            footer
        }
        .padding(Design.Metric.inset)
        .frame(width: 540)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 6) {
            SmallLabel("Sections")
            if rows.isEmpty {
                Text("No ideas yet: add them below, in the order the song plays them.")
                    .font(Design.Typography.prose(13))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(Design.Typography.numeric(12))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .frame(width: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(row, id: \.self) { id in
                            if let found = idea(id) {
                                HStack(spacing: 6) {
                                    Text(found.title).font(Design.Typography.ui(13, weight: id == row.first ? .semibold : .regular))
                                    Text(AppState.ideaLine(found))
                                        .font(Design.Typography.prose(12))
                                        .foregroundStyle(Design.Palette.inkSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    FormChip("↑", isOn: false) { move(index, by: -1) }.disabled(index == 0 || isWorking)
                    FormChip("↓", isOn: false) { move(index, by: 1) }.disabled(index == rows.count - 1 || isWorking)
                    if index > 0 {
                        FormChip("With the one above", isOn: false) { join(index) }.disabled(isWorking)
                    }
                    if row.count > 1 {
                        FormChip("Apart", isOn: false) { split(index) }.disabled(isWorking)
                    }
                    FormChip("Take out", isOn: false) { rows.remove(at: index) }.disabled(isWorking)
                }
            }
        }
    }

    private var addRow: some View {
        let left = app.ideasToMakeSongsFrom.filter { idea in !rows.contains { $0.contains(idea.id) } }
        return HStack(spacing: 8) {
            ChipMenu(left.isEmpty ? "Every idea is in" : "Add an idea") {
                ForEach(left) { idea in
                    MenuChoice(idea.title, isOn: false, help: AppState.ideaLine(idea)) { rows.append([idea.id]) }
                }
            }
            .disabled(left.isEmpty || isWorking)
            if !rows.isEmpty {
                let bars = rows.compactMap { $0.first.flatMap(idea)?.sections.first?.lengthInBars }.reduce(0, +)
                Text("\(Guidance.count(rows.count, "section")), about \(Guidance.count(bars, "bar"))")
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
        }
    }

    private func gridRow(_ taken: IdeasGrid) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SmallLabel("Tempo and key")
                ChipMenu("\(SongFromIdeas.line(taken)), \(taken.title)'s") {
                    ForEach(grids) { candidate in
                        MenuChoice("\(candidate.title): \(SongFromIdeas.line(candidate))\(candidate.idea == grids.first?.idea ? " (moves the rest least)" : "")",
                                   isOn: candidate.idea == taken.idea) { grid = candidate.idea }
                    }
                }
                .disabled(isWorking)
            }
            ForEach(taken.sentences, id: \.self) { sentence in
                Text(sentence)
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(taken.flags, id: \.self) { flag in
                Text(flag)
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem {
                Text(problem)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
            }
            HStack(spacing: 8) {
                if isWorking {
                    Text("Putting the ideas in…")
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                }
                Spacer()
                FrameButton(title: "Cancel", emphasis: .quiet, isEnabled: !isWorking) { dismiss() }
                FrameButton(title: "Make the Song", emphasis: .accent, isEnabled: !rows.isEmpty && !isWorking) {
                    Task { await make() }
                }
            }
        }
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    private func join(_ index: Int) {
        guard index > 0 else { return }
        rows[index - 1] += rows[index]
        rows.remove(at: index)
    }

    private func split(_ index: Int) {
        let row = rows[index]
        rows.replaceSubrange(index...index, with: row.map { [$0] })
    }

    private func make() async {
        isWorking = true
        defer { isWorking = false }
        problem = nil
        do {
            try await app.makeSong(from: rows, grid: taken?.idea, title: title)
            dismiss()
        } catch {
            problem = "\(error)"
        }
    }
}
