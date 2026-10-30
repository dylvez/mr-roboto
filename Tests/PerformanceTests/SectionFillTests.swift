import Foundation
import SongGraph
import Testing
@testable import Performance

/// A section's groove, laid out to the section and marked at its edges the way a drummer would.
@Suite("Section fills")
struct SectionFillTests {
    /// Two bars of 4/4 sixteenths: kick on 1 and 3, snare on 2 and 4, eighth hats, a shaker on every step.
    static let groove = Groove(stepsPerBar: 16, bars: 2, patterns: [
        GroovePattern(voice: .kick, steps: (0..<32).map { $0 % 8 == 0 ? .accent : .rest }),
        GroovePattern(voice: .snare, steps: (0..<32).map { $0 % 8 == 4 ? .accent : .rest }),
        GroovePattern(voice: .closedHat, steps: (0..<32).map { $0 % 2 == 0 ? .normal : .rest }),
        GroovePattern(voice: .shaker, steps: [VelocityTier](repeating: .ghost, count: 32)),
    ])

    private func steps(_ groove: Groove, _ voice: DrumVoice) -> [VelocityTier] {
        groove.patterns.first { $0.voice == voice }?.steps ?? []
    }

    @Test("the loop is laid out to the section, and every pattern keeps the section's length")
    func laidOut() {
        let arranged = SectionFill.arranged(Self.groove, bars: 8, beatsPerBar: 4, fillIntoNext: true, crashIn: true)
        #expect(arranged.bars == 8)
        #expect(arranged.patterns.allSatisfy { $0.steps.count == 128 })
        // Away from the edges it is the loop, bar for bar.
        #expect(Array(steps(arranged, .snare)[32..<64]) == steps(Self.groove, .snare))
    }

    @Test("the last half bar is a fill down the toms; the hats rest, the shaker keeps going")
    func fill() {
        let arranged = SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fillIntoNext: true, crashIn: false)
        let start = 4 * 16 - 8
        #expect(steps(arranged, .closedHat)[start...].allSatisfy { $0 == .rest })
        #expect(steps(arranged, .kick)[start] == .accent)
        #expect(steps(arranged, .snare)[start] == .ghost)
        #expect(steps(arranged, .highTom)[start + 2] != .rest)
        #expect(steps(arranged, .midTom)[start + 4] == .accent)
        #expect(steps(arranged, .lowTom)[start + 7] != .rest)
        #expect(steps(arranged, .shaker)[start...].allSatisfy { $0 == .ghost })
        // Nothing before the fill moves.
        #expect(Array(steps(arranged, .closedHat)[0..<start]) == Array((0..<start).map { $0 % 2 == 0 ? VelocityTier.normal : .rest }))
    }

    @Test("a section after another opens on a crash, with the kick under it")
    func crash() {
        let arranged = SectionFill.arranged(Self.groove, bars: 2, beatsPerBar: 4, fillIntoNext: false, crashIn: true)
        #expect(steps(arranged, .crash).first == .accent)
        #expect(steps(arranged, .crash).dropFirst().allSatisfy { $0 == .rest })
        #expect(steps(arranged, .kick).first == .accent)
        #expect(steps(arranged, .highTom).isEmpty, "no fill was asked for")
    }

    @Test("nothing to mark, or a one-bar section with only a fill, leaves the groove alone")
    func untouched() {
        #expect(SectionFill.arranged(Self.groove, bars: 8, beatsPerBar: 4, fillIntoNext: false, crashIn: false) == Self.groove)
        #expect(SectionFill.arranged(Self.groove, bars: 1, beatsPerBar: 4, fillIntoNext: true, crashIn: false) == Self.groove)
    }

    @Test("in 3/4 the fill takes the last beat; in 6/8 on eighths it takes the last three eighths")
    func otherMeters() {
        let waltz = Groove(stepsPerBar: 12, bars: 1, patterns: [
            GroovePattern(voice: .kick, steps: (0..<12).map { $0 == 0 ? .accent : .rest }),
        ])
        let arranged = SectionFill.arranged(waltz, bars: 2, beatsPerBar: 3, fillIntoNext: true, crashIn: false)
        let toms = [DrumVoice.snare, .highTom, .midTom, .lowTom].flatMap { voice in
            steps(arranged, voice).indices.filter { steps(arranged, voice)[$0] != .rest }
        }
        #expect(toms.min() == 20 && toms.max() == 23)

        let sixEight = Groove(stepsPerBar: 6, bars: 2, patterns: [
            GroovePattern(voice: .kick, steps: (0..<12).map { $0 % 6 == 0 ? .accent : .rest }),
        ])
        let bell = SectionFill.arranged(sixEight, bars: 4, beatsPerBar: 6, fillIntoNext: true, crashIn: false)
        let fillSteps = [DrumVoice.snare, .highTom, .midTom, .lowTom].flatMap { voice in
            steps(bell, voice).indices.filter { steps(bell, voice)[$0] != .rest }
        }
        #expect(fillSteps.min() == 21 && fillSteps.max() == 23)
    }
}

/// Every feel the library ships is heard on every kit: no line on a voice no machine plays.
@Suite("Feels and kits")
struct FeelVoicesTests {
    @Test("every voice a shipped feel writes is one the kits have")
    func everyVoiceIsPlayable() {
        let kitVoices: Set<DrumVoice> = [
            .kick, .snare, .clap, .rim, .closedHat, .openHat, .ride, .crash, .lowTom, .midTom, .highTom, .cowbell,
            .shaker, .tambourine, .highConga, .lowConga, .highBongo, .lowBongo, .claves, .woodblock,
            .highAgogo, .lowAgogo, .cabasa, .guiro, .guiroLong, .openTriangle, .muteTriangle, .vibraslap,
            .cajon, .cajonSlap, .darbuka, .darbukaTek, .frameDrum, .slitDrum,
            .timbaleHigh, .timbaleLow, .cuicaOpen, .cuicaMute, .palmas,
        ]
        for feel in FeelLibrary.standard.feels {
            for pattern in feel.groove.patterns {
                #expect(kitVoices.contains(pattern.voice), "\(feel.name) writes \(pattern.voice), which no kit plays")
            }
        }
    }

    @Test("every shipped feel's steps fill its bars, and its bars divide into its meter")
    func shapes() {
        for feel in FeelLibrary.standard.feels {
            let groove = feel.groove
            #expect(groove.patterns.allSatisfy { $0.steps.count == groove.stepsPerBar * groove.bars }, "\(feel.name)")
            #expect(groove.stepsPerBar % feel.timeSignature.beatsPerBar == 0, "\(feel.name)")
            #expect(feel.tempoRange.contains(feel.suggestedTempo), "\(feel.name)")
            #expect(feel.tempoRange.upperBound <= 300, "\(feel.name) asks for more than the clock runs")
        }
    }
}

/// A groove with timbales fills on them, as a timbalero does, and leaves the toms alone.
@Suite("Fills on the timbales")
struct TimbaleFillTests {
    @Test("a fill in a groove that has timbales walks the timbales, high to low")
    func timbaleWalk() {
        var timbale = [VelocityTier](repeating: .rest, count: 16)
        timbale[12] = .accent
        var kick = [VelocityTier](repeating: .rest, count: 16)
        kick[0] = .accent
        let groove = Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: kick),
                                                                 GroovePattern(voice: .timbaleLow, steps: timbale)])
        let filled = SectionFill.arranged(groove, bars: 2, beatsPerBar: 4, fillIntoNext: true, crashIn: false)
        func hits(_ voice: DrumVoice) -> [Int] {
            filled.patterns.first { $0.voice == voice }?.steps.enumerated().filter { $0.element != .rest }.map(\.offset) ?? []
        }
        #expect(!hits(.timbaleHigh).isEmpty && hits(.timbaleHigh).allSatisfy { $0 >= 24 })
        #expect(hits(.timbaleLow).contains(12) && hits(.timbaleLow).contains { $0 >= 28 })
        #expect(hits(.highTom).isEmpty && hits(.snare).isEmpty, "the toms are not the fill")
    }
}


/// The vocabulary of fills: each shape plays the voices it names and silences what it says, the
/// chooser's table holds, and a way out round-trips on disk with its shape.
@Suite("Fill shapes")
struct FillShapeTests {
    static let groove = SectionFillTests.groove

    private func steps(_ groove: Groove, _ voice: DrumVoice) -> [VelocityTier] {
        groove.patterns.first { $0.voice == voice }?.steps ?? []
    }

    private func hits(_ groove: Groove, _ voice: DrumVoice, from start: Int = 0) -> [Int] {
        steps(groove, voice).indices.filter { $0 >= start && steps(groove, voice)[$0] != .rest }
    }

    @Test("every shape is named, described and sized, and found by its name")
    func named() {
        for shape in FillShape.allCases {
            #expect(!shape.name.isEmpty && !shape.about.isEmpty, "\(shape)")
            #expect(shape == .none || shape.sizes.contains(shape.defaultSize), "\(shape)'s own size is one it comes in")
            #expect(FillShape.named(shape.rawValue) == shape && FillShape.named(shape.name) == shape)
        }
        #expect(FillShape.named("snare roll") == .snareRoll && FillShape.named("the kit out") == .dropOut && FillShape.named("tambourine") == nil)
        #expect(FillSize.named("half a bar") == .halfBar && FillSize.named("two bars") == .twoBars && FillSize.named("bar") == .bar)
        #expect(FillSize.of(beats: 2, in: 4) == .halfBar && FillSize.of(beats: 4, in: 4) == .bar && FillSize.of(beats: 8, in: 4) == .twoBars
                && FillSize.of(beats: 1, in: 4) == .beat && FillSize.of(beats: 0, in: 4) == nil)
        #expect(Fill.usual.name == "the snare down the toms, half a bar" && Fill(shape: .none).name == "no fill")
    }

    @Test("each shape plays the voices it names in its window and silences what it says", arguments: FillShape.allCases)
    func renders(shape: FillShape) {
        let fill = Fill(shape: shape)
        let arranged = SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fill: fill, crashIn: false)
        let total = 64
        let length = SectionFill.length(of: fill.size, shape: shape, stepsPerBar: 16, stepsPerBeat: 4, beats: 4, bars: 4)
        let start = total - length
        #expect(shape == .none || hits(arranged, .shaker).count == 64, "\(shape): the shaker keeps going")
        switch shape {
        case .tomWalkDown:
            #expect(length == 8 && steps(arranged, .snare)[start] == .ghost && !hits(arranged, .lowTom, from: start).isEmpty)
            #expect(hits(arranged, .closedHat, from: start).isEmpty)
        case .tomWalkUp:
            #expect(length == 8 && steps(arranged, .lowTom)[start] == .ghost && !hits(arranged, .snare, from: start + 6).isEmpty)
            #expect(hits(arranged, .closedHat, from: start).isEmpty && hits(arranged, .snare, from: start).allSatisfy { $0 >= start + 6 })
        case .snareRoll:
            #expect(length == 8 && hits(arranged, .snare, from: start).count == 6, "\(hits(arranged, .snare, from: start))")
            #expect(hits(arranged, .lowTom).isEmpty && hits(arranged, .highTom).isEmpty && hits(arranged, .closedHat, from: start).isEmpty)
            #expect(steps(arranged, .snare)[total - 1] == .accent && steps(arranged, .kick)[start] == .accent)
        case .kickSnare:
            #expect(hits(arranged, .kick, from: start) == [start, start + 1, start + 4, start + 5])
            #expect(hits(arranged, .snare, from: start) == [start + 2, start + 6] && steps(arranged, .snare)[start + 2] == .accent)
            #expect(hits(arranged, .lowTom).isEmpty)
        case .flam:
            #expect(length == 4 && steps(arranged, .snare)[start] == .accent && steps(arranged, .snare)[total - 1] == .ghost)
            #expect(hits(arranged, .closedHat, from: start).isEmpty && !hits(arranged, .closedHat, from: start - 4).isEmpty, "only the last beat rests")
        case .dropOut:
            for voice in SectionFill.kitVoices { #expect(hits(arranged, voice, from: start).isEmpty, "\(voice) still plays through the drop-out") }
            #expect(!hits(arranged, .kick, from: start - 8).isEmpty, "and played before it")
        case .hatLift:
            #expect(length == 16 && hits(arranged, .openHat, from: start) == stride(from: start, to: total, by: 2).map { $0 })
            #expect(hits(arranged, .closedHat, from: start).isEmpty && hits(arranged, .lowTom).isEmpty)
            #expect(hits(arranged, .kick, from: start) == [start, start + 8] && hits(arranged, .snare, from: start) == [start + 4, start + 12], "the kick and snare as written")
        case .rimPickup:
            #expect(length == 4 && steps(arranged, .rim)[start] == .normal && steps(arranged, .highTom)[start + 2] == .accent)
            #expect(hits(arranged, .closedHat, from: start).isEmpty)
        case .timbales:
            #expect(!hits(arranged, .timbaleHigh, from: start).isEmpty && !hits(arranged, .timbaleLow, from: start).isEmpty && hits(arranged, .lowTom).isEmpty)
        case .build:
            #expect(length == 16 && hits(arranged, .snare, from: start).count == 12 && hits(arranged, .kick, from: start) == [start, start + 4, start + 8, start + 12])
            #expect(steps(arranged, .snare)[start] == .ghost && steps(arranged, .snare)[total - 1] == .accent && hits(arranged, .closedHat, from: start).isEmpty)
        case .none:
            #expect(arranged == Self.groove, "no fill and no crash leaves the groove alone")
        }
    }

    @Test("a size is a beat, half a bar, a bar or two, held to what the section has and the shape allows")
    func sizes() {
        func length(_ size: FillSize, _ shape: FillShape = .snareRoll, bars: Int = 4) -> Int {
            SectionFill.length(of: size, shape: shape, stepsPerBar: 16, stepsPerBeat: 4, beats: 4, bars: bars)
        }
        #expect(length(.beat) == 4 && length(.halfBar) == 8 && length(.bar) == 16 && length(.twoBars, .hatLift) == 32)
        #expect(length(.twoBars) == 8, "a size the shape does not come in is the shape's own")
        #expect(length(.twoBars, .hatLift, bars: 2) == 16 && length(.bar, bars: 1) == 8, "a bar needs a bar before it")
        #expect(length(.bar, .flam) == 4 && length(.beat, .build) == 16, "a flam is a beat, a build a bar")
        let roll = SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fill: Fill(shape: .snareRoll, size: .bar), crashIn: false)
        #expect(hits(roll, .closedHat).allSatisfy { $0 < 48 } && hits(roll, .snare, from: 48).count == 12)
        // The usual fill is the one every song had: the old entry point writes the same groove.
        #expect(SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fill: .usual, crashIn: true)
                == SectionFill.arranged(Self.groove, bars: 4, beatsPerBar: 4, fillIntoNext: true, crashIn: true))
    }

    @Test("the chooser's table: the family, the edge and the step pick among shapes that fit, and a whole bar only into a peak")
    func chooser() {
        func shapes(_ family: FillFamily, _ from: SectionRole, _ to: SectionRole, step: Double = 0.2) -> Set<FillShape> {
            Set(SectionFill.candidates(from: from, to: to, step: step, family: family).map(\.shape))
        }
        #expect(shapes(.kit, .verse, .hook).isSubset(of: [.snareRoll, .tomWalkDown, .kickSnare]) && !shapes(.kit, .verse, .hook).isEmpty)
        #expect(shapes(.electronic, .verse, .hook).isSubset(of: [.hatLift, .dropOut]), "no toms on a machine")
        #expect(shapes(.electronic, .build, .drop).contains(.dropOut) || shapes(.electronic, .verse, .drop).contains(.dropOut))
        #expect(shapes(.reggae, .verse, .hook) == [.rimPickup, .dropOut])
        #expect(shapes(.latin, .verse, .hook).isSubset(of: [.timbales, .none]) && shapes(.jazz, .verse, .hook) == [.none, .flam])
        #expect(shapes(.kit, .verse, .breakdown) == [.dropOut] && shapes(.electronic, .hook, .breakdown) == [.dropOut])
        #expect(shapes(.kit, .verse, .bridge) == [.tomWalkUp, .snareRoll] && shapes(.electronic, .verse, .bridge) == [.hatLift, .dropOut])
        #expect(shapes(.kit, .hook, .verse) == [.flam, .dropOut, .none] && shapes(.latin, .hook, .verse) == [.none])
        #expect(shapes(.kit, .verse, .verse) == [.none, .flam] && shapes(.kit, .hook, .outro) == [.flam, .dropOut, .none])
        #expect(shapes(.kit, .intro, .verse) == [.tomWalkDown, .snareRoll, .kickSnare])
        // Decision 2: a whole bar into a hook or a drop only, from a verse or a build, and only on a big step.
        for family in FillFamily.allCases {
            for from in SectionRole.allCases {
                for to in SectionRole.allCases {
                    for step in [0.1, 0.4] {
                        for fill in SectionFill.candidates(from: from, to: to, step: step, family: family) where fill.size == .bar || fill.size == .twoBars {
                            #expect(to.isPeak || to == .breakdown || fill.shape == .hatLift, "\(family) \(from)→\(to) at \(step): \(fill.name)")
                            if to.isPeak, from != .build, family == .kit {
                                #expect(step >= SectionFill.bigStep || (from == .verse && to == .drop), "\(from)→\(to) at \(step): \(fill.name) is a bar on a small step")
                            }
                        }
                    }
                }
            }
        }
        // A build's roll is its own way out; nothing follows the last section.
        #expect(SectionFill.choose(from: .build, to: .drop, step: 0.2, family: .kit, seed: 1, index: 0) == nil)
        #expect(SectionFill.choose(from: .verse, to: nil, step: 0, family: .kit, seed: 1, index: 0) == nil)
        // The seed and the edge's place choose among what fits: two edges of one song, two songs.
        let edges = (0..<8).map { SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: 7, index: $0) }
        #expect(Set(edges.map { $0?.name ?? "" }).count >= 2, "\(edges.map { $0?.name ?? "" })")
        let songs = (1...8).map { SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: UInt64($0), index: 0) }
        #expect(Set(songs.map { $0?.name ?? "" }).count >= 2)
        #expect(SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: 7, index: 3)
                == SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: 7, index: 3), "the same song, the same fill")
        // The fill the edge before played is not played twice running when another fits.
        for seed in 1...12 {
            let first = SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: UInt64(seed), index: 1)
            let second = SectionFill.choose(from: .verse, to: .hook, step: 0.35, family: .kit, seed: UInt64(seed), index: 3, avoiding: first)
            #expect(first != nil && second != nil && first != second, "seed \(seed): \(first?.name ?? "") twice")
        }
        #expect(SectionFill.choose(from: .verse, to: .breakdown, step: 0, family: .latin, seed: 3, index: 1, avoiding: Fill(shape: .dropOut, size: .halfBar))?.shape == .dropOut,
                "with nothing else that fits, the same again")
        // A family from a feel's idioms: the most specific first.
        #expect(FillFamily.of(idioms: [.house, .electronic]) == .electronic && FillFamily.of(idioms: [.motown, .soul]) == .kit)
        #expect(FillFamily.of(idioms: [.dub, .reggae]) == .reggae && FillFamily.of(idioms: [.latin]) == .latin && FillFamily.of(idioms: [.jazz]) == .jazz)
        #expect(FillFamily.of(idioms: [.cinematic]) == .quiet && FillFamily.of(idioms: []) == .kit)
    }

    @Test("a way out carries its fill: the shape by name and the size in beats, round-tripped, and a way out written before reads as it did")
    func transition() throws {
        let way = Transition.fill(Fill(shape: .snareRoll, size: .halfBar), beatsPerBar: 4)
        #expect(way.kind == .fill && way.shape == "snare-roll" && way.beats == 2)
        #expect(way.fill(beatsPerBar: 4) == Fill(shape: .snareRoll, size: .halfBar))
        #expect(way.wayOut(beatsPerBar: 4) == "a snare roll, half a bar")
        let data = try JSONEncoder().encode(way)
        #expect(try JSONDecoder().decode(Transition.self, from: data) == way)
        #expect(String(decoding: data, as: UTF8.self).contains("\"shape\":\"snare-roll\""))
        // Written before shapes existed: no shape key, and none when read.
        let old = try JSONDecoder().decode(Transition.self, from: Data(#"{"kind":"cut","beats":0}"#.utf8))
        #expect(old == Transition(kind: .cut) && old.shape == nil && old.wayOut(beatsPerBar: 4) == "cut")
        let bare = try JSONDecoder().decode(Transition.self, from: Data(#"{"kind":"fill"}"#.utf8))
        #expect(bare.kind == .fill && bare.beats == 0 && bare.fill(beatsPerBar: 4) == nil && bare.wayOut(beatsPerBar: 4) == "the usual fill")
        #expect(!String(decoding: try JSONEncoder().encode(Transition(kind: .riser)), as: UTF8.self).contains("shape"), "a way out with no shape writes none")
        #expect(Transition(kind: .riser).wayOut(beatsPerBar: 4) == "a build's roll to the bar line")
        // A size the meter rounds: 3/4's half bar is a beat.
        #expect(Transition.fill(Fill(shape: .tomWalkDown, size: .halfBar), beatsPerBar: 3).fill(beatsPerBar: 3)?.size == .halfBar)
    }
}
