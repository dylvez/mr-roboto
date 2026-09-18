import Foundation
import Instrument
import SongGraph
import Testing
@testable import Performance

/// The listening test the Dilla feel is waiting on: is the snare late or early?
///
/// `Feels.lofiHipHop` pushes its snare *late* (+0.10 of a step). The Beatmaker persona's own
/// measured range for the Dilla lineage puts it *early* (−21 to −65 ms, typically −21). Both
/// readings have sources behind them (see `Feels+Idiom.swift`), so the decision is an ear's. This
/// renders the same two bars three ways — snare late, snare early, snare on the grid — with the
/// same kit, tempo and humanize seed, so the snare is the only thing that moves.
///
///     DILLA_DEMO=1 swift test --filter dillaDemo
///
/// Writes to Demos/dilla/ (gitignored). Same idiom as `SYNTH_DEMO` and `CHOP_DEMO`.
@Suite("Dilla demo")
struct DillaDemoTests {
    static let sr: Double = 48_000
    static let bpm: Double = 82

    /// ±21 ms at 82 bpm, in fractions of a sixteenth: the persona's typical Dilla figure, used in
    /// both directions so the A/B is symmetrical.
    static var offset: Double { 0.021 / (60 / bpm / 4) }

    @Test("snare late vs early", .enabled(if: ProcessInfo.processInfo.environment["DILLA_DEMO"] != nil))
    func dillaDemo() throws {
        let root = ChopPaths.repoRoot.appendingPathComponent("Demos/dilla", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kit = try SynthesizedKit.build(.linn, in: root.appendingPathComponent("kit", isDirectory: true),
                                           sampleRate: Self.sr)

        let takes: [(file: String, label: String, snare: Double)] = [
            ("A-snare-late.wav", "snare late — what the feel does now", Self.offset),
            ("B-snare-early.wav", "snare early — what the persona's measurements say", -Self.offset),
            ("C-snare-on-grid.wav", "snare on the grid — the reference", 0),
        ]
        print("")
        print("=== Dilla: snare late vs early, \(Int(Self.bpm)) bpm, LinnDrum, ±\(String(format: "%.0f", 0.021 * 1000)) ms ===")
        for take in takes {
            var feel = Feels.lofiHipHop
            feel.voices[.snare] = VoiceFeel(timingOffset: take.snare)
            let hits = GrooveRenderer.render(feel, on: .tempo(Self.bpm), repeats: 4, seed: 0x10F1_0001)
            let seconds = (hits.map(\.time).max() ?? 0) + 1.5
            let audio = try ChopRender.render(kit, hits: hits, seconds: seconds, sampleRate: Self.sr)
            let url = root.appendingPathComponent(take.file)
            // 16-bit, as every listening demo is: float WAVs carry padding chunks some players
            // stumble over, which once cost an afternoon of chasing a "click" that was the file.
            let float = root.appendingPathComponent("float-\(take.file)")
            try ChopAudio.writeWAV([ChopDemoTests.normalised(audio)], to: float, sampleRate: Self.sr)
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "WAVE", "-d", "LEI16", float.path, url.path]
            try convert.run()
            convert.waitUntilExit()
            try? FileManager.default.removeItem(at: float)
            print("  afplay '\(url.path)'   # \(take.label)")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        print("")
    }
}
