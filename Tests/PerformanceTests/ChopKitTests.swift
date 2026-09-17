import AVFoundation
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The load-bearing assumption of the whole design: many zones, one buffer, different windows.
///
/// Apple's own sampler is known to misbehave when several regions point at one file, which is why
/// most chop implementations write a WAV per slice. The render core here is ours, so the question
/// is answerable rather than folklore — these tests render every pad through the real
/// `VoiceSampler` and check that each one produced its own slice's samples and nobody else's.
@Suite("Chop kit: zones sharing one buffer")
struct ChopKitTests {
    static let sr: Double = 48_000
    /// Centre pan is -3 dB a side and a mono render sums the two, so a unity-gain zone comes back
    /// at cos(π/4) of the source. Measured below as well as asserted, so a change to the core's
    /// pan law shows up as a failed expectation rather than as a mysterious level.
    static let monoPanGain = Float(cos(Double.pi / 4))

    /// A bar of four different sounds, one per beat: two kicks, a snare, a hat. Different enough
    /// that a zone playing the wrong window cannot pass by accident.
    static func bar() -> (signal: [Float], chop: Chop) {
        let sr = Self.sr
        let sounds: [[Float]] = [
            ChopFixtures.kick(sr),
            ChopFixtures.snare(sr),
            ChopFixtures.hat(sr),
            ChopFixtures.decayingSine(sampleRate: sr, frequency: 320, duration: 0.25, decay: 12),
        ]
        let signal = ChopFixtures.place(sounds.enumerated().map { (Double($0.offset) * 0.5, $0.element) },
                                        length: 2, sampleRate: sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: sr, divisions: 4)
        return (signal, chop)
    }

    // MARK: Shape of the kit

    @Test("every zone points at the one file, with its own window")
    func oneFileManyWindows() throws {
        let (signal, chop) = Self.bar()
        let kit = try ChopMap.pads(chop, name: "Bar").render(source: [signal])

        #expect(kit.manifest.samplePaths.count == 1)
        #expect(kit.manifest.zones.count == chop.count)
        #expect(kit.frameCount == signal.count, "nothing should be appended for a plain chop")
        for (zone, slice) in zip(kit.manifest.zones, chop.slices) {
            #expect(zone.sample == kit.sampleFileName)
            #expect(zone.sampleStart == slice.start)
            #expect(zone.sampleEnd == slice.end)
        }
    }

    @Test("the shared file is decoded exactly once, however many zones read it")
    func decodedOnce() throws {
        let (signal, chop) = Self.bar()
        let kit = try ChopMap.pads(chop, name: "Bar").render(source: [signal])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chop-decode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loaded = try kit.write(to: folder)

        let cache = SampleCache()
        let sampler = VoiceSampler(cache: cache)
        try sampler.prepare(loaded, sampleRate: Self.sr, channels: 1)
        defer { sampler.unprepare() }

        #expect(cache.decodeCount == 1)
        #expect(cache.count == 1)
        #expect(sampler.zoneCount == chop.count)
    }

    // MARK: The real question

    @Test("each pad renders its own slice and nobody else's")
    func eachPadPlaysItsOwnWindow() throws {
        let (signal, chop) = Self.bar()
        let map = ChopMap.pads(chop, name: "Bar")
        let kit = try map.render(source: [signal])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chop-pads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loaded = try kit.write(to: folder)

        var scales: [Float] = []
        for slice in chop.slices {
            let note = try #require(map.note(forSlice: slice.index))
            let rendered = try ChopRender.render(loaded,
                                                 hits: [.init(note: note, velocity: 127, at: 0)],
                                                 seconds: slice.duration, sampleRate: Self.sr)
            #expect(rendered.count >= slice.frameCount - 1)

            let expected = Array(signal[slice.range])
            let n = min(rendered.count, expected.count)
            // Its own slice, sample for sample (modulo the constant pan gain).
            let own = ChopSignal.correlation(rendered[0..<n], expected[0..<n])
            #expect(own > 0.99999, "pad \(slice.index) does not play its own slice (r = \(own))")

            let scale = Float(ChopSignal.rms(rendered[0..<n]) / max(1e-12, ChopSignal.rms(expected[0..<n])))
            scales.append(scale)
            let scaled = expected.map { $0 * scale }
            let worst = ChopSignal.maxDifference(Array(rendered[0..<n]), Array(scaled[0..<n]))
            #expect(worst < 1e-5, "pad \(slice.index) differs from its slice by \(worst)")

            // And not anybody else's: a zone that ignored sampleStart would play slice 0 every time.
            for other in chop.slices where other.index != slice.index {
                let m = min(n, other.frameCount)
                let cross = ChopSignal.correlation(rendered[0..<m], signal[other.range].prefix(m))
                #expect(abs(cross) < 0.5,
                        "pad \(slice.index) correlates \(cross) with slice \(other.index)")
            }
        }
        // The level is one constant across every pad — the pan law, not a per-zone accident.
        let spread = (scales.max() ?? 0) - (scales.min() ?? 0)
        #expect(spread < 1e-5)
        #expect(abs((scales.first ?? 0) - Self.monoPanGain) < 1e-4,
                "mono pan gain measured at \(scales.first ?? 0)")
    }

    @Test("playing the chop back in order reproduces the bar")
    func originalOrderReproducesTheSource() throws {
        let (signal, chop) = Self.bar()
        let map = ChopMap.pads(chop, name: "Bar")
        let kit = try map.render(source: [signal])
        let rendered = try ChopRender.render(kit, hits: map.nativeHits(),
                                             seconds: chop.duration, sampleRate: Self.sr)

        let n = min(rendered.count, signal.count)
        let expected = signal.map { $0 * Self.monoPanGain }
        let r = ChopSignal.correlation(rendered[0..<n], expected[0..<n])
        #expect(r > 0.9999, "the chop played in order does not reproduce the bar (r = \(r))")

        // Exact, apart from the core's 2 ms declick ramp where a slice ends mid-waveform.
        let worst = ChopSignal.maxDifference(Array(rendered[0..<n]), Array(expected[0..<n]))
        #expect(worst < 0.02, "worst sample error \(worst)")
    }

    // MARK: Per-slice treatment

    @Test("pitch, gain and reverse are per pad")
    func perSliceTreatment() throws {
        let (signal, chop) = Self.bar()
        var map = ChopMap.pads(chop, name: "Bar")
        map.mappings[1].tuneCents = -1200
        map.mappings[2].gainDB = -6
        map.mappings[3].reverse = true
        let kit = try map.render(source: [signal])

        #expect(kit.manifest.zones[1].tuneCents == -1200)
        #expect(kit.manifest.zones[2].gainDB == -6)
        // The reversed pad could not be a window into the original audio, so it was appended —
        // to the same file, not to a second one.
        #expect(kit.manifest.samplePaths.count == 1)
        #expect(kit.frameCount > signal.count)
        let reversed = kit.manifest.zones[3]
        #expect(reversed.sampleStart >= signal.count)
        #expect(reversed.sampleEnd.map { $0 - reversed.sampleStart } == chop.slices[3].frameCount)

        let source = Array(signal[chop.slices[3].range])
        let appended = Array(kit.audio[0][reversed.sampleStart..<(reversed.sampleEnd ?? 0)])
        #expect(ChopSignal.maxDifference(appended, Array(source.reversed())) < 1e-6)
    }

    @Test("a stretched pad is appended, not written to a second file")
    func stretchedPadStaysInOneFile() throws {
        let (signal, chop) = Self.bar()
        var map = ChopMap.pads(chop, name: "Bar")
        let note = map.addPad(sliceIndex: 0, stretchRatio: 1.5, label: "slow kick")
        let cache = SliceStretch()
        let kit = try map.render(source: [signal], stretch: cache)

        #expect(cache.stretchCount == 1)
        #expect(kit.manifest.samplePaths.count == 1)
        let zone = try #require(kit.manifest.zones.first { $0.key.noteRange.contains(note) })
        let length = (zone.sampleEnd ?? 0) - zone.sampleStart
        let expected = Int((Double(chop.slices[0].frameCount) * 1.5).rounded())
        #expect(abs(length - expected) <= 1)
    }

    // MARK: The file on disk

    @Test("a buffer whose length is not a whole number of blocks survives the round trip")
    func wholeFileRoundTrip() throws {
        // 102,720 frames is 100 blocks of 1024 plus 320. Written and read back with one
        // `read(into:frameCount:)` it comes back as 102,400 — a silent short read, and for a chop
        // it is the last slice's tail. This is the regression test for that.
        let frames = 102_720
        let signal = (0..<frames).map { Float(sin(Double($0) * 0.01)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chop-roundtrip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try ChopAudio.writeWAV([signal], to: url, sampleRate: Self.sr)
        let back = try ChopAudio.readPlanar(url)
        #expect(back.planar[0].count == frames)
        #expect(ChopSignal.maxDifference(back.planar[0], signal) < 1e-6)

        let decoded = try SampleCache.decodeFile(url, Self.sr)
        #expect(decoded.channels[0].count == frames)
        #expect(ChopSignal.maxDifference(decoded.channels[0], signal) < 1e-6)
    }

    @Test("the last slice keeps its tail all the way through the sampler")
    func lastSliceKeepsItsTail() throws {
        // Same length as above, sliced in two, played back in order: the end of the bar must still
        // be there after the write, the decode, the zone table and the C core.
        let frames = 102_720
        let sr = Self.sr
        let signal = ChopFixtures.place([(0, ChopFixtures.kick(sr)),
                                         (Double(frames) / sr - 0.25,
                                          ChopFixtures.decayingSine(sampleRate: sr, frequency: 440,
                                                                    duration: 0.25, decay: 6))],
                                        length: Double(frames) / sr, sampleRate: sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: sr, divisions: 2)
        let map = ChopMap.pads(chop, name: "Tail")
        let kit = try map.render(source: [signal])
        let rendered = try ChopRender.render(kit, hits: map.nativeHits(),
                                             seconds: chop.duration, sampleRate: sr)

        let tail = (frames - 4_000)..<min(frames, rendered.count)
        #expect(ChopSignal.rms(rendered[tail]) > 0.01,
                "the end of the bar is missing: \(ChopSignal.rms(rendered[tail]))")
    }

    @Test("a chop of a stereo source keeps both channels")
    func stereoSource() throws {
        let (mono, chop) = Self.bar()
        let right = mono.map { $0 * 0.5 }
        let kit = try ChopMap.pads(chop, name: "Bar").render(source: [mono, right])

        #expect(kit.channelCount == 2)
        #expect(kit.audio[0].count == kit.audio[1].count)
    }
}
