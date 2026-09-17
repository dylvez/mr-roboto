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

    /// Surfaces the M1 spec defines but Gate B builds: compare, check, proposal, argument.
    public static var gateA: [SurfaceKind] { allCases }
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

/// The bench: at most three surfaces, replacing the oldest unpinned one.
@MainActor
@Observable
public final class Bench {
    public private(set) var items: [BenchItem] = []

    public init() {}

    /// Opens a surface, retiring the oldest unpinned one if the bench is full. Returns what it
    /// retired, so the frame can animate the swap rather than having a panel vanish.
    @discardableResult
    public func open(_ item: BenchItem) -> BenchItem? {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            items[existing] = item
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
        return retired
    }

    public func close(_ id: SurfaceID) { items.removeAll { $0.id == id } }

    public func setPinned(_ pinned: Bool, for id: SurfaceID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isPinned = pinned
    }
}
