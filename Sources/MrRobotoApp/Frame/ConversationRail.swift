import SwiftUI

/// The thread. Two halves, in the order you need them.
///
/// **What next**, at the top: what this song could use, derived from what it actually holds, one
/// click each. In Gate B these are the Director's proposals; in Gate A `Guidance` derives the same
/// values from the song graph, so the rail renders `[Proposal]` either way and does not get rebuilt
/// when the band arrives. Nothing appears here that does not work when clicked — `AppState.proposals`
/// filters on `canPerform`, so the list is allowed to be empty and never allowed to lie.
///
/// **Session**, below it: what you did, in order, in your own words and the app's. Nothing is ever
/// attributed to a band member that did not say it — there is no band yet.
///
/// The composer is present because the frame is the frame, but it is inert and says so.
struct ConversationRail: View {
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SmallLabel("Session")
                Spacer()
                Text("\(app.log.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
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
            return "No song open. Pick one from the library on the left, or open Import from the bench "
                + "above the surfaces and drop a record on it."
        }
        if song.versions.isEmpty {
            return "\(song.title) is empty — nothing has been imported or made in it yet, so there is "
                + "nothing to suggest. Open Import from the bench and drop a record on it."
        }
        return "Nothing obvious left. Every surface is still open from the bench above."
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
                        VStack(alignment: .leading, spacing: 6) {
                            SmallLabel(entry.source.rawValue)
                            Text(entry.text)
                                .font(Design.Typography.prose(16))
                                .foregroundStyle(Design.Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(Design.Typography.ui(11.5, weight: .regular))
                                    .foregroundStyle(Design.Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id(entry.id)
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
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: The composer

    /// Present, obviously not usable, and honest about why.
    private var composer: some View {
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

            Text("Gate A is the instrument: you play it yourself, and What next is the song telling you "
                 + "what it is missing. The band — and this field — arrive in Gate B.")
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
