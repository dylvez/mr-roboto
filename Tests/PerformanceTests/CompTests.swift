import AudioEngine
import Foundation
import SongGraph
import Testing

@testable import Performance

// M5 R4: a comp of three takes has the bars the plan named and no click at a seam.

@Suite("Comp: takes chosen bar by bar, seams crossfaded")
struct CompTests {
    private let rate = 48_000.0
    private let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)

    /// A tone, with an optional dip to silence whose edges ramp over 5 ms so the material itself
    /// has no click in it.
    private func tone(_ hz: Double, seconds: Double, gap: ClosedRange<Double>? = nil) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var envelope = 1.0
            if let gap {
                let ramp = 0.005
                if gap.contains(t) { envelope = 0 }
                else if t < gap.lowerBound, gap.lowerBound - t < ramp { envelope = 0.5 - 0.5 * cos(.pi * (gap.lowerBound - t) / ramp) }
                else if t > gap.upperBound, t - gap.upperBound < ramp { envelope = 0.5 - 0.5 * cos(.pi * (t - gap.upperBound) / ramp) }
            }
            return Float(0.5 * envelope * sin(2 * .pi * hz * t))
        }
    }

    @Test("bars come from the takes the plan named, and the seams do not click")
    func rendersAPlan() throws {
        let a = VersionID(), b = VersionID(), c = VersionID()
        // Three 6-second takes (three bars at 120), each a different tone, all aligned at 0. Take
        // A has a 30 ms silence just before bar 2 for the seam to find.
        let takes: [VersionID: Comp.TakeAudio] = [
            a: .init(planar: [tone(220, seconds: 6, gap: 1.965...1.995)], sampleRate: rate, alignmentSeconds: 0),
            b: .init(planar: [tone(330, seconds: 6)], sampleRate: rate, alignmentSeconds: 0),
            c: .init(planar: [tone(440, seconds: 6)], sampleRate: rate, alignmentSeconds: 0),
        ]
        let plan = CompPlan(spans: [.init(startBar: 0, endBar: 1, take: a), .init(startBar: 1, endBar: 2, take: b), .init(startBar: 2, endBar: 3, take: c)])
        let out = try Comp.render(plan, takes: takes, clock: clock)
        #expect(out.planar[0].count == Int(6 * rate) && out.alignmentSeconds == 0)
        #expect(out.seams.count == 2)
        // The seam out of A snapped into A's silence, not onto the bar line.
        #expect(out.seams[0] > 1.965 && out.seams[0] < 1.995, "\(out.seams[0])")
        #expect(abs(out.seams[1] - 4.0) <= 0.04)

        // Away from the seams, each bar is its take's tone, sample for sample.
        func at(_ seconds: Double) -> Float { out.planar[0][Int(seconds * rate)] }
        #expect(abs(at(0.5) - takes[a]!.planar[0][Int(0.5 * rate)]) < 1e-6)
        #expect(abs(at(3.0) - takes[b]!.planar[0][Int(3.0 * rate)]) < 1e-6)
        #expect(abs(at(5.0) - takes[c]!.planar[0][Int(5.0 * rate)]) < 1e-6)

        // No click: the largest step across each seam is within the tones' own steps — a cut would
        // be a step of the whole amplitude, sixteen times that.
        let ownStep = (1..<Int(rate)).map { abs(takes[c]!.planar[0][$0] - takes[c]!.planar[0][$0 - 1]) }.max()!
        for seam in out.seams {
            let centre = Int(seam * rate)
            let steps = ((centre - 600)..<(centre + 600)).map { abs(out.planar[0][$0] - out.planar[0][$0 - 1]) }
            #expect(steps.max()! <= ownStep * 1.5, "a click at the seam \(seam): step \(steps.max()!) vs \(ownStep)")
        }
    }

    @Test("a take placed later in the song reads from its own frame 0 at its alignment, and outside it is silence")
    func alignment() throws {
        let a = VersionID()
        let takes: [VersionID: Comp.TakeAudio] = [a: .init(planar: [tone(220, seconds: 2)], sampleRate: rate, alignmentSeconds: 2.5)]
        let plan = CompPlan(spans: [.init(startBar: 1, endBar: 3, take: a)])
        let out = try Comp.render(plan, takes: takes, clock: clock)
        #expect(out.alignmentSeconds == 2.0 && out.planar[0].count == Int(4 * rate))
        #expect(out.planar[0][Int(0.25 * rate)] == 0, "before the take begins is silence")
        #expect(abs(out.planar[0][Int(1.0 * rate)] - takes[a]!.planar[0][Int(0.5 * rate)]) < 1e-6)
        #expect(out.planar[0][Int(3.0 * rate)] == 0, "after the take ends is silence")
    }

    @Test("a plan naming a take that is not there, or no bars, is refused")
    func refusals() {
        #expect(throws: Comp.Failure.self) { try Comp.render(CompPlan(spans: []), takes: [:], clock: clock) }
        #expect(throws: Comp.Failure.self) {
            try Comp.render(CompPlan(spans: [.init(startBar: 0, endBar: 1, take: VersionID())]), takes: [:], clock: clock)
        }
    }
}
