import Foundation
import Testing

@testable import Instrument

// The pitched instrument: it plays the note it was asked for, it does not alias at the top of the
// keyboard, and the two engines reach different places.

@Suite("Instrument: a voice that sustains and is played in chords")
struct InstrumentSynthesizerTests {
    private static let rate = 48_000.0

    /// The preset's full length, or `seconds` of it: the per-preset checks look at the first
    /// second, and fifty presets rendered at five seconds each made the suite crawl.
    private func render(_ spec: InstrumentVoiceSpec, midi: Int, velocity: Int = 110, seconds: Double? = nil) -> [Float] {
        InstrumentSynthesizer.render(spec, midi: midi, velocity: velocity, sampleRate: Self.rate, seconds: seconds)
    }

    @Test("every preset plays the note it was given, within a few cents, across the keyboard",
          arguments: InstrumentVoiceSpec.all)
    func pitch(spec: InstrumentVoiceSpec) {
        for midi in [36, 60, 84] {
            let samples = render(spec, midi: midi, seconds: 0.6)
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
        let once = render(spec, midi: 60, seconds: 1.2)
        #expect(once == render(spec, midi: 60, seconds: 1.2), "\(spec.id) is not deterministic")
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
    @Test("a bank to choose from: fifty-odd instruments over twelve families, three engines")
    func aBank() {
        let all = InstrumentVoiceSpec.all
        #expect(all.count >= 50, "\(all.count)")
        #expect(Set(all.map(\.family)) == ["keys", "organ", "bell", "guitar", "plucked", "strings", "pad", "wind", "brass", "pluck", "lead", "chip"])
        #expect(Set(all.map(\.engine)) == Set(InstrumentVoiceSpec.Engine.allCases).subtracting([.sampled]), "every engine but an import's")
        #expect(BassVoiceSpec.all.count >= 15 && Set(BassVoiceSpec.all.map(\.id)).count == BassVoiceSpec.all.count)
        #expect(Set(BassVoiceSpec.all.map(\.family)) == Set(BassVoiceSpec.Family.allCases))
    }

    @Test("kits are levelled by how loud they sound, not by their attacks: a pluck, an organ and two basses land together")
    func levelled() {
        let rate = 48_000.0
        func level(_ renders: [Int: [Float]], target: Double) -> (loud: [Double], peak: Double) {
            let gains = KitLevel.gains(reference: renders, peaks: renders.mapValues(SynthMeasure.peak),
                                       targetDBFS: target, sampleRate: rate)
            let loud = renders.map { 20 * log10(KitLevel.loudness($0.value, sampleRate: rate) * Double(gains[$0.key]!)) }
            let peak = renders.map { 20 * log10(Double(SynthMeasure.peak($0.value) * gains[$0.key]!)) }.max()!
            return (loud, peak)
        }
        let roots = [36, 60, 84]
        var all: [Double] = []
        for spec in [InstrumentVoiceSpec.harpsichord, .organ, .rhodes] {
            let renders = Dictionary(uniqueKeysWithValues: roots.map { ($0, InstrumentSynthesizer.render(spec, midi: $0, velocity: spec.velocityLayers.last!, sampleRate: rate, seconds: 2)) })
            let (loud, peak) = level(renders, target: KitLevel.instrumentDBFS)
            #expect(peak <= KitLevel.ceilingDBFS + 0.01, "\(spec.id) peaks at \(peak) dBFS")
            all += loud
        }
        // Peak-normalised, the organ sat 14 dB over the harpsichord.
        #expect(all.max()! - all.min()! < 5, "instruments spread \(all.max()! - all.min()!) dB: \(all)")

        var basses: [Double] = []
        for spec in [BassVoiceSpec.finger, .sub] {
            let renders = Dictionary(uniqueKeysWithValues: [24, 38, 52].map {
                ($0, BassSynthesizer.render(spec, midi: $0, velocity: 110, sampleRate: rate))
            })
            let (loud, peak) = level(renders, target: KitLevel.bassDBFS)
            #expect(peak <= KitLevel.ceilingDBFS + 0.01)
            // A line walking down does not fade: every root of one bass within 3 dB.
            #expect(loud.max()! - loud.min()! < 3, "\(spec.id) across the neck: \(loud)")
            basses += loud
        }
        // They were 20 dB apart: the default bass under the sub by that much.
        #expect(basses.max()! - basses.min()! < 6, "finger against sub: \(basses)")
    }

    @Test("vibrato bends the pitch and tremolo dips the level, both fading in after the note starts")
    func wobbles() {
        let rate = 48_000.0
        // The violin at A4: its vibrato is 20 cents at 6 Hz, in after 0.3 s. Zero crossings in a
        // twelfth of a second either side of a wobble's peak read the pitch rising and falling.
        let violin = InstrumentSynthesizer.render(.violin, midi: 69, velocity: 110, sampleRate: rate, seconds: 1.5)
        func hz(_ at: Double) -> Double {
            let slice = violin[Int(at * rate)..<Int((at + 0.04) * rate)]
            let crossings = zip(slice, slice.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            return Double(crossings) / 0.04
        }
        let early = hz(0.02), steady = [0.8, 0.88, 0.96, 1.04].map(hz)
        #expect(abs(early - 440) < 30, "\(early)")
        #expect((steady.max() ?? 0) - (steady.min() ?? 0) > 2, "the pitch moves once the vibrato is in: \(steady)")

        // The vibraphone's tremolo: the level swings at 5.2 Hz once it is in.
        let vibes = InstrumentSynthesizer.render(.vibraphone, midi: 72, velocity: 110, sampleRate: rate, seconds: 1.5)
        func level(_ at: Double) -> Float { vibes[Int(at * rate)..<Int((at + 0.02) * rate)].map(abs).max() ?? 0 }
        let window = stride(from: 0.4, to: 1.2, by: 0.02).map(level)
        let ratios = zip(window, window.dropFirst()).map { max($0, $1) / max(1e-6, min($0, $1)) }
        #expect((ratios.max() ?? 1) > 1.08, "the level should swing")
    }

    @Test("a kit's folder carries a fingerprint of its settings: change one and it is a new render; old ones are recognised")
    func fingerprints() {
        let name = SynthesizedInstrument.folderName(for: .rhodes)
        var retuned = InstrumentVoiceSpec.rhodes
        retuned.drive += 0.01
        #expect(name != SynthesizedInstrument.folderName(for: retuned))
        #expect(name == SynthesizedInstrument.folderName(for: .rhodes), "the same settings, the same folder")
        #expect(KitFingerprint.isStale("instrument-rhodes", prefix: "instrument-rhodes", current: name), "a render from before fingerprints")
        #expect(KitFingerprint.isStale(SynthesizedInstrument.folderName(for: retuned), prefix: "instrument-rhodes", current: name))
        #expect(!KitFingerprint.isStale(name, prefix: "instrument-rhodes", current: name))
        #expect(!KitFingerprint.isStale("instrument-rhodes-live", prefix: "instrument-rhodes", current: name), "only fingerprints")
        #expect(!KitFingerprint.isStale(SynthesizedInstrument.folderName(for: .fmPiano), prefix: "instrument-rhodes", current: name))
    }

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
        case .pluckedString:
            let pluck = try? #require(spec.pluck, "\(spec.id) has no pluck")
            #expect((pluck?.decaySeconds ?? 0) > 0 && (0...0.5).contains(pluck?.pickPosition ?? -1))
        case .sampled:
            Issue.record("\(spec.id): a preset is synthesized; only an import is sampled")
        }
        #expect(!spec.summary.isEmpty, "\(spec.id) says nothing about how it sounds")
        #expect(spec.durationSeconds >= 1 && spec.durationSeconds <= 10)
        #expect(spec.amplitude.attack >= 0 && spec.amplitude.release > 0)
        #expect((0...1).contains(spec.amplitude.sustain))
        #expect(spec.velocityLayers.allSatisfy { (1...127).contains($0) })
        #expect(spec.velocityLayers == spec.velocityLayers.sorted(), "layers must be in order")
        #expect(spec.level > 0 && spec.level <= 1)
    }
}

// The crash this caught: switching instrument while one was playing.

@Suite("Voice sampler: swapping a kit keeps the node")
struct SamplerKitSwapTests {
    /// Two kits, built into their own folders.
    private func kits() throws -> (URL, LoadedKit, LoadedKit) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        let a = try SynthesizedInstrument.build(.marimba, in: root.appendingPathComponent("a"), sampleRate: 48_000)
        let b = try SynthesizedInstrument.build(.organ, in: root.appendingPathComponent("b"), sampleRate: 48_000)
        return (root, a, b)
    }

    @Test("a second prepare swaps the zones and keeps the same node, so an attached node stays attached")
    func swapKeepsTheNode() throws {
        let (root, first, second) = try kits()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = VoiceSampler(cache: SampleCache())
        defer { sampler.unprepare() }

        try sampler.prepare(first, sampleRate: 48_000, channels: 2)
        let node = try #require(sampler.node)
        #expect(sampler.kit?.manifest.name == first.manifest.name)

        try sampler.prepare(second, sampleRate: 48_000, channels: 2)
        // Identity, not equality: the service attaches this node to the engine exactly once, so a
        // new object here is a node nobody attached, and the first note asks it for a render time
        // it cannot give. That is a crash, not a wrong sound.
        #expect(sampler.node === node, "the kit swap replaced the node")
        #expect(sampler.kit?.manifest.name == second.manifest.name, "the zones did not swap")
    }

    @Test("unprepare does destroy the node, which is why the service must not call it on a live sampler")
    func unprepareDropsTheNode() throws {
        let (root, first, _) = try kits()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = VoiceSampler(cache: SampleCache())
        try sampler.prepare(first, sampleRate: 48_000, channels: 2)
        #expect(sampler.node != nil)
        sampler.unprepare()
        #expect(sampler.node == nil && sampler.kit == nil)
    }
}
