import Foundation
import MusicTheory
import SongGraph
import Testing
@testable import Performance

/// The figure hands as vocabularies: each has a few cited figures, writes in phrases that turn,
/// and the seed chooses — so two seeds are two lines, which they were not before.
@Suite("Bass figures")
struct BassFiguresTests {

    static let figureHands: [BassLineage] = [.rootFifth, .motown, .oneDrop, .octave, .tumbao, .walking, .rolling, .dub, .afrobeat, .logDrum, .pedal]

    static func request(_ lineage: BassLineage, density: Double = 0.6, seed: UInt64 = 7, bars: Int? = 4,
                        chords: [ChordSpan] = BassWriterTests.dm7g7, figure: Int? = nil) -> BassRequest {
        BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: chords, groove: BassWriterTests.groove(),
                    tempo: 92, lineage: lineage, density: density, seed: seed, bars: bars, figure: figure)
    }

    /// A line's rhythm, bar by bar, as sixteenth-step grids of its attacks.
    static func rhythm(_ line: Bassline, bars: Int) -> [String] {
        (0..<bars).map { bar in
            var grid = Array(repeating: "-", count: 16)
            for note in line.notes where note.velocity > 60 {
                let step = Int(((note.start - Double(bar) * 4) * 4).rounded())
                if (0..<16).contains(step) { grid[step] = "x" }
            }
            return grid.joined()
        }
    }

    @Test("every figure hand has a vocabulary, each figure named, described and cited; the kick players have none",
          arguments: BassLineage.allCases)
    func cited(lineage: BassLineage) {
        let figures = lineage.figures
        if Self.figureHands.contains(lineage) {
            #expect(figures.count >= 2, "\(lineage) has \(figures.count) figures")
            #expect(lineage.writesFigures)
            for figure in figures {
                #expect(!figure.name.isEmpty && !figure.about.isEmpty, "\(lineage): \(figure.name)")
                #expect(figure.source.contains("profile"), "\(lineage): \(figure.name) cites no profile: \(figure.source)")
                #expect(figure.lineage == lineage)
            }
            #expect(Set(figures.map(\.name)).count == figures.count, "\(lineage): a name twice")
        } else {
            #expect(figures.isEmpty && !lineage.writesFigures)
            #expect(BassWriter.phrase(for: Self.request(lineage)) == nil)
        }
    }

    @Test("two seeds are two rhythms, in every figure hand", arguments: figureHands)
    func seedsDiffer(lineage: BassLineage) {
        let lines = (1...8).map { seed in BassWriter.write(Self.request(lineage, seed: UInt64(seed))) }
        // A pedal is one note a chord whatever the seed; its seeds differ in how it breathes.
        if lineage == .pedal {
            #expect(Set(lines.map { $0.notes.map { ($0.start * 100).rounded() / 100 + $0.duration } }).count >= 2, "pedal: one line in eight seeds")
            return
        }
        let rhythms = Set(lines.map { Self.rhythm($0, bars: 4).joined(separator: "|") })
        #expect(rhythms.count >= 2, "\(lineage): one rhythm in eight seeds")
    }

    @Test("the same seed is the same line, and the phrase it names is the one written", arguments: figureHands)
    func sameSeed(lineage: BassLineage) throws {
        let request = Self.request(lineage, seed: 11)
        #expect(BassWriter.write(request) == BassWriter.write(request))
        let phrase = try #require(BassWriter.phrase(for: request))
        #expect(lineage.figures.contains { $0.name == phrase.figure.name })
        #expect(phrase.length == 4)
        #expect(!phrase.about.isEmpty)
        // Asked for by number, the figure is that one, counted round, and the rest of the line
        // is as the seed had it.
        for index in 0..<lineage.figures.count {
            let asked = try #require(BassWriter.phrase(for: Self.request(lineage, seed: 11, figure: index)))
            #expect(asked.figureIndex == index && asked.figure.name == lineage.figures[index].name)
            #expect(asked.turnaround == phrase.turnaround && asked.swapped == phrase.swapped)
        }
        let round = try #require(BassWriter.phrase(for: Self.request(lineage, seed: 11, figure: lineage.figures.count + 1)))
        #expect(round.figureIndex == 1)
    }

    @Test("every figure of a hand is a different line", arguments: figureHands)
    func figuresDiffer(lineage: BassLineage) {
        let lines = lineage.figures.indices.map { BassWriter.write(Self.request(lineage, seed: 11, figure: $0)) }
        for (i, a) in lines.enumerated() {
            for (j, b) in lines.enumerated() where j > i {
                #expect(a.notes != b.notes, "\(lineage): \(lineage.figures[i].name) and \(lineage.figures[j].name) are one line")
            }
        }
    }

    @Test("a phrase is four bars, two for a two-bar line, one for a one-bar line")
    func phraseLength() throws {
        #expect(try #require(BassWriter.phrase(for: Self.request(.rootFifth, bars: 8))).length == 4)
        #expect(try #require(BassWriter.phrase(for: Self.request(.rootFifth, bars: 2))).length == 2)
        #expect(try #require(BassWriter.phrase(for: Self.request(.rootFifth, bars: 1))).length == 1)
        // The two-bar line turns in its second bar where its phrase does; the one-bar line never.
        let two = Self.request(.rootFifth, seed: 3, bars: 2, figure: 3)
        let phrase = try #require(BassWriter.phrase(for: two))
        #expect(phrase.turnaround(atBar: 0, of: 2) == nil && phrase.turnaround(atBar: 1, of: 2) == phrase.turnaround)
        let one = try #require(BassWriter.phrase(for: Self.request(.rootFifth, seed: 3, bars: 1)))
        #expect(one.turnaround(atBar: 0, of: 1) == nil)
        // A long line's eighth bar turns with its second turnaround.
        let long = try #require(BassWriter.phrase(for: Self.request(.motown, seed: 5, bars: 16)))
        #expect(long.turnaround(atBar: 3, of: 16) == long.turnaround && long.turnaround(atBar: 7, of: 16) == long.secondTurnaround)
        #expect(long.turnaround(atBar: 4, of: 16) == nil)
    }

    @Test("the turnarounds do what they say to a bar")
    func turnarounds() {
        let bar = BassFigures.Bar(density: 0.6, beats: 4, index: 3, bars: 4, held: false, changeNext: true, changes: [], swapped: false)
        let body = [BassFigures.Note(at: 0, tone: .interval(0), length: 0.9, weight: 3),
                    BassFigures.Note(at: 2, tone: .interval(0), length: 0.9, weight: 3),
                    BassFigures.Note(at: 3, tone: .interval(0), length: 0.45, weight: 1)]
        let rest = BassFigures.turned(body, .restOnFour, bar: bar, lineage: .rootFifth)
        #expect(rest.map(\.at) == [0, 2])
        let walk = BassFigures.turned(body, .walkUp, bar: bar, lineage: .rootFifth)
        #expect(walk.map(\.at) == [0, 2, 3])
        if case .stepTo(let steps, _) = walk[1].tone { #expect(steps == -2) } else { Issue.record("beat three is not a step") }
        if case .stepTo(let steps, _) = walk[2].tone { #expect(steps == -1) } else { Issue.record("beat four is not a step") }
        let skip = BassFigures.turned(body, .skip, bar: bar, lineage: .rootFifth)
        #expect(skip.map(\.at) == [0, 2, 3, 3.5, 3.75] && skip.suffix(2).allSatisfy { $0.anticipates == 4 })
        let fifth = BassFigures.turned(body, .fifthDown, bar: bar, lineage: .oneDrop)
        if case .interval(let a) = fifth[0].tone, case .interval(let b) = fifth[1].tone { #expect(a == 0 && b == -5) } else { Issue.record("not intervals") }
        let marked = BassFigures.turned(Array(body.dropFirst()), .markOne, bar: bar, lineage: .tumbao)
        #expect(marked.first?.at == 0 && marked.count == 3)
        #expect(BassFigures.turned(body, .markOne, bar: bar, lineage: .tumbao).count == 3, "one already struck is not struck twice")
        let down = BassFigures.turned(body, .octaveWalkDown, bar: bar, lineage: .octave)
        #expect(down.count == 6 && down.allSatisfy { $0.at < 3 })
        #expect(BassFigures.turned(body, .none, bar: bar, lineage: .rootFifth).map(\.at) == body.map(\.at))
    }

    @Test("a walk-up steps up the key's scale into the next bar's root")
    func walkUp() throws {
        let key = Key(tonic: NoteName(.d), mode: .aeolian)
        // D aeolian: D E F G A B♭ C. Two steps below D is B♭, one below is C; one above is E.
        #expect(BassFigures.scaleStep(from: 62, by: -2, in: key) == 58)
        #expect(BassFigures.scaleStep(from: 62, by: -1, in: key) == 60)
        #expect(BassFigures.scaleStep(from: 62, by: 1, in: key) == 64)
        #expect(BassFigures.scaleStep(from: 62, by: 3, in: key) == 67)
        // Off the scale, semitones.
        #expect(BassFigures.scaleStep(from: 61, by: -2, in: key) == 59)
        // In a line: the Walk-up figure of the root–fifth hand, at a change, puts the last beat a
        // scale step below the next root.
        let line = BassWriter.write(Self.request(.rootFifth, density: 0.3, seed: 2, bars: 2, figure: 3))
        // Bar one is Dm7, bar two G7: beat four of bar one is F, the step below G.
        let four = try #require(line.notes.first { abs($0.start - 3) < 0.01 })
        #expect(four.pitch.pitchClass == .f, "\(four.pitch)")
    }

    @Test("the hands that follow the kick land on the groove's off-beat kicks", arguments: [BassLineage.motown, .octave, .rolling, .afrobeat, .logDrum])
    func followsTheKick(lineage: BassLineage) {
        // G1's kick: one and the and of two, every bar.
        for seed in 1...4 {
            let line = BassWriter.write(Self.request(lineage, density: 0.6, seed: UInt64(seed)))
            for bar in 0..<4 {
                let kick = Double(bar) * 4 + 1.5
                #expect(line.notes.contains { abs($0.start - kick) < 0.13 }, "\(lineage) seed \(seed): nothing on the kick at \(kick)")
            }
        }
    }

    @Test("the hands that play against the kick keep their figure", arguments: [BassLineage.oneDrop, .tumbao, .dub])
    func againstTheKick(lineage: BassLineage) {
        // The same figure under a kick on every beat and under G1's: the figure's own onsets are the same.
        var floor = Self.request(lineage, seed: 3, figure: 0)
        floor.groove = Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: (0..<16).map { $0 % 4 == 0 ? .normal : .rest })])
        let a = Self.rhythm(BassWriter.write(floor), bars: 4)
        let b = Self.rhythm(BassWriter.write(Self.request(lineage, seed: 3, figure: 0)), bars: 4)
        #expect(a == b, "\(lineage): \(a) under four on the floor, \(b) under G1")
    }

    @Test("a bar never has more attacks than the hand's ceiling, and density moves the count", arguments: figureHands)
    func budget(lineage: BassLineage) {
        let ceiling = BassWriter.attackBudget(density: 1, tempo: 92, lineage: lineage)
        for seed in 1...4 {
            for density in [0.0, 0.5, 1.0] {
                let line = BassWriter.write(Self.request(lineage, density: density, seed: UInt64(seed)))
                for bar in 0..<4 {
                    let attacks = Set(line.notes.filter { $0.velocity > 60 && $0.start >= Double(bar) * 4 && $0.start < Double(bar + 1) * 4 }
                        .map { ($0.start * 100).rounded() }).count
                    // Motown's chromatic approaches and a walking line's step into the change sit outside the budget.
                    #expect(attacks <= ceiling + 1, "\(lineage) seed \(seed) density \(density) bar \(bar + 1): \(attacks) attacks")
                }
            }
        }
        guard lineage != .pedal else { return }
        func attacks(_ density: Double) -> Int { BassWriter.write(Self.request(lineage, density: density, seed: 2)).notes.filter { $0.velocity > 60 }.count }
        #expect(attacks(0) <= attacks(1), "\(lineage): \(attacks(0)) bare, \(attacks(1)) busy")
    }

    @Test("the hands that strike one strike it in every bar, turnaround bars too", arguments: [BassLineage.rootFifth, .walking, .motown, .rolling])
    func downbeat(lineage: BassLineage) {
        for seed in 1...6 {
            let line = BassWriter.write(Self.request(lineage, seed: UInt64(seed), bars: 8))
            for bar in 0..<8 {
                #expect(line.notes.contains { abs($0.start - Double(bar) * 4) < 0.01 && $0.velocity > 60 }, "\(lineage) seed \(seed): bar \(bar + 1) has no one")
            }
        }
    }

    @Test("a change inside the bar is said on the new root, by a note of the figure or one of its own")
    func changeInsideTheBar() throws {
        let chords = [ChordSpan(Chord(.g, .major), beats: 2), ChordSpan(Chord(.c, .major), beats: 2)]
        // The bossa has a note on three: there it plays the new chord's root, not the fifth below the old.
        let bossa = BassWriter.write(Self.request(.rootFifth, density: 0.3, seed: 3, bars: 2, chords: chords, figure: 6))
        let three = try #require(bossa.notes.first { abs($0.start - 2) < 0.01 })
        #expect(three.pitch.pitchClass == .c, "\(three.pitch)")
        // The three-three-two has none near it: it gets a root of its own, and every note stays the chord's.
        let bulgar = BassWriter.write(Self.request(.rootFifth, density: 0.3, seed: 3, bars: 2, chords: chords, figure: 5))
        #expect(bulgar.notes.contains { abs($0.start - 2) < 0.01 && $0.pitch.pitchClass == .c }, "\(bulgar.notes.map { ($0.start, $0.pitch.midi) })")
        // A chord that lasts the bar changes nothing.
        let held = [ChordSpan(Chord(.g, .major), beats: 4)]
        #expect(BassFigures.changing([BassFigures.Note(at: 2, tone: .interval(-5), length: 1)], on: [], lineage: .rootFifth).count == 1)
        #expect(BassWriter.write(Self.request(.rootFifth, density: 0.3, seed: 3, bars: 1, chords: held, figure: 5)).notes.map(\.start) == [0, 1.5, 3])
    }

    @Test("the figures the root–fifth hand was missing: the bulgar's 3+3+2, the bossa's bounce, the cumbia's long three")
    func theGenresOwn() throws {
        let hand = BassLineage.rootFifth.figures.map(\.name)
        #expect(Array(hand.suffix(3)) == ["Three-three-two", "Bossa", "Cumbia"], "\(hand)")
        func line(_ figure: Int) -> Bassline {
            BassWriter.write(Self.request(.rootFifth, density: 0.4, seed: 5, bars: 1, chords: [ChordSpan(Chord(.d, .minor), beats: 4)], figure: figure))
        }
        #expect(line(5).notes.map(\.start) == [0, 1.5, 3], "3+3+2")
        #expect(Array(line(6).notes.map(\.start).prefix(3)) == [0, 1.5, 2], "the long-short into three")
        let cumbia = line(7).notes
        #expect(cumbia.map(\.start) == [0, 1, 2, 3] && cumbia[0].duration < 0.5 && cumbia[2].duration > 0.9, "staccato, the three long")
    }

    @Test("a tumbao's one is struck only to mark a bar; the one drop's figure leaves one empty")
    func idioms() {
        let tumbao = BassWriter.write(Self.request(.tumbao, seed: 4, figure: 0))
        #expect(tumbao.notes.filter { $0.start.truncatingRemainder(dividingBy: 4) < 0.01 }.count <= 1, "the plain tumbao strikes one at most at the turn")
        let oneDrop = BassWriter.write(Self.request(.oneDrop, seed: 4, figure: 0))
        for bar in 0..<3 {
            #expect(!oneDrop.notes.contains { abs($0.start - Double(bar) * 4) < 0.01 }, "the one drop's bar \(bar + 1) has a one")
        }
    }

    @Test("over the key's I–IV–V–I the figures are chord tones or the key's steps", arguments: figureHands)
    func inKey(lineage: BassLineage) {
        let key = Key(tonic: NoteName(.d), mode: .aeolian)
        let request = Self.request(lineage, seed: 9, chords: [])
        let line = BassWriter.write(request)
        let harmony = HarmonyMap(chords: request.effectiveChords, totalBeats: 16)
        for note in line.notes where note.velocity > 60 {
            let chord = harmony.chord(at: note.start)
            let next = harmony.chord(at: (note.start + 4).truncatingRemainder(dividingBy: 16))
            let fits = chord.pitchClassSet.contains(note.pitch.pitchClass) || next.pitchClassSet.contains(note.pitch.pitchClass)
                || key.pitchClasses.contains(note.pitch.pitchClass)
                // A chromatic step into the next root.
                || abs(note.pitch.midi - BassWriter.place(next.bass, near: note.pitch.midi, in: lineage)) == 1
            let symbol = chord.symbol()
            #expect(fits, "\(lineage): \(note.pitch) at \(note.start) is no note of \(symbol), the next chord, the key or a step into it")
        }
    }
}
