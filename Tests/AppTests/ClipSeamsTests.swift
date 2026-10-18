import Foundation
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Where a voice rests: each bar's start and end read from a stem, the bar lines it rests across,
// what the plan says of bars that end on one or mid-line, and the sections that cut a clip of it off.

@Suite("Clip seams: where a voice rests") @MainActor
struct ClipSeamsTests {

    /// A voice over four one-second bars: a line through bars 1 and 2 that stops before bar 2
    /// ends, a breath, then a line from the second half of bar 3 running on through bar 4.
    static func voice(rate: Double = 8_000) -> [[Float]] {
        let seconds = 4.0, frames = Int(seconds * rate)
        var lane = [Float](repeating: 0, count: frames)
        func sing(_ from: Double, _ to: Double) {
            for i in Int(from * rate)..<min(frames, Int(to * rate)) { lane[i] = 0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / rate)) }
        }
        sing(0, 1.6)
        sing(2.5, 4)
        return [lane]
    }

    static let bars = (0..<4).map { SongGraph.TimeRange(start: Double($0), end: Double($0 + 1)) }

    static func stem(rests: Bool = true) -> RecordStem {
        let planar = voice(), rate = 8_000.0
        let edges = RecordStems.edges(planar, sampleRate: rate, bars: bars)
        return RecordStem(name: "vocals", media: GuidanceFixture.media("a"), sampleRate: rate, channelCount: 1, duration: 4,
                          barLevels: RecordStems.levels(planar, sampleRate: rate, bars: bars),
                          barHeads: rests ? edges.heads : nil, barTails: rests ? edges.tails : nil)
    }

    @Test("a stem rests across a bar line where the end of one bar and the start of the next are both quiet")
    func rests() {
        let stem = Self.stem()
        // Bar 2 (0-based 1) ends in the breath and bar 3 starts in it; bar 3 ends singing; bar 4 ends singing.
        #expect(RecordStems.rests(of: stem) == [1])
        #expect(RecordStems.soundsAtEnd(of: 0, in: stem) == true, "the line runs over the first bar line")
        #expect(RecordStems.soundsAtEnd(of: 1, in: stem) == false)
        #expect(RecordStems.soundsAtEnd(of: 3, in: stem) == true)
        #expect(RecordStems.rests(of: Self.stem(rests: false)) == nil, "not measured, not guessed")
    }

    @Test("the plan says whether some bars of a voice end on a rest, and where it rests when they do not")
    func planLines() throws {
        let record = Record(title: "A voice", media: GuidanceFixture.media("b"), stems: [Self.stem()])
        #expect(ClipSeams.lines(for: 0..<2, of: record, stem: "vocals") == ["Ends where the voice rests, so the loop turns clean."])
        let midLine = ClipSeams.lines(for: 0..<4, of: record, stem: "vocals")
        #expect(midLine.first?.hasPrefix("Ends mid-line: the voice is still going as bar 4 ends") == true)
        #expect(midLine.first?.contains("It rests after bar 2: end there") == true, "\(midLine)")
        #expect(ClipSeams.lines(for: 1..<2, of: record, stem: "vocals").contains("Comes in mid-line: the voice is already going as bar 2 begins."))
        #expect(ClipSeams.lines(for: 0..<4, of: record, stem: "bass").isEmpty, "a bass looping mid-phrase is what a loop is")
    }

    @Test("a section that stops a clip of a voice mid-line says so, and one whose clip ends on a rest says nothing")
    func sectionCuts() throws {
        let record = Record(title: "A voice", media: GuidanceFixture.media("b"), stems: [Self.stem()])
        func clip(_ bars: Range<Int>) -> PartVersion {
            let fit = SourceFit(label: "A voice", media: GuidanceFixture.media("a"), stem: "vocals", start: 0, end: 4,
                                fromBar: bars.lowerBound, toBar: bars.upperBound, record: record.id)
            return PartVersion(partID: PartID(), kind: .sample(Sample(media: GuidanceFixture.media("c"), fit: fit)),
                               author: .user, operation: Operation.fitted, note: "Vocals of A voice, bars \(bars.lowerBound + 1)–\(bars.upperBound)")
        }
        let whole = clip(0..<4), clean = clip(0..<2)
        var song = Song(title: "Cuts", tempo: 120)
        try song.append(whole)
        try song.append(clean)
        let short = Section(name: "Drop", stitch: [Lane(part: whole.partID)], lengthInBars: 3)
        let cuts = ClipSeams.cuts(in: short, song: song) { $0 == record.id ? record : nil }
        #expect(cuts.count == 1)
        #expect(cuts.first?.sentence.hasPrefix("Drop stops Vocals of A voice, bars 1–4 at its bar 3 of 4, mid-line") == true, "\(cuts)")
        #expect(cuts.first?.sentence.contains("It rests after bar 2") == true && cuts.first?.sentence.contains("each turn") == false,
                "three bars of four never loop")
        // Six bars of a four-bar clip: it goes round once, mid-line, and ends on its rest after bar 2.
        let long = Section(name: "Chorus", stitch: [Lane(part: whole.partID)], lengthInBars: 6)
        let loops = ClipSeams.cuts(in: long, song: song) { $0 == record.id ? record : nil }
        #expect(loops.first?.sentence.hasPrefix("Vocals of A voice, bars 1–4 loops mid-line in Chorus: the voice is still going as bar 4 ends.") == true,
                "\(loops)")
        let even = Section(name: "Hook", stitch: [Lane(part: clean.partID)], lengthInBars: 4)
        #expect(ClipSeams.cuts(in: even, song: song) { $0 == record.id ? record : nil }.isEmpty, "it ends on its rest, twice")
        let unmeasured = Record(title: "A voice", media: record.media, stems: [Self.stem(rests: false)])
        #expect(ClipSeams.cuts(in: short, song: song) { _ in unmeasured }.isEmpty, "nothing said before it is measured")
    }
}
