import AVFAudio
import AudioToolbox
import CStripFX
import Foundation
import SongGraph

/// A strip's insert as an audio unit: the amp or the rotating speaker of `CStripFX`, in the graph
/// between a part's sources and its EQ, live and offline alike.
///
/// An in-process Audio Unit, registered once under the app's own codes, so the engine can hold one
/// in every strip of its pool like any of Apple's units. The render block does nothing but pull its
/// input and hand the buffers to C: allocation, locking and the DSP's state all stay out of it.
/// Settings cross to the audio thread through `sfx_set_params`, which is safe while it renders.
public final class StripInsertUnit: AUAudioUnit {

    /// The codes it is registered under: an effect, "mrfx", by "MrRb".
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6D72_6678,       // 'mrfx'
        componentManufacturer: 0x4D72_5262,  // 'MrRb'
        componentFlags: 0, componentFlagsMask: 0)

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(StripInsertUnit.self, as: componentDescription,
                                     name: "Mr. Roboto: Strip Insert", version: 1)
    }()

    /// A node holding a fresh insert, set to nothing.
    public static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    /// What renders: created with the render resources, at their rate and channel count.
    private var fx: OpaquePointer?
    /// Where the input is pulled to when the host gives no output buffers of its own.
    private var pulled: AVAudioPCMBuffer?
    /// The channel pointers handed to C, allocated once with the render resources.
    private var planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    private var planeCount = 0
    /// The settings, kept so a unit whose resources are made later starts with them.
    private var settings = StripInsertUnit.params(for: StripChain())
    /// The song's clock and sections as last set, kept for the same reason. Allocated once: it is
    /// some eighteen kilobytes, and the C side copies it.
    private let timeline: UnsafeMutablePointer<sfx_timeline_t> = {
        let pointer = UnsafeMutablePointer<sfx_timeline_t>.allocate(capacity: 1)
        pointer.initialize(to: sfx_timeline_t())
        return pointer
    }()

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096
    }

    deinit {
        if let fx { sfx_destroy(fx) }
        planes?.deallocate()
        timeline.deallocate()
        scratch.deallocate()
    }

    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var canProcessInPlace: Bool { true }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        let channels = Int(format.channelCount)
        if let fx { sfx_destroy(fx) }
        fx = sfx_create(format.sampleRate, Int32(channels))
        if let fx {
            sfx_set_params(fx, &settings)
            sfx_set_timeline(fx, timeline)
            sfx_reset(fx)
        }
        pulled = AVAudioPCMBuffer(pcmFormat: inputBus.format, frameCapacity: maximumFramesToRender)
        planes?.deallocate()
        planes = .allocate(capacity: max(1, channels))
        planes?.initialize(repeating: nil, count: max(1, channels))
        planeCount = channels
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        if let fx { sfx_destroy(fx) }
        fx = nil
        pulled = nil
        planes?.deallocate()
        planes = nil
        planeCount = 0
    }

    /// Puts `insert` in, or takes what is in out with `.off`; the other stages are left alone.
    public func set(_ insert: StripInsert?) {
        var chain = self.chain
        chain.insert = insert
        set(chain)
    }

    /// Everything on the strip, as it plays now.
    public private(set) var chain = StripChain()

    /// Puts the whole chain in: the pedal, the insert, the modulation, the filter and the pump.
    public func set(_ chain: StripChain) {
        self.chain = chain
        let params = Self.params(for: chain)
        guard params != settings else { return }
        settings = params
        if let fx { sfx_set_params(fx, &settings) }
    }

    /// The song's clock and sections, for the filter's moves and the pump. Sent to the audio
    /// thread only when it differs from what it has: a fader move re-applies the whole mix, and
    /// every strip copying eighteen kilobytes for nothing is not free.
    public func set(timeline build: (UnsafeMutablePointer<sfx_timeline_t>) -> Void) {
        scratch.pointee = sfx_timeline_t()
        build(scratch)
        guard memcmp(scratch, timeline, MemoryLayout<sfx_timeline_t>.size) != 0 else { return }
        timeline.pointee = scratch.pointee
        if let fx { sfx_set_timeline(fx, timeline) }
    }

    /// Where a timeline is built before it is compared with the one in use.
    private let scratch: UnsafeMutablePointer<sfx_timeline_t> = {
        let pointer = UnsafeMutablePointer<sfx_timeline_t>.allocate(capacity: 1)
        pointer.initialize(to: sfx_timeline_t())
        return pointer
    }()

    static func params(for chain: StripChain) -> sfx_params_t {
        var params = sfx_params_t()
        let insert = chain.insert ?? .off
        switch insert.kind {
        case .off: params.kind = Int32(SFX_OFF.rawValue)
        case .amp: params.kind = Int32(SFX_AMP.rawValue)
        case .rotary: params.kind = Int32(SFX_ROTARY.rawValue)
        }
        params.drive = Float(insert.kind == .amp ? insert.drive : 0.3)
        params.growl = Float(insert.kind == .rotary ? insert.drive : 0)
        params.tone = Float(insert.tone)
        params.fast = insert.fast ? 1 : 0
        params.level = 1
        // Every field is set whether or not its stage is on, so two chains that sound the same
        // compare the same and a change of nothing publishes nothing.
        let pedal = chain.pedal
        params.pedal = Int32(pedal.map { $0.kind == .envelope ? SFX_PEDAL_ENVELOPE.rawValue : SFX_PEDAL_WAH.rawValue } ?? SFX_PEDAL_OFF.rawValue)
        params.pedalAmount = Float(pedal?.amount ?? 0.5)
        params.pedalResonance = Float(pedal?.resonance ?? 0.6)
        params.pedalBeats = Float(pedal?.beats ?? 0.5)
        let modulation = chain.modulation
        switch modulation?.kind ?? .off {
        case .off: params.mod = Int32(SFX_MOD_OFF.rawValue)
        case .chorus: params.mod = Int32(SFX_MOD_CHORUS.rawValue)
        case .phaser: params.mod = Int32(SFX_MOD_PHASER.rawValue)
        case .flanger: params.mod = Int32(SFX_MOD_FLANGER.rawValue)
        case .vibrato: params.mod = Int32(SFX_MOD_VIBRATO.rawValue)
        }
        params.modRate = Float(modulation?.rateHz ?? 0.5)
        params.modDepth = Float(modulation?.depth ?? 0.5)
        params.modFeedback = Float(modulation?.feedback ?? 0)
        let filter = chain.filter
        params.filter = Int32(filter.map { $0.kind == .lowPass ? SFX_FILTER_LOWPASS.rawValue : SFX_FILTER_HIGHPASS.rawValue } ?? SFX_FILTER_OFF.rawValue)
        params.filterHz = Float(filter?.cutoffHz ?? 20_000)
        params.filterResonance = Float(filter?.resonance ?? 0)
        params.pump = chain.pump == nil ? 0 : 1
        params.pumpDB = Float(chain.pump?.depthDB ?? 6)
        params.pumpReleaseBeats = Float(chain.pump?.releaseBeats ?? 0.5)
        return params
    }

    /// What is in, as last set.
    public var isOff: Bool { settings.kind == Int32(SFX_OFF.rawValue) }

    /// The filter's corner as last played, Hz; 0 when it has none.
    public var filterCorner: Float { fx.map { sfx_filter_corner($0) } ?? 0 }

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Unretained, as the unit outlives its block. What the block reads of it — the C state,
        // the pull buffer, the channel pointers — is made with the render resources and does not
        // change while they are allocated, which is the only time the block runs.
        let state = Unmanaged.passUnretained(self)
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            let stamp = timestamp.pointee
            let unit = state.takeUnretainedValue()
            guard let pull = pullInputBlock, let pulled = unit.pulled, let planes = unit.planes else {
                return kAudioUnitErr_NoConnection
            }
            let out = UnsafeMutableAudioBufferListPointer(outputData)
            // Pull into the host's buffers when it gave some, else into our own and point at them.
            let into = out.first?.mData == nil ? pulled.mutableAudioBufferList : outputData
            let target = UnsafeMutableAudioBufferListPointer(into)
            for index in target.indices { target[index].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size) }
            var flags = AudioUnitRenderActionFlags()
            let status = pull(&flags, timestamp, frameCount, 0, into)
            guard status == noErr else { return status }
            if into != outputData {
                for index in out.indices where index < target.count {
                    out[index].mData = target[index].mData
                    out[index].mDataByteSize = target[index].mDataByteSize
                }
            }
            let count = min(out.count, unit.planeCount)
            for c in 0..<count { planes[c] = out[c].mData?.assumingMemoryBound(to: Float.self) }
            if let fx = unit.fx, count > 0 {
                // The block's place on the render timeline, which the song's clock is counted in.
                let at = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : -1
                sfx_process_at(fx, planes, Int32(count), Int32(frameCount), at)
            }
            return noErr
        }
    }
}

/// Everything on a strip between its sources and its EQ, as it plays in one section.
public struct StripChain: Equatable, Sendable {
    public var pedal: StripPedal?
    public var insert: StripInsert?
    public var modulation: StripModulation?
    public var filter: StripFilter?
    public var pump: StripPump?

    public init(pedal: StripPedal? = nil, insert: StripInsert? = nil, modulation: StripModulation? = nil,
                filter: StripFilter? = nil, pump: StripPump? = nil) {
        self.pedal = pedal
        self.insert = insert
        self.modulation = modulation
        self.filter = filter
        self.pump = pump
    }
}

extension sfx_params_t: @retroactive Equatable {
    public static func == (a: sfx_params_t, b: sfx_params_t) -> Bool {
        a.kind == b.kind && a.drive == b.drive && a.tone == b.tone && a.fast == b.fast && a.growl == b.growl && a.level == b.level
            && a.pedal == b.pedal && a.pedalAmount == b.pedalAmount && a.pedalResonance == b.pedalResonance && a.pedalBeats == b.pedalBeats
            && a.mod == b.mod && a.modRate == b.modRate && a.modDepth == b.modDepth && a.modFeedback == b.modFeedback
            && a.filter == b.filter && a.filterHz == b.filterHz && a.filterResonance == b.filterResonance
            && a.pump == b.pump && a.pumpDB == b.pumpDB && a.pumpReleaseBeats == b.pumpReleaseBeats
    }
}
