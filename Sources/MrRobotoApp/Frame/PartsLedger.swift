import SongGraph
import SwiftUI

/// Every part version in the open song, with the line that says where it came from. The selected one
/// is the only accented thing in the column — that is the whole budget for accent on this side.
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
        return Button {
            app.select(version.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(version.type.rawValue.capitalized)
                        .font(Design.Typography.ui(14.5, weight: .medium))
                        .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.ink)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Metric.inset)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
