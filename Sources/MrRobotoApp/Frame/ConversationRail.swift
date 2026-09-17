import SwiftUI

/// The thread. In Gate A there is no agent, so this is the session's own history: what you did, in
/// order, in your own words and the app's. Nothing is ever attributed to a band member that did not
/// say it — there is no band yet.
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

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if app.log.isEmpty {
                            EmptyNote(title: "Nothing has happened yet.",
                                      detail: "Open a song from the library, or a surface from the Surfaces menu. What you do shows up here.")
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

            Hairline()
            composer
        }
        .background(Design.Palette.paper)
    }

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

            Text("Gate A is the instrument: you play it yourself. The band — and this field — arrive in Gate B.")
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
