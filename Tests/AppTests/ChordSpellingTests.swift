import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A chord's name on the Chords sheet's bars and on the Piano roll's band is spelled as the key
// spells its root. Both used to ask the key only whether it prefers sharps or flats, and a
// preference never reaches a C♭: Malecón's VImaj7, Cbmaj7 in the line it kept and in the part's
// name, read "Bmaj7" on both.

@Suite("Chord names spelled in the key: the Chords sheet's bars and the Piano roll's band") @MainActor
struct ChordSpellingTests {

    static let eFlatMinor = Key(tonic: .eFlat, mode: .aeolian)
    static let eMajor = Key(tonic: NoteName(.e))
    /// Malecón's loop, as the reharmonizing wrote it.
    static let malecon = "Ebm9 | Ab7 | Cbmaj7 | Bb7"

    private func names(on model: ChordsModel) throws -> [String] {
        try #require(model.progression).chords.map { model.symbol(of: $0) }
    }

    /// The band's names, laid over the line as the band lays them.
    private func band(of model: PianoRollModel) -> [String] {
        HarmonyMap(chords: model.chords, totalBeats: model.totalBeats).spans.map { model.symbol(of: $0.chord) }
    }

    @Test("in E flat minor the bars read C♭maj7 over VImaj7, as the line kept and the part's name do")
    func sheetInEFlatMinor() throws {
        let model = ChordsModel(host: ChordsStub(), key: Self.eFlatMinor)
        model.text = Self.malecon
        #expect(try names(on: model) == ["Ebm9", "Ab7", "Cbmaj7", "Bb7"])
        let chords = try #require(model.progression).chords
        #expect(chords.map { model.numeral(of: $0) } == ["i9", "IV7", "VImaj7", "V7"])

        let kept = try #require(model.commit())
        #expect(PartLabel.title(of: kept).hasPrefix(Self.malecon), "\(PartLabel.title(of: kept))")
        // Opened on the part from a song read in another key, the bars are in the part's own.
        let reopened = ChordsModel(host: ChordsStub(), key: .cMajor, progression: kept)
        #expect(reopened.key == Self.eFlatMinor)
        #expect(reopened.text == Self.malecon)
        #expect(try names(on: reopened) == ["Ebm9", "Ab7", "Cbmaj7", "Bb7"])
    }

    @Test("a sharp key keeps its sharps, and the bass of an inversion is the chord tone it is")
    func sheetInASharpKey() throws {
        let model = ChordsModel(host: ChordsStub(), key: Self.eMajor)
        model.text = "Emaj7 | C#m7 | F# | B7/D#"
        #expect(try names(on: model) == ["Emaj7", "C#m7", "F#", "B7/D#"])
        // One chord in two keys: on B in E major, on C♭ in E flat minor, its bass following its root.
        model.text = "Bmaj7/D#"
        #expect(try names(on: model) == ["Bmaj7/D#"])
        model.setKey(Self.eFlatMinor)
        #expect(try names(on: model) == ["Cbmaj7/Eb"])
    }

    @Test("a chord off the key is named as it was: a natural as a natural, a black key by the key's preference")
    func sheetOffTheKey() throws {
        let model = ChordsModel(host: ChordsStub(), key: Self.eFlatMinor)
        model.text = "Ebm | D7 | E/G# | Bb7"
        #expect(try names(on: model) == ["Ebm", "D7", "E/G#", "Bb7"])
        model.setKey(Self.eMajor)
        model.text = "E | A#dim7 | B7 | E"
        #expect(try names(on: model) == ["E", "A#dim7", "B7", "E"])
        model.setKey(Key(tonic: NoteName(.f)))
        model.text = "F | Dbmaj7 | C7 | F"
        #expect(try names(on: model) == ["F", "Dbmaj7", "C7", "F"])
    }

    @Test("the Piano roll's band names the song's chords as its key spells them, and follows a new key")
    func rollBand() throws {
        let line = try Progression.parse(Self.malecon, key: Self.eFlatMinor).get()
        let model = PianoRollModel(host: RollStub(), groove: PianoRollTests.kicking().tiled(toBars: 4),
                                   chords: line.spans, key: Self.eFlatMinor, tempo: 125)
        #expect(model.bars == 4)
        #expect(band(of: model) == ["Ebm9", "Ab7", "Cbmaj7", "Bb7"])

        let sharp = try Progression.parse("Emaj7 | C#m7 | F# | B7", key: Self.eMajor).get()
        model.follow(groove: model.groove, grooveVersion: model.grooveVersion, chords: sharp.spans, key: Self.eMajor,
                     tempo: model.tempo, timeSignature: model.timeSignature, kickDecaySeconds: model.kickDecaySeconds)
        #expect(band(of: model) == ["Emaj7", "C#m7", "F#", "B7"])
    }
}
