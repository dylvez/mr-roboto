import Foundation

// MARK: - Rendering an instrument voice

/// Renders `InstrumentVoiceSpec` to samples, and bakes a voice into a pitched kit.
///
/// The oscillators are **additive rather than naive**: a saw built by summing harmonics up to
/// Nyquist instead of by a rising ramp with a jump in it. A naive saw at the top of the keyboard
/// folds everything above Nyquist back down as inharmonic noise, and because these renders are
/// cached that aliasing would be baked in permanently rather than merely sounding bad live.
public enum InstrumentSynthesizer {

    /// One note, rendered.
    public static func render(_ spec: InstrumentVoiceSpec, midi: Int, velocity: Int,
                              sampleRate: Double = 48_000) -> [Float] {
        let frames = max(1, Int(spec.durationSeconds * sampleRate))
        let frequency = frequency(ofMIDI: midi)
        let loudness = max(0, min(1, Double(velocity) / 127))
        var samples: [Float]
        switch spec.engine {
        case .subtractive:
            samples = subtractive(spec, frequency: frequency, midi: midi, loudness: loudness,
                                  frames: frames, sampleRate: sampleRate)
        case .fm:
            samples = frequencyModulated(spec, frequency: frequency, loudness: loudness,
                                         frames: frames, sampleRate: sampleRate)
        }
        applyAmplitude(&samples, spec.amplitude, sampleRate: sampleRate)
        if spec.drive > 0 {
            for index in samples.indices {
                samples[index] = Float(SynthShaper.saturate(Double(samples[index]), drive: spec.drive))
            }
        }
        let gain = Float(spec.level)
        for index in samples.indices { samples[index] *= gain }
        // The render ends at its own edge; without this a note held to the end clicks.
        SynthEnvelope.applyFadeOut(&samples, seconds: 0.01, sampleRate: sampleRate)
        return samples
    }

    public static func frequency(ofMIDI midi: Int) -> Double { 440 * pow(2, (Double(midi) - 69) / 12) }

    // MARK: Subtractive

    private static func subtractive(_ spec: InstrumentVoiceSpec, frequency: Double, midi: Int,
                                    loudness: Double, frames: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        var phases = [Double](repeating: 0, count: spec.oscillators.count)
        var subPhase = 0.0
        var seeded = SeededRandom(seed: UInt64(midi &* 2_654_435_761 &+ 1))

        let total = max(0.0001, spec.oscillators.reduce(0) { $0 + $1.level } + spec.subLevel + spec.noiseLevel)
        for index in 0..<frames {
            var value = 0.0
            for (which, oscillator) in spec.oscillators.enumerated() {
                let ratio = pow(2, Double(oscillator.octave) + oscillator.cents / 1_200)
                let hz = frequency * ratio
                value += oscillator.level * waveform(oscillator.waveform, phase: phases[which],
                                                     frequency: hz, sampleRate: sampleRate,
                                                     pulseWidth: oscillator.pulseWidth)
                phases[which] += hz / sampleRate
                if phases[which] >= 1 { phases[which] -= 1 }
            }
            if spec.subLevel > 0 {
                value += spec.subLevel * sin(2 * .pi * subPhase)
                subPhase += (frequency / 2) / sampleRate
                if subPhase >= 1 { subPhase -= 1 }
            }
            if spec.noiseLevel > 0 { value += spec.noiseLevel * seeded.bipolar() }
            samples[index] = Float(value / total)
        }
        applyFilter(&samples, spec, midi: midi, loudness: loudness, sampleRate: sampleRate)
        return samples
    }

    /// A band-limited waveform: harmonics summed only while they stay under Nyquist.
    static func waveform(_ shape: InstrumentVoiceSpec.Waveform, phase: Double, frequency: Double,
                         sampleRate: Double, pulseWidth: Double) -> Double {
        let angle = 2 * Double.pi * phase
        switch shape {
        case .sine:
            return sin(angle)
        case .triangle, .saw, .square, .pulse:
            let limit = max(1, Int((sampleRate / 2) / max(1, frequency)))
            var sum = 0.0
            switch shape {
            case .saw:
                for harmonic in 1...min(limit, 64) { sum += sin(angle * Double(harmonic)) / Double(harmonic) }
                return sum * (2 / Double.pi)
            case .square:
                for harmonic in stride(from: 1, through: min(limit, 63), by: 2) { sum += sin(angle * Double(harmonic)) / Double(harmonic) }
                return sum * (4 / Double.pi)
            case .triangle:
                var sign = 1.0
                for harmonic in stride(from: 1, through: min(limit, 63), by: 2) {
                    sum += sign * sin(angle * Double(harmonic)) / Double(harmonic * harmonic)
                    sign = -sign
                }
                return sum * (8 / (Double.pi * Double.pi))
            default:
                // A pulse is the difference of two saws a width apart, which stays band-limited.
                let width = max(0.05, min(0.95, pulseWidth))
                for harmonic in 1...min(limit, 64) {
                    let h = Double(harmonic)
                    sum += (sin(angle * h) - sin((angle + 2 * .pi * width) * h)) / h
                }
                return sum * (1 / Double.pi)
            }
        }
    }

    /// The resonant low-pass, its corner following the note and the envelope.
    ///
    /// Recomputed every 32 samples rather than every sample: a biquad's coefficients are eight
    /// transcendentals, and at 48 kHz over four seconds per note per key zone that is the whole
    /// render time. 32 samples is 0.67 ms, far under anything audible as a step.
    private static func applyFilter(_ samples: inout [Float], _ spec: InstrumentVoiceSpec,
                                    midi: Int, loudness: Double, sampleRate: Double) {
        guard spec.filterHz > 0, spec.filterHz < sampleRate / 2 else { return }
        let track = pow(2, Double(midi - spec.filterReferenceMIDI) / 12 * spec.filterKeyTrack)
        let base = spec.filterHz * track
        let octaves = spec.filterEnvelopeOctaves * (0.35 + 0.65 * loudness)
        let block = 32
        var filter = Biquad.lowPass(frequency: min(base, sampleRate / 2 - 100), q: spec.filterQ, sampleRate: sampleRate)
        var index = 0
        while index < samples.count {
            if octaves != 0 {
                let seconds = Double(index) / sampleRate
                let open = envelopeValue(spec.filterEnvelope, at: seconds)
                let corner = min(base * pow(2, octaves * open), sampleRate / 2 - 100)
                // Only the coefficients: `filter` keeps its own delay line, so the corner moves
                // without resetting the filter and clicking.
                let fresh = Biquad.lowPass(frequency: max(20, corner), q: spec.filterQ, sampleRate: sampleRate)
                filter.b0 = fresh.b0; filter.b1 = fresh.b1; filter.b2 = fresh.b2
                filter.a1 = fresh.a1; filter.a2 = fresh.a2
            }
            for offset in index..<min(index + block, samples.count) {
                samples[offset] = Float(filter.process(Double(samples[offset])))
            }
            index += block
        }
    }

    // MARK: FM

    private static func frequencyModulated(_ spec: InstrumentVoiceSpec, frequency: Double, loudness: Double,
                                           frames: Int, sampleRate: Double) -> [Float] {
        var operators = spec.operators
        while operators.count < 4 { operators.append(InstrumentVoiceSpec.Operator(ratio: 1, level: 0)) }
        var phases = [Double](repeating: 0, count: 4)
        var samples = [Float](repeating: 0, count: frames)
        // Velocity drives the modulators, not the carriers: harder is brighter, which is the
        // whole reason these presets ask for two layers.
        let index = 0.35 + 0.65 * loudness

        func step(_ which: Int, modulation: Double, seconds: Double) -> Double {
            let op = operators[which]
            let hz = op.fixedHz ?? frequency * op.ratio
            let value = sin(2 * .pi * phases[which] + modulation)
            phases[which] += hz / sampleRate
            if phases[which] >= 1 { phases[which] -= 1 }
            return value * op.level * operatorEnvelope(op, at: seconds)
        }

        for frame in 0..<frames {
            let seconds = Double(frame) / sampleRate
            var out = 0.0
            switch spec.algorithm {
            case .stack:
                let four = step(3, modulation: 0, seconds: seconds) * index * 6
                let three = step(2, modulation: four, seconds: seconds) * index * 6
                let two = step(1, modulation: three, seconds: seconds) * index * 6
                out = step(0, modulation: two, seconds: seconds)
            case .twoIntoOne:
                let four = step(3, modulation: 0, seconds: seconds) * index * 6
                let three = step(2, modulation: four, seconds: seconds) * index * 6
                let two = step(1, modulation: 0, seconds: seconds) * index * 6
                out = step(0, modulation: three + two, seconds: seconds)
            case .twinPairs:
                let two = step(1, modulation: 0, seconds: seconds) * index * 6
                let four = step(3, modulation: 0, seconds: seconds) * index * 6
                out = step(0, modulation: two, seconds: seconds) + step(2, modulation: four, seconds: seconds)
            case .onePairTwoSines:
                let two = step(1, modulation: 0, seconds: seconds) * index * 6
                out = step(0, modulation: two, seconds: seconds)
                    + step(2, modulation: 0, seconds: seconds) + step(3, modulation: 0, seconds: seconds)
            }
            samples[frame] = Float(out * 0.5)
        }
        return samples
    }

    // MARK: Envelopes

    /// An operator's own envelope: attack, decay to sustain, held there.
    static func operatorEnvelope(_ op: InstrumentVoiceSpec.Operator, at seconds: Double) -> Double {
        if seconds < op.attack { return op.attack <= 0 ? 1 : seconds / op.attack }
        let since = seconds - op.attack
        guard op.decay > 0 else { return op.sustain }
        let fallen = exp(-3 * since / op.decay)
        return op.sustain + (1 - op.sustain) * fallen
    }

    /// The value of an ADSR while the note is held, ignoring release.
    static func envelopeValue(_ envelope: InstrumentVoiceSpec.Envelope, at seconds: Double) -> Double {
        if seconds < envelope.attack { return envelope.attack <= 0 ? 1 : seconds / envelope.attack }
        let since = seconds - envelope.attack
        guard envelope.decay > 0 else { return envelope.sustain }
        let fallen = exp(-3 * since / envelope.decay)
        return envelope.sustain + (1 - envelope.sustain) * fallen
    }

    private static func applyAmplitude(_ samples: inout [Float], _ envelope: InstrumentVoiceSpec.Envelope,
                                       sampleRate: Double) {
        for index in samples.indices {
            samples[index] *= Float(envelopeValue(envelope, at: Double(index) / sampleRate))
        }
    }
}

// MARK: - Baking a kit

/// Builds an instrument into a pitched kit the sampler plays.
///
/// A root every four semitones from C1 to C7, so nothing is transposed more than two semitones —
/// tighter than the bass's fourth, because a transposed pad's formants move audibly where a bass
/// note's do not. With two velocity layers that is 37 renders, which is why `KitStore` caches.
public enum SynthesizedInstrument {
    /// C1 to C7 every four semitones.
    public static let roots: [Int] = Array(stride(from: 24, through: 96, by: 4))
    public static let headroomDBFS: Double = -3

    public static func folderName(for spec: InstrumentVoiceSpec) -> String { "instrument-\(spec.id)" }

    public static func build(_ spec: InstrumentVoiceSpec, in folder: URL, sampleRate: Double = 48_000) throws -> LoadedKit {
        let samplesFolder = folder.appendingPathComponent("samples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: samplesFolder.path, reason: "\(error)")
        }

        let layers = spec.velocityLayers
        var rendered: [(root: Int, layer: Int, velocity: Int, samples: [Float])] = []
        var peak: Float = 0
        for root in roots {
            for (layer, velocity) in layers.enumerated() {
                let samples = InstrumentSynthesizer.render(spec, midi: root, velocity: velocity, sampleRate: sampleRate)
                peak = Swift.max(peak, SynthMeasure.peak(samples))
                rendered.append((root, layer, velocity, samples))
            }
        }
        let scale = peak > 0 ? Float(pow(10, headroomDBFS / 20)) / peak : 1

        var zones: [Zone] = []
        for entry in rendered {
            let index = roots.firstIndex(of: entry.root) ?? 0
            let low = index == 0 ? 0 : entry.root - 2
            let high = index == roots.count - 1 ? 127 : entry.root + 1
            // Velocity bands split evenly between the layers, the top one reaching 127.
            let bandLow = entry.layer == 0 ? 1 : (127 * entry.layer / layers.count) + 1
            let bandHigh = entry.layer == layers.count - 1 ? 127 : 127 * (entry.layer + 1) / layers.count
            let relativePath = "samples/\(spec.id)_\(entry.root)_v\(entry.velocity).wav"
            var samples = entry.samples
            for index in samples.indices { samples[index] *= scale }
            try SynthesizedKit.writeWAV(samples, to: KitPath.resolve(relativePath, in: folder), sampleRate: sampleRate)
            zones.append(Zone(
                id: ZoneID("\(spec.id)_\(entry.root)_\(entry.layer)"),
                sample: relativePath,
                key: .range(low...high, rootNote: entry.root),
                velocity: bandLow...bandHigh,
                offMode: .normal,
                envelope: Envelope(sustain: 1, release: Float(spec.amplitude.release))))
        }

        let manifest = KitManifest(
            name: spec.name,
            description: "Synthesized \(spec.family): \(spec.engine.rawValue), \(roots.count) roots × \(layers.count) velocity layer\(layers.count == 1 ? "" : "s").",
            kind: .synthesized,
            zones: zones,
            velocityCurve: .squared)
        return try KitStore.save(manifest, to: folder)
    }
}
