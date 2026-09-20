import Foundation
import Testing

@testable import Instrument

// The pitched instrument: it plays the note it was asked for, it does not alias at the top of the
// keyboard, and the two engines reach different places.

@Suite("Instrument: a voice that sustains and is played in chords")
struct InstrumentSynthesizerTests {
    private static let rate = 48_000.0

    private func render(_ spec: InstrumentVoiceSpec, midi: Int, velocity: Int = 110) -> [Float] {
        InstrumentSynthesizer.render(spec, midi: midi, velocity: velocity, sampleRate: Self.rate)
    }

    @Test("every preset plays the note it was given, within a few cents, across the keyboard",
          arguments: InstrumentVoiceSpec.all)
    func pitch(spec: InstrumentVoiceSpec) {
        for midi in [36, 60, 84] {
            let samples = render(spec, midi: midi)
            let expected = InstrumentSynthesizer.frequency(ofMIDI: midi)
            // Half a second, past the attack. Shorter than this and the analysis itself cannot
            // resolve the bottom of the keyboard: at 65 Hz a 200 ms window's bins are 5 Hz apart,
            // which reads a correct note as 4% flat.
            let window = Array(samples[Int(0.02 * Self.rate)..<Int(0.52 * Self.rate)])
            let found = SynthMeasure.dominantFrequency(window, in: 0..<window.count,
                                                       band: (expected * 0.45)...(expected * 2.2),
                                                       sampleRate: Self.rate, resolution: max(0.5, expected / 200))
            // An octave either way is still "the note": some voices put more energy in the
            // second harmonic than the first, which reads as the same pitch.
            let ratio = found / expected
            let onPitch = [1.0, 2.0, 0.5].contains { abs(ratio - $0) / $0 < 0.03 }
            #expect(onPitch, "\(spec.id) at MIDI \(midi): wanted \(Int(expected)) Hz, found \(Int(found)) Hz")
        }
    }

    @Test("the top of the keyboard does not alias: nothing appears below the fundamental")
    func noAliasing() {
        // A saw at C7 has its fundamental at 2093 Hz. A naive saw folds images back underneath it;
        // a band-limited one leaves that region empty.
        let spec = InstrumentVoiceSpec.juno
        let samples = render(spec, midi: 96)
        let window = Array(samples[Int(0.02 * Self.rate)..<Int(0.22 * Self.rate)])
        let fundamental = InstrumentSynthesizer.frequency(ofMIDI: 96)
        let below = SynthMeasure.magnitude(window, at: fundamental * 0.45, in: 0..<window.count, sampleRate: Self.rate)
        let at = SynthMeasure.magnitude(window, at: fundamental, in: 0..<window.count, sampleRate: Self.rate)
        #expect(at > below * 8, "fundamental \(at) against the region below it \(below)")
    }

    @Test("the envelopes do what they say: a pad swells, a pluck is gone before a pad has started")
    func envelopes() {
        func peakTime(_ spec: InstrumentVoiceSpec) -> Double {
            let samples = render(spec, midi: 60)
            let loudest = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
            return Double(loudest) / Self.rate
        }
        func energy(_ spec: InstrumentVoiceSpec, at seconds: Double) -> Float {
            let samples = render(spec, midi: 60)
            let start = min(samples.count - 1, Int(seconds * Self.rate))
            let end = min(samples.count, start + Int(0.05 * Self.rate))
            return start < end ? SynthMeasure.peak(Array(samples[start..<end])) : 0
        }
        #expect(peakTime(.warmPad) > 0.2, "a pad takes time to arrive")
        #expect(peakTime(.pluck) < 0.05, "a pluck is immediate")
        // Half a second in, the pluck has collapsed and the pad has not.
        #expect(energy(.pluck, at: 0.6) < energy(.warmPad, at: 0.6))
        #expect(energy(.organ, at: 2) > energy(.marimba, at: 2), "an organ holds, a marimba does not")
    }

    @Test("velocity opens the filter and drives the operators, so harder is brighter")
    func velocityIsBrightness() {
        for spec in [InstrumentVoiceSpec.rhodes, .pluck] {
            let soft = render(spec, midi: 60, velocity: 40)
            let hard = render(spec, midi: 60, velocity: 120)
            let window = Int(0.02 * Self.rate)..<Int(0.12 * Self.rate)
            let softSlice = Array(soft[window]), hardSlice = Array(hard[window])
            let softTone = SynthMeasure.spectralCentroid(softSlice, in: 0..<softSlice.count, sampleRate: Self.rate)
            let hardTone = SynthMeasure.spectralCentroid(hardSlice, in: 0..<hardSlice.count, sampleRate: Self.rate)
            #expect(hardTone > softTone, "\(spec.id): soft \(Int(softTone)) Hz, hard \(Int(hardTone)) Hz")
        }
    }

    @Test("FM reaches what subtractive cannot: a bell's partials are not whole multiples of its note")
    func inharmonic() {
        let fundamental = InstrumentSynthesizer.frequency(ofMIDI: 60)
        func partial(_ spec: InstrumentVoiceSpec, _ multiple: Double) -> Double {
            let samples = render(spec, midi: 60)
            let window = Array(samples[Int(0.01 * Self.rate)..<Int(0.31 * Self.rate)])
            return SynthMeasure.magnitude(window, at: fundamental * multiple, in: 0..<window.count, sampleRate: Self.rate)
        }
        // A carrier at 1 modulated at 3.51 puts its sidebands at 2.51 and 4.51, and the second
        // pair's carrier sits at 2.01. None of those is a whole multiple of the note.
        for multiple in [2.01, 2.51, 4.51] {
            #expect(partial(.bell, multiple) > partial(.bell, 3) * 20,
                    "the bell's \(multiple) partial should dwarf its third harmonic")
        }
        // A saw is the opposite shape: whole harmonics present, nothing between them.
        #expect(partial(.juno, 3) > partial(.juno, 2.51) * 3)
        #expect(partial(.juno, 4) > partial(.juno, 4.51) * 3)
    }

    @Test("a render is the same bytes twice, and nothing clips or goes non-finite",
          arguments: InstrumentVoiceSpec.all)
    func deterministicAndClean(spec: InstrumentVoiceSpec) {
        let once = render(spec, midi: 60)
        #expect(once == render(spec, midi: 60), "\(spec.id) is not deterministic")
        let finite = once.allSatisfy { $0.isFinite }
        let peak = SynthMeasure.peak(once)
        #expect(finite, "\(spec.id) produced a non-finite sample")
        #expect(peak <= 1, "\(spec.id) peaks at \(peak)")
        #expect(peak > 0.05, "\(spec.id) is nearly silent")
        // It ends at zero, so a note held to the edge of the render does not click.
        #expect(abs(once[once.count - 1]) < 0.001)
    }

    @Test("baked into a kit: zones cover the keyboard, never transposing far, with the velocity layers asked for")
    func bakesAKit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("instrument-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = InstrumentVoiceSpec.rhodes
        let kit = try SynthesizedInstrument.build(spec, in: folder, sampleRate: Self.rate)
        #expect(kit.manifest.zones.count == SynthesizedInstrument.roots.count * spec.velocityLayers.count)

        // Every note from C1 to C7 finds a zone at every velocity, and is never transposed far.
        for midi in 24...96 {
            for velocity in [30, 100] {
                let found = kit.manifest.zone(note: midi, velocity: velocity, roundRobin: 0)
                let zone = try #require(found, "nothing covers MIDI \(midi) at velocity \(velocity)")
                let distance = abs(midi - zone.key.rootNote)
                #expect(distance <= 2, "MIDI \(midi) transposes \(distance)")
            }
        }
        // The two layers split the velocity range and both are reachable.
        let roots = Set(kit.manifest.zones.map(\.key.rootNote))
        #expect(roots.count == SynthesizedInstrument.roots.count)
        #expect(Set(kit.manifest.zones.map(\.velocity)).count == 2)
        #expect(kit.manifest.zones.allSatisfy { $0.envelope.sustain == 1 }, "a pitched voice sustains")
    }
}

@Suite("Instrument: the presets are a usable set")
struct InstrumentPresetTests {
    @Test("ids are unique, every preset is reachable by id, and the families cover what a song needs")
    func theSet() {
        let all = InstrumentVoiceSpec.all
        #expect(Set(all.map(\.id)).count == all.count, "ids repeat")
        #expect(all.allSatisfy { InstrumentVoiceSpec.preset(id: $0.id)?.id == $0.id })
        #expect(InstrumentVoiceSpec.preset(id: "no-such-preset") == nil)
        let families = Set(all.map(\.family))
        #expect(families.isSuperset(of: ["keys", "pad", "pluck", "lead", "bell"]), "\(families)")
        #expect(all.contains { $0.engine == .fm } && all.contains { $0.engine == .subtractive })
    }

    @Test("every preset is well formed: it makes sound, and its envelopes are not nonsense", arguments: InstrumentVoiceSpec.all)
    func wellFormed(spec: InstrumentVoiceSpec) {
        switch spec.engine {
        case .subtractive:
            #expect(!spec.oscillators.isEmpty, "\(spec.id) has no oscillators")
            #expect(spec.oscillators.contains { $0.level > 0 }, "\(spec.id) is silent")
        case .fm:
            #expect(spec.operators.count == 4, "\(spec.id) has \(spec.operators.count) operators")
            #expect(spec.operators.contains { $0.level > 0 })
        }
        #expect(spec.durationSeconds >= 1 && spec.durationSeconds <= 10)
        #expect(spec.amplitude.attack >= 0 && spec.amplitude.release > 0)
        #expect((0...1).contains(spec.amplitude.sustain))
        #expect(spec.velocityLayers.allSatisfy { (1...127).contains($0) })
        #expect(spec.velocityLayers == spec.velocityLayers.sorted(), "layers must be in order")
        #expect(spec.level > 0 && spec.level <= 1)
    }
}
