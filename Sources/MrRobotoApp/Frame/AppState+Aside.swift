import Foundation
import SongGraph

// Taking a part away without deleting it. The graph is append-only and nothing in a song could be
// removed, so a part tried and not wanted played on in every section it had joined, its fader on
// the Mixer and its row in Structure, until someone took it out of each section by hand. Set aside,
// it is out of every section and out of what plays, is drawn and is suggested; it is listed in
// Parts, and brought back into the sections it left.

extension AppState {

    /// Sets a part aside. False, with nothing said, when the song has no such part or it is aside
    /// already.
    @discardableResult
    public func setAside(_ part: PartID, note reason: String? = nil, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, let version = current.latestVersion(of: part), !current.isAside(part) else { return false }
        let playing = current.sections.filter { $0.stitch.contains(part: part) }.count
        updateSong { $0.setAside(part, note: reason) }
        note(source, "Set \(PartLabel.title(of: version)) aside",
             detail: (playing > 0 ? "Out of \(playing == 1 ? "the section" : "the \(playing) sections") it played in, and " : "")
                 + "out of what plays and what the band suggests. It is under Set aside in Parts, to bring back.")
        return true
    }

    /// Brings a part back into the sections it was taken out of. False when it was not aside.
    @discardableResult
    public func bringBack(_ part: PartID, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = song, current.isAside(part), let version = current.latestVersion(of: part) else { return false }
        var back: [SectionID] = []
        updateSong { back = $0.bringBack(part) ?? [] }
        let names = song?.sections.filter { back.contains($0.id) }.map(\.name) ?? []
        note(source, "Brought \(PartLabel.title(of: version)) back",
             detail: names.isEmpty ? "It plays wherever the form puts it; no section it played in is still in the form."
                                   : "It plays in \(names.joined(separator: ", ")) again.")
        return true
    }

    /// The parts set aside in the open song, newest version of each, in the order they were.
    public var asideVersions: [PartVersion] {
        guard let song else { return [] }
        return (song.asides ?? []).compactMap { song.latestVersion(of: $0.part) }
    }
}
