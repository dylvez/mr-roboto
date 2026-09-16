import AVFAudio
import Foundation

/// Small synthesized-buffer helpers used by the metronome and by tests.
public enum AudioSynth {
    /// A zeroed float32 buffer of `frames` frames with `frameLength` set.
    public static func silence(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else { return nil }
        buffer.frameLength = frames
        return buffer
    }

    /// Fill every channel of a float32 buffer with `sample(i)`.
    public static func fill(_ buffer: AVAudioPCMBuffer, _ sample: (Int) -> Float) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        var values = [Float](repeating: 0, count: n)
        for i in 0..<n { values[i] = sample(i) }
        for c in 0..<Int(buffer.format.channelCount) {
            let dst = channels[c]
            for i in 0..<n { dst[i * stride] = values[i] }
        }
    }

    /// A short click: an exponentially decaying cosine burst whose *first* sample is at
    /// full amplitude, so onset detectors find it on the exact scheduled frame.
    public static func click(format: AVAudioFormat, frequency: Double, duration: Double,
                             amplitude: Float, decay: Double) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(max(1, (duration * sr).rounded()))
        guard let buffer = silence(format: format, frames: frames) else { return nil }
        let tau = max(decay, 1e-5) * sr
        fill(buffer) { i in
            let t = Double(i)
            return amplitude * Float(exp(-t / tau) * cos(2 * .pi * frequency * t / sr))
        }
        return buffer
    }

    /// A sine burst with a linear fade-out over its whole length (a percussive "tone").
    public static func sineBurst(format: AVAudioFormat, frequency: Double, duration: Double,
                                 amplitude: Float = 0.8) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(max(1, (duration * sr).rounded()))
        guard let buffer = silence(format: format, frames: frames) else { return nil }
        let n = Double(frames)
        fill(buffer) { i in
            let t = Double(i)
            return amplitude * Float((1 - t / n) * sin(2 * .pi * frequency * t / sr))
        }
        return buffer
    }
}
