import SongGraph
import SwiftUI

/// The contract every surface in the catalog honours. From the M1 spec:
///
/// - **Binds to parts.** A surface opens against part versions from the song graph and holds no
///   state of its own. An edit produces a new version; it never mutates one.
/// - **Plays on touch.** Every candidate, slice, chord or take auditions in place, with no agent
///   round trip. This is the Komma lesson: the payoff is in the first five seconds.
/// - **Two speeds.** Controls run locally against the engine at engine speed. The agent re-enters
///   only when you speak.
/// - **Flags, never fixes.** A critic finding appears as a mark plus a check card. Nothing is
///   corrected silently.
///
/// Surfaces are registered types, so the Director can later choose one by name and fill it. In
/// Gate A you open them yourself; nothing here assumes an agent exists.
public protocol Surface: Identifiable, Sendable {
    /// Stable across reopens, so a pinned surface survives the answer that replaced it.
    var id: SurfaceID { get }

    /// What the catalog calls this: "Chop lane", "Grid".
    static var kind: SurfaceKind { get }

    /// The part versions this surface is bound to. Empty is legal for a surface still being filled.
    var bound: [VersionID] { get }

    /// Shown in the surface's own header, beside the kind: "Bar 9 of Arrival", "Motown feel, 104".
    var title: String { get }
}

public struct SurfaceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// The fixed catalog. The Director picks from this list and fills the surface; it never invents a
/// layout. Twenty-two in the full spec; these are the ones Gate A builds.
public enum SurfaceKind: String, CaseIterable, Sendable {
    /// The record: its waveform, key, tempo, bars, sections and stems. Named for what it shows
    /// rather than for how it got there — you meet it far more often by opening a song than by
    /// importing a file, and the dock reads as the workflow: Record, Chop lane, Grid, Sound.
    case importRecord = "Record"
    case chopLane = "Chop lane"
    case grid = "Grid"
    case sound = "Sound"
    /// M2. The lead sheet (catalog #5): chord symbols over bars, as a `.progression` part.
    case chords = "Chords"
    /// M2. Catalog #7: a bass line's notes over the bar, with the groove's kicks under them.
    case pianoRoll = "Piano roll"
    /// M2. Catalog #14: the form — sections in order, each naming what plays in it and for how
    /// many bars. Bound to nothing: it draws the song's sections, not a version.
    case structure = "Structure"
    /// M3. An album's tracklist, targets and sample clearances. Bound to nothing: it draws a
    /// library album (`AppState.albumBindings`), not a version, and opens from the sidebar.
    case album = "Album"

    // The two answer surfaces. They are in the catalog because the Director has to be able to
    // *name* one — a question with alternatives gets a Compare, a question with one finding gets a
    // Check — and naming is all a `SurfaceAction` does. The views are built separately; until one
    // is registered the bench draws the labelled placeholder, which is the frame working as
    // designed rather than a gap.
    /// Candidates judged against the thing they are meant to beat, which stays visible at the top.
    case compare = "Compare"
    /// One finding about one part, flagged and never silently fixed.
    case check = "Check"

    /// The ones the user drives themselves: the dock, ⌘1–⌘7, the Surfaces menu. In workflow
    /// order: a record, its chop, the groove, the chords, the bass under them, the sound, the form.
    public static let gateA: [SurfaceKind] = [.importRecord, .chopLane, .grid, .chords, .pianoRoll, .sound, .structure]

    /// The surfaces that draw the song or the library rather than a version of a part, and so
    /// open on nothing.
    public var isUnbound: Bool { self == .structure || self == .album }

    /// The two the Director opens to answer with. You do not pick these off a shelf — a Compare
    /// with nothing to compare is not a surface, it is an empty promise — so they are deliberately
    /// absent from the dock and from ⌘1–⌘4.
    public static let answers: [SurfaceKind] = [.compare, .check]

    /// Whether this surface only exists as an answer to something.
    public var isAnswer: Bool { Self.answers.contains(self) }
}

/// A surface in the bench, with the state the frame owns rather than the surface.
public struct BenchItem: Identifiable, Sendable {
    public let id: SurfaceID
    public let kind: SurfaceKind
    public let title: String
    /// A pinned surface survives the next answer; unpinned ones are replaced oldest-first.
    public var isPinned: Bool
    public let openedAt: Date

    public init(id: SurfaceID, kind: SurfaceKind, title: String,
                isPinned: Bool = false, openedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isPinned = isPinned
        self.openedAt = openedAt
    }
}

/// The bench: at most three surfaces, replacing the oldest unpinned one — and, of those three, the
/// one you are working in is what gets drawn.
///
/// `items` is the model and has not changed: three surfaces, oldest unpinned retired, pinning
/// protects. What changed is `visible`, which is what the bench draws. In Gate B, where a Director
/// opens a Compare and a Check beside the decision you are making, `Design.maximumVisibleSurfaces`
/// rises to three and the bench stacks them again. In Gate A there is no Director, you drive one
/// surface at a time, and stacking three of them cost the instrument two thirds of its height for a
/// mechanic that does not exist yet.
///
/// Pinning is the exception, and it is exactly the right one: a pinned surface is the case where you
/// have said you want to keep looking at something while you work on something else. So one surface
/// fills the bench, and pinning a second splits it.
@MainActor
@Observable
public final class Bench {
    public private(set) var items: [BenchItem] = []

    /// The surface you are working in: the one that fills the bench. Set by opening a surface and by
    /// bringing one forward from the dock; never nil while anything is open.
    public private(set) var activeID: SurfaceID?

    public init() {}

    /// Opens a surface, retiring the oldest unpinned one if the bench is full, and makes it the one
    /// you are working in. Returns what it retired, so the frame can say what it closed rather than
    /// having a panel vanish.
    @discardableResult
    public func open(_ item: BenchItem) -> BenchItem? {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            items[existing] = item
            activeID = item.id
            return nil
        }
        var retired: BenchItem?
        if items.count >= Design.maximumOpenSurfaces {
            if let oldest = items.enumerated()
                .filter({ !$0.element.isPinned })
                .min(by: { $0.element.openedAt < $1.element.openedAt })?.offset {
                retired = items.remove(at: oldest)
            } else {
                // Everything is pinned: the newest pin gives way rather than refusing to answer.
                retired = items.removeFirst()
            }
        }
        items.append(item)
        activeID = item.id
        return retired
    }

    public func close(_ id: SurfaceID) {
        items.removeAll { $0.id == id }
        if activeID == id { activeID = items.last?.id }
    }

    public func setPinned(_ pinned: Bool, for id: SurfaceID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isPinned = pinned
    }

    /// Brings an already-open surface forward without reopening it: no retirement, no new binding,
    /// nothing retitled. This is what a dock chip does for a surface that is already on the bench.
    public func focus(_ id: SurfaceID) {
        guard items.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Renames a surface in place, keeping its pin, its position and — unlike `open` — whatever you
    /// are currently working in. A surface that learns its title after it loads must not steal focus.
    public func rename(_ id: SurfaceID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i] = BenchItem(id: id, kind: items[i].kind, title: title,
                             isPinned: items[i].isPinned, openedAt: items[i].openedAt)
    }

    public var active: BenchItem? { items.first { $0.id == activeID } }

    /// What the bench draws, in bench order: everything pinned, plus the one you are working in.
    ///
    /// Capped at `Design.maximumVisibleSurfaces`; when pins would overflow that, the oldest pinned
    /// one gives up its place on screen rather than the surface you are actually in. It stays open —
    /// it is still in `items`, and its dock chip is still lit — so nothing is lost, only undrawn.
    public var visible: [BenchItem] {
        guard let active else { return [] }
        var shown = items.filter { $0.isPinned || $0.id == active.id }
        while shown.count > Design.maximumVisibleSurfaces {
            guard let drop = shown.firstIndex(where: { $0.id != active.id }) else { break }
            shown.remove(at: drop)
        }
        return shown
    }
}
