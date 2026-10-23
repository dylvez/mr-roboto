import MusicTheory
import Testing
@testable import Performance

/// One key a chord: the chord a root plays in a key, and what the buttons held build on it.
@Suite("Chord keys: a root and the buttons held")
struct ChordKeysTests {

    private func symbols(in key: String, holding buttons: Set<ChordButton> = []) -> [String] {
        let key = Key(parsing: key)!
        return PitchClass.allCases.map { ChordKeys.chord(root: $0, in: key, holding: buttons).chord.symbol(in: key) }
    }

    @Test("with nothing held a key in the scale plays the key's own triad, and one outside it the triad with most of the key in it")
    func inTheKey() {
        #expect(symbols(in: "C major") == ["C", "C#dim", "Dm", "D#dim", "Em", "F", "F#dim", "G", "G#dim", "Am", "Bb", "Bdim"])
        #expect(symbols(in: "C minor") == ["Cm", "Db", "Ddim", "Eb", "Edim", "Fm", "F#dim", "Gm", "Ab", "Adim", "Bb", "Bdim"])
        // A mode is its own scale: D dorian's IV is major, and its vi° is the B.
        let dorian = symbols(in: "D dorian")
        #expect(dorian[2] == "Dm" && dorian[7] == "G" && dorian[11] == "Bdim")
    }

    @Test("a kind held is the kind, whatever the key would have played; two held, the first of dim, sus, min, maj wins")
    func kinds() {
        let key = Key(parsing: "C major")!
        #expect(ChordKeys.chord(root: .d, in: key, holding: [.major]).chord == Chord(.d, .major))
        #expect(ChordKeys.chord(root: .c, in: key, holding: [.minor]).chord == Chord(.c, .minor))
        #expect(ChordKeys.chord(root: .g, in: key, holding: [.suspended]).chord == Chord(.g, .suspendedFourth))
        #expect(ChordKeys.chord(root: .e, in: key, holding: [.diminished]).chord == Chord(.e, .diminished))
        let both = ChordKeys.chord(root: .a, in: key, holding: [.major, .minor])
        #expect(both.chord == Chord(.a, .minor) && both.unused == [.major])
    }

    @Test("the added notes go on the kind: the seventh makes a 7 on a major chord and an m7 on a minor one")
    func additions() {
        let key = Key(parsing: "C major")!
        func play(_ root: PitchClass, _ buttons: Set<ChordButton>) -> String {
            ChordKeys.chord(root: root, in: key, holding: buttons).chord.symbol(in: key)
        }
        #expect(play(.d, [.seventh]) == "Dm7")
        #expect(play(.g, [.seventh]) == "G7")
        #expect(play(.c, [.majorSeventh]) == "Cmaj7")
        #expect(play(.b, [.seventh]) == "Bm7b5")
        #expect(play(.c, [.seventh]) == "C7", "the five of F, from the tonic's key with one button")
        #expect(play(.d, [.seventh, .ninth]) == "Dm9")
        #expect(play(.g, [.seventh, .ninth]) == "G9")
        #expect(play(.f, [.majorSeventh, .ninth]) == "Fmaj9")
        #expect(play(.c, [.ninth]) == "Cadd9")
        #expect(play(.a, [.ninth]) == "Amadd9")
        #expect(play(.c, [.sixth]) == "C6")
        #expect(play(.c, [.sixth, .ninth]) == "C6/9")
        #expect(play(.a, [.minor, .majorSeventh]) == "AmMaj7")
        #expect(play(.g, [.suspended, .seventh]) == "G7sus4")
        #expect(play(.g, [.suspended, .seventh, .ninth]) == "G9sus4")
        #expect(play(.d, [.suspended, .ninth]) == "Dsus2", "a ninth on a sus with no seventh is the second in place of the fourth")
        #expect(play(.c, [.diminished, .sixth]) == "Cdim7", "the sixth of a diminished chord is its diminished seventh")
    }

    @Test("what does not make a chord is let go, the sixth first, and said: a major seventh will not go on a diminished chord")
    func unused() {
        let key = Key(parsing: "C major")!
        let dimMaj7 = ChordKeys.chord(root: .b, in: key, holding: [.majorSeventh])
        #expect(dimMaj7.chord == Chord(.b, .diminished) && dimMaj7.unused == [.majorSeventh])
        let sixOnSeven = ChordKeys.chord(root: .g, in: key, holding: [.seventh, .sixth])
        #expect(sixOnSeven.chord == Chord(.g, .dominantSeventh) && sixOnSeven.unused == [.sixth])
        let bothSevenths = ChordKeys.chord(root: .c, in: key, holding: [.seventh, .majorSeventh])
        #expect(bothSevenths.chord == Chord(.c, .dominantSeventh) && bothSevenths.unused == [.majorSeventh])
    }

    @Test("below middle C a controller's key holds the button it spells: E♭ minor, E major, F sus, G♭ dim, A 6, B♭ 7, B maj7, D 9")
    func controllerButtons() {
        #expect(ChordKeys.button(forNote: 51) == .minor)
        #expect(ChordKeys.button(forNote: 52) == .major)
        #expect(ChordKeys.button(forNote: 53) == .suspended)
        #expect(ChordKeys.button(forNote: 54) == .diminished)
        #expect(ChordKeys.button(forNote: 57) == .sixth)
        #expect(ChordKeys.button(forNote: 58) == .seventh)
        #expect(ChordKeys.button(forNote: 59) == .majorSeventh)
        #expect(ChordKeys.button(forNote: 50) == .ninth)
        #expect(ChordKeys.button(forNote: 39) == .minor, "any octave below the split")
        #expect([48, 49, 55, 56].allSatisfy { ChordKeys.button(forNote: $0) == nil }, "C, C♯, G and G♯ hold nothing")
        #expect(ChordKeys.button(forNote: 63) == nil, "from middle C up a key is a root")
        #expect(Set(ChordButton.allCases.map { $0.semitones % 12 }).count == 8, "eight buttons, eight notes")
    }
}
