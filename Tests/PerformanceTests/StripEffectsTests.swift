import AVFAudio
import AudioEngine
import CStripFX
import Foundation
import SongGraph
import Testing

@testable import Performance

/// A strip's insert and the echo, rendered offline through the graph the transport plays: an amp
/// adds harmonics and keeps its level, a rotating speaker moves, the echo comes back on the beat,
/// and a strip with nothing in it is untouched.
@Suite("Strip effects: amp, rotating speaker, echo", .serialized)
struct StripEffectsTests {
    private static let rate = 48_000.0

    private func tone(hz: Double, seconds: Double, amplitude: Float, format: AVAudioFormat, burst: Double? = nil) -> AVAudioPCMBuffer {
        let frames = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<frames {
                let t = Double(i) / Self.rate
                let on = burst.map { t < $0 } ?? true
                buffer.floatChannelData![channel][i] = on ? amplitude * Float(sin(2 * .pi * hz * t)) : 0
            }
        }
        return buffer
    }

    @AudioActor
    private func render(hz: Double, amplitude: Float = 0.25, part: PartID, mix: Mix, instrument: StripInsert? = nil,
                        seconds: Double = 2, burst: Double? = nil, tempo: Double = 120) throws -> [[Float]] {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        let player = try engine.player(0)
        try graph.route(player, to: part)
        graph.tempo = tempo
        if let instrument { graph.instrumentInserts = [part: instrument] }
        graph.apply(mix)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: tempo, sampleRate: Self.rate))
        player.scheduleBuffer(tone(hz: hz, seconds: seconds, amplitude: amplitude, format: engine.format, burst: burst),
                              at: nil, options: [], completionHandler: nil)
        player.play()
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(seconds * Self.rate))
        engine.stop()
        let frames = Int(out.frameLength)
        return (0..<Int(out.format.channelCount)).map { c in Array(UnsafeBufferPointer(start: out.floatChannelData![c], count: frames)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        let energy = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(energy / Double(max(1, x.count)), 1e-20))
    }

    /// The share of a steady tone's energy that is not at its own frequency: how much the amp
    /// added. By projecting out the fundamental over whole cycles.
    private func distortion(_ x: [Float], hz: Double) -> Double {
        let start = x.count / 2, count = Int(Self.rate / hz) * 40
        let slice = x[start..<(start + count)]
        var re = 0.0, im = 0.0
        for (i, v) in slice.enumerated() {
            let p = 2 * Double.pi * hz * Double(i) / Self.rate
            re += Double(v) * cos(p)
            im += Double(v) * sin(p)
        }
        let fundamental = 2 * (re * re + im * im) / Double(count * count)
        let total = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(count)
        return max(0, total - fundamental) / max(total, 1e-20)
    }

    @Test("A strip with nothing in it passes the signal sample for sample, as before inserts")
    @AudioActor
    func offIsTransparent() async throws {
        let part = PartID()
        let unity = try render(hz: 440, part: part, mix: .unity, seconds: 0.5)
        var mix = Mix()
        mix.set(Strip(part: part, label: "Keys", insert: .off))
        let off = try render(hz: 440, part: part, mix: mix, seconds: 0.5)
        #expect(unity == off)
        #expect(distortion(unity[0], hz: 440) < 1e-4)
    }

    @Test("The amp adds harmonics as it is driven, keeps its level within a few dB, and never clips")
    @AudioActor
    func amp() async throws {
        let part = PartID()
        let dry = try render(hz: 220, amplitude: 0.2, part: part, mix: .unity)
        var previous = distortion(dry[0], hz: 220)
        for setting in [StripInsert.ampClean, .ampCrunch, .ampLead] {
            var mix = Mix()
            mix.set(Strip(part: part, label: "Guitar", insert: setting))
            let wet = try render(hz: 220, amplitude: 0.2, part: part, mix: mix)
            let amount = distortion(wet[0], hz: 220)
            #expect(amount > previous, "\(setting.words): \(amount) after \(previous)")
            previous = amount
            let change = rms(wet[0][48_000...]) - rms(dry[0][48_000...])
            #expect(abs(change) < 6, "\(setting.words) moves the level \(change) dB")
            #expect(wet.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1 } })
        }
        #expect(previous > 0.05, "the lead setting is plainly distorted")
    }

    @Test("The rotating speaker swells and moves between the two sides; fast moves faster than slow")
    @AudioActor
    func rotary() async throws {
        let part = PartID()
        func movement(_ insert: StripInsert) throws -> (depth: Double, crossings: Int, sides: Double) {
            var mix = Mix()
            mix.set(Strip(part: part, label: "Organ", insert: insert))
            let out = try render(hz: 2_000, amplitude: 0.2, part: part, mix: mix, seconds: 3)
            // The left channel's level in 10 ms windows over the last two seconds.
            let window = 480
            let levels = stride(from: 48_000, to: out[0].count - window, by: window).map { rms(out[0][$0..<($0 + window)]) }
            let mean = levels.reduce(0, +) / Double(levels.count)
            let crossings = zip(levels, levels.dropFirst()).filter { ($0 - mean) * ($1 - mean) < 0 }.count
            let sides = zip(out[0][48_000...], out[1][48_000...]).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }
            return ((levels.max() ?? 0) - (levels.min() ?? 0), crossings, sides)
        }
        let slow = try movement(.rotarySlow), fast = try movement(.rotaryFast)
        #expect(slow.depth > 3 && fast.depth > 3, "slow \(slow.depth) dB, fast \(fast.depth) dB of swell")
        #expect(fast.crossings > 3 * slow.crossings, "fast \(fast.crossings), slow \(slow.crossings)")
        #expect(slow.sides > 1, "the two microphones hear it differently")
    }

    @Test("An organ's speaker is on its strip until the mix takes it off")
    @AudioActor
    func instrumentsOwn() async throws {
        let part = PartID()
        let own = try render(hz: 2_000, amplitude: 0.2, part: part, mix: .unity, instrument: .rotarySlow, seconds: 1)
        let plain = try render(hz: 2_000, amplitude: 0.2, part: part, mix: .unity, seconds: 1)
        #expect(own != plain)
        var mix = Mix()
        mix.set(Strip(part: part, label: "Organ", insert: .off))
        let taken = try render(hz: 2_000, amplitude: 0.2, part: part, mix: mix, instrument: .rotarySlow, seconds: 1)
        #expect(taken == plain)
    }

    @Test("The echo comes back a dotted eighth later at the song's tempo, quieter each time")
    @AudioActor
    func echo() async throws {
        let part = PartID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Lead", gainDB: -60, echoDB: 0))
        mix.echo = Echo(beats: 0.75, feedback: 0.5, toneHz: 8_000)
        // A 20 ms burst at 100 BPM: repeats every 0.45 s.
        let out = try render(hz: 1_000, amplitude: 0.5, part: part, mix: mix, seconds: 1.6, burst: 0.02, tempo: 100)
        let window = 480
        let levels = stride(from: 0, to: out[0].count - window, by: window).map { rms(out[0][$0..<($0 + window)]) }
        let first = levels.indices.filter { Double($0) * 0.01 > 0.3 && Double($0) * 0.01 < 0.6 }.max { levels[$0] < levels[$1] }!
        let second = levels.indices.filter { Double($0) * 0.01 > 0.75 && Double($0) * 0.01 < 1.05 }.max { levels[$0] < levels[$1] }!
        #expect(abs(Double(first) * 0.01 - 0.45) < 0.03, "first repeat at \(Double(first) * 0.01) s")
        #expect(abs(Double(second) * 0.01 - 0.90) < 0.03, "second repeat at \(Double(second) * 0.01) s")
        #expect(levels[second] < levels[first] - 3)
    }

    @Test("The horn gets to a new speed within a second or so, and the drum takes several")
    func rotorsEase() {
        let fx = sfx_create(48_000, 2)!
        defer { sfx_destroy(fx) }
        var params = sfx_params_t(kind: Int32(SFX_ROTARY.rawValue), drive: 0.3, tone: 0.5, fast: 0, growl: 0, level: 1)
        sfx_set_params(fx, &params)
        sfx_reset(fx)
        params.fast = 1
        sfx_set_params(fx, &params)
        var left = [Float](repeating: 0.1, count: 512), right = left
        func run(seconds: Double) {
            for _ in 0..<Int(seconds * 48_000 / 512) {
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        var planes: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
                        planes.withUnsafeMutableBufferPointer { sfx_process(fx, $0.baseAddress, 2, 512) }
                    }
                }
            }
        }
        var horn: Float = 0, drum: Float = 0
        run(seconds: 1)
        sfx_rotor_speeds(fx, &horn, &drum)
        #expect(horn > 6, "the horn at \(horn) after a second")
        #expect(drum < 3, "the drum at \(drum) after a second")
        run(seconds: 9)
        sfx_rotor_speeds(fx, &horn, &drum)
        #expect(drum > 5.5, "the drum at \(drum) after ten")
    }

    @Test("A section can turn the speaker fast and set its own echo send; the rest keep the strip's")
    func sectionEffects() {
        let part = PartID(), verse = SectionID(), chorus = SectionID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Organ", echoDB: -12))
        mix.setSectionEffect(SectionEffect(section: chorus, part: part, fast: true, echoDB: -3))
        #expect(mix.insert(for: part, in: verse, instrument: .rotarySlow) == .rotarySlow)
        #expect(mix.insert(for: part, in: chorus, instrument: .rotarySlow) == .rotaryFast)
        #expect(mix.insert(for: part, in: chorus, instrument: nil) == nil)
        #expect(mix.echoDB(for: part, in: verse) == -12 && mix.echoDB(for: part, in: chorus) == -3)
        mix.setSectionEffect(SectionEffect(section: chorus, part: part))
        #expect(mix.sectionEffects == nil)
        // A mix that never touched any of it encodes as it always did.
        let encoded = String(decoding: try! JSONEncoder().encode(Mix.unity), as: UTF8.self)
        #expect(!encoded.contains("echo") && !encoded.contains("room") && !encoded.contains("sectionEffects"))
    }
}
