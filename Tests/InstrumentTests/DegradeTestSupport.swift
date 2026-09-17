import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// Planar float buffers owned outright, so a test can hand the chain exactly the pointer shape a
/// render block would and still read the samples back as an array afterwards.
final class PlanarBuffer {
    let channelCount: Int
    let frameCount: Int
    private let planes: [UnsafeMutablePointer<Float>]

    init(channelCount: Int, frameCount: Int) {
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.planes = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            p.initialize(repeating: 0, count: frameCount)
            return p
        }
    }

    deinit {
        for p in planes {
            p.deinitialize(count: frameCount)
            p.deallocate()
        }
    }

    subscript(channel: Int) -> UnsafeMutablePointer<Float> { planes[channel] }

    func fill(_ generator: (_ channel: Int, _ frame: Int) -> Float) {
        for c in 0..<channelCount {
            for f in 0..<frameCount { planes[c][f] = generator(c, f) }
        }
    }

    func samples(_ channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: planes[channel], count: frameCount))
    }

    /// Runs the whole buffer through the chain in blocks, which is what a render callback does and
    /// what catches anything that only works when the whole signal arrives at once.
    func process(with chain: DegradeChain, blockSize: Int = 512) {
        var offset = 0
        while offset < frameCount {
            let n = min(blockSize, frameCount - offset)
            var pointers: [UnsafeMutablePointer<Float>?] = planes.map { $0 + offset }
            pointers.withUnsafeBufferPointer { buf in
                chain.processInPlace(buf.baseAddress!, channelCount: channelCount, frameCount: n)
            }
            offset += n
        }
    }
}

enum DegradeFixtures {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // InstrumentTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo

    static let arrivalDrums = repoRoot.appending(path: "Bench/goldens/Arrival/stems/drums.wav")

    /// Where the listening artifacts go. Under `.build`, which is already gitignored, so the files
    /// survive the test run and do not pollute the working tree.
    static let demoDirectory = repoRoot.appending(path: ".build/degrade-demo")

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// One channel of a sine, generated in double precision so the test's own signal is not the
    /// thing under measurement.
    static func sine(frequency: Double, amplitude: Double, frames: Int, sampleRate: Double) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Amplitude of `frequency` in `samples`, by direct correlation. A single-bin DFT: enough for
    /// "is the alias there and how loud", and immune to the windowing arguments an FFT would need.
    static func magnitude(of samples: ArraySlice<Float>, at frequency: Double, sampleRate: Double) -> Double {
        var re = 0.0
        var im = 0.0
        let w = 2 * Double.pi * frequency / sampleRate
        for (i, v) in samples.enumerated() {
            let t = w * Double(i)
            re += Double(v) * cos(t)
            im -= Double(v) * sin(t)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count)
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    /// Instantaneous frequency over time, from linearly interpolated upward zero crossings. This is
    /// how a pitch wobble is measured without trusting any of the DSP under test.
    static func zeroCrossingFrequencies(_ samples: [Float], sampleRate: Double, from start: Int) -> [Double] {
        var previous: Double?
        var out: [Double] = []
        var i = max(start, 0)
        while i < samples.count - 1 {
            if samples[i] <= 0, samples[i + 1] > 0 {
                let frac = Double(-samples[i]) / Double(samples[i + 1] - samples[i])
                let t = (Double(i) + frac) / sampleRate
                if let p = previous { out.append(1 / (t - p)) }
                previous = t
            }
            i += 1
        }
        return out
    }

    /// Largest jump between neighbouring samples — the measure of a click.
    static func largestStep(_ samples: [Float], from start: Int) -> Float {
        var worst: Float = 0
        var i = max(start, 1)
        while i < samples.count {
            worst = max(worst, abs(samples[i] - samples[i - 1]))
            i += 1
        }
        return worst
    }

    /// The `k / 2^(bits-1)` grid the chain's mid-tread quantiser lands on, with the signed
    /// converter's clamp at `[-steps, steps - 1]`.
    static func expectedQuantisation(_ x: Float, bits: Double) -> Float {
        let steps = Float(exp2(bits - 1))
        var q = (x * steps + 0.5).rounded(.down)
        q = min(max(q, -steps), steps - 1)
        return q / steps
    }

    static func writeWAV(_ planes: [[Float]], to url: URL, sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let channels = AVAudioChannelCount(planes.count)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = planes[0].count
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for c in 0..<planes.count {
            planes[c].withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
    }
}

/// A one-shot flag two threads can share without pulling in a dependency. Only ever goes false to
/// true, which is all the concurrency test needs.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
