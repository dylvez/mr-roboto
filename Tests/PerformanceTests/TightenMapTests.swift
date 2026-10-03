import Analysis
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import Performance

// Tightening: each of a record's bars pinned to one of the song's. The sums: the tracker's jitter
// smoothed out but the record's real drift kept, no bar stretched past 8% of the rest, and every
// bar line of a tightened plan on a bar line of the song.

@Suite("Sources: tightened bar by bar")
struct TightenMapTests {
    /// Bar lines of a record that slows from 100 to about 90 bpm over thirty-two bars.
    private static let slowing: [SongGraph.TimeRange] = {
        var lines: [Double] = [0.5]
        for bar in 0..<32 { lines.append(lines.last! + 2.4 * (1 + Double(bar) * 0.0035)) }
        return zip(lines, lines.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }
    }()

    @Test("a record that really slows or swings keeps every bar line; a misread one is put back and its neighbours are not touched")
    func misread() {
        #expect(TightenMap.smoothed(Self.slowing) == Self.slowing)
        // Swinging 5% over twelve bars, as a band pushing and dragging might.
        var lines: [Double] = [0.5]
        for bar in 0..<40 { lines.append(lines.last! + 2.4 / (1 + 0.05 * sin(2 * .pi * Double(bar) / 12))) }
        let swinging = zip(lines, lines.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }
        #expect(TightenMap.smoothed(swinging) == swinging)

        for late in [0.05, 0.1, 0.3] {
            var read = lines
            read[20] += late
            let fixed = TightenMap.smoothed(zip(read, read.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }).map(\.start)
            #expect(abs(fixed[20] - lines[20]) < 0.005, "misread by \(late * 1000) ms, put back to \((fixed[20] - lines[20]) * 1000) ms")
            #expect(fixed.indices.filter { $0 != 20 }.allSatisfy { fixed[$0] == read[$0] }, "no other line moves")
        }
        // A record whose every bar line is a little off — ordinary timing — is left as it is.
        var seed: UInt64 = 7
        let loose = lines.map { line -> Double in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return line + (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * 0.015
        }
        let bars = zip(loose, loose.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }
        #expect(TightenMap.smoothed(bars) == bars)
    }

    @Test("no bar is stretched more than 8% from the rest; a held bar is caught up after")
    func held() {
        // Five bars of 2 s onto bars of 2 s, but the third pinned 0.4 s late.
        let pins = [TightenMap.Pin(source: 2, output: 2), TightenMap.Pin(source: 4, output: 4.4),
                    TightenMap.Pin(source: 6, output: 6), TightenMap.Pin(source: 8, output: 8), TightenMap.Pin(source: 10, output: 10)]
        let (anchors, held) = TightenMap.anchors(pins, ratio: 1)
        #expect(held >= 1 && anchors[1].output < 4.4, "the late line is not reached in one bar")
        let stretches = zip([StretchAnchor(input: 0, output: 0)] + anchors, anchors).map { ($1.output - $0.output) / ($1.input - $0.input) }
        #expect(stretches.allSatisfy { $0 <= 1.08 + 1e-9 && $0 >= 0.92 - 1e-9 }, "\(stretches)")
        #expect(abs(anchors.last!.output - 10) < 1e-9, "caught up by the end")
    }

    @Test("a tightened whole stem: every bar line of the record on a bar line of the song")
    func whole() {
        let source = SourceMaterial(label: "Drifter", tempo: 95, bars: Self.slowing, duration: 90)
        let plan = SourceFitting.plan(source, into: MergeTarget(tempo: 100), shape: .whole(atBar: 2), tighten: true)
        let anchors = try! #require(plan.anchors)
        #expect(plan.held == 0 && plan.sentences.contains { $0.hasPrefix("Tightened") })
        let lines = TightenMap.smoothed(Self.slowing).map(\.start)
        for (index, line) in lines.enumerated() {
            let transport = plan.offset + plan.output(atSource: line - plan.region.start)
            #expect(abs(transport - Double(2 + index) * 2.4) < 1e-6, "bar \(index + 1) at \(transport)")
        }
        #expect(anchors.count >= 32)
        // Untightened, at its average tempo, the same record is a beat and more off in the middle.
        let loose = SourceFitting.plan(source, into: MergeTarget(tempo: 100), shape: .whole(atBar: 2))
        let worst = Self.slowing.enumerated().map { index, bar in
            abs(loose.offset + loose.output(atSource: bar.start - loose.region.start) - Double(2 + index) * 2.4)
        }.max() ?? 0
        #expect(loose.anchors == nil && worst > 0.6, "\(worst) s")
    }

    @Test("a tightened clip: each of its bars an equal share of the song's, its end on theirs")
    func clip() {
        let source = SourceMaterial(label: "Drifter", tempo: 95, bars: Self.slowing, duration: 90)
        let plan = SourceFitting.plan(source, into: MergeTarget(tempo: 100), shape: .clip(from: 20, to: 24), tighten: true)
        #expect(plan.bars == 4 && plan.isTightened)
        let lines = TightenMap.smoothed(Self.slowing)[20...23].map(\.start)
        for (step, line) in lines.enumerated() {
            #expect(abs(plan.output(atSource: line - plan.region.start) - Double(step) * 2.4) < 1e-6)
        }
        #expect(abs(plan.output(atSource: plan.region.duration) - 4 * 2.4) < 1e-6)
        // Rebased for a preview of its middle two bars.
        let middle = try! #require(plan.anchors(from: lines[1] - plan.region.start, to: lines[3] - plan.region.start))
        #expect(abs(middle.last!.output - 2 * 2.4) < 1e-6)
    }
}
