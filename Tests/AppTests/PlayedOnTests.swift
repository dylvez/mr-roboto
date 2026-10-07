import Foundation
import Instrument
@testable import MrRobotoApp
import Performance
import SongGraph
import Testing

/// What the band is told about recordings, and the hand percussion the feels now play on.
@Suite("Played on recordings")
struct PlayedOnTests {

    static func recorded(_ name: String, family: String = "keys") -> InstrumentVoiceSpec {
        var spec = InstrumentVoiceSpec(id: "sfz-test-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", name: name,
                                       family: family, engine: .sampled)
        spec.sampledKit = "/nowhere/\(name)"
        return spec
    }

    @Test("read_genre says which recording plays each of the genre's sounds, and which are synthesized")
    func playedOn() {
        let library = [Self.recorded("Steinway Grand"), Self.recorded("Trumpet", family: "brass")]
        let said = ReadGenreTool.playedOn(["grand-piano", "trumpet", "organ", "pad"], among: library)
        #expect(said[0] == "grand-piano: Steinway Grand (sfz-test-steinway-grand), recorded")
        #expect(said[1] == "trumpet: Trumpet (sfz-test-trumpet), recorded")
        #expect(said[2] == "organ: Organ, synthesized")
        #expect(said[3] == "pad: Warm Pad, synthesized")
        let none = ReadGenreTool.playedOn(["grand-piano"], among: [])
        #expect(none == ["grand-piano: Grand Piano, synthesized, no recording in the library"])
    }

    @Test("set_instrument says when a synthesized preset has a recording in the library, and only then")
    func recordingNote() {
        let steinway = Self.recorded("Steinway Grand")
        ImportedInstruments.register(steinway)
        defer { ImportedInstruments.unregister(id: steinway.id) }
        let piano = SetInstrumentTool.recordingNote(for: .grandPiano)
        #expect(piano.contains("Steinway Grand (sfz-test-steinway-grand)"))
        #expect(SetInstrumentTool.recordingNote(for: steinway).isEmpty)
        #expect(SetInstrumentTool.recordingNote(for: .juno).isEmpty)
    }

    @Test("A short pattern suits a section, or an instrument with its short notes recorded")
    func shortPatterns() {
        var trumpet = Self.recorded("Trumpet", family: "brass")
        #expect(!KeysPattern.stabs.suits(trumpet))
        trumpet.shortKit = "/nowhere/Trumpet Staccato"
        #expect(KeysPattern.stabs.suits(trumpet))
        var section = InstrumentVoiceSpec(id: Ensemble.stringSection.id, name: "String Section", family: "strings", engine: .sampled)
        section.members = ["a", "b"]
        #expect(KeysPattern.offbeats.suits(section))
        #expect(Develop.chordsTreatment(for: .hook, playing: nil, lifted: .stabs, instrument: section) != nil)
        #expect(Develop.chordsTreatment(for: .hook, playing: nil, lifted: .stabs, instrument: .stringSection) == nil)
    }

    // MARK: Hand percussion

    @Test("Every hand-percussion voice travels on its own MIDI note, and comes back as itself")
    func drumMap() {
        // The toms are left out: the MIDI file has always written them on General MIDI's 45, 47
        // and 50, and the kits play them on 41, 45 and 48.
        for kind in SynthVoiceKind.handPercussion {
            #expect(DrumMap.note(for: kind.drumVoice) == kind.generalMIDINote, "\(kind)")
            #expect(DrumMap.voice(for: kind.generalMIDINote) == kind.drumVoice, "\(kind)")
        }
        let notes = SynthVoiceKind.allCases.map(\.generalMIDINote)
        #expect(Set(notes).count == notes.count)
    }

    @Test("Every voice a kit has can be written by the band and added on the Grid")
    @MainActor
    func voicesEverywhere() {
        for kind in SynthVoiceKind.allCases {
            #expect(WriteGrooveTool.voices.contains(kind.drumVoice.rawValue), "\(kind)")
            #expect(GridModel.knownVoices.contains(kind.drumVoice), "\(kind)")
            #expect(Regroove.Policy.defaultVoices.values.contains { $0.contains(kind.drumVoice) }, "\(kind)")
        }
        #expect(GridModel.name(of: .guiroLong) == "güiro, long")
        #expect(GridModel.name(of: .frameDrum) == "frame drum")
    }

    @Test("Cumbia has a feel, on the güiro, and its profile names it")
    func cumbia() throws {
        let feel = try #require(FeelLibrary.standard.feel(named: "Cumbia"))
        let voices = Set(feel.groove.patterns.map(\.voice))
        #expect(voices.isSuperset(of: [.guiro, .guiroLong, .kick, .highConga]))
        #expect(GenreBook.standard.profile(named: "cumbia")?.feels.contains("Cumbia") == true)
        #expect(GenreBook.standard.profile(named: "folk")?.feels.contains("Cajón Groove") == true)
        // The feels whose notes said a güiro or a triangle now play one.
        let chaCha = try #require(FeelLibrary.standard.feel(named: "Cha-Cha-Chá"))
        #expect(chaCha.groove.patterns.contains { $0.voice == .guiro })
        let baiao = try #require(FeelLibrary.standard.feel(named: "Baião"))
        #expect(baiao.groove.patterns.contains { $0.voice == .openTriangle })
    }
}
