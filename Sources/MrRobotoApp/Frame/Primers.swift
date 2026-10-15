import Observation
import SwiftUI

/// One line per surface saying what it is for and what it makes, shown the first time you open it.
///
/// The surfaces were built to be self-evident to someone who already knew the idioms, and nobody
/// arrives knowing them. A tour would be the wrong fix — it front-loads the vocabulary before there
/// is anything on screen to attach it to — so each surface says its one line at the moment you first
/// meet it, and then gets out of the way. The `?` in every surface header brings it back, and the
/// Field Guide window lists them all.
///
/// Every primer names what the surface *makes* and where that goes next, because the thing that was
/// missing was never what a surface does in isolation; it was how one surface's output is the next
/// one's input.
public enum Primer {

    /// - Parameter variant: a surface with modes names which one it is in, so the primer explains
    ///   what is actually on screen rather than what the surface usually does.
    public static func text(for kind: SurfaceKind, variant: String? = nil) -> (title: String, body: String) {
        switch kind {
        case .importRecord:
            return ("Record",
                    "The record as measured on import: key, tempo, bars and its form. Separate it into "
                        + "stems here — drums, bass, vocals, other — and each stem becomes something you can chop.")
        case .chopLane:
            return ("Chop lane",
                    "A chop is one bar cut from a stem, and it plays in the song as cut. Its slices play on the pads, and "
                        + "onset sensitivity sets how many there are; your edits keep themselves. Re-groove puts the slices on a "
                        + "feel, and Make the groove keeps it: a groove that plays these slices in the song, in place of the loop. "
                        + "Dust puts the bar through a machine — an SP-1200, a cassette — as a new version, the clean one a step back.")
        case .grid:
            return ("Grid",
                    "A groove is steps, swing and ghost notes for each drum voice, one bar or several. Paint steps, choose "
                        + "a feel, set the bars, or press Record MIDI and play pads against the song: each hit lands on its step. "
                        + "It keeps itself a moment after you stop, as a new version, and ⌘Z steps back. Dust puts the groove "
                        + "through a machine; right-click a voice's name to shape its sound.")
        case .chords:
            return ("Chords",
                    "A progression, typed the way a lead sheet says it: Dm9 G13 | Cmaj9. Bars are separated by |. "
                        + "Click a bar to hear it, or press Record MIDI and play chords: each is written as the next bar. "
                        + "What you type keeps itself, and the bass writer reads it. With none, the bass "
                        + "is written to the key. Played and Voiced say how a player plays them: the rhythm they are struck "
                        + "in, and where the notes of each chord sit.")
        case .pianoRoll where variant == "melody":
            return ("Piano roll · melody",
                    "A tune, as many bars long as you set: click to place a note, drag it to move it, or press Record MIDI "
                        + "and play it against the song, then Tighten it to the grid. Ask the band and the Director writes one for the "
                        + "Melodist. The Melodist reads it below, and it keeps itself as you go.")
        case .pianoRoll:
            return ("Piano roll",
                    "A bass line, with the groove's kicks drawn under it so the lag is visible. The levers re-run the writer "
                        + "in a named player's hands; drag a note to move it, or press Record MIDI and play your own. The writer's "
                        + "line is a proposal until you touch it; "
                        + "then it keeps itself. The Bassist reads the result below.")
        case .structure:
            return ("Structure",
                    "The song's form: sections in order, each a name, a length in bars and the parts stitched into it. "
                        + "A section plays each part's newest version and follows it as you work, so keeping a new take is "
                        + "heard where the old one was. Drag a block to reorder, set its bars, duplicate it; the form keeps "
                        + "itself, and double-clicking a section in the transport plays from it. Develop the song writes "
                        + "the arrangement from the loop: each section playing it its own way, with a level of its own.")
        case .album:
            return ("Album",
                    "An album is songs in order, with the loudness targets they are delivered to and a clearance state for "
                        + "every record their samples came from. Drag songs in from the library; nothing is mastered here.")
        case .lyrics:
            return ("Lyrics",
                    "Type the words, a line each, a blank line between stanzas, and label a stanza with its section — [Verse], "
                        + "[Hook] — so the Booth shows it when you sing that section. Set to melody puts a syllable on each note, and "
                        + "the Lyricist says where a stressed one lands off the beat. Every stanza gets its rhyme scheme; the words "
                        + "keep themselves as a version, like any part.")
        case .cast:
            return ("Cast",
                    "Who is in the room for this song. Each persona owns one thing and listens for it first; take one out "
                        + "and the Director stops consulting it. The house calls are what you decided on their open questions, by ear.")
        case .merge:
            return ("Merge",
                    "Two fragments, one key, one tempo. The plan says how each moves — semitones and a stretch for audio, "
                        + "arithmetic for a written part, nothing for a groove — with the numbers editable. Play each, play both, "
                        + "then stitch them as a section: the moved versions land in the song with the originals one step back.")
        case .compare:
            return ("Compare",
                    "The band's candidates, each judged against the thing at the top that it has to beat. "
                        + "Play them, then take the one you want; the others stay in the song's history.")
        case .check:
            return ("Check",
                    "One finding from a critic about one part. Critics flag and never fix: the fix is "
                        + "offered, and taking it is yours.")
        case .booth:
            return ("Booth",
                    "Pick a section and a count-in, press Record: the song plays from that section under you, with that "
                        + "section's words in view, and the take lands on the bar you sang it on, latency taken out. Keep going "
                        + "sings the section pass after pass, each a take. Every take stays, lane by "
                        + "lane below, where the band flags bars and you make the comp.")
        case .sources:
            return ("Sources",
                    "A stem of a record in the library, or a few of its bars, brought into the open song. The song's key, "
                        + "tempo and bars stand: the record is moved to meet them, its first bar on the bar you choose, or its bars "
                        + "fitted to whole bars and looped like a chop. Preview eight bars against the song, add it, and fit it "
                        + "again later from the untouched record — another semitone, another bar.")
        case .library:
            return ("Library",
                    "Everything the house has made and brought in, a shelf at a time: songs, records, ideas, samples and "
                        + "albums. Type to search every word a thing says about itself; sort by any column; narrow by key, "
                        + "tempo — half and double time count — and whether anything uses it. Pick one to read it without "
                        + "opening it: what a song is made from, which songs take from a record. What can be done to it is "
                        + "under its name; drag a row, a stem or a chop onto the song or a section to bring it in.")
        case .mashup:
            return ("Mashup",
                    "Two songs from the library on one grid. One keeps its tempo and key — usually the instrumental — and the "
                        + "other is shifted and stretched to meet it, first downbeat on a bar line. Choose stems from each — or "
                        + "a song's full record — preview eight bars, then make the song: it lands in the library with its stems in place.")
        case .mixer:
            return ("Mixer",
                    "A strip per part: fader, pan, reverb and echo sends, mute and solo, three bands of EQ, a compressor and an "
                        + "insert, an amp or a rotating speaker, with meters while the song plays. \"Level in…\" sets a strip's level, "
                        + "its speaker or its echo for one section alone; the room and the echo's time are on the Returns row. Every "
                        + "move you let go of is a mix version — step back from Parts. Pick two strips "
                        + "and the overlay says where they share energy, band by band, in dB. The master is on its own tab.")
        case .master:
            return ("Master",
                    "The last bounce read against the target: integrated loudness, true peak, crest and the spectrum. The "
                        + "target and the ceiling are the album's, or −14 / −1. The Engineer's readings say what to change first; "
                        + "nothing here is applied to a part.")
        case .takes:
            return ("Takes",
                    "Every take of one part, lane by lane against the bars, with the band's flags on the bar they belong "
                        + "to — cents and milliseconds, never adjectives. Choose which take each bar comes from, or Pick the "
                        + "clean bars to take each from the take flagged least there; hear the comp, then make it: one version, "
                        + "seams crossfaded, the takes under it in the history.")
        }
    }
}

extension Primer {
    /// The primer in one line: what the surface is for, said under its title while the primer is
    /// showing. The whole primer is behind the `?`.
    public static func summary(for kind: SurfaceKind, variant: String? = nil) -> String {
        switch kind {
        case .importRecord: return "The record as measured — key, tempo, bars, form — and its stems, ready to chop."
        case .chopLane: return "One bar cut from a stem, its slices on the pads; Re-groove puts them on a feel, Dust through a machine."
        case .grid: return "Steps, swing and ghost notes for each drum voice, its machine and its dust. It keeps itself as you paint."
        case .chords: return "A progression, typed the way a lead sheet says it: Dm9 G13 | Cmaj9."
        case .pianoRoll where variant == "melody": return "A tune: click to place a note, drag to move it, or play one in."
        case .pianoRoll: return "A bass line over the groove's kicks; the levers re-run it in a player's hands."
        case .structure: return "The song's form: sections in order, each with its bars and the parts that play in it."
        case .album: return "Songs in order, the loudness they are delivered at, and a clearance for every record."
        case .lyrics: return "The words, a line each; label a stanza [Verse] or [Hook] and the Booth shows it."
        case .cast: return "Who is in the room for this song, and what each of them listens for."
        case .merge: return "Two fragments moved to one key and one tempo, then stitched as a section."
        case .compare: return "The band's candidates, each judged against the thing it has to beat."
        case .check: return "One finding from a critic about one part. Flagged, never fixed for you."
        case .booth: return "Pick a section and a count-in, press Record; every take stays."
        case .sources: return "A stem, or some bars, of a record, moved to the song's key, tempo and bars."
        case .library: return "Everything made and brought in, a shelf at a time: search it, hear it, act on it."
        case .mashup: return "Two songs on one grid: one keeps its key and tempo, the other meets it."
        case .mixer: return "A strip per part — level, pan, sends, EQ, compressor, insert — with meters."
        case .master: return "The last bounce against the target: loudness, true peak, crest and spectrum."
        case .takes: return "Every take of one part, lane by lane, with the band's flags. Make the comp."
        }
    }
}

/// Which primers you have dismissed, remembered across launches.
@MainActor
@Observable
public final class PrimerStore {
    public private(set) var dismissed: Set<SurfaceKind>
    /// Primers brought back with `?` for this launch, even though they were dismissed once.
    public private(set) var recalled: Set<SurfaceKind> = []

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dismissed = Set(SurfaceKind.allCases.filter { defaults.bool(forKey: Self.key($0)) })
    }

    static func key(_ kind: SurfaceKind) -> String { "primer.dismissed.\(kind.rawValue)" }

    public func isShowing(_ kind: SurfaceKind) -> Bool {
        !dismissed.contains(kind) || recalled.contains(kind)
    }

    public func dismiss(_ kind: SurfaceKind) {
        dismissed.insert(kind)
        recalled.remove(kind)
        defaults.set(true, forKey: Self.key(kind))
    }

    /// The `?` in a surface header: shows it again, or hides it if it is showing.
    public func toggle(_ kind: SurfaceKind) {
        if isShowing(kind) { dismiss(kind) } else { recalled.insert(kind) }
    }

    /// Help ▸ Show All Primers Again.
    public func resetAll() {
        for kind in SurfaceKind.allCases { defaults.removeObject(forKey: Self.key(kind)) }
        dismissed = []
        recalled = []
    }
}

/// The primer, drawn under a surface's header.
struct PrimerBanner: View {
    let kind: SurfaceKind
    let store: PrimerStore

    var variant: String?

    var body: some View {
        let primer = Primer.text(for: kind, variant: variant)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (Text(primer.title + ". ").font(Design.Typography.ui(12.5, weight: .semibold))
                + Text(primer.body).font(Design.Typography.ui(12.5, weight: .regular)))
                .foregroundStyle(Design.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Got it") { store.dismiss(kind) }
                .buttonStyle(.plain)
                .font(Design.Typography.ui(12, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .help("Hide this. The ? in the header brings it back.")
        }
        .padding(.horizontal, Design.Metric.inset)
        .padding(.vertical, 9)
        .background(Design.Palette.accentSoft)
        .overlay(alignment: .leading) {
            Rectangle().fill(Design.Palette.accent).frame(width: 2)
        }
    }
}

/// The primer as a surface shows it: the one line under its title, quiet, with the whole primer a
/// click away and a way to put it away for good. A banner the width of the surface used to carry
/// the whole primer; this costs one line of the surface's own height.
struct PrimerLine: View {
    let kind: SurfaceKind
    let store: PrimerStore
    var variant: String?
    @State private var isShowingAll = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Primer.summary(for: kind, variant: variant))
                .font(Design.Typography.role(.callout))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("More") { isShowingAll = true }
                .buttonStyle(.plain)
                .font(Design.Typography.role(.callout))
                .foregroundStyle(Design.Palette.accent)
                .fixedSize()
                .help("The whole primer")
                .popover(isPresented: $isShowingAll, arrowEdge: .bottom) {
                    PrimerPopover(kind: kind, variant: variant)
                }
            Spacer(minLength: 8)
            Button {
                store.dismiss(kind)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Palette.inkTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this line. The ? in the header has the whole primer.")
        }
        .padding(.horizontal, Design.Metric.inset)
        .padding(.bottom, 8)
    }
}

/// The whole primer, behind a surface's `?`.
struct PrimerPopover: View {
    let kind: SurfaceKind
    var variant: String?

    var body: some View {
        let primer = Primer.text(for: kind, variant: variant)
        VStack(alignment: .leading, spacing: 6) {
            Text(primer.title)
                .font(Design.Typography.role(.title3))
                .foregroundStyle(Design.Palette.ink)
            Text(primer.body)
                .font(Design.Typography.role(.body))
                .foregroundStyle(Design.Palette.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}
