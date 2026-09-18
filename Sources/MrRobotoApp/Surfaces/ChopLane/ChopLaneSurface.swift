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
/// rendered kit, the stretch cache) and the in-flight drag — none of which is an edit until it is
/// committed.
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

    /// Which pad the eye is on. Auditioning one selects it.
    public var selectedSlice: Int?

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
    }

    /// Point the lane at a host after the fact — the frame builds the surface, then adopts it.
    public func adopt(_ host: any ChopLaneHost) {
        self.host = host
        needsAuditionRefresh = true
    }

    // MARK: Slicing

    public var sliceCount: Int { chop.count }

    /// Re-detect at the current sensitivity and re-slice from scratch.
    ///
    /// Hand edits do not survive this, and that is the honest behaviour: the markers were a
    /// function of the dial, and the dial moved. `handEdited` exists so the view can say so first.
    public func resliceFromDetection() {
        guard source.isWellFormed else { return }
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
    private func rebuildChop() {
        var chopper = Chopper()
        chopper.snapTolerance = snapTolerance
        chop = chopper.slice(atOnsets: markers, signal: source.mono, sampleRate: source.sampleRate,
                             snappingTo: source.grid, division: gridDivision,
                             sourceOffset: source.sourceOffset, detectedTempo: source.tempo)
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
        markers[markerIndex] = current.time
        markers.sort()
        handEdited = true
        rebuildChop()
    }

    public func cancelDrag() { drag = nil }

    /// Add a marker, cutting the slice it lands in.
    public func addMarker(at seconds: Double) {
        let time = snapTarget(near: seconds)?.time ?? seconds
        let minimum = Chopper().minimumSliceDuration
        guard time > minimum, time < source.duration - minimum else { return }
        guard !markers.contains(where: { abs($0 - time) < minimum }) else { return }
        markers.append(time)
        markers.sort()
        handEdited = true
        rebuildChop()
    }

    /// Remove a slice's marker; its audio joins the slice before it.
    public func removeMarker(slice index: Int) {
        guard let markerIndex = markerIndex(forSlice: index), markers.count > 1 else { return }
        markers.remove(at: markerIndex)
        handEdited = true
        rebuildChop()
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
        guard chop.slices.indices.contains(index) else { return }
        overrides[index] = kind
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
    }

    /// Give a slice back to the classifier.
    public func clearOverride(slice index: Int) {
        guard overrides.removeValue(forKey: index) != nil else { return }
        classifications = SliceClassifier().classify(chop, in: source.mono, overrides: overrides)
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
        guard edits.removeValue(forKey: index) != nil else { return }
        needsAuditionRefresh = true
    }

    private func update(slice index: Int, _ change: (inout SliceEdit) -> Void) {
        guard chop.slices.indices.contains(index) else { return }
        var edit = edits[index] ?? SliceEdit()
        change(&edit)
        if edit.isNeutral { edits.removeValue(forKey: index) } else { edits[index] = edit }
        needsAuditionRefresh = true
    }

    // MARK: The map

    /// The slice-to-pad map: every slice on its own pad from C1 up, carrying its trims and named
    /// with the class the pad was called.
    ///
    /// This is what `Performance` is handed — `ChopMap.render`, `Regroove.perform` — so it is the
    /// surface's actual output, not a view model.
    public var chopMap: ChopMap {
        var map = ChopMap.pads(chop, name: source.label)
        for position in map.mappings.indices {
            let index = map.mappings[position].sliceIndex
            let edit = edits[index] ?? SliceEdit()
            map.mappings[position].tuneCents = edit.tuneCents
            map.mappings[position].gainDB = edit.gainDB
            map.mappings[position].reverse = edit.reverse
            map.mappings[position].stretchRatio = edit.stretchRatio
            let kind = classification(forSlice: index)?.kind
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
    /// The per-pad trims are **not** in this payload: `Sample` models markers, and a pad's tuning,
    /// gain, reverse and stretch belong to a rendered kit rather than to the sample the kit was
    /// cut from. They reach the graph when a chop is bounced into a kit, which Gate A does not do.
    @discardableResult
    public func commitChop(note: String? = nil) throws -> PartVersion {
        guard let host else { throw ChopLaneError.noHost }
        // A re-cut keeps the chain the chop plays through: dust is a property of the chop's sound,
        // and moving a slice marker is not a request to clean it.
        var chain: [Degradation] = []
        var key: Key?
        var span: SongGraph.TimeRange?
        if case .sample(let previous)? = parent?.kind { chain = previous.degradation; key = previous.key; span = previous.span }
        let sample = Sample(media: source.media, slices: sliceMarkers,
                            detectedTempo: chop.detectedTempo, sourceRecord: source.record,
                            degradation: chain, key: key, span: span)
        let version = parent.map {
            $0.deriving(.sample(sample), by: .user, operation: Operation.chop, note: note)
        } ?? PartVersion(partID: partID, kind: .sample(sample), author: .user,
                         parents: versions, operation: Operation.chop, note: note)
        guard host.record(version) else { throw ChopLaneError.versionRefused }
        versions = [version.id]
        handEdited = false
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
        let summary = note ?? "\(feel.name) at \(Int(tempo.rounded())) bpm"
        let version = parent.map {
            $0.spawning(.groove(feel.groove), by: .user, operation: Operation.regroove,
                        note: summary)
        } ?? PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                         parents: versions, operation: Operation.regroove, note: summary)
        guard host.record(version) else { throw ChopLaneError.versionRefused }
        return version
    }

    /// The version this lane's next commit derives from, when the host's song still has it.
    private var parent: PartVersion? {
        guard let id = versions.last else { return nil }
        return host?.song?.version(id)
    }

    // MARK: Levers

    /// The catalog's rule, written down: at most two levers are prominent at once.
    public enum Lever: String, Hashable, Sendable, CaseIterable {
        case sensitivity, feel, tempo, slice
    }

    /// The two this surface spends its prominence on. Everything else is secondary.
    public nonisolated static let prominentLevers: [Lever] = [.sensitivity, .feel]
}
