import Foundation
import Testing

@testable import Instrument

// The band-limited waveforms now take each harmonic's sine from a recurrence instead of calling
// sin() per harmonic. This holds them to the direct sum they replaced.

@Suite("Band-limited waveforms by recurrence")
struct WaveformRecurrenceTests {

    /// The waveform as it was summed: one sin() per harmonic.
    private func reference(_ shape: InstrumentVoiceSpec.Waveform, phase: Double, frequency: Double,
                           sampleRate: Double, pulseWidth: Double) -> Double {
        let angle = 2 * Double.pi * phase
        let limit = max(1, Int((sampleRate / 2) / max(1, frequency)))
        var sum = 0.0
        switch shape {
        case .sine:
            return sin(angle)
        case .saw:
            for h in 1...min(limit, 64) { sum += sin(angle * Double(h)) / Double(h) }
            return sum * (2 / Double.pi)
        case .square:
            for h in stride(from: 1, through: min(limit, 63), by: 2) { sum += sin(angle * Double(h)) / Double(h) }
            return sum * (4 / Double.pi)
        case .triangle:
            var sign = 1.0
            for h in stride(from: 1, through: min(limit, 63), by: 2) {
                sum += sign * sin(angle * Double(h)) / Double(h * h)
                sign = -sign
            }
            return sum * (8 / (Double.pi * Double.pi))
        case .pulse:
            let width = max(0.05, min(0.95, pulseWidth))
            for h in 1...min(limit, 64) {
                let x = Double(h)
                sum += (sin(angle * x) - sin((angle + 2 * .pi * width) * x)) / x
            }
            return sum * (1 / Double.pi)
        }
    }

    @Test("every shape matches the direct sum, across the keyboard and the cycle")
    func matches() {
        var worst = 0.0
        for shape in [InstrumentVoiceSpec.Waveform.sine, .saw, .square, .triangle, .pulse] {
            for frequency in [32.7, 110, 440, 1_760, 7_040, 18_000] {
                for step in 0..<97 {
                    let phase = Double(step) / 97
                    let fast = InstrumentSynthesizer.waveform(shape, phase: phase, frequency: frequency,
                                                              sampleRate: 48_000, pulseWidth: 0.3)
                    let slow = reference(shape, phase: phase, frequency: frequency, sampleRate: 48_000, pulseWidth: 0.3)
                    worst = max(worst, abs(fast - slow))
                }
            }
        }
        #expect(worst < 1e-9, "largest difference \(worst)")
    }
}
