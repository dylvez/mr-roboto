import AVFAudio
import CoreAudio
import Foundation
import Testing

@testable import AudioEngine

// Inputs I1/I2: devices listed; one channel of a wider source records as mono.

@Suite("Inputs: the devices here, and one channel as mono", .serialized)
struct InputDevicesTests {
    private static let rate = 48_000.0

    /// Stereo: a tone on the left, silence on the right.
    private func stereo(_ frames: Int, phase: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 220 * Double(phase + i) / Self.rate))
            buffer.floatChannelData![1][i] = 0
        }
        return buffer
    }

    private func rms(of url: URL) throws -> (channels: Int, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var sum = 0.0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += Double(buffer.floatChannelData![0][i] * buffer.floatChannelData![0][i]) }
        return (Int(file.processingFormat.channelCount), (sum / Double(max(1, n))).squareRoot())
    }

    @Test("one channel of a stereo source is a mono take of that channel")
    @AudioActor
    func channelPick() async throws {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 1)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        try engine.start()
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: Self.rate)
        let transport = try engine.startTransport(clock: clock)
        let startFrame = transport.originSampleTime + clock.frame(forBar: 1)
        let buffers = (0..<3).map { i in (stereo(1_024, phase: i * 1_024), AVAudioTime(sampleTime: startFrame + AVAudioFramePosition(i * 1_024), atRate: Self.rate)) }

        for (channel, expectSound) in [(0, true), (1, false)] {
            let source = ChannelSource(try BufferSource(buffers, latencySeconds: 0.005, name: "Scarlett 2i2"), channel: channel)
            #expect(source.format.channelCount == 1)
            #expect(source.name == "Scarlett 2i2, input \(channel + 1)")
            let recorder = Recorder(source: source, transport: transport)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mono-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try recorder.start(to: url)
            let recording = try recorder.stop()
            #expect(recording.channelCount == 1 && recording.frames == 3 * 1_024)
            #expect(recording.input == "Scarlett 2i2, input \(channel + 1)")
            let read = try rms(of: url)
            #expect(read.channels == 1)
            #expect(expectSound ? read.rms > 0.3 : read.rms < 1e-6, "channel \(channel): rms \(read.rms)")
        }
    }

    @Test("ChannelPick keeps the channel asked for and refuses one the buffer lacks")
    func pick() throws {
        let mono = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = stereo(256, phase: 0)
        let left = try #require(ChannelPick.mono(buffer, channel: 0, format: mono))
        #expect(left.frameLength == 256 && left.floatChannelData![0][10] == buffer.floatChannelData![0][10])
        let right = try #require(ChannelPick.mono(buffer, channel: 1, format: mono))
        #expect(right.floatChannelData![0][10] == 0)
        #expect(ChannelPick.mono(buffer, channel: 2, format: mono) == nil)
    }

    /// Whether this Mac has a default output to play through and an input to listen to.
    private static var hasDevices: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let output = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0
        return output && !AudioDevices.inputs().isEmpty
    }

    /// Configuration changes posted for an engine, from whichever thread posts them.
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        /// How many came since the last take, and starts counting again.
        func take() -> Int { lock.withLock { defer { count = 0 }; return count } }
    }

    /// What a source delivered, from the tap's thread.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers = 0
        private var untimed = 0
        private var formats: Set<String> = []
        func add(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
            lock.withLock {
                buffers += 1
                if !time.isHostTimeValid { untimed += 1 }
                formats.insert("\(buffer.format.sampleRate)/\(buffer.format.channelCount)")
            }
        }
        var read: (buffers: Int, untimed: Int, formats: Set<String>) { lock.withLock { (buffers, untimed, formats) } }
    }

    // A USB mic and the MacBook's own microphone have no outputs. Set on the playback engine's
    // input node — one audio unit with its output on the Mac — either left the song unable to
    // start again: -10875, IsFormatSampleRateAndChannelCountValid(outputHWFormat).
    @Test("a take on any input here leaves the song playing and able to start again",
          .enabled(if: InputDevicesTests.hasDevices))
    @AudioActor
    func listeningLeavesPlayback() async throws {
        let engine = try Engine(playerCount: 1)
        // The system may stop the engine when the route changes — with Bluetooth headphones
        // connected, a microphone opening does — and says so. That is the system's, and the frame
        // says it when it happens; a stop with nothing said would be this app's.
        let changes = Changes()
        let watch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine.avEngine,
                                                           queue: nil) { _ in changes.add() }
        defer { NotificationCenter.default.removeObserver(watch) }
        try engine.start()
        for device in AudioDevices.inputs() {
            let source = try InputNodeSource(device: device.id, deviceName: device.name,
                                             outputLatency: engine.avEngine.outputNode.presentationLatency)
            #expect(source.format.sampleRate > 0 && Int(source.format.channelCount) == device.inputChannels, "\(device.name): \(source.format)")
            let heard = Heard()
            try source.begin { buffer, time in heard.add(buffer, time) }
            // A Bluetooth headset switching to its microphone, or a phone's over Continuity, can
            // take a second or more to deliver anything.
            for _ in 0..<30 where heard.read.buffers < 3 { try await Task.sleep(for: .milliseconds(100)) }
            source.end()
            let read = heard.read
            #expect(read.buffers > 0, "\(device.name): nothing came in")
            #expect(read.untimed == 0, "\(device.name): buffers with no host time")
            #expect(read.formats == ["\(source.format.sampleRate)/\(source.format.channelCount)"], "\(device.name): \(read.formats)")
            if !engine.isRunning {
                #expect(changes.take() > 0, "\(device.name) stopped the song, and nothing said the output changed")
                try engine.start()
            }
            #expect(engine.isRunning, "\(device.name) left the song unable to start again")
            _ = changes.take()
        }
        // A second Play.
        engine.stop()
        try engine.start()
        #expect(engine.isRunning)
        #expect(engine.avEngine.outputNode.outputFormat(forBus: 0).sampleRate > 0)
        engine.stop()
    }

    /// An input that will not open: a headset gone to another rate since it was chosen.
    private final class Refusing: RecordingSource {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let latencySeconds = 0.0
        let name = "Gone"
        func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
            throw RecorderError.inputUnavailable("it runs at 24000 Hz now")
        }
        func end() {}
    }

    @Test("an input that will not open is an error, not a take: the recorder is not recording and leaves no file")
    func refused() throws {
        let recorder = Recorder(source: Refusing(), transport: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RecorderError.self) { try recorder.start(to: url) }
        #expect(!recorder.isRecording)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: RecorderError.self) { try recorder.stop() }
    }

    @Test("the devices CoreAudio reports: every one has inputs, at most one is the default, a bogus UID is nobody")
    func devices() {
        let inputs = AudioDevices.inputs()
        #expect(inputs.allSatisfy { $0.inputChannels > 0 && !$0.uid.isEmpty })
        #expect(inputs.filter(\.isDefault).count <= 1)
        if let first = inputs.first, inputs.contains(where: \.isDefault) { #expect(first.isDefault) }
        #expect(AudioDevices.input(uid: "no-such-device-\(UUID().uuidString)") == nil)
        if let first = inputs.first { #expect(AudioDevices.input(uid: first.uid) == first) }
    }
}
