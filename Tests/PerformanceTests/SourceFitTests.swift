import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import Performance

// A source is a record moved onto the open song: the song's key, tempo and bars stand. These are the
// sums: where a whole stem's bar 1 lands, what is left out before the song starts, a clip fitted to
// whole bars exactly, the drums never shifted, and one level for a record.

@Suite("Sources: a record moved onto the song")
struct SourceFitTests {
    /// 98 bpm in E major, its first downbeat at 1.2 s, a bar every 60/98 × 4 s.
    private static let bar = 4 * 60 / 98.0
    private let vocal = SourceMaterial(label: "Vocals of Exit Interview", key: Key(tonic: NoteName(.e)), tempo: 98,
                                       bars: (0..<40).map { SongGraph.TimeRange(start: 1.2 + Double($0) * bar, end: 1.2 + Double($0 + 1) * bar) },
                                       duration: 100)
    private let song = MergeTarget(key: Key(tonic: NoteName(.d)), tempo: 92)

    @Test("a whole stem: moved to the song's key and tempo, its bar 1 on the bar asked for, the pickup left out at bar 1")
    func whole() {
        let onFive = SourceFitting.plan(vocal, into: song, shape: .whole(atBar: 4))
        #expect(onFive.move.semitones == -2 && abs(onFive.move.ratio - 98.0 / 92) < 1e-9)
        let songBar = 4 * 60 / 92.0
        // The record's first downbeat sounds on song bar 5: offset plus (downbeat − region start) × ratio.
        let landing = onFive.offset + (vocal.firstDownbeat - onFive.region.start) * onFive.move.ratio
        #expect(abs(landing - 4 * songBar) < 1e-9, "\(landing)")
        #expect(onFive.region.start == 0 && onFive.cut == 0, "the pickup fits before bar 5")
        #expect(onFive.sentences.contains { $0.contains("bar 5 of the song") })

        let onOne = SourceFitting.plan(vocal, into: song, shape: .whole(atBar: 0))
        #expect(abs(onOne.offset) < 1e-9 && abs(onOne.region.start - 1.2) < 1e-9, "what would sound before the song starts is not read")
        #expect(onOne.sentences.contains { $0.contains("are left out") })
        #expect(onOne.bars == Int(ceil((100 - 1.2) * onOne.move.ratio / songBar - 1e-9)))

        // Already under way: two bars of the record have gone by when the song starts.
        let under = SourceFitting.plan(vocal, into: song, shape: .whole(atBar: -2))
        #expect(abs(under.region.start - (1.2 + 2 * Self.bar)) < 1e-6 && abs(under.offset) < 1e-6)
    }

    @Test("a clip is fitted to whole bars of the song exactly, whatever the record's bars came to")
    func clip() {
        let plan = SourceFitting.plan(vocal, into: song, shape: .clip(from: 8, to: 10))
        #expect(plan.isClip && plan.bars == 2)
        #expect(abs(plan.region.start - vocal.bars[8].start) < 1e-9 && abs(plan.region.end - vocal.bars[9].end) < 1e-9)
        let songBar = 4 * 60 / 92.0
        #expect(abs(plan.region.duration * plan.move.ratio - 2 * songBar) < 1e-9, "two of the song's bars, to the sample")
        #expect(plan.flags.isEmpty)
        #expect(plan.sentences.first == "Bars 9–10 of Vocals of Exit Interview, fitted to 2 bars of the song.")

        // Bars the record drags through: still two bars, and said.
        var dragging = vocal
        dragging.bars[8].end += 0.1
        dragging.bars[9].start += 0.1
        dragging.bars[9].end += 0.2
        let dragged = SourceFitting.plan(dragging, into: song, shape: .clip(from: 8, to: 10))
        #expect(dragged.bars == 2 && abs(dragged.region.duration * dragged.move.ratio - 2 * songBar) < 1e-9)
        #expect(dragged.flags.contains { $0.contains("longer than its tempo says") })
    }

    @Test("T1 first: a record at twice the song's tempo gives a bar of the song for every two of its own")
    func doubled() {
        let fast = SourceMaterial(label: "Breaks", tempo: 184, bars: (0..<8).map { SongGraph.TimeRange(start: Double($0) * 240 / 184, end: Double($0 + 1) * 240 / 184) },
                                  duration: 12)
        let plan = SourceFitting.plan(fast, into: MergeTarget(tempo: 92), shape: .clip(from: 0, to: 4))
        #expect(plan.bars == 2 && plan.move.tempoFactor == 0.5, "\(plan.bars) \(plan.move.tempoFactor)")
        #expect(abs(plan.move.ratio - 1) < 1e-9)
    }

    @Test("drums are stretched and never shifted; a nudge by ear moves the rest")
    func drums() {
        var kit = vocal
        kit.label = "Drums of Exit Interview"
        kit.isDrums = true
        let plan = SourceFitting.plan(kit, into: song, shape: .whole(atBar: 0), semitones: 3)
        #expect(plan.move.semitones == 0 && plan.move.keepsTransients && !plan.move.preservesFormants)
        #expect(abs(plan.move.ratio - 98.0 / 92) < 1e-9)
        let nudged = SourceFitting.plan(vocal, into: song, shape: .whole(atBar: 0), semitones: 5)
        #expect(nudged.move.semitones == 5 && nudged.flags.contains { $0.contains("timbre") })
    }

    @Test("one level for a record: toward the records already in the song, within twelve dB")
    func level() {
        #expect(SourceFitting.level(record: -9, toward: -14) == -5)
        #expect(SourceFitting.level(record: -30, toward: -14) == 12)
        #expect(SourceFitting.level(record: nil, toward: -14) == nil)
        #expect(SourceFitting.level(record: -12.94, toward: nil) == nil)
    }
}

// A record between the keys is brought to concert pitch as it is fitted: the cents it sits off are
// taken off on top of the semitones, and said.

@Suite("Sources: a record brought to concert pitch")
struct ConcertPitchTests {
    private static let bar = 4 * 60 / 98.0
    private func vocal(tuning: Double?, drums: Bool = false) -> SourceMaterial {
        SourceMaterial(label: "Vocals of Deep River", key: Key(tonic: NoteName(.e)), tempo: 98,
                       bars: (0..<40).map { SongGraph.TimeRange(start: 1.2 + Double($0) * Self.bar, end: 1.2 + Double($0 + 1) * Self.bar) },
                       duration: 100, isDrums: drums, tuning: tuning)
    }
    private let song = MergeTarget(key: Key(tonic: NoteName(.d)), tempo: 92)

    @Test("28 cents flat: up 28 cents on top of the semitones, a whole stem and a clip alike, and said")
    func flat() {
        for shape in [SourceShape.whole(atBar: 0), .clip(from: 4, to: 6)] {
            let plan = SourceFitting.plan(vocal(tuning: -28), into: song, shape: shape)
            #expect(plan.move.semitones == -2 && plan.move.cents == 28 && abs(plan.move.pitchShift + 1.72) < 1e-9)
            #expect(plan.sentences.contains("Up 28 cents to concert pitch: the record sits that far flat."))
        }
        let sharp = SourceFitting.plan(vocal(tuning: 12), into: song, shape: .whole(atBar: 0))
        #expect(sharp.move.cents == -12 && sharp.sentences.contains("Down 12 cents to concert pitch: the record sits that far sharp."))
    }

    @Test("within five cents, never measured, or drums: left where it is, and nothing said")
    func left() {
        for material in [vocal(tuning: 4), vocal(tuning: nil), vocal(tuning: -28, drums: true)] {
            let plan = SourceFitting.plan(material, into: song, shape: .whole(atBar: 0))
            #expect(plan.move.cents == 0 && !plan.sentences.contains { $0.contains("concert pitch") })
        }
    }

    @Test("a record at the song's key and tempo, 30 cents flat, is still moved: the cents are a move of their own")
    func onlyCents() throws {
        var material = vocal(tuning: -30)
        material.key = song.key
        material.tempo = 92
        let plan = SourceFitting.plan(material, into: song, shape: .whole(atBar: 0))
        #expect(plan.move.semitones == 0 && !plan.move.movesTime && plan.move.movesPitch && !plan.move.isUntouched)
        // Rendered, a tone 30 cents under A comes out on A.
        let rate = 44_100.0
        let hz = 440 * pow(2, -30.0 / 1200)
        let tone = (0..<Int(rate * 3)).map { Float(sin(2 * Double.pi * hz * Double($0) / rate)) * 0.4 }
        let moved = try MergeRender.audio([tone], sampleRate: rate, move: plan.move)
        // Its pitch from the zero crossings of the middle second.
        let middle = Array(moved[0][Int(rate)..<Int(rate * 2)])
        var crossings: [Double] = []
        for index in 1..<middle.count where middle[index - 1] < 0 && middle[index] >= 0 {
            crossings.append(Double(index - 1) + Double(-middle[index - 1]) / Double(middle[index] - middle[index - 1]))
        }
        let period = (crossings.last! - crossings.first!) / Double(crossings.count - 1)
        let cents = 1200 * log2(rate / period / 440)
        #expect(abs(cents) < 4, "\(cents) cents from A")
    }
}
