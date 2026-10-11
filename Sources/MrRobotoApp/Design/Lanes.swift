import SongGraph
import SwiftUI

/// Which of the eight hues a drum voice wears in Studio, by what it is rather than by its name: every
/// hand drum is a tom's colour, every shaker a closed hat's, so a kit of thirty voices still reads as
/// eight kinds of sound at a glance — the way XO colours a kick red and a snare blue.
enum LaneClass: Int, CaseIterable, Sendable {
    case kick, snare, closedHat, openHat, clap, perc, toms, cymbal

    init(_ voice: DrumVoice) {
        switch voice {
        case .kick: self = .kick
        case .snare, .rim, .cajonSlap, .darbukaTek: self = .snare
        case .clap: self = .clap
        case .closedHat, .shaker, .cabasa, .guiro, .muteTriangle: self = .closedHat
        case .openHat, .guiroLong: self = .openHat
        case .ride, .crash, .openTriangle: self = .cymbal
        case .lowTom, .midTom, .highTom, .highConga, .lowConga, .highBongo, .lowBongo,
             .cajon, .darbuka, .frameDrum, .slitDrum: self = .toms
        default: self = .perc
        }
    }

    var color: Color { Design.Palette.lane(rawValue) }
}

/// A section's hue in Studio, by its kind, so a verse is the same colour in every song: the
/// Structure surface's blocks and the transport's strip both wear it.
enum SectionHue {
    /// The hue index for a section named `name`. Names the app writes — Intro, Verse, Hook, Bridge,
    /// Outro and their numbered kin — get fixed hues; anything else gets one from its letters, so it
    /// is at least the same every time.
    static func index(for name: String) -> Int {
        let word = name.lowercased()
        // Neighbours in a form get hues apart: an intro's green against a verse's blue, a verse's
        // blue against a hook's gold. The kick's red is left to the drums, where it means kick; on
        // a section it would read as record.
        let kinds: [(keys: [String], hue: Int)] = [
            (["pre-chorus", "prechorus", "pre-hook", "pre chorus", "build"], 4),
            (["intro"], 5),
            (["verse"], 1),
            (["hook", "chorus", "refrain"], 2),
            (["bridge", "middle"], 6),
            (["break", "drop", "solo", "interlude"], 7),
            (["outro", "ending", "coda", "tag"], 3),
        ]
        for kind in kinds where kind.keys.contains(where: word.contains) { return kind.hue }
        return 1 + word.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 7
    }

    static func color(for name: String) -> Color { Design.Palette.lane(index(for: name)) }
}
