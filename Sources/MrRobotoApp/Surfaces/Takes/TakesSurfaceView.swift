import SongGraph
import SwiftUI

/// Takes as lanes against the bars, the comp lane on top, flags on the bars they belong to.
struct TakesSurfaceView: View {
    @Bindable var model: TakesModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            if model.takes.isEmpty {
                empty
            } else {
                lanes
                footer
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
            Button("Keep the comp") { model.keepComp() }
                .font(Design.Typography.ui(12.5))
                .disabled(model.takes.isEmpty)
                .help("Renders the comp lane as one new version, with the takes as its parents.")
        }
    }

    /// With nothing to comp there is no lane to draw. Takes come from the Booth, and this surface
    /// cannot open it — its host records and plays takes, nothing more — so it says where to go.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyNote(title: "No takes yet.",
                      detail: "Takes are recorded in the Booth: pick a section, press Record and sing it. "
                          + "Every take you stop lands here as a lane.")
            FrameButton(title: "Open the Booth", emphasis: .accent) { model.openBooth() }
                .help("The Booth, on the song's active section (⌘0)")
        }
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: 6) {
            laneRow(title: "Comp", subtitle: model.comp.map { "kept as \(PartLabel.title(of: $0))" } ?? "choose a take for each bar",
                    isComp: true, version: nil)
            ForEach(model.takes) { take in
                laneRow(title: PartLabel.title(of: take), subtitle: detail(take), isComp: false, version: take)
            }
        }
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
                Text(subtitle).font(Design.Typography.numeric(10.5)).foregroundStyle(Design.Palette.inkTertiary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(Array(model.bars), id: \.self) { bar in
                    barCell(bar: bar, isComp: isComp, version: version)
                }
            }
            }
            if let version, let flags = model.flags[version.id], !flags.isEmpty {
                // The band's flags, each a chip that opens its Check: the bar and the number.
                HStack(spacing: 6) {
                    ForEach(flags) { finding in
                        Button { model.openCheck(finding, on: version) } label: {
                            Text(finding.headline)
                                .font(Design.Typography.numeric(10.5))
                                .foregroundStyle(finding.severity == .warn ? Design.Palette.warn : Design.Palette.inkSecondary)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(finding.severity == .warn ? Design.Palette.warnSoft : Design.Palette.panelAlt,
                                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                        }
                        .buttonStyle(.plain)
                        .help(finding.why)
                    }
                }
                .padding(.leading, 158)
            }
        }
        .padding(.vertical, 4)
    }

    private func barCell(bar: Int, isComp: Bool, version: PartVersion?) -> some View {
        let chosen = model.take(forBar: bar)
        let isChosen = isComp ? chosen != nil : chosen == version?.id
        let covers = version.map { covers($0, bar: bar) } ?? true
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
                Text("\(bar + 1)")
                    .font(Design.Typography.numeric(9))
                    .foregroundStyle(isChosen && covers ? Design.Palette.accent : Design.Palette.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 22, maxWidth: .infinity)
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .disabled(isComp || !covers)
        .help(cellHelp(bar: bar, isComp: isComp, version: version, covers: covers))
        .accessibilityLabel(isComp ? "Comp, bar \(bar + 1)" : "Bar \(bar + 1)")
    }

    /// Why a cell does what it does — and, for the ones that do nothing, why not. The comp lane is
    /// read-only because it is the result of the choices on the take lanes, and there is no way to
    /// hear it before keeping it: the host plays takes, not a plan.
    private func cellHelp(bar: Int, isComp: Bool, version: PartVersion?, covers: Bool) -> String {
        if isComp {
            let from = model.take(forBar: bar).flatMap { id in model.takes.first { $0.id == id } }.map(PartLabel.title(of:))
            return (from.map { "Bar \(bar + 1) comes from \($0). " } ?? "")
                + "The comp lane shows the choice; press a bar on a take's lane to change it. Keep the comp to hear it."
        }
        guard let version else { return "" }
        guard covers else { return "\(PartLabel.title(of: version)) has no audio under bar \(bar + 1)." }
        return "Take bar \(bar + 1) from \(PartLabel.title(of: version))."
    }

    /// Whether a take has audio under this bar.
    private func covers(_ version: PartVersion, bar: Int) -> Bool {
        guard let audio = Guidance.audio(of: version), let take = audio.take else { return false }
        let start = model.clock.seconds(forBar: take.startBar) + take.startBeat * model.clock.secondsPerBeat
        let end = start + audio.duration
        let barStart = model.clock.seconds(forBar: bar), barEnd = model.clock.seconds(forBar: bar + 1)
        return end > barStart + 0.05 && start < barEnd - 0.05
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError {
            Text(error).font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.warn)
        } else {
            Text("Press a bar on a take's lane to take that bar from it. The comp is one version; the takes stay under it.")
                .font(Design.Typography.ui(11)).foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}
