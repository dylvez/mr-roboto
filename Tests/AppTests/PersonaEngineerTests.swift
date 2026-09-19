import Foundation
import Performance
import Testing

@testable import MrRobotoApp

// M4 Gate B: the Engineer reads a bounce in the delivery spec's numbers.

@Suite("Persona: Engineer")
struct PersonaEngineerTests {
    private let engineer = Engineer()
    private let rate = 48_000.0

    private func sine(_ hz: Double, peakDB: Double, seconds: Double = 2) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test("it reads loudness, peak, crest, bandwidth and who owns the low end, in numbers")
    func readsABounce() {
        // A kick-like 80 Hz tone at −6 and a bass-like 100 Hz tone at −8: within 6 dB, they fight.
        let drums = sine(80, peakDB: -6)
        let bass = sine(100, peakDB: -8)
        let mix = zip(drums, bass).map { $0 + $1 }
        let observation = MixObservation.measure(label: "Verse", mix: [mix], sampleRate: rate, drums: [drums], bass: [bass])
        #expect(observation.integratedLUFS.isFinite)
        #expect(abs(observation.peakDBFS - MixMeter.samplePeakDB([mix])) < 1e-9)
        #expect(observation.lowEndOwner == "kick")
        #expect(observation.lowEndSeparationDB.map { $0 > 1 && $0 < 4 } == true, "\(observation.lowEndSeparationDB ?? -1)")
        #expect(observation.bandwidthHz < 8_000, "two low tones have no top end")
        let readings = engineer.read(observation)
        let low = readings.first { $0.rule == "engineer.who-owns-eighty" }
        #expect(low?.holds == false && low?.says.contains("The kick owns it") == true, "\(low?.says ?? "")")
        #expect(readings.first { $0.rule == "engineer.a-corner-is-a-choice" }?.holds == false)
        #expect(readings.first { $0.rule == "engineer.peak-ceiling" }?.holds == true)
        #expect(readings.first { $0.rule == "engineer.drums-keep-their-crest" }?.says.contains("squashed") == true, "a sine's crest is 3 dB")

        // Loud and separated: a −9 LUFS mix is hot; a bass 10 dB under the kick is owned.
        let hot = MixObservation.measure(label: "Hook", mix: [sine(1_000, peakDB: -3), sine(1_000, peakDB: -3)], sampleRate: rate,
                                         drums: [sine(80, peakDB: -6)], bass: [sine(100, peakDB: -18)])
        let hotReadings = engineer.read(hot)
        #expect(hotReadings.first { $0.rule == "engineer.delivery-loudness" }?.holds == false)
        #expect(hotReadings.first { $0.rule == "engineer.delivery-loudness" }?.says.contains("hot") == true)
        #expect(hotReadings.first { $0.rule == "engineer.who-owns-eighty" }?.holds == true)
        let silent = MixObservation.measure(label: "Nothing", mix: [[Float](repeating: 0, count: 4800)], sampleRate: rate)
        #expect(engineer.read(silent).first { $0.rule == "engineer.delivery-loudness" }?.says.contains("silent") == true)
    }

    @Test("it refuses a hot master, a squashed drum bus and a fighting low end, and defers the rest")
    func verdicts() {
        #expect(engineer.consider(.setLoudness(integratedLUFS: -9, peakDBFS: -0.1)).refusedByRule == "engineer.delivery-loudness")
        #expect(engineer.consider(.setLoudness(integratedLUFS: -14.5, peakDBFS: -2)).isAgreement)
        #expect(engineer.consider(.setLoudness(integratedLUFS: -14, peakDBFS: 0)).refusedByRule == "engineer.peak-ceiling")
        #expect(engineer.consider(.squashDrums(crestDB: 5)).refusedByRule == "engineer.drums-keep-their-crest")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 2)).refusedByRule == "engineer.who-owns-eighty")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 20)).refusedByRule == "engineer.bass-has-a-body")
        #expect(engineer.consider(.balanceLowEnd(separationDB: 9)).isAgreement)
        if case .defer_(let to, _) = engineer.consider(.moveCutLate(milliseconds: 9)) { #expect(to == .sampler) } else { Issue.record("a cut is the Sampler's") }
        // M6: the hands.
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -3, bandHz: 0, bandDB: 0)).isAgreement)
        #expect(engineer.consider(.moveStrip(part: "kick", gainDB: 0, bandHz: 3_000, bandDB: 4)).refusedByRule == "engineer.cut-before-boost")
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -3, bandHz: 80, bandDB: -6)).refusedByRule == "engineer.one-move-at-a-time")
        #expect(engineer.consider(.moveStrip(part: "bass", gainDB: -9, bandHz: 0, bandDB: 0)).refusedByRule == "engineer.small-moves")
        #expect(engineer.consider(.setMaster(targetLUFS: -14, ceilingDBTP: -1)).isAgreement)
        #expect(engineer.consider(.setMaster(targetLUFS: -14, ceilingDBTP: 0)).refusedByRule == "engineer.master-ceiling")
        #expect(engineer.consider(.setMaster(targetLUFS: -4, ceilingDBTP: -1)).refusedByRule == "engineer.master-target")
        if case .defer_(let to, _) = Beatmaker().consider(.moveStrip(part: "kick", gainDB: -3, bandHz: 0, bandDB: 0)) { #expect(to == .engineer) } else { Issue.record("a strip move is the Engineer's") }
        #expect(BibleMethod.lint(Engineer.bible).isEmpty, "\(BibleMethod.lint(Engineer.bible))")
    }
}
