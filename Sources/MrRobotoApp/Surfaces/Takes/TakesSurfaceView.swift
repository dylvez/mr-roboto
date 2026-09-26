import SongGraph
import SwiftUI

/// Takes as lanes against the bars, the comp lane on top, flags on the bars they belong to.
///
/// The lanes themselves are `TakesLanes`, which the Booth draws too, under the section it records:
/// singing and comping are one act there, and this surface is where a ledger row or the Director
/// opens one part's takes on their own.
struct TakesSurfaceView: View {
    @Bindable var model: TakesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            if model.takes.isEmpty {
                empty
            } else {
                // Scrolls rather than overflows: an evening's takes are more lanes than a
                // surface is tall.
                ScrollsInside {
                    TakesLanes(model: model)
                }
                TakesNote(model: model)
            }
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.sectionName.map { "\($0) takes" } ?? "Takes").font(Design.Typography.prose(16, weight: .medium))
            Text("\(model.takes.count) take\(model.takes.count == 1 ? "" : "s") · bars \(model.bars.lowerBound + 1)–\(model.bars.upperBound)")
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            HearCompButton(model: model)
            MakeCompButton(model: model)
        }
    }

    /// With nothing to comp there is no lane to draw. Takes come from the Booth, so it says where
    /// to go and opens it.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyNote(title: "No takes yet.",
                      detail: "Takes are recorded in the Booth: pick a section, press Record and sing it. "
                          + "Every take you stop lands there and here as a lane.")
            FrameButton(title: "Open the Booth", emphasis: .accent) { model.openBooth() }
                .help("The Booth, on the song's active section (⌘0)")
        }
    }
}

/// A pane's content, scrolling inside the pane rather than pushing the surface past its edge.
///
/// Offscreen — the test renders — an AppKit scroll view draws nothing at all, so there the content
/// is drawn clipped to the pane instead, and a render shows what the pane holds.
struct ScrollsInside<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        if Design.isOffscreenRender {
            // A minimum of zero, or the frame grows to the content's height and clips nothing.
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
                // Shown whether or not you are scrolling: with the system's overlay scrollers a
                // panel cut off at its bottom edge — Structure's Chop row, a critic's findings —
                // gave no sign there was more below.
                .scrollIndicators(.visible)
        }
    }
}

/// "Hear the comp": the comp lane as it stands, rendered and played, nothing kept. Pressed again
/// while it sounds, it stops.
struct HearCompButton: View {
    var model: TakesModel

    var body: some View {
        Button {
            Task { model.isHearingComp ? model.stopAudition() : await model.hearComp() }
        } label: {
            // "Hear" when the Booth's takes pane is narrow, rather than "Hear the co…".
            ViewThatFits(in: .horizontal) {
                Label(model.isHearingComp ? "Stop" : "Hear the comp", systemImage: model.isHearingComp ? "stop.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                Label(model.isHearingComp ? "Stop" : "Hear", systemImage: model.isHearingComp ? "stop.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
        }
        .font(Design.Typography.ui(12.5))
        .disabled(model.takes.isEmpty)
        .help(model.isHearingComp ? "Stop the comp" : "Play the comp lane as chosen, bar by bar, without keeping it")
    }
}

/// "Make the comp": the comp lane rendered as one new version with the takes as its parents.
///
/// A button, not something that happens as the bars are chosen — the app's rule (`Keeping.swift`)
/// is that an edit keeps itself and making something new is a decision. Off once the comp lane is
/// the comp already made, so pressing it twice cannot file the same audio twice.
struct MakeCompButton: View {
    var model: TakesModel

    var body: some View {
        Button("Make the comp") { model.keepComp() }
            .font(Design.Typography.ui(12.5))
            .disabled(model.takes.isEmpty || model.compIsCurrent)
            .help(model.compIsCurrent
                  ? "The comp lane is the comp already made. Take a bar from another take to make a new one."
                  : "Renders the comp lane as one new version, with the takes as its parents.")
    }
}

/// The line under the lanes: what went wrong making the comp, or how the lanes work.
struct TakesNote: View {
    var model: TakesModel

    var body: some View {
        if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else {
            Text("Press a bar on a take's lane to take that bar from it. The comp is one version; the takes stay under it.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

/// The comp lane and a lane per take, the bars across, the band's flags under the take they are on.
/// Drawn by the Takes surface and by the Booth, so the two cannot disagree about what a lane is.
struct TakesLanes: View {
    var model: TakesModel
    /// The column the lane names sit in. The Booth shares its width with the words, so it runs
    /// this narrower than the Takes surface does.
    var titleWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            laneRow(title: "Comp", subtitle: compLine, isComp: true, version: nil)
            ForEach(model.takes) { take in
                laneRow(title: PartLabel.title(of: take), subtitle: detail(take), isComp: false, version: take)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Under the comp lane's name: the one-press pick, or the way back from it.
    @ViewBuilder
    private var pickLink: some View {
        if model.choicesBeforePick != nil {
            Button("Put back my bars") { model.putBackPick() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(11, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .help("The bars as you had them before the pick")
        } else if model.canPickClean {
            Button("Pick the clean bars") { model.pickCleanBars() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(11, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .help("Each bar from the take the band flags least there; a tie goes to the later take. Nothing is made until you make the comp.")
        }
    }

    /// What the comp lane is: the version it was made as, until a bar is chosen differently.
    private var compLine: String {
        guard let comp = model.comp else { return "a take for each bar" }
        return model.compIsCurrent ? "in the song as \(PartLabel.title(of: comp))" : "changed since \(PartLabel.title(of: comp))"
    }

    private func detail(_ take: PartVersion) -> String {
        guard let audio = Guidance.audio(of: take), let meta = audio.take else { return "" }
        let flags = model.flags[take.id]?.count ?? 0
        return String(format: "bar %d · %.1f s%@", meta.startBar + 1, audio.duration, flags > 0 ? " · \(flags) flag\(flags == 1 ? "" : "s")" : "")
    }

    private func laneRow(title: String, subtitle: String, isComp: Bool, version: PartVersion?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let version {
                            let isPlaying = model.playing == version.id
                            Button {
                                Task { isPlaying ? model.stopAudition() : await model.audition(version) }
                            } label: {
                                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                    .font(Design.Typography.ui(9))
                                    .foregroundStyle(Design.Palette.accent)
                                    .frame(width: Design.Metric.tagHeight, height: Design.Metric.tagHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isPlaying ? "Stop \(title)" : "Play \(title) on its own")
                            .accessibilityLabel(isPlaying ? "Stop \(title)" : "Play \(title)")
                        }
                        Text(title).font(Design.Typography.ui(13, weight: isComp ? .semibold : .medium)).lineLimit(1)
                    }
                    // Two lines before an ellipsis: the flag count is what a take's line is read for,
                    // and it is last, so one line cut it to "2 fla…".
                    Text(subtitle).font(Design.Typography.numeric(10.5)).foregroundStyle(Design.Palette.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(subtitle)
                    if isComp { pickLink }
                }
                .frame(width: titleWidth, alignment: .leading)
                HStack(spacing: 2) {
                    ForEach(Array(model.bars), id: \.self) { bar in
                        barCell(bar: bar, isComp: isComp, version: version)
                    }
                }
            }
            if let version, let flags = model.flags[version.id], !flags.isEmpty {
                // The band's flags, each a chip that opens its Check: the bar and the number. They
                // wrap, so a take the band has a lot to say about stays inside its lane.
                FlowRow(spacing: 6) {
                    ForEach(flags) { finding in
                        Button { model.openCheck(finding, on: version) } label: {
                            Text(finding.headline)
                                .font(Design.Typography.numeric(10.5))
                                .foregroundStyle(finding.severity == .warn ? Design.Palette.warn : Design.Palette.inkSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(finding.severity == .warn ? Design.Palette.warnSoft : Design.Palette.panelAlt,
                                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                        }
                        .buttonStyle(.plain)
                        .help(finding.why)
                    }
                }
                .padding(.leading, titleWidth + 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func barCell(bar: Int, isComp: Bool, version: PartVersion?) -> some View {
        let chosen = model.take(forBar: bar)
        let isChosen = isComp ? chosen != nil : chosen == version?.id
        let covers = version.map { model.covers($0, bar: bar) } ?? true
        let flagged = version.flatMap { model.flags[$0.id] }?.contains { $0.locus.bar == bar } ?? false
        return Button {
            if let version { model.choose(version.id, forBar: bar) }
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isChosen && covers ? Design.Palette.accentSoft : (covers ? Design.Palette.panelAlt : Design.Palette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(isChosen && covers ? Design.Palette.accent.opacity(0.5) : Design.Palette.line, lineWidth: Design.Metric.hairline))
                if flagged {
                    Circle().fill(Design.Palette.warn).frame(width: 5, height: 5).padding(3)
                }
                // The number steps aside when a long section leaves the cell narrower than it,
                // rather than the lane growing past its pane.
                ViewThatFits(in: .horizontal) {
                    Text("\(bar + 1)")
                        .font(Design.Typography.numeric(9))
                        .foregroundStyle(isChosen && covers ? Design.Palette.accent : Design.Palette.inkTertiary)
                        .lineLimit(1)
                    Color.clear
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 6, maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isComp || !covers)
        .help(cellHelp(bar: bar, isComp: isComp, version: version, covers: covers))
        .accessibilityLabel(isComp ? "Comp, bar \(bar + 1)" : "Bar \(bar + 1)")
    }

    /// Why a cell does what it does — and, for the ones that do nothing, why not. The comp lane is
    /// read-only because it is the result of the choices on the take lanes.
    private func cellHelp(bar: Int, isComp: Bool, version: PartVersion?, covers: Bool) -> String {
        if isComp {
            let from = model.take(forBar: bar).flatMap { id in model.takes.first { $0.id == id } }.map(PartLabel.title(of:))
            return (from.map { "Bar \(bar + 1) comes from \($0). " } ?? "")
                + "The comp lane shows the choice; press a bar on a take's lane to change it. Hear the comp plays it."
        }
        guard let version else { return "" }
        guard covers else { return "\(PartLabel.title(of: version)) has no audio under bar \(bar + 1)." }
        return "Take bar \(bar + 1) from \(PartLabel.title(of: version))."
    }

}
