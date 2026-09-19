import AVFAudio
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

/// The engine's input node, tapped.
public final class InputNodeSource: RecordingSource {
    private let engine: AVAudioEngine
    public let format: AVAudioFormat
    public let name: String
    public let latencySeconds: Double

    public init(engine: AVAudioEngine) {
        self.engine = engine
        let input = engine.inputNode
        format = input.outputFormat(forBus: 0)
        name = "Input"
        latencySeconds = input.presentationLatency + engine.outputNode.presentationLatency
    }

    public func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            sink(buffer, time)
        }
    }

    public func end() {
        engine.inputNode.removeTap(onBus: 0)
    }
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

    public var description: String {
        switch self {
        case .noInput: return "There is no input to record from."
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
        try source.begin { [weak self] buffer, time in
            self?.take(buffer, at: time)
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
