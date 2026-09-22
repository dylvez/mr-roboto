import SongGraph
import SwiftUI

/// The form: section blocks in order, the selected one opened up underneath.
struct StructureSurfaceView: View {
    @Bindable var model: StructureModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            blocks
            if let section = model.selectedSection {
                SectionDetail(model: model, section: section)
            } else {
                emptyHint
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Design.Metric.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.title).font(Design.Typography.prose(16, weight: .medium))
            Text(model.lengthText)
                .font(Design.Typography.numeric(12))
                .foregroundStyle(Design.Palette.inkSecondary)
            // The form plays from the surface's header, where every surface's play control is.
            Spacer()
        }
    }

    /// The strip. Each block is as wide as its bars and a long form wraps onto the next line; drag
    /// one block onto another to put it before it, or onto the tail to put it last.
    private var blocks: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel("Sections")
            FlowRow(spacing: 6) {
                ForEach(model.sections) { section in
                    SectionBlock(model: model, section: section)
                }
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 40, height: 44)
                    .dropDestination(for: String.self) { ids, _ in
                        drop(ids, before: nil)
                    }
            }
            HStack(spacing: 4) {
                ForEach(StructureModel.Preset.allCases, id: \.self) { preset in
                    FormChip("+ \(preset.rawValue)", isOn: false) { model.add(preset) }
                }
            }
        }
    }

    private func drop(_ ids: [String], before target: SectionID?) -> Bool {
        guard let raw = ids.first, let uuid = UUID(uuidString: raw) else { return false }
        model.move(SectionID(rawValue: uuid), before: target)
        return true
    }

    private var emptyHint: some View {
        Text(model.isEmpty
             ? "No sections yet. Add one: it plays the newest groove, bass line, chords, tune and dusty chop, and follows them as you work. The transport plays the sections in order."
             : "Select a section to name it, set its bars and choose what plays in it.")
            .font(Design.Typography.ui(12, weight: .regular))
            .foregroundStyle(Design.Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.lastError {
                Text(error).font(Design.Typography.ui(11.5)).foregroundStyle(Design.Palette.warn)
            } else if model.isDirty {
                Text("Not kept yet: the transport plays what was last kept.")
                    .font(Design.Typography.ui(11.5, weight: .regular))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12))
                .foregroundStyle(Design.Palette.inkSecondary)
                .disabled(!model.isDirty)
            Button("Keep arrangement") { Task { await model.keep() } }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
                .disabled(!model.isDirty)
        }
    }
}

// MARK: - A block in the strip

private struct SectionBlock: View {
    let model: StructureModel
    let section: SongGraph.Section

    private var isSelected: Bool { model.selected == section.id }
    private var width: CGFloat { min(240, max(96, CGFloat(section.lengthInBars) * 8)) }
    private var kinds: [String] { model.kinds(of: section) }

    var body: some View {
        Button { model.select(section.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.name.uppercased())
                    .font(Design.Typography.label)
                    .tracking(1.1)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.ink)
                Text("\(section.lengthInBars) bars")
                    .font(Design.Typography.numeric(10))
                    .foregroundStyle(Design.Palette.inkTertiary)
                // What it plays, in words. Anonymous dots said how many parts were stitched in and
                // never which, which is the one thing you want to know while reading a form.
                Text(kinds.isEmpty ? "silent" : kinds.joined(separator: " · "))
                    .font(Design.Typography.ui(9.5, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(kinds.isEmpty ? Design.Palette.inkTertiary : Design.Palette.inkSecondary)
                    .frame(height: 11, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(isSelected ? Design.Palette.accentSoft : Design.Palette.panelAlt,
                        in: RoundedRectangle(cornerRadius: Design.Metric.corner))
            .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                .stroke(isSelected ? Design.Palette.accent.opacity(0.5) : Design.Palette.line,
                        lineWidth: Design.Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(section.id.rawValue.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first, let uuid = UUID(uuidString: raw) else { return false }
            model.move(SectionID(rawValue: uuid), before: section.id)
            return true
        }
        .modifier(SectionDropTarget(model: model, section: section.id))
        .help(model.silence(of: section)
              ?? "\(section.name) · \(section.lengthInBars) bars · plays \(kinds.joined(separator: ", "))")
    }
}

/// A library row dropped on a block is adopted and stitched into that section. Off in offscreen
/// renders, like every drop target: `dropDestination` is AppKit-backed and renders as a block.
private struct SectionDropTarget: ViewModifier {
    let model: StructureModel
    let section: SectionID

    func body(content: Content) -> some View {
        if Design.isOffscreenRender {
            content
        } else {
            content.dropDestination(for: LibraryDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                Task { await model.receive(payload, into: section) }
                return true
            }
        }
    }
}

// MARK: - The selected section

private struct SectionDetail: View {
    let model: StructureModel
    let section: SongGraph.Section

    private static let lengths = [1, 2, 4, 8, 16, 32]

    /// A chip's words. The version titles this app writes are sentences — "Brushes under the C
    /// loop: kick on 1, brushed accent on 3, ghost snare sweeping between…" — and a chip is
    /// `fixedSize`, so an untrimmed one takes the whole row and the rest wrap off the end. The
    /// full title is on the chip's tooltip.
    private static func chipTitle(_ layer: StructureModel.Layer) -> String {
        var title = layer.title
        if title.count > 30 { title = title.prefix(29).trimmingCharacters(in: .whitespaces) + "…" }
        guard let reason = layer.silentReason else { return title }
        return "\(title) (\(reason))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel("Name")
                    TextField("Verse", text: Binding(
                        get: { section.name },
                        set: { model.rename(section.id, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(Design.Typography.ui(13))
                        .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel("Bars")
                    HStack(spacing: 4) {
                        FormChip("−", isOn: false) { model.setLength(section.id, bars: section.lengthInBars - 1) }
                        ForEach(Self.lengths, id: \.self) { bars in
                            FormChip("\(bars)", isOn: section.lengthInBars == bars) { model.setLength(section.id, bars: bars) }
                        }
                        FormChip("+", isOn: false) { model.setLength(section.id, bars: section.lengthInBars + 1) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel("Order")
                    HStack(spacing: 4) {
                        FormChip("◀", isOn: false) { model.moveEarlier(section.id) }
                        FormChip("▶", isOn: false) { model.moveLater(section.id) }
                        FormChip("Duplicate", isOn: false) { model.duplicate(section.id) }
                        FormChip("Remove", isOn: false) { model.remove(section.id) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FormLabel("Plays")
                if model.layers.isEmpty {
                    Text("Nothing in the song plays on the transport yet: paint a groove, write a bass line, set the chords or dust a chop.")
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                } else {
                    // One row per kind, because a version title is a sentence about the part and
                    // says nothing about which part it is. A row is a choice, not a set: the
                    // transport plays one of each kind, and `toggle` enforces it.
                    ForEach(model.choices(for: section), id: \.type) { choice in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(StructureModel.name(of: choice.type))
                                .font(Design.Typography.ui(11, weight: .medium))
                                .foregroundStyle(Design.Palette.inkSecondary)
                                .frame(width: 48, alignment: .leading)
                            FlowRow(spacing: 4) {
                                ForEach(choice.layers) { layer in
                                    FormChip(Self.chipTitle(layer),
                                             isOn: section.stitch.contains(part: layer.id)) {
                                        model.toggle(layer.id, in: section.id)
                                    }
                                    .help(layer.plays ? layer.title
                                                      : "\(layer.title) — \(layer.silentReason ?? "silent"), so it makes no sound on the transport")
                                }
                            }
                        }
                    }
                }
                if let missing = model.missingText(from: section) {
                    HStack(spacing: 8) {
                        Text("This section does not play the \(missing) the song has.")
                            .font(Design.Typography.ui(11.5, weight: .regular))
                            .foregroundStyle(Design.Palette.inkSecondary)
                        FormChip("Add \(missing)", isOn: false) { model.fill(section.id) }
                    }
                }
                if let silence = model.silence(of: section) {
                    Text(silence)
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.warn)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
    }
}

/// Chips that wrap onto the next line rather than running off the panel.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct FormChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    init(_ title: String, isOn: Bool, action: @escaping () -> Void) { self.title = title; self.isOn = isOn; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Design.Palette.accent : Design.Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(isOn ? Design.Palette.accentSoft : Design.Palette.panel,
                            in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line, lineWidth: Design.Metric.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct FormLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Design.Typography.label)
            .tracking(1.1)
            .foregroundStyle(Design.Palette.inkTertiary)
    }
}
