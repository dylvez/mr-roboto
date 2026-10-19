import Foundation
import Testing

@testable import Performance

// The Master's section by section reading, against sections whose level and spectrum are known:
// tones at stated levels, so every number has an answer worked out on paper.

@Suite("Section meter")
struct SectionMeterTests {
    private let rate = 48_000.0

    private func sine(_ hz: Double, peakDB: Double, seconds: Double) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Back-to-back stretches, as one buffer, with a span for each.
    private func song(_ parts: [(name: String, samples: [Float])]) -> (planar: [[Float]], spans: [SectionMeter.Span]) {
        var lane: [Float] = []
        var spans: [SectionMeter.Span] = []
        for part in parts {
            spans.append(SectionMeter.Span(name: part.name, frames: lane.count..<(lane.count + part.samples.count)))
            lane += part.samples
        }
        return ([lane, lane], spans)
    }

    @Test("each section's loudness is its own, gated as the standard gates it, and the whole is MixMeter's to the digit")
    func loudness() {
        let (planar, spans) = song([("Verse", sine(1_000, peakDB: -30, seconds: 6)),
                                    ("Chorus", sine(1_000, peakDB: -20, seconds: 6)),
                                    ("Bridge", sine(1_000, peakDB: -23, seconds: 6))])
        let sheet = SectionMeter.read(planar, sampleRate: rate, spans: spans)
        #expect(sheet.sections.map(\.name) == ["Verse", "Chorus", "Bridge"])
        // A stereo 1 kHz sine reads its peak level in LUFS (MixMeterTests): −30, −20, −23.
        let lufs = sheet.sections.map { $0.integratedLUFS ?? .nan }
        #expect(abs(lufs[0] + 30) < 0.3 && abs(lufs[1] + 20) < 0.3 && abs(lufs[2] + 23) < 0.3, "\(lufs)")
        #expect(abs((lufs[1] - lufs[0]) - 10) < 0.05, "ten decibels apart, as written")
        // The whole is read exactly as the Master's integrated loudness is.
        #expect(sheet.whole.integratedLUFS == MixMeter.integratedLoudness(planar, sampleRate: rate))
        // And a section read in the song is the section read alone, to a hair: its filters carry on
        // from the bars before it rather than starting cold, which is the only difference.
        let chorusAlone = MixMeter.integratedLoudness(planar.map { Array($0[spans[1].frames]) }, sampleRate: rate)
        #expect(abs((sheet.sections[1].integratedLUFS ?? 0) - chorusAlone) < 0.05, "\(sheet.sections[1].integratedLUFS ?? 0) v \(chorusAlone)")
        #expect(sheet.sections[1].startSeconds == 6 && sheet.sections[1].seconds == 6)
    }

    @Test("each band is a share of the whole song's energy, one scale for every row; the whole row is the balance")
    func bands() {
        // A bass section and an air section, equal in length and level: each has all of its energy in
        // its own band, so against the whole song (half of whose energy each holds) its band reads
        // 0 dB, and the whole song's balance is half and half — −3 dB in each of the two bands.
        let (planar, spans) = song([("Low", sine(80, peakDB: -20, seconds: 6)), ("Air", sine(8_000, peakDB: -20, seconds: 6))])
        let sheet = SectionMeter.read(planar, sampleRate: rate, spans: spans)
        let low = sheet.sections[0].bandsDB, air = sheet.sections[1].bandsDB, whole = sheet.whole.bandsDB
        #expect(SectionMeter.bands.map(\.name) == ["20–120", "120–500", "500–2k", "2k–6k", "6k–16k"])
        #expect(abs(low[0]) < 0.3 && abs(air[4]) < 0.3, "\(low) \(air)")
        #expect(low[0] - low[2] > 40 && air[4] - air[2] > 40, "the rest of the spectrum is empty: \(low) \(air)")
        #expect(abs(whole[0] + 3.01) < 0.3 && abs(whole[4] + 3.01) < 0.3, "\(whole)")
        #expect(abs(sheet.whole.energyDB) < 0.01, "the whole is the whole")
        #expect(abs(sheet.sections[0].energyDB) < 0.3, "each holds the song's level")
        // A section's own balance takes its level away: a quiet copy of the bass reads the same.
        let (quieter, quietSpans) = song([("Low", sine(80, peakDB: -32, seconds: 6)), ("Air", sine(8_000, peakDB: -20, seconds: 6))])
        let quiet = SectionMeter.read(quieter, sampleRate: rate, spans: quietSpans)
        // On the song's scale it is down by more than its 12 dB less what the song lost with it:
        // (1/15.85) / ((1/15.85 + 1) / 2) is −9.25 dB.
        #expect(abs(quiet.sections[0].bandsDB[0] - low[0] + 9.25) < 0.3, "\(quiet.sections[0].bandsDB[0])")
        #expect(abs(quiet.sections[0].balanceDB[0] - sheet.sections[0].balanceDB[0]) < 0.3, "its own balance is the same")
        // The whole row's spectrum is the one the Master draws and the tilt is read from.
        #expect(sheet.spectrum == MixMeter.powerSpectrum(planar, sampleRate: rate))
    }

    @Test("crest is peak over RMS, and spread is how far the 3-second loudness moves")
    func crestAndSpread() {
        // A steady tone: a sine's crest, 3 dB, and no spread to speak of.
        let steady = sine(1_000, peakDB: -20, seconds: 12)
        // The same length, its second half 10 dB up: its 3-second loudness walks from −30 to −20.
        let step = sine(1_000, peakDB: -30, seconds: 6) + sine(1_000, peakDB: -20, seconds: 6)
        let (planar, spans) = song([("Steady", steady), ("Step", step)])
        let sheet = SectionMeter.read(planar, sampleRate: rate, spans: spans)
        #expect(abs((sheet.sections[0].crestDB ?? 0) - 3.01) < 0.1, "\(sheet.sections[0].crestDB ?? 0)")
        #expect((sheet.sections[0].spreadLU ?? 99) < 0.2, "\(sheet.sections[0].spreadLU ?? -1)")
        let spread = sheet.sections[1].spreadLU ?? 0
        #expect(spread > 8 && spread < 10.5, "\(spread)")
        // The spread's percentiles and gates on their own: a value 30 LU under the rest is gated.
        #expect(MixMeter.loudnessSpread([-20, -20, -20, -20]) == 0)
        #expect(MixMeter.loudnessSpread([-20, -20, -20, -60, -80]) == 0, "under −70 and 20 LU under the mean are not counted")
        #expect(MixMeter.loudnessSpread([-20]) == nil, "one window has no spread")
    }

    @Test("silence, a span off the end and a span too short to read each say so rather than inventing a number")
    func edges() {
        let tone = sine(1_000, peakDB: -20, seconds: 4)
        let silence = [Float](repeating: 0, count: Int(4 * rate))
        let planar = [tone + silence, tone + silence]
        let spans = [SectionMeter.Span(name: "Tone", frames: 0..<tone.count),
                     SectionMeter.Span(name: "Rest", frames: tone.count..<(2 * tone.count)),
                     SectionMeter.Span(name: "Past the end", frames: (3 * tone.count)..<(4 * tone.count)),
                     SectionMeter.Span(name: "A blink", frames: 1_000..<1_480)]
        let sheet = SectionMeter.read(planar, sampleRate: rate, spans: spans)
        #expect(sheet.sections.count == 4, "a row for every span asked for")
        // The rest after the tone: its filters ring on for a moment from the tone, as they would in
        // the song, sixty decibels down; nothing of the tone reaches its bands.
        #expect((sheet.sections[1].integratedLUFS ?? -100) < -60, "\(sheet.sections[1].integratedLUFS ?? 0)")
        #expect(sheet.sections[1].crestDB == nil && sheet.sections[1].spreadLU == nil)
        #expect(sheet.sections[1].bandsDB.allSatisfy { $0 == SectionMeter.floorDB }, "\(sheet.sections[1].bandsDB)")
        #expect(sheet.sections[2].integratedLUFS == nil && sheet.sections[2].seconds == 0)
        // Ten milliseconds of tone: shorter than a gating block, so the mean square over it, and no
        // 3-second window for a spread.
        #expect(sheet.sections[3].integratedLUFS != nil && sheet.sections[3].spreadLU == nil)
        // Silence through and through.
        let nothing = SectionMeter.read([silence], sampleRate: rate, spans: [])
        #expect(nothing.whole.integratedLUFS == nil && nothing.sections.isEmpty)
        #expect(nothing.whole.bandsDB.allSatisfy { $0 == SectionMeter.floorDB })
    }
}
