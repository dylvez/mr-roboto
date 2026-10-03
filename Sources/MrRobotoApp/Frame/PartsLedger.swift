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
            HStack(spacing: 8) {
                SmallLabel("Parts")
                Spacer()
                Text("\(app.versions.count)")
                    .font(Design.Typography.numeric(10.5))
                    .foregroundStyle(Design.Palette.inkTertiary)
                CollapseButton(region: .ledger, app: app)
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
                    } else if let song = app.song {
                        ForEach(LedgerGroups.groups(for: song)) { group in
                            groupHeader(group)
                            ForEach(group.parts) { part in
                                row(part)
                                Hairline()
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
        }
        .background(Design.Palette.panelAlt)
        // A library row dropped on the ledger is adopted and nothing more: it lands as a part.
        .acceptsLibraryDrops(app, at: .ledger)
    }

    /// A stage's name over its parts, in the words the path strip uses, so the ledger and the path
    /// are visibly the same chain.
    private func groupHeader(_ group: LedgerGroups.Group) -> some View {
        HStack(spacing: 6) {
            Glyph(name: group.glyph, symbol: group.symbol, size: 12)
                .foregroundStyle(Design.Palette.inkTertiary)
            SmallLabel(group.title, color: Design.Palette.inkTertiary)
            Spacer()
        }
        .padding(.horizontal, Design.Metric.inset)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// One part: its newest version's name, where that came from, and the verb. A part with more
    /// than one version lists them underneath, so "v1" only appears where there is a v2 to tell it
    /// from.
    private func row(_ part: LedgerGroups.Part) -> some View {
        let version = part.newest
        let isSelected = part.versions.contains { $0.id == app.selectedVersion }
        let isAside = app.song?.isAside(part.id) == true
        let action = isAside ? nil : app.song.flatMap { PartActions.primary(for: version, in: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                // Set aside, the row's one verb is bringing it back.
                if isAside {
                    app.bringBack(part.id)
                // Select either way — an inert kind still accents — but when the kind has a surface,
                // selecting it is what opens it. `perform` selects as part of carrying the action out.
                } else if let action, app.canPerform(action.action) {
                    app.perform(action.action)
                } else {
                    app.select(version.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PartLabel.title(of: version))
                        .font(Design.Typography.ui(14.5, weight: .medium))
                        .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.ink)
                        .lineLimit(1)
                        .padding(.trailing, PartPlayer.canPlay(version) ? 26 : 0)
                    Text(app.provenanceLine(for: version))
                        .font(Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isAside {
                        if let reason = app.song?.aside(part.id)?.note, !reason.isEmpty {
                            Text(reason)
                                .font(Design.Typography.ui(11.5, weight: .regular))
                                .foregroundStyle(Design.Palette.inkTertiary)
                                .lineLimit(2)
                        }
                        ActionTag(title: "Bring back", isSelected: isSelected)
                    } else if let action {
                        ActionTag(title: action.title, isSelected: isSelected)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isAside ? "Back into the sections it played in when it was set aside."
                  : action.map { "\($0.title) — \($0.rationale)" } ?? "Nothing opens on this part; it is here for the history.")
            // Beside the row's own button, not inside it: a button in a button's label gets no clicks.
            .overlay(alignment: .topTrailing) { PartPlayButton(version: version, app: app) }
            .contextMenu {
                if let target = app.stepBackTarget(for: part.id) {
                    // The ledger's undo: the part's music as it was one version ago, as a new
                    // version. ⌘Z does the same on the surface in front, edit by edit.
                    Button("Back to \(LedgerGroups.versionLabel(target, parent: nil)) (v\(app.versionNumber(of: target.id) ?? 0))") {
                        app.stepBack(part.id)
                    }
                    Divider()
                }
                if isAside {
                    Button("Bring Back") { app.bringBack(part.id) }
                } else if StructureModel.plays(version) || version.type == .audio {
                    Button("Set Aside") { app.setAside(part.id) }
                        .help("Out of every section and out of what plays, without deleting it. It waits under Set aside.")
                }
                Divider()
                Button("Keep as idea") { app.keepAsIdea(version.id) }
                    .disabled(app.store == nil)
                if version.type == .sample {
                    Button("Save to Samples") { app.saveToSamples(version.id) }
                        .disabled(app.store == nil)
                }
                if let song = app.song, MergeModel.canMerge(version) {
                    let partners = MergeModel.partners(for: version, in: song)
                    if !partners.isEmpty {
                        Menu("Merge with…") {
                            ForEach(partners) { partner in
                                Button(PartLabel.title(of: partner) + (partner.note.map { " — \($0.prefix(40))" } ?? "")) {
                                    app.perform(SurfaceAction(surface: .merge,
                                                              title: "\(PartLabel.title(of: version)) + \(PartLabel.title(of: partner))",
                                                              bound: [version.id, partner.id]))
                                }
                            }
                        }
                    }
                }
            }

            if part.versions.count > 1, let song = app.song {
                VersionChips(part: part, song: song, app: app)
            }
        }
        .padding(.horizontal, Design.Metric.inset)
        .padding(.vertical, 10)
        .background(isSelected ? Design.Palette.accentSoft : .clear)
    }
}

/// A part's versions, oldest first, each named for what made it different: "v1 clean",
/// "v2 SP-1200 at 60%". Pressing one opens that exact version.
private struct VersionChips: View {
    let part: LedgerGroups.Part
    let song: Song
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(part.versions.enumerated()), id: \.element.id) { index, version in
                let action = LedgerGroups.action(for: version, in: song)
                let isSelected = app.selectedVersion == version.id
                Button {
                    if let action, app.canPerform(action) { app.perform(action) } else { app.select(version.id) }
                } label: {
                    HStack(spacing: 6) {
                        Text("v\(index + 1)")
                            .font(Design.Typography.numeric(10.5, weight: .medium))
                            .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.inkSecondary)
                        Text(LedgerGroups.versionLabel(version, parent: index > 0 ? part.versions[index - 1] : nil))
                            .font(Design.Typography.ui(11.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: Design.Metric.tagHeight)
                    .background(isSelected ? Design.Palette.panel : Design.Palette.panelAlt)
                    .overlay(RoundedRectangle(cornerRadius: Design.Metric.corner)
                        .stroke(isSelected ? Design.Palette.accent : Design.Palette.line, lineWidth: Design.Metric.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: Design.Metric.corner))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(action.map { "Open this version in \($0.surface.rawValue)" } ?? app.provenanceLine(for: version))
                .overlay(alignment: .trailing) { PartPlayButton(version: version, app: app, size: 7).padding(.trailing, 3) }
                .contextMenu {
                    if version.id != part.newest.id {
                        Button("Make v\(index + 1) the current version") { app.restore(version.id) }
                            .help("The song plays this version's music again, as a new version. Nothing is removed.")
                    }
                }
            }
        }
    }
}

// MARK: - Grouping

/// The ledger's rows as parts under stages, rather than a flat list of versions.
///
/// The flat list was accurate and unreadable: every stem, chop and groove is its own part, so every
/// row said "v1", and a chop with a dusty version appeared twice with nothing saying they were one
/// thing. Grouping by stage uses the path's own words, and nesting versions under their part makes
/// the one place a version number means something — a part with more than one — the only place it
/// appears.
public enum LedgerGroups {

    public struct Part: Identifiable, Sendable {
        public let id: PartID
        /// Oldest first, in the order the graph recorded them.
        public let versions: [PartVersion]
        public var newest: PartVersion { versions[versions.count - 1] }
    }

    public struct Group: Identifiable, Sendable {
        public let title: String
        public let glyph: String
        public let symbol: String
        public let parts: [Part]
        public var id: String { title }
    }

    /// Stage order, as the path runs. Kinds with no surface yet come last, under one heading.
    static let order: [(title: String, glyph: String, symbol: String)] = [
        ("Record", PathStep.Kind.record.glyph, PathStep.Kind.record.symbol),
        ("Stems", PathStep.Kind.stems.glyph, PathStep.Kind.stems.symbol),
        ("Chops", PathStep.Kind.chop.glyph, PathStep.Kind.chop.symbol),
        ("Grooves", PathStep.Kind.groove.glyph, PathStep.Kind.groove.symbol),
        ("Kit", PathStep.Kind.kit.glyph, PathStep.Kind.kit.symbol),
        ("Chords", "section", "music.note.list"),
        ("Bass", "stem-bass", "waveform.path"),
        ("Written", "idea", "text.alignleft"),
        ("Takes", "booth", "mic"),
        ("Mix", "mixer", "slider.horizontal.3"),
    ]

    static func stage(of version: PartVersion) -> String {
        switch version.kind {
        case .analysis: return "Record"
        case .audio(let audio):
            if audio.take != nil || audio.comp != nil { return "Takes" }
            return audio.role == .take ? "Record" : "Stems"
        case .sample: return "Chops"
        case .groove: return "Grooves"
        case .sound: return "Kit"
        case .progression: return "Chords"
        case .bassline: return "Bass"
        case .melody, .lyric: return "Written"
        case .mix: return "Mix"
        }
    }

    public static func groups(for song: Song) -> [Group] {
        var partOrder: [PartID] = []
        var byPart: [PartID: [PartVersion]] = [:]
        for version in song.versions {
            if byPart[version.partID] == nil { partOrder.append(version.partID) }
            byPart[version.partID, default: []].append(version)
        }
        let all = partOrder.map { Part(id: $0, versions: byPart[$0]!) }
        // A part set aside is listed under its own heading, last, to be brought back from there.
        let parts = all.filter { !song.isAside($0.id) }
        let aside = (song.asides ?? []).compactMap { entry in all.first { $0.id == entry.part } }
        return order.compactMap { stage in
            let members = parts.filter { self.stage(of: $0.versions[0]) == stage.title }
            return members.isEmpty ? nil : Group(title: stage.title, glyph: stage.glyph, symbol: stage.symbol, parts: members)
        } + (aside.isEmpty ? [] : [Group(title: asideTitle, glyph: "version", symbol: "tray.and.arrow.down", parts: aside)])
    }

    /// The heading parts set aside are listed under.
    static let asideTitle = "Set aside"

    /// What set this version apart from the one before it.
    static func versionLabel(_ version: PartVersion, parent: PartVersion?) -> String {
        let passes = version.kind.degradation
        if let parent, passes != parent.kind.degradation { return Dust.spoken(passes) }
        if parent == nil, version.kind.canCarryDegradation, passes.isEmpty { return "clean" }
        return version.operation
    }

    /// A dusty version opens where its dust is (Sound); anything else opens where its kind does.
    static func action(for version: PartVersion, in song: Song) -> SurfaceAction? {
        if !version.kind.degradation.isEmpty {
            return SurfaceAction(surface: .sound, title: PartLabel.title(of: version), bound: [version.id])
        }
        return PartActions.primary(for: version, in: song)?.action
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
