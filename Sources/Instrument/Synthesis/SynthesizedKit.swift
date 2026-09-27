import AVFoundation
import Foundation
import SongGraph

// MARK: - Velocity layers

/// One pre-rendered velocity layer: the MIDI range it covers and the velocity it is rendered at.
///
/// Per-hit variation in a synthesized kit comes from having two or three of these, not from
/// re-synthesizing every hit. That is authentic rather than a compromise: on a TR-808 there is one
/// ACCENT bus, and accent is mostly a level change with a small second-order effect on the pitch
/// envelope and decay. Two or three layers capture that, and playing them back through the existing
/// sampler is what gives A3 choke groups, round robin and offline determinism for free.
public struct SynthVelocityLayer: Hashable, Codable, Sendable {
    public var range: ClosedRange<Int>
    /// The velocity the layer is rendered at — the middle of its range.
    public var velocity: Int

    public init(range: ClosedRange<Int>, velocity: Int) {
        self.range = range
        self.velocity = velocity
    }

    /// Splits 1…127 into `count` contiguous layers, each rendered at its midpoint.
    public static func split(_ count: Int) -> [SynthVelocityLayer] {
        let n = max(1, count)
        var layers: [SynthVelocityLayer] = []
        var low = 1
        for i in 0..<n {
            let high = i == n - 1 ? 127 : 1 + (127 * (i + 1)) / n
            layers.append(SynthVelocityLayer(range: low...high, velocity: (low + high) / 2))
            low = high + 1
        }
        return layers
    }

    private enum CodingKeys: String, CodingKey { case lovel, hivel, velocity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let low = try c.decodeIfPresent(Int.self, forKey: .lovel) ?? 1
        let high = try c.decodeIfPresent(Int.self, forKey: .hivel) ?? 127
        range = Swift.min(low, high)...Swift.max(low, high)
        velocity = try c.decodeIfPresent(Int.self, forKey: .velocity) ?? (range.lowerBound + range.upperBound) / 2
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range.lowerBound, forKey: .lovel)
        try c.encode(range.upperBound, forKey: .hivel)
        try c.encode(velocity, forKey: .velocity)
    }
}

// MARK: - Building a kit

/// Builds a complete, playable kit folder from a machine preset.
///
/// The result is an ordinary sampled kit as far as everything downstream is concerned: `KitStore`
/// loads it, `KitManifest.validate` passes it, `SampleCache` decodes its WAVs and `VoiceSampler`
/// plays them. The only thing that marks it as synthesized is `kind == .synthesized` and the
/// `synthesis` block, which records the specs so the kit can be re-rendered after a parameter
/// change. No playback path has a special case for it.
public enum SynthesizedKit {

    /// A machine's kit folder: its id and a fingerprint of its voices, so a machine retuned in a
    /// later build is rendered again rather than loaded stale from the cache.
    public static func folderName(for machine: SynthMachine) -> String { "\(machine.id)-\(KitFingerprint.of(machine))" }

    /// The choke group the hi-hat pair shares. Both hats carry `group = 1` (they *silence* group 1)
    /// and `offBy = 1` (they *are silenced by* group 1), so either one cuts the other — which is
    /// what one physical pair of hats does, and exactly the SFZ `group=1 off_by=1` idiom
    /// `KitManifest` documents.
    public static let hatChokeGroup = 1

    /// Peak level, in dBFS, the loudest sample in a generated kit is scaled to. 1 dB of headroom:
    /// enough that nothing clips after the WAV round trip, little enough that a kit is not quiet.
    public static let headroomDBFS: Double = -1

    /// Renders `machine` into `folder` and returns the loaded kit.
    ///
    /// - Parameters:
    ///   - machine: the preset to render.
    ///   - folder: the kit folder to create. WAVs go in `folder/samples/`.
    ///   - sampleRate: render rate. Use the rate the sampler will run at so `SampleCache` does not
    ///     resample on load.
    ///   - layerCount: velocity layers per voice, 2 or 3.
    ///   - name: kit name; defaults to the machine's.
    @discardableResult
    public static func build(_ machine: SynthMachine, in folder: URL,
                             sampleRate: Double = 48_000, layerCount: Int = 3,
                             name: String? = nil) throws -> LoadedKit {
        let layers = SynthVelocityLayer.split(min(3, max(2, layerCount)))
        let samplesFolder = folder.appendingPathComponent("samples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: samplesFolder.path, reason: "\(error)")
        }

        // Render everything first, then scale the whole kit by one factor, so the relative balance
        // between voices — which the presets set with LEVEL, as the machine's own faders do — is
        // exactly what comes out.
        var rendered: [(spec: SynthVoiceSpec, layer: SynthVelocityLayer, samples: [Float])] = []
        var peak: Float = 0
        for spec in machine.voices {
            for layer in layers {
                var samples = DrumSynthesizer.render(spec, velocity: layer.velocity, sampleRate: sampleRate)
                // Strip the level part of velocity: the kit's `velocityCurve` applies it once, on
                // playback. What is left in the layer is the *timbral* difference between a soft
                // and a hard hit, which is the reason to pre-render layers at all.
                let velocityGain = Float(pow(10, spec.velocity.rangeDB * (Double(layer.velocity) / 127 - 1) / 20))
                if velocityGain > 0 {
                    for i in samples.indices { samples[i] /= velocityGain }
                }
                peak = Swift.max(peak, SynthMeasure.peak(samples))
                rendered.append((spec, layer, samples))
            }
        }
        let scale = peak > 0 ? Float(pow(10, headroomDBFS / 20)) / peak : 1

        var zones: [Zone] = []
        var voiceNotes: [DrumVoice: Int] = [:]
        for entry in rendered {
            let stem = entry.spec.kind.fileStem
            let suffix = "v\(entry.layer.range.lowerBound)_\(entry.layer.range.upperBound)"
            let relativePath = "samples/\(stem)_\(suffix).wav"
            var samples = entry.samples
            for i in samples.indices { samples[i] *= scale }
            try writeWAV(samples, to: KitPath.resolve(relativePath, in: folder), sampleRate: sampleRate)

            let isHat = entry.spec.kind == .closedHat || entry.spec.kind == .openHat
            zones.append(Zone.drum(
                id: ZoneID("\(stem)_\(suffix)"),
                sample: relativePath,
                note: entry.spec.kind.generalMIDINote,
                velocity: entry.layer.range,
                group: isHat ? hatChokeGroup : nil,
                offBy: isHat ? hatChokeGroup : nil,
                // No envelope shaping at all beyond a short release. The rendered WAV already
                // *is* the voice's envelope; an `ampeg` on top would shape it twice. (In
                // particular `.percussive(decay: 0)` would be silence: sustain 0 with no decay
                // to reach it.) The release only matters if a caller gives a hit a duration.
                envelope: Envelope(release: 0.005)
            ))
            voiceNotes[entry.spec.kind.drumVoice] = entry.spec.kind.generalMIDINote
        }

        var manifest = KitManifest(
            name: name ?? machine.name,
            description: machine.summary,
            kind: .synthesized,
            zones: zones.sorted { $0.id < $1.id },
            velocityCurve: .squared,
            synthesis: SynthesizedVoiceSet(
                machine: machine.id,
                sampleRate: sampleRate,
                layers: layers,
                voices: machine.voices
            )
        )
        for (voice, note) in voiceNotes { manifest.setNote(note, for: voice) }
        return try KitStore.save(manifest, to: folder)
    }

    /// Re-renders the WAVs of an already-built synthesized kit from the specs in its manifest, after
    /// a parameter change. The zone layout is untouched, so nothing downstream has to reload the
    /// manifest — only the sample files change.
    ///
    /// - Returns: the kit with its `synthesis` block as saved.
    @discardableResult
    public static func rerender(_ kit: LoadedKit) throws -> LoadedKit {
        guard let synthesis = kit.manifest.synthesis, !synthesis.voices.isEmpty else { return kit }
        let machine = SynthMachine(id: synthesis.machine, name: kit.manifest.name,
                                   summary: kit.manifest.description ?? "", voices: synthesis.voices)
        return try build(machine, in: kit.folder, sampleRate: synthesis.sampleRate,
                         layerCount: synthesis.layers.count, name: kit.manifest.name)
    }

    // MARK: WAV

    /// Writes mono float32 samples as a WAV. Float32 on purpose: the sample rate matches the render
    /// rate and the format matches what `SampleCache` decodes to, so the bytes the sampler reads are
    /// the bytes the synthesizer produced — no resampling, no quantisation, no drift between a
    /// render today and the same render tomorrow.
    static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw KitError.writeFailed(path: url.path, reason: "unsupported format at \(sampleRate) Hz")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // The `commonFormat`/`interleaved` initializer, not the two-argument one, so the
            // processing format is the float32 the samples already are and nothing converts on
            // the way out. `ChopAudio.writeWAV` writes its WAVs the same way.
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(max(1, samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw KitError.writeFailed(path: url.path, reason: "could not allocate \(frames) frames")
            }
            buffer.frameLength = frames
            if let data = buffer.floatChannelData {
                for i in 0..<Int(frames) { data[0][i] = i < samples.count ? samples[i] : 0 }
            }
            try file.write(from: buffer)
            // Not optional: until the file is closed the header is not finalised, and a read that
            // follows in the same scope sees a length of 0. Releasing the object closes it too, but
            // only whenever the last reference goes — `AVAudioEngine`'s `OfflineRenderer` closes
            // explicitly for the same reason.
            file.close()
        } catch let error as KitError {
            throw error
        } catch {
            throw KitError.writeFailed(path: url.path, reason: "\(error)")
        }
    }
}

// MARK: - A kit's fingerprint

/// Sixteen hex digits that change whenever a voice's settings do: FNV-1a over its JSON, keys
/// sorted so the same settings are always the same bytes. A kit's folder carries it, so a preset
/// retuned in a later build is not played from the render of the one before.
public enum KitFingerprint {
    /// `salt` stands for how the kit is built rather than what it is of: change the building and
    /// the salt, and every kit built the old way is rendered again.
    public static func of<Spec: Encodable>(_ spec: Spec, salt: String = "") -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = Data(salt.utf8) + ((try? encoder.encode(spec)) ?? Data())
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    /// Whether `name` is a kit folder of `prefix` ("instrument-rhodes") from another fingerprint,
    /// or from before fingerprints: a render nothing will load again.
    public static func isStale(_ name: String, prefix: String, current: String) -> Bool {
        guard name != current else { return false }
        if name == prefix { return true }
        guard name.hasPrefix(prefix + "-") else { return false }
        let tail = name.dropFirst(prefix.count + 1)
        return tail.count == 16 && tail.allSatisfy(\.isHexDigit)
    }
}

/// How loud a pitched kit is made.
///
/// Scaling a kit so its loudest sample sits at one peak level made presets as loud as their
/// attacks, not as they sound: a harpsichord's pluck is a spike over a quiet string, an organ is
/// all body, and at the same peak the organ played 14 dB over the harpsichord. The played basses
/// were worse — the Karplus–Strong string is quieter the lower it goes, so a finger bass was 12 dB
/// quieter at C1 than at its top, and 20 dB under the sub.
///
/// So a kit is levelled by ear's proxy instead: each root is brought to one loudness — the RMS of
/// its loudest 100 ms — so a line does not fade as it walks down, as far as a peak ceiling allows.
/// The ceiling wins for the spikiest sounds, which therefore still sit a few dB under the rest.
public enum KitLevel {
    /// Bump this when the levelling changes: every pitched kit's fingerprint carries it.
    public static let version = "level-1"
    /// No sample in a kit goes over this.
    public static let ceilingDBFS: Double = -1
    /// The loudness chords and melodies are made to: under a snare's first 100 ms, which sits
    /// between -11 and -17 dBFS on the machines here.
    public static let instrumentDBFS: Double = -14
    /// The loudness a bass is made to: under the kick, which sits between -5 and -10 dBFS.
    public static let bassDBFS: Double = -12

    /// The RMS of the loudest 100 ms in the first two seconds: what a note sounds like while it
    /// is sounding, whether it swells into it or starts there. Longer windows read a short,
    /// bright note — a harpsichord's top octave — as quieter than it sounds.
    public static func loudness(_ samples: [Float], sampleRate: Double) -> Double {
        let window = max(1, Int(0.1 * sampleRate))
        let hop = max(1, Int(0.025 * sampleRate))
        let end = min(samples.count, Int(2 * sampleRate))
        guard end > 0 else { return 0 }
        var loudest = 0.0
        var start = 0
        repeat {
            let stop = min(samples.count, start + window)
            var sum = 0.0
            for index in start..<stop { sum += Double(samples[index]) * Double(samples[index]) }
            loudest = Swift.max(loudest, (sum / Double(window)).squareRoot())
            start += hop
        } while start + window <= end
        return loudest
    }

    /// One gain per root: the one that puts `reference` (the root's loudest layer) at
    /// `targetDBFS`, or as near as the ceiling lets the loudest sample of `peaks` (every render
    /// of that root) go. Per root, not per kit: one spiky top note would otherwise hold every
    /// other note down with it.
    public static func gains(reference: [Int: [Float]], peaks: [Int: Float], targetDBFS: Double,
                             sampleRate: Double) -> [Int: Float] {
        let target = pow(10, targetDBFS / 20)
        let ceiling = pow(10, ceilingDBFS / 20)
        var gains: [Int: Float] = [:]
        for (root, samples) in reference {
            let loud = loudness(samples, sampleRate: sampleRate)
            let peak = Double(peaks[root] ?? 0)
            guard loud > 1e-6, peak > 0 else { gains[root] = 1; continue }
            gains[root] = Float(Swift.min(target / loud, ceiling / peak))
        }
        return gains
    }
}
