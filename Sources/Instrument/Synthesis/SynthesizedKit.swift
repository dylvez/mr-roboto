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
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(max(1, samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw KitError.writeFailed(path: url.path, reason: "could not allocate \(frames) frames")
            }
            buffer.frameLength = frames
            if let data = buffer.floatChannelData {
                for i in 0..<Int(frames) { data[0][i] = i < samples.count ? samples[i] : 0 }
            }
            try file.write(from: buffer)
        } catch let error as KitError {
            throw error
        } catch {
            throw KitError.writeFailed(path: url.path, reason: "\(error)")
        }
    }
}
