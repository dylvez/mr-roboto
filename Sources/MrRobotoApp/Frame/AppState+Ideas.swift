import Foundation
import MusicTheory
import SongGraph

// Ideas: parts made with no song around them, to be put into songs later.
//
// An idea is a song package flagged `Song.idea` — a name, a tempo, a key, a meter, one section as
// long as the idea, and whatever parts are made in it. It opens in the frame as a song does, so
// every surface that makes or edits a part works in it unchanged: the Booth and Takes, the Grid,
// Chords, the Piano roll, Lyrics. What differs is around it: no form to arrange, no master, and a
// shelf of its own in the library (`Library.ideaSongs`). See Demos/plans/ideas-first.md.

extension Song {
    /// How many bars a new idea starts at, until it is set or sung longer.
    public static let startingIdeaBars = 4

    /// What an idea's one section is called.
    public static let ideaSectionName = "Idea"

    /// A new idea: one section `bars` long, at a grid of its own. No fills: an idea goes round and
    /// round, and a fill at the end of every pass would be a fill in the idea.
    public static func newIdea(title: String, key: Key? = nil, tempo: Double = Song.startingTempo,
                               timeSignature: TimeSignature = .fourFour, bars: Int = Song.startingIdeaBars) -> Song {
        var idea = Song(title: title, key: key, tempo: tempo, timeSignature: timeSignature,
                        sections: [Section(name: ideaSectionName, stitch: [], lengthInBars: max(1, bars))])
        idea.idea = true
        idea.fills = false
        return idea
    }
}

extension SurfaceKind {
    /// Whether the surface has anything to do in an idea. Structure arranges a form and an idea is
    /// one section; Merge makes a section of two fragments; the Master reads a finished mix.
    public var worksInIdeas: Bool { self != .structure && self != .merge && self != .master }
}

extension AppState {
    /// The lengths an idea can be, in bars.
    public static let ideaBarsRange = 1...256

    /// File ▸ New Idea: an idea of its own, open in the frame, with its settings showing — a name,
    /// a tempo, a key, a meter and how many bars.
    @discardableResult
    public func newIdea(by source: SessionEntry.Source = .you) -> SongID {
        let idea = Song.newIdea(title: MrRobotoApp.untitledIdeaName())
        open(idea, by: source)
        wantsSongSettings = true
        return idea.id
    }

    /// How long the open idea is, in bars; nil when a song is open, or nothing is.
    public var ideaBars: Int? {
        guard let song, song.isIdea else { return nil }
        return song.sections.first?.lengthInBars
    }

    /// Sets how long the open idea is, in bars, clamped to `ideaBarsRange`. Nothing in it moves:
    /// a part shorter than the idea goes round, one longer is heard to the idea's end.
    @discardableResult
    public func setIdeaBars(_ bars: Int, by source: SessionEntry.Source = .you) -> Bool {
        guard let current = ideaBars else { return false }
        let clamped = min(Self.ideaBarsRange.upperBound, max(Self.ideaBarsRange.lowerBound, bars))
        guard clamped != current else { return false }
        updateSong { song in
            if song.sections.isEmpty {
                song.sections = [Section(name: Song.ideaSectionName, stitch: [], lengthInBars: clamped)]
            } else {
                song.sections[0].lengthInBars = clamped
            }
        }
        if let song { library.upsert(song) }
        note(source, "The idea is \(clamped) bar\(clamped == 1 ? "" : "s") long")
        return true
    }
}
