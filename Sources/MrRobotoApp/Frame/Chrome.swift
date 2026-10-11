import SwiftUI

/// The small pieces the six regions share. Every colour and size comes from `Design`; nothing here
/// hard-codes either, so retuning the palette retunes the whole frame.
///
/// Each piece draws itself the way the current theme's `Design.style` says: outlined in Cool, filled
/// in Studio. The surfaces never ask which theme is current; they use these.

/// The label that sits above a control or a column: letterspaced capitals in Cool, sentence case in
/// Studio. `eyebrow` is a region's name — Band, Parts — which stays in small capitals in both.
struct SmallLabel: View {
    enum Kind { case label, eyebrow }

    let text: String
    var color: Color = Design.Palette.inkSecondary
    var kind: Kind = .label

    init(_ text: String, color: Color = Design.Palette.inkSecondary, kind: Kind = .label) {
        self.text = text
        self.color = color
        self.kind = kind
    }

    var body: some View {
        if Design.style.uppercaseLabels {
            Text(text.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(color)
        } else if kind == .eyebrow {
            Text(text.uppercased())
                .font(Design.Typography.role(.eyebrow))
                .tracking(0.6)
                .foregroundStyle(color)
        } else {
            Text(text)
                .font(Design.Typography.role(.label))
                .foregroundStyle(color)
        }
    }
}

/// A square control with a glyph: the pin and close in a surface header, the composer's send. An
/// outlined box in Cool; in Studio no box at all until the pointer is over it, and a fill when on.
struct ChipButton: View {
    let systemImage: String
    var help: String = ""
    var isOn: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if Design.style.filledControls {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: Design.Metric.chipHeight + 4, height: Design.Metric.chipHeight + 4)
                    .foregroundStyle(isOn ? Design.Palette.ink : Design.Palette.inkSecondary)
                    .background(isOn ? Design.Palette.selected : (isHovering ? Design.Palette.hover : .clear),
                                in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
                    .contentShape(Rectangle())
            } else {
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
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// The header's buttons: quiet (History), outlined (Save), accented (the one thing worth doing).
/// In Studio quiet is borderless, outlined is a grey fill, and accented is the one filled button.
struct FrameButton: View {
    enum Emphasis { case quiet, outlined, accent }

    let title: String
    var emphasis: Emphasis = .outlined
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if Design.style.filledControls {
                Text(title)
                    .font(.system(size: 13, weight: emphasis == .accent ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 12)
                    .frame(height: Design.Metric.controlHeight)
                    .background(studioBackground, in: RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous))
                    .contentShape(Rectangle())
            } else {
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
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
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

    private var studioBackground: Color {
        switch emphasis {
        case .quiet: return isHovering ? Design.Palette.hover : .clear
        case .outlined: return isHovering ? Design.Palette.hover : Design.Palette.fill
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

/// Studio's chip, for every surface: no outline, a grey fill that steps up under the pointer and
/// again when the chip is on. A tone gives a chip a meaning instead — a caution, a destructive
/// second press, the one primary action — and nothing else is coloured.
struct StudioChip<Label: View>: View {
    enum Tone { case plain, warn, danger, primary, sounding }

    var isOn: Bool = false
    var tone: Tone = .plain
    var height: CGFloat? = nil
    var horizontalPadding: CGFloat = 8
    @ViewBuilder let label: Label

    @State private var isHovering = false

    var body: some View {
        label
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height ?? Design.Metric.chipHeight)
            .background(background, in: RoundedRectangle(cornerRadius: Design.Metric.corner, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch tone {
        case .plain: return isOn ? Design.Palette.ink : Design.Palette.inkSecondary
        case .warn: return Design.Palette.warn
        case .danger: return Design.Palette.danger
        case .primary: return Design.Palette.panel
        case .sounding: return Design.Palette.onSounding
        }
    }

    private var background: Color {
        switch tone {
        case .plain: return isOn ? Design.Palette.selected : (isHovering ? Design.Palette.hover : Design.Palette.fill)
        case .warn: return Design.Palette.warnSoft
        case .danger: return Design.Palette.dangerSoft
        case .primary: return Design.Palette.accent
        case .sounding: return Design.Palette.sounding
        }
    }
}

/// A chip's words in Studio. An "on" chip is set a weight heavier, in a width reserved for that
/// weight, so pressing one never nudges its neighbours.
struct ChipText: View {
    let title: String
    var isOn: Bool = false
    var size: CGFloat = 12

    init(_ title: String, isOn: Bool = false, size: CGFloat = 12) {
        self.title = title
        self.isOn = isOn
        self.size = size
    }

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .overlay {
                Text(title)
                    .font(.system(size: size, weight: isOn ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
    }
}

/// A choice of one among a few — Alone or In the song; Off, Kit, Bass or Keys — drawn as the Mac's
/// segmented control draws it in Studio: a sunken track, the chosen segment raised out of it. Cool
/// keeps a row of its outlined chips.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    var help: (Value) -> String = { _ in "" }
    let choose: (Value) -> Void

    var body: some View {
        if Design.style.filledControls {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let isOn = option == selection
                    Button { choose(option) } label: {
                        ChipText(title(option), isOn: isOn, size: 11.5)
                            .foregroundStyle(isOn ? Design.Palette.ink : Design.Palette.inkSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: Design.Metric.chipHeight - 4)
                            .background {
                                if isOn {
                                    RoundedRectangle(cornerRadius: Design.Metric.corner - 1, style: .continuous)
                                        .fill(Design.Palette.raised)
                                        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(option))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Metric.corner + 1, style: .continuous))
        } else {
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    BoothChip(title(option), isOn: option == selection) { choose(option) }
                        .help(help(option))
                }
            }
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
            if Design.style.filledControls {
                OptionCard(title: proposal.title, rationale: proposal.rationale, isLeading: isLeading,
                           trailing: proposal.action.surface.rawValue)
            } else {
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
        }
        .buttonStyle(.plain)
        .help(proposal.rationale)
    }
}

/// One answer to the band's question: what it does and why, "Your usual" when your history put it
/// there, and "Not this" to wave it away.
struct NextOptionButton: View {
    let option: NextOption
    var isLeading: Bool = false
    /// Its place in the band's ranking, numbered in Studio: the first is what the band would do.
    var rank: Int? = nil
    let take: () -> Void
    let decline: () -> Void

    @State private var isHovering = false

    var body: some View {
        if Design.style.filledControls { studio } else { cool }
    }

    private var studio: some View {
        Button(action: take) {
            OptionCard(title: option.title, rationale: option.rationale, isLeading: isLeading, rank: rank,
                       tag: option.isYourUsual ? "Your usual" : nil, reservesDecline: true)
        }
        .buttonStyle(.plain)
        .help(option.rationale)
        .overlay(alignment: .topTrailing) {
            // "Not this" is there when you are looking at the card, and out of the way when not.
            Button(action: decline) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .opacity(isHovering ? 1 : 0)
            .help("Not this: offered less here from now on")
            .accessibilityLabel("Not this: \(option.title)")
        }
        .onHover { isHovering = $0 }
    }

    private var cool: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: take) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.title)
                            .font(Design.Typography.prose(15, weight: isLeading ? .medium : .regular))
                            .foregroundStyle(isLeading ? Design.Palette.accent : Design.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if option.isYourUsual {
                            Text("YOUR USUAL")
                                .font(Design.Typography.label)
                                .tracking(1.1)
                                .foregroundStyle(Design.Palette.accent)
                                .help("You have chosen this at this point before, so it is offered first")
                        }
                        Spacer(minLength: 4)
                    }
                    Text(option.rationale)
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(option.rationale)
            Button(action: decline) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.trailing, 4)
            .help("Not this: offered less here from now on")
            .accessibilityLabel("Not this: \(option.title)")
        }
        .background(isLeading ? Design.Palette.accentSoft : Design.Palette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(isLeading ? Design.Palette.accent : Design.Palette.line, lineWidth: Design.Metric.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}

/// Studio's card for an offer: no outline, a numbered rank, a title in the body size's semibold and
/// the reason under it in three lines at most. The one the band would take is raised and carries
/// the accent as a bar down its leading edge; the rest sit flat in the column's fill.
struct OptionCard: View {
    let title: String
    let rationale: String
    var isLeading = false
    var rank: Int? = nil
    var tag: String? = nil
    var trailing: String? = nil
    /// Room at the top right for the "Not this" that appears on hover.
    var reservesDecline = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isLeading ? Design.Palette.accent : Design.Palette.inkTertiary)
                    .frame(width: 10, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Design.Typography.role(.headline))
                        .foregroundStyle(Design.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let tag {
                        Text(tag)
                            .font(Design.Typography.role(.caption))
                            .foregroundStyle(Design.Palette.inkSecondary)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Design.Palette.fill, in: Capsule())
                            .fixedSize()
                            .help("You have chosen this at this point before, so it is offered first")
                    }
                    Spacer(minLength: reservesDecline ? 18 : 4)
                    if let trailing {
                        Text(trailing)
                            .font(Design.Typography.role(.caption))
                            .foregroundStyle(Design.Palette.inkTertiary)
                    }
                }
                Text(rationale)
                    .font(Design.Typography.role(.callout))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: Design.Metric.containerCorner, style: .continuous)
            if isLeading {
                shape.fill(Design.Palette.raised)
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            } else {
                shape.fill(Design.Palette.fill)
            }
        }
        .overlay(alignment: .leading) {
            if isLeading {
                Capsule()
                    .fill(Design.Palette.accent)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A one-pixel rule in the frame's line colour. `Divider()` picks its own grey, which is not ours.
///
/// It takes a point of layout either way, which is what the frame's arithmetic counts. Cool fills the
/// point; Studio draws one device pixel in the middle of it, the weight of a Mac's own separators —
/// a whole point is two pixels on a Retina screen, and read as a ruled line rather than an edge.
struct Hairline: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let thickness = Design.style.filledControls ? max(1 / max(displayScale, 1), 0.5) : Design.Metric.hairline
        Rectangle()
            .fill(Design.Palette.line)
            .frame(width: axis == .vertical ? thickness : nil,
                   height: axis == .horizontal ? thickness : nil)
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
                .font(Design.style.filledControls ? Design.Typography.role(.headline) : Design.Typography.prose(14.5))
                .foregroundStyle(Design.Palette.ink)
            Text(detail)
                .font(Design.style.filledControls ? Design.Typography.role(.callout) : Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped area inside a surface — a section's detail, a reading, a list, a note — with the edge
/// the theme draws: a box with a hairline in Cool; in Studio a soft fill with a card's corner and no
/// line, told from the panel around it by its value rather than by an outline.
struct GroupedArea: ViewModifier {
    var fill: Color = Design.Palette.panelAlt
    var stroke: Color = Design.Palette.line

    func body(content: Content) -> some View {
        if Design.style.surfaceCards {
            content
                .background(fill)
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(stroke, lineWidth: Design.Metric.hairline))
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        } else {
            content
                .background(fill, in: RoundedRectangle(cornerRadius: Design.Metric.containerCorner, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Design.Metric.containerCorner, style: .continuous))
        }
    }
}

extension View {
    /// See `GroupedArea`. The fill and the line are Cool's; Studio keeps the fill and drops the line.
    func groupedArea(_ fill: Color = Design.Palette.panelAlt, stroke: Color = Design.Palette.line) -> some View {
        modifier(GroupedArea(fill: fill, stroke: stroke))
    }
}
