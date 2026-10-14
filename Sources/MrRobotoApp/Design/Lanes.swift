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

    /// The class's colour as `role` draws it: as words on the ground, or as a figure on a plate.
    func color(_ role: Design.LaneRole) -> Color { Design.Palette.lane(rawValue, role) }
}

/// A section's hue, by its kind, so a verse is the same colour in every song: the Structure
/// surface's blocks and the transport's strip both wear it, and the transport's display glows in it
/// while the section plays.
enum SectionHue {
    /// The hue index for a section named `name`. Names the app writes — Intro, Verse, Hook, Bridge,
    /// Outro and their numbered kin — get fixed hues; anything else gets one from its letters, so it
    /// is at least the same every time.
    static func index(for name: String) -> Int { SharedPalette.sectionLane(for: name) }

    static func color(for name: String, _ role: Design.LaneRole = .fill) -> Color {
        Design.Palette.lane(index(for: name), role)
    }
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

    static func color(for type: PartType?, _ role: Design.LaneRole = .fill) -> Color? {
        type.flatMap(index(for:)).map { Design.Palette.lane($0, role) }
    }
}

/// A chord's hue, by the step of the key its root stands on, so a progression reads as colours the
/// way Hooktheory's lead sheets do: home red, then round the wheel — two gold, three green, four
/// teal, five sky, six violet, seven magenta. The Chords surface's bars and the Piano roll's chord
/// band both wear it, so a iv is the same teal on both.
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

    /// The chord's colour as `role` draws it; nil for a root the key cannot spell.
    static func color(for chord: Chord, in key: Key, _ role: Design.LaneRole = .fill) -> Color? {
        guard let reading = reading(of: chord, in: key) else { return nil }
        return Design.Palette.lane(index(degree: reading.degree), role)
    }
}

/// A band member's hue: the colour of what it owns, so the Beatmaker speaks in the groove's gold and
/// the Harmonist in the chords' teal wherever either appears. The three who own no part take what
/// is left — the Producer red, the Engineer the take's green, the Peer the words' periwinkle — and the
/// Director keeps the palette's own blue. A member's colour is mostly its name, so it is the colour
/// as words.
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

    /// The member's colour; nil for a name it does not know.
    static func color(forPersona name: String) -> Color? {
        index(forPersona: name).map { Design.Palette.lane($0, .ink) }
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
        switch source {
        case .persona(let name): return color(forPersona: name)
        case .director: return Design.scheme.palette.accent.color
        case .session: return nil
        }
    }
}

/// A member's portrait, ringed in its hue so the face and the colour are learned together.
///
/// Under `markBelow` the portrait's detail is lost, so the member's mark stands in: the same
/// subject drawn as a line, in the hue, on a disc washed with it. The ring sits outside the face
/// but inside the emblem's frame, so a container that clips at its edge never cuts the ring; the
/// room is kept with or without a hue, so a member joining or leaving does not move its row.
struct MemberEmblem: View {
    let name: String
    var hue: Color?
    var width: CGFloat

    static let ringInset: CGFloat = 2.5
    static let markBelow: CGFloat = 32

    var body: some View {
        face
            .padding(Self.ringInset)
            .overlay {
                if let hue {
                    Circle()
                        .strokeBorder(hue, lineWidth: 1.5)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder private var face: some View {
        if width < Self.markBelow, let mark = Art.mark(forEmblem: name) {
            let ink = hue ?? Design.Palette.inkSecondary
            Circle()
                .fill(ink.opacity(0.2))
                .frame(width: width, height: width)
                .overlay {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width * 0.76, height: width * 0.76)
                        .foregroundStyle(ink)
                }
                .accessibilityHidden(true)
        } else {
            ArtImage(name, width: width)
        }
    }
}

/// A part's colour as a stripe down the leading edge of its row, washing out from it across the
/// row, so a list of parts reads as their colours first.
struct PartStripe: ViewModifier {
    let type: PartType?

    func body(content: Content) -> some View {
        if let hue = PartHue.color(for: type) {
            content
                .background {
                    LinearGradient(colors: [hue.opacity(0.2), hue.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(hue)
                        .frame(width: 4)
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
    /// or the library as a whole, and for Sound shaping a drum voice, which is not a track.
    static func work(of kind: SurfaceKind, bound: [PartType]) -> Int? {
        let edits: [PartType]?
        switch kind {
        case .grid: edits = [.groove]
        case .pianoRoll: edits = [.bassline, .melody]
        case .chords: edits = [.progression]
        case .chopLane: edits = [.sample]
        case .importRecord, .takes, .booth: edits = [.audio]
        case .lyrics: edits = [.lyric]
        // The chop or the groove it dusts. Whatever else is bound is not what it edits: a tune
        // bound to it once turned the bench the tune's blue over a kit voice.
        case .sound: return bound.first { $0 == .sample || $0 == .groove }.flatMap(index(for:))
        // About one part, whichever kind: its candidates, its finding.
        case .compare, .check: edits = nil
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

    /// The hue of the section playing, while the transport plays: what the display glows in.
    var playingSectionHue: Int? {
        guard transport.isPlaying, let id = activeSection,
              let section = song?.sections.first(where: { $0.id == id }) else { return nil }
        return SectionHue.index(for: section.name)
    }
}
