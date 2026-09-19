import Foundation
import Testing

@testable import Analysis

// M5 R6: the pitch tracker reads a tone to the cent, vibrato as one note, a glide as two, silence as none.

@Suite("Pitch tracker")
struct PitchTrackerTests {
    private let rate = 48_000.0

    private func voice(_ hz: (Double) -> Double, seconds: Double, amplitude: Double = 0.3) -> [Float] {
        var phase = 0.0
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            phase += 2 * .pi * hz(t) / rate
            // A few harmonics, so it is a voice-like periodic signal rather than a pure sine.
            return Float(amplitude * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)))
        }
    }

    @Test("a 220 Hz tone reads within 2 cents, as one note at A3")
    func tone() {
        let tracker = PitchTracker()
        let frames = tracker.track(voice({ _ in 220 }, seconds: 1), sampleRate: rate)
        let voiced = frames.compactMap(\.frequency)
        #expect(voiced.count > 80, "\(voiced.count) voiced frames")
        let cents = voiced.map { 1200 * log2($0 / 220) }
        #expect(cents.allSatisfy { abs($0) < 2 }, "worst \(cents.map(abs).max() ?? 0) cents")
        let notes = tracker.notes(in: frames)
        #expect(notes.count == 1 && notes.first?.nearest == 57 && abs(notes.first?.cents ?? 99) < 2, "\(notes)")
    }

    @Test("vibrato of ±30 cents at 6 Hz is one note at its centre; a note 31 cents sharp reads as such")
    func vibratoAndSharp() {
        let tracker = PitchTracker()
        let vibrato = tracker.notes(in: tracker.track(voice({ t in 261.63 * pow(2, 0.3 * sin(2 * .pi * 6 * t) / 12) }, seconds: 1), sampleRate: rate))
        #expect(vibrato.count == 1 && vibrato.first?.nearest == 60 && abs(vibrato.first?.cents ?? 99) < 8, "\(vibrato)")
        let sharp = tracker.notes(in: tracker.track(voice({ _ in 261.63 * pow(2, 0.31 / 12) }, seconds: 0.8), sampleRate: rate))
        #expect(sharp.count == 1 && sharp.first?.nearest == 60 && abs((sharp.first?.cents ?? 0) - 31) < 3, "\(sharp)")
    }

    @Test("a step from A3 to C4 halfway reads as two notes with the right timing, and silence is unvoiced")
    func twoNotesAndSilence() {
        let tracker = PitchTracker()
        var signal = voice({ t in t < 0.5 ? 220 : 261.63 }, seconds: 1)
        signal += [Float](repeating: 0, count: Int(0.5 * rate))
        let frames = tracker.track(signal, sampleRate: rate)
        let notes = tracker.notes(in: frames)
        #expect(notes.count == 2, "\(notes)")
        #expect(notes.first?.nearest == 57 && notes.last?.nearest == 60)
        #expect(abs((notes.last?.start ?? 0) - 0.5) < 0.03)
        #expect(frames.filter { $0.time > 1.05 }.allSatisfy { $0.frequency == nil })
    }
}
