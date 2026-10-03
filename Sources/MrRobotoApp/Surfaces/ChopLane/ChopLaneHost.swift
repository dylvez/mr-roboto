import Analysis
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// What the Chop lane needs from whatever is hosting it.
///
/// Deliberately tiny, and deliberately not `AppState` itself. The frame and its `AppState` were
/// being built alongside this surface; a surface that named that type would have been unbuildable
/// and untestable until it landed, and would still be untestable without an audio device.
/// Three capabilities are all this lane actually uses:
///
/// - **audition**: hand the host a rendered chop, then fire pads at it. The host owns the engine,
///   the sampler and the disk; the surface owns nothing that makes sound. Splitting it this way is
///   what keeps "plays on touch" true — `prepareAudition` happens on an edit, `audition` happens
///   on the touch, and the touch does no work beyond posting a hit.
/// - **versioning**: an edit becomes a new, immutable part version. The surface builds it and hands
///   it over; where it goes is the host's business. The surface never mutates a version and never
///   writes to the graph itself.
/// - **the song**: read-only, so a commit can derive from the version it opened against. Optional,
///   because a lane can be opened on a loose idea before a song exists.
///
/// The two graph members are spelled the way the frame's `AppState` already spells them
/// (`song`, `record(_:)`), and the way the Sound surface's own host protocol does, so the frame has
/// nothing to adapt. The audition members are the lane's own: `AppState` hands surfaces an
/// `Engine` and lets each one drive it, exactly as the Grid surface's `GridHosting` does, so a live
/// chop-lane host is a small type over a `VoiceSampler` rather than anything the frame owes us.
///
/// `AppTests` supplies a stub conforming to this, so every test here runs with no audio device,
/// no engine and no file store.
@MainActor
public protocol ChopLaneHost: AnyObject {
    /// The song this lane is working inside, when there is one. Read-only: a surface proposes
    /// versions, it does not write them.
    var song: Song? { get }

    /// Make this chop playable, now. Called when the slice set or a pad's controls change, never
    /// on the touch that plays a pad.
    func prepareAudition(_ kit: ChopKit) throws

    /// Play, immediately. `Hit.time` is seconds from this instant, so a pad is a single hit at 0.
    func audition(_ hits: [VoiceSampler.Hit])

    /// Silence anything this surface has auditioning.
    func stopAudition()

    /// Take a new, immutable part version.
    ///
    /// - Returns: `false` when the host refused it, so the surface can keep the edit rather than
    ///   pretending it was kept.
    @discardableResult
    func record(_ version: PartVersion) -> Bool

    /// A groove this lane made from its chop has been recorded. The host puts the groove on the
    /// chop's own slices, so the song plays what the lane played.
    func madeGroove(_ groove: PartVersion, fromChop chop: PartID)

    /// Gives a chop the song holds the level its bar asks for, or puts it back as recorded, as
    /// the chop's next version. The level it now plays at in dB over its recording (0 as
    /// recorded), or nil when nothing moved.
    func levelChop(_ chop: PartID, asRecorded: Bool) -> Double?
}

extension ChopLaneHost {
    public func madeGroove(_ groove: PartVersion, fromChop chop: PartID) {}
    public func levelChop(_ chop: PartID, asRecorded: Bool) -> Double? { nil }
}

/// The bar the Chop lane opens against: the audio, where it came from, and the grid it sits on.
///
/// Immutable. Re-slicing, dragging a marker and re-grooving all read this and produce new values;
/// nothing here is ever edited in place, because the source bar is not the thing being edited —
/// the part version is.
public struct ChopLaneSource: Sendable {
    /// The media the bar was lifted out of, by content hash. What a committed `Sample` points at.
    public var media: MediaRef
    /// The part this bar already belongs to, when it is already a part. Nil starts a new one.
    public var partID: PartID?
    /// The library record, when known. Drives clearances downstream.
    public var record: RecordID?
    /// Mono of the region: what is detected, classified and drawn.
    public var mono: [Float]
    /// The region as it plays, planar. One channel is legal and is what the tests use.
    public var planar: [[Float]]
    public var sampleRate: Double
    /// Where frame 0 sits in the record, in seconds. Slice markers are written back in the
    /// record's own time, so this is what makes a committed `Sample` mean anything.
    public var sourceOffset: Double
    /// The record's grid, in the record's own time. Grid snapping and the grid lines the eye sees
    /// both come from here; with no grid the lane snaps to onsets only.
    public var grid: BeatGrid?
    /// The record's tempo, when the analysis found one. Seeds the re-groove tempo.
    public var tempo: Double?
    /// What the lane calls this: "Bar 9 of Arrival".
    public var label: String

    public init(media: MediaRef, partID: PartID? = nil, record: RecordID? = nil, mono: [Float],
                planar: [[Float]]? = nil, sampleRate: Double, sourceOffset: Double = 0,
                grid: BeatGrid? = nil, tempo: Double? = nil, label: String = "Bar") {
        self.media = media
        self.partID = partID
        self.record = record
        self.mono = mono
        self.planar = planar ?? [mono]
        self.sampleRate = sampleRate
        self.sourceOffset = sourceOffset
        self.grid = grid
        self.tempo = tempo
        self.label = label
    }

    public var frameCount: Int { mono.count }
    public var duration: Double { sampleRate > 0 ? Double(mono.count) / sampleRate : 0 }

    /// True when the planar audio matches the mono the analysis is run on — the only shape
    /// `ChopMap.render` will accept.
    public var isWellFormed: Bool {
        guard sampleRate > 0, !mono.isEmpty, let frames = planar.first?.count else { return false }
        return frames == mono.count && planar.allSatisfy { $0.count == frames }
    }
}

/// A critic finding drawn on the lane.
///
/// **Gate B fills this; Gate A never does.** It exists now so the seam is a shape rather than a
/// refactor: the model carries `marks`, the waveform draws them in the warn colour, and nothing
/// in this surface ever writes one. When the critic arrives it hands the lane marks and the lane
/// already knows where to put them. Per the catalog's fourth rule, a mark flags and never fixes:
/// there is no code path here that acts on one.
public struct ChopLaneMark: Identifiable, Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable, CaseIterable {
        case note, warn
    }

    public let id: UUID
    /// The slice this is about, when it is about one.
    public var sliceIndex: Int?
    /// Seconds from frame 0 of the source.
    public var start: Double
    public var end: Double
    /// One line, shown on the check card the mark opens.
    public var summary: String
    public var severity: Severity

    public init(id: UUID = UUID(), sliceIndex: Int? = nil, start: Double, end: Double,
                summary: String, severity: Severity = .warn) {
        self.id = id
        self.sliceIndex = sliceIndex
        self.start = start
        self.end = max(start, end)
        self.summary = summary
        self.severity = severity
    }
}

public enum ChopLaneError: Error, CustomStringConvertible, Equatable {
    case noHost
    case noFeel
    case malformedSource
    case versionRefused

    public var description: String {
        switch self {
        case .noHost: return "chop lane: no host to play or version through"
        case .noFeel: return "chop lane: pick a feel before re-grooving"
        case .malformedSource: return "chop lane: the source audio is empty or ragged"
        case .versionRefused: return "chop lane: the host would not take the version"
        }
    }
}
