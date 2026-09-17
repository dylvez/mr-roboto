import AVFAudio
import Foundation

/// A drawable summary of a whole file: one low/high pair per horizontal pixel bucket.
///
/// Peaks are computed once, off the main actor, from the decoded file. A three-minute track at
/// 44.1 kHz is about eight million frames and the surface draws perhaps a thousand columns, so the
/// waveform the view holds is four orders of magnitude smaller than the audio — which is the only
/// reason a surface can hold it at all.
public struct ImportWaveform: Sendable, Equatable {

    /// The extremes of one bucket of frames, in -1…1.
    public struct Peak: Sendable, Equatable, Hashable {
        public var low: Float
        public var high: Float

        public init(low: Float, high: Float) {
            self.low = low
            self.high = high
        }

        /// Half the bucket's peak-to-peak height, which is what a symmetric waveform draws.
        public var magnitude: Float { max(abs(low), abs(high)) }
    }

    public var peaks: [Peak]
    /// Seconds of audio the peaks span.
    public var duration: Double

    public init(peaks: [Peak], duration: Double) {
        self.peaks = peaks
        self.duration = duration
    }

    public static let empty = ImportWaveform(peaks: [], duration: 0)

    public var isEmpty: Bool { peaks.isEmpty }

    /// 0…1 across the waveform for a time in seconds.
    public func position(ofTime seconds: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    /// The time a 0…1 position along the waveform stands for.
    public func time(atPosition fraction: Double) -> Double {
        duration * min(1, max(0, fraction))
    }

    /// Reads `url` and reduces it to `buckets` low/high pairs, mixing channels to mono.
    ///
    /// Not `async`, and deliberately so: it is plain blocking work that the caller runs on a
    /// detached task. Making it `async` would only hide where the thread hop is.
    public static func read(_ url: URL, buckets: Int = 1_200) throws -> ImportWaveform {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ImportHostError.notAudio(path: url.path, reason: error.localizedDescription)
        }
        let format = file.processingFormat
        let frameCount = Int(file.length)
        guard frameCount > 0, format.sampleRate > 0 else { throw ImportHostError.emptyFile(path: url.path) }

        let bucketCount = max(1, min(buckets, frameCount))
        let framesPerBucket = Double(frameCount) / Double(bucketCount)
        var peaks = [Peak](repeating: Peak(low: 0, high: 0), count: bucketCount)

        // Read in chunks so a long file never lands in memory whole.
        let chunkFrames = AVAudioFrameCount(1 << 16)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw ImportHostError.notAudio(path: url.path, reason: "could not allocate a read buffer for \(format)")
        }
        let channelCount = Int(format.channelCount)
        var frameIndex = 0
        while frameIndex < frameCount {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer)
            } catch {
                throw ImportHostError.notAudio(path: url.path, reason: error.localizedDescription)
            }
            let read = Int(buffer.frameLength)
            guard read > 0 else { break }
            guard let channels = buffer.floatChannelData else { break }
            for frame in 0..<read {
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                value /= Float(max(1, channelCount))
                let bucket = min(bucketCount - 1, Int(Double(frameIndex + frame) / framesPerBucket))
                if value < peaks[bucket].low { peaks[bucket].low = value }
                if value > peaks[bucket].high { peaks[bucket].high = value }
            }
            frameIndex += read
        }

        return ImportWaveform(peaks: peaks, duration: Double(frameCount) / format.sampleRate)
    }
}
