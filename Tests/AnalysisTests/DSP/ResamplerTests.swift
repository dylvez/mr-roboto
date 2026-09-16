import AVFoundation
import Foundation
import Testing
@testable import Analysis

@Suite("Resampler")
struct ResamplerTests {
    /// Stereo 48 kHz buffer: left = 1 kHz sine at 0.5, right = the same sine at 0.3.
    private func stereo48k(seconds: Double = 1) -> AVAudioPCMBuffer {
        let sr = 48000.0
        let n = Int(sr * seconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let s = Float(sin(2 * Double.pi * 1000 * Double(i) / sr))
            buffer.floatChannelData![0][i] = 0.5 * s
            buffer.floatChannelData![1][i] = 0.3 * s
        }
        return buffer
    }

    @Test("downmixes and resamples 48 kHz stereo to 44.1 kHz mono")
    func stereo48kToMono44k() throws {
        let buffer = stereo48k()
        let out = try Resampler().monoSamples(from: buffer)
        let expected = 44100
        #expect(abs(out.count - expected) <= 64, "got \(out.count) samples")
        // Mono of 0.5 and 0.3 sines is a 0.4 sine: RMS 0.4 / sqrt(2).
        let interior = Array(out[2000..<(out.count - 2000)])
        #expect(abs(rms(interior) - 0.4 / 2.0.squareRoot()) < 0.01)
        // Frequency is preserved: count zero crossings ~ 2 * 1000 per second.
        var crossings = 0
        for i in 1..<interior.count where (interior[i - 1] < 0) != (interior[i] < 0) { crossings += 1 }
        let seconds = Double(interior.count) / 44100
        #expect(abs(Double(crossings) / seconds - 2000) < 20)
    }

    @Test("same-rate input is only downmixed")
    func sameRate() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        buffer.frameLength = 10
        for i in 0..<10 {
            buffer.floatChannelData![0][i] = Float(i)
            buffer.floatChannelData![1][i] = Float(-i)
        }
        let out = try Resampler().monoSamples(from: buffer)
        #expect(out == [Float](repeating: 0, count: 10))
    }

    @Test("int16 interleaved buffers are converted")
    func int16Interleaved() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let data = buffer.int16ChannelData![0]
        for i in 0..<4 { data[2 * i] = 16384; data[2 * i + 1] = 0 }
        let out = try Resampler().monoSamples(from: buffer)
        #expect(out.count == 4)
        for v in out { #expect(abs(v - 0.25) < 1e-4) }
    }

    @Test("reads the Arrival drum stem as 44.1 kHz mono")
    func drumStem() throws {
        try #require(DSPFixtures.exists(DSPFixtures.arrivalDrums), "drum stem fixture missing")
        let samples = try Resampler().monoSamples(fromFileAt: DSPFixtures.arrivalDrums)
        let seconds = Double(samples.count) / 44100
        #expect(abs(seconds - 164.96) < 0.05)
        #expect(rms(samples) > 0.01)
    }
}
