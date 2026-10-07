import AVFAudio
import AudioToolbox
import Foundation
import SongGraph

// M6 X2: the strips in the engine.
//
// Every source the transport adds is routed through its part's strip — an insert (an amp, a
// rotating speaker, or nothing), an EQ unit, a dynamics unit and a mixer node for level and pan —
// into the main mixer; each strip also feeds a send mixer into one reverb bus and another into
// one echo. The master chain is the main mixer, a peak limiter, and a trim that sets the ceiling.
// The same graph live and offline, so a bounce through the mix is the mix.
//
// The units are Apple's (AVAudioUnitEQ, the DynamicsProcessor, the PeakLimiter, AVAudioUnitReverb):
// deterministic enough for a rough mix, licence-free, and they render in manual mode. Two honest
// mappings: the compressor's `ratio` sets the dynamics unit's head room (it has no ratio), and the
// limiter clamps at 0 dBFS, so the ceiling is a trim after it with 0.3 dB of head room for the
// inter-sample peaks a limited signal still carries.

/// The nodes of one strip, in signal order. Not actor-isolated: the meter tap writes from the
/// render thread, under a lock. A strip with no part sits silent in the pool.
public final class MixStripNodes: @unchecked Sendable {
    /// The part holding this slot; nil while free.
    public fileprivate(set) var part: PartID?
    /// Where a part's sources come in: a mixer, so a part heard from two nodes at once — a
    /// sampler for its clean sections and a player for its dusty ones — has both. The EQ has one
    /// input bus, and connecting a second node to it silently replaced the first.
    public let input: AVAudioMixerNode
    /// The amp or the rotating speaker, before the EQ; set to nothing on most strips.
    public let insert: AVAudioUnitEffect
    public let eq: AVAudioUnitEQ
    public let dynamics: AVAudioUnitEffect
    public let out: AVAudioMixerNode
    public let send: AVAudioMixerNode
    /// The send to the echo.
    public let echo: AVAudioMixerNode
    private var peakValue: Float = 0
    private var rmsValue: Float = 0
    /// Whether the meter tap is installed. A tap is per-node and installing a second one on the
    /// same bus replaces the first, so this is bookkeeping rather than protection — but it keeps
    /// `removeTap` from being called on a node that never had one.
    fileprivate var isMetered = false
    let lock = NSLock()

    init() {
        input = AVAudioMixerNode()
        insert = StripInsertUnit.makeNode()
        eq = AVAudioUnitEQ(numberOfBands: 3)
        dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        out = AVAudioMixerNode()
        send = AVAudioMixerNode()
        echo = AVAudioMixerNode()
    }

    /// The insert's unit, to set.
    var insertUnit: StripInsertUnit? { insert.auAudioUnit as? StripInsertUnit }

    /// The last buffer's peak and RMS at the strip's output, 0…1.
    public var meter: (peak: Float, rms: Float) { lock.withLock { (peakValue, rmsValue) } }

    func meter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak: Float = 0, energy: Float = 0
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for channel in 0..<channels {
            for i in 0..<n {
                let v = data[channel][i]
                peak = max(peak, abs(v))
                energy += v * v
            }
        }
        lock.withLock {
            peakValue = peak
            rmsValue = sqrt(energy / Float(n * channels))
        }
    }
}

@AudioActor
public final class MixGraph {

    public typealias StripNodes = MixStripNodes

    /// How many strips the graph wires at build time.
    ///
    /// AVAudioEngine will not make a fan-out connection (a strip's output to the main mixer *and*
    /// its send) once it runs, so the strips are a pool, wired while the engine is quiet, and parts
    /// take slots as they are routed. **Do not make the pool grow on demand**: growing it means
    /// stopping the engine in the middle of a song, which is the one thing this shape exists to
    /// avoid.
    ///
    /// Sixteen rather than eight because a section may now play several parts of a kind — two
    /// grooves, a pad and a lead — and eight was already tight for a groove, a bass, a chop and
    /// four stems. Twenty-four rather than sixteen because a song can now take stems from any
    /// number of records: three records' stems and the parts written over them came to sixteen,
    /// and the seventeenth played unmixed. An unclaimed slot costs four silent nodes and, since
    /// the meter tap moved to `strip(for:)`, nothing at all on the render thread.
    public nonisolated static let slotCount = 24

    public let engine: Engine
    /// The pool, in slot order.
    private var slots: [MixStripNodes] = []
    /// Which slot each routed part holds.
    public private(set) var strips: [PartID: MixStripNodes] = [:]
    /// Parts the pool could not seat.
    ///
    /// They still play — `route` falls through to the main mixer, as it always has — but unmixed,
    /// unmetered and un-soloable. That used to happen in silence: a song with more parts than
    /// slots simply had faders that did nothing, and nothing anywhere said which. Read this after
    /// `reserve(_:)`; the frame says so on the rail and the Mixer draws those rows as what they
    /// are. Cleared by `releaseSlots()`.
    public private(set) var unseated: [PartID] = []
    public let trim: AVAudioMixerNode
    public let bus: AVAudioMixerNode
    public let reverb: AVAudioUnitReverb
    /// The echo's return: every strip's echo send into one tempo-synced delay.
    public let echoBus: AVAudioMixerNode
    public let delay: AVAudioUnitDelay
    /// The song's tempo, which the echo's time is counted in. Set before a mix is applied.
    public var tempo: Double = 120 {
        didSet { if tempo != oldValue { applyEcho(mix.echoSettings) } }
    }
    /// What each part's instrument brings to its strip when the mix sets nothing: an organ's
    /// rotating speaker. Set by whoever routes the parts, before the mix is applied.
    public var instrumentInserts: [PartID: StripInsert] = [:]
    /// Where every routed node went, so it can be put back.
    private var routed: [ObjectIdentifier: (node: AVAudioNode, part: PartID)] = [:]
    /// The mix as last applied.
    public private(set) var mix: Mix = .unity
    public private(set) var section: SectionID?

    /// Builds the master trim, the bus and the pool on an engine. Must run before the engine does.
    public init(engine: Engine) throws {
        self.engine = engine
        let av = engine.avEngine
        trim = AVAudioMixerNode()
        bus = AVAudioMixerNode()
        reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 100
        echoBus = AVAudioMixerNode()
        delay = AVAudioUnitDelay()
        delay.wetDryMix = 100
        for node in [trim, bus, reverb, echoBus, delay] as [AVAudioNode] { av.attach(node) }
        // Master: main mixer → trim → output. No limiter here — a lookahead limiter has latency,
        // and the transport is sample-exact; the ceiling is `Limiter` over a bounce or an export.
        av.disconnectNodeOutput(engine.mainMixer)
        try av.connectNode(engine.mainMixer, to: trim, format: engine.format)
        try av.connectNode(trim, to: av.outputNode, format: engine.format)
        // The bus: sends → bus mixer → reverb → main mixer.
        try av.connectNode(bus, to: reverb, format: engine.format)
        try av.connectNode(reverb, to: engine.mainMixer, format: engine.format)
        // The echo: echo sends → echo bus → delay → main mixer.
        try av.connectNode(echoBus, to: delay, format: engine.format)
        try av.connectNode(delay, to: engine.mainMixer, format: engine.format)
        // The pool.
        for _ in 0..<Self.slotCount {
            let strip = MixStripNodes()
            for node in [strip.input, strip.insert, strip.eq, strip.dynamics, strip.out, strip.send, strip.echo] as [AVAudioNode] {
                av.attach(node)
            }
            try av.connectNode(strip.input, to: strip.insert, format: engine.format)
            try av.connectNode(strip.insert, to: strip.eq, format: engine.format)
            try av.connectNode(strip.eq, to: strip.dynamics, format: engine.format)
            try av.connectNode(strip.dynamics, to: strip.out, format: engine.format)
            av.connect(strip.out, to: [AVAudioConnectionPoint(node: engine.mainMixer, bus: engine.mainMixer.nextAvailableInputBus),
                                       AVAudioConnectionPoint(node: strip.send, bus: 0),
                                       AVAudioConnectionPoint(node: strip.echo, bus: 0)],
                       fromBus: 0, format: engine.format)
            try av.connectNode(strip.send, to: bus, format: engine.format)
            try av.connectNode(strip.echo, to: echoBus, format: engine.format)
            // The meter tap is *not* installed here. `MixStripNodes.meter` is a per-sample loop over
            // every frame of every channel, and it runs on the render thread — so a pool of strips
            // metered at build time runs that loop for every slot, for every block, forever,
            // including the slots no part ever claims. It is installed when a part takes the slot
            // and removed when the slot is given back (`strip(for:)`, `releaseSlots()`). Taps may be
            // changed while the engine runs; connections, as above, may not, which is why the
            // strips are still a pool.
            apply(Strip(part: PartID(), label: ""), to: strip)
            slots.append(strip)
        }
        applyMaster(mix.master)
        applyReturns(mix)
    }

    // MARK: Strips

    /// The strip for a part: its slot, or the next free one. Nil when the pool is spent, and the
    /// part plays straight into the main mixer.
    public func strip(for part: PartID) -> MixStripNodes? {
        if let existing = strips[part] { return existing }
        guard let free = slots.first(where: { $0.part == nil }) else {
            if !unseated.contains(part) { unseated.append(part) }
            return nil
        }
        free.part = part
        strips[part] = free
        meter(free)
        apply(mix.strip(for: part, label: ""), to: free)
        return free
    }

    /// Starts metering a strip a part has just taken.
    private func meter(_ strip: MixStripNodes) {
        guard !strip.isMetered, let format = try? engine.format else { return }
        // `@Sendable`, so the closure is not inferred as actor-isolated: the tap fires on the
        // render thread, and an isolated closure called there trips the executor check.
        strip.out.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
            strip.meter(buffer)
        }
        strip.isMetered = true
    }

    /// Claims a slot for each part, in order, before a single source is connected.
    ///
    /// Without this, slots went to whoever `LiveSongPlayer` happened to schedule first, so which
    /// parts got a fader depended on the order the transport built its sources — and the parts that
    /// missed out were whichever came last, discovered by noticing a dead fader. Reserving up
    /// front makes the allocation the plan's own order, and makes the shortfall known before a
    /// frame is rendered. Returns the parts it could not seat, which is also `unseated`.
    @discardableResult
    public func reserve(_ parts: [PartID]) -> [PartID] {
        for part in parts { _ = strip(for: part) }
        return unseated
    }

    /// Routes a source node through a part's strip instead of straight into the main mixer.
    /// With the pool spent the node goes to the main mixer, and the caller can ask `strip(for:)`.
    public func route(_ node: AVAudioNode, to part: PartID) throws {
        let av = engine.avEngine
        guard let strip = strip(for: part) else {
            try unroute(node)
            return
        }
        av.disconnectNodeOutput(node)
        // A bus of its own on the strip's input mixer: every source of the part is heard.
        av.connect(node, to: strip.input, fromBus: 0, toBus: strip.input.nextAvailableInputBus, format: engine.format)
        routed[ObjectIdentifier(node)] = (node, part)
    }

    /// Puts a node back on the main mixer.
    public func unroute(_ node: AVAudioNode) throws {
        let av = engine.avEngine
        guard routed[ObjectIdentifier(node)] != nil else { return }
        av.disconnectNodeOutput(node)
        try av.connectNode(node, to: engine.mainMixer, format: engine.format)
        routed[ObjectIdentifier(node)] = nil
    }

    /// Gives every slot back, so a new plan's parts take them afresh.
    public func releaseSlots() {
        unseated = []
        for slot in slots {
            slot.part = nil
            if slot.isMetered {
                slot.out.removeTap(onBus: 0)
                slot.isMetered = false
            }
        }
        strips = [:]
    }

    /// The part a node is routed to, if any.
    public func part(of node: AVAudioNode) -> PartID? { routed[ObjectIdentifier(node)]?.part }

    /// How many slots are metering. Every one costs a per-sample loop on the render thread, so
    /// this is the number a test asserts on rather than a thing the app reads.
    public var metered: Int { slots.count { $0.isMetered } }

    // MARK: Applying a mix

    /// Applies a mix to every strip and the master, for the section named (its gain overrides).
    public func apply(_ mix: Mix, section: SectionID? = nil) {
        self.mix = mix
        self.section = section
        for (part, strip) in strips {
            apply(mix.strip(for: part, label: ""), to: strip)
        }
        applyMaster(mix.master)
        applyReturns(mix)
    }

    /// Moves to a section: only what a section overrides changes — the gains, the echo sends and
    /// the rotating speakers' speed.
    public func move(to section: SectionID?) {
        guard section != self.section else { return }
        self.section = section
        for (part, strip) in strips {
            strip.out.outputVolume = Self.linear(mix.levelDB(for: part, in: section))
            strip.echo.outputVolume = Self.linear(mix.echoDB(for: part, in: section))
            strip.insertUnit?.set(mix.insert(for: part, in: section, instrument: instrumentInserts[part]))
        }
    }

    /// The reverb's space and the echo's time, feedback and tone.
    private func applyReturns(_ mix: Mix) {
        if mix.roomSetting != appliedRoom {
            reverb.loadFactoryPreset(Self.preset(mix.roomSetting))
            reverb.wetDryMix = 100
            appliedRoom = mix.roomSetting
        }
        applyEcho(mix.echoSettings)
    }

    private var appliedRoom: Room = .room

    private func applyEcho(_ echo: Echo) {
        // AVAudioUnitDelay reaches two seconds: a half note under 60 BPM is folded to the beat.
        var seconds = echo.beats * 60 / max(20, tempo)
        while seconds > 2 { seconds /= 2 }
        delay.delayTime = seconds
        delay.feedback = Float(echo.feedback * 100)
        delay.lowPassCutoff = Float(echo.toneHz)
        delay.wetDryMix = 100
    }

    static func preset(_ room: Room) -> AVAudioUnitReverbPreset {
        switch room {
        case .room: return .mediumRoom
        case .plate: return .plate
        case .chamber: return .mediumChamber
        case .hall: return .largeHall
        case .cathedral: return .cathedral
        }
    }

    private func apply(_ settings: Strip, to strip: MixStripNodes) {
        strip.out.outputVolume = strip.part == nil ? 0 : Self.linear(mix.levelDB(for: settings.part, in: section))
        strip.out.pan = Float(max(-1, min(1, settings.pan)))
        strip.send.outputVolume = Self.linear(settings.sendDB)
        strip.echo.outputVolume = strip.part == nil ? 0 : Self.linear(mix.echoDB(for: settings.part, in: section))
        strip.insertUnit?.set(strip.part.map { mix.insert(for: $0, in: section, instrument: instrumentInserts[$0]) } ?? nil)
        for (index, band) in settings.eq.prefix(strip.eq.bands.count).enumerated() {
            let unit = strip.eq.bands[index]
            switch band.shape {
            case .lowShelf: unit.filterType = .lowShelf
            case .peak: unit.filterType = .parametric
            case .highShelf: unit.filterType = .highShelf
            }
            unit.frequency = Float(band.frequency)
            unit.gain = Float(band.gainDB)
            unit.bandwidth = Float(max(0.05, band.width))
            unit.bypass = band.gainDB == 0
        }
        let dynamics = strip.dynamics.audioUnit
        if let compressor = settings.compressor {
            strip.dynamics.bypass = false
            AudioUnitSetParameter(dynamics, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, Float(compressor.thresholdDB), 0)
            // No ratio on this unit: the head room is the knee, and a harder ratio is a smaller one.
            AudioUnitSetParameter(dynamics, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, Float(max(0.1, 24 / max(1, compressor.ratio))), 0)
            AudioUnitSetParameter(dynamics, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, Float(compressor.attackMS / 1000), 0)
            AudioUnitSetParameter(dynamics, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, Float(compressor.releaseMS / 1000), 0)
            AudioUnitSetParameter(dynamics, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, Float(compressor.makeupDB), 0)
        } else {
            strip.dynamics.bypass = true
        }
    }

    /// The master's gain, on the trim. The ceiling is not a live setting: see `init`.
    private func applyMaster(_ master: Master) {
        masterGainDB = master.gainDB
        trim.outputVolume = Self.linear(master.gainDB) * fade
    }

    private var masterGainDB: Double = 0
    /// The song's ending, as it plays: 1 until the fade, 0 at the end. On the trim with the
    /// master's gain, so a mix move during the fade keeps the fade.
    private var fade: Float = 1

    /// Sets how far into its fade-out the song is: 1 is untouched, 0 is silent.
    public func setFade(_ gain: Double) {
        fade = Float(max(0, min(1, gain)))
        trim.outputVolume = Self.linear(masterGainDB) * fade
    }

    /// The compressor's gain reduction on a strip right now, dB (a reading, not a setting).
    public func gainReductionDB(for part: PartID) -> Double {
        guard let strip = strips[part], !strip.dynamics.bypass else { return 0 }
        var value: AudioUnitParameterValue = 0
        AudioUnitGetParameter(strip.dynamics.audioUnit, kDynamicsProcessorParam_CompressionAmount, kAudioUnitScope_Global, 0, &value)
        return Double(value)
    }

    /// The strip's meter, 0…1 peak and RMS.
    public func meter(for part: PartID) -> (peak: Float, rms: Float) {
        strips[part]?.meter ?? (0, 0)
    }

    static func linear(_ dB: Double?) -> Float {
        guard let dB else { return 0 }
        return Float(pow(10, dB / 20))
    }
}

extension Engine {
    /// The engine's mix graph: built by `start()` before the engine runs, or here when asked for
    /// earlier. Strips are made as parts are routed.
    public func mixGraph() throws -> MixGraph {
        if let existing = mixGraphStorage { return existing }
        guard !avEngine.isRunning else { throw EngineError.alreadyRunning }
        let graph = try MixGraph(engine: self)
        mixGraphStorage = graph
        return graph
    }
}
