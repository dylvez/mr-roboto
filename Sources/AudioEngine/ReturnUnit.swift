import AVFAudio
import AudioToolbox
import CStripFX
import Foundation

/// A return's own effect as an audio unit: the spring, the gated room or the tape echo of
/// `CStripFX`, ahead of the Apple reverb or delay on that return. Off, it passes the sends through
/// to the Apple unit; on, the Apple unit is bypassed and this is the return.
///
/// Registered once under the app's own codes, as `StripInsertUnit` is, for the same reasons: the
/// render block only pulls its input and hands the buffers to C.
public final class ReturnUnit: AUAudioUnit {

    /// "mrrt", by "MrRb".
    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6D72_7274,       // 'mrrt'
        componentManufacturer: 0x4D72_5262,  // 'MrRb'
        componentFlags: 0, componentFlagsMask: 0)

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(ReturnUnit.self, as: componentDescription,
                                     name: "Mr. Roboto: Return", version: 1)
    }()

    public static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// What a return can be besides its Apple unit.
    public enum Kind: Equatable, Sendable {
        case off
        /// `ring` 0 short … 1 long.
        case spring(ring: Double, toneHz: Double)
        /// Cut off `holdSeconds` after each hit.
        case gated(holdSeconds: Double)
        case tape(seconds: Double, feedback: Double, toneHz: Double, wow: Double)
    }

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var fx: OpaquePointer?
    private var pulled: AVAudioPCMBuffer?
    private var planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    private var planeCount = 0
    private var settings = rfx_params_t(kind: Int32(RFX_OFF.rawValue), decay: 0.5, toneHz: 4_200, delaySeconds: 0.375, feedback: 0.35, wow: 0.4)

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
        if let fx { rfx_destroy(fx) }
        planes?.deallocate()
    }

    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var canProcessInPlace: Bool { true }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        let channels = min(2, Int(format.channelCount))
        if let fx { rfx_destroy(fx) }
        fx = rfx_create(format.sampleRate, Int32(channels))
        if let fx {
            rfx_set_params(fx, &settings)
            rfx_reset(fx)
        }
        pulled = AVAudioPCMBuffer(pcmFormat: inputBus.format, frameCapacity: maximumFramesToRender)
        planes?.deallocate()
        planes = .allocate(capacity: max(1, channels))
        planes?.initialize(repeating: nil, count: max(1, channels))
        planeCount = channels
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        if let fx { rfx_destroy(fx) }
        fx = nil
        pulled = nil
        planes?.deallocate()
        planes = nil
        planeCount = 0
    }

    /// What the return is now.
    public private(set) var kind: Kind = .off

    public func set(_ kind: Kind) {
        self.kind = kind
        var params = settings
        switch kind {
        case .off:
            params.kind = Int32(RFX_OFF.rawValue)
        case .spring(let ring, let tone):
            params.kind = Int32(RFX_SPRING.rawValue)
            params.decay = Float(ring)
            params.toneHz = Float(tone)
        case .gated(let hold):
            params.kind = Int32(RFX_GATED.rawValue)
            params.decay = Float(hold)
        case .tape(let seconds, let feedback, let tone, let wow):
            params.kind = Int32(RFX_TAPE.rawValue)
            params.delaySeconds = Float(seconds)
            params.feedback = Float(feedback)
            params.toneHz = Float(tone)
            params.wow = Float(wow)
        }
        guard params != settings else { return }
        settings = params
        if let fx { rfx_set_params(fx, &settings) }
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let state = Unmanaged.passUnretained(self)
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            let unit = state.takeUnretainedValue()
            guard let pull = pullInputBlock, let pulled = unit.pulled, let planes = unit.planes else {
                return kAudioUnitErr_NoConnection
            }
            let out = UnsafeMutableAudioBufferListPointer(outputData)
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
                rfx_process(fx, planes, Int32(count), Int32(frameCount))
            }
            return noErr
        }
    }
}

extension rfx_params_t: @retroactive Equatable {
    public static func == (a: rfx_params_t, b: rfx_params_t) -> Bool {
        a.kind == b.kind && a.decay == b.decay && a.toneHz == b.toneHz && a.delaySeconds == b.delaySeconds
            && a.feedback == b.feedback && a.wow == b.wow
    }
}
