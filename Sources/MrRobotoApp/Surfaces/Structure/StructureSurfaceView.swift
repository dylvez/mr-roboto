import SongGraph
import SwiftUI

/// The form: section blocks in order, the selected one opened up underneath.
struct StructureSurfaceView: View {
    @Bindable var model: StructureModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Metric.gutter) {
            header
            // The blocks and the open section scroll; the title and the keep line stay put. A long
            // form with its section open — the parts, the words — is taller than a bench.
            ScrollsInside {
                VStack(alignment: .leading, spacing: Design.Metric.gutter) {
                    blocks
                    if let section = model.selectedSection {
                        SectionDetail(model: model, section: section)
                    } else {
                        emptyHint
                    }
                }
            }
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
                // The tail: where a block dropped past the last one lands. Outlined, so there is
                // something to aim at. It used to be a clear box of the same size, which is a
                // target only to someone who already knew it was there.
                RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .strokeBorder(Design.Palette.lineStrong,
                                  style: StrokeStyle(lineWidth: Design.Metric.hairline, dash: [3, 3]))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { ids, _ in
                        drop(ids, before: nil)
                    }
                    .help("Drop a section here to put it last.")
                    .accessibilityLabel("End of the form: drop a section here to put it last")
            }
            HStack(spacing: 4) {
                ForEach(StructureModel.Preset.allCases, id: \.self) { preset in
                    FormChip("+ \(preset.rawValue)", isOn: false) { model.add(preset) }
                        .help("Add a \(preset.bars)-bar \(preset.rawValue.lowercased()) after the selected section, playing the newest of everything")
                }
                // The genre's own arrangement, whole, when the song has a genre that states one.
                if let offered = model.genreForm {
                    FormChip("+ \(offered.genre) form", isOn: false) { model.addGenreForm() }
                        .help("Add \(offered.form.sections.map { "\($0.name) \($0.bars)" }.joined(separator: " · ")) — \(offered.form.bars) bars, the way \(offered.genre) is usually arranged")
                }
            }
            // What the whole form leaves out, above the section detail rather than inside it: a
            // part written after the form was arranged is in no section, and saying that once
            // about the song reads as the fact it is, where saying it in each section's panel
            // reads as a problem with whichever one you happened to select.
            if let orphaned = model.orphanedText {
                HStack(spacing: 8) {
                    Text("No section plays the \(orphaned) this song has.")
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.warn)
                    FormChip("Add to every section", isOn: false) { model.fillAll() }
                }
                .padding(.top, 2)
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
             ? "No sections yet. Add one: it plays the newest groove, bass line, chords, tune and chop, and follows them as you work. The transport plays the sections in order."
             : "Select a section to name it, set its bars and choose what plays in it.")
            .font(Design.Typography.ui(12, weight: .regular))
            .foregroundStyle(Design.Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            model.statusBar
            Spacer()
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

    /// The section whose Remove has been clicked once. Remove asks: the first click turns the
    /// chip into "Remove Verse?" in the warn colour and the second removes; any other click on
    /// the panel, or selecting another section, puts it back. Keep and Revert are still there,
    /// so one question is enough and a sheet would be too much.
    @State private var armedRemove: SectionID?

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

    private var isArmed: Bool { armedRemove == section.id }
    private func disarm() { armedRemove = nil }

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
                        FormChip("−", isOn: false) { disarm(); model.setLength(section.id, bars: section.lengthInBars - 1) }
                            .help("One bar shorter")
                            .accessibilityLabel("One bar shorter")
                        ForEach(Self.lengths, id: \.self) { bars in
                            FormChip("\(bars)", isOn: section.lengthInBars == bars) { disarm(); model.setLength(section.id, bars: bars) }
                                .help("\(bars) bar\(bars == 1 ? "" : "s")")
                        }
                        FormChip("+", isOn: false) { disarm(); model.setLength(section.id, bars: section.lengthInBars + 1) }
                            .help("One bar longer")
                            .accessibilityLabel("One bar longer")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FormLabel("Order")
                    HStack(spacing: 4) {
                        FormChip("◀", isOn: false) { disarm(); model.moveEarlier(section.id) }
                            .help("Move \(section.name) one place earlier in the form")
                            .accessibilityLabel("Move \(section.name) earlier")
                        FormChip("▶", isOn: false) { disarm(); model.moveLater(section.id) }
                            .help("Move \(section.name) one place later in the form")
                            .accessibilityLabel("Move \(section.name) later")
                        FormChip("Duplicate", isOn: false) { disarm(); model.duplicate(section.id) }
                            .help("A copy of \(section.name) right after it, playing the same parts")
                        removeChip
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
                    // says nothing about which part it is. A section can play two of a kind — a
                    // groove layered on a groove — so each chip toggles on its own; a new part
                    // joins only the sections that have none of its kind.
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
                                        disarm()
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
                        FormChip("Add \(missing)", isOn: false) { disarm(); model.fill(section.id) }
                    }
                }
                if let silence = model.silence(of: section) {
                    Text(silence)
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.warn)
                }
            }
            if let words = model.words(for: section.id) {
                wordsRow(words)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.panelAlt)
        .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner).stroke(Design.Palette.line, lineWidth: Design.Metric.hairline))
        .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
        .onChange(of: section.id) { disarm() }
    }

    /// What the section sings: its stanza's first lines, the way the Booth will show them, or how
    /// to give it one. The words and the form meet here and in the Booth, and nowhere else.
    private func wordsRow(_ words: StructureModel.Words) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel("Sings")
            switch words {
            case .sings(let label, let lines):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label.uppercased())
                        .font(Design.Typography.label)
                        .tracking(1.1)
                        .foregroundStyle(Design.Palette.accent)
                    Text(lines.prefix(2).joined(separator: " / ") + (lines.count > 2 ? " …" : ""))
                        .font(Design.Typography.prose(12.5))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(lines.joined(separator: "\n"))
                }
            case .unlabelled(let name):
                HStack(spacing: 8) {
                    Text("No stanza is labelled \(name), so the Booth shows the whole lyric here.")
                        .font(Design.Typography.ui(11.5, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                    FormChip("Label one", isOn: false) { disarm(); model.openLyrics() }
                        .help("Open the Lyrics surface and put [\(name)] above the stanza this section sings")
                }
            }
        }
    }

    private var removeChip: some View {
        FormChip(isArmed ? "Remove \(section.name)?" : "Remove", isOn: false, warns: isArmed) {
            if isArmed {
                disarm()
                model.remove(section.id)
            } else {
                armedRemove = section.id
            }
        }
        .help(isArmed ? "Click again to take \(section.name) out of the form. Revert brings it back until you keep."
                      : "Take \(section.name) out of the form. Asks once; the parts it plays stay in the song.")
        .accessibilityLabel(isArmed ? "Confirm removing \(section.name)" : "Remove \(section.name)")
    }
}

/// Chips that wrap onto the next line rather than running off the panel.
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    /// Between lines, when it should differ from between items. Nil is the same.
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let lineGap = lineSpacing ?? spacing
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + lineGap; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lineGap = lineSpacing ?? spacing
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + lineGap; rowHeight = 0 }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct FormChip: View {
    let title: String
    let isOn: Bool
    /// A chip that is a warning rather than a choice — the armed Remove. Warn ink on the warn
    /// ground, so it cannot be read as one more option in the row.
    let warns: Bool
    let action: () -> Void
    init(_ title: String, isOn: Bool, warns: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.isOn = isOn; self.warns = warns; self.action = action
    }

    private var ink: Color { warns ? Design.Palette.warn : isOn ? Design.Palette.accent : Design.Palette.inkSecondary }
    private var ground: Color { warns ? Design.Palette.warnSoft : isOn ? Design.Palette.accentSoft : Design.Palette.panel }
    private var edge: Color { warns ? Design.Palette.warn.opacity(0.5) : isOn ? Design.Palette.accent.opacity(0.35) : Design.Palette.line }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.ui(11.5, weight: isOn || warns ? .semibold : .regular))
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Design.Metric.chipHeight)
                .background(ground, in: RoundedRectangle(cornerRadius: Design.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                    .stroke(edge, lineWidth: Design.Metric.hairline))
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
