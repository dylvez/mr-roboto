import Accelerate
import AVFoundation
import Foundation

/// Converts any `AVAudioFile` / `AVAudioPCMBuffer` to mono Float samples at a fixed rate
/// (44.1 kHz by default) so analysis code never has to care about source formats.
///
/// Channels are averaged (equal-weight downmix) before the rate conversion, which is done by
/// `AVAudioConverter` at maximum quality.
public struct Resampler: Sendable {
    public enum Error: Swift.Error, Sendable {
        case unsupportedFormat(String)
        case converterUnavailable
        case conversionFailed(String)
    }

    public var targetSampleRate: Double

    public init(targetSampleRate: Double = 44100) {
        self.targetSampleRate = targetSampleRate
    }

    /// Reads the whole file and returns mono samples at `targetSampleRate`.
    public func monoSamples(fromFileAt url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw Error.unsupportedFormat(format.description)
        }
        try file.read(into: buffer)
        return try monoSamples(from: buffer)
    }

    /// Downmixes and resamples an in-memory buffer.
    public func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let mono = try Resampler.mono(buffer)
        let sourceRate = buffer.format.sampleRate
        if sourceRate == targetSampleRate { return mono }
        return try resample(mono, from: sourceRate, to: targetSampleRate)
    }

    /// Equal-weight downmix to mono Float at the buffer's own sample rate.
    public static func mono(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let floatBuffer = try asFloat32Deinterleaved(buffer)
        let n = Int(floatBuffer.frameLength)
        let channels = Int(floatBuffer.format.channelCount)
        guard n > 0, let data = floatBuffer.floatChannelData else { return [] }
        var out = [Float](repeating: 0, count: n)
        if channels == 1 {
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data[0], count: n) }
            return out
        }
        for c in 0..<channels {
            vDSP_vadd(out, 1, data[c], 1, &out, 1, vDSP_Length(n))
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }

    // MARK: Internals

    /// `buffer` as Float32 deinterleaved: the buffer itself when it already is, else a converted copy.
    static func asFloat32Deinterleaved(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let src = buffer.format
        if src.commonFormat == .pcmFormatFloat32 && !src.isInterleaved {
            return buffer
        }
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate,
                                            channels: src.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dstFormat),
              let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: buffer.frameLength) else {
            throw Error.unsupportedFormat(src.description)
        }
        do {
            try converter.convert(to: out, from: buffer)
        } catch {
            throw Error.conversionFailed(String(describing: error))
        }
        return out
    }

    private func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw Error.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        guard let input = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw Error.converterUnavailable
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let ratio = targetRate / sourceRate
        let expected = Int((Double(samples.count) * ratio).rounded(.up))
        var output: [Float] = []
        output.reserveCapacity(expected + 64)

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }

        let chunk: AVAudioFrameCount = 1 << 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: chunk) else {
            throw Error.converterUnavailable
        }
        loop: while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let error { throw Error.conversionFailed(error.localizedDescription) }
            let produced = Int(outBuffer.frameLength)
            if produced > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: produced))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream, .error:
                break loop
            @unknown default:
                break loop
            }
            if produced == 0 { break }
        }
        return output
    }
}
