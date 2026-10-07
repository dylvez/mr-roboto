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
    private var settings = sfx_params_t(kind: Int32(SFX_OFF.rawValue), drive: 0.3, tone: 0.5, fast: 0, growl: 0, level: 1)

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

    /// Puts `insert` in, or takes what is in out with `.off`.
    public func set(_ insert: StripInsert?) {
        let insert = insert ?? .off
        var params = settings
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
        guard params != settings else { return }
        settings = params
        if let fx { sfx_set_params(fx, &settings) }
    }

    /// What is in, as last set.
    public var isOff: Bool { settings.kind == Int32(SFX_OFF.rawValue) }

    public override var internalRenderBlock: AUInternalRenderBlock {
        // Unretained, as the unit outlives its block. What the block reads of it — the C state,
        // the pull buffer, the channel pointers — is made with the render resources and does not
        // change while they are allocated, which is the only time the block runs.
        let state = Unmanaged.passUnretained(self)
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
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
                sfx_process(fx, planes, Int32(count), Int32(frameCount))
            }
            return noErr
        }
    }
}

extension sfx_params_t: @retroactive Equatable {
    public static func == (a: sfx_params_t, b: sfx_params_t) -> Bool {
        a.kind == b.kind && a.drive == b.drive && a.tone == b.tone && a.fast == b.fast && a.growl == b.growl && a.level == b.level
    }
}
