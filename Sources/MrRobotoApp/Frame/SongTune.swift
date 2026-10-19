import Foundation
import SongGraph

// Which part is the song's tune.
//
// Every reading names what it measured, so a reading of the wrong part is wrong numbers and wrong
// advice. The band used to choose the tune itself, and two of its members chose differently: the
// Melodist took the melody with the most notes that sound alone, vary_tune the first melody in the
// section's stitch. In Mirror Ball, 1923 both took a guitar written as chords, and the Melodist
// read "a leap of 14 semitones, 16 notes a bar" off it. Now the song says which part is its tune
// (`Song.tune`) — the Piano roll, mark_tune, write_melody and developing mark it — and everyone
// who means the tune asks here.

/// The song's tune: the part marked as it, or with none marked, the band's own choice.
public enum SongTune {

    /// The part marked as the tune, while the band can read it: in the song, a melody, not set
    /// aside. Nil when nothing is marked, or the part marked is out of play.
    public static func marked(in song: Song) -> PartID? {
        guard let part = song.tune, !song.isAside(part), song.latestVersion(of: part)?.type == .melody else { return nil }
        return part
    }

    /// The part the band reads as the song's tune: the one marked, else the newest melody of its
    /// own — not a variation, not a line answering the tune, not set aside — that has notes and is
    /// not chords.
    public static func part(of song: Song) -> PartID? {
        marked(in: song) ?? chosen(in: song)
    }

    /// The tune as the song holds it now: that part's newest version.
    public static func version(in song: Song) -> PartVersion? {
        part(of: song).flatMap { song.latestVersion(of: $0) }
    }

    /// What plays the tune in a section: the lane, the version it plays and the part it is a
    /// variation of (itself, when it is nobody's). The part marked, or a variation of it; with
    /// none marked, the line a listener follows there — of its melodies, the one with the most
    /// notes that sound alone at their onset — never one written as chords, nor a line that
    /// answers the tune. Nil when the section plays none of those.
    public static func lane(in section: Section, of song: Song) -> (lane: Lane, version: PartVersion, root: PartID)? {
        if let tune = marked(in: song) {
            for lane in section.stitch where song.strip(of: lane.part) == tune {
                guard let version = song.version(playing: lane), version.type == .melody else { continue }
                return (lane, version, tune)
            }
            return nil
        }
        let answers = answering(in: song)
        let playing = section.stitch.compactMap { lane -> (lane: Lane, version: PartVersion, alone: Int)? in
            guard !answers.contains(lane.part), let version = song.version(playing: lane),
                  case .melody(let melody) = version.kind, isALine(melody) else { return nil }
            return (lane, version, soundingAlone(melody))
        }
        return playing.max { $0.alone < $1.alone }.map { ($0.lane, $0.version, song.strip(of: $0.lane.part)) }
    }

    /// Whether most of a melody's onsets are more than one note: chords written as a melody to
    /// give them a rhythm. Notes that start within a sixty-fourth note of the one before are one
    /// onset, so a chord rolled by a hand on a controller, or strummed, counts as the chord it is.
    public static func isChords(_ melody: Melody) -> Bool {
        var onsets: [Int] = []
        var last: Double?
        for start in melody.notes.map(\.start).sorted() {
            if let last, start - last <= 1.0 / 16 + 1e-9 { onsets[onsets.count - 1] += 1 } else { onsets.append(1) }
            last = start
        }
        return onsets.filter { $0 > 1 }.count * 2 > onsets.count
    }

    /// A melody the band could take for a tune: notes, and not chords.
    static func isALine(_ melody: Melody) -> Bool { !melody.notes.isEmpty && !isChords(melody) }

    /// How many of a melody's notes sound alone at their onset: what a listener follows, and so
    /// what weighs a section's melodies when none is marked. Chords written as a melody do not
    /// outvote the tune.
    static func soundingAlone(_ melody: Melody) -> Int {
        Dictionary(grouping: melody.notes, by: { ($0.start * 1000).rounded() }).values.filter { $0.count == 1 }.count
    }

    /// The band's own choice with none marked: the melody part of its own most lately written.
    static func chosen(in song: Song) -> PartID? {
        let answers = answering(in: song)
        var seen = Set<PartID>()
        for version in song.versions.reversed() where version.type == .melody && seen.insert(version.partID).inserted {
            guard !song.isVariation(version.partID), !answers.contains(version.partID), !song.isAside(version.partID),
                  case .melody(let melody) = version.kind, isALine(melody) else { continue }
            return version.partID
        }
        return nil
    }

    /// The parts that answer the tune in its rests. Any version says so: one edited by hand since
    /// keeps the part what it was written as.
    static func answering(in song: Song) -> Set<PartID> {
        Set(song.versions.lazy.filter(Develop.isAnswer).map(\.partID))
    }
}
