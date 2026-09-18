import Performance
import SongGraph
import SwiftUI

/// The Compare surface: two to four candidates as rows, the thing they are judged against at the
/// top, differences marked, at most two levers.
///
/// Every colour, face and metric comes from `Design`, so all three themes work without this file
/// knowing there are three. The one place an accent is spent is the selected row; the one place a
/// warn is spent is a candidate carrying a critic finding. Nothing else is coloured, which is what
/// makes those two mean something.
public struct CompareSurfaceView: View {
    @Bindable public var model: CompareModel

    public init(model: CompareModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = CompareLayout(size: geometry.size,
                                       candidates: model.candidates.count,
                                       features: model.features.count,
                                       levers: model.levers.count)
            VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                header
                ReferenceBand(model: model, layout: layout)
                if !model.levers.isEmpty { LeverStrip(model: model) }
                ColumnHeadings(model: model, layout: layout)
                CandidateRows(model: model, layout: layout)
                footer
                Spacer(minLength: 0)
            }
            .padding(Design.Metric.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Design.Palette.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(SurfaceKind.compare.rawValue.uppercased())
                .font(Design.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Design.Palette.inkTertiary)
            Text(model.title)
                .font(Design.Typography.prose(16, weight: .medium))
            Spacer()
            if model.findingCount > 0 {
                Text("\(model.findingCount) finding\(model.findingCount == 1 ? "" : "s")")
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.warn)
            }
            Button("Take this one") {
                if let id = model.selectedID { Task { await model.choose(id) } }
            }
            .font(Design.Typography.ui(12))
            .buttonStyle(.plain)
            .foregroundStyle(model.selectedID == nil ? Design.Palette.inkTertiary : Design.Palette.accent)
            .disabled(model.selectedID == nil)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let error = model.lastError {
            Text(error)
                .font(Design.Typography.ui(11))
                .foregroundStyle(Design.Palette.warn)
        } else if !model.indistinguishable.isEmpty {
            // A row that reads the same as the reference on every compared feature is not a choice,
            // and saying so is more useful than drawing it as if it were.
            Text(model.indistinguishable.map(\.title).joined(separator: ", ")
                 + " read the same as the reference on everything measured here.")
                .font(Design.Typography.ui(11))
                .foregroundStyle(Design.Palette.inkTertiary)
        }
    }
}

// MARK: - The reference

private struct ReferenceBand: View {
    @Bindable var model: CompareModel
    let layout: CompareLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("JUDGED AGAINST")
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .foregroundStyle(Design.Palette.inkTertiary)
                Spacer()
                PlayDot(isPlaying: model.isPlayingReference) { model.auditionReference() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.reference.title)
                    .font(Design.Typography.prose(15, weight: .medium))
                Text(model.reference.kind)
                    .font(Design.Typography.ui(11))
                    .foregroundStyle(Design.Palette.inkSecondary)
                if layout.referenceReadingsInline { Spacer(); readings }
            }
            if !layout.referenceReadingsInline { readings }
        }
        .padding(12)
        .frame(height: layout.referenceHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(Design.Palette.lineStrong, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }

    private var readings: some View {
        HStack(spacing: 14) {
            ForEach(Array(model.features.prefix(layout.visibleFeatureCount)), id: \.self) { feature in
                Text(model.reference.reading(feature)?.text ?? "—")
                    .font(Design.Typography.numeric(11.5))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
        }
    }
}

// MARK: - Levers

private struct LeverStrip: View {
    @Bindable var model: CompareModel

    var body: some View {
        HStack(alignment: .top, spacing: Design.Metric.gutter) {
            ForEach(model.levers) { lever in
                VStack(alignment: .leading, spacing: 3) {
                    Text(lever.label.uppercased())
                        .font(Design.Typography.label)
                        .tracking(1.1)
                        .foregroundStyle(Design.Palette.inkTertiary)
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { model.value(of: lever) },
                                              set: { model.setLever(lever, to: $0) }),
                               in: lever.range)
                            .frame(width: CompareLayout.leverWidth - 64)
                        Text(String(format: "%.4g%@", model.value(of: lever),
                                    lever.unit.isEmpty ? "" : " " + lever.unit))
                            .font(Design.Typography.numeric(12))
                            .frame(width: 56, alignment: .leading)
                    }
                    Text("applies to every row")
                        .font(Design.Typography.ui(10))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                .frame(width: CompareLayout.leverWidth, alignment: .leading)
            }
            Spacer()
        }
        .frame(height: CompareLayout.leverHeight, alignment: .top)
    }
}

// MARK: - Columns

private struct ColumnHeadings: View {
    let model: CompareModel
    let layout: CompareLayout

    var body: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: layout.titleWidth, alignment: .leading)
            ForEach(Array(model.features.prefix(layout.visibleFeatureCount)), id: \.self) { feature in
                Text(CompareSurfaceView.shortName(of: feature, in: model.vocabulary).uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.0)
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .lineLimit(1)
                    .frame(width: layout.columnWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }
}

// MARK: - Rows

private struct CandidateRows: View {
    @Bindable var model: CompareModel
    let layout: CompareLayout

    var body: some View {
        ScrollView(layout.rowsScroll ? .vertical : []) {
            VStack(spacing: CompareLayout.rowSpacing) {
                ForEach(model.candidates) { candidate in
                    CandidateRow(model: model, candidate: candidate, layout: layout)
                }
            }
        }
        .frame(height: layout.rowsAreaHeight)
    }
}

private struct CandidateRow: View {
    @Bindable var model: CompareModel
    let candidate: CompareCandidate
    let layout: CompareLayout

    private var isSelected: Bool { model.selectedID == candidate.id }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    PlayDot(isPlaying: model.isPlaying(candidate.id)) { model.audition(candidate.id) }
                    Text(candidate.title)
                        .font(Design.Typography.prose(14, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if !candidate.warnings.isEmpty {
                        Text("\(candidate.warnings.count)")
                            .font(Design.Typography.numeric(10))
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Design.Palette.warnSoft)
                            .foregroundStyle(Design.Palette.warn)
                            .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    }
                }
                if let persona = candidate.proposedBy {
                    Text(persona.rawValue)
                        .font(Design.Typography.ui(10))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                if layout.showsRationale, !candidate.rationale.isEmpty {
                    Text(candidate.rationale)
                        .font(Design.Typography.ui(11, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(2)
                }
            }
            .frame(width: layout.titleWidth, alignment: .leading)

            ForEach(Array(model.features.prefix(layout.visibleFeatureCount)), id: \.self) { feature in
                DifferenceCell(reading: candidate.reading(feature),
                               difference: model.difference(feature, for: candidate.id))
                    .frame(width: layout.columnWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: layout.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Design.Palette.accentSoft : Design.Palette.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(isSelected ? Design.Palette.accent : Design.Palette.line,
                        lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .contentShape(Rectangle())
        .onTapGesture { model.select(candidate.id) }
    }
}

/// One cell: the candidate's own number, and under it the marked difference from the reference.
private struct DifferenceCell: View {
    let reading: CompareReading?
    let difference: CompareDifference?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(reading?.text ?? "—")
                .font(Design.Typography.numeric(13))
                .foregroundStyle(Design.Palette.ink)
            if let difference, difference.matters {
                Text(difference.text)
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.accent)
            } else {
                Text("same")
                    .font(Design.Typography.ui(10))
                    .foregroundStyle(Design.Palette.inkTertiary)
            }
        }
    }
}

// MARK: - Shared bits

/// The audition affordance. Small, always present on every row, and the whole reason this surface
/// is worth opening.
private struct PlayDot: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isPlaying ? Design.Palette.accent : Design.Palette.inkTertiary)
                .frame(width: 9, height: 9)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension CompareSurfaceView {
    /// The short label a column heading uses.
    ///
    /// Feature keys are already namespaced the way a column wants reading — `pocket.snare.ms`,
    /// `swing.percent` — so the heading is the first segment and the unit is the last. "pocket
    /// snare", "swing", "source slice". A feature with no dots is printed whole.
    static func shortName(of feature: Feature, in bible: PersonaBible) -> String {
        let parts = feature.rawValue.split(separator: ".").map(String.init)
        guard parts.count > 1 else { return feature.rawValue }
        // Drop a trailing unit segment — ms, db, hz, percent, bpm — since the cell carries the unit.
        let units: Set<String> = ["ms", "db", "hz", "percent", "bpm", "ratio", "count"]
        let named = units.contains(parts[parts.count - 1].lowercased()) ? parts.dropLast() : parts[...]
        return named.isEmpty ? parts[0] : named.joined(separator: " ")
    }
}
