import SongGraph
import SwiftUI

// Each surface's title is a menu of the song's parts that surface works on: every groove in the
// Grid, every bass line and tune in the Piano roll, every progression in Chords. Choosing one turns
// the surface to it in place. Before, the only way to another groove was the Parts column, which
// starts folded, and it opened a second Grid beside the first.

/// One part a surface could be turned to.
public struct PartChoice: Identifiable, Sendable, Hashable {
    public var id: PartID { part }
    public var part: PartID
    /// Its newest version: what the surface opens on, and what is selected.
    public var version: VersionID
    public var title: String
    /// The kind of part, for grouping: "Bass lines", "Melodies".
    public var group: String
    /// The surface the part opens in, and the versions it binds, as its ledger row would.
    public var surface: SurfaceKind
    public var bound: [VersionID]
}

/// A part a surface can start from nothing: its menu's "New …" entries.
public struct FreshPart: Identifiable, Sendable, Hashable {
    public var type: PartType
    public var title: String
    public var id: PartType { type }
}

extension SurfaceKind {
    /// Whether a surface of this kind can be turned to a part that opens in `other`. The Master
    /// is bound as the Mixer is, to a mix.
    func showsParts(of other: SurfaceKind) -> Bool {
        other == self || (self == .master && other == .mixer)
    }

    /// The parts this surface can start from nothing. The others' come from somewhere else: a chop
    /// is cut from a stem, a take is sung in the Booth, a mix is the song's.
    public var freshParts: [FreshPart] {
        switch self {
        case .grid: return [FreshPart(type: .groove, title: "New groove")]
        case .pianoRoll: return [FreshPart(type: .bassline, title: "New bass line"),
                                 FreshPart(type: .melody, title: "New melody")]
        case .chords: return [FreshPart(type: .progression, title: "New progression")]
        case .lyrics: return [FreshPart(type: .lyric, title: "New lyric")]
        default: return []
        }
    }
}

extension AppState {

    /// The parts of the open song this surface works on, in the order the song made them.
    ///
    /// Relevance is the ledger's: a part belongs to the surface its row opens, so the menu and the
    /// Parts column never disagree about where something lives. Parts needing work before they
    /// open — a stem not chopped yet — are left to the ledger, and two parts that open the same
    /// thing (a chop, and the stem it was cut from) are one choice.
    public func partChoices(for kind: SurfaceKind) -> [PartChoice] {
        guard let song else { return [] }
        var seen: Set<PartID> = []
        var opened: [[VersionID]: Int] = [:]
        var choices: [PartChoice] = []
        for version in song.versions where !seen.contains(version.partID) {
            seen.insert(version.partID)
            guard let newest = song.versions.last(where: { $0.partID == version.partID }),
                  let action = LedgerGroups.action(for: newest, in: song),
                  kind.showsParts(of: action.surface), action.prepare == .none, !action.bound.isEmpty else { continue }
            let choice = PartChoice(part: newest.partID, version: newest.id, title: action.title,
                                    group: Self.group(of: newest), surface: action.surface, bound: action.bound)
            if let at = opened[action.bound] {
                // The same thing opened twice: named for the part that *is* it — the chop, not the
                // stem it was cut from.
                if action.bound.contains(newest.id) { choices[at] = choice }
                continue
            }
            opened[action.bound] = choices.count
            choices.append(choice)
        }
        return choices
    }

    /// Which of `choices` the surface is on: the part it is working on, else the one its binding
    /// holds.
    func currentChoice(among choices: [PartChoice], for item: BenchItem, working: PartID?) -> PartChoice? {
        if let working, let found = choices.first(where: { $0.part == working }) { return found }
        let bound = Set(self.bound(for: item.id))
        return choices.first { !bound.isDisjoint(with: $0.bound) }
    }

    private static func group(of version: PartVersion) -> String {
        switch version.kind {
        case .groove: return "Grooves"
        case .bassline: return "Bass lines"
        case .melody: return "Melodies"
        case .progression: return "Progressions"
        case .sample: return "Chops"
        case .sound: return "Sounds"
        case .lyric: return "Lyrics"
        case .mix: return "Mixes"
        case .analysis: return "The record"
        case .audio(let audio):
            if audio.take != nil || audio.comp != nil { return "Takes" }
            return audio.role == .stem ? "Stems" : "The record"
        }
    }
}

/// The surface's title, and the menu of the parts it could show instead. A plain title when the
/// song has nothing else for it.
struct PartSwitcher: View {
    let item: BenchItem
    let app: AppState
    let title: String
    let working: PartID?

    var body: some View {
        let choices = app.partChoices(for: item.kind)
        let current = app.currentChoice(among: choices, for: item, working: working)
        let fresh = item.kind.freshParts
        if fresh.isEmpty && (choices.isEmpty || (choices.count == 1 && current != nil)) {
            label(showsMenu: false)
        } else {
            Menu {
                let groups = choices.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
                ForEach(groups, id: \.self) { group in
                    let members = choices.filter { $0.group == group }
                    if groups.count > 1 {
                        Section(group) { items(members, current: current) }
                    } else {
                        items(members, current: current)
                    }
                }
                if !fresh.isEmpty {
                    if !choices.isEmpty { Divider() }
                    ForEach(fresh) { part in
                        Button(part.title) { app.startNewPart(part, on: item.id) }
                    }
                }
            } label: {
                label(showsMenu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help(choices.isEmpty
                  ? "Start a new part here"
                  : "Switch \(item.kind.rawValue) to another of the song's \(noun(choices)), or start a new one")
            .accessibilityLabel("\(title). Switch to another part")
        }
    }

    @ViewBuilder
    private func items(_ members: [PartChoice], current: PartChoice?) -> some View {
        ForEach(members) { choice in
            Toggle(choice.title, isOn: Binding(get: { choice.part == current?.part },
                                               set: { on in if on { app.switchSurface(item.id, to: choice) } }))
        }
    }

    private func label(showsMenu: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Design.Typography.ui(16, weight: .medium))
                .foregroundStyle(Design.Palette.ink)
                .lineLimit(1)
            if showsMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Palette.inkSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// "grooves", "bass lines and melodies": what the menu holds, for its tooltip.
    private func noun(_ choices: [PartChoice]) -> String {
        let groups = choices.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        return groups.map { $0.lowercased() }.joined(separator: " and ")
    }
}
