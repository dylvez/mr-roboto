import Foundation

// MARK: - The voices

/// A synthesized bass voice: what a bass line plays through.
///
/// Two of them, one per side of the Bassist bible's tone profiles, and neither is a sample of a
/// real instrument. Like the drums (A3), they are generators the sampler plays: each renders a
/// handful of root notes into a pitched kit, and the sampler's own `.range` transposition and
/// release stage do the rest. Unlike the drums they *sustain*, so a hit's `duration` matters —
/// the note-off runs the zone's release, which is what lets a bass line end a note on the beat.
///
/// **Sub** is the programmed low end (lineage C): a sine with the 808's short pitch drop at the
/// front, a long exponential decay, and a low-pass around 180 Hz that tracks the key. The bible's
/// own words for the tone: "Serum or sampled 808, low-pass ≈180 Hz key-tracked, saturation, mono".
/// The decay sits inside R10's 550–650 ms band by default.
///
/// **Finger** is the played bass (lineages A and B): a plucked-string model — a burst of noise into
/// a delay line whose length is the period, damped a little on every trip round. Damping is what
/// a palm and a set of flatwound strings do to a note; the bible's '63 P-Bass "an inch from the
/// bridge" is a short, dark, quickly-settling note, and that is a heavily damped string through a
/// low-pass, not a bright one. The model is Karplus–Strong with a two-point loop average, which
/// keeps the pitch exact (the average adds exactly half a sample of delay, accounted for below).
public struct BassVoiceSpec: Codable, Sendable, Hashable, Identifiable {
    public enum Engine: String, Codable, Sendable, Hashable {
        /// A sine with a pitch drop and an exponential decay.
        case sub
        /// A damped plucked string.
        case pluckedString
    }

    public var id: String
    public var name: String
    public var engine: Engine

    /// Seconds the render lasts. A note longer than this rides the release into silence; a
    /// whole note at 60 bpm is 4 s, so this covers anything a bass line writes at tempo.
    public var durationSeconds: Double
    /// T60 of the note's own decay, before any note-off.
    public var decaySeconds: Double
    /// Release after note-off, seconds. Short enough to end a note *on* the beat rather than
    /// after it (R8), long enough not to click.
    public var releaseSeconds: Double

    /// Sub only: how far above the pitch the note starts, as a ratio (1.5 = a fifth up), and how
    /// quickly it falls to pitch. The 808's characteristic first few milliseconds.
    public var pitchDropRatio: Double
    public var pitchDropSeconds: Double

    /// Low-pass corner at the reference pitch, in Hz, and the reference pitch itself. The corner
    /// tracks the note: a fifth up moves it a fifth up. 0 turns the filter off.
    public var lowPassHz: Double
    public var lowPassReferenceMIDI: Int
    /// Saturation, 0…1, `SynthShaper.saturate`.
    public var drive: Double
    /// Plucked string only: how bright the pluck is, as the low-pass on the excitation noise, Hz.
    public var pluckBrightnessHz: Double
    /// Output level, linear.
    public var level: Double

    public init(id: String, name: String, engine: Engine, durationSeconds: Double = 4,
                decaySeconds: Double, releaseSeconds: Double = 0.04,
                pitchDropRatio: Double = 1, pitchDropSeconds: Double = 0.03,
                lowPassHz: Double = 0, lowPassReferenceMIDI: Int = 40, drive: Double = 0,
                pluckBrightnessHz: Double = 2_000, level: Double = 1) {
        self.id = id
        self.name = name
        self.engine = engine
        self.durationSeconds = durationSeconds
        self.decaySeconds = decaySeconds
        self.releaseSeconds = releaseSeconds
        self.pitchDropRatio = pitchDropRatio
        self.pitchDropSeconds = pitchDropSeconds
        self.lowPassHz = lowPassHz
        self.lowPassReferenceMIDI = lowPassReferenceMIDI
        self.drive = drive
        self.pluckBrightnessHz = pluckBrightnessHz
        self.level = level
    }

    /// The programmed low end. Decay 600 ms, the middle of R10's band.
    public static let sub = BassVoiceSpec(
        id: "sub", name: "Sub", engine: .sub,
        decaySeconds: 0.6, releaseSeconds: 0.03,
        pitchDropRatio: 1.5, pitchDropSeconds: 0.025,
        lowPassHz: 180, lowPassReferenceMIDI: 40, drive: 0.35, level: 1)

    /// The played bass: flatwounds, palm near the bridge. T60 half a second, dark.
    public static let finger = BassVoiceSpec(
        id: "finger", name: "Finger", engine: .pluckedString,
        decaySeconds: 0.55, releaseSeconds: 0.045,
        lowPassHz: 700, lowPassReferenceMIDI: 40, drive: 0.15,
        pluckBrightnessHz: 1_400, level: 0.9)

    public static let all: [BassVoiceSpec] = [sub, finger]
}

// MARK: - Rendering one note

public enum BassSynthesizer {

    /// One note at `midi`, `velocity`, as mono samples at `sampleRate`.
    public static func render(_ spec: BassVoiceSpec, midi: Int, velocity: Int, sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((spec.durationSeconds * sampleRate).rounded()))
        guard sampleRate > 0 else { return [Float](repeating: 0, count: frameCount) }
        let v = Double(min(127, max(1, velocity))) / 127
        let frequency = 440 * pow(2, Double(midi - 69) / 12)
        var signal = [Double](repeating: 0, count: frameCount)

        switch spec.engine {
        case .sub:
            addSub(&signal, spec: spec, frequency: frequency, sampleRate: sampleRate)
        case .pluckedString:
            addPluckedString(&signal, spec: spec, frequency: frequency, velocity: v, sampleRate: sampleRate)
        }
        applyOutput(&signal, spec: spec, midi: midi, velocity: v, sampleRate: sampleRate)
        var samples = signal.map(Float.init)
        SynthEnvelope.applyFadeOut(&samples, seconds: 0.01, sampleRate: sampleRate)
        return samples
    }

    /// A sine whose instantaneous frequency starts `pitchDropRatio` above the note and settles
    /// exponentially, under an exponential amplitude decay. Phase is integrated, not computed from
    /// time, so the sweep is continuous.
    private static func addSub(_ signal: inout [Double], spec: BassVoiceSpec, frequency: Double,
                               sampleRate: Double) {
        var phase = 0.0
        let drop = max(0, spec.pitchDropRatio - 1)
        for i in signal.indices {
            let t = Double(i) / sampleRate
            let f = frequency * (1 + drop * exp(-t / max(1e-4, spec.pitchDropSeconds)))
            phase += 2 * .pi * f / sampleRate
            signal[i] = sin(phase) * SynthEnvelope.exponential(t: t, t60: spec.decaySeconds)
        }
    }

    /// Karplus–Strong. A one-period burst of low-passed noise circulates in a delay line with a
    /// two-point average, losing `g` per trip. The average adds exactly half a sample of delay, so
    /// the line is `period − 0.5` samples long and the fractional part is linearly interpolated;
    /// pitch error stays under a cent across the bass range. `g` is set from the wanted T60: the
    /// loop runs `frequency × T60` times in that many seconds, so `g = 10^(−3 / (f · T60))`.
    private static func addPluckedString(_ signal: inout [Double], spec: BassVoiceSpec, frequency: Double,
                                         velocity: Double, sampleRate: Double) {
        let period = sampleRate / frequency
        let lineLength = period - 0.5
        let n = Int(lineLength.rounded(.down))
        let frac = lineLength - Double(n)
        guard n >= 2 else { return }
        let g = pow(10, -3 / (frequency * max(0.05, spec.decaySeconds)))

        // Excitation: one period of noise, low-passed for the pluck's brightness. Harder plucks
        // are brighter, which is how a played bass responds to velocity.
        var rng = SeededRandom(seed: 0x5EED_BA55 ^ UInt64(frequency * 1000))
        var exciteFilter = Biquad.lowPass(frequency: min(sampleRate * 0.45, spec.pluckBrightnessHz * (0.6 + 0.6 * velocity)),
                                          sampleRate: sampleRate)
        var line = [Double](repeating: 0, count: n + 2)
        for i in 0..<(n + 2) { line[i] = exciteFilter.process(rng.bipolar()) }
        // Remove the burst's DC so the string does not carry an offset round the loop.
        let mean = line.reduce(0, +) / Double(line.count)
        for i in line.indices { line[i] -= mean }

        var write = 0
        let count = line.count
        for i in signal.indices {
            // Read `lineLength` samples back, interpolating between the two integer taps.
            let readA = (write - n + count) % count
            let readB = (readA - 1 + count) % count
            let delayed = line[readA] * (1 - frac) + line[readB] * frac
            let previous = line[(readA - 1 + count) % count] * (1 - frac) + line[(readB - 1 + count) % count] * frac
            let y = g * 0.5 * (delayed + previous)
            signal[i] = y
            line[write] = y
            write = (write + 1) % count
        }
    }

    /// Key-tracked low-pass, saturation, level — the same order the drum voices use.
    private static func applyOutput(_ signal: inout [Double], spec: BassVoiceSpec, midi: Int,
                                    velocity v: Double, sampleRate: Double) {
        let tracked = spec.lowPassHz * pow(2, Double(midi - spec.lowPassReferenceMIDI) / 12)
        var lowPass = Biquad.lowPass(frequency: min(sampleRate * 0.45, max(20, tracked)), sampleRate: sampleRate)
        let gain = spec.level * (0.55 + 0.45 * v)
        for i in signal.indices {
            var y = signal[i]
            if spec.lowPassHz > 0 { y = lowPass.process(y) }
            if spec.drive > 0 { y = SynthShaper.saturate(y, drive: spec.drive) }
            signal[i] = gain * y
        }
    }
}

// MARK: - The kit

/// Builds a bass voice into a pitched kit the sampler plays.
///
/// One root every seven semitones from C1 to G4 — the bible's widest register is B0–G4 — each
/// covering three semitones either side, so the sampler never transposes more than a fourth. The
/// zones sustain (`sustain: 1`) and carry the voice's release, so a hit's `duration` ends the
/// note through the release stage rather than cutting it.
public enum SynthesizedBass {

    public static let roots: [Int] = [24, 31, 38, 45, 52, 59, 66]
    public static let headroomDBFS: Double = -3

    /// The kit's folder name for a voice, so a caller can find one it built earlier.
    public static func folderName(for spec: BassVoiceSpec) -> String { "bass-\(spec.id)" }

    public static func build(_ spec: BassVoiceSpec, in folder: URL, sampleRate: Double = 48_000) throws -> LoadedKit {
        let samplesFolder = folder.appendingPathComponent("samples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: samplesFolder.path, reason: "\(error)")
        }

        var rendered: [(root: Int, samples: [Float])] = []
        var peak: Float = 0
        for root in roots {
            let samples = BassSynthesizer.render(spec, midi: root, velocity: 110, sampleRate: sampleRate)
            peak = Swift.max(peak, SynthMeasure.peak(samples))
            rendered.append((root, samples))
        }
        let scale = peak > 0 ? Float(pow(10, headroomDBFS / 20)) / peak : 1

        var zones: [Zone] = []
        for (index, entry) in rendered.enumerated() {
            let relativePath = "samples/\(spec.id)_\(entry.root).wav"
            var samples = entry.samples
            for i in samples.indices { samples[i] *= scale }
            try SynthesizedKit.writeWAV(samples, to: KitPath.resolve(relativePath, in: folder), sampleRate: sampleRate)
            let low = index == 0 ? 0 : entry.root - 3
            let high = index == roots.count - 1 ? 127 : entry.root + 3
            zones.append(Zone(
                id: ZoneID("\(spec.id)_\(entry.root)"),
                sample: relativePath,
                key: .range(low...high, rootNote: entry.root),
                offMode: .normal,
                envelope: Envelope(sustain: 1, release: Float(spec.releaseSeconds))))
        }

        let manifest = KitManifest(
            name: "\(spec.name) bass",
            description: "Synthesized \(spec.name.lowercased()) bass: \(spec.engine.rawValue), \(roots.count) roots, transposed between them.",
            kind: .synthesized,
            zones: zones,
            velocityCurve: .squared)
        return try KitStore.save(manifest, to: folder)
    }
}
