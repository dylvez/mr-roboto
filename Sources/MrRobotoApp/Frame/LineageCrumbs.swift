import SongGraph
import SwiftUI

/// Where the thing on the bench came from, as a row of crumbs: Arrival › Drums stem › Bar 9 ›
/// SP-1200 at 60%.
///
/// This is the song graph's parent edges, read from the bound part back to the record, and it is the
/// clearest single statement of how the idioms connect: a chop is *of* a stem, which is *of* the
/// record; a dusty chop is the chop *through* a machine. Every crumb but the last opens its part in
/// the surface that part belongs in, so the lineage is also a way to walk back up it.
public enum PartLineage {

    public struct Crumb: Identifiable, Sendable, Equatable {
        public let id: VersionID?
        public let title: String
        /// What pressing the crumb opens. Nil for the crumb you are on, and for the song's own name
        /// on a song with no record to show.
        public let action: SurfaceAction?
    }

    /// The deepest a lineage is followed. A real chain is five or six long; this stops a malformed
    /// graph with a cycle from spinning.
    static let maximumDepth = 16

    /// The crumbs for a bound version, oldest first, ending in the version itself. Empty when the
    /// version is not in the song.
    public static func crumbs(for id: VersionID, in song: Song) -> [Crumb] {
        guard var version = song.version(id) else { return [] }
        var chain = [version]
        var seen: Set<VersionID> = [version.id]
        while let parentID = version.parents.first, let parent = song.version(parentID),
              !seen.contains(parentID), chain.count < maximumDepth {
            chain.append(parent)
            seen.insert(parentID)
            version = parent
        }
        chain.reverse()

        var crumbs: [Crumb] = []
        // The record is the song, seen from inside: its crumb carries the song's name and shows the
        // record. A song with no record still starts with its name, so every trail is anchored.
        if let first = chain.first, Guidance.audio(of: first)?.role == .take || first.type == .analysis {
            chain.removeFirst()
            crumbs.append(Crumb(id: first.id, title: song.title,
                                action: PartActions.primary(for: first, in: song)?.action))
        } else {
            crumbs.append(Crumb(id: nil, title: song.title, action: nil))
        }

        for (index, version) in chain.enumerated() {
            let isLast = index == chain.count - 1
            crumbs.append(Crumb(id: version.id, title: title(of: version, after: index > 0 ? chain[index - 1] : nil),
                                action: isLast ? nil : PartActions.primary(for: version, in: song)?.action))
        }
        return crumbs
    }

    /// A crumb's words. A version that only added a machine to its parent is named for the machine,
    /// because that is the only thing that changed; "Bar 9 › Bar 9" would say nothing.
    static func title(of version: PartVersion, after parent: PartVersion?) -> String {
        let passes = version.kind.degradation
        if let parent, parent.partID == version.partID, passes != parent.kind.degradation {
            return Dust.spoken(passes)
        }
        return PartLabel.title(of: version)
    }
}

/// The crumbs, drawn in a surface's header.
struct LineageCrumbs: View {
    let crumbs: [PartLineage.Crumb]
    let app: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("›")
                        .font(Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(Design.Palette.inkTertiary)
                }
                let isLast = index == crumbs.count - 1
                if let action = crumb.action {
                    Button(crumb.title) { app.perform(action) }
                        .buttonStyle(.plain)
                        .font(Design.Typography.ui(12, weight: .regular))
                        .foregroundStyle(Design.Palette.inkSecondary)
                        .lineLimit(1)
                        .help("Open \(crumb.title) in \(action.surface.rawValue)")
                } else {
                    Text(crumb.title)
                        .font(Design.Typography.ui(12, weight: isLast ? .medium : .regular))
                        .foregroundStyle(isLast ? Design.Palette.accent : Design.Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .truncationMode(.head)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Made from: " + crumbs.map(\.title).joined(separator: ", "))
    }
}
