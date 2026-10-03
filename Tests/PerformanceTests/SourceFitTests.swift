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
