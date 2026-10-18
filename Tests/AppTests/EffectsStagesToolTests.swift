import AudioEngine
import Foundation
import Instrument
@testable import MrRobotoApp
import MusicTheory
import Performance
import SongGraph
import Testing

/// set_effects' other stages: a pump on the kick, a low-pass swept open across a section, a wah,
/// a chorus, the echo on tape and a spring; read_mix says them back; what a section cannot do is
/// refused. And the plan's timeline the strips keep time by.
@Suite("Director: the strip's stages and the returns' own") @MainActor
struct EffectsStagesToolTests {

    static func setEffects(_ fields: String) -> String {
        #"{"part":"Organ chords","insert":"keep","echo":"keep","section":"","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"test""#
            + (fields.isEmpty ? "" : "," + fields) + "}"
    }

    @Test("A pump on the kick and a low-pass opened across the chorus go on the strip, and read_mix says them")
    func pumpAndSweep() async throws {
        let (song, chords) = try EffectsToolTests.song()
        let workspace = DirectorScratchWorkspace(song: song)
        let box = WritingFixture.toolbox(workspace)
        let pump = await WritingFixture.run(box, "set_effects", Self.setEffects(#""pump":"kick","pump_db":8"#))
        #expect(!pump.isError, "\(pump.content)")
        let sweep = await WritingFixture.run(box, "set_effects", Self.setEffects(#""section":"Chorus","filter":"low-pass","filter_hz":300,"filter_to_hz":20000"#)
            .replacingOccurrences(of: #""section":"","#, with: ""))
        #expect(!sweep.isError, "\(sweep.content)")
        let chorus = try #require(song.sections.last?.id)
        let mix = try #require(EffectsToolTests.mix(workspace))
        #expect(mix.strip(for: chords)?.pump == StripPump(trigger: .kick, depthDB: 8, releaseBeats: 0.5))
        #expect(mix.strip(for: chords)?.filter?.kind == .lowPass && mix.strip(for: chords)?.filter?.isOpen == true)
        let effect = try #require(mix.sectionEffect(for: chords, in: chorus))
        #expect(effect.filterFromHz == 300 && effect.filterToHz == 20_000)
        // No groove, no kick: the tool says the pump will do nothing, and how to make it pump.
        #expect(WritingFixture.json(pump)["strip"].map { "\($0)" }?.contains("pump beat") == true, "\(pump.content)")

        let read = WritingFixture.json(await WritingFixture.run(box, "read_mix", #"{"section":""}"#))
        let strip = (read["strips"] as? [[String: Any]])?.first
        let effects = strip?["effects"] as? [String] ?? []
        #expect(effects.contains("a low-pass, open") && effects.contains("pumping 8 dB on the kick"), "\(effects)")
        let bySection = read["section_effects"] as? [String] ?? []
        #expect(bySection.contains { $0.contains("low-pass swept from 300 Hz to open") && $0.contains("Chorus") }, "\(bySection)")
    }

    @Test("A wah and a chorus go on everywhere; a section cannot take them, and a sweep needs its start")
    func pedalsAndRefusals() async throws {
        let (song, chords) = try EffectsToolTests.song()
        let workspace = DirectorScratchWorkspace(song: song)
        let box = WritingFixture.toolbox(workspace)
        let on = await WritingFixture.run(box, "set_effects", Self.setEffects(#""pedal":"wah-sixteenths","modulation":"chorus""#))
        #expect(!on.isError, "\(on.content)")
        let mix = try #require(EffectsToolTests.mix(workspace))
        #expect(mix.strip(for: chords)?.pedal == .wahSixteenths && mix.strip(for: chords)?.modulation == .chorus)

        let inSection = await WritingFixture.run(box, "set_effects", Self.setEffects(#""modulation":"phaser-slow""#)
            .replacingOccurrences(of: #""section":"""#, with: #""section":"Chorus""#))
        #expect(inSection.isError && inSection.content.contains("not the pedal or the modulation"), "\(inSection.content)")
        let noStart = await WritingFixture.run(box, "set_effects", Self.setEffects(#""filter_to_hz":2000"#)
            .replacingOccurrences(of: #""section":"""#, with: #""section":"Chorus""#))
        #expect(noStart.isError && noStart.content.contains("where it starts"), "\(noStart.content)")
        let pumpNone = await WritingFixture.run(box, "set_effects", Self.setEffects(#""pump":"kick""#)
            .replacingOccurrences(of: #""section":"""#, with: #""section":"Chorus""#))
        #expect(pumpNone.isError && pumpNone.content.contains("no pump"), "\(pumpNone.content)")
    }

    @Test("The echo goes on tape and the room becomes a spring; the returns say so")
    func tapeAndSpring() async throws {
        let (song, _) = try EffectsToolTests.song()
        let workspace = DirectorScratchWorkspace(song: song)
        let box = WritingFixture.toolbox(workspace)
        let moved = await WritingFixture.run(box, "set_effects",
            #"{"part":"","insert":"keep","echo":"keep","section":"","room":"spring","echo_time":"keep","echo_feedback":0.6,"reason":"dub","echo_tape":"tape"}"#)
        #expect(!moved.isError, "\(moved.content)")
        let mix = try #require(EffectsToolTests.mix(workspace))
        #expect(mix.room == .spring && mix.echoSettings.isTape && mix.echoSettings.feedback == 0.6)
        #expect((WritingFixture.json(moved)["returns"] as? String)?.hasPrefix("reverb spring; echo on tape every dotted eighth") == true)
        // A mix that never touched any of it still encodes as it always did.
        let encoded = String(decoding: try JSONEncoder().encode(Mix.unity), as: UTF8.self)
        #expect(!encoded.contains("tape") && !encoded.contains("pump") && !encoded.contains("filter"))
    }

    @Test("The Mixer's note says what moved in the new stages")
    func describedMoves() {
        let part = PartID(), section = SectionID()
        var before = Mix(), after = Mix()
        before.set(Strip(part: part, label: "Pad"))
        after.set(Strip(part: part, label: "Pad", modulation: .chorusWide, filter: StripFilter(kind: .lowPass), pump: .standard))
        after.setSectionEffect(SectionEffect(section: section, part: part, filterFromHz: 300, filterToHz: 20_000, pumpDB: 0))
        let note = MixerModel.describe(from: before, to: after, labels: [part: "Pad"], sections: [section: "Intro"])
        #expect(note.contains("Pad chorus, wide") && note.contains("Pad low-pass, open") && note.contains("Pad pumping 6 dB on the kick"), "\(note)")
        #expect(note.contains("Pad low-pass swept from 300 Hz to open in Intro") && note.contains("Pad no pump in Intro"), "\(note)")
    }

    @Test("The plan's timeline places each section in beats and reads its groove's kicks")
    func timeline() throws {
        var song = Song(title: "Floor", key: .cMajor, tempo: 124)
        var kick = [VelocityTier](repeating: .rest, count: 16)
        for step in [0, 4, 8, 12] { kick[step] = .accent }
        let groove = Groove(stepsPerBar: 16, bars: 1, patterns: [GroovePattern(voice: .kick, steps: kick)])
        let drums = PartVersion(partID: PartID(), kind: .groove(groove), author: .user, operation: Operation.written, note: "Four on the floor")
        try song.append(drums)
        let progression = try Progression.parse("C | F", key: .cMajor).get()
        let pad = PartVersion(partID: PartID(), kind: .progression(progression), author: .user, operation: Operation.written, note: "Pad")
        try song.append(pad)
        song.sections = [Section(name: "Intro", stitch: [Lane(part: pad.partID)], lengthInBars: 4),
                         Section(name: "Drop", stitch: [Lane(part: drums.partID), Lane(part: pad.partID)], lengthInBars: 8)]
        let timeline = SongPlayback.plan(for: song, mediaURL: { _ in nil }).mixTimeline
        #expect(timeline.sections.count == 2)
        #expect(timeline.sections[0].startBeat == 0 && timeline.sections[0].lengthBeats == 16 && timeline.sections[0].kicks.isEmpty)
        #expect(timeline.sections[1].startBeat == 16 && timeline.sections[1].lengthBeats == 32)
        #expect(timeline.sections[1].kicks == [0, 1, 2, 3] && timeline.sections[1].patternBeats == 4,
                "\(timeline.sections[1].kicks) over \(timeline.sections[1].patternBeats)")
    }
}

/// The recordings that stand for the built-in drums, basses and overdriven guitars.
@Suite("Recorded sounds: kits, basses, treatments")
struct RecordedCounterpartsTests {
    @Test("A studio, rock, jazz and vintage kit each have recorded kits to stand for them; the drum machines have none")
    func kits() {
        for id in ["studio", "rock", "funk", "vintage", "jazz", "lofi"] { #expect(RecordedSounds.kits[id] != nil, "\(id)") }
        for id in ["tr808", "tr909", "linn", "trap"] { #expect(RecordedSounds.kits[id] == nil, "\(id)") }
        #expect(RecordedSounds.kits["jazz"] == ["Swirly Brushes"])
        // Every machine named has a preset, so the map cannot drift from the machines.
        for id in RecordedSounds.kits.keys { #expect(SynthMachine.preset(id: id) != nil, "\(id)") }
        for id in RecordedSounds.basses.keys { #expect(BassVoiceSpec.preset(id: id) != nil, "\(id)") }
    }

    @Test("A treatment plays the recording it is made from through its amp, and cannot be removed")
    func treatments() {
        var guitar = InstrumentVoiceSpec(id: "sfz-electric-guitar", name: "Electric Guitar", family: "guitar", engine: .sampled)
        guitar.sampledKit = "/tmp/electric-guitar"
        let made = Treatment.available(among: [guitar])
        // The guitar's three; the combo organ waits for a transistor organ.
        #expect(made.map(\.id) == [Treatment.cleanAmp, .crunch, .lead].map(\.id))
        let crunch = made.first { $0.id == Treatment.crunch.id }
        #expect(crunch?.insert == .ampCrunch && crunch?.sampledKit == "/tmp/electric-guitar" && crunch?.basedOn == guitar.id)
        #expect(crunch?.isMadeFromRecordings == true && crunch?.isEnsemble == false)
        #expect(RecordedSounds.recording(for: "overdrive-guitar", among: [guitar] + made)?.id == Treatment.crunch.id)
        #expect(RecordedSounds.recording(for: "distorted-guitar", among: [guitar] + made)?.id == Treatment.lead.id)
        #expect(Treatment.available(among: []).isEmpty)
    }

    @Test("The combo organ is on the drawbar engine and brings its amp and its vibrato")
    func comboOrgan() {
        let organ = InstrumentVoiceSpec.comboOrgan
        #expect(organ.engine == .drawbar && organ.insert == .ampClean && organ.modulation == .vibrato)
    }
}
