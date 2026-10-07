import Foundation

// MARK: - Rendering an instrument voice

/// Renders `InstrumentVoiceSpec` to samples, and bakes a voice into a pitched kit.
///
/// The oscillators are **additive rather than naive**: a saw built by summing harmonics up to
/// Nyquist instead of by a rising ramp with a jump in it. A naive saw at the top of the keyboard
/// folds everything above Nyquist back down as inharmonic noise, and because these renders are
/// cached that aliasing would be baked in permanently rather than merely sounding bad live.
public enum InstrumentSynthesizer {

    /// One note, rendered: the preset's full length, or `seconds` of it (still faded out at the end).
    public static func render(_ spec: InstrumentVoiceSpec, midi: Int, velocity: Int,
                              sampleRate: Double = 48_000, seconds: Double? = nil) -> [Float] {
        let frames = max(1, Int((seconds ?? spec.durationSeconds) * sampleRate))
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
        case .pluckedString:
            samples = plucked(spec, frequency: frequency, midi: midi, loudness: loudness,
                              frames: frames, sampleRate: sampleRate)
        case .sampled:
            // Its sound is its recordings, which are played from its kit, not rendered here.
            return [Float](repeating: 0, count: frames)
        }
        applyAmplitude(&samples, spec.amplitude, sampleRate: sampleRate)
        if let tremolo = spec.tremolo, tremolo.depth > 0 {
            for index in samples.indices {
                let seconds = Double(index) / sampleRate
                let dip = tremolo.depth * fadeIn(tremolo, at: seconds) * (0.5 - 0.5 * cos(2 * .pi * tremolo.rateHz * seconds))
                samples[index] *= Float(1 - dip)
            }
        }
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

    /// How far a wobble has faded in, 0…1, rising over its delay.
    static func fadeIn(_ modulation: InstrumentVoiceSpec.Modulation, at seconds: Double) -> Double {
        modulation.delaySeconds <= 0 ? 1 : min(1, seconds / modulation.delaySeconds)
    }

    /// The pitch multiplier vibrato gives at `seconds`: 1 with none. Cents are small, so the
    /// exponential is its first-order term — a sample's cost is one sine, not a `pow`.
    static func vibrato(_ spec: InstrumentVoiceSpec, at seconds: Double) -> Double {
        guard let vibrato = spec.vibrato, vibrato.depth != 0 else { return 1 }
        let swing = sin(2 * .pi * vibrato.rateHz * seconds) * fadeIn(vibrato, at: seconds)
        return 1 + (log(2) / 1_200) * vibrato.depth * swing
    }

    // MARK: Subtractive

    private static func subtractive(_ spec: InstrumentVoiceSpec, frequency: Double, midi: Int,
                                    loudness: Double, frames: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        var phases = [Double](repeating: 0, count: spec.oscillators.count)
        var subPhase = 0.0
        var seeded = SeededRandom(seed: UInt64(midi &* 2_654_435_761 &+ 1))

        let total = max(0.0001, spec.oscillators.reduce(0) { $0 + $1.level } + spec.subLevel + spec.noiseLevel)
        // Each oscillator's pitch is fixed for the note: worked out once, not at every sample.
        let pitches = spec.oscillators.map { frequency * pow(2, Double($0.octave) + $0.cents / 1_200) }
        let wobbles = spec.vibrato != nil
        for index in 0..<frames {
            var value = 0.0
            let bend = wobbles ? vibrato(spec, at: Double(index) / sampleRate) : 1
            for (which, oscillator) in spec.oscillators.enumerated() {
                let hz = pitches[which]
                value += oscillator.level * waveform(oscillator.waveform, phase: phases[which],
                                                     frequency: hz, sampleRate: sampleRate,
                                                     pulseWidth: oscillator.pulseWidth)
                phases[which] += hz * bend / sampleRate
                if phases[which] >= 1 { phases[which] -= 1 }
            }
            if spec.subLevel > 0 {
                value += spec.subLevel * sin(2 * .pi * subPhase)
                subPhase += (frequency / 2) * bend / sampleRate
                if subPhase >= 1 { subPhase -= 1 }
            }
            if spec.noiseLevel > 0 { value += spec.noiseLevel * seeded.bipolar() }
            samples[index] = Float(value / total)
        }
        applyFilter(&samples, spec, midi: midi, loudness: loudness, sampleRate: sampleRate)
        return samples
    }

    /// A band-limited waveform: harmonics summed only while they stay under Nyquist.
    ///
    /// Each harmonic's sine comes from the two before it — sin((n+1)θ) = 2·cos θ·sin(nθ) − sin((n−1)θ)
    /// — so a sample costs one sine and one cosine rather than one per harmonic. A pad's kit is 19
    /// notes of six seconds, and summed a sine at a time it took most of a minute to build.
    static func waveform(_ shape: InstrumentVoiceSpec.Waveform, phase: Double, frequency: Double,
                         sampleRate: Double, pulseWidth: Double) -> Double {
        let angle = 2 * Double.pi * phase
        switch shape {
        case .sine:
            return sin(angle)
        case .triangle, .saw, .square, .pulse:
            let limit = max(1, Int((sampleRate / 2) / max(1, frequency)))
            var sum = 0.0
            // sin(h·θ) for h = 1, 2, 3…, one step at a time: `now` is this harmonic's, `before`
            // the last one's. Written out rather than behind a helper, so a debug build is not
            // slowed by the calls.
            var before = 0.0, now = sin(angle)
            let twiceCosine = 2 * cos(angle)
            switch shape {
            case .saw:
                for harmonic in 1...min(limit, 64) {
                    sum += now / Double(harmonic)
                    (before, now) = (now, twiceCosine * now - before)
                }
                return sum * (2 / Double.pi)
            case .square:
                let top = min(limit, 63)
                for harmonic in 1...max(1, top) {
                    if harmonic % 2 == 1 { sum += now / Double(harmonic) }
                    (before, now) = (now, twiceCosine * now - before)
                }
                return sum * (4 / Double.pi)
            case .triangle:
                let top = min(limit, 63)
                var sign = 1.0
                for harmonic in 1...max(1, top) {
                    if harmonic % 2 == 1 {
                        sum += sign * now / Double(harmonic * harmonic)
                        sign = -sign
                    }
                    (before, now) = (now, twiceCosine * now - before)
                }
                return sum * (8 / (Double.pi * Double.pi))
            default:
                // A pulse is the difference of two saws a width apart, which stays band-limited.
                let width = max(0.05, min(0.95, pulseWidth))
                let shiftedAngle = angle + 2 * .pi * width
                var shiftedBefore = 0.0, shiftedNow = sin(shiftedAngle)
                let shiftedTwiceCosine = 2 * cos(shiftedAngle)
                for harmonic in 1...min(limit, 64) {
                    sum += (now - shiftedNow) / Double(harmonic)
                    (before, now) = (now, twiceCosine * now - before)
                    (shiftedBefore, shiftedNow) = (shiftedNow, shiftedTwiceCosine * shiftedNow - shiftedBefore)
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
        var bend = 1.0

        func step(_ which: Int, modulation: Double, seconds: Double) -> Double {
            let op = operators[which]
            // A fixed-pitch operator is a clank; vibrato bends the note, not the clank.
            let hz = op.fixedHz ?? frequency * op.ratio * bend
            let value = sin(2 * .pi * phases[which] + modulation)
            phases[which] += hz / sampleRate
            if phases[which] >= 1 { phases[which] -= 1 }
            return value * op.level * operatorEnvelope(op, at: seconds)
        }

        let wobbles = spec.vibrato != nil
        for frame in 0..<frames {
            let seconds = Double(frame) / sampleRate
            if wobbles { bend = vibrato(spec, at: seconds) }
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

    // MARK: Plucked string

    /// Karplus–Strong across the keyboard: a one-period burst of low-passed noise circulates in a
    /// delay line with a two-point average, losing a little each trip. The average adds half a
    /// sample of delay, so the line is `period − 0.5` long with its fraction interpolated, which
    /// keeps the pitch within a cent. The loop gain comes from the ring time wanted at this note:
    /// the loop runs `frequency × T60` times in that many seconds, so `g = 10^(−3 / (f · T60))`.
    ///
    /// Where the string is plucked is a comb on the burst: subtracting the burst from itself
    /// `pickPosition` of a period later notches the harmonics with a node there, which is what makes
    /// a pluck by the bridge thin and one over the soundhole round.
    private static func plucked(_ spec: InstrumentVoiceSpec, frequency: Double, midi: Int, loudness: Double,
                                frames: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        guard let pluck = spec.pluck, frequency > 0 else { return samples }
        let period = sampleRate / frequency
        let lineLength = period - 0.5
        let n = Int(lineLength.rounded(.down))
        let fraction = lineLength - Double(n)
        guard n >= 2 else { return samples }
        let ringing = pluck.decaySeconds * pow(261.63 / frequency, pluck.decayKeyTrack)
        let g = pow(10, -3 / (frequency * max(0.05, ringing)))

        var random = SeededRandom(seed: UInt64(truncatingIfNeeded: midi) &* 0x9E37_79B9_7F4A_7C15 &+ 0x5EED)
        let bright = min(sampleRate * 0.45, pluck.brightnessHz * (0.4 + 0.6 * loudness))
        var shaper = Biquad.lowPass(frequency: max(40, bright), sampleRate: sampleRate)
        var line = [Double](repeating: 0, count: n + 2)
        for i in line.indices { line[i] = shaper.process(random.bipolar()) }
        let pick = Int((max(0, min(0.5, pluck.pickPosition)) * period).rounded())
        if pick > 0 {
            let burst = line
            for i in line.indices { line[i] = burst[i] - burst[(i - pick + burst.count) % burst.count] }
        }
        let mean = line.reduce(0, +) / Double(line.count)
        let peak = max(1e-9, line.map { abs($0 - mean) }.max() ?? 1)
        for i in line.indices { line[i] = (line[i] - mean) / peak }

        var write = 0
        let count = line.count
        for i in 0..<frames {
            let readA = (write - n + count) % count
            let readB = (readA - 1 + count) % count
            let delayed = line[readA] * (1 - fraction) + line[readB] * fraction
            let previous = line[(readA - 1 + count) % count] * (1 - fraction) + line[(readB - 1 + count) % count] * fraction
            let y = g * 0.5 * (delayed + previous)
            samples[i] = Float(y)
            line[write] = y
            write = (write + 1) % count
        }
        // The spec's own filter, when it has one: a darker body than the pluck alone gives. A
        // resonant one can lift the attack past full scale, so the note is brought back under it.
        if spec.filterHz < 12_000 { applyFilter(&samples, spec, midi: midi, loudness: loudness, sampleRate: sampleRate) }
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        if loudest > 0.95 { let scale = 0.95 / loudest; for i in samples.indices { samples[i] *= scale } }
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

    /// The kit's folder: the preset's id and a fingerprint of its settings, so a preset changed in
    /// a later build is rendered again rather than loaded stale from the cache.
    public static func folderName(for spec: InstrumentVoiceSpec) -> String {
        "instrument-\(spec.id)-\(KitFingerprint.of(spec, salt: KitLevel.version))"
    }

    public static func build(_ spec: InstrumentVoiceSpec, in folder: URL, sampleRate: Double = 48_000) throws -> LoadedKit {
        if spec.engine == .sampled {
            // An imported instrument already is a kit; there is nothing to render. A section, or
            // one with short recordings beside its held ones, is its recordings put together.
            if let played = try PlayedKits.kit(for: spec) { return played }
            guard let kit = spec.sampledKit else { throw KitError.notADirectory(path: spec.id) }
            return try KitStore.load(from: URL(fileURLWithPath: kit, isDirectory: true))
        }
        let samplesFolder = folder.appendingPathComponent("samples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: samplesFolder.path, reason: "\(error)")
        }

        let layers = spec.velocityLayers
        var rendered: [(root: Int, layer: Int, velocity: Int, samples: [Float])] = []
        var loudest: [Int: [Float]] = [:]
        var peaks: [Int: Float] = [:]
        for root in roots {
            for (layer, velocity) in layers.enumerated() {
                let samples = InstrumentSynthesizer.render(spec, midi: root, velocity: velocity, sampleRate: sampleRate)
                peaks[root] = Swift.max(peaks[root] ?? 0, SynthMeasure.peak(samples))
                rendered.append((root, layer, velocity, samples))
                // The top layer is the one a root is levelled by; the softer ones keep their
                // distance under it, which is what velocity is.
                if layer == layers.count - 1 { loudest[root] = samples }
            }
        }
        let gains = KitLevel.gains(reference: loudest, peaks: peaks, targetDBFS: KitLevel.instrumentDBFS, sampleRate: sampleRate)

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
            let scale = gains[entry.root] ?? 1
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
