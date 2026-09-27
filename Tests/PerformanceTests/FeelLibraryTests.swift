import MusicTheory
import SongGraph
import Testing
@testable import Performance

@Suite("Feel library")
struct FeelLibraryTests {

    static let library = FeelLibrary.standard

    // MARK: Validity

    @Test("every shipped feel is valid")
    func libraryValidates() {
        let issues = Self.library.validate()
        #expect(issues.isEmpty, "\(issues.map(\.description).joined(separator: "\n"))")
    }

    @Test("every feel's patterns match its time signature and bar count",
          arguments: FeelLibrary.standard.feels)
    func feelIsWellFormed(feel: Feel) {
        let expected = feel.groove.stepsPerBar * feel.groove.bars
        #expect(feel.groove.stepsPerBar > 0)
        #expect(feel.groove.bars > 0)
        #expect(feel.groove.stepsPerBar % feel.timeSignature.beatsPerBar == 0,
                "\(feel.name): \(feel.groove.stepsPerBar) steps do not divide into \(feel.timeSignature)")
        #expect(!feel.groove.patterns.isEmpty, "\(feel.name) has no patterns")
        for pattern in feel.groove.patterns {
            #expect(pattern.steps.count == expected,
                    "\(feel.name)/\(pattern.voice): \(pattern.steps.count) steps, expected \(expected)")
        }
        #expect(feel.groove.swing >= 0 && feel.groove.swing <= 1, "\(feel.name) swing out of range")
        #expect(feel.swing.percent >= 50 && feel.swing.percent <= 75)
        #expect(feel.tempoRange.contains(feel.suggestedTempo))
        #expect(!feel.idioms.isEmpty, "\(feel.name) is untagged")
        #expect(!feel.provenance.summary.isEmpty, "\(feel.name) has no provenance summary")
    }

    @Test("every feel loads and produces hits at its own tempo",
          arguments: FeelLibrary.standard.feels)
    func feelProducesHits(feel: Feel) {
        let hits = GrooveRenderer.render(feel, on: feel.suggestedTimeline)
        #expect(!hits.isEmpty, "\(feel.name) produced no hits")
        #expect(hits.allSatisfy { $0.velocity > 0 && $0.velocity <= 127 },
                "\(feel.name) produced a velocity outside 1…127")
        #expect(hits.map(\.time) == hits.map(\.time).sorted(), "\(feel.name) hits are out of order")

        // Nothing may spill outside the phrase it belongs to (allowing for swing and pocket).
        let loop = GrooveRenderer.duration(of: feel.groove, on: feel.suggestedTimeline)
        let step = feel.suggestedTimeline.stepDuration(ofStep: 0, stepsPerBar: feel.groove.stepsPerBar)
        #expect(hits.first!.time >= -step, "\(feel.name) starts before its own bar")
        #expect(hits.last!.time < loop + step, "\(feel.name) runs past its own phrase")
    }

    @Test("a feel renders the same way twice",
          arguments: FeelLibrary.standard.feels)
    func feelIsReproducible(feel: Feel) {
        let timeline = feel.suggestedTimeline
        #expect(GrooveRenderer.render(feel, on: timeline, repeats: 2)
                == GrooveRenderer.render(feel, on: timeline, repeats: 2))
    }

    @Test("every feel rides a detected grid as happily as a metronome",
          arguments: FeelLibrary.standard.feels)
    func feelRidesAGrid(feel: Feel) {
        // A wobbly grid in the feel's own meter, built around its suggested tempo.
        let beatLength = 60 / feel.suggestedTempo
        let wobble = [1.0, 1.12, 0.91, 1.05, 0.96, 1.08]
        var beats: [Double] = []
        var t = 0.0
        for index in 0..<(feel.groove.bars * feel.timeSignature.beatsPerBar * 2 + 1) {
            beats.append(t)
            t += beatLength * wobble[index % wobble.count]
        }
        let barStarts = stride(from: 0, to: beats.count, by: feel.timeSignature.beatsPerBar).map { beats[$0] }
        let grid = BeatGrid(beats: beats, bars: barStarts,
                            bpm: feel.suggestedTempo, timeSignature: feel.timeSignature)

        let hits = GrooveRenderer.render(feel, on: feel.timeline(on: grid))
        #expect(!hits.isEmpty)
        #expect(hits.last!.time < beats.last! + beatLength)
    }

    // MARK: The catalogue

    @Test("all three provenances are represented")
    func provenanceCoverage() {
        let origins = Set(Self.library.feels.map(\.provenance.origin))
        #expect(origins.contains(.grooveTheory))
        #expect(origins.contains(.theChorus))
        #expect(origins.contains(.researched))

        // The twelve ported beat templates are all there.
        let ported = Self.library.feels.filter { $0.provenance.origin == .grooveTheory }
        #expect(ported.count == 12)
        for name in ["Standard Rock", "Four on the Floor", "Boom-Bap", "Shuffle", "Bossa Nova",
                     "Train Beat", "Reggae One Drop", "Motown", "Breakbeat (Amen)", "Waltz",
                     "Jazz Waltz", "3/4 Ballad"] {
            #expect(Self.library[name] != nil, "missing ported template \(name)")
        }
        // And the six the first idiom needed.
        for name in ["Lo-Fi Hip-Hop", "Boom-Bap Pocket", "Trap Rolling Hats",
                     "Lo-Fi House", "Trip-Hop", "Neo-Soul Pocket"] {
            let feel = Self.library[name]
            #expect(feel != nil, "missing researched feel \(name)")
            #expect(feel?.provenance.origin == .researched)
            #expect(feel?.provenance.references.isEmpty == false, "\(name) cites no sources")
            #expect(feel?.provenance.lineage.isEmpty == false, "\(name) names no lineage")
        }
    }

    @Test("lookup is forgiving about spelling")
    func forgivingLookup() {
        #expect(Self.library["Boom-Bap Pocket"]?.name == "Boom-Bap Pocket")
        #expect(Self.library["boom bap pocket"]?.name == "Boom-Bap Pocket")
        #expect(Self.library["BOOMBAPPOCKET"]?.name == "Boom-Bap Pocket")
        #expect(Self.library["not a feel"] == nil)
    }

    @Test("filtering by idiom and tempo")
    func filtering() {
        let lofi = Self.library.feels(idiom: .lofi)
        #expect(lofi.count >= 3)
        #expect(lofi.allSatisfy { $0.idioms.contains(.lofi) })

        let at90 = Self.library.feels(tempo: 90)
        #expect(at90.allSatisfy { $0.tempoRange.contains(90) })
        #expect(at90.contains { $0.name == "Boom-Bap Pocket" })

        let threeFour = Self.library.feels(timeSignature: .threeFour)
        #expect(threeFour.count == 4)  // Waltz, Jazz Waltz, 3/4 Ballad, Oom-Pah Waltz
        #expect(threeFour.allSatisfy { $0.timeSignature == .threeFour })

        let combined = Self.library.feels(idiom: .hipHop, tempo: 90)
        #expect(!combined.isEmpty)
        #expect(combined.allSatisfy { $0.idioms.contains(.hipHop) && $0.tempoRange.contains(90) })
    }

    // MARK: Suggestion

    @Test("92 BPM lo-fi suggests lo-fi feels that can actually play at 92")
    func suggestsLofiAt92() {
        let suggestions = Self.library.suggest(for: FeelLibrary.Request(tempo: 92, idiom: .lofi, limit: 3))
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.idioms.contains(.lofi) },
                "asked for lo-fi, got \(suggestions.map(\.name))")
        let best = suggestions[0]
        #expect(best.name == "Lo-Fi Hip-Hop", "best for 92 BPM lo-fi was \(best.name)")
        #expect(best.tempoRange.contains(92))
        // Nothing wildly out of tempo should surface ahead of something in range.
        #expect(suggestions.first!.tempoRange.contains(92))
    }

    @Test("128 BPM house suggests house feels")
    func suggestsHouseAt128() {
        let suggestions = Self.library.suggest(for: 128, idiom: .house, limit: 3)
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.idioms.contains(.house) })
        // Classic House is the one whose home is house; Four on the Floor's is disco.
        #expect(suggestions[0].name == "Classic House",
                "best for 128 BPM house was \(suggestions[0].name)")
        #expect(suggestions[0].tempoRange.contains(128))
        #expect(suggestions.contains { $0.name == "Four on the Floor" })
        #expect(suggestions.contains { $0.name == "Lo-Fi House" })
    }

    @Test("a tempo alone still ranks sensibly")
    func suggestsOnTempoAlone() {
        let slow = Self.library.suggest(for: 72, limit: 5)
        #expect(slow.allSatisfy { $0.tempoRange.contains(72) })
        let fast = Self.library.suggest(for: 150, limit: 3)
        #expect(fast.contains { $0.name == "Breakbeat (Amen)" || $0.name == "Trap Rolling Hats" })
    }

    @Test("an idiom nothing carries falls back rather than returning nothing")
    func unknownIdiomFallsBack() {
        let suggestions = Self.library.suggest(for: 120, idiom: Idiom("klezmer"), limit: 3)
        #expect(suggestions.count == 3, "an unknown idiom should rank on tempo, not empty out")
        #expect(suggestions.allSatisfy { $0.tempoRange.contains(120) })
    }

    @Test("a meter is a hard filter when anything matches it")
    func meterFilters() {
        let suggestions = Self.library.suggest(for: FeelLibrary.Request(tempo: 110, timeSignature: .threeFour, limit: 4))
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.timeSignature == .threeFour })
    }

    @Test("suggestion is stable")
    func suggestionIsStable() {
        let request = FeelLibrary.Request(tempo: 92, idiom: .lofi, limit: 5)
        let first = Self.library.suggest(for: request).map(\.name)
        for _ in 0..<5 {
            #expect(Self.library.suggest(for: request).map(\.name) == first)
        }
    }

    // MARK: Editing

    @Test("a library can be extended and a feel replaced by name")
    func editing() {
        let bent = Self.library["Lo-Fi Hip-Hop"]!.swung(percent: 66)
        let extended = Self.library.adding(bent)
        #expect(extended.count == Self.library.count)
        #expect(abs(extended["Lo-Fi Hip-Hop"]!.swing.percent - 66) < 1e-9)

        let renamed = Self.library.adding(bent.renamed("Lo-Fi Hip-Hop (Triplet)"))
        #expect(renamed.count == Self.library.count + 1)
        #expect(renamed.validate().isEmpty)

        let shrunk = renamed.removing(named: "Lo-Fi Hip-Hop (Triplet)")
        #expect(shrunk.count == Self.library.count)
    }

    // MARK: The corrections the port had to make

    @Test("Shuffle is 4/4 in triplet eighths, not 3/4")
    func shuffleMeterIsCorrected() {
        let shuffle = Self.library["Shuffle"]!
        #expect(shuffle.timeSignature == .fourFour)
        #expect(shuffle.groove.stepsPerBar == 12, "twelve triplet eighths to a 4/4 bar")
        #expect(shuffle.stepsPerBeat == 3)
        // Its own backbeat proves it: snare on steps 3 and 9, i.e. beats 2 and 4.
        let snare = shuffle.groove.patterns.first { $0.voice == .snare }!
        #expect(snare.steps[3] != .rest && snare.steps[9] != .rest)
    }

    @Test("the trap feel is the one on a thirty-second grid")
    func trapResolution() {
        let trap = Self.library["Trap Rolling Hats"]!
        #expect(trap.groove.stepsPerBar == 32)
        #expect(trap.stepsPerBeat == 8)
        // Half-time: the snare is on beat 3 of each bar and nowhere else.
        let snare = trap.groove.patterns.first { $0.voice == .snare }!
        let sounding = snare.steps.enumerated().filter { $0.element != .rest }.map(\.offset)
        #expect(sounding == [16, 48])
    }

    @Test("the researched feels carry a pocket, the ported templates do not")
    func pocketsBelongToResearchedFeels() {
        for feel in Self.library.feels where feel.provenance.origin == .grooveTheory {
            #expect(feel.groove.swing == 0, "\(feel.name) is a template and should be straight")
            #expect(feel.voices.isEmpty, "\(feel.name) is a template and should have no pocket")
        }
        let lofi = Self.library["Lo-Fi Hip-Hop"]!
        #expect(abs(lofi.swing.percent - 60) < 1e-9)
        #expect(lofi.voices[.closedHat]?.swing == .straight, "the hats stay straight")
        #expect((lofi.voices[.snare]?.timingOffset ?? 0) > 0, "the snare leans back")
        #expect(lofi.humanize.isActive)
    }
}
