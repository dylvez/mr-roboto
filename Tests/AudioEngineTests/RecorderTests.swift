import AVFAudio
import Foundation
import Testing

@testable import AudioEngine

// M5 R2: the recorder places a take in the song and writes what it was given.

@Suite("Recorder: a take lands on the bar it was sung on", .serialized)
struct RecorderTests {
    private static let rate = 48_000.0

    private func sine(_ frames: Int, hz: Double, phase: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * hz * Double(phase + i) / Self.rate)) }
        return buffer
    }

    @Test("offline: buffers stamped with render sample times land at the transport bar, less latency")
    @AudioActor
    func offlineAlignment() async throws {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 1)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        try engine.start()
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: Self.rate)
        let transport = try engine.startTransport(clock: clock)

        // Three buffers from bar 3 (6 s at 120), 1024 frames each, in render sample time.
        let startFrame = transport.originSampleTime + clock.frame(forBar: 3)
        var buffers: [(AVAudioPCMBuffer, AVAudioTime)] = []
        for i in 0..<3 {
            buffers.append((sine(1_024, hz: 220, phase: i * 1_024), AVAudioTime(sampleTime: startFrame + AVAudioFramePosition(i * 1_024), atRate: Self.rate)))
        }
        let source = try BufferSource(buffers, latencySeconds: 0.012, name: "Test input")
        let recorder = Recorder(source: source, transport: transport)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try recorder.start(to: url)
        #expect(recorder.isRecording)
        let recording = try recorder.stop()
        #expect(!recorder.isRecording)
        #expect(recording.frames == 3 * 1_024)
        #expect(abs(recording.duration - 3 * 1_024 / Self.rate) < 1e-9)
        #expect(recording.capturedAt.map { abs($0 - 6.0) < 1 / Self.rate } == true, "\(recording.capturedAt ?? -1)")
        #expect(recording.alignmentSeconds.map { abs($0 - (6.0 - 0.012)) < 1 / Self.rate } == true)
        #expect(recording.input == "Test input")

        // The file holds the sine, contiguous across buffers.
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 3 * 1_024)
        let back = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: back)
        let expected = sine(3 * 1_024, hz: 220, phase: 0)
        var worst: Float = 0
        for i in 0..<Int(file.length) { worst = max(worst, abs(back.floatChannelData![0][i] - expected.floatChannelData![0][i])) }
        #expect(worst < 1e-6, "the recorded file differs from what was fed by \(worst)")
        engine.stopTransport()
        engine.stop()
    }

    @Test("a buffer with no placeable time records without a place, and stopping twice is an error")
    @AudioActor
    func unplaced() async throws {
        let source = try BufferSource([(sine(512, hz: 110, phase: 0), AVAudioTime(sampleTime: 0, atRate: Self.rate))])
        let recorder = Recorder(source: source, transport: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try recorder.start(to: url)
        let recording = try recorder.stop()
        #expect(recording.capturedAt == nil && recording.alignmentSeconds == nil)
        #expect(recording.frames == 512)
        #expect(throws: RecorderError.self) { try recorder.stop() }
    }

    @Test("a host-time stamp is placed against an anchored clock")
    func hostTime() {
        var clock = TransportClock(tempo: 100, sampleRate: Self.rate)
        clock.startHostTime = 1_000_000_000
        let transport = Transport(clock: clock, mode: .realtime, originSampleTime: 0)
        let at = clock.hostTime(forSeconds: 2.5)!
        let seconds = Recorder.transportSeconds(of: AVAudioTime(hostTime: at), transport: transport, sampleRate: Self.rate)
        #expect(seconds.map { abs($0 - 2.5) < 1e-6 } == true)
    }
}
