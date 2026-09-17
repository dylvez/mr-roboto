import Analysis
import AVFoundation
import Foundation
import Instrument
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The real material, and the listening artifact.
///
/// The integration test runs whenever the drum stem is checked out and writes one WAV whose path it
/// prints, because the acceptance test for "chop a bar and play it in another feel" is somebody's
/// ears. The larger demo set is off by default; from a normal Terminal:
///
///     CHOP_DEMO=1 swift test --filter chopDemo
///
/// Same idiom as `SYNTH_DEMO` in `Tests/InstrumentTests/SynthDemoRenderTests.swift`.
@Suite("Chop demos")
struct ChopDemoTests {
    static let sr: Double = 48_000
    /// Which bar of the stem gets chopped. Bar 9 counting from one, so index 8.
    static let barIndex = 8

    // MARK: Loading the real stem

    struct Source {
        var mono: [Float]
        var grid: BeatGrid
        var barStart: Double
        var barEnd: Double
        var bar: [Float]
        var bpm: Double
    }

    /// The drum stem, its golden grid, and bar `barIndex` of it. Nil when the stem is not present.
    static func arrivalBar() throws -> Source? {
        guard let stem = ChopPaths.drumStem else { return nil }
        let beatsURL = ChopPaths.repoRoot.appendingPathComponent("Bench/goldens/Arrival/beats.json")
        guard FileManager.default.fileExists(atPath: beatsURL.path) else { return nil }

        let golden = try BeatComparison.Golden(contentsOf: beatsURL)
        let grid = BeatGrid(beats: golden.beats, bars: golden.downbeats)
        let mono = try Resampler(targetSampleRate: sr).monoSamples(fromFileAt: stem)
        guard let bounds = grid.bounds(ofBar: barIndex) else { return nil }
        let from = max(0, Int((bounds.start * sr).rounded()))
        let to = min(mono.count, Int((bounds.end * sr).rounded()))
        guard to > from else { return nil }
        return Source(mono: mono, grid: grid, barStart: bounds.start, barEnd: bounds.end,
                      bar: Array(mono[from..<to]), bpm: grid.bpm ?? 112)
    }

    // MARK: Integration

    @Test("bar 9 of the Arrival drum stem, chopped and re-grooved")
    func arrivalBarNine() throws {
        guard let source = try Self.arrivalBar() else {
            print("Bench/goldens/Arrival/stems/drums.wav not present; skipping the chop integration test")
            return
        }

        let chopper = Chopper()
        let chop = chopper.sliceByOnsets(source.bar, sampleRate: Self.sr, snappingTo: source.grid,
                                         division: 4, sourceOffset: source.barStart,
                                         detectedTempo: source.bpm)
        let classes = SliceClassifier().classify(chop, in: source.bar)
        let map = ChopMap.pads(chop, name: "Arrival bar \(Self.barIndex + 1)")

        print("")
        print("=== Arrival drums, bar \(Self.barIndex + 1) "
              + String(format: "(%.3f–%.3f s, %.1f bpm) ===", source.barStart, source.barEnd, source.bpm))
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
        }
        print([pad("slice", 5), pad("start s", 9), pad("len s", 9), pad("sound s", 9),
               pad("peak", 8), pad("centroid", 9), pad("class", 7), pad("conf", 6),
               pad("origin", 9)].joined(separator: " "))
        for (slice, klass) in zip(chop.slices, classes) {
            print([pad("\(slice.index)", 5),
                   pad(String(format: "%.3f", slice.startSeconds), 9),
                   pad(String(format: "%.3f", slice.duration), 9),
                   pad(String(format: "%.3f", klass.effectiveDuration), 9),
                   pad(String(format: "%.3f", Double(slice.peak)), 8),
                   pad(String(format: "%.0f", klass.centroid), 9),
                   pad(klass.kind.rawValue, 7),
                   pad(String(format: "%.2f", klass.confidence), 6),
                   pad(slice.origin.rawValue, 9)].joined(separator: " "))
        }
        let snapped = chop.slices.filter { $0.origin == .snapped }
        print("slices: \(chop.count)  (onsets \(chop.onsetSlices.count), snapped \(snapped.count))")
        if !snapped.isEmpty {
            let offsets = snapped.map { $0.snapOffset * 1000 }
            print(String(format: "snap offsets ms: min %.1f, max %.1f, mean %.1f",
                         offsets.min() ?? 0, offsets.max() ?? 0,
                         offsets.reduce(0, +) / Double(offsets.count)))
        }
        let counts = Dictionary(grouping: classes, by: \.kind).mapValues(\.count)
        print("classes: " + SliceClass.allCases.map { "\($0.rawValue) \(counts[$0] ?? 0)" }
            .joined(separator: ", "))
        // How much of the slicing is the detector's threshold rather than the music. Printed
        // because "how many pads do I get" is the first thing anybody asks of a chopper, and the
        // answer is a tuning decision that should be visible rather than buried.
        for threshold in [Float(3), 4, 5, 6] {
            var detector = SpectralFluxOnsetDetector()
            detector.threshold = threshold
            var sensitive = Chopper()
            sensitive.detector = detector
            let alternative = sensitive.sliceByOnsets(source.bar, sampleRate: Self.sr,
                                                      snappingTo: source.grid, division: 4,
                                                      sourceOffset: source.barStart)
            print("  onset threshold \(threshold): \(alternative.count) slices")
        }

        #expect(chop.count >= 4, "a bar of a break should cut into at least four slices")
        #expect(chop.slices.allSatisfy { $0.frameCount > 0 })
        #expect(chop.slices.last?.end == source.bar.count)
        #expect(classes.contains { $0.kind == .kick })

        // Re-groove it onto a boom-bap feel at 88 bpm and render through the real sampler.
        let target = BeatGrid.regular(bpm: 88, bars: 4)
        let performance = try Regroove().perform(map, classifications: classes,
                                                 groove: ChopFixtures.boomBap(swing: 0.3),
                                                 grid: target, repeats: 2)
        #expect(!performance.hits.isEmpty)
        #expect(performance.unplacedSteps == 0)

        let folder = ChopPaths.demoFolder.appendingPathComponent("arrival-bar\(Self.barIndex + 1)",
                                                                 isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let kit = try performance.map.render(source: [source.bar], stretch: SliceStretch())
        let loaded = try kit.write(to: folder.appendingPathComponent("kit", isDirectory: true))
        let rendered = try ChopRender.render(loaded, hits: performance.hits,
                                             seconds: performance.duration + 1.5, sampleRate: Self.sr)
        #expect(ChopSignal.peak(rendered) > 0.01)

        let url = folder.appendingPathComponent("arrival-bar\(Self.barIndex + 1)-boombap-88.wav")
        try ChopAudio.writeWAV([Self.normalised(rendered)], to: url, sampleRate: Self.sr)
        print("")
        print("Listen:  afplay \(url.path)")
        print("")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: The demo set

    @Test("chop demo", .enabled(if: ProcessInfo.processInfo.environment["CHOP_DEMO"] != nil))
    func chopDemo() throws {
        let root = ChopPaths.demoFolder
        // Clear this demo's own output only: the integration test writes an `arrival-bar9` folder
        // into the same place and a blanket delete would take it with us.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix("kit") || name.first?.isNumber == true {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bar: [Float]
        let grid: BeatGrid
        let offset: Double
        let sourceName: String
        if let source = try Self.arrivalBar() {
            bar = source.bar
            grid = source.grid
            offset = source.barStart
            sourceName = "Arrival drums, bar \(Self.barIndex + 1), \(String(format: "%.1f", source.bpm)) bpm"
        } else {
            let synthetic = ChopFixtures.breakBar(bpm: 90, sampleRate: Self.sr)
            bar = synthetic.signal
            grid = BeatGrid.regular(bpm: 90, bars: 1)
            offset = 0
            sourceName = "synthetic break bar, 90 bpm (the real stem is not checked out)"
        }

        let chop = Chopper().sliceByOnsets(bar, sampleRate: Self.sr, snappingTo: grid,
                                           division: 4, sourceOffset: offset)
        let classes = SliceClassifier().classify(chop, in: bar)
        let map = ChopMap.pads(chop, name: "Demo chop")

        print("")
        print("=== Chop demo: \(sourceName) ===")
        print("\(chop.count) slices; " + SliceClass.allCases.map { kind in
            "\(kind.rawValue) \(classes.filter { $0.kind == kind }.count)"
        }.joined(separator: ", "))
        print("")

        var written: [(label: String, url: URL)] = []

        // 1. The bar as it came.
        let originalURL = root.appendingPathComponent("00-original-bar.wav")
        try ChopAudio.writeWAV([Self.normalised(bar)], to: originalURL, sampleRate: Self.sr)
        written.append(("the bar as it came off the record", originalURL))

        // 2. The chop, played back in its own order. Should be indistinguishable from (1): if it
        //    is not, the windows or the rate are wrong and everything below is wrong with them.
        let kit = try map.render(source: [bar])
        let selfCheck = try ChopRender.render(kit, hits: map.nativeHits(),
                                              seconds: chop.duration + 0.5, sampleRate: Self.sr,
                                              in: root.appendingPathComponent("kit", isDirectory: true))
        let selfCheckURL = root.appendingPathComponent("01-chopped-original-order.wav")
        try ChopAudio.writeWAV([Self.normalised(selfCheck)], to: selfCheckURL, sampleRate: Self.sr)
        written.append(("the same bar, but every hit fired from its own pad", selfCheckURL))

        let reference = bar.map { $0 * Float(cos(Double.pi / 4)) }
        let n = min(reference.count, selfCheck.count)
        let r = ChopSignal.correlation(selfCheck[0..<n], reference[0..<n])
        print(String(format: "self-check: chopped-in-order vs original, r = %.6f", r))
        #expect(r > 0.99, "the chop played in its own order does not reproduce the bar (r = \(r))")

        // 3. and 4. The same chop in two other feels, at two other tempos.
        let feels: [(name: String, groove: Groove, bpm: Double)] = [
            ("boombap-76", ChopFixtures.boomBap(swing: 0.35), 76),
            ("fourfour-124", ChopFixtures.fourFour(), 124),
        ]
        for (index, feel) in feels.enumerated() {
            let target = BeatGrid.regular(bpm: feel.bpm, bars: 6)
            var policy = Regroove.Policy()
            policy.overlap = feel.bpm > 110 ? .stretchToFit : .ring
            let performance = try Regroove(policy: policy).perform(
                map, classifications: classes, groove: feel.groove, grid: target, repeats: 4)
            let folder = root.appendingPathComponent("kit-\(feel.name)", isDirectory: true)
            let regrooved = try performance.map.render(source: [bar], stretch: SliceStretch())
            let audio = try ChopRender.render(regrooved, hits: performance.hits,
                                              seconds: performance.duration + 1.5,
                                              sampleRate: Self.sr, in: folder)
            let url = root.appendingPathComponent(String(format: "%02d-%@.wav", index + 2, feel.name))
            try ChopAudio.writeWAV([Self.normalised(audio)], to: url, sampleRate: Self.sr)
            written.append(("re-grooved: \(feel.name), \(policy.overlap.rawValue)", url))
            print("\(feel.name): \(performance.hits.count) hits, "
                  + "\(performance.map.mappings.count - map.mappings.count) stretched pads, "
                  + String(format: "%.1f s", performance.duration))
        }

        print("")
        print("Play these in order — 00 and 01 should be the same thing:")
        for entry in written { print("  afplay \(entry.url.path)   # \(entry.label)") }
        print("")
        print("Everything is under: \(root.path)")
        print("")

        for entry in written { #expect(FileManager.default.fileExists(atPath: entry.url.path)) }
    }

    // MARK: Helpers

    /// Peak-normalised to -1 dBFS, so every file plays back at a comparable level.
    static func normalised(_ x: [Float]) -> [Float] {
        let peak = ChopSignal.peak(x)
        guard peak > 0 else { return x }
        let scale = Float(pow(10, -1.0 / 20)) / peak
        return x.map { $0 * scale }
    }
}
