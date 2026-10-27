import AVFAudio
import CoreAudio
import Foundation

// M5 R2: the input side of the engine.
//
// A take is audio recorded while the transport plays, and the one thing it has to know that a
// file does not is *when it started* in the song. The recorder stamps the first buffer's time
// against the transport clock — host time when the engine is live, render sample time when it is
// offline — and folds the input and output latency in, so the take lands on the bar it was sung
// on rather than a few tens of milliseconds after it.
//
// The source is a protocol so the same recorder runs against the input node in the app and against
// a buffer stream in a test: what is tested is the alignment arithmetic and the file, which are
// the parts that go wrong.

/// Where recorded buffers come from.
public protocol RecordingSource: AnyObject {
    /// The buffers' format.
    var format: AVAudioFormat { get }
    /// Seconds between a sound reaching the input and its buffer being delivered, plus the output
    /// path's own delay when monitoring through the engine. Folded into the alignment.
    var latencySeconds: Double { get }
    /// A name for the take's record: the device, or what stood in for one.
    var name: String { get }
    /// Start delivering buffers, each with the time its first frame was captured.
    func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func end()
}

/// A device's input on an engine of its own, tapped — the whole device, or one of its channels as mono.
///
/// Not the playback engine's input node: on the Mac that node is the output's audio unit too, and
/// a device with no outputs set on it silenced the song (see `AudioDevices.point`). This engine only
/// listens, so any device will do, and its buffers carry host times the song's clock reads.
public final class InputNodeSource: RecordingSource {
    private let engine = AVAudioEngine()
    private let tapFormat: AVAudioFormat
    public let format: AVAudioFormat
    public let name: String
    public let latencySeconds: Double
    /// The channel kept, 0-based, or nil for every channel.
    public let channel: Int?

    /// - Parameters:
    ///   - device: the device listened to; nil is the system's default input.
    ///   - channel: one channel, 0-based, delivered as mono; nil keeps the device's format.
    ///   - deviceName: what the take's record says, e.g. "Scarlett 2i2".
    ///   - outputLatency: the playback engine's output delay — the song reaches the singer that late.
    public init(device: AudioDeviceID? = nil, channel: Int? = nil, deviceName: String = "Input", outputLatency: Double = 0) throws {
        guard let id = device ?? AudioDevices.defaultInputID() else { throw RecorderError.noInput }
        try AudioDevices.point(engine, at: id)
        let input = engine.inputNode
        // The device's own rate and channels, read once the engine is prepared: until then the
        // node reports the format it had before. AirPods say 48 kHz there and run their microphone
        // at 24, and a tap asked for at 48 threw "format mismatch" and took the app down. The
        // node's output side keeps the old device's format even then, and a tap at another rate
        // is never called.
        engine.prepare()
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let tap = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) else { throw RecorderError.noInput }
        tapFormat = tap
        var picked: Int?
        if let channel, tap.channelCount > 1, channel < Int(tap.channelCount) { picked = channel }
        self.channel = picked
        format = picked == nil ? tap : (AVAudioFormat(standardFormatWithSampleRate: tap.sampleRate, channels: 1) ?? tap)
        name = picked.map { "\(deviceName), input \($0 + 1)" } ?? deviceName
        latencySeconds = input.presentationLatency + outputLatency
    }

    public func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let channel = self.channel
        let mono = format
        // A device that has changed its rate or channels since it was chosen — a headset switched
        // to its microphone's rate, another plugged in under the same name — is refused rather
        // than tapped: a tap at a format the node no longer has is an exception, not an error.
        engine.prepare()
        let now = engine.inputNode.inputFormat(forBus: 0)
        guard now.sampleRate == tapFormat.sampleRate, now.channelCount == tapFormat.channelCount else {
            throw RecorderError.inputUnavailable("it runs at \(Int(now.sampleRate)) Hz with \(now.channelCount) channel\(now.channelCount == 1 ? "" : "s") now, not the \(Int(tapFormat.sampleRate)) Hz it was chosen at; choose it again")
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { buffer, time in
            if let channel, let picked = ChannelPick.mono(buffer, channel: channel, format: mono) {
                sink(picked, time)
            } else {
                sink(buffer, time)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw RecorderError.inputUnavailable("\(error)")
        }
    }

    public func end() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// One channel of a buffer as a mono buffer.
public enum ChannelPick {
    public static func mono(_ buffer: AVAudioPCMBuffer, channel: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let data = buffer.floatChannelData, channel < Int(buffer.format.channelCount),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        guard let target = out.floatChannelData else { return nil }
        target[0].update(from: data[channel], count: Int(buffer.frameLength))
        return out
    }
}

/// A source narrowed to one channel of another, for a test or a file.
public final class ChannelSource: RecordingSource {
    private let inner: any RecordingSource
    public let channel: Int
    public let format: AVAudioFormat
    public var latencySeconds: Double { inner.latencySeconds }
    public let name: String

    public init(_ inner: any RecordingSource, channel: Int) {
        self.inner = inner
        self.channel = channel
        format = AVAudioFormat(standardFormatWithSampleRate: inner.format.sampleRate, channels: 1) ?? inner.format
        name = "\(inner.name), input \(channel + 1)"
    }

    public func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let channel = self.channel, mono = format
        try inner.begin { buffer, time in
            if let picked = ChannelPick.mono(buffer, channel: channel, format: mono) { sink(picked, time) }
        }
    }

    public func end() { inner.end() }
}

/// Buffers handed in by a test, each with its capture time, delivered on `begin`.
public final class BufferSource: RecordingSource {
    public let format: AVAudioFormat
    public let latencySeconds: Double
    public let name: String
    private let buffers: [(AVAudioPCMBuffer, AVAudioTime)]

    public init(_ buffers: [(AVAudioPCMBuffer, AVAudioTime)], latencySeconds: Double = 0, name: String = "Buffers") throws {
        guard let first = buffers.first else { throw RecorderError.noInput }
        format = first.0.format
        self.buffers = buffers
        self.latencySeconds = latencySeconds
        self.name = name
    }

    public func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        for (buffer, time) in buffers { sink(buffer, time) }
    }

    public func end() {}
}

public enum RecorderError: Error, CustomStringConvertible {
    case noInput
    case alreadyRecording
    case notRecording
    case unwritable(String)
    case inputUnavailable(String)

    public var description: String {
        switch self {
        case .noInput: return "There is no input to record from."
        case .inputUnavailable(let why): return "The input could not be opened: \(why)"
        case .alreadyRecording: return "Already recording."
        case .notRecording: return "Nothing is being recorded."
        case .unwritable(let why): return "The take could not be written: \(why)"
        }
    }
}

/// One take, written to disk while the transport plays.
public final class Recorder: @unchecked Sendable {

    /// What a finished take is.
    public struct Recording: Sendable, Equatable {
        public var url: URL
        public var sampleRate: Double
        public var channelCount: Int
        public var frames: AVAudioFramePosition
        public var duration: Double { Double(frames) / sampleRate }
        /// Transport seconds at which the first frame was *captured*, or nil when the first buffer
        /// carried no time the transport could place.
        public var capturedAt: Double?
        /// The source's latency, seconds.
        public var latencySeconds: Double
        /// Where the take's first frame belongs in the song: captured time less latency. This is
        /// the audio version's `alignmentOffset`.
        public var alignmentSeconds: Double? { capturedAt.map { $0 - latencySeconds } }
        public var input: String

        public init(url: URL, sampleRate: Double, channelCount: Int, frames: AVAudioFramePosition,
                    capturedAt: Double?, latencySeconds: Double, input: String) {
            self.url = url
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.frames = frames
            self.capturedAt = capturedAt
            self.latencySeconds = latencySeconds
            self.input = input
        }
    }

    private let source: any RecordingSource
    private let transport: Transport?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    private var capturedAt: Double?
    private var placedFirst = false
    private var writeError: Error?
    private var lastPeak: Float = 0

    /// The last buffer's peak, 0…1. A meter, read from any thread.
    public var peak: Float { lock.withLock { lastPeak } }

    /// - Parameters:
    ///   - source: where the buffers come from.
    ///   - transport: the running transport, so the first buffer's time becomes a song time. Nil
    ///     records without a place in the song.
    public init(source: any RecordingSource, transport: Transport?) {
        self.source = source
        self.transport = transport
    }

    public var isRecording: Bool { lock.withLock { file != nil } }

    /// Starts writing to `url` (a .wav or .caf, from the extension). Float32, the source's rate
    /// and channels.
    public func start(to url: URL) throws {
        try lock.withLock {
            guard file == nil else { throw RecorderError.alreadyRecording }
            let format = source.format
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw RecorderError.unwritable("\(error)")
            }
            self.file = file
            self.url = url
            frames = 0
            capturedAt = nil
            placedFirst = false
            writeError = nil
            lastPeak = 0
        }
        do {
            try source.begin { [weak self] buffer, time in
                self?.take(buffer, at: time)
            }
        } catch {
            // Nothing is coming: not recording, and the empty file is not a take.
            lock.withLock {
                self.file = nil
                self.url = nil
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func take(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.withLock {
            guard let file else { return }
            if !placedFirst {
                placedFirst = true
                capturedAt = Self.transportSeconds(of: time, transport: transport, sampleRate: buffer.format.sampleRate)
            }
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            } catch {
                writeError = error
            }
            if let data = buffer.floatChannelData, buffer.frameLength > 0 {
                var peak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][i])) }
                }
                lastPeak = peak
            }
        }
    }

    /// Where a capture time sits in the song.
    static func transportSeconds(of time: AVAudioTime, transport: Transport?, sampleRate: Double) -> Double? {
        guard let transport else { return nil }
        if time.isHostTimeValid, let seconds = transport.clock.seconds(forHostTime: time.hostTime) { return seconds }
        if time.isSampleTimeValid {
            let rate = time.sampleRate > 0 ? time.sampleRate : sampleRate
            return Double(time.sampleTime - transport.originSampleTime) / rate
        }
        return nil
    }

    /// A recorder let go while it was still recording — its surface closed mid-take — ends its
    /// source. The input's tap stayed installed otherwise, and the next take's tap on the same bus
    /// was refused.
    deinit {
        let running = lock.withLock { file != nil }
        if running { source.end() }
    }

    /// Stops, closes the file and says what was recorded.
    @discardableResult
    public func stop() throws -> Recording {
        source.end()
        return try lock.withLock {
            guard let file, let url else { throw RecorderError.notRecording }
            let recording = Recording(url: url, sampleRate: file.processingFormat.sampleRate,
                                      channelCount: Int(file.processingFormat.channelCount), frames: frames,
                                      capturedAt: capturedAt, latencySeconds: source.latencySeconds, input: source.name)
            self.file = nil
            self.url = nil
            if let writeError { throw RecorderError.unwritable("\(writeError)") }
            return recording
        }
    }
}
