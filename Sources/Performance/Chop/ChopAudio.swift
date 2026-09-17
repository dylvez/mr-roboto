import AVFoundation
import Foundation
import Instrument

/// Reading and writing the one WAV a chop lives in.
///
/// Float32 at the render rate on purpose, for the same reason the synthesized kits are: the bytes
/// the sampler reads are the bytes the chopper cut, with no resampling and no quantisation between
/// a render today and the same render tomorrow.
public enum ChopAudio {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedFormat(String)
        case writeFailed(path: String, reason: String)
        case readFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case .unsupportedFormat(let s): return "chop audio: unsupported format \(s)"
            case .writeFailed(let path, let reason): return "chop audio: cannot write \(path): \(reason)"
            case .readFailed(let path, let reason): return "chop audio: cannot read \(path): \(reason)"
            }
        }
    }

    /// Writes planar Float32 channels as a WAV, creating the enclosing folder.
    public static func writeWAV(_ planar: [[Float]], to url: URL, sampleRate: Double) throws {
        let channels = max(1, planar.count)
        let frames = planar.first?.count ?? 0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw Error.unsupportedFormat("\(channels) ch at \(sampleRate) Hz")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            // The `commonFormat`/`interleaved` initializer, not the two-argument one: with the
            // short form the processing format is chosen for us and the final partial block never
            // reaches the file — writing 102,720 frames and reading them back gave 102,400, so a
            // chop's last slice silently lost its tail.
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))) else {
                throw Error.writeFailed(path: url.path, reason: "could not allocate \(frames) frames")
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            if frames > 0, let data = buffer.floatChannelData {
                for c in 0..<channels {
                    let source = c < planar.count ? planar[c] : []
                    for i in 0..<frames { data[c][i] = i < source.count ? source[i] : 0 }
                }
            }
            try file.write(from: buffer)
            // Also not optional: without an explicit close the header is not finalised until the
            // object is released, and a read that follows in the same scope sees a length of 0.
            // `OfflineRenderer` closes its file for the same reason.
            file.close()
        } catch let error as Error {
            throw error
        } catch {
            throw Error.writeFailed(path: url.path, reason: "\(error)")
        }
    }

    /// Reads a file as planar Float32 at its own rate, keeping its channel count.
    public static func readPlanar(_ url: URL) throws -> (planar: [[Float]], sampleRate: Double) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return (Array(repeating: [], count: Int(format.channelCount)), format.sampleRate)
            }
            // `SampleCache.readAll`, not `file.read(into:frameCount:)`: one read call is a short
            // read on this toolchain and stops on a block boundary without throwing, which for a
            // chop is the last slice's tail going missing. The loop lives in `Instrument` because
            // the sample cache needs it for exactly the same reason.
            try SampleCache.readAll(file, into: buffer)
            guard let data = buffer.floatChannelData else {
                throw Error.readFailed(path: url.path, reason: "not float32")
            }
            let n = Int(buffer.frameLength)
            let stride = buffer.stride
            let planar = (0..<Int(format.channelCount)).map { c in
                (0..<n).map { data[c][$0 * stride] }
            }
            return (planar, format.sampleRate)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.readFailed(path: url.path, reason: "\(error)")
        }
    }

    /// Equal-weight downmix of planar channels.
    public static func mono(_ planar: [[Float]]) -> [Float] {
        guard let first = planar.first else { return [] }
        if planar.count == 1 { return first }
        let n = planar.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        for channel in planar {
            for i in 0..<n { out[i] += channel[i] }
        }
        let scale = 1 / Float(planar.count)
        for i in 0..<n { out[i] *= scale }
        return out
    }
}

