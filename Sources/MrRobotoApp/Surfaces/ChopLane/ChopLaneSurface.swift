import Analysis
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Synchronization

/// The Chop lane: where a bar of a record becomes something you can play.
///
/// The model. It owns no audio engine and no file store — it turns a bar into a `Chop`, a
/// `ChopMap` and a `RegroovePerformance`, and hands those to a `ChopLaneHost`. Everything it does
/// is a pure function of the source bar plus the handful of decisions below, which is why the
/// whole surface is testable with no audio device.
///
/// ## The two levers
///
/// The catalog allows two prominent levers. They are **sensitivity** (how finely the bar is cut)
/// and **feel** (whose rhythm it is played in). Everything else — the tempo, the per-slice pitch,
/// gain, reverse and stretch, the classification overrides — is secondary, reachable but never
/// competing with those two for the eye.
///
/// ## No state of its own
///
/// The marker positions live in a part version, not here. `commitChop` writes them; reopening the
/// lane on that version restores them. What is genuinely surface-local is the audition rig (the
/// rendered kit, the stretch cache), the in-flight drag, and a fingerprint of what was last kept
/// so the lane can say whether it is holding anything the ledger is not — none of which is an
/// edit until it is committed.
@MainActor
@Observable
public final class ChopLaneSurface: Surface {

    // MARK: Surface

    public nonisolated let id: SurfaceID
    public nonisolated static var kind: SurfaceKind { .chopLane }

    /// `Surface` refines `Sendable`, so its requirements cannot be witnessed by main-actor state:
    /// the compiler rejects a main-actor-isolated conformance to a `Sendable`-inheriting protocol.
    /// The two mutable requirements are therefore published through a mutex from the main actor.
    /// `versions` and `headline` below are the observable originals; this is a mirror, never a
    /// second source of truth.
    struct Published: Sendable {
        var bound: [VersionID]
        var title: String
    }

    @ObservationIgnored private let published: Mutex<Published>

    public nonisolated var bound: [VersionID] { published.withLock { $0.bound } }
    public nonisolated var title: String { published.withLock { $0.title } }

    /// The part versions this lane is bound to, observably. After a commit this is the new one.
    public private(set) var versions: [VersionID] { didSet { publish() } }
    /// The lane's own headline: "Bar 9 of Arrival, 6 slices".
    public private(set) var headline: String { didSet { publish() } }

    private func publish() {
        published.withLock { $0 = Published(bound: versions, title: headline) }
    }

    // MARK: The bar

    public let source: ChopLaneSource
    public private(set) weak var host: (any ChopLaneHost)?

    /// The part a commit belongs to: the one the bar came from, or a new one this lane starts.
    /// Stable for the lane's lifetime, so two commits are two versions of one part rather than
    /// two parts.
    @ObservationIgnored public let partID: PartID

    // MARK: Sensitivity
    //
    // The M1 decision this surface exists to honour: the onset threshold is a control, not a
    // hidden default. `SpectralFluxOnsetDetector.threshold` is δ added to the local mean of the
    // detection function — bigger δ means fewer, surer onsets — so the dial is inverted to read
    // the way a person thinks about it: more sensitivity, more slices.

    /// δ at sensitivity 0. High enough that only the accents of a bar survive.
    public nonisolated static let thresholdAtZero: Float = 9
    /// δ at sensitivity 1. Low enough to find ghost notes, and false positives with them.
    public nonisolated static let thresholdAtOne: Float = 1

    /// Where the dial starts: 0.625, which is δ = 4.
    ///
    /// `Analysis`'s own default is δ = 5, tuned so beat coverage is high with *no* false positives
    /// on a click train — the right trade for a tracker, which a phantom beat poisons. A chopper's
    /// trade runs the other way. A marker you did not want is one drag from being dragged onto
    /// something you did, or one gesture from being deleted; a hit that was never detected is
    /// invisible, and you cannot play a pad that does not exist. Under-slicing costs you a sound;
    /// over-slicing costs you a drag.
    ///
    /// So the lane opens one notch looser than the analysis default. Measured on bars of the
    /// Arrival drum stem, δ = 5 finds 5 or 6 onsets in a bar and δ = 4 finds 7 to 10 — the six to
    /// eight the spec describes — while δ = 3 runs to 10 to 14 and starts reporting room tone.
    /// Four is the last value on that slope that is still all drums.
    public nonisolated static let defaultSensitivity: Double = 0.625

    /// δ for a position on the dial.
    public nonisolated static func threshold(forSensitivity sensitivity: Double) -> Float {
        let s = Float(min(1, max(0, sensitivity)))
        return thresholdAtZero + (thresholdAtOne - thresholdAtZero) * s
    }

    /// 0…1. Higher finds more slices. Changing it re-detects and re-slices, which is the whole
    /// point of it being a control: you hear the bar get finer as you turn it.
    public var sensitivity: Double = ChopLaneSurface.defaultSensitivity {
        didSet {
            let clamped = min(1, max(0, sensitivity))
            // Write the clamped value back and let the nested `didSet` do the work, so an
            // out-of-range write still re-slices at the value it actually landed on.
            if clamped != sensitivity { sensitivity = clamped; return }
            guard clamped != slicedAtSensitivity else { return }
            resliceFromDetection()
        }
    }

    /// The dial position the current slices were cut at. Compared against rather than `oldValue`,
    /// which after a clamp is a number the lane never used.
    @ObservationIgnored private var slicedAtSensitivity = ChopLaneSurface.defaultSensitivity

    /// The δ the dial currently means. Shown beside it, because a number a user can repeat is
    /// worth more than a dial they cannot.
    public var onsetThreshold: Float { Self.threshold(forSensitivity: sensitivity) }

    // MARK: Slicing decisions

    /// How far a dragged marker, or a detected onset, may be from something and still land on it.
    /// The same 25 ms `Chopper` uses: close enough to be a timing error, far enough that a dragged
    /// or swung hit survives.
    public var snapTolerance: Double = 0.025
    /// Subdivisions per beat of the snap grid. 4 is sixteenths.
    public var gridDivision: Int = 4

    // MARK: State

    /// Marker start times, seconds from frame 0 of the source. The detector seeds them; dragging,
    /// adding and deleting edit them.
    public private(set) var markers: [Double] = []
    /// What the detector found at the current sensitivity, whatever the markers have since become.
    /// Dragging snaps to these, so a marker can always be put back on a real transient.
    public private(set) var detectedOnsets: [Double] = []
    /// Grid lines in the buffer's own time, for snapping and for drawing.
    public private(set) var gridLines: [Double] = []
    public private(set) var chop: Chop
    public private(set) var classifications: [SliceClassification] = []
    /// Hand classifications. The classifier is wrong sometimes by design; this is the override the
    /// M1 spec requires be exposed, and it is carried into the re-groove and into the commit.
    public private(set) var overrides: [Int: SliceClass] = [:]
    /// Per-pad trims.
    public private(set) var edits: [Int: SliceEdit] = [:]
    /// True once a marker has been dragged, added or deleted — so the view can warn that turning
    /// the sensitivity dial will throw those edits away.
    public private(set) var handEdited = false
    /// Critic findings. Always empty in Gate A; see `ChopLaneMark`.
    public var marks: [ChopLaneMark] = []
    /// The last thing that went wrong, for the surface's own footer. Never an alert.
    public private(set) var lastError: String?

    // MARK: What has been kept
    //
    // A lane is closed by the bench, not by a keep, so it has to know what it is still holding
    // that the ledger is not. Each of the two commits leaves a fingerprint of what it wrote; the
    // lane compares what it would write now against that.

    /// What `commitChop` last wrote, or what the lane opened on. Nil when the lane opened with no
    /// version, because then nobody has ever kept this chop.
    ///
    /// Opening is not a change: a lane opened on a version takes the fingerprint of its own fresh
    /// detection, so an untouched lane never claims to hold unkept work and the bench can close it
    /// without a word. Only what the user does after that counts.
    private var keptChop: KeptCut?

    /// What `commitChop` writes, as one comparable value: the markers with their classes, and the
    /// pads' trims.
    struct KeptCut: Equatable {
        var markers: [SliceMarker]
        var pads: [PadTrim]
    }

    private var cut: KeptCut { KeptCut(markers: sliceMarkers, pads: padTrims) }
    /// The re-groove last heard through `playRegroove`. A re-groove has been made when it has been
    /// played, and not before: a feel picked and never played is a setting, not a thing to keep.
    private var playedRegroove: RegrooveSetting?
    /// The re-groove `commitRegroove` last wrote.
    private var keptRegroove: RegrooveSetting?

    /// Which pad the eye is on. Auditioning one selects it.
    public var selectedSlice: Int?

    // MARK: Keeping as it goes

    /// What ⌘Z steps back through: the cut, the classes and the trims.
    struct ChopState: Equatable, Sendable {
        var markers: [Double]
        var overrides: [Int: SliceClass]
        var edits: [Int: SliceEdit]
        var handEdited: Bool
    }

    private var history = EditHistory<ChopState>()
    private var lastEdit: (kind: String, at: Date)?
    /// Keeps the chop a moment after the last edit. A test sets its delay to nil.
    public let autoKeep = AutoKeep()

    private var state: ChopState {
        ChopState(markers: markers, overrides: overrides, edits: edits, handEdited: handEdited)
    }

    private func apply(_ restored: ChopState) {
        markers = restored.markers
        overrides = restored.overrides
        edits = restored.edits
        handEdited = restored.handEdited
        rebuildChop()
    }

    /// Before an edit; a slider dragged is one step of undo.
    private func willEdit(_ kind: String) {
        let now = Date()
        defer { lastEdit = (kind, now) }
        if let last = lastEdit, last.kind == kind, now.timeIntervalSince(last.at) < 0.75 { return }
        history.record(state)
    }

    /// After an edit: the chop keeps itself once the edits settle, a trim as much as a marker.
    private func didEdit() {
        guard hasUnkeptChopEdits else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    // MARK: Re-groove

    public let feels: FeelLibrary
    /// The feel the chop is played in. Nil plays the bar as it was cut.
    public var feelName: String? {
        didSet {
            guard feelName != oldValue else { return }
            if let feel, !feel.suits(tempo: tempo) { tempo = feel.suggestedTempo }
        }
    }
    /// Target tempo of the re-groove, in BPM. Secondary to the feel, and seeded from it.
    public var tempo: Double
    /// How many times the feel is laid down.
    public var repeats: Int = 2
    /// What happens to a slice longer than the room its step gives it.
    public var overlap: Regroove.Overlap = .ring

    public var feel: Feel? { feelName.flatMap { feels.feel(named: $0) } }

    /// Feels worth offering for this bar, best first.
    public var suggestedFeels: [Feel] {
        feels.suggest(for: FeelLibrary.Request(tempo: source.tempo, limit: 8))
    }

    /// Everything that decides what a re-groove sounds like, as one comparable value. Two
    /// re-grooves with the same setting are the same re-groove, which is how the lane knows
    /// whether the one it is hearing is the one it kept.
    public struct RegrooveSetting: Hashable, Sendable {
        public var feelName: String
        public var tempo: Double
        public var repeats: Int
        public var overlap: Regroove.Overlap
    }

    /// The re-groove the levers currently describe, or nil with no feel picked.
    public var currentRegroove: RegrooveSetting? {
        feel.map { RegrooveSetting(feelName: $0.name, tempo: tempo, repeats: repeats, overlap: overlap) }
    }

    // MARK: Audition

    @ObservationIgnored private let stretch = SliceStretch()
    /// True when the host is holding a kit that no longer matches the map. Cleared by
    /// `refreshAudition`, which every mutator schedules and every audition forces.
    public private(set) var needsAuditionRefresh = true

    // MARK: Init

    public init(id: SurfaceID = SurfaceID(), source: ChopLaneSource,
                host: (any ChopLaneHost)? = nil, version: VersionID? = nil,
                feels: FeelLibrary = .standard) {
        self.id = id
        self.source = source
        self.partID = source.partID ?? PartID()
        self.host = host
        self.feels = feels
        let openedOn = version.map { [$0] } ?? []
        self.versions = openedOn
        self.headline = source.label
        self.tempo = source.tempo ?? 90
        self.chop = Chop(slices: [], sampleRate: source.sampleRate,
                         sourceFrameCount: source.frameCount, sourceOffset: source.sourceOffset,
                         detectedTempo: source.tempo)
        self.published = Mutex(Published(bound: openedOn, title: source.label))
        guard source.isWellFormed else {
            lastError = ChopLaneError.malformedSource.description
            return
        }
        self.gridLines = Self.lines(of: source, division: gridDivision)
        resliceFromDetection()
        if let suggested = suggestedFeels.first {
            feelName = suggested.name
            tempo = source.tempo ?? suggested.suggestedTempo
        }
        keptChop = version == nil ? nil : cut
    }

    /// Opens on the cut a version kept: its markers and the classes they record, rather than a
    /// fresh detection. Reopening a chop used to detect its slices again and treat that as kept,
    /// so a marker moved by hand or a slice called a snare was gone, and the next edit saved over
    /// the kept cut. Not an edit: the lane holds what the song holds.
    public func restore(_ kept: [SliceMarker], pads: [PadTrim] = []) {
        guard source.isWellFormed, !kept.isEmpty else { return }
        let restored = kept.map { $0.position - source.sourceOffset }
            .filter { $0 >= 0 && $0 < source.duration }
            .sorted()
        guard !restored.isEmpty else { return }
        markers = restored
        overrides = [:]
        edits = [:]
        selectedSlice = nil
        rebuildChop(exact: true)
        let carried = Self.carried(kept, pads: pads, onto: chop)
        overrides = carried.overrides
        edits = carried.edits
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
        handEdited = sliceMarkers.map(\.position) != detectedOnsets.map { $0 + source.sourceOffset }
        keptChop = cut
        needsAuditionRefresh = true
    }

    /// Kept markers cut again exactly where they were kept. The lane's own chopper backs each start
    /// up to a quiet frame and merges slices closer than 15 ms. That has already been done to a kept
    /// cut, and doing it again can merge two markers the backing-up brought closer, and drop a slice.
    public nonisolated static func recut(at positions: [Double], signal: [Float], sampleRate: Double,
                                         sourceOffset: Double, detectedTempo: Double?) -> Chop {
        Chopper(minimumSliceDuration: 0.001, includeLeadIn: false, zeroCrossingWindow: 0)
            .slice(atOnsets: positions, signal: signal, sampleRate: sampleRate,
                   sourceOffset: sourceOffset, detectedTempo: detectedTempo)
    }

    /// The classes and trims a kept cut recorded, put back on the slices that start where their
    /// markers are: by position, not by place in the list, so a slice lost or gained between the
    /// two moves nothing onto its neighbour. A trim's `slice` counts in `kept` as given.
    public nonisolated static func carried(_ kept: [SliceMarker], pads: [PadTrim],
                                           onto chop: Chop) -> (overrides: [Int: SliceClass], edits: [Int: SliceEdit]) {
        let classes = overrides(from: kept)
        let trims = Dictionary(pads.map { ($0.slice, $0) }, uniquingKeysWith: { first, _ in first })
        var outClasses: [Int: SliceClass] = [:]
        var outEdits: [Int: SliceEdit] = [:]
        for slice in chop.slices {
            let at = chop.sourceOffset + slice.startSeconds
            guard let nearest = kept.indices.min(by: { abs(kept[$0].position - at) < abs(kept[$1].position - at) }),
                  abs(kept[nearest].position - at) <= 0.005 else { continue }
            if let kind = classes[nearest] { outClasses[slice.index] = kind }
            if let pad = trims[nearest] {
                outEdits[slice.index] = SliceEdit(tuneCents: Float(pad.tuneCents), gainDB: Float(pad.gainDB),
                                                  reverse: pad.reverse, stretchRatio: pad.stretchRatio)
            }
        }
        return (outClasses, outEdits)
    }

    /// Point the lane at a host after the fact — the frame builds the surface, then adopts it.
    public func adopt(_ host: any ChopLaneHost) {
        self.host = host
        needsAuditionRefresh = true
    }

    // MARK: Slicing

    public var sliceCount: Int { chop.count }

    /// What turning the sensitivity dial would throw away, said before it is turned. Nil when
    /// nothing is at stake because the lane is exactly what the detector made of it.
    ///
    /// `resliceFromDetection` clears the pad overrides and trims along with the markers, so the
    /// warning has to name all three or it is a warning about the wrong thing.
    public var resliceWarning: String? {
        Self.resliceWarning(handEdited: handEdited, overrides: overrides.count, trims: edits.count)
    }

    /// The warning's wording, kept pure so it can be checked without a bar.
    public nonisolated static func resliceWarning(handEdited: Bool, overrides: Int,
                                                  trims: Int) -> String? {
        var lost: [String] = []
        if handEdited { lost.append("your marker edits") }
        if overrides > 0 { lost.append(overrides == 1 ? "1 pad override" : "\(overrides) pad overrides") }
        if trims > 0 { lost.append(trims == 1 ? "1 pad's trims" : "\(trims) pads' trims") }
        guard !lost.isEmpty else { return nil }
        let list = lost.count == 1
            ? lost[0]
            : lost.dropLast().joined(separator: ", ") + " and " + lost[lost.count - 1]
        return "Moving this re-slices the bar and drops \(list)."
    }

    /// Re-detect at the current sensitivity and re-slice from scratch.
    ///
    /// Hand edits do not survive this, and that is the honest behaviour: the markers were a
    /// function of the dial, and the dial moved. `resliceWarning` exists so the view can say so
    /// first.
    public func resliceFromDetection() {
        guard source.isWellFormed else { return }
        willEdit("sensitivity")
        defer { didEdit() }
        slicedAtSensitivity = min(1, max(0, sensitivity))
        var detector = SpectralFluxOnsetDetector()
        detector.threshold = onsetThreshold
        detectedOnsets = detector.onsets(in: source.mono, sampleRate: source.sampleRate)
        markers = detectedOnsets
        overrides = [:]
        edits = [:]
        handEdited = false
        selectedSlice = nil
        rebuildChop()
    }

    /// Rebuild the chop from the current markers, keeping the hand classifications and pad trims
    /// that still refer to a slice that exists.
    private func rebuildChop(exact: Bool = false) {
        if exact {
            chop = Self.recut(at: markers, signal: source.mono, sampleRate: source.sampleRate,
                              sourceOffset: source.sourceOffset, detectedTempo: source.tempo)
        } else {
            var chopper = Chopper()
            chopper.snapTolerance = snapTolerance
            chop = chopper.slice(atOnsets: markers, signal: source.mono, sampleRate: source.sampleRate,
                                 snappingTo: source.grid, division: gridDivision,
                                 sourceOffset: source.sourceOffset, detectedTempo: source.tempo)
        }
        let live = Set(chop.slices.map(\.index))
        overrides = overrides.filter { live.contains($0.key) }
        edits = edits.filter { live.contains($0.key) }
        if let selected = selectedSlice, !live.contains(selected) { selectedSlice = nil }
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
        headline = "\(source.label), \(chop.count) slice\(chop.count == 1 ? "" : "s")"
        needsAuditionRefresh = true
    }

    private nonisolated static func lines(of source: ChopLaneSource, division: Int) -> [Double] {
        guard let grid = source.grid else { return [] }
        return Chopper.gridLines(grid, division: division, from: source.sourceOffset,
                                 duration: source.duration)
    }

    // MARK: Snapping

    /// What a marker landed on, and what to tell the eye it landed on.
    public struct SnapTarget: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable, CaseIterable {
            case onset, grid
        }

        public var kind: Kind
        /// Seconds from frame 0 of the source.
        public var time: Double
        /// What the indicator says: "onset", or a grid position like "2e".
        public var label: String
    }

    /// A marker being dragged. The free position and the landed position are both kept, so the
    /// view can draw the marker where it will land *and* the pointer where it actually is — which
    /// is how a snap is made visible rather than merely felt.
    public struct MarkerDrag: Hashable, Sendable {
        public var sliceIndex: Int
        /// Where the pointer is, in seconds.
        public var free: Double
        /// Where the marker would land if you let go.
        public var time: Double
        /// What it caught on, nil when it is free between things.
        public var snapped: SnapTarget?

        public var isSnapped: Bool { snapped != nil }
    }

    public private(set) var drag: MarkerDrag?

    /// The nearest snap candidate within `snapTolerance` of `seconds`, or nil.
    ///
    /// Onsets are offered before grid lines at equal distance: a transient is where the record
    /// actually put a drum, and a grid line is only where the bar says one should be.
    public func snapTarget(near seconds: Double) -> SnapTarget? {
        var best: SnapTarget?
        var bestDistance = snapTolerance + 1e-12
        for onset in detectedOnsets {
            let distance = abs(onset - seconds)
            if distance < bestDistance {
                bestDistance = distance
                best = SnapTarget(kind: .onset, time: onset, label: "onset")
            }
        }
        for (index, line) in gridLines.enumerated() {
            let distance = abs(line - seconds)
            if distance < bestDistance {
                bestDistance = distance
                best = SnapTarget(kind: .grid, time: line, label: gridLabel(atLineIndex: index))
            }
        }
        return best
    }

    /// "2e" — beat and subdivision, counted from the first grid line in the buffer.
    ///
    /// The lane opens on a bar, so line 0 is a downbeat and counting from it is right. On a region
    /// that does not start on a beat the count is still consistent, just offset.
    func gridLabel(atLineIndex index: Int) -> String {
        let division = max(1, gridDivision)
        let beatsPerBar = max(1, source.grid?.timeSignature.beatsPerBar ?? 4)
        let beat = (index / division) % beatsPerBar + 1
        let names = ["", "e", "&", "a"]
        let part = index % division
        return part < names.count ? "\(beat)\(names[part])" : "\(beat)+\(part)"
    }

    // MARK: Dragging a marker

    public func beginDrag(slice index: Int) {
        guard chop.slices.indices.contains(index) else { return }
        selectedSlice = index
        let time = chop.slices[index].startSeconds
        drag = MarkerDrag(sliceIndex: index, free: time, time: time, snapped: nil)
    }

    /// Move the marker in flight. Clamped so a marker can never pass a neighbour or leave the bar.
    public func dragMarker(to seconds: Double) {
        guard var current = drag else { return }
        let free = clamp(seconds, forSlice: current.sliceIndex)
        let target = snapTarget(near: free)
        let landed = target.map { clamp($0.time, forSlice: current.sliceIndex) }
        // A snap that has to be clamped is not a snap: it did not land on the thing.
        let caught = landed.map { abs($0 - (target?.time ?? $0)) < 1e-9 } ?? false
        current.free = free
        current.time = caught ? (landed ?? free) : free
        current.snapped = caught ? target : nil
        drag = current
    }

    /// Let go. The marker moves, the chop is rebuilt, and the audition kit goes stale.
    public func endDrag() {
        guard let current = drag else { return }
        drag = nil
        guard markers.indices.contains(markerIndex(forSlice: current.sliceIndex) ?? -1),
              let markerIndex = markerIndex(forSlice: current.sliceIndex) else { return }
        guard abs(markers[markerIndex] - current.time) > 1e-9 else { return }
        willEdit("drag")
        markers[markerIndex] = current.time
        markers.sort()
        handEdited = true
        rebuildChop()
        didEdit()
    }

    public func cancelDrag() { drag = nil }

    /// Add a marker, cutting the slice it lands in.
    public func addMarker(at seconds: Double) {
        let time = snapTarget(near: seconds)?.time ?? seconds
        let minimum = Chopper().minimumSliceDuration
        guard time > minimum, time < source.duration - minimum else { return }
        guard !markers.contains(where: { abs($0 - time) < minimum }) else { return }
        willEdit("add")
        markers.append(time)
        markers.sort()
        handEdited = true
        rebuildChop()
        didEdit()
    }

    /// Remove a slice's marker; its audio joins the slice before it.
    public func removeMarker(slice index: Int) {
        guard let markerIndex = markerIndex(forSlice: index), markers.count > 1 else { return }
        willEdit("remove")
        markers.remove(at: markerIndex)
        handEdited = true
        rebuildChop()
        didEdit()
    }

    /// The marker that produced a slice. Not always `slice` itself: the chopper can insert a
    /// lead-in slice before the first marker, and can drop markers that fell too close together.
    func markerIndex(forSlice index: Int) -> Int? {
        guard chop.slices.indices.contains(index) else { return nil }
        let time = chop.slices[index].startSeconds - chop.slices[index].snapOffset
        return markers.enumerated()
            .min { abs($0.element - time) < abs($1.element - time) }
            .flatMap { abs($0.element - time) <= snapTolerance + 0.005 ? $0.offset : nil }
    }

    private func clamp(_ seconds: Double, forSlice index: Int) -> Double {
        let minimum = Chopper().minimumSliceDuration
        let lower = index > 0 ? chop.slices[index - 1].startSeconds + minimum : 0
        let upper = index + 1 < chop.count
            ? chop.slices[index + 1].startSeconds - minimum
            : source.duration - minimum
        return min(max(seconds, lower), max(lower, upper))
    }

    // MARK: Classification

    public func classification(forSlice index: Int) -> SliceClassification? {
        classifications.first { $0.sliceIndex == index }
    }

    /// Force a slice's class. Sticks through a re-groove and through a commit.
    public func override(slice index: Int, as kind: SliceClass) {
        guard chop.slices.indices.contains(index), overrides[index] != kind else { return }
        willEdit("override")
        overrides[index] = kind
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
        didEdit()
    }

    /// Give a slice back to the classifier.
    public func clearOverride(slice index: Int) {
        guard overrides[index] != nil else { return }
        willEdit("override")
        overrides.removeValue(forKey: index)
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
        didEdit()
    }

    // MARK: Per-slice controls

    /// What a pad does to its slice on the way out. Not part of the `Sample` payload — see
    /// `commitChop` — so this is render state, applied to the map the host plays and the map the
    /// re-groove is built from.
    public struct SliceEdit: Hashable, Sendable, Codable {
        /// Pitch offset in cents. -1200 is the octave down that makes a break sit lower without
        /// changing its rhythm.
        public var tuneCents: Float
        public var gainDB: Float
        public var reverse: Bool
        /// Output duration over input duration; nil plays the slice at its natural length.
        public var stretchRatio: Double?

        public init(tuneCents: Float = 0, gainDB: Float = 0, reverse: Bool = false,
                    stretchRatio: Double? = nil) {
            self.tuneCents = tuneCents
            self.gainDB = gainDB
            self.reverse = reverse
            self.stretchRatio = stretchRatio
        }

        public var isNeutral: Bool {
            tuneCents == 0 && gainDB == 0 && !reverse && stretchRatio == nil
        }
    }

    /// Cents a pad may be tuned by, either way: two octaves, which is as far as a chopped drum
    /// stays a drum.
    public nonisolated static let tuneRange: ClosedRange<Float> = -2400...2400
    public nonisolated static let gainRange: ClosedRange<Float> = -24...12
    /// The ratios `Regroove` will accept, so a pad cannot be set to something a re-groove rejects.
    public nonisolated static let stretchRange: ClosedRange<Double> = 0.25...4

    public func edit(forSlice index: Int) -> SliceEdit { edits[index] ?? SliceEdit() }

    /// The trims as the version holds them: one per pad that has any, in slice order.
    public var padTrims: [PadTrim] {
        edits.filter { !$0.value.isNeutral }.sorted { $0.key < $1.key }.map { slice, edit in
            PadTrim(slice: slice, tuneCents: Double(edit.tuneCents), gainDB: Double(edit.gainDB),
                    reverse: edit.reverse, stretchRatio: edit.stretchRatio)
        }
    }

    public func setTune(_ cents: Float, slice index: Int) {
        update(slice: index) { $0.tuneCents = min(Self.tuneRange.upperBound,
                                                  max(Self.tuneRange.lowerBound, cents)) }
    }

    public func setGain(_ dB: Float, slice index: Int) {
        update(slice: index) { $0.gainDB = min(Self.gainRange.upperBound,
                                               max(Self.gainRange.lowerBound, dB)) }
    }

    public func setReverse(_ reverse: Bool, slice index: Int) {
        update(slice: index) { $0.reverse = reverse }
    }

    public func setStretch(_ ratio: Double?, slice index: Int) {
        update(slice: index) {
            $0.stretchRatio = ratio.map {
                SliceStretch.rounded(min(Self.stretchRange.upperBound,
                                         max(Self.stretchRange.lowerBound, $0)))
            }
        }
    }

    public func resetSlice(_ index: Int) {
        guard edits[index] != nil else { return }
        willEdit("reset \(index)")
        edits.removeValue(forKey: index)
        needsAuditionRefresh = true
        didEdit()
    }

    private func update(slice index: Int, _ change: (inout SliceEdit) -> Void) {
        guard chop.slices.indices.contains(index) else { return }
        var edit = edits[index] ?? SliceEdit()
        change(&edit)
        guard edit != (edits[index] ?? SliceEdit()) else { return }
        willEdit("trim \(index)")
        if edit.isNeutral { edits.removeValue(forKey: index) } else { edits[index] = edit }
        needsAuditionRefresh = true
        didEdit()
    }

    // MARK: The map

    /// The slice-to-pad map: every slice on its own pad from C1 up, carrying its trims and named
    /// with the class the pad was called.
    ///
    /// This is what `Performance` is handed — `ChopMap.render`, `Regroove.perform` — so it is the
    /// surface's actual output, not a view model.
    public var chopMap: ChopMap {
        Self.map(of: chop, classifications: classifications, name: source.label, edits: edits)
    }

    /// The map for any chop, as the lane builds it. The song builds a groove-on-a-chop's pads with
    /// this too (`ChopGroove`), so the slice the lane called the kick is the one the song plays.
    public nonisolated static func map(of chop: Chop, classifications: [SliceClassification],
                                       name: String, edits: [Int: SliceEdit] = [:]) -> ChopMap {
        var map = ChopMap.pads(chop, name: name)
        for position in map.mappings.indices {
            let index = map.mappings[position].sliceIndex
            let edit = edits[index] ?? SliceEdit()
            map.mappings[position].tuneCents = edit.tuneCents
            map.mappings[position].gainDB = edit.gainDB
            map.mappings[position].reverse = edit.reverse
            map.mappings[position].stretchRatio = edit.stretchRatio
            let kind = classifications.first { $0.sliceIndex == index }?.kind
            map.mappings[position].label = kind.map { "slice \(index) (\($0.rawValue))" }
                ?? "slice \(index)"
        }
        // Name a voice for each class so a `Groove` can address this chop without knowing its
        // pad layout. The loudest slice of each class gets the name.
        for kind in SliceClass.allCases {
            let best = classifications.filter { $0.kind == kind }.max { $0.peak < $1.peak }
            guard let best, let note = map.note(forSlice: best.sliceIndex) else { continue }
            map.setVoice(Self.voice(for: kind), note: note)
        }
        return map
    }

    nonisolated static func voice(for kind: SliceClass) -> DrumVoice {
        switch kind {
        case .kick: return .kick
        case .snare: return .snare
        case .hat: return .closedHat
        }
    }

    // MARK: Playing on touch
    //
    // The surface's most important property. The kit is rendered and handed to the host whenever
    // an edit makes it stale, so the touch itself does nothing but post a hit. There is no agent
    // in this path and no round trip: `audition(slice:)` is engine-speed by construction.

    /// Render the current map and hand it to the host. Cheap when nothing is reversed or
    /// stretched — every pad is a window into the one buffer the host already has.
    public func refreshAudition() {
        guard let host else { return }
        do {
            try host.prepareAudition(chopMap.render(source: source.planar, stretch: stretch))
            needsAuditionRefresh = false
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    private func ensureAudition() {
        if needsAuditionRefresh { refreshAudition() }
    }

    /// Play one slice, now.
    public func audition(slice index: Int, velocity: Int = 120) {
        ensureAudition()
        selectedSlice = index
        guard let note = chopMap.note(forSlice: index) else { return }
        host?.audition([VoiceSampler.Hit(note: note, velocity: velocity, at: 0)])
    }

    /// Play the bar back as it was cut — every slice at its own position. The self-check: if this
    /// does not sound like the record, a marker is in the wrong place.
    public func auditionBar() {
        ensureAudition()
        host?.audition(chopMap.nativeHits())
    }

    public func stop() { host?.stopAudition() }

    // MARK: Re-groove

    /// The chop played in the chosen feel at the chosen tempo.
    ///
    /// The classification overrides go in twice on purpose: once as the labels on the
    /// classifications and once in the policy, because `Regroove` re-applies the policy's
    /// overrides itself and a disagreement between the two would be a silent bug.
    public func regroove() throws -> RegroovePerformance {
        guard let feel else { throw ChopLaneError.noFeel }
        let bars = max(1, repeats) * max(1, feel.bars) + 1
        let grid = BeatGrid.regular(bpm: tempo, timeSignature: feel.timeSignature, bars: bars)
        let policy = Regroove.Policy(overrides: overrides, overlap: overlap)
        return try Regroove(policy: policy).perform(chopMap, classifications: classifications,
                                                    groove: feel.groove, grid: grid,
                                                    startBar: 0, repeats: max(1, repeats))
    }

    /// Hear the chop in the chosen feel. The performance's own map is rendered, not the pad map:
    /// it carries the stretched variants the placements needed.
    public func playRegroove() {
        guard let host else { return }
        do {
            let performance = try regroove()
            try host.prepareAudition(performance.map.render(source: source.planar,
                                                            stretch: stretch))
            host.audition(performance.hits)
            // The host is now holding the re-groove's kit, so the pad map has to be re-sent
            // before a pad is touched again.
            needsAuditionRefresh = true
            playedRegroove = currentRegroove
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Committing
    //
    // An edit is not an edit until it is a version. Nothing here mutates a version, and the
    // surface's own marker list is only ever a proposal until one of these is called.

    /// Slice markers in the record's own time, with the class each slice was called.
    ///
    /// The label carries `<origin> <class>` — "snapped kick", "onset hat" — so a hand override
    /// survives the commit and comes back when the lane is reopened on this version.
    /// `SliceMarker.label` is free text in the schema, and this is the lane's convention for it.
    public var sliceMarkers: [SliceMarker] {
        chop.slices.map { slice in
            let kind = classification(forSlice: slice.index)?.kind
            let label = kind.map { "\(slice.origin.rawValue) \($0.rawValue)" }
                ?? slice.origin.rawValue
            return SliceMarker(position: chop.sourceOffset + slice.startSeconds, label: label)
        }
    }

    /// The classes a previous commit's markers recorded, for reopening a lane on a version.
    public nonisolated static func overrides(from markers: [SliceMarker]) -> [Int: SliceClass] {
        var out: [Int: SliceClass] = [:]
        for (index, marker) in markers.enumerated() {
            guard let label = marker.label else { continue }
            let parts = label.split(separator: " ")
            guard parts.count == 2, let kind = SliceClass(rawValue: String(parts[1])) else { continue }
            out[index] = kind
        }
        return out
    }

    /// The chop as a new `sample` part version.
    ///
    /// The pads' trims go with it (`padTrims`), so a groove played on this chop in the song
    /// sounds the pads the way the lane does.
    @discardableResult
    public func commitChop(note: String? = nil) throws -> PartVersion {
        guard let host else { throw ChopLaneError.noHost }
        // A re-cut keeps the chain the chop plays through: dust is a property of the chop's sound,
        // and moving a slice marker is not a request to clean it.
        var chain: [Degradation] = []
        var key: Key?
        var span: SongGraph.TimeRange?
        // Its level too: the lane is playing the bar at it.
        var gain: Double?
        if case .sample(let previous)? = parent?.kind { chain = previous.degradation; key = previous.key; span = previous.span; gain = previous.gainDB }
        let sample = Sample(media: source.media, slices: sliceMarkers,
                            detectedTempo: chop.detectedTempo, sourceRecord: source.record,
                            degradation: chain, key: key, span: span, pads: padTrims, gainDB: gain)
        let version = parent.map {
            $0.deriving(.sample(sample), by: .user, operation: Operation.chop, note: note)
        } ?? PartVersion(partID: partID, kind: .sample(sample), author: .user,
                         parents: versions, operation: Operation.chop, note: note)
        autoKeep.cancel()
        guard host.record(version) else { throw ChopLaneError.versionRefused }
        versions = [version.id]
        keptChop = cut
        return version
    }

    /// The re-groove as a new `groove` part, spawned from the chop it was played with.
    ///
    /// A new part rather than a new version of the sample: a groove is not a later draft of a
    /// chopped bar, it is a different thing the bar produced. The lineage still records which chop
    /// it came from.
    @discardableResult
    public func commitRegroove(note: String? = nil) throws -> PartVersion {
        guard let host else { throw ChopLaneError.noHost }
        guard let feel else { throw ChopLaneError.noFeel }
        // The feel and the bar it plays, not the lane's preview tempo: the song plays it at its own.
        let summary = note ?? "\(feel.name) on \(source.label)"
        let version = parent.map {
            $0.spawning(.groove(feel.groove), by: .user, operation: Operation.regroove,
                        note: summary)
        } ?? PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                         parents: versions, operation: Operation.regroove, note: summary)
        guard host.record(version) else { throw ChopLaneError.versionRefused }
        keptRegroove = currentRegroove
        // The song plays the groove on the chop as it holds it: `keepRegroove` keeps the cut first
        // so the two agree. A groove from a chop the song never kept has nothing to play on.
        if let chop = parent?.partID { host.madeGroove(version, fromChop: chop) }
        return version
    }

    /// The version this lane's next commit derives from: the part's newest in the song, so dust
    /// Sound put on the chop since the lane opened goes with the next cut rather than being lost.
    private var parent: PartVersion? {
        guard let id = versions.last, let known = host?.song?.version(id) else { return nil }
        return host?.song?.versions.last { $0.partID == known.partID } ?? known
    }

    // MARK: Keeping
    //
    // The two commits above throw, and a view has nowhere to put a throw. These are the verbs the
    // view presses: each one says beforehand whether it can be pressed and why not, and afterwards
    // routes whatever went wrong into `lastError`, where the footer already looks.

    /// True when the chop the lane would write differs from the one it last wrote: the markers,
    /// the class each slice was called, and the pads' trims.
    public var hasUnkeptChopEdits: Bool {
        guard sliceCount > 0 else { return false }
        guard let keptChop else { return true }
        return cut != keptChop
    }

    /// True when a re-groove has been heard that the ledger does not have.
    public var hasUnkeptRegroove: Bool {
        guard let playedRegroove else { return false }
        return playedRegroove != keptRegroove
    }

    /// True when closing this lane would lose something. A re-groove heard and not made is not
    /// in it: that is a thing tried, and making it is a decision with its own button.
    public var hasUnkeptChanges: Bool { hasUnkeptChopEdits }

    public var canKeepChop: Bool { whyChopCannotBeKept == nil }

    /// Why Keep chop is disabled, in words the button can show. Nil when it is not.
    public var whyChopCannotBeKept: String? {
        if sliceCount == 0 { return "There are no slices to keep." }
        if !hasUnkeptChopEdits { return "Nothing has changed since this bar was kept." }
        return nil
    }

    public var canKeepRegroove: Bool { whyRegrooveCannotBeKept == nil }

    /// Why Keep re-groove is disabled. Nil when it is not.
    ///
    /// What is kept is what was heard, so the current setting has to have been played. And a
    /// groove is spawned from the chop version it was played with, so an unkept chop goes first:
    /// otherwise the groove's lineage would name a cut that is not the one it came from.
    public var whyRegrooveCannotBeKept: String? {
        guard let current = currentRegroove else { return "Pick a feel first." }
        if current != playedRegroove {
            return "Play it in this feel first, so what is made is what was heard."
        }
        if current == keptRegroove { return "This groove is already made." }
        return nil
    }

    /// Keep the chop as a new version of this bar. The note is the bar's own label, which is what
    /// the lane will be titled by when it is reopened on the version.
    public func keepChop() {
        guard canKeepChop else {
            lastError = whyChopCannotBeKept
            return
        }
        do {
            try commitChop(note: source.label)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// Keep the re-groove as a new groove part. The host decides what happens next; the frame's
    /// adapter opens the Grid on it.
    public func keepRegroove() {
        guard canKeepRegroove else {
            lastError = whyRegrooveCannotBeKept
            return
        }
        // The chop first, so the groove's lineage names the cut it was played from. A bar promoted
        // and never cut holds no cut to play the groove on: the one the lane heard is kept, rather
        // than the song cutting the bar again its own way, without the record's grid to snap to.
        guard keepNow() else { return }
        if sliceCount > 1, case .sample(let kept)? = parent?.kind, kept.slices.count <= 1 {
            do { try commitChop() } catch { lastError = "\(error)"; return }
        }
        do {
            try commitRegroove()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Levers

    /// The catalog's rule, written down: at most two levers are prominent at once.
    public enum Lever: String, Hashable, Sendable, CaseIterable {
        case sensitivity, feel, tempo, slice
    }

    /// The two this surface spends its prominence on. Everything else is secondary.
    public nonisolated static let prominentLevers: [Lever] = [.sensitivity, .feel]
}

extension ChopLaneSurface: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        guard hasUnkeptChopEdits else { autoKeep.cancel(); return true }
        do {
            try commitChop(note: source.label)
            lastError = nil
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let previous = history.undo(from: state) else { return }
        lastEdit = nil
        apply(previous)
        didEdit()
    }

    public func redo() {
        guard let next = history.redo(from: state) else { return }
        lastEdit = nil
        apply(next)
        didEdit()
    }

    public var keepLine: KeepLine {
        if let lastError { return .refused(lastError) }
        if hasUnkeptChopEdits { return .pending }
        if keptChop != nil, let id = versions.last, let version = host?.song?.version(id) {
            return .kept(title: PartLabel.title(of: version))
        }
        return .untouched
    }
}
