import SongGraph
import SwiftUI

/// Add to This Song…, or an idea dropped on a section: which of the idea's parts, where they go,
/// and what moving them onto the song's key and tempo does to each, in the words a merge says it
/// in — before anything is done. Nothing in the idea changes.
struct PlaceIdeaSheet: View {
    let app: AppState
    let request: IdeaPlacingRequest
    @Environment(\.dismiss) private var dismiss
    @State private var spot: IdeaSpot
    /// The parts taken out of what comes; everything placeable comes unless taken out.
    @State private var leftOut: Set<PartID> = []
    @State private var bringsWords = true
    @State private var isWorking = false
    @State private var problem: String?

    init(app: AppState, request: IdeaPlacingRequest) {
        self.app = app
        self.request = request
        _spot = State(initialValue: request.spot)
    }

    private var placement: IdeaPlacement? { app.ideaPlacement(request.idea, at: spot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let placement, let song = app.song {
                header(placement, song: song)
                whereRow(placement, song: song)
                parts(placement)
                if let words = placement.words { wordsRow(words) }
                said(placement)
                buttons(placement)
            } else {
                Text("That idea, or the section it was going in, is not there any more.")
                    .font(Design.Typography.prose(13.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
                HStack {
                    Spacer()
                    FrameButton(title: "Close", emphasis: .quiet) { dismiss() }
                }
            }
        }
        .padding(Design.Metric.inset)
        .frame(width: 500)
        .background(Design.Palette.panel)
        .foregroundStyle(Design.Palette.ink)
    }

    private func header(_ placement: IdeaPlacement, song: Song) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SmallLabel("Add an idea to \(song.title)")
            Text(placement.idea.title)
                .font(Design.Typography.ui(17, weight: .semibold))
            Text("\(AppState.ideaLine(placement.idea)). Its parts are copied in, moved onto the song's key and tempo; the idea is left as it is.")
                .font(Design.Typography.prose(13))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func whereRow(_ placement: IdeaPlacement, song: Song) -> some View {
        HStack(spacing: 8) {
            SmallLabel("Where")
            ChipMenu(spotTitle(placement)) {
                ForEach(song.sections) { section in
                    MenuChoice("\(section.name) · \(Guidance.count(section.lengthInBars, "bar"))", isOn: spot == .section(section.id)) {
                        spot = .section(section.id)
                    }
                }
                // An idea is one section: its parts go in that one.
                if !song.isIdea {
                    MenuChoice("A new section after the last", isOn: spot == .end) { spot = .end }
                }
            }
            .disabled(isWorking)
        }
    }

    private func spotTitle(_ placement: IdeaPlacement) -> String {
        switch placement.spot {
        case .section: "The \(placement.sectionName), \(Guidance.count(placement.sectionBars, "bar"))"
        case .end: "A new section, \(Guidance.count(placement.sectionBars, "bar"))"
        }
    }

    private func parts(_ placement: IdeaPlacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallLabel("Parts")
            if placement.pieces.isEmpty {
                Text("Nothing in it plays.")
                    .font(Design.Typography.prose(13))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            ForEach(placement.pieces) { piece in
                VStack(alignment: .leading, spacing: 3) {
                    FormChip(piece.title, isOn: comes(piece)) {
                        if leftOut.contains(piece.id) { leftOut.remove(piece.id) } else { leftOut.insert(piece.id) }
                    }
                    .disabled(piece.isRefused || isWorking)
                    Text(piece.sentence + (piece.replaces.isEmpty ? "" : " In the \(placement.sectionName), in place of \(SectionWriting.list(piece.replaces))."))
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(piece.flags, id: \.self) { flag in
                        Text(flag)
                            .font(Design.Typography.prose(12.5))
                            .foregroundStyle(Design.Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func wordsRow(_ words: IdeaWords) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FormChip("Words", isOn: words.comes && bringsWords) { bringsWords.toggle() }
                .disabled(!words.comes || isWorking)
            Text(words.sentence)
                .font(Design.Typography.prose(12.5))
                .foregroundStyle(Design.Palette.inkSecondary)
        }
    }

    private func said(_ placement: IdeaPlacement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(placement.sentences, id: \.self) { sentence in
                Text(sentence)
                    .font(Design.Typography.prose(13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if placement.audioBytes > 0, chosen(placement).contains(where: { $0.version.type == .audio }) {
                Text("About \(ByteCountFormatter.string(fromByteCount: Int64(placement.audioBytes), countStyle: .file)) of audio is written into the song.")
                    .font(Design.Typography.prose(12.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            if let problem {
                Text(problem)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(_ placement: IdeaPlacement) -> some View {
        let anything = !chosen(placement).isEmpty || (bringsWords && placement.words?.comes == true)
        let fitting = chosen(placement).contains { $0.version.type == .audio }
        return HStack(spacing: 8) {
            if isWorking {
                Text(fitting ? "Fitting the audio…" : "Putting it in…")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            Spacer()
            FrameButton(title: "Cancel", emphasis: .quiet, isEnabled: !isWorking) { dismiss() }
            FrameButton(title: placement.spot == .end ? "Add as a New Section" : "Add to the \(placement.sectionName)",
                        emphasis: .accent, isEnabled: anything && !isWorking) {
                Task { await place(placement) }
            }
        }
    }

    private func comes(_ piece: IdeaPiece) -> Bool { !piece.isRefused && !leftOut.contains(piece.id) }

    private func chosen(_ placement: IdeaPlacement) -> [IdeaPiece] { placement.pieces.filter(comes) }

    private func place(_ placement: IdeaPlacement) async {
        isWorking = true
        defer { isWorking = false }
        problem = nil
        do {
            try await app.place(placement, parts: Set(chosen(placement).map(\.id)), words: bringsWords)
            dismiss()
        } catch {
            problem = "\(error)"
        }
    }
}
