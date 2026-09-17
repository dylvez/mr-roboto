import AVFoundation
import Foundation
import SongGraph
import Testing
@testable import Instrument

/// The listening artifact. The real acceptance test for a drum voice is somebody's ears, and an
/// automated shell on this machine is not allowed to make sound, so this renders a demo bar of each
/// machine to WAV files and prints the paths for `afplay`.
///
/// Off by default. To run it, from a normal Terminal:
///
///     SYNTH_DEMO=1 swift test --filter synthDemoBars
///
/// It follows the same environment-variable idiom as the `DSP_TUNE` sweep in
/// `Tests/AnalysisTests/DSP/DrumStemOnsetTests.swift`.
@Suite("Synth demo")
struct SynthDemoRenderTests {
    static let sr: Double = 48_000
    static let bpm: Double = 108

    @Test("demo bars", .enabled(if: ProcessInfo.processInfo.environment["SYNTH_DEMO"] != nil))
    func synthDemoBars() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-roboto-synth-demo-\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        print("")
        print("=== Synthesized drum voices: demo bars ===")
        print("Rendered at \(Int(Self.sr)) Hz, \(Int(Self.bpm)) bpm.")
        print("")

        var written: [URL] = []
        for machine in SynthMachine.all {
            let kitFolder = root.appendingPathComponent("\(machine.id)-kit", isDirectory: true)
            let kit = try SynthesizedKit.build(machine, in: kitFolder, sampleRate: Self.sr)
            let url = root.appendingPathComponent("\(machine.id)-demo.wav")
            try Self.renderBar(kit: kit, to: url)
            written.append(url)
        }

        // One file per voice of the 808 too, so a single sound can be auditioned on its own.
        let voicesFolder = root.appendingPathComponent("tr808-voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voicesFolder, withIntermediateDirectories: true)
        var voiceFiles: [URL] = []
        for spec in SynthMachine.tr808.voices {
            var samples: [Float] = []
            // The same voice three times: soft, normal, accent — the thing velocity layers exist for.
            for velocity in [40, 90, 127] {
                samples += DrumSynthesizer.render(spec, velocity: velocity, sampleRate: Self.sr)
                samples += [Float](repeating: 0, count: Int(0.15 * Self.sr))
            }
            let url = voicesFolder.appendingPathComponent("\(spec.kind.fileStem).wav")
            try SynthesizedKit.writeWAV(samples, to: url, sampleRate: Self.sr)
            voiceFiles.append(url)
        }

        // What you should be hearing, measured from the same renders. Printed so an ear check and
        // the numbers in the presets can be compared without a spectrum analyser.
        print("Measured, per voice at velocity 110 (T60 of the whole voice, spectral centroid):")
        print(String(format: "  %-8s %-11s %9s %9s %9s", ("machine" as NSString).utf8String!,
                     ("voice" as NSString).utf8String!, ("T60 s" as NSString).utf8String!,
                     ("centroid" as NSString).utf8String!, ("peak" as NSString).utf8String!))
        for machine in SynthMachine.all {
            for spec in machine.voices {
                let x = DrumSynthesizer.render(spec, velocity: 110, sampleRate: Self.sr)
                let t60 = SynthMeasure.decayTime(x, toDB: 60, sampleRate: Self.sr)
                let window = 0..<min(x.count, Int(0.08 * Self.sr))
                let centroid = SynthMeasure.spectralCentroid(x, in: window, sampleRate: Self.sr)
                print("  \(machine.id.padding(toLength: 8, withPad: " ", startingAt: 0))"
                      + "\(spec.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))"
                      + String(format: "%9.3f%9.0f%9.3f", t60, centroid, Double(SynthMeasure.peak(x))))
            }
        }
        print("")

        print("Demo bars — play these first:")
        for url in written { print("  afplay \(url.path)") }
        print("")
        print("Every TR-808 voice on its own (soft / normal / accent):")
        for url in voiceFiles { print("  afplay \(url.path)") }
        print("")
        print("Generated kit folders (kit.json + samples/):")
        for machine in SynthMachine.all {
            print("  \(root.appendingPathComponent("\(machine.id)-kit").path)")
        }
        print("")
        print("Everything is under: \(root.path)")
        print("Remove it with: rm -rf \(root.path)")
        print("")

        for url in written { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    /// A two-bar pattern through the real sampler: the point is to hear the kit as it will actually
    /// be played, choke and all, not to hear one-shots concatenated.
    private static func renderBar(kit: LoadedKit, to url: URL) throws {
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(kit, sampleRate: sr, channels: 1)
        let host = try OfflineHost(sampler: sampler, sampleRate: sr, channels: 1)
        defer { host.stop(); sampler.unprepare() }

        let step = 60.0 / bpm / 4        // a sixteenth
        var hits: [VoiceSampler.Hit] = []
        func place(_ voice: DrumVoice, _ pattern: String, velocities: [Character: Int]) {
            for (i, c) in pattern.enumerated() {
                guard let velocity = velocities[c] else { continue }
                hits.append(.init(voice, velocity: velocity, at: Double(i) * step))
            }
        }
        // Two bars of sixteenths. `X` accent, `x` normal, `.` ghost, `-` rest.
        let levels: [Character: Int] = ["X": 124, "x": 96, ".": 46]
        place(.kick,      "X--x--X---x--X--X--x--X---x-----", velocities: levels)
        place(.snare,     "----X-------X-.-----X----.--X---", velocities: levels)
        place(.closedHat, "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.--", velocities: levels)
        place(.openHat,   "------------------------------x-", velocities: levels)
        place(.clap,      "----------------------------X---", velocities: levels)
        place(SynthVoiceKind.cowbell.drumVoice, "--------x-----------------------", velocities: levels)
        place(.lowTom,    "------------------------------.x", velocities: levels)
        place(.crash,     "X-------------------------------", velocities: levels)

        host.startTransport()
        sampler.enqueue(hits.sorted { $0.time < $1.time })
        let seconds = Double(32) * step + 2.5
        let buffer = try host.render(seconds: seconds)
        var samples = Signal.samples(buffer)
        // A conservative normalise so all three machines play back at a comparable level.
        let peak = SynthMeasure.peak(samples)
        if peak > 0 {
            let scale = Float(pow(10, -1.0 / 20)) / peak
            for i in samples.indices { samples[i] *= scale }
        }
        try SynthesizedKit.writeWAV(samples, to: url, sampleRate: sr)
    }
}
