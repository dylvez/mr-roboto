import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
@testable import MrRobotoApp

// MARK: - Bars to chop
//
// Synthetic and deliberately plain, like `PerformanceTests`' own fixtures: a kick is a decaying
// sine, a snare is lowpassed noise plus a tone, a hat is highpassed noise.
//
// There are two bars because they are asked two different questions.
//
// `cleanBar` is silent between its hits, so every transient is found at every threshold and the
// classifier has an easy time: kick, hat, snare, kick, hat, kick, snare, hat. It is the bar for
// everything that is about slices, pads, maps and re-grooves.
//
// `ghostBar` has a noise floor and four very quiet hats in it, which is what makes the onset
// threshold mean anything at all. A transient in silence produces an enormous spectral flux — the
// detection function jumps from nothing — so δ in its useful range cannot touch it. A transient in
// a noise floor produces a flux that is only a little above the local mean, and δ decides. That is
// the situation on a real record, and it is the only situation in which a *sensitivity* control is
// a control rather than a decoration.

enum ChopLaneFixtures {
    struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static let sampleRate: Double = 48_000
    static let bpm: Double = 90
    /// A sixteenth at 90 BPM: 1/6 s.
    static var step: Double { 60 / bpm / 4 }
    static var barLength: Double { step * 16 }

    // MARK: Sounds

    static func fadeOut(_ x: inout [Float], seconds: Double) {
        let n = x.count
        let fade = min(n / 4, max(1, Int(seconds * sampleRate)))
        guard fade > 1 else { return }
        for i in (n - fade)..<n {
            x[i] *= Float(0.5 * (1 + cos(.pi * Double(i - (n - fade)) / Double(fade))))
        }
    }

    static func decayingSine(frequency: Double, duration: Double, decay: Double,
                             amplitude: Double) -> [Float] {
        var out = (0..<max(1, Int(duration * sampleRate))).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(sin(2 * .pi * frequency * t) * exp(-t * decay) * amplitude)
        }
        fadeOut(&out, seconds: 0.02)
        return out
    }

    static func noiseBurst(duration: Double, decay: Double, seed: UInt64,
                           amplitude: Double) -> [Float] {
        var rng = RNG(state: seed &* 2862933555777941757 &+ 3037000493)
        var out = (0..<max(1, Int(duration * sampleRate))).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(rng.next() * exp(-t * decay) * amplitude)
        }
        fadeOut(&out, seconds: 0.005)
        return out
    }

    static func lowpass(_ x: [Float], cutoff: Double, poles: Int = 2) -> [Float] {
        var y = x
        let a = exp(-2 * .pi * cutoff / sampleRate)
        for _ in 0..<poles {
            var z = 0.0
            for i in y.indices {
                z = Double(y[i]) * (1 - a) + z * a
                y[i] = Float(z)
            }
        }
        return y
    }

    static func highpass(_ x: [Float], cutoff: Double) -> [Float] {
        zip(x, lowpass(x, cutoff: cutoff, poles: 1)).map { $0 - $1 }
    }

    static func kick() -> [Float] {
        decayingSine(frequency: 60, duration: 0.3, decay: 18, amplitude: 0.9)
    }

    static func snare() -> [Float] {
        var body = lowpass(noiseBurst(duration: 0.18, decay: 26, seed: 3, amplitude: 3.0),
                           cutoff: 2200)
        let tone = decayingSine(frequency: 190, duration: 0.18, decay: 26, amplitude: 0.45)
        for i in 0..<min(body.count, tone.count) { body[i] += tone[i] }
        let peak = body.map { abs($0) }.max() ?? 1
        if peak > 0 { body = body.map { $0 / peak * 0.8 } }
        return body
    }

    static func hat(_ amplitude: Double = 0.7) -> [Float] {
        highpass(noiseBurst(duration: 0.045, decay: 100, seed: 7, amplitude: amplitude),
                 cutoff: 4000)
    }

    static func place(_ hits: [(time: Double, sound: [Float])], into out: inout [Float]) {
        for hit in hits {
            let offset = Int((hit.time * sampleRate).rounded())
            guard offset >= 0 else { continue }
            for i in 0..<hit.sound.count where offset + i < out.count {
                out[offset + i] += hit.sound[i]
            }
        }
    }

    // MARK: The bars

    /// Where the late hat sits: half a sixteenth behind step 14, so the bar has one transient the
    /// grid does not explain and a marker can be dragged onto *it* rather than onto a line.
    static let lateHatStep = 14.5

    /// Kicks on 1, the "and" of 2 and the "and" of 3; snares on 2 and 4; hats on the "and" of 1
    /// and of 3, and one dragging behind step 14. Eight transients, nothing between them.
    static func cleanBar() -> [Float] {
        var out = [Float](repeating: 0, count: Int((barLength * sampleRate).rounded()))
        var hits: [(time: Double, sound: [Float])] = []
        for s in [0, 6, 10] { hits.append((Double(s) * step, kick())) }
        for s in [4, 12] { hits.append((Double(s) * step, snare())) }
        for s in [2, 8] { hits.append((Double(s) * step, hat())) }
        hits.append((lateHatStep * step, hat()))
        place(hits, into: &out)
        return out
    }

    /// The same kicks and snares over a noise floor, with four ghosted hats on the off-sixteenths.
    /// `bed` is the floor's RMS; 0.008 is about -42 dBFS.
    static func ghostBar(bed: Double = 0.008, ghost: Double = 0.02) -> [Float] {
        var rng = RNG(state: 424_242)
        var floor = (0..<Int((barLength * sampleRate).rounded())).map { _ in Float(rng.next()) }
        let rms = (floor.reduce(0.0) { $0 + Double($1) * Double($1) }
                   / Double(floor.count)).squareRoot()
        if rms > 0 { for i in floor.indices { floor[i] = Float(Double(floor[i]) / rms * bed) } }
        var hits: [(time: Double, sound: [Float])] = []
        for s in [0, 6, 10] { hits.append((Double(s) * step, kick())) }
        for s in [4, 12] { hits.append((Double(s) * step, snare())) }
        for s in [3, 7, 11, 15] { hits.append((Double(s) * step, hat(ghost))) }
        place(hits, into: &floor)
        return floor
    }

    // MARK: Sources and lanes

    static var grid: BeatGrid {
        BeatGrid.regular(bpm: bpm, timeSignature: .fourFour, bars: 2)
    }

    static var media: MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: "a", count: 64))!, fileExtension: "wav")
    }

    static func source(_ mono: [Float], label: String) -> ChopLaneSource {
        ChopLaneSource(media: media, mono: mono, sampleRate: sampleRate, sourceOffset: 0,
                       grid: grid, tempo: bpm, label: label)
    }

    /// A lane on `cleanBar` with a stub host already adopted.
    @MainActor
    static func cleanLane() -> (ChopLaneSurface, ChopLaneHostStub) {
        let host = ChopLaneHostStub()
        return (ChopLaneSurface(source: source(cleanBar(), label: "Bar 1 of Fixture"),
                                host: host), host)
    }

    /// A lane on `ghostBar`.
    @MainActor
    static func ghostLane() -> (ChopLaneSurface, ChopLaneHostStub) {
        let host = ChopLaneHostStub()
        return (ChopLaneSurface(source: source(ghostBar(), label: "Noisy bar"), host: host), host)
    }
}

// MARK: - The stub host
//
// Everything the surface asks of its host, recorded, and nothing else. No engine, no device, no
// disk — which is the point of `ChopLaneHost`: the whole surface is exercised offline, and none of
// these tests would behave differently on a machine with no audio hardware.

@MainActor
final class ChopLaneHostStub: ChopLaneHost {
    var song: Song? = Song(title: "Fixture", artist: "Tests", tempo: ChopLaneFixtures.bpm)

    private(set) var preparedKits: [ChopKit] = []
    private(set) var auditionedHits: [[VoiceSampler.Hit]] = []
    private(set) var stopCount = 0
    private(set) var madeVersions: [PartVersion] = []
    /// Each groove the lane said it made from its chop, with that chop's part.
    private(set) var madeGrooves: [(groove: PartID, chop: PartID)] = []

    /// Set to make `prepareAudition` throw, so the surface's error path is testable.
    var prepareFailure: (any Error)?
    /// Set to make `record` refuse, so the surface's refusal path is testable.
    var refuseVersions = false

    var lastKit: ChopKit? { preparedKits.last }
    var lastHits: [VoiceSampler.Hit] { auditionedHits.last ?? [] }

    func prepareAudition(_ kit: ChopKit) throws {
        if let prepareFailure { throw prepareFailure }
        preparedKits.append(kit)
    }

    func audition(_ hits: [VoiceSampler.Hit]) { auditionedHits.append(hits) }

    func stopAudition() { stopCount += 1 }

    @discardableResult
    func record(_ version: PartVersion) -> Bool {
        guard !refuseVersions else { return false }
        madeVersions.append(version)
        try? song?.append(version)
        return true
    }

    func madeGroove(_ groove: PartVersion, fromChop chop: PartID) {
        madeGrooves.append((groove.partID, chop))
    }
}
