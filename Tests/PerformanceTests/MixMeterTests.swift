import Foundation
import Testing

@testable import Performance

// The Engineer's meter, against the numbers the standard states.

@Suite("Mix meter")
struct MixMeterTests {
    private let rate = 48_000.0

    private func sine(_ hz: Double, peakDB: Double, seconds: Double) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test("the K-weighting at 48 kHz is the standard's table")
    func kWeighting() {
        let (shelf, highPass) = MixMeter.kWeighting(sampleRate: 48_000)
        #expect(abs(shelf.b0 - 1.53512485958697) < 1e-6 && abs(shelf.a1 + 1.69065929318241) < 1e-6 && abs(shelf.a2 - 0.73248077421585) < 1e-6,
                "\(shelf.b0) \(shelf.a1) \(shelf.a2)")
        #expect(abs(highPass.a1 + 1.99004745483398) < 1e-6 && abs(highPass.a2 - 0.99007225036621) < 1e-6,
                "\(highPass.a1) \(highPass.a2)")
    }

    @Test("a stereo 1 kHz sine at −23 dBFS reads −23 LUFS, and silence reads nothing")
    func loudness() {
        let tone = sine(1_000, peakDB: -23, seconds: 3)
        let lufs = MixMeter.integratedLoudness([tone, tone], sampleRate: rate)
        #expect(abs(lufs + 23) < 0.3, "\(lufs)")
        let quieter = MixMeter.integratedLoudness([sine(1_000, peakDB: -33, seconds: 3), sine(1_000, peakDB: -33, seconds: 3)], sampleRate: rate)
        #expect(abs(quieter + 33) < 0.3, "\(quieter)")
        #expect(MixMeter.integratedLoudness([[Float](repeating: 0, count: 48_000)], sampleRate: rate) == -.infinity)
        // Gating: a second of tone and two of near-silence read as the tone, not the average.
        let gated = MixMeter.integratedLoudness([tone + [Float](repeating: 0, count: 2 * 48_000)], sampleRate: rate)
        #expect(abs(gated - MixMeter.integratedLoudness([tone], sampleRate: rate)) < 0.5, "\(gated)")
        // Independent of sample rate: the same tone at 44.1 kHz reads the same.
        let other = 44_100.0
        let tone44 = (0..<Int(3 * other)).map { Float(pow(10, -23.0 / 20) * sin(2 * .pi * 1_000 * Double($0) / other)) }
        #expect(abs(MixMeter.integratedLoudness([tone44, tone44], sampleRate: other) + 23) < 0.3)
    }

    @Test("peak, crest, tilt, bandwidth and a band's energy read what was put in")
    func spectrum() {
        let tone = sine(1_000, peakDB: -6, seconds: 1)
        #expect(abs(MixMeter.samplePeakDB([tone]) + 6) < 0.05)
        #expect(abs(MixMeter.crestDB([tone]) - 3.01) < 0.1, "a sine's crest is 3 dB")
        let low = sine(80, peakDB: -6, seconds: 1)
        let high = sine(5_000, peakDB: -6, seconds: 1)
        #expect(MixMeter.tiltDB([low], sampleRate: rate) < -20)
        #expect(MixMeter.tiltDB([high], sampleRate: rate) > 20)
        #expect(MixMeter.bandwidthHz([low], sampleRate: rate) < 200)
        #expect(MixMeter.bandwidthHz([high], sampleRate: rate) > 4_000 && MixMeter.bandwidthHz([high], sampleRate: rate) < 6_000)
        let inBand = MixMeter.bandEnergyDB([low], sampleRate: rate, lowHz: 60, highHz: 120)
        let outOfBand = MixMeter.bandEnergyDB([high], sampleRate: rate, lowHz: 60, highHz: 120)
        #expect(inBand - outOfBand > 40, "\(inBand) v \(outOfBand)")
    }
}
