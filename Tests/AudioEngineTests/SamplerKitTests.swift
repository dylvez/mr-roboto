import Testing
import AVFAudio
import Foundation
@testable import AudioEngine

@Suite struct SamplerKitTests {
    static let kitNotes: [(note: UInt8, frequency: Double, name: String)] = [
        (36, 220, "36 kick.wav"),
        (38, 440, "38-snare.wav"),
        (42, 880, "hat.wav"),  // no number: assigned the next free note from baseNote 36 -> 37
    ]

    /// Three short sine bursts written as 16-bit WAVs into a temp folder.
    static func makeSyntheticKit(sampleRate: Double) throws -> URL {
        let dir = try Analysis.temporaryDirectory("kit")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for entry in kitNotes {
            let burst = AudioSynth.sineBurst(format: format, frequency: entry.frequency, duration: 0.5, amplitude: 0.8)!
            try Analysis.writeWAV(burst, to: dir.appendingPathComponent(entry.name))
        }
        return dir
    }

    @Test func fileNameNotes() {
        #expect(SamplerKit.noteNumber(inFileName: "36 kick.wav") == 36)
        #expect(SamplerKit.noteNumber(inFileName: "038-snare.aif") == 38)
        #expect(SamplerKit.noteNumber(inFileName: "hat.wav") == nil)
        #expect(SamplerKit.noteNumber(inFileName: "200.wav") == nil)
    }

    @Test @AudioActor func loadsKitAndScheduledNoteProducesSound() throws {
        let sr = 48_000.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let kitFolder = try Self.makeSyntheticKit(sampleRate: sr)
        let kit = SamplerKit(engine: engine)
        let mapping = try kit.load(folder: kitFolder)
        #expect(Set(mapping.keys) == [36, 37, 38])
        #expect(mapping[36]?.lastPathComponent == "36 kick.wav")
        #expect(mapping[37]?.lastPathComponent == "hat.wav")
        #expect(kit.mapping == mapping)
        #expect(kit.kitDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("038.aif").path) } == true)

        engine.add(kit)
        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 120))

        let onsetSeconds = 0.5
        kit.play(38, velocity: 110, at: onsetSeconds, duration: 0.4)
        #expect(kit.pendingEventCount == 2)

        let buffer = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(1.5 * sr))
        #expect(kit.pendingEventCount == 0)
        #expect(kit.scheduledEventCount == 2)
        let x = Analysis.samples(buffer)
        let onset = Int(onsetSeconds * sr)

        // Silent before the note, sound right after it.
        #expect(Analysis.maxAbs(x[0..<(onset - 1)]) < 1e-4)
        #expect(Analysis.maxAbs(x[onset..<(onset + 200)]) > 0.01)
        #expect(Analysis.maxAbs(x[(onset + 1000)..<(onset + 5000)]) > 0.1)

        // The right zone played: note 38 is the 440 Hz file, at its original pitch.
        let f = Analysis.estimateFrequency(x, in: (onset + 2000)..<(onset + 14_000), sampleRate: sr)
        #expect(abs(f - 440) < 10, "estimated \(f) Hz")
        engine.stop()
    }

    @Test @AudioActor func differentNotesPlayDifferentFiles() throws {
        let sr = 48_000.0
        let engine = try makeOfflineEngine(sampleRate: sr)
        let kit = SamplerKit(engine: engine)
        try kit.load(folder: try Self.makeSyntheticKit(sampleRate: sr))
        engine.add(kit)
        try engine.start()
        try engine.startTransport(clock: TransportClock(tempo: 120))
        kit.play(36, at: 0.0, duration: 0.3)
        kit.play(37, at: 1.0, duration: 0.3)
        let x = Analysis.samples(try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(2 * sr)))
        let f36 = Analysis.estimateFrequency(x, in: 2000..<12_000, sampleRate: sr)
        let f37 = Analysis.estimateFrequency(x, in: (48_000 + 2000)..<(48_000 + 12_000), sampleRate: sr)
        #expect(abs(f36 - 220) < 10, "note 36 -> \(f36) Hz")
        #expect(abs(f37 - 880) < 20, "note 37 -> \(f37) Hz")
        engine.stop()
    }

    @Test func emptyFolderIsRejected() async throws {
        let dir = try Analysis.temporaryDirectory("empty")
        let engine = try await makeOfflineEngine()
        let kit = await SamplerKit(engine: engine)
        await #expect(throws: EngineError.noAudioFiles(dir)) {
            try await kit.load(folder: dir)
        }
    }
}
