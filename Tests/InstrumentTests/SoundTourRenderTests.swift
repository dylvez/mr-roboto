import Foundation
import Testing
@testable import Instrument

/// A listening tour of every built-in sound: each instrument playing a C major arpeggio and chord,
/// each bass a one-bar riff, each drum machine two bars of a beat. An automated shell here cannot
/// make sound, so this writes files for ears, with an index of where each sound starts.
///
/// Off by default. To run it:
///
///     SOUND_TOUR=1 swift test --filter soundTour
///
/// It writes to `Demos/sound-tour` in the repo (gitignored); `SOUND_TOUR_DIR` overrides it.
@Suite("Sound tour")
struct SoundTourRenderTests {
    static let sr: Double = 48_000

    @Test("sound tour", .enabled(if: ProcessInfo.processInfo.environment["SOUND_TOUR"] != nil))
    func soundTour() throws {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["SOUND_TOUR_DIR"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Demos/sound-tour", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Instruments: C4 E4 G4 C5 as eighths at 110 bpm, then the four together, held.
        var instruments = Tour()
        for spec in InstrumentVoiceSpec.all {
            let start = instruments.mark("\(spec.name) (\(spec.family))")
            let eighth = 60.0 / 110 / 2
            // At the level its kit is built to, so the tour is as loud as the app.
            let reference = InstrumentSynthesizer.render(spec, midi: 60, velocity: spec.velocityLayers.last!, sampleRate: Self.sr)
            let level = KitLevel.gains(reference: [60: reference], peaks: [60: SynthMeasure.peak(reference)],
                                       targetDBFS: KitLevel.instrumentDBFS, sampleRate: Self.sr)[60]!
            for (index, note) in [60, 64, 67, 72].enumerated() {
                instruments.add(InstrumentSynthesizer.render(spec, midi: note, velocity: 96, sampleRate: Self.sr, seconds: 0.9),
                                at: start + Double(index) * eighth, gain: level)
            }
            for note in [48, 60, 64, 67] {
                instruments.add(InstrumentSynthesizer.render(spec, midi: note, velocity: 88, sampleRate: Self.sr, seconds: 1.8),
                                at: start + 4 * eighth, gain: level * 0.6)
            }
            instruments.advance(to: start + 4 * eighth + 2.2)
        }
        try instruments.write(to: root, name: "instruments")

        // Basses: a bar of a riff in C at 96 bpm.
        var basses = Tour()
        for spec in BassVoiceSpec.all {
            let start = basses.mark("\(spec.name) (\(spec.family == .played ? "played" : "synth"))")
            let eighth = 60.0 / 96 / 2
            let riff: [(midi: Int, eighths: Double)] = [(36, 0), (36, 1.5), (43, 3), (46, 4), (36, 5), (48, 6.5)]
            let reference = BassSynthesizer.render(spec, midi: 38, velocity: 110, sampleRate: Self.sr)
            let level = KitLevel.gains(reference: [38: reference], peaks: [38: SynthMeasure.peak(reference)],
                                       targetDBFS: KitLevel.bassDBFS, sampleRate: Self.sr)[38]!
            for hit in riff {
                basses.add(BassSynthesizer.render(spec, midi: hit.midi, velocity: 104, sampleRate: Self.sr),
                           at: start + hit.eighths * eighth, gain: level, seconds: 1.2)
            }
            basses.advance(to: start + 8 * eighth + 0.8)
        }
        try basses.write(to: root, name: "basses")

        // Drum machines: the same two bars on each, at 96 bpm.
        var drums = Tour()
        for machine in SynthMachine.all {
            let start = drums.mark(machine.name)
            let step = 60.0 / 96 / 4
            let levels: [Character: Int] = ["X": 124, "x": 96, ".": 46]
            let pattern: [(SynthVoiceKind, String)] = [
                (.kick,      "X--x--X---x--X--X--x--X---x-----"),
                (.snare,     "----X-------X-.-----X----.--X---"),
                (.closedHat, "x.x.x.x.x.x.x.x.x.x.x.x.x.x.----"),
                (.openHat,   "----------------------------x---"),
                (.clap,      "----------------------------X---"),
                (.rim,       "---------.-----------.----------"),
                (.lowTom,    "------------------------------xx"),
                (.crash,     "X-------------------------------"),
            ]
            for (kind, steps) in pattern {
                guard let spec = machine.spec(for: kind) else { continue }
                for (index, c) in steps.enumerated() {
                    guard let velocity = levels[c] else { continue }
                    drums.add(DrumSynthesizer.render(spec, velocity: velocity, sampleRate: Self.sr),
                              at: start + Double(index) * step, gain: 0.45)
                }
            }
            drums.advance(to: start + 32 * step + 1.2)
        }
        try drums.write(to: root, name: "drum-machines")

        print("Sound tour written to \(root.path)")
    }

    /// One long mono buffer and the times each sound starts at.
    struct Tour {
        var samples: [Float] = []
        var cursor: Double = 0.4
        var index: [(seconds: Double, name: String)] = []

        mutating func mark(_ name: String) -> Double {
            index.append((cursor, name))
            return cursor
        }

        mutating func add(_ sound: [Float], at seconds: Double, gain: Float, seconds length: Double? = nil) {
            let start = Int(seconds * SoundTourRenderTests.sr)
            var count = length.map { min(sound.count, Int($0 * SoundTourRenderTests.sr)) } ?? sound.count
            count = max(0, count)
            if samples.count < start + count { samples += [Float](repeating: 0, count: start + count - samples.count) }
            let fade = min(count, Int(0.02 * SoundTourRenderTests.sr))
            for i in 0..<count {
                // A short fade where a note is cut, so a cut is not a click.
                let tail = count - i
                let shape: Float = length != nil && tail < fade ? Float(tail) / Float(fade) : 1
                samples[start + i] += sound[i] * gain * shape
            }
        }

        mutating func advance(to seconds: Double) { cursor = seconds }

        func write(to folder: URL, name: String) throws {
            var out = samples + [Float](repeating: 0, count: Int(0.5 * SoundTourRenderTests.sr))
            let peak = out.map(abs).max() ?? 0
            if peak > 0.95 { for i in out.indices { out[i] *= 0.95 / peak } }
            try SynthesizedKit.writeWAV(out, to: folder.appendingPathComponent("\(name).wav"), sampleRate: SoundTourRenderTests.sr)
            let lines = index.map { entry in
                String(format: "%d:%05.2f  %@", Int(entry.seconds) / 60, entry.seconds.truncatingRemainder(dividingBy: 60), entry.name)
            }
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }
}
