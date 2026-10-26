import AudioEngine
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

extension Song {
    /// How many bars a part fills in this song's clock, from the first bar: a written part's own
    /// length, a groove's bars, a recording's last second where it is placed. Nil for what has no
    /// length of its own — words, a chop, a mix, a sound.
    public func bars(holding version: PartVersion) -> Int? {
        let beatsPerBar = timeSignature.beatsPerBar
        switch version.kind {
        case .progression(let progression): return progression.bars.isEmpty ? nil : progression.bars.count
        case .melody(let melody): return melody.notes.isEmpty ? nil : melody.loopBars(beatsPerBar: beatsPerBar)
        case .bassline(let line): return line.notes.isEmpty ? nil : line.loopBars(beatsPerBar: beatsPerBar)
        case .groove(let groove): return groove.bars
        case .audio(let audio):
            guard tempo > 0, audio.duration > 0 else { return nil }
            // Where it plays now: a take or a comp from the section it was sung to, at the tempo
            // it was sung at; anything else as the record plays, at its reading's tempo.
            let end: Double
            if audio.take != nil || audio.comp != nil {
                let clock = TransportClock(tempo: tempo, timeSignature: timeSignature)
                end = TakePlacement.alignment(of: audio, in: self, clock: clock) + TakePlacement.duration(of: audio, in: self)
            } else {
                let stretch = SongPlayback.recordStretch(of: version, in: self)
                end = ((audio.alignmentOffset ?? 0) + audio.duration) * stretch
            }
            let barSeconds = Double(beatsPerBar) * 60 / tempo
            // A take stopped a hair into the next bar has not sung it.
            return max(1, Int((end / barSeconds - 0.02).rounded(.up)))
        case .sample, .lyric, .sound, .analysis, .mix:
            return nil
        }
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
        guard let clamped = changedIdeaBars(bars) else { return false }
        resizeIdea(to: clamped)
        note(source, "The idea is \(Guidance.count(clamped, "bar")) long")
        return true
    }

    /// Makes the open idea long enough to hold what was just put in it — a take sung past its end,
    /// a line written longer — and never shorter. True when it grew.
    @discardableResult
    func growIdea(toHold version: PartVersion) -> Bool {
        guard let song, song.isIdea, let needed = song.bars(holding: version), let current = ideaBars,
              needed > current, let grown = changedIdeaBars(needed) else { return false }
        resizeIdea(to: grown)
        note(.session, "The idea grew to \(Guidance.count(grown, "bar"))", detail: "To hold \(PartLabel.title(of: version)), \(Guidance.count(needed, "bar")) long.")
        return true
    }

    /// The length `bars` comes to inside `ideaBarsRange`, when an idea is open and it differs.
    private func changedIdeaBars(_ bars: Int) -> Int? {
        guard let current = ideaBars else { return nil }
        let clamped = min(Self.ideaBarsRange.upperBound, max(Self.ideaBarsRange.lowerBound, bars))
        return clamped == current ? nil : clamped
    }

    private func resizeIdea(to bars: Int) {
        updateSong { song in
            if song.sections.isEmpty {
                song.sections = [Section(name: Song.ideaSectionName, stitch: [], lengthInBars: bars)]
            } else {
                song.sections[0].lengthInBars = bars
            }
        }
        if let song { library.upsert(song) }
    }

    // MARK: A take in an idea runs on

    /// How many bars a take in an idea can run before the transport stops: room to sing a line
    /// several times the idea's length, at the cost of a song's worth of dusty bouncing at most.
    static func ideaRunwayBars(for bars: Int) -> Int {
        min(ideaBarsRange.upperBound, max(64, bars * 2))
    }

    /// What a counted-in run plays in an idea: the idea as one section `ideaRunwayBars` long, its
    /// parts going round under you and the click with them, so a line longer than the idea is sung
    /// to its end rather than cut off at the idea's last bar. The take that lands grows the idea
    /// (`growIdea(toHold:)`). Nil when no idea is open.
    func ideaTakePlan() -> SongPlayback? {
        guard var long = song, long.isIdea, let bars = long.sections.first?.lengthInBars else { return nil }
        long.sections[0].lengthInBars = Self.ideaRunwayBars(for: bars)
        return SongPlayback.plan(for: long) { [store, song] ref in
            guard let store else { return nil }
            return try? store.mediaURL(for: ref, song: song?.id)
        }
    }
}
