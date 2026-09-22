import AVFAudio
import AudioEngine
import Foundation
import SongGraph
import Testing

@testable import Performance

// M6 X2: strips in the engine, rendered offline. A −3 dB fader is 3.0 dB; an EQ cut is where it
// says; the limiter's ceiling holds the true peak.

@Suite("Mix graph: strips, EQ, the limiter", .serialized)
struct MixGraphTests {
    private static let rate = 48_000.0

    private func buffer(hz: Double, seconds: Double, amplitude: Float, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<frames { buffer.floatChannelData![channel][i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / Self.rate)) }
        }
        return buffer
    }

    /// Renders one player through a strip at `mix`, and returns planar audio of the output.
    @AudioActor
    private func render(hz: Double, amplitude: Float = 0.25, part: PartID, mix: Mix, seconds: Double = 1) throws -> [[Float]] {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        let player = try engine.player(0)
        try graph.route(player, to: part)
        graph.apply(mix)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: Self.rate))
        player.scheduleBuffer(buffer(hz: hz, seconds: seconds, amplitude: amplitude, format: engine.format), at: nil, options: [], completionHandler: nil)
        player.play()
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(seconds * Self.rate))
        engine.stop()
        let frames = Int(out.frameLength)
        return (0..<Int(out.format.channelCount)).map { c in Array(UnsafeBufferPointer(start: out.floatChannelData![c], count: frames)) }
    }

    /// RMS in dB over the steady middle of the render, past any attack.
    private func middleRMS(_ planar: [[Float]]) -> Double {
        let lane = planar[0]
        let slice = Array(lane[(lane.count / 4)..<(lane.count * 3 / 4)])
        return MixMeter.rmsDB([slice])
    }

    @Test("a strip at unity passes the signal; at −3 dB it is 3.0 dB quieter; muted it is silent")
    @AudioActor
    func fader() async throws {
        let part = PartID()
        let unity = try render(hz: 1_000, part: part, mix: .unity)
        let reference = middleRMS(unity)
        #expect(reference > -20 && reference < -8, "unity \(reference) dB")
        var mix = Mix()
        mix.set(Strip(part: part, label: "Bass", gainDB: -3))
        let down = try render(hz: 1_000, part: part, mix: mix)
        #expect(abs((middleRMS(down) - reference) + 3) < 0.15, "\(middleRMS(down) - reference)")
        mix.set(Strip(part: part, label: "Bass", isMuted: true))
        let muted = try render(hz: 1_000, part: part, mix: mix)
        #expect(MixMeter.samplePeakDB(muted) < -90)
        // Solo on another part silences this one.
        mix = Mix()
        mix.set(Strip(part: PartID(), label: "Other", isSoloed: true))
        let soloedOut = try render(hz: 1_000, part: part, mix: mix)
        #expect(MixMeter.samplePeakDB(soloedOut) < -90)
    }

    @Test("a −6 dB peak band at 80 Hz is −6 there and 0 at 1 kHz")
    @AudioActor
    func eq() async throws {
        let part = PartID()
        var mix = Mix()
        mix.set(Strip(part: part, label: "Kick", eq: [EQBand(shape: .lowShelf, frequency: 100), EQBand(shape: .peak, frequency: 80, gainDB: -6, width: 1),
                                                      EQBand(shape: .highShelf, frequency: 8_000)]))
        let at80 = middleRMS(try render(hz: 80, part: part, mix: mix)) - middleRMS(try render(hz: 80, part: part, mix: .unity))
        let at1k = middleRMS(try render(hz: 1_000, part: part, mix: mix)) - middleRMS(try render(hz: 1_000, part: part, mix: .unity))
        #expect(abs(at80 + 6) < 0.6, "at 80 Hz: \(at80) dB")
        #expect(abs(at1k) < 0.3, "at 1 kHz: \(at1k) dB")
    }

    @Test("the master gain is on the trim; the limiter over the render holds the true peak under the ceiling")
    @AudioActor
    func limiter() async throws {
        let part = PartID()
        var mix = Mix()
        mix.master = Master(gainDB: 12, ceilingDBTP: -1)
        let hot = try render(hz: 1_000, amplitude: 0.5, part: part, mix: mix)
        // +12 dB on a 0.5 sine clips in the render (2.0 peak): the trim is the master gain.
        #expect(MixMeter.samplePeakDB(hot) > 5, "\(MixMeter.samplePeakDB(hot))")
        let limited = Limiter.apply(hot, sampleRate: Self.rate, ceilingDBTP: -1)
        let truePeak = MixMeter.truePeakDB(limited, sampleRate: Self.rate)
        #expect(truePeak <= -1.0, "true peak \(truePeak) dBTP")
        #expect(truePeak > -2.5, "limiting, not silencing: \(truePeak) dBTP")
        let lower = MixMeter.truePeakDB(Limiter.apply(hot, sampleRate: Self.rate, ceilingDBTP: -6), sampleRate: Self.rate)
        #expect(lower <= -6.0 && lower > -7.5, "\(lower)")
        // Under the ceiling already, nothing moves.
        let quiet = try render(hz: 1_000, amplitude: 0.1, part: part, mix: .unity)
        #expect(Limiter.apply(quiet, sampleRate: Self.rate, ceilingDBTP: -1) == quiet)
    }

    @Test("the pool: one more part than slots, and the one that missed out is named rather than silent")
    @AudioActor
    func pool() async throws {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        let slots = MixGraph.slotCount
        let parts = (0...slots).map { _ in PartID() }

        for part in parts.prefix(slots) { #expect(graph.strip(for: part) != nil) }
        #expect(graph.strip(for: parts[slots]) == nil)
        #expect(graph.strips.count == slots)
        // The part that missed out used to be discovered by noticing a fader that did nothing.
        #expect(graph.unseated == [parts[slots]])

        graph.releaseSlots()
        #expect(graph.strips.isEmpty && graph.unseated.isEmpty)
        #expect(graph.strip(for: parts[slots]) != nil)
    }

    @Test("reserve seats the plan's parts in the plan's own order, and says which it could not")
    @AudioActor
    func reserving() async throws {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()
        let parts = (0..<(MixGraph.slotCount + 2)).map { _ in PartID() }

        let missed = graph.reserve(parts)
        #expect(missed == Array(parts.suffix(2)), "the last two asked are the two that miss out")
        #expect(graph.unseated == missed)
        #expect(graph.strips.count == MixGraph.slotCount)
        // Every seated part kept the slot it was given, in order.
        for part in parts.prefix(MixGraph.slotCount) { #expect(graph.strips[part] != nil) }

        // A part with no strip still plays: `route` puts it on the main mixer rather than refusing.
        let player = try engine.player(0)
        try graph.route(player, to: parts[MixGraph.slotCount])
        #expect(graph.part(of: player) == nil, "it was not routed through a strip")
        engine.stop()
    }

    @Test("a slot no part has taken is not metered: the render thread counts only what is playing")
    @AudioActor
    func metersOnlyWhatPlays() async throws {
        let engine = try Engine(playerCount: 1, sampleRate: Self.rate, channels: 2)
        try engine.prepare(offlineSampleRate: Self.rate, maximumFrames: 4_096)
        let graph = try engine.mixGraph()

        // `MixStripNodes.meter` is a per-sample loop over every frame of every channel, on the
        // render thread. It used to be installed on all eight slots at build, so seven idle strips
        // ran it every block for nothing.
        #expect(graph.metered == 0, "a freshly built pool meters nothing")

        let part = PartID()
        #expect(graph.strip(for: part) != nil)
        #expect(graph.metered == 1, "the slot a part took is metered")
        #expect(graph.strip(for: part) != nil)
        #expect(graph.metered == 1, "asking again for the same part does not install a second tap")

        let second = PartID()
        _ = graph.strip(for: second)
        #expect(graph.metered == 2)

        graph.releaseSlots()
        #expect(graph.metered == 0, "giving the slots back stops the metering with them")
        // And the pool still works afterwards: a tap removed and re-installed is an ordinary thing.
        _ = graph.strip(for: part)
        #expect(graph.metered == 1)
        engine.stop()
    }

    @Test("the true peak of a sine between samples reads above its sample peak, and a mix round-trips as a part")
    func truePeakAndCodable() throws {
        // A 11.025 kHz sine at 48 k: samples land off the crests, so the sample peak under-reads.
        var lane = [Float](repeating: 0, count: 48_000)
        for i in 0..<lane.count {
            let phase: Double = 2 * Double.pi * 11_025 * Double(i) / 48_000 + 0.3
            lane[i] = Float(0.5 * sin(phase))
        }
        let sample = MixMeter.samplePeakDB([lane]), truth = MixMeter.truePeakDB([lane], sampleRate: 48_000)
        #expect(truth > sample - 0.05 && abs(truth - 20 * log10(0.5)) < 0.3, "sample \(sample) true \(truth)")
        var mix = Mix()
        mix.set(Strip(part: PartID(), label: "Bass", gainDB: -3, pan: -0.2, compressor: Compressor(), sendDB: -12))
        mix.sectionGains = [SectionGain(section: SectionID(), part: mix.strips[0].part, gainDB: -6)]
        let data = try JSONEncoder().encode(PartKind.mix(mix))
        let back = try JSONDecoder().decode(PartKind.self, from: data)
        #expect(back == .mix(mix) && back.type == .mix)
        #expect(mix.levelDB(for: mix.strips[0].part, in: mix.sectionGains[0].section) == -6)
        #expect(mix.levelDB(for: mix.strips[0].part) == -3)
    }
}
