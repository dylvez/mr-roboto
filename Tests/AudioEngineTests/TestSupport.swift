import AVFAudio
import Foundation
@testable import AudioEngine

/// Signal-analysis helpers for the offline-render tests.
enum Analysis {
    /// Channel `channel` of a float32 buffer as an array.
    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        return (0..<n).map { data[channel][$0 * stride] }
    }

    /// Indices where |x| exceeds `threshold`.
    static func peaks(in x: [Float], above threshold: Float) -> [Int] {
        x.indices.filter { abs(x[$0]) > threshold }
    }

    /// Onsets: the first sample above `threshold` after at least `quietWindow` samples
    /// (or the start of the signal) below `quietLevel`.
    static func onsets(in x: [Float], threshold: Float, quietWindow: Int, quietLevel: Float) -> [Int] {
        var result: [Int] = []
        var quietRun = quietWindow  // treat the start as quiet
        for i in x.indices {
            let a = abs(x[i])
            if a > threshold, quietRun >= quietWindow {
                result.append(i)
                quietRun = 0
            } else if a < quietLevel {
                quietRun += 1
            } else {
                quietRun = 0
            }
        }
        return result
    }

    static func maxAbs(_ x: ArraySlice<Float>) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    /// Zero-crossing frequency estimate over `range`.
    static func estimateFrequency(_ x: [Float], in range: Range<Int>, sampleRate: Double) -> Double {
        var crossings = 0
        for i in (range.lowerBound + 1)..<range.upperBound where x[i - 1] < 0 && x[i] >= 0 {
            crossings += 1
        }
        return Double(crossings) * sampleRate / Double(range.count)
    }

    /// Read a whole PCM file into a float32 buffer.
    static func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))!
        if file.length > 0 { try file.read(into: buffer, frameCount: AVAudioFrameCount(file.length)) }
        return buffer
    }

    /// Write a float32 buffer as a 16-bit WAV.
    static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
    }

    /// A fresh temporary directory for one test.
    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEngineTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A mono offline engine ready to render at `sampleRate`.
@AudioActor
func makeOfflineEngine(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1,
                       playerCount: Int = 2, maximumFrames: AVAudioFrameCount = 4096) throws -> Engine {
    let engine = try Engine(playerCount: playerCount, sampleRate: sampleRate, channels: channels)
    try engine.prepare(offlineSampleRate: sampleRate, maximumFrames: maximumFrames)
    return engine
}

/// Thread-safe counter for completion callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }

    var recorded: [Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    /// Poll until `count >= expected` or the timeout elapses.
    func wait(for expected: Int, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
