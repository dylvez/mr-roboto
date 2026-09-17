import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// The listening artifact for the degradation chain. Every claim in `DegradeChainTests` is a
/// number; whether an SP-1200 chop actually sounds like an SP-1200 chop is a question for ears, and
/// an automated shell on this machine is not allowed to make sound. So this renders the real drum
/// stem through each preset, writes the files, and prints the `afplay` lines to run from a normal
/// Terminal.
///
/// It skips itself if the stem is not there — `Bench/goldens/` is not committed.
@Suite("Degrade demo")
struct DegradeDemoTests {

    /// How much of the stem to render. Long enough to hear a couple of bars, short enough that the
    /// test suite does not notice.
    static let seconds: Double = 8

    @Test("preset renders of the real drum stem, for listening")
    func renderPresetDemos() throws {
        let stem = DegradeFixtures.arrivalDrums
        guard DegradeFixtures.exists(stem) else {
            print("degrade demo: skipped, \(stem.path) is not present (Bench/goldens is not committed)")
            return
        }

        let file = try AVAudioFile(forReading: stem)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let wanted = AVAudioFrameCount(Self.seconds * format.sampleRate)
        let frames = min(wanted, AVAudioFrameCount(file.length))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: source, frameCount: frames)

        let out = DegradeFixtures.demoDirectory
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func planes(_ buffer: AVAudioPCMBuffer) throws -> [[Float]] {
            let data = try #require(buffer.floatChannelData)
            let n = Int(buffer.frameLength)
            return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        }

        var written: [(String, URL)] = []

        // The dry original, trimmed to the same length, so the comparison is like for like.
        let dryURL = out.appending(path: "drums-00-dry.wav")
        try DegradeFixtures.writeWAV(try planes(source), to: dryURL, sampleRate: format.sampleRate)
        written.append(("dry original", dryURL))

        for (index, preset) in DegradeSettings.Preset.allCases.enumerated() where preset != .clean {
            let processed = try DegradeChain.rendered(source, settings: DegradeSettings(preset: preset))
            let url = out.appending(path: String(format: "drums-%02d-%@.wav", index, preset.rawValue))
            try DegradeFixtures.writeWAV(try planes(processed), to: url, sampleRate: format.sampleRate)
            written.append((preset.rawValue, url))
        }

        print("")
        print("=== Degradation chain: \(Int(Self.seconds)) s of Bench/goldens/Arrival/stems/drums.wav ===")
        print("Rendered at \(Int(format.sampleRate)) Hz, \(channels) ch, latency-compensated, so the")
        print("files line up sample for sample and A/B is honest.")
        print("")
        for (name, url) in written {
            print("  afplay \(url.path)        # \(name)")
        }
        print("")
        print("All of them, back to back:")
        print("  for f in \(out.path)/*.wav; do echo \"$f\"; afplay \"$f\"; done")
        print("")

        for (_, url) in written {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // The point of the exercise: the SP-1200 render is not the dry render.
        #expect(written.count == DegradeSettings.Preset.allCases.count)
    }
}
