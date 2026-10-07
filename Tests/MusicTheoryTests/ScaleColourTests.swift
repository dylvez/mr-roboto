import Foundation
import Testing
@testable import MusicTheory

/// The scales the church modes do not have, as keys: harmonic minor, Phrygian dominant and the
/// rest, written in their mode's signature with a degree or two raised.
@Suite("Scale colours")
struct ScaleColourTests {

    @Test("Each colour is its mode with the right degrees raised")
    func intervals() {
        #expect(ScaleColour.harmonicMinor.intervals == [0, 2, 3, 5, 7, 8, 11])
        #expect(ScaleColour.melodicMinor.intervals == [0, 2, 3, 5, 7, 9, 11])
        #expect(ScaleColour.phrygianDominant.intervals == [0, 1, 4, 5, 7, 8, 10])
        #expect(ScaleColour.doubleHarmonic.intervals == [0, 1, 4, 5, 7, 8, 11])
        #expect(ScaleColour.hungarianMinor.intervals == [0, 2, 3, 6, 7, 8, 11])
        #expect(ScaleColour.ukrainianDorian.intervals == [0, 2, 3, 6, 7, 9, 10])
    }

    @Test("A coloured key is spelled on consecutive letters, in its mode's signature")
    func spelling() throws {
        let freygish = try #require(Key(parsing: "E phrygian dominant"))
        #expect(freygish.mode == .phrygian && freygish.colour == .phrygianDominant)
        #expect(freygish.spelledScale.map(\.description) == ["E", "F", "G#", "A", "B", "C", "D"])
        #expect(freygish.signature.fifths == 0, "written in E Phrygian's signature, the G♯ an accidental")
        #expect(freygish.name == "E phrygian dominant")
        let harmonic = try #require(Key(parsing: "D harmonic minor"))
        #expect(harmonic.spelledScale.map(\.description) == ["D", "E", "F", "G", "A", "Bb", "C#"])
        #expect(harmonic.isMinor && !harmonic.isMajor)
    }

    @Test("A colour answers to the names the musics give it")
    func aliases() {
        #expect(Key(parsing: "A freygish")?.colour == .phrygianDominant)
        #expect(Key(parsing: "D hijaz")?.colour == .phrygianDominant)
        #expect(Key(parsing: "G misheberakh")?.colour == .ukrainianDorian)
        #expect(Key(parsing: "C Double Harmonic")?.colour == .doubleHarmonic)
        #expect(Key(parsing: "A gypsy minor")?.colour == .hungarianMinor)
        #expect(Key(parsing: "D minor")?.colour == nil)
        #expect(Key(parsing: "D dorian")?.colour == nil)
    }

    @Test("The chords a coloured key owns are its scale's: harmonic minor has a major V")
    func chords() throws {
        let key = try #require(Key(parsing: "A harmonic minor"))
        let triads = key.diatonicTriads
        #expect(triads[4] == Chord(root: .e, quality: .major), "\(triads[4])")
        #expect(key.pitchClasses.contains(.gSharp) && !key.pitchClasses.contains(.g))
        let freygish = try #require(Key(parsing: "E phrygian dominant"))
        #expect(freygish.diatonicTriads[0] == Chord(root: .e, quality: .major), "the tonic chord is major")
        #expect(freygish.diatonicTriads[1] == Chord(root: .f, quality: .major))
    }

    @Test("A key with no colour is written as it always was; one with a colour keeps it through a document")
    func coding() throws {
        let plain = try JSONEncoder().encode(Key.aMinor)
        #expect(!String(decoding: plain, as: UTF8.self).contains("colour"))
        let old = Data(#"{"tonic":{"letter":"a","accidental":0},"mode":6}"#.utf8)
        if let decoded = try? JSONDecoder().decode(Key.self, from: old) { #expect(decoded.colour == nil) }
        let coloured = try #require(Key(parsing: "E phrygian dominant"))
        let back = try JSONDecoder().decode(Key.self, from: JSONEncoder().encode(coloured))
        #expect(back == coloured && back.colour == .phrygianDominant)
    }

    @Test("A coloured key moved keeps its colour")
    func transposing() throws {
        let freygish = try #require(Key(parsing: "E phrygian dominant"))
        let up = freygish.transposed(by: 2)
        #expect(up.colour == .phrygianDominant && up.tonic.pitchClass == .fSharp && up.mode == .phrygian)
        #expect(Key.aMinor.transposed(by: 3) == Key(parsing: "C minor"))
    }
}
