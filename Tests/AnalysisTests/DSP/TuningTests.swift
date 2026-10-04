import Foundation
import Testing

@testable import Analysis

// A record between the keys: how far it sits from concert pitch, read from its partials.

enum TuningFixture {
    /// Four bars of four chords in C, each note a fundamental and three partials, the whole of it
    /// `cents` off concert pitch: a piano that was tuned to itself and a turntable that ran slow.
    static func chords(cents: Double, sampleRate: Double = 44_100, seconds: Double = 8) -> [Float] {
        let chords: [[Int]] = [[48, 60, 64, 67], [53, 60, 65, 69], [55, 62, 67, 71], [48, 60, 64, 72]]
        let frames = Int(seconds * sampleRate), each = frames / chords.count
        var out = [Float](repeating: 0, count: frames)
        for (index, chord) in chords.enumerated() {
            for note in chord {
                let hz = 440 * pow(2, (Double(note) - 69 + cents / 100) / 12)
                for partial in 1...4 {
                    let step = 2 * Double.pi * hz * Double(partial) / sampleRate
                    let level = Float(0.12 / Double(partial))
                    for frame in 0..<each { out[index * each + frame] += level * Float(sin(step * Double(frame))) }
                }
            }
        }
        return out
    }
}

@Suite("Tuning: how far a record sits from concert pitch")
struct TuningTests {

    @Test("chords at pitch read 0; thirty cents flat, twelve sharp and forty-five flat read as they are, within two cents",
          arguments: [0.0, -30, 12, -45, 28])
    func reads(cents: Double) throws {
        let reading = try #require(Tuning.read(TuningFixture.chords(cents: cents), sampleRate: 44_100))
        #expect(abs(reading.cents - cents) < 2, "\(reading.cents) for \(cents)")
        #expect(reading.confidence > 0.6)
    }

    @Test("the same at 48 kHz")
    func otherRate() throws {
        let reading = try #require(Tuning.read(TuningFixture.chords(cents: -22, sampleRate: 48_000), sampleRate: 48_000))
        #expect(abs(reading.cents + 22) < 2, "\(reading.cents)")
    }

    @Test("noise, one bare tone, and a signal too short have no reading")
    func none() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let noise = (0..<(44_100 * 6)).map { _ -> Float in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 20_000) / 10_000 - 1
        }
        #expect(Tuning.read(noise, sampleRate: 44_100) == nil)
        let tone = (0..<(44_100 * 6)).map { Float(sin(2 * Double.pi * 200 * Double($0) / 44_100)) * 0.5 }
        #expect(Tuning.read(tone, sampleRate: 44_100) == nil, "one partial is not a scale")
        #expect(Tuning.read([Float](repeating: 0.1, count: 4_000), sampleRate: 44_100) == nil)
    }
}
