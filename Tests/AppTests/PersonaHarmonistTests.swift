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
