import Foundation
import Instrument
import MusicTheory
import Testing
@testable import Performance

/// Does a chop *sound* like a chop, or like static?
///
/// The demos were once described as "staticy and glitchy, not chopped", and the difference between
/// the two is measurable without ears: a click is a step, and a step is a single-sample difference
/// far larger than anything the source material contains. The bar these tests use has a largest
/// single-sample difference of its own; chopping it up and playing it back in another order must
/// not introduce anything much bigger.
///
/// Two defects produced those steps, and each is pinned here:
///
///  1. **The slice start.** A chopped slice begins wherever the transient was, part-way up a cycle,
///     and a voice that starts at full amplitude steps the output from silence to that value in one
///     sample. Fixed by backing the cut up to the nearest quiet frame (`Chopper.zeroCrossingWindow`)
///     and, where the material offers no quiet frame, by a fade sized from the sample the pad has to
///     climb (`ChopMap.Declick`).
///  2. **The slice end.** The render core's ramp existed but never ran: a voice reaching the end of
///     its window mid-segment stopped producing output and only picked the ramp up when the *next*
///     segment began, which on a 4096-frame block is a hard cut followed up to 85 ms later by a step
///     back up to the held value. Fixed in `vr_render_voice`; pinned from the sampler's side in
///     `InstrumentTests.VoiceSamplerTests`.
@Suite("Chop continuity")
struct ChopContinuityTests {
    static let sr: Double = 48_000
    /// Centre pan is -3 dB a side and a mono render sums the two, so everything comes back scaled
    /// by this. Deltas measured on the render are compared against source deltas scaled the same.
    static let monoPanGain = Float(cos(Double.pi / 4))

    // MARK: Material

    /// A sustained, continuous tone — no silence anywhere in it.
    ///
    /// Deliberately not a drum fixture: every one of those starts and ends at zero, so every cut
    /// lands in silence and the defect cannot show. Here every cut lands part-way up a cycle, which
    /// is what a chop of a real record looks like and is the case that clicks.
    static func sustained(seconds: Double, sampleRate: Double) -> [Float] {
        let partials: [(frequency: Double, amplitude: Double, phase: Double)] = [
            (110, 0.35, 0.0), (173, 0.25, 1.1), (262, 0.20, 2.3), (415, 0.12, 0.6),
        ]
        let n = Int((seconds * sampleRate).rounded())
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            var x = 0.0
            for p in partials { x += p.amplitude * sin(2 * .pi * p.frequency * t + p.phase) }
            return Float(x)
        }
    }

    /// Largest absolute difference between neighbouring samples.
    static func maximumStep(_ x: [Float]) -> Float {
        guard x.count > 1 else { return 0 }
        var worst: Float = 0
        for i in 1..<x.count { worst = max(worst, abs(x[i] - x[i - 1])) }
        return worst
    }

    /// Frames where the signal steps by more than `threshold` in one sample — the clicks.
    static func steps(in x: [Float], above threshold: Float) -> [Int] {
        guard x.count > 1 else { return [] }
        return (1..<x.count).filter { abs(x[$0] - x[$0 - 1]) > threshold }
    }

    /// A fixed, non-identity permutation of `count` indices: the chop played in somebody else's
    /// order, which is the whole point of a chop and the only arrangement where both ends of every
    /// slice are exposed.
    static func scrambled(_ count: Int) -> [Int] {
        (0..<count).map { ($0 * 7 + 3) % count }
    }

    /// The chop, the kit and the hits that play `order` back to back with no gaps.
    static func performance(divisions: Int = 16, seconds: Double = 2,
                            chopper: Chopper = Chopper(),
                            declick: ChopMap.Declick = .default)
        throws -> (signal: [Float], map: ChopMap, kit: ChopKit, hits: [VoiceSampler.Hit], end: Double) {
        let signal = sustained(seconds: seconds, sampleRate: sr)
        let chop = chopper.sliceByDivisions(signal, sampleRate: sr, divisions: divisions)
        var map = ChopMap.pads(chop, name: "Continuity")
        map.declick = declick
        let kit = try map.render(source: [signal])

        var hits: [VoiceSampler.Hit] = []
        var time = 0.0
        for index in scrambled(chop.count) {
            guard let note = map.note(forSlice: index) else { continue }
            hits.append(VoiceSampler.Hit(note: note, velocity: 127, at: time))
            time += chop.slices[index].duration
        }
        return (signal, map, kit, hits, time)
    }

    // MARK: The regression

    @Test("a multi-slice chop plays back without a single click")
    func chopPlaysWithoutClicks() throws {
        let (signal, _, kit, hits, end) = try Self.performance()
        let rendered = try ChopRender.render(kit, hits: hits, seconds: end + 0.05, sampleRate: Self.sr)

        // What the material itself does between neighbouring samples, scaled the way the render is.
        let sourceStep = Self.maximumStep(signal) * Self.monoPanGain
        let renderedStep = Self.maximumStep(rendered)

        // Nothing that would be heard as a click. 0.15 is the threshold the defect was found with:
        // the broken renders had 80 of these in one file, peaking at 0.418.
        let clicks = Self.steps(in: rendered, above: 0.15)
        #expect(clicks.isEmpty,
                "\(clicks.count) clicks, first at frame \(clicks.first ?? -1) of \(rendered.count)")

        // And, more strictly, nothing much steeper than the source ever was. The allowance covers
        // a slice's own fade-in running at the same time as the previous slice's ramp out; both
        // are gentler than the waveform they carry, so a small multiple is generous.
        #expect(renderedStep <= sourceStep * 4,
                "rendered step \(renderedStep) against source step \(sourceStep)")
        #expect(ChopSignal.peak(rendered) > 0.1, "nothing was rendered")
    }

    @Test("every slice boundary is a boundary, not a step")
    func boundariesAreSmooth() throws {
        // The same chop played in its own order: this must come back as the source, because every
        // seam is a seam in the original waveform. Any step here is manufactured by the playback.
        let signal = Self.sustained(seconds: 2, sampleRate: Self.sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)
        let map = ChopMap.pads(chop, name: "In order")
        let kit = try map.render(source: [signal])
        let rendered = try ChopRender.render(kit, hits: map.nativeHits(), seconds: chop.duration,
                                             sampleRate: Self.sr)

        #expect(Self.steps(in: rendered, above: 0.15).isEmpty)
        // Within the fade-in and the 2 ms ramp out, it *is* the source.
        let n = min(rendered.count, signal.count)
        let expected = signal.map { $0 * Self.monoPanGain }
        let r = ChopSignal.correlation(rendered[0..<n], expected[0..<n])
        #expect(r > 0.999, "chopped in order no longer reproduces the source (r = \(r))")
    }

    // MARK: Transients survive

    @Test("the fade-in is short enough to leave a drum's attack alone")
    func transientsSurvive() throws {
        // A kick on its own pad, cut at the frame the transient starts — the worst case for a
        // fade-in, because there is nothing before it to hide in.
        let sr = Self.sr
        let kick = ChopFixtures.kick(sr)
        let signal = ChopFixtures.place([(0.05, kick)], length: 0.5, sampleRate: sr)
        let chop = Chopper().sliceByDivisions(signal, sampleRate: sr, divisions: 2)
        var map = ChopMap.pads(chop, name: "Kick")
        map.declick = .default
        let kit = try map.render(source: [signal])
        let note = try #require(map.note(forSlice: 0))
        let rendered = try ChopRender.render(kit, hits: [.init(note: note, velocity: 127, at: 0)],
                                             seconds: 0.25, sampleRate: sr)

        // Time from the first audible sample to the pad's peak. A kick's own attack is tens of
        // milliseconds; a fade that pushed this out by even a millisecond would be audible as a
        // softened hit, so it is pinned well inside that.
        let expected = Array(signal[chop.slices[0].range]).map { $0 * Self.monoPanGain }
        let reference = Self.riseFrames(expected)
        let measured = Self.riseFrames(rendered)
        #expect(measured >= reference, "the pad cannot peak earlier than the material does")
        #expect(measured - reference <= Int((0.001 * sr).rounded()),
                "attack pushed out by \(measured - reference) frames")
    }

    /// Frames from the first sample above -60 dBFS to the first sample within 1% of the peak.
    static func riseFrames(_ x: [Float]) -> Int {
        let peak = ChopSignal.peak(x)
        guard peak > 0, let first = x.firstIndex(where: { abs($0) > 1e-3 }),
              let top = x.firstIndex(where: { abs($0) >= peak * 0.99 }) else { return 0 }
        return max(0, top - first)
    }

    // MARK: Determinism

    @Test("two renders of the same chop are sample-identical")
    func rendersAreIdentical() throws {
        let (_, _, kit, hits, end) = try Self.performance()
        let a = try ChopRender.render(kit, hits: hits, seconds: end + 0.05, sampleRate: Self.sr)
        let b = try ChopRender.render(kit, hits: hits, seconds: end + 0.05, sampleRate: Self.sr)
        #expect(a.count == b.count)
        #expect(a == b, "two offline renders of one chop differ")
    }

    @Test("the chop is cut the same way every time")
    func choppingIsDeterministic() throws {
        let signal = Self.sustained(seconds: 2, sampleRate: Self.sr)
        let a = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)
        let b = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)
        #expect(a.slices == b.slices)

        let one = try ChopMap.pads(a, name: "Kit").render(source: [signal])
        let two = try ChopMap.pads(b, name: "Kit").render(source: [signal])
        #expect(one.manifest.zones == two.manifest.zones)
    }

    // MARK: The two mechanisms, separately

    @Test("zero-crossing placement moves a cut backwards only, and not far")
    func zeroCrossingPlacementIsBoundedAndBackwards() throws {
        let signal = Self.sustained(seconds: 2, sampleRate: Self.sr)
        var plain = Chopper()
        plain.zeroCrossingWindow = 0
        let marked = plain.sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)
        let refined = Chopper().sliceByDivisions(signal, sampleRate: Self.sr, divisions: 16)

        #expect(refined.count == marked.count)
        let window = Int((0.0015 * Self.sr).rounded())
        for (a, b) in zip(marked.slices, refined.slices) {
            #expect(b.start <= a.start, "slice \(a.index) moved forwards, into the transient")
            #expect(a.start - b.start <= window, "slice \(a.index) moved \(a.start - b.start) frames")
        }
        // Still a tiling: no gaps, no overlaps, first frame to last.
        #expect(refined.slices.first?.start == 0)
        #expect(refined.slices.last?.end == signal.count)
        for (a, b) in zip(refined.slices, refined.slices.dropFirst()) { #expect(a.end == b.start) }

        // And it did its job. Per slice it can only improve things — a cut is moved only onto a
        // frame at least four times quieter — and across the chop it does, for most of them.
        var moved = 0
        for (a, b) in zip(marked.slices, refined.slices) {
            #expect(abs(signal[b.start]) <= abs(signal[a.start]),
                    "slice \(a.index) was moved onto a louder frame")
            if b.start != a.start { moved += 1 }
        }
        #expect(moved > marked.count / 2, "only \(moved) of \(marked.count) cuts found a quiet frame")

        // Not all of them, though, which is the point of keeping the fade as well: on dense
        // material there is simply no quiet frame within the window, and those pads are the ones
        // `ChopMap.Declick` has to carry.
        #expect(moved < marked.count)
    }

    @Test("the fade-in alone carries material with no quiet frame to find")
    func declickCarriesDenseMaterial() throws {
        // Placement disabled, so every cut lands exactly where the division put it: whatever is
        // left has to be handled by the pad's envelope.
        var blunt = Chopper()
        blunt.zeroCrossingWindow = 0
        let (_, _, kit, hits, end) = try Self.performance(chopper: blunt)

        // Pads that start loud got a fade; the ceiling is a millisecond however loud they start.
        let attacks = kit.manifest.zones.map { $0.envelope.attack }
        #expect(attacks.contains { $0 > 0 }, "no pad was given a fade")
        #expect(attacks.allSatisfy { $0 <= Float(0.001) + 1e-7 })

        let rendered = try ChopRender.render(kit, hits: hits, seconds: end + 0.05, sampleRate: Self.sr)
        #expect(Self.steps(in: rendered, above: 0.15).isEmpty)
    }

    @Test("a pad that starts at a crossing is not faded at all")
    func quietStartsAreLeftAlone() throws {
        let declick = ChopMap.Declick.default
        #expect(declick.attack(forFirstSample: 0, sampleRate: Self.sr) == 0)
        #expect(declick.attack(forFirstSample: 0.001, sampleRate: Self.sr) == 0)
        // Sized from the climb, and capped.
        let quiet = declick.attack(forFirstSample: 0.1, sampleRate: Self.sr)
        let loud = declick.attack(forFirstSample: 0.9, sampleRate: Self.sr)
        #expect(quiet > 0 && quiet < loud)
        #expect(loud <= Float(0.001) + 1e-7)
        #expect(ChopMap.Declick.none.attack(forFirstSample: 1, sampleRate: Self.sr) == 0)
    }
}
