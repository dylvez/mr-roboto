import SwiftUI

/// The small pieces the six regions share. Every colour and size comes from `Design`; nothing here
/// hard-codes either, so retuning the palette retunes the whole frame.

/// The uppercase, letterspaced label that sits above a control or a column.
struct SmallLabel: View {
    let text: String
    var color: Color = Design.Palette.inkSecondary

    init(_ text: String, color: Color = Design.Palette.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// A bordered square control: the pin and close in a surface header, the transport's glyphs.
struct ChipButton: View {
    let systemImage: String
    var help: String = ""
    var isOn: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: Design.Metric.chipHeight, height: Design.Metric.chipHeight)
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(isOn ? Design.Palette.accent : Design.Palette.lineStrong,
                                lineWidth: Design.Metric.hairline)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

/// The header's buttons: quiet (History), outlined (Save), accented (the one thing worth doing).
struct FrameButton: View {
    enum Emphasis { case quiet, outlined, accent }

    let title: String
    var emphasis: Emphasis = .outlined
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(12.5, weight: emphasis == .accent ? .semibold : .medium))
                .tracking(0.2)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(height: Design.Metric.controlHeight)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(border, lineWidth: Design.Metric.hairline)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch emphasis {
        case .quiet: return Design.Palette.inkSecondary
        case .outlined: return Design.Palette.ink
        case .accent: return Design.Palette.panel
        }
    }

    private var background: Color {
        switch emphasis {
        case .quiet, .outlined: return .clear
        case .accent: return Design.Palette.accent
        }
    }

    private var border: Color {
        switch emphasis {
        case .quiet: return Design.Palette.lineStrong
        case .outlined: return Design.Palette.ink
        case .accent: return Design.Palette.accent
        }
    }
}

/// A proposal, as a thing you press: the verb, the surface it opens, and the quiet line saying why.
///
/// Shared by the rail's "What next" block and by the surfaces that are empty because nothing is bound
/// to them, so an offer looks the same wherever it is made — and, more to the point, so there is one
/// control that takes a `Proposal` and no second way to render one when the Director starts sending
/// them.
///
/// The leading one carries the accent: one accented thing per region is the catalog's rule, and the
/// next step is what it is spent on.
struct ProposalButton: View {
    let proposal: Proposal
    var isLeading: Bool = false
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(proposal.title)
                        .font(Design.Typography.prose(15, weight: isLeading ? .medium : .regular))
                        .foregroundStyle(isLeading ? Design.Palette.accent : Design.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text(proposal.action.surface.rawValue)
                        .font(Design.Typography.label)
                        .tracking(1.1)
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                Text(proposal.rationale)
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isLeading ? Design.Palette.accentSoft : Design.Palette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isLeading ? Design.Palette.accent : Design.Palette.line,
                            lineWidth: Design.Metric.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(proposal.rationale)
    }
}

/// A one-pixel rule in the frame's line colour. `Divider()` picks its own grey, which is not ours.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Design.Palette.line)
            .frame(width: axis == .vertical ? Design.Metric.hairline : nil,
                   height: axis == .horizontal ? Design.Metric.hairline : nil)
    }
}

/// What a region shows when it has nothing to show. Says what is missing and what would fill it,
/// never a fake row.
struct EmptyNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Design.Typography.prose(14.5))
                .foregroundStyle(Design.Palette.ink)
            Text(detail)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
