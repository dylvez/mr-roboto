import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import Performance

@Suite("Mashup: two records on one grid")
struct MashupTests {
    private let instrumental = MashupSource(label: "Arrival", key: Key(tonic: NoteName(.d)), tempo: 92, firstDownbeat: 0.5, duration: 120)
    private let acapella = MashupSource(label: "Exit Interview", key: Key(tonic: NoteName(.e)), tempo: 98, firstDownbeat: 1.2, duration: 100)

    @Test("the backbone stands; the other moves to its key and tempo; first downbeats sit on bar lines")
    func plan() throws {
        let plan = Mashup.plan(a: instrumental, b: acapella, backbone: .a)
        #expect(plan.target.tempo == 92 && plan.target.key == instrumental.key)
        #expect(plan.a.isUntouched)
        #expect(plan.b.semitones == -2 && abs(plan.b.ratio - 98.0 / 92.0) < 1e-9)
        // Both have a pickup before bar 0, so one bar of lead-in; then each downbeat is on a bar line.
        #expect(plan.leadBars == 1)
        let downA = Mashup.bar(of: instrumental.firstDownbeat, in: .a, plan: plan)
        let downB = Mashup.bar(of: acapella.firstDownbeat, in: .b, plan: plan)
        #expect(abs(downA - 1) < 1e-9 && abs(downB - 1) < 1e-9, "\(downA) \(downB)")
        #expect(plan.offsetA >= 0 && plan.offsetB >= 0)
        #expect(plan.lengthInBars == Int(ceil((plan.offsetA + 120) / plan.secondsPerBar)))
        #expect(plan.sentences.count == 4 && plan.sentences[2].contains("bar 1 meets bar 1"))
        // Drums: stretched with the record, never shifted, transients kept.
        let drums = plan.drumMove(.b)
        #expect(drums.semitones == 0 && drums.keepsTransients && drums.ratio == plan.b.ratio)
    }

    @Test("a bar shift brings the other in later, or first; the other side can be the backbone; an override wins")
    func shiftsAndSides() {
        let later = Mashup.plan(a: instrumental, b: acapella, backbone: .a, barShift: 8)
        #expect(abs(Mashup.bar(of: acapella.firstDownbeat, in: .b, plan: later) - Double(8 + later.leadBars)) < 1e-9)
        #expect(later.sentences[2].contains("meets bar 9 of Arrival"))
        let first = Mashup.plan(a: instrumental, b: acapella, backbone: .a, barShift: -4)
        #expect(first.leadBars == 5, "four bars early plus the pickup")
        #expect(abs(Mashup.bar(of: instrumental.firstDownbeat, in: .a, plan: first) - 5) < 1e-9)
        let flipped = Mashup.plan(a: instrumental, b: acapella, backbone: .b)
        #expect(flipped.target.tempo == 98 && flipped.b.isUntouched && flipped.a.semitones == 2)
        let byEar = Mashup.plan(a: instrumental, b: acapella, backbone: .a, semitonesB: 3)
        #expect(byEar.b.semitones == 3 && byEar.b.preservesFormants)
    }

    @Test("a double-time record is halved before it is stretched; no downbeat pickup means no lead-in")
    func doubleTime() {
        let fast = MashupSource(label: "Fluorescent", key: nil, tempo: 174, firstDownbeat: 0, duration: 60)
        let slow = MashupSource(label: "Arrival", key: Key(tonic: NoteName(.d)), tempo: 90, firstDownbeat: 0, duration: 60)
        let plan = Mashup.plan(a: slow, b: fast, backbone: .a)
        #expect(plan.b.tempoFactor == 0.5 && abs(plan.b.ratio - 87.0 / 90.0) < 1e-9)
        #expect(plan.leadBars == 0 && plan.offsetA == 0 && plan.offsetB == 0)
        #expect(plan.b.semitones == 0, "no key, no shift")
    }
}
