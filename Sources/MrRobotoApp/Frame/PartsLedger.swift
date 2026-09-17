import SongGraph
import SwiftUI

/// Every part version in the open song, with the line that says where it came from and the one
/// obvious thing to do with it.
///
/// A row is a verb, not a label. Clicking it accents the row *and* opens the surface that kind of
/// part belongs in — a stem chops, a chop re-grooves, a groove opens in the Grid, the record shows
/// itself — because a ledger whose rows only highlight is a list of nouns you cannot use. The rows
/// Gate A has no surface for say nothing rather than offering an action that opens nothing.
struct PartsLedger: View {
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SmallLabel("Parts")
                Spacer()
                Text("\(app.versions.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
            .padding(.horizontal, Design.Metric.inset)
            .frame(height: FrameLayout.headerHeight)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if app.song == nil {
                        EmptyNote(title: "No song open.",
                                  detail: "Open one from the library and its parts appear here.")
                            .padding(.horizontal, Design.Metric.inset)
                            .padding(.top, 16)
                    } else if app.versions.isEmpty {
                        EmptyNote(title: "No parts yet.",
                                  detail: "Every version a surface makes is listed here, newest last, with what made it.")
                            .padding(.horizontal, Design.Metric.inset)
                            .padding(.top, 16)
                    } else {
                        ForEach(app.versions) { version in
                            row(version)
                            Hairline()
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
        }
        .background(Design.Palette.panelAlt)
    }

    private func row(_ version: PartVersion) -> some View {
        let isSelected = app.selectedVersion == version.id
        let action = app.song.flatMap { PartActions.primary(for: version, in: $0) }
        return Button {
            // Select either way — an inert kind still accents — but when the kind has a surface,
            // selecting it is what opens it. `perform` selects as part of carrying the action out.
            if let action, app.canPerform(action.action) {
                app.perform(action.action)
            } else {
                app.select(version.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(PartLabel.title(of: version))
                        .font(Design.Typography.ui(14.5, weight: .medium))
                        .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(app.versionNumber(of: version.id).map { "v\($0)" } ?? "")
                        .font(Design.Typography.numeric(11))
                        .foregroundStyle(Design.Palette.inkSecondary)
                }
                Text(app.provenanceLine(for: version))
                    .font(Design.Typography.ui(12, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    ActionTag(title: action.title, isSelected: isSelected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Metric.inset)
            .padding(.vertical, 10)
            .background(isSelected ? Design.Palette.accentSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.map { "\($0.title) — \($0.rationale)" } ?? "Gate A has no surface for this kind of part yet")
    }
}

/// The verb on a ledger row: what clicking it will do, said before you click it.
private struct ActionTag: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.forward")
                .font(.system(size: 8, weight: .semibold))
            Text(title)
                .font(Design.Typography.ui(11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Design.Palette.accent)
        .padding(.horizontal, 6)
        .frame(height: Design.Metric.tagHeight)
        .background(isSelected ? Design.Palette.panel : Design.Palette.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .padding(.top, 2)
    }
}
