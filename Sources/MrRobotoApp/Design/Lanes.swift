import MusicTheory
import SongGraph
import SwiftUI

/// Which of the eight hues a drum voice wears, by what it is rather than by its name: every
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

/// A section's hue, by its kind, so a verse is the same colour in every song: the Structure
/// surface's blocks and the transport's strip both wear it, and in Vibrant the transport's display
/// glows in it while the section plays.
enum SectionHue {
    /// The hue index for a section named `name`. Names the app writes — Intro, Verse, Hook, Bridge,
    /// Outro and their numbered kin — get fixed hues; anything else gets one from its letters, so it
    /// is at least the same every time.
    static func index(for name: String) -> Int { SharedPalette.sectionLane(for: name) }

    static func color(for name: String) -> Color { Design.Palette.lane(index(for: name)) }
}

/// A part's hue, by its kind, the way a desk colours its tracks: the drums gold, the bass
/// violet, the chords teal, the tune blue, a chop magenta, a take green, the words periwinkle. The
/// same eight hues as the lanes and the sections, read in a different place: a strip, a row of the
/// parts, a line of what a section plays. Nil for what is not a track — a sound, a mix, a reading.
enum PartHue {
    static func index(for type: PartType) -> Int? {
        switch type {
        case .groove: return SharedPalette.PartLane.groove
        case .bassline: return SharedPalette.PartLane.bassline
        case .progression: return SharedPalette.PartLane.progression
        case .melody: return SharedPalette.PartLane.melody
        case .sample: return SharedPalette.PartLane.sample
        case .audio: return SharedPalette.PartLane.audio
        case .lyric: return SharedPalette.PartLane.lyric
        case .sound, .analysis, .mix: return nil
        }
    }

    static func color(for type: PartType?) -> Color? {
        type.flatMap(index(for:)).map(Design.Palette.lane)
    }
}

/// A chord's hue, by the step of the key its root stands on, so a progression reads as colours the
/// way Hooktheory's lead sheets do: home red, then round the wheel — two gold, three green, four
/// teal, five sky, six violet, seven magenta. The Chords surface's bars and the Piano roll's chord
/// band both wear it, so a iv is the same teal on both. Vibrant draws with it; the other palettes
/// leave the chords in ink.
enum HarmonyHue {
    /// The lane for a scale degree, 1…7.
    static func index(degree: Int) -> Int {
        let lanes = [0, 2, 5, 3, 1, 4, 6]
        return lanes[((degree - 1) % 7 + 7) % 7]
    }

    /// The step of the key a chord's root stands on, and whether every note of it is the key's own:
    /// a borrowed chord keeps its step's hue and is drawn as borrowed. The Harmonist's rule, so the
    /// bars and its reading agree: the major chord on a minor key's fifth is the key's own.
    static func reading(of chord: Chord, in key: Key) -> (degree: Int, inKey: Bool)? {
        guard let numeral = key.romanNumeral(for: chord) else { return nil }
        let own = Set(key.pitchClasses)
        let isMinor = key.scale.diatonicChord(degree: 1, root: key.tonic.pitchClass)?.quality.hasMinorThird ?? false
        let isTheFive = isMinor && key.tonic.pitchClass.distance(to: chord.root) == 7
            && (chord.quality.third == 4 || chord.quality.isSuspended)
        return (numeral.degree, isTheFive || chord.pitchClasses.allSatisfy(own.contains))
    }

    /// The chord's colour in Vibrant; nil in the other palettes, and for a root the key cannot spell.
    static func color(for chord: Chord, in key: Key) -> Color? {
        guard Design.scheme.isVivid, let reading = reading(of: chord, in: key) else { return nil }
        return Design.Palette.lane(index(degree: reading.degree))
    }
}

/// A band member's hue: the colour of what it owns, so the Beatmaker speaks in the groove's gold and
/// the Harmonist in the chords' teal wherever either appears. The three who own no part take what
/// is left — the Producer red, the Engineer the take's green, the Peer the words' periwinkle — and the
/// Director keeps Vibrant's own blue. Vibrant only: the other palettes leave the names in ink.
enum MemberHue {
    static func index(forPersona name: String) -> Int? {
        let key = name.lowercased()
        if key.contains("beat") { return SharedPalette.PartLane.groove }
        if key.contains("sampl") { return SharedPalette.PartLane.sample }
        if key.contains("bass") { return SharedPalette.PartLane.bassline }
        if key.contains("harmon") { return SharedPalette.PartLane.progression }
        if key.contains("melod") { return SharedPalette.PartLane.melody }
        if key.contains("lyric") { return SharedPalette.PartLane.lyric }
        if key.contains("engineer") { return SharedPalette.PartLane.audio }
        if key.contains("produc") { return 0 }
        if key.contains("peer") { return SharedPalette.PartLane.lyric }
        return nil
    }

    /// The member's colour in Vibrant; nil in the other palettes and for a name it does not know.
    static func color(forPersona name: String) -> Color? {
        guard Design.scheme.isVivid, let index = index(forPersona: name) else { return nil }
        return Design.Palette.lane(index)
    }

    /// The colour of a line's speaker in the rail: a member's own, the Director's blue; none for you
    /// or for the app.
    static func color(for source: SessionEntry.Source) -> Color? {
        switch source {
        case .persona(let name): return color(forPersona: name)
        case .director: return color(for: Proposal.Source.director)
        case .you, .session: return nil
        }
    }

    /// The colour of whoever is speaking: a member's own, the Director's blue, nothing for the app.
    static func color(for source: Proposal.Source) -> Color? {
        guard Design.scheme.isVivid else { return nil }
        switch source {
        case .persona(let name): return color(forPersona: name)
        case .director: return Design.ColorPair.fixed(SharedPalette.Vibrant.accent).color
        case .session: return nil
        }
    }
}

/// A member's portrait, ringed in its hue in Vibrant so the face and the colour are learned together.
struct MemberEmblem: View {
    let name: String
    var hue: Color?
    var width: CGFloat

    var body: some View {
        ArtImage(name, width: width)
            .overlay {
                if let hue {
                    Circle()
                        .strokeBorder(hue, lineWidth: 1.5)
                        .padding(-2.5)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// A part's colour as a stripe down the leading edge of its row. In Vibrant the stripe is wider and
/// the colour washes out from it across the row, so a list of parts reads as their colours first.
struct PartStripe: ViewModifier {
    let type: PartType?
    var inset: CGFloat = 0

    func body(content: Content) -> some View {
        if let hue = PartHue.color(for: type) {
            let vivid = Design.scheme.isVivid
            content
                .background {
                    if vivid {
                        LinearGradient(colors: [hue.opacity(0.2), hue.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(hue)
                        .frame(width: vivid ? 4 : 3)
                        .padding(.vertical, vivid ? 0 : inset)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

extension PartHue {
    /// The hue of what a surface is working on, for `Design.follow(hue:)`: the part it edits among
    /// those it is bound to — the bass line, not the groove a Piano roll draws under it — or the
    /// kind of part it makes when it is bound to none yet. Nil for a surface about the song, the mix
    /// or the library as a whole.
    static func work(of kind: SurfaceKind, bound: [PartType]) -> Int? {
        let edits: [PartType]?
        switch kind {
        case .grid: edits = [.groove]
        case .pianoRoll: edits = [.bassline, .melody]
        case .chords: edits = [.progression]
        case .chopLane: edits = [.sample]
        case .importRecord, .takes, .booth: edits = [.audio]
        case .lyrics: edits = [.lyric]
        // About one part, whichever kind: its sound, its candidates, its finding.
        case .sound, .compare, .check: edits = nil
        default: return nil
        }
        let chosen = bound.first { type in index(for: type) != nil && (edits?.contains(type) ?? true) }
        return (chosen ?? edits?.first).flatMap(index(for:))
    }
}

extension AppState {
    /// The hue of what fills the bench, for `Design.follow(hue:)`: the part the surface in front is
    /// bound to, or the kind of part it makes; on Structure, the section that is lit. Nil for a
    /// surface about the song or the library as a whole, and with nothing open.
    var workHue: Int? {
        guard let item = bench.active else { return nil }
        if item.kind == .structure {
            guard let id = activeSection, let section = song?.sections.first(where: { $0.id == id }) else { return nil }
            return SectionHue.index(for: section.name)
        }
        let types = bound(for: item.id).compactMap { song?.version($0)?.type }
        return PartHue.work(of: item.kind, bound: types)
    }

    /// The hue of the section playing, while the transport plays: what Vibrant's display glows in.
    var playingSectionHue: Int? {
        guard transport.isPlaying, let id = activeSection,
              let section = song?.sections.first(where: { $0.id == id }) else { return nil }
        return SectionHue.index(for: section.name)
    }
}
