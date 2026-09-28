import AVFoundation
import Foundation
import SongGraph
import Testing
@testable import Instrument

/// Recordings standing in for a kit's hand percussion: in the voice's place, on its key, at its
/// loudness, and only when a set is in use.
@Suite("Recorded percussion")
struct RecordedPercussionTests {
    /// A two-layer "conga" on key 60: a soft and a hard decaying tone, the hard one 12 dB louder.
    static func recording(in directory: URL) throws {
        let folder = directory.appendingPathComponent("test-conga", isDirectory: true)
        for (name, amplitude) in [("soft", Float(0.2)), ("hard", Float(0.8))] {
            let samples = (0..<24_000).map { i in amplitude * sin(Float(i) * 2 * .pi * 330 / 48_000) * exp(-Float(i) / 6_000) }
            try SynthesizedKit.writeWAV(samples, to: folder.appendingPathComponent("samples/\(name).wav"), sampleRate: 48_000)
        }
        let manifest = KitManifest(name: "Test Conga", kind: .sampled, zones: [
            // With an SFZ's own volume on each, as VCSL raises its quiet recordings.
            Zone.drum(id: "soft", sample: "samples/soft.wav", note: 60, velocity: 1...63, gainDB: 20),
            Zone.drum(id: "hard", sample: "samples/hard.wav", note: 60, velocity: 64...127, gainDB: 14),
        ])
        _ = try KitStore.save(manifest, to: folder)
    }

    static func loudness(_ url: URL, gainDB: Float) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let gain = pow(10, gainDB / 20)
        let samples = (0..<Int(buffer.frameLength)).map { buffer.floatChannelData![0][$0] * gain }
        return KitLevel.loudness(samples, sampleRate: file.processingFormat.sampleRate)
    }

    @Test("a recording plays its voice in every kit, on the voice's key, each layer at the voice's loudness")
    func replacesTheVoice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.recording(in: directory)
        let set = RecordedPercussion(name: "Test", assignments: [
            .init(kind: .highConga, source: "test-conga", note: 60, label: "a test conga")])
        let resolved = try #require(RecordedPercussion.resolve(set, in: directory))

        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        let withRecording = directory.appendingPathComponent("recorded", isDirectory: true)
        let before = try SynthesizedKit.build(.tr808, in: plain, sampleRate: 24_000, layerCount: 2, recorded: nil)
        let after = try SynthesizedKit.build(.tr808, in: withRecording, sampleRate: 24_000, layerCount: 2, recorded: resolved)

        let note = SynthVoiceKind.highConga.generalMIDINote
        let conga = after.manifest.zones.filter { $0.key == .note(note) }
        #expect(conga.count == 2 && conga.allSatisfy { $0.sample.hasPrefix("samples/recorded/test-conga/") })
        #expect(conga.map(\.velocity) == [1...63, 64...127])
        #expect(after.manifest.note(for: .highConga) == note)
        #expect(after.manifest.validate(resolvingSamplesAgainst: withRecording).isPlayable)

        // Both layers at the synthesized conga's loudness: the soft one brought up, the hard one down.
        let synthesized = try #require(before.manifest.zones.last { $0.key == .note(note) })
        let target = try Self.loudness(KitPath.resolve(synthesized.sample, in: plain), gainDB: synthesized.gainDB)
        for zone in conga {
            let loud = try Self.loudness(KitPath.resolve(zone.sample, in: withRecording), gainDB: zone.gainDB)
            #expect(abs(20 * log10(loud / target)) < 0.5, "\(zone.id) sits \(20 * log10(loud / target)) dB off the synthesized conga")
        }

        // Everything else is the machine's own, and the old perc still plays the shaker.
        let others = before.manifest.zones.filter { $0.key != .note(note) }.map(\.sample)
        #expect(after.manifest.zones.filter { $0.key != .note(note) }.map(\.sample) == others)
        #expect(after.manifest.note(for: .perc) == SynthVoiceKind.shaker.generalMIDINote)

        // A kit with a recording in it is another kit.
        #expect(SynthesizedKit.folderName(for: .tr808, recorded: resolved) != SynthesizedKit.folderName(for: .tr808, recorded: nil))
    }

    @Test("a set that is off, or whose recordings are gone, changes nothing; the set round-trips on disk")
    func offAndMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.recording(in: directory)
        var set = RecordedPercussion(name: "Test", assignments: [
            .init(kind: .highConga, source: "test-conga", note: 60, label: "a test conga"),
            .init(kind: .claves, source: "not-here", note: 60, label: "gone")])
        let resolved = try #require(RecordedPercussion.resolve(set, in: directory))
        #expect(resolved.set.assignments.map(\.kind) == [.highConga], "the missing recording is left out")
        set.isOn = false
        #expect(RecordedPercussion.resolve(set, in: directory) == nil)

        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(RecordedPercussion.self, from: data) == set)
    }
}
