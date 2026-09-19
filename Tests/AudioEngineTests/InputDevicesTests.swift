import AVFAudio
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
