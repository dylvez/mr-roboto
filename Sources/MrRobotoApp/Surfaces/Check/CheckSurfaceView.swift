import Performance
import SongGraph
import SwiftUI

/// The Check surface: one finding, who found it, the bar, why, and two fixes — with a way to hear
/// the problem before you decide anything.
///
/// The warn colour is spent on exactly one thing here: the finding's own severity mark. The accent
/// is spent on exactly one thing: whatever is currently sounding. Everything else is ink on panel,
/// so all three themes carry the card without it knowing they exist.
public struct CheckSurfaceView: View {
    @Bindable public var model: CheckModel

    public init(model: CheckModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = CheckLayout(size: geometry.size)
            HStack(spacing: 0) {
                Spacer(minLength: layout.cardInset)
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    header(layout)
                    headline(layout)
                    HearIt(model: model, layout: layout)
                    if layout.showsArithmetic { Arithmetic(model: model) }
                    Fixes(model: model, layout: layout)
                    footer
                    Spacer(minLength: 0)
                }
                .frame(width: layout.cardWidth, alignment: .leading)
                Spacer(minLength: layout.cardInset)
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header — who found it

    private func header(_ layout: CheckLayout) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.attribution)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            Spacer()
            if model.isResolved {
                Tag(text: "fixed", tint: Design.Palette.accent, ground: Design.Palette.accentSoft)
            } else if model.isDismissed {
                // "Left as is", not "kept": Keep is the verb for saving a version everywhere else
                // in the frame, and a dismissed finding saved nothing.
                Tag(text: "left as is", tint: Design.Palette.inkSecondary, ground: Design.Palette.panelAlt)
            } else if model.finding.severity == .warn {
                Tag(text: "warn", tint: Design.Palette.warn, ground: Design.Palette.warnSoft)
            } else {
                Tag(text: "note", tint: Design.Palette.inkSecondary, ground: Design.Palette.panelAlt)
            }
        }
    }

    // MARK: The finding itself

    private func headline(_ layout: CheckLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.finding.headline)
                .font(Design.Typography.prose(layout.headlineSize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.where_)
                .font(Design.Typography.numeric(11.5))
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(model.finding.why)
                .font(Design.Typography.prose(layout.reasonSize))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let outcome = model.lastOutcome {
                Text(outcome.spoken)
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(outcome.didResolve ? Design.Palette.accent : Design.Palette.warn)
            } else if let error = model.lastError {
                Text(error)
                    .font(Design.Typography.ui(11.5))
                    .foregroundStyle(Design.Palette.warn)
            }
            Spacer()
            if model.isOpen {
                Button("Leave it") { model.dismiss() }
                    .font(Design.Typography.ui(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .help("I hear it and I want it: leave the part as it is. Nothing is fixed and nothing is lost; the card can be reopened.")
                    .accessibilityLabel("Leave it as it is")
            } else if model.isDismissed {
                Button("Look again") { model.reopen() }
                    .font(Design.Typography.ui(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .help("Reopens the finding so its fixes can be heard and applied.")
            }
        }
    }
}

// MARK: - Hear it

/// The first control on the card, and the one that makes the rest worth reading.
private struct HearIt: View {
    @Bindable var model: CheckModel
    let layout: CheckLayout

    var body: some View {
        Button { model.isPlayingProblem ? model.stop() : model.hearProblem() } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.isPlayingProblem ? Design.Palette.accent : Design.Palette.inkSecondary)
                    .frame(width: 10, height: 10)
                Text(model.isPlayingProblem ? "Playing — \(model.where_)" : "Hear the problem")
                    .font(Design.Typography.ui(13))
                Spacer()
                Text(String(format: "%.3g s", max(0.05, model.finding.locus.duration)))
                    .font(Design.Typography.numeric(11))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: CheckLayout.hearHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.isPlayingProblem ? Design.Palette.accentSoft : Design.Palette.panelAlt)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(model.isPlayingProblem ? Design.Palette.accent : Design.Palette.line,
                            lineWidth: Design.Metric.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The arithmetic

/// What was measured against what it was measured to, and the critic's own sentence about the
/// check. Shown only where there is room; the finding is complete without it.
private struct Arithmetic: View {
    let model: CheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Reading(label: "measured",
                        value: String(format: "%.4g %@", model.finding.measurement.measured,
                                      model.finding.measurement.unit))
                Reading(label: "wanted",
                        value: model.finding.measurement.threshold.description)
                Spacer()
            }
            Text(model.finding.critic.rawValue)
                .font(Design.Typography.numeric(10))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private struct Reading: View {
        let label: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.0)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Text(value)
                    .font(Design.Typography.numeric(12.5))
            }
        }
    }
}

// MARK: - The two fixes

private struct Fixes: View {
    @Bindable var model: CheckModel
    let layout: CheckLayout

    var body: some View {
        if layout.fixesSideBySide {
            HStack(alignment: .top, spacing: Design.Metric.gutter) {
                ForEach(model.fixes) { fix in
                    FixCard(model: model, fix: fix, layout: layout)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                ForEach(model.fixes) { fix in
                    FixCard(model: model, fix: fix, layout: layout)
                }
            }
        }
    }
}

private struct FixCard: View {
    @Bindable var model: CheckModel
    let fix: Fix
    let layout: CheckLayout

    private var isChosen: Bool { model.resolvedBy == fix.id }
    private var wasApplied: Bool { model.applied.contains { $0.id == fix.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fix.title)
                .font(Design.Typography.prose(13.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(fix.detail)
                .font(Design.Typography.ui(11.5, weight: .regular))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(model.isPlaying(fix.id) ? "Stop" : "Hear it") {
                    model.isPlaying(fix.id) ? model.stop() : model.hear(fix)
                }
                .font(Design.Typography.ui(11.5))
                .buttonStyle(.plain)
                .foregroundStyle(model.canPreview(fix) ? Design.Palette.accent : Design.Palette.inkTertiary)
                .disabled(!model.canPreview(fix))

                Button(isChosen ? "Applied" : "Apply") {
                    Task { await model.apply(fix) }
                }
                .font(Design.Typography.ui(11.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(isChosen ? Design.Palette.inkTertiary : Design.Palette.accent)
                .disabled(isChosen)

                Spacer()
                if wasApplied, !isChosen {
                    Text("did not resolve")
                        .font(Design.Typography.ui(10.5))
                        .foregroundStyle(Design.Palette.warn)
                }
            }
        }
        .padding(12)
        .frame(width: layout.fixWidth == layout.cardWidth ? nil : layout.fixWidth,
               height: layout.fixHeight, alignment: .topLeading)
        .frame(maxWidth: layout.fixWidth == layout.cardWidth ? .infinity : nil, alignment: .leading)
        .background(isChosen ? Design.Palette.accentSoft : Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(isChosen ? Design.Palette.accent : Design.Palette.line,
                        lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}

// MARK: - Shared

private struct Tag: View {
    let text: String
    let tint: Color
    let ground: Color

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.0)
            .padding(.horizontal, 7)
            .frame(height: Design.Metric.tagHeight)
            .background(ground)
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}
