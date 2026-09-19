import Analysis
import AudioEngine
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import Performance

// M5 R7–R8: a synthetic take with one note 31 cents sharp and one onset 60 ms late is read as
// exactly that, at the right bar; the offers bring the note within ±5 cents and the onset onto the grid.

enum SungFixture {
    static let rate = 48_000.0
    static let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)

    /// Four notes, one a beat, starting at bar 1 (2 s): D4, F#4 (+31 cents), A4 (60 ms late), D4.
    /// In D major; each note 0.4 s with a 10 ms edge.
    static func take() -> (planar: [[Float]], alignment: Double) {
        let notes: [(midi: Double, at: Double)] = [(62, 0), (66.31, 0.5), (69, 1.06), (62, 1.5)]
        let length = Int(2.2 * rate)
        var out = [Float](repeating: 0, count: length)
        for note in notes {
            let hz = 440 * pow(2, (note.midi - 69) / 12)
            let start = Int(note.at * rate), n = Int(0.4 * rate)
            var phase = 0.0
            for i in 0..<n where start + i < length {
                phase += 2 * .pi * hz / rate
                var env = 1.0
                let ramp = Int(0.01 * rate)
                if i < ramp { env = Double(i) / Double(ramp) }
                if n - i < ramp { env = Double(n - i) / Double(ramp) }
                out[start + i] += Float(0.3 * env * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)))
            }
        }
        return ([out], clock.seconds(forBar: 1))
    }
}

@Suite("Take analysis: cents and milliseconds at the right bar")
struct TakeAnalysisTests {

    @Test("the sharp note and the late note are read as such")
    func reads() {
        let (planar, alignment) = SungFixture.take()
        let analysis = TakeAnalysis.of(planar, sampleRate: SungFixture.rate, alignmentSeconds: alignment,
                                       key: Key(tonic: NoteName(.d)), clock: SungFixture.clock)
        #expect(analysis.notes.count == 4, "\(analysis.notes.map(\.midi))")
        let sharp = analysis.notes[1]
        #expect(sharp.nearest == 66 && abs(sharp.cents - 31) < 4, "\(sharp)")
        #expect(sharp.bar == 1 && abs(sharp.beat - 1) < 0.1)
        #expect(abs(analysis.notes[0].centsFromKey) < 4 && abs(analysis.notes[3].centsFromKey) < 4)
        let late = analysis.notes[2]
        #expect(late.timingMS > 45 && late.timingMS < 75, "\(late.timingMS)")
        #expect(abs(analysis.notes[0].timingMS) < 20 && abs(analysis.notes[1].timingMS) < 20)
        #expect(analysis.worstCents?.index == 1 && analysis.worstTiming?.index == 2)
        #expect(analysis.drifting(over: 10).count == 1 && analysis.late(over: 20).count == 1)
        #expect(analysis.peakDBFS < 0 && analysis.peakDBFS > -12)
        // A note between scale degrees is read against the key: 63.5 in D major is closer to D (62)
        // or E (64) than to the D# it is nearest by semitone.
        #expect(TakeAnalysis.nearest(63.5, inScale: Key(tonic: NoteName(.d)).pitchClasses.map(\.rawValue)) != 63)
    }

    @Test("shifting the sharp note by its cents brings it within 5, and touches nothing else")
    func pitchOffer() throws {
        let (planar, alignment) = SungFixture.take()
        let before = TakeAnalysis.of(planar, sampleRate: SungFixture.rate, alignmentSeconds: alignment, key: Key(tonic: NoteName(.d)), clock: SungFixture.clock)
        let sharp = before.notes[1]
        let fixed = try TakeCorrection.shifting(planar, sampleRate: SungFixture.rate,
                                                start: sharp.start - alignment, end: sharp.end - alignment, cents: -sharp.centsFromKey)
        let after = TakeAnalysis.of(fixed, sampleRate: SungFixture.rate, alignmentSeconds: alignment, key: Key(tonic: NoteName(.d)), clock: SungFixture.clock)
        #expect(after.notes.count == 4)
        #expect(abs(after.notes[1].centsFromKey) < 5, "\(after.notes[1].centsFromKey)")
        #expect(abs(after.notes[0].centsFromKey - before.notes[0].centsFromKey) < 1)
        // Outside the note, sample for sample the same.
        let untouched = Int(0.1 * SungFixture.rate)
        #expect(fixed[0][untouched] == planar[0][untouched])
    }

    @Test("nudging the late note earlier puts it on the grid")
    func timingOffer() {
        let (planar, alignment) = SungFixture.take()
        let before = TakeAnalysis.of(planar, sampleRate: SungFixture.rate, alignmentSeconds: alignment, key: Key(tonic: NoteName(.d)), clock: SungFixture.clock)
        let late = before.notes[2]
        let fixed = TakeCorrection.nudging(planar, sampleRate: SungFixture.rate, start: late.start - alignment, end: late.end - alignment, milliseconds: -late.timingMS)
        let after = TakeAnalysis.of(fixed, sampleRate: SungFixture.rate, alignmentSeconds: alignment, key: Key(tonic: NoteName(.d)), clock: SungFixture.clock)
        #expect(after.notes.count == 4)
        #expect(abs(after.notes[2].timingMS) < 20, "\(after.notes[2].timingMS)")
        #expect(abs(after.notes[2].centsFromKey) < 4)
    }
}
