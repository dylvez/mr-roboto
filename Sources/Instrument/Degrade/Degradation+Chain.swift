import AVFoundation
import Foundation
import SongGraph

// The graph's `Degradation` and this module's `DegradeSettings` are the same thing seen from two
// sides: the graph stores a pass as names and numbers so it need not know what a chain is, and this
// is the typed view that knows. The keys live here and nowhere else.
//
// The seed never goes near a `Double`. `DegradeSettings.seed` and `Degradation.seed` are both
// `UInt64` and are copied field to field; the parameter dictionary carries everything else.

extension DegradeSettings {

    /// Keys in `Degradation.parameters`. The field names, unprefixed; the two enumerations travel as
    /// their C values (`DG_SAT_*`, `DG_AA_*`), which are small, stable and exact in a `Double`.
    public enum PassKey {
        public static let bitDepth = "bitDepth", companding = "companding"
        public static let targetSampleRate = "targetSampleRate", antiAliasing = "antiAliasing"
        public static let drive = "drive", saturation = "saturation"
        public static let wowDepth = "wowDepth", wowRate = "wowRate"
        public static let flutterDepth = "flutterDepth", flutterRate = "flutterRate"
        public static let noiseLevel = "noiseLevel", crackleDensity = "crackleDensity"
        public static let highCut = "highCut", mix = "mix"
    }

    /// Reads a stored pass back. Starts from the named preset when the pass names one this build
    /// knows, then applies every parameter the pass carries, then the seed — exactly, as a `UInt64`.
    /// A pass written before a parameter existed therefore opens with the preset's value for it.
    public init(_ pass: Degradation) {
        var settings = pass.preset.flatMap(Preset.init(rawValue:)).map(DegradeSettings.init(preset:)) ?? DegradeSettings()
        let p = pass.parameters
        if let v = p[PassKey.bitDepth] { settings.bitDepth = v }
        if let v = p[PassKey.companding] { settings.companding = v }
        if let v = p[PassKey.targetSampleRate] { settings.targetSampleRate = v }
        if let v = p[PassKey.antiAliasing] { settings.antiAliasing = AntiAliasing(raw: Int32(v.rounded())) }
        if let v = p[PassKey.drive] { settings.drive = v }
        if let v = p[PassKey.saturation] { settings.saturation = Saturation(raw: Int32(v.rounded())) }
        if let v = p[PassKey.wowDepth] { settings.wowDepth = v }
        if let v = p[PassKey.wowRate] { settings.wowRate = v }
        if let v = p[PassKey.flutterDepth] { settings.flutterDepth = v }
        if let v = p[PassKey.flutterRate] { settings.flutterRate = v }
        if let v = p[PassKey.noiseLevel] { settings.noiseLevel = v }
        if let v = p[PassKey.crackleDensity] { settings.crackleDensity = v }
        if let v = p[PassKey.highCut] { settings.highCut = v }
        if let v = p[PassKey.mix] { settings.mix = v }
        settings.seed = pass.seed
        self = settings
    }

    /// This set as a stored pass. `preset` names what it was reached from — the matching preset
    /// when it is one exactly, otherwise whatever the caller says it started as — and every
    /// parameter is written, so the pass renders the same even if a preset's definition moves.
    public func degradation(from base: Preset? = nil) -> Degradation {
        Degradation(chain: Degradation.degradeChain,
                    preset: (matchingPreset ?? base)?.rawValue,
                    parameters: [
                        PassKey.bitDepth: bitDepth,
                        PassKey.companding: companding,
                        PassKey.targetSampleRate: targetSampleRate,
                        PassKey.antiAliasing: Double(antiAliasing.raw),
                        PassKey.drive: drive,
                        PassKey.saturation: Double(saturation.raw),
                        PassKey.wowDepth: wowDepth,
                        PassKey.wowRate: wowRate,
                        PassKey.flutterDepth: flutterDepth,
                        PassKey.flutterRate: flutterRate,
                        PassKey.noiseLevel: noiseLevel,
                        PassKey.crackleDensity: crackleDensity,
                        PassKey.highCut: highCut,
                        PassKey.mix: mix,
                    ],
                    seed: seed)
    }
}

extension DegradeChain {

    /// Every pass in order, each through its own fresh, latency-compensated chain — sample *n* out is
    /// sample *n* in — so a stack of two is the first machine's output fed to the second.
    ///
    /// Deterministic: each pass is seeded from its own stored seed, so the same source and the same
    /// passes give the same bytes, which is what makes a dusty version bounce the same twice. A pass
    /// that is bypass is skipped rather than run, so a dry part is returned bit-identical.
    public static func rendered(_ source: AVAudioPCMBuffer, passes: [Degradation]) throws -> AVAudioPCMBuffer {
        var buffer = source
        for pass in passes where pass.chain == Degradation.degradeChain {
            let settings = DegradeSettings(pass)
            guard !settings.isBypass else { continue }
            buffer = try rendered(buffer, settings: settings)
        }
        return buffer
    }

    /// One chain over planar floats at one rate: what a kit puts a drum voice through when the voice
    /// has a chain of its own. Bypass returns the samples as they came.
    public static func rendered(planar: [[Float]], sampleRate: Double, settings: DegradeSettings) throws -> [[Float]] {
        guard !settings.isBypass else { return planar }
        let channels = planar.count
        let frames = planar.map(\.count).min() ?? 0
        guard frames > 0 else { return planar }
        guard channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let input = source.floatChannelData else {
            throw Failure.couldNotCreate(sampleRate: sampleRate, channelCount: channels)
        }
        source.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            planar[channel].withUnsafeBufferPointer { input[channel].update(from: $0.baseAddress!, count: frames) }
        }
        let processed = try rendered(source, settings: settings)
        guard let output = processed.floatChannelData else { return planar }
        let count = Int(processed.frameLength)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: output[$0], count: count)) }
    }

    /// The same over planar floats at one rate, for callers that hold samples rather than buffers.
    public static func rendered(planar: [[Float]], sampleRate: Double,
                                passes: [Degradation]) throws -> [[Float]] {
        let live = passes.filter { $0.chain == Degradation.degradeChain && !DegradeSettings($0).isBypass }
        guard !live.isEmpty else { return planar }
        let channels = planar.count
        let frames = planar.map(\.count).min() ?? 0
        guard channels > 0, frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let input = source.floatChannelData else {
            if frames == 0 { return planar }
            throw Failure.couldNotCreate(sampleRate: sampleRate, channelCount: channels)
        }
        source.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            planar[channel].withUnsafeBufferPointer { input[channel].update(from: $0.baseAddress!, count: frames) }
        }
        let processed = try rendered(source, passes: live)
        guard let output = processed.floatChannelData else { return planar }
        let count = Int(processed.frameLength)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: output[$0], count: count)) }
    }
}
