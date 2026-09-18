import SwiftUI

/// The thread. Two halves, in the order you need them.
///
/// **What next**, at the top: what this song could use, derived from what it actually holds, one
/// click each. In Gate B these are the Director's proposals; in Gate A `Guidance` derives the same
/// values from the song graph, so the rail renders `[Proposal]` either way and does not get rebuilt
/// when the band arrives. Nothing appears here that does not work when clicked — `AppState.proposals`
/// filters on `canPerform`, so the list is allowed to be empty and never allowed to lie.
///
/// **Session**, below it: what happened, in order, and who said it. Four voices — you, the app, the
/// Director, a persona by name — and the two that a model wrote are marked in the accent, so "the
/// app reported this" and "the band said this" are never the same kind of line.
///
/// The composer sends. What comes back streams into the log as it arrives rather than appearing
/// whole at the end, and under the field is the one honest number a thing that spends money owes
/// you: what this session has cost.
struct ConversationRail: View {
    let app: AppState
    @FocusState private var isComposing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SmallLabel("Band")
                Spacer()
                Text("\(app.log.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                CollapseButton(region: .rail, app: app)
            }
            .padding(.horizontal, 28)
            .frame(height: FrameLayout.headerHeight)

            Hairline()
            nextBlock
            Hairline()
            history
            Hairline()
            composer
        }
        .background(Design.Palette.paper)
    }

    // MARK: What next

    private var nextBlock: some View {
        let proposals = app.proposals
        return VStack(alignment: .leading, spacing: 10) {
            SmallLabel(proposals.first?.source.label ?? Proposal.Source.session.label)
            if proposals.isEmpty {
                Text(emptyLine)
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(proposals.enumerated()), id: \.element.id) { index, proposal in
                    ProposalButton(proposal: proposal, isLeading: index == 0) {
                        app.perform(proposal.action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Design.Palette.panelAlt)
    }

    /// The honest version of an empty list. A song with nothing in it gets no invented work.
    private var emptyLine: String {
        guard let song = app.song else {
            return "No song open. Pick one from the library on the left, or press Record in the dock "
                + "above the bench and drop an audio file on it."
        }
        if song.versions.isEmpty {
            return "\(song.title) is empty — nothing has been imported or made in it yet, so there is "
                + "nothing to suggest. Press Record in the dock above the bench and drop a file on it."
        }
        return "Nothing obvious left. Every surface is a press away in the dock above the bench."
    }

    // MARK: The session log

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if app.log.isEmpty {
                        EmptyNote(title: "Nothing has happened yet.",
                                  detail: "Open a song from the library, or a surface from the bench. What you do shows up here.")
                    }
                    ForEach(app.log) { entry in
                        LogLine(source: entry.source, text: entry.text, detail: entry.detail)
                            .id(entry.id)
                    }
                    // The turn in flight, drawn exactly like a finished Director line and replaced
                    // by the real entry when it lands. This is the streaming: the rail fills in
                    // while the work is happening, not twenty seconds afterwards.
                    if let band = app.band, band.isWorking {
                        LogLine(source: .director,
                                text: band.streaming.isEmpty ? (band.activity ?? "Working…") : band.streaming,
                                detail: band.streaming.isEmpty ? nil : band.activity)
                            .id(Self.draftID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .onChange(of: app.log.count) {
                guard let last = app.log.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: app.band?.streaming ?? "") {
                guard app.band?.isWorking == true else { return }
                proxy.scrollTo(Self.draftID, anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The anchor the reply-in-flight scrolls to. A constant rather than a `UUID()` in the body,
    /// which would be a new identity on every render and would scroll on every keystroke.
    private static let draftID = "director.draft"

    // MARK: The composer

    /// The field that sends, and the one line under it that says what this is costing.
    @ViewBuilder
    private var composer: some View {
        if let band = app.band {
            LiveComposer(band: band, isComposing: $isComposing)
        } else {
            InertComposer()
        }
    }
}

// MARK: - One line in the log

/// A line, with who said it above it.
///
/// The accent is the whole design: a line a model wrote is drawn in the accent and a line the app
/// wrote is not, so the log can be read at a glance for the one distinction that matters. A
/// persona's line needs nothing added here — it arrives as `.persona(name)`, prints its own name,
/// and gets the accent because `isBand` is true for it.
struct LogLine: View {
    let source: SessionEntry.Source
    let text: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SmallLabel(source.label,
                       color: source.isBand ? Design.Palette.accent : Design.Palette.inkSecondary)
            Text(text)
                .font(Design.Typography.prose(16))
                .foregroundStyle(Design.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The composer

/// Ask the band. Return sends, escape stops, and the field never eats what you typed.
struct LiveComposer: View {
    @Bindable var band: DirectorSession
    @FocusState.Binding var isComposing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Ask the band…", text: $band.composing, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(Design.Typography.prose(15))
                    .foregroundStyle(Design.Palette.ink)
                    .focused($isComposing)
                    .disabled(band.isWorking)
                    .onSubmit { band.send() }

                if band.isWorking {
                    // Stop is the only control while a turn is in flight, and it is always safe:
                    // the song graph is append-only, so whatever landed is real and the rest is
                    // simply dropped.
                    ChipButton(systemImage: "stop.fill", help: "Stop this turn (⎋)") { band.cancel() }
                } else {
                    ChipButton(systemImage: "arrow.right",
                               help: band.canSend ? "Send (⏎)" : "Type something to send",
                               isOn: band.canSend) {
                        band.send()
                    }
                    .disabled(!band.canSend)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(band.isWorking ? Design.Palette.accent : Design.Palette.lineStrong,
                            lineWidth: Design.Metric.hairline)
            )

            // Honest and quiet: what the session has spent, in the place you spend it, at the size
            // of a footnote. Before the first turn it says whether there is a key at all, which is
            // the only other thing you would want to know from here.
            Text(band.footnote)
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(band.keyStatus.hasKey ? Design.Palette.inkSecondary : Design.Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
                .help("What this session has spent, and how much of each prompt came out of the cache.")
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .onExitCommand { band.cancel() }
        .task { await band.refreshKeyStatus() }
    }
}

/// What a session with no band shows: the field, obviously not usable, and the reason.
struct InertComposer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Ask the band…")
                    .font(Design.Typography.prose(15))
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline)
            )

            Text("This session has no band attached, so the field cannot send. "
                 + "What next is still the song telling you what it is missing.")
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .allowsHitTesting(false)
    }
}
