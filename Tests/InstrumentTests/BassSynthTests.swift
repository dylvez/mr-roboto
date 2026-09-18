import AVFoundation
import Foundation
import Testing
@testable import Instrument

/// B1: a bass in the machine. The pitch is measured, not trusted; the note-off is measured too.
///
/// The demo (`BASS_DEMO=1 swift test --filter bassDemo`) writes Demos/bass/ for ears.
@Suite("Bass synthesis")
struct BassSynthTests {
    static let sr: Double = 48_000

    /// Pitch of a render over `window`, by a fine DFT scan around the expected frequency.
    static func pitch(_ samples: [Float], expected: Double, window: Range<Int>) -> Double {
        SynthMeasure.dominantFrequency(samples, in: window, band: (expected * 0.97)...(expected * 1.03),
                                       sampleRate: sr, resolution: expected * 0.0002)
    }

    static func cents(_ measured: Double, _ expected: Double) -> Double { 1200 * log2(measured / expected) }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func kit(_ spec: BassVoiceSpec) throws -> (LoadedKit, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bass-\(spec.id)-\(UUID().uuidString)", isDirectory: true)
        return (try SynthesizedBass.build(spec, in: folder, sampleRate: sr), folder)
    }

    // MARK: The generators

    @Test("both voices play G2 within 2 cents of 98 Hz", arguments: BassVoiceSpec.all)
    func pitchIsExact(spec: BassVoiceSpec) {
        let g2 = 43
        let expected = 440 * pow(2, Double(g2 - 69) / 12)
        let samples = BassSynthesizer.render(spec, midi: g2, velocity: 110, sampleRate: Self.sr)
        // After the sub's pitch drop has settled and before the note has decayed away.
        let window = Int(0.15 * Self.sr)..<Int(1.15 * Self.sr)
        let measured = Self.pitch(samples, expected: expected, window: window)
        let error = Self.cents(measured, expected)
        print("\(spec.id): G2 measured \(String(format: "%.3f", measured)) Hz, \(String(format: "%+.2f", error)) cents")
        #expect(abs(error) < 2, "\(spec.id) is \(error) cents off")
    }

    @Test("the sub starts above the note and falls to it; the string does not")
    func pitchDrop() {
        let e1 = 28
        let expected = 440 * pow(2, Double(e1 - 69) / 12)
        let sub = BassSynthesizer.render(.sub, midi: e1, velocity: 110, sampleRate: Self.sr)
        // The first 25 ms sit above the settled pitch. One period at E1 is 24 ms, so measure
        // the first 40 ms against the last second.
        let early = SynthMeasure.dominantFrequency(sub, in: 0..<Int(0.04 * Self.sr), band: expected...(expected * 1.6),
                                                   sampleRate: Self.sr, resolution: 0.25)
        #expect(early > expected * 1.05, "sub should start sharp; measured \(early) vs \(expected)")
        let finger = BassSynthesizer.render(.finger, midi: e1, velocity: 110, sampleRate: Self.sr)
        let fingerEarly = Self.pitch(finger, expected: expected, window: Int(0.05 * Self.sr)..<Int(0.55 * Self.sr))
        #expect(abs(Self.cents(fingerEarly, expected)) < 5)
    }

    @Test("decay lands near the spec's T60", arguments: BassVoiceSpec.all)
    func decay(spec: BassVoiceSpec) {
        let samples = BassSynthesizer.render(spec, midi: 40, velocity: 110, sampleRate: Self.sr)
        let t60 = SynthMeasure.decayTime(samples, toDB: 60, sampleRate: Self.sr)
        print("\(spec.id): T60 \(String(format: "%.2f", t60)) s (spec \(spec.decaySeconds))")
        // The string's loop average darkens as it decays, so its T60 reads a little long; the sub
        // is saturated, which reads a little short. Half an octave of tolerance either way.
        #expect(t60 > spec.decaySeconds * 0.6 && t60 < spec.decaySeconds * 1.8)
    }

    // MARK: Through the sampler

    @Test("a transposed note through the kit is in tune, and a note-off ends it on time",
          arguments: BassVoiceSpec.all)
    func throughTheSampler(spec: BassVoiceSpec) throws {
        let (kit, folder) = try Self.kit(spec)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(kit.manifest.zones.count == SynthesizedBass.roots.count)

        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
        let host = try OfflineHost(sampler: sampler, sampleRate: Self.sr, channels: 1)
        defer { host.stop(); sampler.unprepare() }

        // A2 (45 is a root, so play A#2 = 46: one semitone up through the 45 root) held for half
        // a second, then Bb1 (34: four semitones under the 38 root) as a one-second note.
        host.startTransport()
        sampler.enqueue([
            .init(note: 46, velocity: 100, at: 0.1, duration: 0.5),
            .init(note: 34, velocity: 100, at: 1.5, duration: 1.0),
        ])
        let out = Signal.samples(try host.render(seconds: 3.2))

        let expectedHigh = 440 * pow(2, Double(46 - 69) / 12)
        let high = Self.pitch(out, expected: expectedHigh, window: Int(0.2 * Self.sr)..<Int(0.55 * Self.sr))
        #expect(abs(Self.cents(high, expectedHigh)) < 5, "A#2 through the A2 root: \(Self.cents(high, expectedHigh)) cents")

        let expectedLow = 440 * pow(2, Double(34 - 69) / 12)
        let low = Self.pitch(out, expected: expectedLow, window: Int(1.7 * Self.sr)..<Int(2.4 * Self.sr))
        #expect(abs(Self.cents(low, expectedLow)) < 5, "Bb1 through the D2 root: \(Self.cents(low, expectedLow)) cents")

        // The note-off at 0.6 s plus the release: by 0.6 + release + 20 ms the first note is gone,
        // more than 40 dB under what it was while sounding.
        let sounding = Self.rms(out[Int(0.3 * Self.sr)..<Int(0.5 * Self.sr)])
        let after = Int((0.6 + spec.releaseSeconds + 0.02) * Self.sr)
        let silent = Self.rms(out[after..<Int(1.45 * Self.sr)])
        #expect(silent < sounding * 0.01, "\(spec.id): after note-off \(20 * log10(silent / sounding)) dB")
    }

    // MARK: Demo

    @Test("demo", .enabled(if: ProcessInfo.processInfo.environment["BASS_DEMO"] != nil))
    func bassDemo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Demos/bass", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for spec in BassVoiceSpec.all {
            let kit = try SynthesizedBass.build(spec, in: root.appendingPathComponent("kit-\(spec.id)"), sampleRate: Self.sr)
            let sampler = VoiceSampler(cache: SampleCache())
            try sampler.prepare(kit, sampleRate: Self.sr, channels: 1)
            let host = try OfflineHost(sampler: sampler, sampleRate: Self.sr, channels: 1)
            defer { host.stop(); sampler.unprepare() }
            // A walking line up two octaves, then a Dm7 → G7 phrase at 92 bpm with the note-offs
            // on the beat (R8): each note starts a sixteenth early and ends exactly on its beat.
            var hits: [VoiceSampler.Hit] = []
            for (i, note) in [28, 31, 33, 35, 36, 38, 40, 43, 45, 47, 48, 50, 52].enumerated() {
                hits.append(.init(note: note, velocity: 100, at: Double(i) * 0.3, duration: 0.25))
            }
            let beat = 60.0 / 92
            let phrase = [(38, 0.0), (45, 1.5), (38, 2.0), (41, 3.0), (43, 4.0), (43, 5.5), (47, 6.0), (42, 7.5)]
            for (note, beatAt) in phrase {
                let start = 4.2 + beatAt * beat - beat / 4
                hits.append(.init(note: note, velocity: 104, at: start, duration: beat / 4 + beat * 0.6))
            }
            host.startTransport()
            sampler.enqueue(hits.sorted { $0.time < $1.time })
            var samples = Signal.samples(try host.render(seconds: 12))
            let peak = SynthMeasure.peak(samples)
            if peak > 0 { let s = Float(pow(10, -1.0 / 20)) / peak; for i in samples.indices { samples[i] *= s } }
            let float = root.appendingPathComponent("float-\(spec.id).wav")
            try SynthesizedKit.writeWAV(samples, to: float, sampleRate: Self.sr)
            let url = root.appendingPathComponent("\(spec.id)-bass.wav")
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "WAVE", "-d", "LEI16", float.path, url.path]
            try convert.run(); convert.waitUntilExit()
            try? FileManager.default.removeItem(at: float)
            print("  afplay '\(url.path)'   # \(spec.name) bass: a walk up, then Dm7–G7 at 92 with note-offs on the beat")
        }
    }
}
