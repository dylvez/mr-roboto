import AVFoundation
import CDegrade
import Foundation

/// The degradation chain: bit and rate reduction, saturation, wow and flutter, medium noise and a
/// high cut. A thin, safe owner for the C core in `Sources/CDegrade`, which is where the DSP and
/// the research behind every number live.
///
/// # Thread model
///
/// Two roles, and only these — the same shape as `VoiceSampler`'s render core:
///
///   * **owner** — `init`, `deinit`, `reset()`, and setting `settings`. One thread at a time.
///   * **audio** — `processInPlace(_:channelCount:frameCount:)` (or `process(_:)` offline), and
///     nothing else.
///
/// `settings` may be set while the audio thread is processing. The audio path allocates nothing,
/// takes no lock, and calls nothing that can block. The Swift-side mirror of `settings` is guarded
/// by a lock for the benefit of the owner and UI threads; **never read `settings` from the audio
/// thread** — it is the one member here that takes a lock.
///
/// # Which parameters are safe to change while rendering
///
/// Safe, and click-free: `bitDepth`, `companding`, `targetSampleRate`, `drive`, `wowDepth`,
/// `wowRate`, `flutterDepth`, `flutterRate`, `noiseLevel`, `crackleDensity`, `highCut`, `mix`.
/// Each ramps linearly to its new value over 20 ms.
///
/// Safe, but stepped — set them between notes rather than under a held one:
///   * `saturation` and `antiAliasing` are enumerations; they switch at the next process call.
///     With `drive` near unity a saturation switch is inaudible, with heavy drive it is a step.
///   * `seed` restarts the noise generator. That is a cut, not a ramp, and it is the documented way
///     to audition a different pressing.
///   * `bitDepth` and `targetSampleRate` ramp as *parameters*, but the stages they control quantise
///     by nature: the output still steps by up to one quantiser level or one held sample. The ramp
///     stops a knob turn from clicking; it cannot make a quantiser continuous.
///
/// # Latency
///
/// `latencyFrames` is the wow/flutter delay line's nominal delay, and it applies to the dry half of
/// `mix` as well, so the whole chain is delayed by exactly that much at any mix. It is 0 only while
/// `isBypassed`. Offline callers who want sample alignment should use
/// `DegradeChain.rendered(_:settings:)`, which handles the padding and the trim.
///
/// # Bypass
///
/// A chain created — or `reset()` — with bypass settings, and never given anything else since,
/// does not touch a single sample: `process` returns immediately and the output is bit-identical to
/// the input. Once non-bypass settings have been applied the chain stays on the audio path until
/// the next `reset()`, even if it is set back to `.clean`, because dropping off the path would jump
/// the signal forward by `latencyFrames` and click. Setting `.clean` on a running chain is a mix
/// knob; `reset()` is the bypass switch.
public final class DegradeChain: @unchecked Sendable {

    public enum Failure: Error, Equatable {
        /// `dg_create` refused the sample rate or channel count, or could not allocate.
        case couldNotCreate(sampleRate: Double, channelCount: Int)
    }

    private let chain: OpaquePointer
    private let lock = NSLock()
    private var stored: DegradeSettings

    public let sampleRate: Double
    public let channelCount: Int

    /// Creates a chain sized for `channelCount` channels at `sampleRate`. Every buffer the audio
    /// path will ever need is allocated here.
    public init(sampleRate: Double, channelCount: Int, settings: DegradeSettings = .clean) throws {
        guard let handle = dg_create(sampleRate, Int32(channelCount)) else {
            throw Failure.couldNotCreate(sampleRate: sampleRate, channelCount: channelCount)
        }
        self.chain = handle
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.stored = settings
        var params = settings.cParams
        dg_set_params(handle, &params)
        // Snap rather than ramp. `dg_set_params` always ramps, which is right for a knob turn and
        // wrong for construction: without this, the first 20 ms out of a brand new chain would be a
        // fade from clean to the requested settings, and a caller who asked for 8 bits would not
        // get 8 bits until the ramp finished.
        dg_reset(handle)
    }

    deinit { dg_destroy(chain) }

    /// The current parameter set. Setting it is safe while the audio thread is processing; reading
    /// it takes a lock and must not be done from the audio thread.
    public var settings: DegradeSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
            var params = newValue.cParams
            dg_set_params(chain, &params)
        }
    }

    /// Applies a named parameter set.
    public func apply(_ preset: DegradeSettings.Preset) {
        settings = DegradeSettings(preset: preset)
    }

    /// Clears every filter, delay line and crackle voice, reseeds the noise from the current
    /// settings, snaps the parameter ramps to their targets, and re-enters true bypass if the
    /// current settings are bypass settings. Call it when the audio thread is not processing.
    public func reset() {
        dg_reset(chain)
    }

    /// Delay the chain imposes, in frames. Constant for the life of the chain except that it is 0
    /// while `isBypassed`.
    public var latencyFrames: Int { Int(dg_latency_frames(chain)) }

    /// Whether the chain is in true bypass, per the rule in the type's documentation.
    public var isBypassed: Bool { dg_bypassed(chain) != 0 }

    // MARK: - Processing

    /// The realtime path: processes `frameCount` frames in place across `channelCount` planar float
    /// buffers. Allocation-free, lock-free, and safe to call from a render block.
    ///
    /// `channels` is the planar layout `AVAudioPCMBuffer.floatChannelData` and `AudioBufferList`
    /// both use: `channels[c]` points at `frameCount` samples for channel `c`.
    public func processInPlace(_ channels: UnsafePointer<UnsafeMutablePointer<Float>?>,
                               channelCount: Int,
                               frameCount: Int) {
        dg_process(chain, channels, Int32(channelCount), Int32(frameCount))
    }

    /// The same, for the non-optional pointer shape `AVAudioPCMBuffer` hands out.
    public func processInPlace(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                               channelCount: Int,
                               frameCount: Int) {
        channels.withMemoryRebound(to: UnsafeMutablePointer<Float>?.self, capacity: channelCount) {
            dg_process(chain, $0, Int32(channelCount), Int32(frameCount))
        }
    }

    /// Offline use: processes `buffer` in place over its whole `frameLength`. The output is delayed
    /// by `latencyFrames` relative to the input; use `DegradeChain.rendered(_:settings:)` when that
    /// matters.
    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return }
        processInPlace(data, channelCount: channels, frameCount: frames)
    }

    /// One-shot offline bounce: runs `source` through a fresh chain and returns a new buffer of the
    /// same length, latency-compensated so sample *n* out corresponds to sample *n* in.
    ///
    /// Deterministic given `settings.seed`: the same source and the same settings produce the same
    /// bytes, which is what makes a bounce reproducible from a stored part version.
    public static func rendered(_ source: AVAudioPCMBuffer,
                                settings: DegradeSettings) throws -> AVAudioPCMBuffer {
        let format = source.format
        let channels = Int(format.channelCount)
        let frames = Int(source.frameLength)
        let chain = try DegradeChain(sampleRate: format.sampleRate,
                                     channelCount: channels,
                                     settings: settings)
        let latency = chain.latencyFrames
        let padded = frames + latency
        guard let work = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded)),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let src = source.floatChannelData,
              let dst = work.floatChannelData,
              let res = out.floatChannelData else {
            throw Failure.couldNotCreate(sampleRate: format.sampleRate, channelCount: channels)
        }
        work.frameLength = AVAudioFrameCount(padded)
        out.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            dst[c].update(from: src[c], count: frames)
            dst[c].advanced(by: frames).update(repeating: 0, count: latency)
        }
        chain.processInPlace(dst, channelCount: channels, frameCount: padded)
        for c in 0..<channels {
            res[c].update(from: dst[c].advanced(by: latency), count: frames)
        }
        return out
    }
}
