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
