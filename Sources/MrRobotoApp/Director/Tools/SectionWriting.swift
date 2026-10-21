import Foundation
import SongGraph

// A part written for named sections only, and where a part just written plays.
//
// A section plays each part's newest version, so a tool that writes a part's next version changes
// every section that plays it, and a tool that starts a part puts it only where nothing of its kind
// plays (`AppState.joinForm`) — in an arranged song, nowhere. That left the band able to change a
// song's drums, bass, tune, chords or dust only everywhere at once, and its new parts unheard
// without saying so. With a section named, the tools that write a part write it as that section's
// own, here; without one, they say where what they wrote plays.

/// Writing a part as the named sections' own: in each, what it plays of that kind is replaced by
/// the section's own part — the next version of one placed there that no other section plays, or a
/// variation of the part it played, on the same strip and named for the section, or, where the
/// song has nothing of the kind, a part that plays only there. Every other section keeps what it
/// had. Placed, so developing again leaves it (`Develop.isHeld`). What is written is kept in one
/// `DirectorWorkspace.keep`.
struct SectionWriting {
    typealias Played = (lane: Lane, version: PartVersion, root: PartID)

    private(set) var working: Song
    private(set) var arranged: [Section]
    private(set) var versions: [PartVersion] = []

    init(_ song: Song) {
        working = song
        arranged = song.sections
    }

    func index(of section: Section) -> Int? { arranged.firstIndex { $0.id == section.id } }

    /// What a section plays of `type`: on the strip `strip` when one is named — the part and its
    /// variations — else the first such lane, as `AnotherWay.lane` reads it.
    func played(_ type: PartType, in index: Int, strip: PartID? = nil) -> Played? {
        guard let strip else { return AnotherWay.lane(of: type, in: arranged[index], of: working) }
        for lane in arranged[index].stitch where working.strip(of: lane.part) == strip {
            guard let version = working.version(playing: lane), version.type == type else { continue }
            return (lane, version, strip)
        }
        return nil
    }

    /// Whether a part plays in no section but the one at `index`.
    func onlyIn(_ index: Int, _ part: PartID) -> Bool {
        let id = arranged[index].id
        return !arranged.contains { $0.id != id && $0.stitch.contains { $0.part == part } }
    }

    /// Writes `kind` as the section's own in place of `over`, or beside what it plays when it plays
    /// nothing of the kind; the part it is now. `reusing` false always makes a part of its own, for
    /// a pick that must not reach another section that happens to play the same notes.
    @discardableResult
    mutating func place(_ kind: PartKind, in index: Int, over: Played?, root: PartVersion?, named name: String,
                        note: String, by author: Author, reusing: Bool = true) -> PartID {
        let part: PartID
        if let over, over.lane.part != over.root, onlyIn(index, over.lane.part), Develop.isHeld(over.lane, in: working),
           let mine = working.latestVersion(of: over.lane.part) {
            // The section's own already: its next version.
            part = append(mine.deriving(kind, by: author, operation: Operation.written, note: note))
        } else if let root {
            let made = AnotherWay.variation(of: root, named: name, kind: kind, note: note, by: author, in: working, reusing: reusing)
            if let version = made.version { append(version) }
            part = made.part
        } else {
            // Nothing of the kind in the song: a part that plays only here.
            part = append(PartVersion(partID: PartID(), kind: kind, author: author, operation: Operation.placed, note: note))
        }
        if let over {
            arranged[index].stitch = arranged[index].stitch.map { $0.part == over.lane.part ? Lane(part: part) : $0 }
        } else if !arranged[index].stitch.contains(where: { $0.part == part }) {
            arranged[index].stitch.append(Lane(part: part))
        }
        return part
    }

    /// The newest version of a part as this writing stands.
    func latest(_ part: PartID) -> PartVersion? { working.latestVersion(of: part) }

    @discardableResult
    private mutating func append(_ version: PartVersion) -> PartID {
        versions.append(version)
        try? working.append(version)
        return version.partID
    }

    /// "Intro", "Verse and Hook", "Intro, Verse and Hook"; a name that comes round again once,
    /// "both Hooks", "all 3 Hooks".
    static func list(_ names: [String]) -> String {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        var seen = Set<String>()
        let said = names.filter { seen.insert($0).inserted }.map { name -> String in
            let count = counts[name] ?? 1
            return count == 1 ? name : count == 2 ? "both \(name)s" : "all \(count) \(name)s"
        }
        guard said.count > 1 else { return said.first ?? "" }
        return said.dropLast().joined(separator: ", ") + " and " + said[said.count - 1]
    }
}

/// Where a part just written plays, said in its tool's answer: so a part that every section
/// already had one of — and which so plays nowhere — is never left unheard in silence.
enum FormReach {

    /// The sections a part plays in, by name, in the form's order.
    static func sections(playing part: PartID, in song: Song) -> [String] {
        song.sections.filter { $0.stitch.contains { $0.part == part } }.map(\.name)
    }

    /// " It plays in Intro, Verse and Hook." — or, when nowhere, why, and the two ways to put it
    /// somewhere. Empty for a song with no form, where everything plays as the loop.
    static func sentence(for part: PartID, a what: String, in song: Song) -> String {
        guard !song.sections.isEmpty else { return "" }
        let playing = sections(playing: part, in: song)
        guard playing.isEmpty else { return " It plays in \(SectionWriting.list(playing))." }
        return " It plays in no section yet: every section already plays \(what) of its own, and a new one does not play "
            + "on top of it. Tell the user so, and ask where it goes: name a section to make it that section's own, or "
            + "stitch_section it in."
    }
}
