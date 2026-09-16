import SongGraph
import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// A temporary directory that removes itself when the test finishes with it.
struct TempDirectory {
    let url: URL

    init(_ name: String = "InstrumentTests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func file(_ relativePath: String) -> URL { KitPath.resolve(relativePath, in: url) }

    /// Writes an empty placeholder file (for tests that only care that a path resolves).
    @discardableResult
    func touch(_ relativePath: String) -> URL {
        let target = file(relativePath)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        return target
    }
}

enum Fixtures {
    /// A kit with two velocity layers on the snare, a three-way round robin on the hard layer and a
    /// four-slot round robin with a hole on the soft layer.
    static func roundRobinKit() -> KitManifest {
        var zones: [Zone] = [
            .drum(id: "snare_hard_1", sample: "snare_hard_1.wav", note: 38, velocity: 64...127, seqPosition: 1, seqLength: 3),
            .drum(id: "snare_hard_2", sample: "snare_hard_2.wav", note: 38, velocity: 64...127, seqPosition: 2, seqLength: 3),
            .drum(id: "snare_hard_3", sample: "snare_hard_3.wav", note: 38, velocity: 64...127, seqPosition: 3, seqLength: 3),
            // Positions 1, 2 and 4 of a declared four-slot set: position 3 is missing.
            .drum(id: "snare_soft_1", sample: "snare_soft_1.wav", note: 38, velocity: 1...63, seqPosition: 1, seqLength: 4),
            .drum(id: "snare_soft_2", sample: "snare_soft_2.wav", note: 38, velocity: 1...63, seqPosition: 2, seqLength: 4),
            .drum(id: "snare_soft_4", sample: "snare_soft_4.wav", note: 38, velocity: 1...63, seqPosition: 4, seqLength: 4),
        ]
        zones.append(.drum(id: "kick", sample: "kick.wav", note: 36))
        var manifest = KitManifest(name: "Round Robin Kit", zones: zones)
        manifest.setNote(36, for: .kick)
        manifest.setNote(38, for: .snare)
        return manifest
    }

    /// A manifest with every field set to something other than its default, for round-trip testing.
    static func fullyPopulatedKit() -> KitManifest {
        let drum = Zone(
            id: "drum",
            sample: "samples/kick hard.wav",
            key: .note(36),
            velocity: 64...127,
            seqPosition: 2,
            seqLength: 3,
            group: 1,
            offBy: 2,
            offMode: .normal,
            sampleStart: 64,
            sampleEnd: 44_100,
            gainDB: -3.5,
            pan: -0.25,
            tuneCents: 12.5,
            envelope: Envelope(delay: 0.01, attack: 0.002, hold: 0.03, decay: 0.25, sustain: 0.5, release: 0.125),
            loop: Loop(mode: .loopSustain, start: 1_000, end: 5_000)
        )
        let pitched = Zone(
            id: "pad",
            sample: "samples/pad.wav",
            key: .range(48...72, rootNote: 60),
            velocity: 1...63,
            envelope: .percussive(decay: 0.5, release: 0.25)
        )
        var manifest = KitManifest(
            name: "Everything Kit",
            description: "Every field populated.",
            kind: .hybrid,
            zones: [drum, pitched],
            velocityCurve: .table([0, 0.25, 0.5, 1]),
            voices: ["kick": 36],
            synthesis: SynthesizedVoiceSet()
        )
        manifest.setNote(38, for: .snare)
        return manifest
    }

    /// The hand-written `.sfz` the importer tests parse: group inheritance, `default_path`, round
    /// robin, choke groups, `offset`/`end`, Windows separators, comments, several opcodes per line,
    /// a value containing a space, and opcodes we do not support.
    static let sfzText = """
    // A small test kit.
    <control>
    default_path=samples/

    <group> lokey=36 hikey=36 pitch_keycenter=36 volume=-3 group=1 off_by=1
    ampeg_attack=0.001 ampeg_release=0.08
    <region> sample=kick 1.wav lovel=1 hivel=63 seq_position=1 seq_length=2
    <region> sample=kick 2.wav lovel=1 hivel=63 seq_position=2 seq_length=2
    <region> sample=kick_hard.wav lovel=64 hivel=127 volume=0 offset=64 end=44099 tune=-10 transpose=1 pan=-50

    <group> key=42 off_mode=normal loop_mode=loop_continuous loop_start=100 loop_end=2000 ampeg_sustain=50
    <region> sample=Hats\\closed.wav bend_up=200 xfin_lokey=20  // engine-specific opcodes
    <region> sample=Hats\\dead.wav end=-1

    <curve>
    v000=0
    """
}

// MARK: - Audio fixtures

enum AudioFixtures {
    /// Writes a WAV of `frames` frames whose sample at (channel, frame) is `generator(channel, frame)`.
    @discardableResult
    static func writeWAV(at url: URL, sampleRate: Double = 44_100, channels: AVAudioChannelCount = 1,
                         frames: Int = 1_024,
                         generator: (Int, Int) -> Float = { channel, frame in
                             sinf(Float(frame) * 0.01) * (channel == 0 ? 1 : 0.5)
                         }) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames { data[channel][frame] = generator(channel, frame) }
        }
        try file.write(from: buffer)
        return url
    }
}

// MARK: - Sample generators
//
// Every fixture the voice-sampler tests play is generated here and written as a float32 WAV at the
// render rate, so no resampling happens on load and nothing binary lives in the repo.

extension AudioFixtures {
    /// A sine that starts at zero, with a linear fade-out over its whole length.
    static func sine(frequency: Double, seconds: Double, sampleRate: Double,
                     amplitude: Float = 0.8, fadeOut: Bool = true) -> [Float] {
        let n = max(1, Int((seconds * sampleRate).rounded()))
        return (0..<n).map { i in
            let t = Double(i)
            let envelope = fadeOut ? (1 - t / Double(n)) : 1
            return amplitude * Float(envelope * sin(2 * .pi * frequency * t / sampleRate))
        }
    }

    /// A decaying cosine: its *first* sample is at full amplitude, so an onset test can assert the
    /// exact frame the voice starts on rather than "somewhere in the first few samples".
    static func cosineBurst(frequency: Double, seconds: Double, sampleRate: Double,
                            amplitude: Float = 0.8, decay: Double = 0.05) -> [Float] {
        let n = max(1, Int((seconds * sampleRate).rounded()))
        let tau = max(decay, 1e-5) * sampleRate
        return (0..<n).map { i in
            let t = Double(i)
            return amplitude * Float(exp(-t / tau) * cos(2 * .pi * frequency * t / sampleRate))
        }
    }

    /// Deterministic white noise (a 64-bit LCG, so it is identical on every run and every machine).
    static func noise(seconds: Double, sampleRate: Double, amplitude: Float = 0.5,
                      seed: UInt64 = 0x2545F491_4F6CDD1D) -> [Float] {
        let n = max(1, Int((seconds * sampleRate).rounded()))
        var state = seed | 1
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24) * 2 - 1
            return amplitude * unit
        }
    }

    static func silence(seconds: Double, sampleRate: Double) -> [Float] {
        [Float](repeating: 0, count: max(1, Int((seconds * sampleRate).rounded())))
    }

    /// Writes mono float32 samples as a WAV at `sampleRate`.
    @discardableResult
    static func writeSamples(_ samples: [Float], to url: URL, sampleRate: Double) throws -> URL {
        try writeWAV(at: url, sampleRate: sampleRate, channels: 1, frames: max(1, samples.count)) { _, frame in
            frame < samples.count ? samples[frame] : 0
        }
    }

    /// Writes `samples` (relative path -> mono float32) into `folder` and returns the kit that
    /// `VoiceSampler.prepare(_:)` consumes. `kit.json` is written too, so the manifest goes through
    /// the real `KitStore` encode/decode path.
    static func kit(in folder: URL, name: String = "Test Kit", sampleRate: Double,
                    samples: [String: [Float]], zones: [Zone],
                    voices: [DrumVoice: Int] = [:],
                    velocityCurve: VelocityCurve = .squared) throws -> LoadedKit {
        for (path, data) in samples {
            try writeSamples(data, to: KitPath.resolve(path, in: folder), sampleRate: sampleRate)
        }
        var manifest = KitManifest(name: name, zones: zones, velocityCurve: velocityCurve)
        for (voice, note) in voices { manifest.setNote(note, for: voice) }
        return try KitStore.save(manifest, to: folder)
    }
}
