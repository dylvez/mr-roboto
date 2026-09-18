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

    public static func text(for kind: SurfaceKind) -> (title: String, body: String) {
        switch kind {
        case .importRecord:
            return ("Record",
                    "The record as measured on import: key, tempo, bars and its form. Separate it into "
                        + "stems here — drums, bass, vocals, other — and each stem becomes something you can chop.")
        case .chopLane:
            return ("Chop lane",
                    "A chop is one bar cut from a stem. Its slices play on the pads, and onset sensitivity "
                        + "sets how many there are. Re-groove puts the slices on a feel, which makes a groove for the Grid.")
        case .grid:
            return ("Grid",
                    "A groove is steps, swing and ghost notes for each drum voice. Paint steps, choose a feel, "
                        + "and commit: every commit is a new version, so the one before it is still there.")
        case .sound:
            return ("Sound",
                    "Two jobs. On a chop or a groove, it adds dust — a machine at a mix, kept as a new version "
                        + "with the clean one a step back. On a kit sound, it shapes the synthesized voice.")
        case .chords:
            return ("Chords",
                    "A progression, typed the way a lead sheet says it: Dm7 G7 | Cmaj7. Bars are separated by |. "
                        + "Click a bar to hear it; keep it and the bass writer reads it. With none, the bass is written to the key.")
        case .pianoRoll:
            return ("Piano roll",
                    "A bass line over the bar, with the groove's kicks drawn under it so the lag is visible. The levers "
                        + "re-run the writer in a named player's hands; drag a note to move it. The Bassist reads the result below.")
        case .structure:
            return ("Structure",
                    "The song's form: sections in order, each a name, a length in bars and the versions stitched into it. "
                        + "Drag a block to reorder, set its bars, duplicate it; keep the arrangement and the transport plays the "
                        + "sections one after another.")
        case .album:
            return ("Album",
                    "An album is songs in order, with the loudness targets they are delivered to and a clearance state for "
                        + "every record their samples came from. Drag songs in from the library; nothing is mastered here.")
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

    var body: some View {
        let primer = Primer.text(for: kind)
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
