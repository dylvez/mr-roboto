import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The Bassist bible's golden tests, run against what the writer actually writes and measured by
// the observation — never asserted by hand. G1, G2, G3 and G4 run in full; G5 runs the half the
// engine can express (the alternating early pattern) and says which half it cannot.

private enum BassFixture {
    static func groove(bars: Int = 4, kickAndOfTwo: Bool = true) -> Groove {
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            let one = pattern.map { c -> VelocityTier in c == "x" ? .normal : (c == "." ? .ghost : .rest) }
            return GroovePattern(voice: voice, steps: Array(repeating: one, count: bars).flatMap { $0 })
        }
        return Groove(stepsPerBar: 16, bars: bars, swing: 0, patterns: [
            line(.kick, kickAndOfTwo ? "x-----x---------" : "x-------x-------"),
            line(.snare, "----x-------x---"),
            line(.closedHat, "x-x-x-x-x-x-x-x-"),
        ])
    }

    static let dm7g7: [ChordSpan] = [ChordSpan(Chord(.d, .minorSeventh), beats: 4),
                                     ChordSpan(Chord(.g, .dominantSeventh), beats: 4)]

    /// "Them Changes": C♭maj7 (= Bmaj7) Gm7 A♭m7 Fm7, a bar each. G→A♭ is a half-step, B→G a third.
    static let themChanges: [ChordSpan] = [ChordSpan(Chord(.b, .majorSeventh), beats: 4),
                                           ChordSpan(Chord(.g, .minorSeventh), beats: 4),
                                           ChordSpan(Chord(.gSharp, .minorSeventh), beats: 4),
                                           ChordSpan(Chord(.f, .minorSeventh), beats: 4)]

    static func observe(_ line: Bassline, groove: Groove, chords: [ChordSpan], tempo: Double,
                        options: GrooveRenderOptions = GrooveRenderOptions(), kickDecay: Double = 0) -> BassObservation {
        BassObservation(label: "test", bassline: line, groove: groove, chords: chords, tempo: tempo,
                        options: options, kickDecaySeconds: kickDecay)
    }
}

@Suite("Bassist: golden tests") @MainActor
struct BassistGoldenTests {

    @Test("G1 Voodoo lag: 92 bpm, hats straight, Dm7 to G7")
    func g1() {
        let groove = BassFixture.groove()
        let request = BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: BassFixture.dm7g7,
                                  groove: groove, tempo: 92, lineage: .palladino, density: 0.5, seed: 11)
        let line = BassWriter.write(request)
        let o = BassFixture.observe(line, groove: groove, chords: BassFixture.dm7g7, tempo: 92)

        #expect((30...65).contains(o.medianKickOffsetMS), "median offset \(o.medianKickOffsetMS)")
        #expect(abs(o.maxKickOffsetMS) <= 90, "worst offset \(o.maxKickOffsetMS)")
        #expect(o.noteOffOnBeatRate >= 0.8, "note-offs on the beat: \(o.noteOffOnBeatRate)")
        #expect(o.restRatio >= 0.3, "rest \(o.restRatio)")
        #expect(o.registerHigh <= 50, "nothing above D3; highest \(o.registerHigh)")
        #expect(o.chromaticApproachRate >= 0.5, "slides into G: \(o.chromaticApproachRate)")
        #expect(o.downbeatCoverage == 1)

        let readings = Bassist().read(o)
        for rule in ["bassist.lag-budget", "bassist.lag-ceiling", "bassist.note-off", "bassist.density",
                     "bassist.chromatic-approach", "bassist.downbeat", "bassist.straight-reference"] {
            let reading = readings.first { $0.rule == rule }
            #expect(reading?.holds == true, "\(rule): \(reading?.says ?? "no reading")")
        }
    }

    @Test("G2 a lagging drummer: no line is written, the reason names the hats")
    func g2() {
        let bassist = Bassist()
        let verdict = bassist.consider(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 92,
                                                      hatLagMS: 50, kickLagMS: 50, kickDecaySeconds: 0.15, sound: "finger"))
        #expect(verdict.refusedByRule == "bassist.straight-reference")
        #expect(verdict.spoken.contains("Nothing is straight"))
        #expect(verdict.spoken.contains("play straight so I can lag"))

        // And the same line, read after the fact under a groove whose hats have moved, is flagged.
        let groove = BassFixture.groove()
        var options = GrooveRenderOptions()
        options.voices[.closedHat] = VoiceFeel(timingOffset: 0.3)   // 50 ms at 92 bpm on sixteenths
        options.voices[.kick] = VoiceFeel(timingOffset: 0.3)
        let line = BassWriter.write(BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: BassFixture.dm7g7,
                                                groove: groove, tempo: 92))
        let o = BassFixture.observe(line, groove: groove, chords: BassFixture.dm7g7, tempo: 92, options: options)
        let straight = bassist.read(o).first { $0.rule == "bassist.straight-reference" }
        #expect(straight?.holds == false)
        #expect(straight?.says.contains("nothing is straight") == true)

        // With the hats straight and only the snare moved — the technique — it is happy.
        let hatsStraight = bassist.consider(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 92,
                                                           hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.15, sound: "finger"))
        #expect(hatsStraight.isAgreement)
    }

    @Test("G3 808 ownership: a played bass under a 700 ms kick is refused; the sub copies the kick")
    func g3() {
        let bassist = Bassist()
        let refused = bassist.consider(.writeBassline(lineage: "palladino", lagMS: 0, tempo: 140,
                                                      hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.7, sound: "finger"))
        #expect(refused.refusedByRule == "bassist.808-is-the-bass")
        #expect(refused.spoken.contains("cut, don't stack") || refused.spoken.contains("Cut, don't stack"))
        #expect(bassist.consider(.sustainUnder808(sound: "finger", kickDecaySeconds: 0.7)).isRefusal)
        #expect(bassist.consider(.sustainUnder808(sound: "finger", kickDecaySeconds: 0.15)).isAgreement)

        // The sub, as the 808 line: on the kick note for note, held.
        let groove = BassFixture.groove(bars: 2)
        let line = BassWriter.write(BassRequest(key: Key(tonic: NoteName(.f), mode: .aeolian), groove: groove,
                                                tempo: 140, lineage: .programmed))
        let o = BassFixture.observe(line, groove: groove, chords: [], tempo: 140, kickDecay: 0.7)
        #expect(o.isSub)
        #expect(o.kickOffsetsMS.allSatisfy { abs($0) < 1 }, "\(o.kickOffsetsMS)")
        #expect(o.medianLengthRatio >= 0.8)
        #expect(o.registerHigh <= 40, "sub register; highest \(o.registerHigh)")
        let readings = bassist.read(o)
        #expect(readings.first { $0.rule == "bassist.808-is-the-bass" && $0.feature == .kickDecaySeconds }?.holds == true)
        // The same groove and kick with a finger bass is the one it flags.
        let played = BassWriter.write(BassRequest(key: Key(tonic: NoteName(.f), mode: .aeolian), groove: groove,
                                                  tempo: 140, lineage: .palladino, lagMS: 0))
        let po = BassFixture.observe(played, groove: groove, chords: [], tempo: 140, kickDecay: 0.7)
        let flagged = bassist.read(po).first { $0.rule == "bassist.808-is-the-bass" && $0.feature == .kickDecaySeconds }
        #expect(flagged?.holds == false)
        #expect(flagged?.says.contains("second owner") == true)
    }

    @Test("G4 Thundercat harmony: voicings, a non-diatonic move, notes inside the chord, nothing below B0")
    func g4() {
        let groove = BassFixture.groove(bars: 4)
        let chords = BassFixture.themChanges
        let request = BassRequest(key: Key(tonic: NoteName(.e, .flat), mode: .aeolian), chords: chords, groove: groove,
                                  tempo: 84, lineage: .thundercat, density: 0.5, seed: 3)
        let line = BassWriter.write(request)
        let o = BassFixture.observe(line, groove: groove, chords: chords, tempo: 84)

        #expect(o.distinctVoicings >= 3, "voicings \(o.distinctVoicings)")
        #expect(o.registerLow >= 35, "nothing below B0; lowest \(o.registerLow)")
        #expect(o.attacksPerBar <= 8, "verse attacks \(o.attacksPerBar)")

        // Every note that is not an approach is a chord tone of the chord it sounds under.
        let harmony = HarmonyMap(chords: chords, totalBeats: 16)
        let changes = Set(harmony.changes)
        var inside = 0, total = 0
        for note in line.notes {
            let isApproach = changes.contains(note.start + 0.5) || abs(note.start - 15.5) < 1e-6
            if isApproach { continue }
            total += 1
            if harmony.chord(at: note.start).pitchClassSet.contains(note.pitch.pitchClass) { inside += 1 }
        }
        #expect(Double(inside) / Double(max(1, total)) >= 0.9, "\(inside) of \(total) inside the chord")

        // A non-diatonic root move: G is not in E♭ minor, and B → G is a third.
        let key = Key(tonic: NoteName(.e, .flat), mode: .aeolian)
        let nonDiatonic = chords.contains { !key.pitchClasses.contains($0.chord.root) }
        #expect(nonDiatonic)
        #expect(o.chromaticApproachRate >= 0.5, "approaches \(o.chromaticApproachRate) over \(o.largeRootMoves) moves")
    }

    @Test("G5 Dilla tolerance: the alternating early pattern is written and read as the one early pattern allowed")
    func g5() {
        // One chord, so no approach note breaks the alternation.
        let groove = BassFixture.groove(bars: 4)
        let chords = [ChordSpan(Chord(.d, .minorSeventh), beats: 16)]
        let line = BassWriter.write(BassRequest(key: Key(tonic: NoteName(.d), mode: .aeolian), chords: chords, groove: groove,
                                                tempo: 95, lineage: .palladino, lagMS: 30, density: 0.4,
                                                earlyAlternation: true, seed: 5))
        let o = BassFixture.observe(line, groove: groove, chords: chords, tempo: 95)
        #expect(o.earlyAlternation, "offsets \(o.kickOffsetsMS)")
        #expect(o.kickOffsetsMS.filter { $0 < 0 }.allSatisfy { $0 >= -25.01 })
        // Total displacement under a thirty-second: at 95 bpm that is 79 ms.
        #expect(o.kickOffsetsMS.allSatisfy { abs($0) < 79 })
        let reading = Bassist().read(o).first { $0.rule == "bassist.direction" }
        #expect(reading?.holds == true)
        #expect(reading?.feature == .bassEarlyAlternation)
        // The retune half of G5 is the Sampler's chop, not a bass line; the octave double is an
        // open question the bible names.
        #expect(Bassist.bible.openQuestions.contains { $0.id == "bassist.oq.octave-double" })
    }
}

@Suite("Bassist: the rest of the verdicts") @MainActor
struct BassistVerdictTests {

    @Test("ahead of the kick uniformly is refused; alternating under 25 ms is the one early pattern")
    func direction() {
        let b = Bassist()
        #expect(b.consider(.pushBassAhead(milliseconds: 30, alternating: false)).refusedByRule == "bassist.direction")
        #expect(b.consider(.pushBassAhead(milliseconds: 20, alternating: true)).isAgreement)
        #expect(b.consider(.pushBassAhead(milliseconds: 40, alternating: true)).isRefusal)
        #expect(b.consider(.writeBassline(lineage: "palladino", lagMS: -30, tempo: 92, hatLagMS: 0, kickLagMS: 0,
                                          kickDecaySeconds: 0.1, sound: "finger")).refusedByRule == "bassist.direction")
    }

    @Test("past 90 ms is refused with the ceiling; past 65 is a caveat; house tempos cap at 25")
    func ceilings() {
        let b = Bassist()
        #expect(b.consider(.writeBassline(lineage: "palladino", lagMS: 120, tempo: 92, hatLagMS: 0, kickLagMS: 0,
                                          kickDecaySeconds: 0.1, sound: "finger")).refusedByRule == "bassist.lag-ceiling")
        if case .agreeWithCaveat = b.consider(.writeBassline(lineage: "palladino", lagMS: 75, tempo: 92, hatLagMS: 0,
                                                             kickLagMS: 0, kickDecaySeconds: 0.1, sound: "finger")) {
        } else { Issue.record("75 ms should be a caveat, not a refusal") }
        if case .agreeWithCaveat(_, let caveat) = b.consider(.writeBassline(lineage: "palladino", lagMS: 40, tempo: 124, hatLagMS: 0,
                                                                            kickLagMS: 0, kickDecaySeconds: 0.1, sound: "finger")) {
            #expect(caveat.contains("25"))
        } else { Issue.record("a house tempo should cap the lag with a caveat") }
    }

    @Test("what is not the bass's is deferred to whoever owns it")
    func defers() {
        let b = Bassist()
        if case .defer_(let to, _) = b.consider(.setSwing(percent: 58, idiom: "boom bap", tempo: 90)) {
            #expect(to == .beatmaker)
        } else { Issue.record("swing should be deferred to the Beatmaker") }
        if case .defer_(let to, _) = b.consider(.applyDegrade(preset: "sp1200", sourceBandwidthHz: 12000, sourceNoiseFloorDB: -60)) {
            #expect(to == .sampler)
        } else { Issue.record("dust should be deferred to the Sampler") }
        // And the others defer the bass back.
        if case .defer_(let to, _) = Beatmaker().consider(.pushBassAhead(milliseconds: 20, alternating: true)) {
            #expect(to == .bassist)
        } else { Issue.record("the Beatmaker should defer bass placement") }
    }

    @Test("the cast holds the Bassist, and every golden names rules the bible has")
    func castAndGoldens() {
        #expect(Cast.standard.persona(.bassist) != nil)
        let rules = Set(Bassist.bible.rules.map(\.id))
        for golden in Bassist.bible.goldens {
            for rule in golden.exercises { #expect(rules.contains(rule), "\(golden.id) exercises \(rule), which is not a rule") }
        }
    }
}
