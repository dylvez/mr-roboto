import Foundation
import SongGraph
import Testing
@testable import Instrument
@testable import Performance

/// A listening tour of what the percussion, styles and instruments pass added, for ears: the hand
/// percussion on three kinds of kit, every new feel on a kit, a section change with its fill, and
/// the new instruments. Off by default, like the sound tour:
///
///     NEW_SOUNDS=1 swift test --filter newSoundsTour
///
/// Writes `new-*.wav` and an index of where each sound starts to `Demos/sound-tour`.
@Suite("New sounds tour")
struct NewSoundsTourTests {
    static let sr: Double = 48_000

    @Test("new sounds tour", .enabled(if: ProcessInfo.processInfo.environment["NEW_SOUNDS"] != nil))
    func newSoundsTour() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Demos/sound-tour", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Hand percussion: each voice soft, medium, hard, on a played kit, the 808 and the LinnDrum.
        var percussion = Tour()
        for machine in [SynthMachine.studio, .tr808, .linn] {
            for kind in SynthVoiceKind.handPercussion {
                guard let spec = machine.spec(for: kind) else { continue }
                let start = percussion.mark("\(machine.name) \(kind.rawValue)")
                for (index, velocity) in [50, 90, 124].enumerated() {
                    percussion.add(DrumSynthesizer.render(spec, velocity: velocity, sampleRate: Self.sr),
                                   at: start + Double(index) * 0.3, gain: 0.5)
                }
                percussion.advance(to: start + 1.3)
            }
        }
        try percussion.write(to: root, name: "new-percussion")

        // The feels: the new styles and the Latin set, each twice through at its own tempo.
        var feels = Tour()
        for feel in Feels.styles + Feels.latin {
            let start = feels.mark("\(feel.name) — \(Int(feel.suggestedTempo)) bpm, \(feel.timeSignature)")
            let timeline = feel.timeline(at: feel.suggestedTempo, startingAt: start)
            feels.play(GrooveRenderer.render(feel.groove, on: timeline, options: .feel(feel, repeats: 2)),
                       on: .studio)
            let seconds = Double(feel.groove.bars * feel.timeSignature.beatsPerBar * 2) * 60 / feel.suggestedTempo
            feels.advance(to: start + seconds + 1)
        }
        try feels.write(to: root, name: "new-feels")

        // A section change: four bars of Standard Rock into four more, with the fill and the crash.
        var fills = Tour()
        if let rock = FeelLibrary.standard.feel(named: "Standard Rock") {
            let start = fills.mark("Standard Rock: a verse filling into a hook")
            let bar = 4 * 60 / rock.suggestedTempo
            let verse = SectionFill.arranged(rock.groove, bars: 4, beatsPerBar: 4, fillIntoNext: true, crashIn: false)
            let hook = SectionFill.arranged(rock.groove, bars: 4, beatsPerBar: 4, fillIntoNext: false, crashIn: true)
            fills.play(GrooveRenderer.render(verse, on: rock.timeline(at: rock.suggestedTempo, startingAt: start),
                                             options: .feel(rock)), on: .rock)
            fills.play(GrooveRenderer.render(hook, on: rock.timeline(at: rock.suggestedTempo, startingAt: start + 4 * bar),
                                             options: .feel(rock)), on: .rock)
            fills.advance(to: start + 8 * bar + 1)
        }
        try fills.write(to: root, name: "new-fills")

        // The instruments: an arpeggio and a chord each, and the log drum's riff.
        var instruments = Tour()
        for spec in [InstrumentVoiceSpec.grandPiano, .altoSax, .tenorSax, .overdrivenGuitar, .distortedGuitar] {
            let start = instruments.mark(spec.name)
            let eighth = 60.0 / 100 / 2
            let reference = InstrumentSynthesizer.render(spec, midi: 60, velocity: spec.velocityLayers.last!, sampleRate: Self.sr)
            let level = KitLevel.gains(reference: [60: reference], peaks: [60: SynthMeasure.peak(reference)],
                                       targetDBFS: KitLevel.instrumentDBFS, sampleRate: Self.sr)[60]!
            let low = spec.family == "wind" ? 48 : 55
            for (index, note) in [low, low + 4, low + 7, low + 12, low + 7, low + 4, low].enumerated() {
                instruments.add(InstrumentSynthesizer.render(spec, midi: note, velocity: 70 + index * 7, sampleRate: Self.sr,
                                                             seconds: 0.5), at: start + Double(index) * eighth, gain: level)
            }
            let chord = spec.family == "wind" ? [low + 12] : [low - 12, low - 5, low, low + 4]
            for note in chord {
                instruments.add(InstrumentSynthesizer.render(spec, midi: note, velocity: 100, sampleRate: Self.sr, seconds: 2),
                                at: start + 8 * eighth, gain: level * 0.7)
            }
            instruments.advance(to: start + 8 * eighth + 2.6)
        }
        let logDrum = BassVoiceSpec.logDrum
        let start = instruments.mark("Log Drum")
        let reference = BassSynthesizer.render(logDrum, midi: 38, velocity: 110, sampleRate: Self.sr)
        let level = KitLevel.gains(reference: [38: reference], peaks: [38: SynthMeasure.peak(reference)],
                                   targetDBFS: KitLevel.bassDBFS, sampleRate: Self.sr)[38]!
        let sixteenth = 60.0 / 112 / 4
        for (step, midi) in [(0, 38), (3, 38), (6, 45), (10, 41), (12, 43), (16, 38), (19, 38), (22, 45), (26, 48), (28, 43)] {
            instruments.add(BassSynthesizer.render(logDrum, midi: midi, velocity: 104, sampleRate: Self.sr),
                            at: start + Double(step) * sixteenth, gain: level, seconds: 0.9)
        }
        instruments.advance(to: start + 32 * sixteenth + 1)
        try instruments.write(to: root, name: "new-instruments")

        print("New sounds written to \(root.path)")
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
            let start = max(0, Int(seconds * NewSoundsTourTests.sr))
            let count = max(0, length.map { min(sound.count, Int($0 * NewSoundsTourTests.sr)) } ?? sound.count)
            if samples.count < start + count { samples += [Float](repeating: 0, count: start + count - samples.count) }
            let fade = min(count, Int(0.02 * NewSoundsTourTests.sr))
            for i in 0..<count {
                let tail = count - i
                let shape: Float = length != nil && tail < fade ? Float(tail) / Float(fade) : 1
                samples[start + i] += sound[i] * gain * shape
            }
        }

        /// Groove hits on a machine's voices; a voice the machine lacks is skipped.
        mutating func play(_ hits: [VoiceSampler.Hit], on machine: SynthMachine) {
            for hit in hits {
                guard let voice = hit.voice,
                      let kind = SynthVoiceKind.allCases.first(where: { $0.drumVoice == voice }),
                      let spec = machine.spec(for: kind) else { continue }
                add(DrumSynthesizer.render(spec, velocity: hit.velocity, sampleRate: NewSoundsTourTests.sr),
                    at: hit.time, gain: 0.45)
            }
        }

        mutating func advance(to seconds: Double) { cursor = seconds }

        func write(to folder: URL, name: String) throws {
            var out = samples + [Float](repeating: 0, count: Int(0.5 * NewSoundsTourTests.sr))
            let peak = out.map(abs).max() ?? 0
            if peak > 0.95 { for i in out.indices { out[i] *= 0.95 / peak } }
            try SynthesizedKit.writeWAV(out, to: folder.appendingPathComponent("\(name).wav"), sampleRate: NewSoundsTourTests.sr)
            let lines = index.map { entry in
                String(format: "%d:%05.2f  %@", Int(entry.seconds) / 60, entry.seconds.truncatingRemainder(dividingBy: 60), entry.name)
            }
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(name).txt"),
                                                            atomically: true, encoding: .utf8)
        }
    }
}
