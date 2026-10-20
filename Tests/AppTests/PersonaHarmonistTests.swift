import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The Harmonist: the chords as arithmetic, and the one number that is wrong said out loud.

@Suite("Harmonist: the chords, read")
struct PersonaHarmonistTests {
    private let d = Key(tonic: NoteName(.d))

    private func progression(_ chords: [Chord], beats: Double = 4, key: Key? = nil) -> Progression {
        Progression(key: key ?? d, bars: chords.map { ProgressionBar(chords: [ChordSpan($0, beats: beats)]) })
    }
    private func chord(_ letter: Letter, _ quality: ChordQuality = .major, _ accidental: Accidental = .natural) -> Chord {
        Chord(root: NoteName(letter, accidental).pitchClass, quality: quality)
    }

    /// I–vi–IV–V in D: the progression every rule here was written against.
    private var oneSixFourFive: Progression {
        progression([chord(.d), chord(.b, .minor), chord(.g), chord(.a)])
    }

    @Test("voice leading is the distance the voices travel, and sharing notes makes it small")
    func voiceLeading() {
        let close = HarmonyObservation.of(oneSixFourFive, label: "I–vi–IV–V")
        #expect(close.voiceLeadingSemitones < Harmonist.voiceLeadingCeiling, "\(close.voiceLeadingSemitones)")
        // A major to G major is the far end of the scale: every voice has to move.
        let far = HarmonyObservation.of(progression([chord(.a), chord(.g)]), label: "far")
        #expect(far.voiceLeadingSemitones > close.voiceLeadingSemitones)
        #expect(far.voiceLeadingSemitones > Harmonist.voiceLeadingCeiling, "\(far.voiceLeadingSemitones)")
        // D major to Ab major looks distant and is not: two voices move a semitone, which is what
        // the measure is for and what the bible's open question says it may flatter.
        #expect(HarmonyObservation.of(progression([chord(.d), chord(.a, .major, .flat)]), label: "chromatic")
            .voiceLeadingSemitones < far.voiceLeadingSemitones)
        // A chord to itself moves nothing.
        #expect(HarmonyObservation.of(progression([chord(.d), chord(.d)]), label: "same").voiceLeadingSemitones == 0)
    }

    @Test("the key, the changes, the roots and the landing, counted")
    func theNumbers() {
        let observation = HarmonyObservation.of(oneSixFourFive, label: "I–vi–IV–V")
        #expect(observation.distinctChords == 4 && observation.changesPerBar == 1)
        #expect(observation.diatonicRatio == 1 && observation.borrowed.isEmpty)
        #expect(observation.numerals == ["I", "vi", "IV", "V"], "\(observation.numerals)")
        // vi→IV is a step, IV→V is a step, I→vi is a third: only D→B is not a fourth or fifth.
        #expect(observation.rootMotionFifths >= 0 && observation.rootMotionFifths <= 1)
        // The phrase ends on V, which is a fourth below the tonic it points at: it does not land.
        #expect(observation.cadenceRatio < Harmonist.cadenceFloor)
        // Ending on the tonic lands.
        let lands = HarmonyObservation.of(progression([chord(.g), chord(.a), chord(.d)]), label: "IV–V–I")
        #expect(lands.cadenceRatio == 1 && lands.rootMotionFifths >= 0.5)
    }

    @Test("a chord the key does not own is named, and half outside is a modulation nobody declared")
    func borrowed() {
        // F major in D major: bIII, borrowed.
        let one = HarmonyObservation.of(progression([chord(.d), chord(.f), chord(.g), chord(.a)]), label: "borrowed")
        #expect(one.diatonicRatio == 0.75 && one.borrowed.count == 1)
        #expect(one.diatonicRatio >= Harmonist.diatonicFloor)
        let many = HarmonyObservation.of(progression([chord(.d), chord(.f), chord(.a, .major, .flat), chord(.e, .major, .flat)]), label: "gone")
        #expect(many.diatonicRatio < Harmonist.diatonicFloor, "\(many.diatonicRatio)")
        // Named as the key spells them: B flat seven in F, not A sharp seven.
        let f = Key(tonic: NoteName(.f))
        let blues = progression([chord(.f, .dominantSeventh), chord(.b, .dominantSeventh, .flat)], key: f)
        let says = Harmonist().read(HarmonyObservation.of(blues, label: "blues")).first { $0.rule == "harmonist.stays-in-key" }?.says ?? ""
        #expect(says.contains("Bb7") && !says.contains("A#"), "\(says)")
    }

    @Test("a loop's five goes home on the repeat, and a section ending on the five hands over to the next")
    func loopsAndHandOvers() {
        // Máquina's loop: Em | Em | G7 | C B7, round twice in an eight-bar verse.
        let e = Key(tonic: NoteName(.e), mode: .aeolian)
        let bars = [chord(.e, .minor), chord(.e, .minor), chord(.g, .dominantSeventh)].map { ProgressionBar(chords: [ChordSpan($0, beats: 4)]) }
            + [ProgressionBar(chords: [ChordSpan(chord(.c), beats: 2), ChordSpan(chord(.b, .dominantSeventh), beats: 2)])]
        var verse = HarmonyObservation.of(Progression(key: e, bars: bars), label: "loop")
        #expect(verse.cadenceRatio < Harmonist.cadenceFloor, "read alone, the loop stops on V7")
        let before = verse.rootMotionFifths
        verse.loops = true
        #expect(verse.cadenceRatio == 1, "B7 → Em on the repeat lands")
        #expect(verse.rootMotionFifths > before, "the seam's B → E is a fifth heard every time round")
        #expect(Harmonist().read(verse).first { $0.rule == "harmonist.phrases-land" }?.holds == true)
        // A loop that does not go home on its seam still does not land.
        var away = HarmonyObservation.of(progression([chord(.d), chord(.g), chord(.a), chord(.b, .minor)]), label: "away")
        away.loops = true
        #expect(away.cadenceRatio < Harmonist.cadenceFloor)

        // A turn of two bars, the four to A7 by step, into the next section.
        var turn = HarmonyObservation.of(progression([chord(.g), chord(.a, .dominantSeventh)]), label: "turn")
        #expect(turn.cadenceRatio < Harmonist.cadenceFloor)
        turn.leadsOn = true
        #expect(turn.cadenceRatio == 1, "a half cadence where the next section takes over")
        // Ending on anything but the five is no hand-over: the turn to the four does not land.
        var four = HarmonyObservation.of(progression([chord(.d), chord(.e, .minor)]), label: "four")
        four.leadsOn = true
        #expect(four.cadenceRatio < Harmonist.cadenceFloor)
    }

    @Test("a minor key's major five is its own dominant, not a borrowing")
    func theFiveInMinor() {
        // Máquina's coro: Am | D | G | C | Am | D | B7 | Em. The B7's D sharp is the leading tone,
        // not a key change.
        let e = Key(tonic: NoteName(.e), mode: .aeolian)
        let loop = HarmonyObservation.of(progression([chord(.a, .minor), chord(.d), chord(.g), chord(.c), chord(.a, .minor), chord(.d),
                                                      chord(.b, .dominantSeventh), chord(.e, .minor)], key: e), label: "coro")
        #expect(loop.diatonicRatio == 1 && loop.borrowed.isEmpty, "\(loop.diatonicRatio)")
        #expect(!loop.departures.contains { $0.contains("outside the key") }, "\(loop.departures)")
        let says = Harmonist().read(loop).first { $0.rule == "harmonist.stays-in-key" }
        #expect(says?.holds == true && says?.says == "Every chord belongs to E minor.", "\(says?.says ?? "")")
        // The minor five is the scale's own anyway; the major four in minor is still borrowed.
        let four = HarmonyObservation.of(progression([chord(.e, .minor), chord(.a)], key: e), label: "four")
        #expect(four.borrowed.count == 1)
        // In a major key the five was always the key's.
        #expect(HarmonyObservation.of(oneSixFourFive, label: "I–vi–IV–V").isMinor == false)
    }

    @Test("the bass is judged at the change: a chord tone agrees, a second does not, and an inversion is fine")
    func bassAgreement() throws {
        let chords = oneSixFourFive
        // Roots under every chord: D, B, G, A. Every one agrees.
        let roots = Bassline(notes: [2, 11, 7, 9].enumerated().map { index, semitone in
            NoteEvent(pitch: Pitch(midi: 36 + semitone), start: Double(index) * 4, duration: 4)
        })
        let agreeing = HarmonyObservation.of(chords, label: "roots", bassline: roots)
        #expect(agreeing.bassChanges == 4 && agreeing.bassAgreement == 1 && agreeing.firstBassClash == nil)

        // An inversion under the IV: B is the third of G, so it still agrees.
        let inverted = Bassline(notes: [2, 11, 11, 9].enumerated().map { index, semitone in
            NoteEvent(pitch: Pitch(midi: 36 + semitone), start: Double(index) * 4, duration: 4)
        })
        #expect(HarmonyObservation.of(chords, label: "inverted", bassline: inverted).bassAgreement == 1, "a third underneath is a chord tone")

        // An F natural under the G major is not a note of it.
        let clashing = Bassline(notes: [2, 11, 5, 9].enumerated().map { index, semitone in
            NoteEvent(pitch: Pitch(midi: 36 + semitone), start: Double(index) * 4, duration: 4)
        })
        let clash = HarmonyObservation.of(chords, label: "clash", bassline: clashing)
        #expect(clash.bassAgreement == 0.75, "three of four, which is exactly the floor and holds")
        let named = try #require(clash.firstBassClash)
        #expect(named.bass.pitchClass.description.hasPrefix("F"), "\(named.bass.pitchClass)")

        // Two clashes in four is under the floor.
        let worse = Bassline(notes: [1, 11, 5, 9].enumerated().map { index, semitone in
            NoteEvent(pitch: Pitch(midi: 36 + semitone), start: Double(index) * 4, duration: 4)
        })
        #expect(HarmonyObservation.of(chords, label: "worse", bassline: worse).bassAgreement < Harmonist.bassAgreementFloor)
        // No bass line at all disagrees with nothing.
        #expect(HarmonyObservation.of(chords, label: "none").bassAgreement == 1)
    }

    @Test("the readings: numerals first, then the number that is wrong, in the Harmonist's own words")
    func readings() throws {
        let clashing = Bassline(notes: [1, 11, 5, 9].enumerated().map { index, semitone in
            NoteEvent(pitch: Pitch(midi: 36 + semitone), start: Double(index) * 4, duration: 4)
        })
        let readings = Harmonist().read(HarmonyObservation.of(oneSixFourFive, label: "Chords", bassline: clashing))
        let byRule = Dictionary(uniqueKeysWithValues: readings.map { ($0.rule, $0) })
        #expect(byRule["harmonist.enough-chords"]?.says.contains("I–vi–IV–V in D major") == true, "\(readings.map(\.says))")
        let bass = try #require(byRule["harmonist.bass-agrees"])
        #expect(!bass.holds && bass.says.contains("2 of 4 changes") && bass.says.contains("not a note of it"), "\(bass.says)")
        #expect(byRule["harmonist.voice-leading"]?.holds == true)
        #expect(byRule["harmonist.stays-in-key"]?.holds == true)
        #expect(readings.allSatisfy { $0.rule.hasPrefix("harmonist.") })
        // One chord is a pedal and says so, without pretending to read the rest.
        let drone = Harmonist().read(HarmonyObservation.of(progression([chord(.d)]), label: "One"))
        #expect(drone.count == 1 && !drone[0].holds && drone[0].says.contains("pedal"))
    }

    @Test("harmony is the Harmonist's: everyone else defers, and it defers on everyone else's")
    func ownership() {
        let progression = PersonaProposal.setProgression(distinctChords: 4, changesPerBar: 1, diatonicRatio: 1,
                                                         voiceLeadingSemitones: 0.7, rootMotionFifths: 0.5, cadenceRatio: 1)
        for persona in Cast.standard.personas where persona.bible.id != .harmonist {
            guard case .defer_(let to, _) = persona.consider(progression) else {
                Issue.record("\(persona.bible.id) did not defer on a progression")
                continue
            }
            #expect(to == .harmonist)
        }
        #expect(VerdictShape(Harmonist().consider(progression)) == .agree)
        // And the other way: the pocket is not the Harmonist's to rule on.
        guard case .defer_(let to, _) = Harmonist().consider(.setSwing(percent: 62, idiom: "boom-bap", tempo: 90)) else {
            Issue.record("the Harmonist ruled on the swing")
            return
        }
        #expect(to == .beatmaker)
    }
}
