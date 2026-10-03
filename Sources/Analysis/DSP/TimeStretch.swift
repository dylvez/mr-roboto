import AVFAudio
import CSignalsmithStretch
import Foundation

/// Offline time-stretch and pitch-shift on Signalsmith Stretch (vendored in `CSignalsmithStretch`).
///
/// Every call builds its own stretcher, runs the library's `exact` sequence (seek pre-roll,
/// process, flush) and tears it down, so the value is trivially `Sendable` and calls can run in
/// parallel. `exact` handles the two latencies for us: it primes the processing position with
/// `inputLatency` samples of input, uses the surplus to synthesise `outputLatency` samples of
/// pre-roll that are folded back into the start of the output, and drains the tail with
/// `flush`, so an impulse at `t` in the input lands at `t * ratio` in the output (measured: within
/// a millisecond, see `TimeStretchTests`). Inputs shorter than the pre-roll are zero-padded to
/// it and the output trimmed back, so short buffers work too.
///
/// Ratio is output duration over input duration: 1.25 makes the audio 25 percent longer.
/// Channel count and sample rate are preserved; the output is Float32 deinterleaved.
public struct SignalsmithTimeStretcher: TimeStretcher {
    public static let name = "signalsmith"

    public enum Error: Swift.Error, Sendable, CustomStringConvertible {
        case invalidArgument(String)
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .invalidArgument(let s): return "time stretch: \(s)"
            case .allocationFailed(let s): return "time stretch: cannot allocate \(s)"
            }
        }
    }

    public enum Preset: Sendable, Equatable {
        /// 120 ms blocks, 30 ms interval: the library's quality default.
        case `default`
        /// 100 ms blocks, 40 ms interval: fewer, larger hops.
        case cheaper
        /// 40 ms blocks, 10 ms interval: sharper attacks for drums (on the Arrival drum stem at
        /// x1.1, 92 percent of onsets stay within 15 ms against 87 for `default`), blurrier bass.
        case percussive
        /// Explicit STFT block length and hop in seconds. Shorter blocks keep transients sharper
        /// at the cost of low-frequency resolution.
        case custom(block: Double, interval: Double)

        func makeHandle(channels: Int, sampleRate: Double, seed: Int) -> OpaquePointer? {
            switch self {
            case .default: return ss_stretch_create(Int32(channels), sampleRate, SS_STRETCH_PRESET_DEFAULT, seed)
            case .cheaper: return ss_stretch_create(Int32(channels), sampleRate, SS_STRETCH_PRESET_CHEAPER, seed)
            case .percussive: return Preset.custom(block: 0.04, interval: 0.01).makeHandle(channels: channels, sampleRate: sampleRate, seed: seed)
            case .custom(let block, let interval):
                return ss_stretch_create_configured(Int32(channels), sampleRate, Int32(block * sampleRate), Int32(interval * sampleRate), seed)
            }
        }
    }

    public var preset: Preset
    /// Above this frequency a pitch shift uses the library's non-linear map, keeping more of the
    /// original timbre. 0 disables it. Only matters when `pitchShift != 0`.
    public var tonalityLimitHz: Double
    /// Keep formants where they are when pitch-shifting (the library's `compensatePitch`).
    public var preserveFormants: Bool
    /// Seed for the phase-randomisation engine, so repeated runs are bit-identical.
    public var seed: Int

    public init(preset: Preset = .default, tonalityLimitHz: Double = 8000, preserveFormants: Bool = false, seed: Int = 1) {
        self.preset = preset
        self.tonalityLimitHz = tonalityLimitHz
        self.preserveFormants = preserveFormants
        self.seed = seed
    }

    public var providerName: String { Self.name }

    // MARK: TimeStretcher

    public func stretch(_ buffer: AVReadOnlyAudioPCMBuffer, ratio: Double, pitchShift semitones: Double) async throws -> AVReadOnlyAudioPCMBuffer {
        try Task.checkCancellation()
        let format = buffer.format
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let input = try Self.planarFloat(buffer)
        let output = try stretch(planar: input, sampleRate: sampleRate, ratio: ratio, pitchShift: semitones)
        let frames = output.first?.count ?? 0
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels), interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw Error.allocationFailed("a \(channels)-channel Float32 buffer at \(sampleRate) Hz")
        }
        out.frameLength = AVAudioFrameCount(frames)
        if frames > 0, let dst = out.floatChannelData {
            for c in 0..<channels {
                output[c].withUnsafeBufferPointer { dst[c].update(from: $0.baseAddress!, count: frames) }
            }
        }
        return AVReadOnlyAudioPCMBuffer(copying: out)
    }

    // MARK: Plain-array API

    /// Stretches planar Float channels (all the same length). Output channels have
    /// `round(input.count * ratio)` samples each. Synchronous; the buffer API wraps this.
    public func stretch(planar input: [[Float]], sampleRate: Double, ratio: Double, pitchShift semitones: Double = 0) throws -> [[Float]] {
        guard ratio.isFinite, ratio > 0 else { throw Error.invalidArgument("ratio must be positive, got \(ratio)") }
        guard semitones.isFinite else { throw Error.invalidArgument("pitch shift must be finite") }
        guard sampleRate > 0 else { throw Error.invalidArgument("sample rate must be positive, got \(sampleRate)") }
        let channels = input.count
        guard channels > 0 else { throw Error.invalidArgument("no channels") }
        let inFrames = input[0].count
        guard input.allSatisfy({ $0.count == inFrames }) else { throw Error.invalidArgument("channels differ in length") }
        let outFrames = Int((Double(inFrames) * ratio).rounded())
        guard inFrames > 0, outFrames > 0 else { return Array(repeating: [], count: channels) }

        guard let handle = preset.makeHandle(channels: channels, sampleRate: sampleRate, seed: seed) else {
            throw Error.allocationFailed("a \(channels)-channel stretcher at \(sampleRate) Hz with \(preset)")
        }
        defer { ss_stretch_destroy(handle) }
        ss_stretch_set_time_factor(handle, ratio)
        if semitones != 0 {
            ss_stretch_set_transpose_semitones(handle, semitones, tonalityLimitHz)
            if preserveFormants { ss_stretch_set_formant_semitones(handle, 0, true) }
        }

        // `exact` needs at least the seek pre-roll of input. Shorter inputs are padded with
        // silence at the end and the output trimmed back; padding at the end only extends the
        // output at the end, so the alignment of the real part is unchanged.
        let playbackRate = Double(inFrames) / Double(outFrames)
        let minimumInput = Int(ss_stretch_exact_minimum_input(handle, playbackRate)) + 1
        let paddedIn = max(inFrames, minimumInput)
        let paddedOut = paddedIn == inFrames ? outFrames : Int((Double(paddedIn) / playbackRate).rounded(.up))

        // Flat planar storage: channel c occupies [c * stride, (c + 1) * stride).
        var source = [Float](repeating: 0, count: channels * paddedIn)
        for c in 0..<channels {
            input[c].withUnsafeBufferPointer { src in
                source.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + c * paddedIn).update(from: src.baseAddress!, count: inFrames)
                }
            }
        }
        var result = [Float](repeating: 0, count: channels * paddedOut)
        let ok = source.withUnsafeBufferPointer { src -> Bool in
            result.withUnsafeMutableBufferPointer { dst -> Bool in
                let inPtrs: [UnsafePointer<Float>?] = (0..<channels).map { src.baseAddress! + $0 * paddedIn }
                let outPtrs: [UnsafeMutablePointer<Float>?] = (0..<channels).map { dst.baseAddress! + $0 * paddedOut }
                return inPtrs.withUnsafeBufferPointer { ip in
                    outPtrs.withUnsafeBufferPointer { op in
                        ss_stretch_exact(handle, ip.baseAddress!, Int32(paddedIn), op.baseAddress!, Int32(paddedOut))
                    }
                }
            }
        }
        guard ok else { throw Error.invalidArgument("input of \(inFrames) frames is too short for the pre-roll") }
        return (0..<channels).map { c in
            result.withUnsafeBufferPointer { Array(UnsafeBufferPointer(start: $0.baseAddress! + c * paddedOut, count: outFrames)) }
        }
    }

    // MARK: A rate that varies

    /// Stretches planar Float channels along a time map: `anchors` pin moments of the input
    /// (seconds from its start) to moments of the output, joined by straight lines from (0, 0),
    /// and the last line carries on to the input's end. What tightens a record onto a grid: each
    /// of its bars stretched by its own amount, so its bar lines land on the grid's.
    ///
    /// Run the way `exact` runs a constant stretch — an output seek primes the library so the
    /// first output sample is aligned to the first input sample, then the input is fed ahead of
    /// the output by the library's latency — except that the input fed for each chunk of output
    /// is read off the map, so the rate is the map's slope there. An anchored moment lands where
    /// it was pinned to within a few milliseconds (`TimeStretchTests`). A map that is one straight
    /// line is the constant stretch, bit for bit.
    public func stretch(planar input: [[Float]], sampleRate: Double, anchors: [StretchAnchor], pitchShift semitones: Double = 0) throws -> [[Float]] {
        guard sampleRate > 0 else { throw Error.invalidArgument("sample rate must be positive, got \(sampleRate)") }
        guard semitones.isFinite else { throw Error.invalidArgument("pitch shift must be finite") }
        let channels = input.count
        guard channels > 0 else { throw Error.invalidArgument("no channels") }
        let inFrames = input[0].count
        guard input.allSatisfy({ $0.count == inFrames }) else { throw Error.invalidArgument("channels differ in length") }
        let map = try StretchMap(anchors, sampleRate: sampleRate, inputFrames: inFrames)
        if let ratio = map.constantRatio { return try stretch(planar: input, sampleRate: sampleRate, ratio: ratio, pitchShift: semitones) }
        let outFrames = Int(map.output(Double(inFrames)).rounded())
        guard inFrames > 0, outFrames > 0 else { return Array(repeating: [], count: channels) }

        guard let handle = preset.makeHandle(channels: channels, sampleRate: sampleRate, seed: seed) else {
            throw Error.allocationFailed("a \(channels)-channel stretcher at \(sampleRate) Hz with \(preset)")
        }
        defer { ss_stretch_destroy(handle) }
        ss_stretch_set_time_factor(handle, Double(outFrames) / Double(inFrames))
        if semitones != 0 {
            ss_stretch_set_transpose_semitones(handle, semitones, tonalityLimitHz)
            if preserveFormants { ss_stretch_set_formant_semitones(handle, 0, true) }
        }
        let inputLatency = Int(ss_stretch_input_latency(handle))
        let outputLatency = Int(ss_stretch_output_latency(handle))
        // The input the library has been fed once output `y` is out: the input `y` maps to,
        // `outputLatency` of output further on, plus the input latency.
        func fed(_ y: Int) -> Int { Int(map.input(Double(y + outputLatency)).rounded()) + inputLatency }

        // Padded with silence past the end, for the latency's worth the tail reads.
        let padded = max(inFrames, fed(outFrames)) + 1
        var source = [Float](repeating: 0, count: channels * padded)
        for c in 0..<channels {
            input[c].withUnsafeBufferPointer { src in
                source.withUnsafeMutableBufferPointer { dst in
                    if inFrames > 0 { (dst.baseAddress! + c * padded).update(from: src.baseAddress!, count: inFrames) }
                }
            }
        }
        var result = [Float](repeating: 0, count: channels * outFrames)
        let chunk = 256
        source.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                func inputs(at frame: Int) -> [UnsafePointer<Float>?] { (0..<channels).map { src.baseAddress! + $0 * padded + frame } }
                func outputs(at frame: Int) -> [UnsafeMutablePointer<Float>?] { (0..<channels).map { dst.baseAddress! + $0 * outFrames + frame } }
                var done = fed(0)
                inputs(at: 0).withUnsafeBufferPointer { ss_stretch_output_seek(handle, $0.baseAddress!, Int32(done)) }
                var y = 0
                while y < outFrames {
                    let count = min(chunk, outFrames - y)
                    let target = min(padded, max(done, fed(y + count)))
                    inputs(at: done).withUnsafeBufferPointer { ip in
                        outputs(at: y).withUnsafeBufferPointer { op in
                            ss_stretch_process(handle, ip.baseAddress!, Int32(target - done), op.baseAddress!, Int32(count))
                        }
                    }
                    done = target
                    y += count
                }
            }
        }
        return (0..<channels).map { c in
            result.withUnsafeBufferPointer { Array(UnsafeBufferPointer(start: $0.baseAddress! + c * outFrames, count: outFrames)) }
        }
    }

    // MARK: Helpers

    /// Float32 planar copies of every channel of `buffer`, converting from Int16/Int32/interleaved.
    static func planarFloat(_ buffer: AVReadOnlyAudioPCMBuffer) throws -> [[Float]] {
        let mutable = AVAudioPCMBuffer(copying: buffer)
        let float = try Resampler.asFloat32Deinterleaved(mutable)
        let channels = Int(float.format.channelCount)
        let n = Int(float.frameLength)
        guard n > 0, let data = float.floatChannelData else { return Array(repeating: [], count: channels) }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }
}

/// A moment of the input pinned to a moment of the output, both in seconds from the start.
public struct StretchAnchor: Hashable, Sendable {
    public var input: Double
    public var output: Double

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// A piecewise-linear time map in frames: through (0, 0) and the anchors, the last line carried on.
struct StretchMap {
    private var inputs: [Double] = [0]
    private var outputs: [Double] = [0]

    init(_ anchors: [StretchAnchor], sampleRate: Double, inputFrames: Int) throws {
        for anchor in anchors.sorted(by: { $0.input < $1.input }) {
            let x = anchor.input * sampleRate, y = anchor.output * sampleRate
            guard x.isFinite, y.isFinite else { throw SignalsmithTimeStretcher.Error.invalidArgument("an anchor is not finite") }
            if x <= inputs.last! + 0.5 { continue }
            guard y > outputs.last! else { throw SignalsmithTimeStretcher.Error.invalidArgument("anchors must move forward in time") }
            inputs.append(x)
            outputs.append(y)
        }
        guard inputs.count > 1 else { throw SignalsmithTimeStretcher.Error.invalidArgument("no anchor past the start") }
    }

    /// The ratio when the map is one straight line, else nil.
    var constantRatio: Double? {
        let first = outputs[1] / inputs[1]
        for i in 1..<inputs.count where abs((outputs[i] - outputs[i - 1]) / (inputs[i] - inputs[i - 1]) - first) > 1e-9 { return nil }
        return first
    }

    func output(_ x: Double) -> Double { Self.interpolate(x, from: inputs, to: outputs) }
    func input(_ y: Double) -> Double { Self.interpolate(y, from: outputs, to: inputs) }

    private static func interpolate(_ value: Double, from a: [Double], to b: [Double]) -> Double {
        var index = 1
        while index < a.count - 1, value > a[index] { index += 1 }
        let slope = (b[index] - b[index - 1]) / (a[index] - a[index - 1])
        return b[index - 1] + (value - a[index - 1]) * slope
    }
}
