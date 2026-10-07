import AVFAudio
import CVoiceRender
import Foundation
import MusicTheory
import SongGraph

/// The playable sampler: a kit on one `AVAudioSourceNode`, mixed by the C render core.
///
/// Swift owns everything the audio thread reads. `prepare(_:)` resolves every zone's samples
/// through the `SampleCache`, builds the flat zone table the core wants, and publishes it; from
/// then on the render thread only dereferences stable pointers. Events are pushed onto a
/// single-producer queue from the scheduling thread and consumed sample-accurately in `vr_render`.
///
/// ## Timelines
///
/// The core's event timeline **is the node's render timeline**: `vr_render` is handed the render
/// block's own `mSampleTime`, and an event's `frameTime` is `originFrame + round(t * sampleRate)`
/// where `originFrame` is the render sample time at transport zero (`Transport.originSampleTime`
/// in `AudioEngine`). Nothing mutable is therefore shared with the audio thread: the render block
/// reads one preallocated struct and calls into C. See `transportDidStart(originSampleTime:_:)`.
///
/// ## Lifetime contract, inherited from `SampleBuffer` and enforced here
///
/// This object retains both the cache's buffers and the channel-pointer tables for as long as the
/// core can still be reading them. Swapping kits retires the previous allocations onto a free list
/// that is drained — without blocking — once `vr_zones_epoch_in_use` catches up with the publish
/// that replaced them (`reclaim()`, also called at the start of every `prepare`).
///
/// `unprepare()` and `deinit` destroy the C engine and free the render context. **The node must be
/// detached from its `AVAudioEngine` (or the engine stopped) first**: the render block holds a raw
/// pointer to that context, and no handshake can make a callback that is already running safe.
/// Swapping kits, by contrast, is safe at any time, including while rendering.
///
/// ## Scheduling
///
/// `transportDidStart(originSampleTime:sampleRate:)`, `schedule(through:)` and `transportWillStop()`
/// have exactly the shape of `AudioEngine.ScheduledSource`. `Instrument` does not depend on
/// `AudioEngine`, so the conformance itself lives wherever both modules are visible:
///
/// ```swift
/// extension VoiceSampler: ScheduledSource {
///     public func transportDidStart(_ transport: Transport) {
///         transportDidStart(originSampleTime: Int64(transport.originSampleTime),
///                           sampleRate: transport.sampleRate)
///     }
/// }
/// ```
public final class VoiceSampler: @unchecked Sendable {

    // MARK: Types

    /// What the sampler is asked to play. Velocity is 0...127; the kit's curve maps it to gain.
    ///
    /// `duration` is the honest answer to "does a drum need a note-off?": no. A `nil` duration —
    /// the default, and the only thing the groove engine produces — is a one-shot. The voice runs
    /// to the end of its zone's playback window and frees itself, and the way to silence it early
    /// is a choke group, not a note-off. A non-nil duration is for sustaining, pitched or looped
    /// zones: it schedules a `VR_EVENT_NOTE_OFF` for the voice this hit starts, which runs the
    /// zone's release stage. `stop(_:at:)` does the same thing for a voice already sounding.
    public struct Hit: Hashable, Sendable {
        public var voice: DrumVoice?
        public var note: Int?
        public var velocity: Int
        /// Transport seconds.
        public var time: Double
        /// Seconds until the note-off, or nil for a one-shot.
        public var duration: Double?
        /// The player of a section that plays it (`Zone.layer`), counted from the top. Set when a
        /// section's kit deals a chord out (`KitEnsemble.dealt`); nil everywhere else.
        public var layer: Int?

        /// A drum hit addressed by voice name, the form the groove engine produces.
        public init(_ voice: DrumVoice, velocity: Int, at time: Double, duration: Double? = nil) {
            self.voice = voice; self.note = nil
            self.velocity = velocity; self.time = time; self.duration = duration
        }

        /// A hit addressed by MIDI note, the form a keyboard or a chopped pad map produces.
        public init(note: Int, velocity: Int, at time: Double, duration: Double? = nil, layer: Int? = nil) {
            self.voice = nil; self.note = note
            self.velocity = velocity; self.time = time; self.duration = duration
            self.layer = layer
        }
    }

    /// Identifies one sounding voice, so a specific hit can be stopped. Returned by `play`.
    public struct VoiceHandle: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: Int64
        public var description: String { "voice \(rawValue)" }
    }

    /// The output format, fixed by the first `prepare(_:)` because the C engine and the
    /// `AVAudioSourceNode` are both built for it.
    public struct Format: Hashable, Sendable, CustomStringConvertible {
        public var sampleRate: Double
        public var channels: Int
        public var description: String { "\(sampleRate) Hz / \(channels) ch" }
    }

    public enum SamplerError: Error, CustomStringConvertible {
        case notPrepared
        case engineUnavailable
        case eventQueueFull(pending: Int)
        case unmappedVoice(DrumVoice)
        case formatLocked(current: Format, requested: Format)

        public var description: String {
            switch self {
            case .notPrepared:
                "the sampler has no kit loaded; call prepare(_:) first"
            case .engineUnavailable:
                "the render core could not be created"
            case .eventQueueFull(let pending):
                "the render core's event queue is full (\(pending) events pending); schedule in smaller windows"
            case .unmappedVoice(let voice):
                "the loaded kit maps no zone for \(voice.rawValue)"
            case .formatLocked(let current, let requested):
                "this sampler renders at \(current); call unprepare() before preparing a kit at \(requested)"
            }
        }
    }

    /// Everything the render block touches, in one manually managed allocation so the audio thread
    /// never does ARC traffic, never allocates and never reads Swift state.
    private struct RenderContext {
        var engine: OpaquePointer?
        /// Preallocated `float *const *` handed straight to `vr_render`; filled from the
        /// `AudioBufferList` on every callback, never resized.
        var channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
        var channelCapacity: Int32
        var blockCount: Int64
        /// Render sample time of the first block, for tests that check the timeline mapping.
        var firstStartFrame: Int64
        var sawFirstBlock: Int32
    }

    /// Allocations a kit swap retired, held until the core confirms it is no longer reading them.
    private struct Retired {
        var epoch: Int64
        var zones: UnsafeMutableBufferPointer<vr_zone_t>?
        var tables: [UnsafeMutablePointer<UnsafePointer<Float>?>]
        var buffers: [SampleBuffer]

        func free() {
            zones?.deallocate()
            for table in tables { table.deallocate() }
        }
    }

    // MARK: State

    /// The node to attach to the engine graph. Nil until `prepare(_:)`.
    public private(set) var node: AVAudioSourceNode?
    public private(set) var kit: LoadedKit?
    /// Fixed by the first `prepare(_:)`; nil until then.
    public private(set) var format: Format?

    private let cache: SampleCache
    private let maxVoices: Int32
    private var engine: OpaquePointer?
    private var context: UnsafeMutablePointer<RenderContext>?

    /// Retained so the raw pointers in `zoneTable` stay valid. Order matches `zoneTable`.
    private var buffers: [SampleBuffer] = []
    /// Per-zone channel-pointer arrays, allocated once per prepare, retired on the next one.
    private var channelTables: [UnsafeMutablePointer<UnsafePointer<Float>?>] = []
    /// The zone table itself, in a manual allocation rather than a Swift `Array`: the core keeps
    /// the pointer across calls, and an `Array`'s buffer address is only guaranteed for the
    /// duration of `withUnsafeBufferPointer`. Retired and freed exactly like the channel tables.
    private var zoneStorage: UnsafeMutableBufferPointer<vr_zone_t>?
    private var retired: [Retired] = []
    /// Zone index by id, and the lookup order used to resolve a hit to a zone index.
    private var indexByZone: [ZoneID: Int32] = [:]
    /// Free-running per-note counters; `KitManifest.zone(note:velocity:roundRobin:)` wraps them.
    private var roundRobinCounters: [Int: Int] = [:]

    private var nextVoiceID: Int64 = 1

    /// Render sample time at transport zero. Only ever read on the scheduling thread.
    private var originFrame: Int64 = 0
    private var transportRunning = false
    private var scheduledThrough: Double = -.infinity
    /// Hits handed to `enqueue` that `schedule(through:)` has not reached yet, in time order.
    private var pending: [Hit] = []
    /// Built events waiting for their turn: the core consumes strictly FIFO in non-decreasing
    /// `frameTime` order, so a note-off cannot be pushed when it is built — later note-ons would
    /// queue behind it. Kept sorted by (frameTime, order) and drained up to a horizon.
    private var outbox: [(order: Int, event: vr_event_t)] = []
    private var outboxOrder = 0

    private var unmappedHits = 0
    private var queueFullEvents = 0
    private let lock = NSLock()

    // MARK: Init

    public init(cache: SampleCache, maxVoices: Int = 64) {
        self.cache = cache
        self.maxVoices = Int32(max(1, maxVoices))
    }

    /// Destroys the C engine. See the lifetime contract: the node must already be detached.
    deinit { teardownLocked() }

    // MARK: Preparing a kit

    /// Resolve a kit's samples, build the zone table, and create the node.
    ///
    /// Must be called off the audio thread. Safe to call again with a different kit **while the
    /// engine is rendering**: the new table is published atomically, and any voice still sounding
    /// an old zone is faded out by the core over `VR_DECLICK_MS` without reading the old sample
    /// memory again. The old allocations are retired, not freed, and `reclaim()` drops them once
    /// the core acknowledges the publish.
    ///
    /// The output format is fixed by the first call; a later call with a different one throws
    /// `SamplerError.formatLocked` rather than silently rendering at the wrong rate.
    public func prepare(_ kit: LoadedKit, sampleRate: Double = 48_000, channels: Int = 2) throws {
        lock.lock()
        defer { lock.unlock() }

        let requested = Format(sampleRate: sampleRate, channels: max(1, channels))
        if let format, format != requested {
            throw SamplerError.formatLocked(current: format, requested: requested)
        }

        // Decoding can throw; do it before anything is mutated so a failed prepare is a no-op.
        let buffersByZone = try cache.preload(kit, sampleRate: sampleRate)

        var newBuffers: [SampleBuffer] = []
        var newChannelTables: [UnsafeMutablePointer<UnsafePointer<Float>?>] = []
        var newTable: [vr_zone_t] = []
        var newIndex: [ZoneID: Int32] = [:]
        newBuffers.reserveCapacity(kit.manifest.zones.count)
        newTable.reserveCapacity(kit.manifest.zones.count)

        for zone in kit.manifest.zones {
            guard let buffer = buffersByZone[zone.id], buffer.frameCount > 0 else { continue }
            // One stable channel-pointer array per zone, owned by this object.
            let table = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: buffer.channelCount)
            for c in 0..<buffer.channelCount {
                table[c] = UnsafePointer(buffer.channel(c).baseAddress!)
            }
            newIndex[zone.id] = Int32(newTable.count)
            newTable.append(Self.cZone(zone, buffer: buffer, channels: table))
            newBuffers.append(buffer)
            newChannelTables.append(table)
        }

        if engine == nil {
            guard let created = vr_create(maxVoices, requested.sampleRate, Int32(requested.channels)) else {
                for table in newChannelTables { table.deallocate() }
                throw SamplerError.engineUnavailable
            }
            engine = created
            format = requested

            let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: requested.channels)
            planes.initialize(repeating: nil, count: requested.channels)
            let ctx = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
            ctx.initialize(to: RenderContext(engine: created, channels: planes,
                                             channelCapacity: Int32(requested.channels),
                                             blockCount: 0, firstStartFrame: 0, sawFirstBlock: 0))
            context = ctx
            node = Self.makeNode(context: ctx, format: requested)
        }

        // Drop anything a previous swap retired that the core has since moved past, then publish.
        reclaimLocked()
        let previousTables = channelTables
        let previousBuffers = buffers
        let previousZones = zoneStorage

        let storage = UnsafeMutableBufferPointer<vr_zone_t>.allocate(capacity: max(1, newTable.count))
        _ = storage.initialize(fromContentsOf: newTable)
        zoneStorage = storage
        vr_set_zones(engine, storage.baseAddress, Int32(newTable.count))

        if previousZones != nil || !previousTables.isEmpty || !previousBuffers.isEmpty {
            retired.append(Retired(epoch: vr_zones_epoch(engine), zones: previousZones,
                                   tables: previousTables, buffers: previousBuffers))
        }

        buffers = newBuffers
        channelTables = newChannelTables
        indexByZone = newIndex
        roundRobinCounters.removeAll()
        self.kit = kit
    }

    /// Free every retired allocation the core has confirmed it is no longer reading.
    ///
    /// Non-blocking by design: what cannot be freed yet stays on the list until the next call.
    /// `prepare(_:)` calls this, so a caller that never swaps kits never has to.
    public func reclaim() {
        lock.lock()
        defer { lock.unlock() }
        reclaimLocked()
    }

    /// Kit swaps whose previous allocations are still waiting for the core to acknowledge the
    /// publish that replaced them. Tests assert this reaches zero once rendering has moved on.
    public var retiredAllocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retired.count
    }

    /// Stop the voices and drop the kit, its buffers, the node and the C engine.
    ///
    /// The node must already be detached from its `AVAudioEngine`, or the engine stopped: this
    /// frees the memory the render block reads.
    public func unprepare() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        transportRunning = false
        pending.removeAll()
        outbox.removeAll()
        if let engine { vr_reset(engine) }
        // Force: the engine is about to go away, so nothing can still be reading these.
        for entry in retired { entry.free() }
        retired.removeAll()
        for table in channelTables { table.deallocate() }
        channelTables = []
        buffers = []
        zoneStorage?.deallocate()
        zoneStorage = nil
        indexByZone = [:]
        roundRobinCounters = [:]
        kit = nil
        node = nil
        if let ctx = context {
            ctx.pointee.engine = nil
            ctx.pointee.channels.deallocate()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            context = nil
        }
        if let engine { vr_destroy(engine) }
        engine = nil
        format = nil
    }

    /// The core frees nothing and never blocks the caller: it exposes an epoch handshake instead.
    /// Once `vr_zones_epoch_in_use` has reached the epoch a publish returned, no render can still
    /// be reading what that publish replaced, so the previous table and its buffers can go.
    private func reclaimLocked() {
        guard !retired.isEmpty else { return }
        guard let engine else {
            for entry in retired { entry.free() }
            retired.removeAll()
            return
        }
        let inUse = vr_zones_epoch_in_use(engine)
        var kept: [Retired] = []
        kept.reserveCapacity(retired.count)
        for entry in retired {
            if inUse >= entry.epoch {
                entry.free()
            } else {
                kept.append(entry)
            }
        }
        retired = kept
    }

    // MARK: Zone conversion

    /// One `Zone` as the flat struct the core reads.
    ///
    /// Units, checked against the header: `gain` is **linear** (`Zone.gain` converts from dB),
    /// `pan` is -1…+1 and the core applies the equal-power law, `velocity` on the event is the
    /// curve-mapped 0…1 value. `pitchRatio` here carries the zone's *tuning only*; per-note
    /// transposition is a separate per-voice parameter (see `resolve`), because a single zone
    /// entry is shared by every note in a `.range` placement.
    ///
    /// Not representable in the core and therefore dropped: `Envelope.delay` and `Envelope.hold`.
    private static func cZone(_ zone: Zone, buffer: SampleBuffer,
                              channels: UnsafeMutablePointer<UnsafePointer<Float>?>) -> vr_zone_t {
        let frames = buffer.frameCount
        let start = Int32(min(max(0, zone.sampleStart), frames))
        // `Zone.sampleEnd` is exclusive, as is the core's; nil means "to the end", which the core
        // spells as <= 0.
        let end = zone.sampleEnd.map { Int32(min(max(0, $0), frames)) } ?? 0

        // `Loop.end` is inclusive (SFZ); the core's `loopEnd` is exclusive. And a `no_loop` or
        // `one_shot` loop block describes points without asking for them to be played.
        let loop = zone.loop
        let looping = loop.map { $0.mode == .loopContinuous || $0.mode == .loopSustain } ?? false
        let loopStart = Int32(min(max(0, loop?.start ?? 0), frames))
        let loopEnd = Int32(min(max(0, (loop?.end ?? -1) + 1), frames))

        return vr_zone_t(
            channels: UnsafePointer(channels),
            frameCount: Int32(frames),
            channelCount: Int32(buffer.channelCount),
            sourceSampleRate: buffer.sampleRate,
            sampleStart: start,
            sampleEnd: end,
            gain: zone.gain,
            pan: zone.pan,
            pitchRatio: Float(pow(2.0, Double(zone.tuneCents) / 1200.0)),
            loopStart: loopStart,
            loopEnd: loopEnd,
            loopEnabled: looping && loopEnd - loopStart >= 2 ? 1 : 0,
            attack: zone.envelope.attack,
            decay: zone.envelope.decay,
            sustain: zone.envelope.sustain,
            release: zone.envelope.release,
            group: Int32(zone.group ?? 0),
            offBy: Int32(zone.offBy ?? 0),
            offMode: zone.offMode == .fast ? Int32(VR_OFF_MODE_FAST.rawValue) : Int32(VR_OFF_MODE_NORMAL.rawValue)
        )
    }

    // MARK: The node

    /// The render block. Allocation-free and ARC-free: it fills a preallocated plane array from
    /// the `AudioBufferList` and calls straight into C on the node's own render timeline.
    private static func makeNode(context ctx: UnsafeMutablePointer<RenderContext>,
                                 format: Format) -> AVAudioSourceNode {
        let avFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                     channels: AVAudioChannelCount(format.channels))!
        return AVAudioSourceNode(format: avFormat) { _, timestamp, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let planes = min(Int32(abl.count), ctx.pointee.channelCapacity)
            if planes <= 0 { return noErr }
            let out = ctx.pointee.channels
            for c in 0..<Int(planes) {
                out[c] = abl[c].mData?.assumingMemoryBound(to: Float.self)
            }
            let startFrame = Int64(timestamp.pointee.mSampleTime)
            if ctx.pointee.sawFirstBlock == 0 {
                ctx.pointee.sawFirstBlock = 1
                ctx.pointee.firstStartFrame = startFrame
            }
            ctx.pointee.blockCount &+= 1
            vr_render(ctx.pointee.engine, UnsafePointer(out), planes, Int32(frameCount), startFrame)
            return noErr
        }
    }

    // MARK: Transport

    /// Called once when the transport starts. `originSampleTime` is the node's render sample time
    /// at transport zero — `Transport.originSampleTime` in `AudioEngine`, which offline is
    /// `avEngine.manualRenderingSampleTime` and in realtime is the extrapolated render anchor.
    ///
    /// Resets everything that must not leak between runs: the look-ahead cursor, the queued hits,
    /// and the round-robin counters — without which two renders of the same part would differ.
    public func transportDidStart(originSampleTime: Int64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        originFrame = originSampleTime
        transportRunning = true
        scheduledThrough = -.infinity
        // `pending` is musical content, not scheduling state: hits enqueued before the transport
        // started are exactly the normal case (load a part, then press play), so they are kept and
        // re-scheduled against the new origin. Only the staged events are dropped, because they
        // carry frame times computed from the *previous* origin.
        outbox.removeAll()
        outboxOrder = 0
        roundRobinCounters.removeAll()
        unmappedHits = 0
        queueFullEvents = 0
        // Transport seconds are converted with the *engine's* rate, because that is the rate the
        // render timeline actually advances at. A transport running at another rate is a graph
        // misconfiguration (it would put every hit on the wrong frame), so it is surfaced rather
        // than silently absorbed.
        transportSampleRateMismatch = format.map { $0.sampleRate != sampleRate } ?? false
    }

    /// True when the last `transportDidStart` reported a sample rate other than the one this
    /// sampler was prepared for — the graph is misconfigured and every hit will land early or late.
    public private(set) var transportSampleRateMismatch = false

    /// Schedule every queued hit with transport time `< seconds` that has not been handed to the
    /// core yet. Monotonic and idempotent: a hit is pushed exactly once, and a hit enqueued after
    /// its time has passed is pushed on the next call with a `frameTime` in the past, which the
    /// core applies at the first frame of the current block rather than dropping.
    public func schedule(through seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard transportRunning, engine != nil, kit != nil else { return }
        scheduledThrough = max(scheduledThrough, seconds)

        var count = 0
        while count < pending.count, pending[count].time < seconds { count += 1 }
        if count > 0 {
            let due = Array(pending[0..<count])
            pending.removeFirst(count)
            // Never throws here: `throwingOnUnmapped` is off, so an unmapped hit is counted
            // (`unmappedHitCount`) rather than reported — `schedule(through:)` cannot throw.
            _ = try? buildLocked(due)
        }
        drainLocked(upTo: frame(forSeconds: seconds))
    }

    /// Called before the transport stops: silence the voices and forget what was queued. Unlike
    /// `transportDidStart`, this does clear `pending` — stopping means abandoning the run.
    public func transportWillStop() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        outbox.removeAll()
        transportRunning = false
        scheduledThrough = -.infinity
        guard let engine else { return }
        var event = vr_event_t()
        event.type = Int32(VR_EVENT_ALL_NOTES_OFF.rawValue)
        event.zoneIndex = -1
        event.frameTime = 0  // "as soon as possible"
        _ = vr_push_event(engine, &event)
    }

    /// Queue hits for the transport to hand to the core as the look-ahead reaches them. Times are
    /// transport seconds and may arrive in any order; they are kept sorted here.
    public func enqueue(_ hits: [Hit]) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: dealtLocked(hits))
        pending.sort { $0.time < $1.time }
    }

    /// `hits` as the kit plays them: a section's deals what is struck together out to its players
    /// (`KitEnsemble.dealt`); any other kit plays them as they are. Called with the lock held.
    private func dealtLocked(_ hits: [Hit]) -> [Hit] {
        guard let ensemble = kit?.manifest.ensemble else { return hits }
        return ensemble.dealt(hits)
    }

    // MARK: Playing

    /// Hand hits to the core immediately, bypassing the look-ahead. Times are transport seconds.
    ///
    /// Hits must be pushed in non-decreasing time order across calls: the core consumes its queue
    /// strictly FIFO, so an event queued for a later frame holds back everything behind it.
    ///
    /// - Returns: a handle per hit, in the order given, for `stop(_:at:)`. A section plays a note on
    ///   each of its players, and hands back a handle for each.
    @discardableResult
    public func play(_ hits: [Hit]) throws -> [VoiceHandle] {
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil, kit != nil else { throw SamplerError.notPrepared }
        let handles = try buildLocked(dealtLocked(hits), throwingOnUnmapped: true)
        drainLocked(upTo: nil)
        if queueFullEvents > 0 {
            let pending = queueFullEvents
            queueFullEvents = 0
            throw SamplerError.eventQueueFull(pending: pending)
        }
        return handles
    }

    @discardableResult
    public func play(_ hit: Hit) throws -> VoiceHandle? { try play([hit]).first }

    /// Release one sounding voice at `time` (transport seconds), running its zone's release stage.
    /// Harmless if the voice has already finished.
    public func stop(_ handle: VoiceHandle, at time: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil else { return }
        var event = vr_event_t()
        event.frameTime = frame(forSeconds: time)
        event.voiceId = handle.rawValue
        event.type = Int32(VR_EVENT_NOTE_OFF.rawValue)
        event.zoneIndex = -1
        append(event)
        drainLocked(upTo: nil)
    }

    /// Release every sounding voice with its zone's release stage.
    public func allNotesOff(at time: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil else { return }
        var event = vr_event_t()
        event.frameTime = frame(forSeconds: time)
        event.type = Int32(VR_EVENT_ALL_NOTES_OFF.rawValue)
        event.zoneIndex = -1
        append(event)
        drainLocked(upTo: nil)
    }

    /// Engine-wide linear gain applied to the sum of all voices.
    public func setMasterGain(_ gain: Float, at time: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil else { return }
        var event = vr_event_t()
        event.frameTime = frame(forSeconds: time)
        event.type = Int32(VR_EVENT_PARAMETER_CHANGE.rawValue)
        event.zoneIndex = -1
        event.paramId = Int32(VR_PARAM_MASTER_GAIN.rawValue)
        event.value = gain
        append(event)
        drainLocked(upTo: nil)
    }

    // MARK: Event construction

    private func frame(forSeconds seconds: Double) -> Int64 {
        guard let format else { return 0 }
        return originFrame + Int64((seconds * format.sampleRate).rounded())
    }

    /// Turn hits into events. One note-on, plus a `VR_EVENT_PARAMETER_CHANGE` on the same frame
    /// when the note is transposed — the core reads `paramId`/`value` **only** for a parameter
    /// change, so a note-on cannot carry a pitch ratio. The pair is ordered note-on first (it is
    /// what creates the voice the parameter targets) and both land before any audio is produced
    /// for that frame, because `vr_render` drains every event due at or before a frame before
    /// rendering it.
    @discardableResult
    private func buildLocked(_ hits: [Hit], throwingOnUnmapped: Bool = false) throws -> [VoiceHandle] {
        guard let kit else { return [] }
        var handles: [VoiceHandle] = []
        handles.reserveCapacity(hits.count)

        for hit in hits.sorted(by: { $0.time < $1.time }) {
            guard hit.velocity > 0 else { continue }  // MIDI velocity 0 is a note-off, not a hit
            guard let resolved = resolve(hit, in: kit) else {
                unmappedHits += 1
                if throwingOnUnmapped, let voice = hit.voice { throw SamplerError.unmappedVoice(voice) }
                continue
            }
            let voiceID = nextVoiceID
            nextVoiceID += 1
            let onFrame = frame(forSeconds: hit.time)

            var on = vr_event_t()
            on.frameTime = onFrame
            on.voiceId = voiceID
            on.type = Int32(VR_EVENT_NOTE_ON.rawValue)
            on.zoneIndex = resolved.index
            on.velocity = kit.manifest.velocityCurve.gain(forVelocity: hit.velocity)
            append(on)

            if resolved.ratio != 1 {
                var pitch = vr_event_t()
                pitch.frameTime = onFrame
                pitch.voiceId = voiceID
                pitch.type = Int32(VR_EVENT_PARAMETER_CHANGE.rawValue)
                pitch.zoneIndex = -1
                pitch.paramId = Int32(VR_PARAM_VOICE_PITCH_RATIO.rawValue)
                pitch.value = resolved.ratio
                append(pitch)
            }

            if let duration = hit.duration, duration > 0 {
                var off = vr_event_t()
                off.frameTime = frame(forSeconds: hit.time + duration)
                off.voiceId = voiceID
                off.type = Int32(VR_EVENT_NOTE_OFF.rawValue)
                off.zoneIndex = -1
                append(off)
            }
            handles.append(VoiceHandle(rawValue: voiceID))
        }
        return handles
    }

    private func append(_ event: vr_event_t) {
        outbox.append((order: outboxOrder, event: event))
        outboxOrder += 1
    }

    /// Push every buffered event up to `horizon` (nil = all of them) in non-decreasing `frameTime`
    /// order, which is what the core's strictly-FIFO queue requires. The sort is by
    /// (frameTime, insertion order), so a note-on and the parameter change that belongs to it stay
    /// adjacent and in that order.
    private func drainLocked(upTo horizon: Int64?) {
        guard let engine, !outbox.isEmpty else { return }
        outbox.sort { $0.event.frameTime != $1.event.frameTime
            ? $0.event.frameTime < $1.event.frameTime
            : $0.order < $1.order }
        var pushed = 0
        for entry in outbox {
            if let horizon, entry.event.frameTime > horizon { break }
            var event = entry.event
            if vr_push_event(engine, &event) != 0 { queueFullEvents += 1 }
            pushed += 1
        }
        if pushed > 0 { outbox.removeFirst(pushed) }
    }

    /// Resolve a hit to a zone index and a per-note pitch ratio, advancing the round robin.
    ///
    /// Round robin is keyed by the **resolved MIDI note**, whether the hit named a drum voice or a
    /// note, so the two addressing forms share one counter for the same drum instead of walking
    /// two independent sequences. The counters are reset by `prepare(_:)` and by
    /// `transportDidStart`, which is what makes two renders of the same part identical.
    private func resolve(_ hit: Hit, in kit: LoadedKit) -> (index: Int32, ratio: Float)? {
        let note: Int
        if let explicit = hit.note {
            note = explicit
        } else if let voice = hit.voice, let mapped = kit.manifest.note(for: voice) {
            note = mapped
        } else {
            return nil
        }
        // Each player of a section keeps its own count, as each keeps its own recordings.
        let counted = note + 128 * (hit.layer ?? 0)
        let counter = roundRobinCounters[counted, default: 0]
        guard let zone = kit.manifest.zone(note: note, velocity: hit.velocity, roundRobin: counter,
                                           layer: hit.layer, length: hit.duration),
              let index = indexByZone[zone.id] else { return nil }
        roundRobinCounters[counted] = counter + 1
        // Tuning is already baked into the zone's `pitchRatio`; this is the key transposition only,
        // which is 0 for a `.note` (drum) placement and `note - rootNote` for a `.range` one.
        let semitones = zone.key.transposition(forNote: note)
        return (index, semitones == 0 ? 1 : Float(pow(2.0, Double(semitones) / 12.0)))
    }

    // MARK: Diagnostics

    public var activeVoiceCount: Int { engine.map { Int(vr_active_voices($0)) } ?? 0 }
    public var droppedEventCount: Int { engine.map { Int(vr_dropped_events($0)) } ?? 0 }
    public var stolenVoiceCount: Int { engine.map { Int(vr_stolen_voices($0)) } ?? 0 }
    public var hardCutCount: Int { engine.map { Int(vr_hard_cuts($0)) } ?? 0 }
    public var declickFrames: Int { engine.map { Int(vr_declick_frames($0)) } ?? 0 }
    public var zoneCount: Int { zoneStorage?.count ?? 0 }
    /// Hits whose kit maps no zone, since the transport started.
    public var unmappedHitCount: Int { lock.lock(); defer { lock.unlock() }; return unmappedHits }
    /// Hits queued by `enqueue` that `schedule(through:)` has not reached yet.
    public var pendingHitCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    /// Events built but not yet pushed, because their frame is beyond the scheduling horizon.
    public var bufferedEventCount: Int { lock.lock(); defer { lock.unlock() }; return outbox.count }
    /// Render blocks the node has produced. A diagnostic, read without synchronisation: it is a
    /// snapshot of a value the audio thread writes, exactly like the core's own counters.
    public var renderedBlockCount: Int { context.map { Int($0.pointee.blockCount) } ?? 0 }
    /// Render sample time of the node's first block, for checking the transport mapping offline.
    public var firstRenderStartFrame: Int64? {
        guard let context, context.pointee.sawFirstBlock != 0 else { return nil }
        return context.pointee.firstStartFrame
    }
}
