import AudioEngine
import Foundation
import Instrument
@testable import MrRobotoApp
import MusicTheory
import Performance
import SongGraph
import Testing

/// set_effects and read_mix: an organ comes with its speaker, a section turns it fast, the returns
/// change, and what a section cannot do is refused with what it can.
@Suite("Director: the effects") @MainActor
struct EffectsToolTests {

    /// Chords on the organ, a Verse and a Chorus.
    static func song() throws -> (song: Song, chords: PartID) {
        var song = Song(title: "Sunday", key: .cMajor, tempo: 100)
        let progression = try Progression.parse("C | F | G | C", key: .cMajor).get()
        let chords = PartVersion(partID: PartID(), kind: .progression(progression), author: .user, operation: Operation.written, note: "Organ chords")
        try song.append(chords)
        try song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: "organ", forPart: chords.partID)), author: .user,
                                    operation: Operation.written, note: "Organ"))
        song.sections = [Section(name: "Verse", stitch: [Lane(part: chords.partID)], lengthInBars: 4),
                         Section(name: "Chorus", stitch: [Lane(part: chords.partID)], lengthInBars: 4)]
        return (song, chords.partID)
    }

    static func mix(_ workspace: DirectorScratchWorkspace) -> Mix? {
        workspace.song.flatMap { Guidance.mix(in: $0) }
    }

    @Test("An organ brings its rotating speaker, and read_mix says it is the instrument's own")
    func organsOwn() async throws {
        let (song, chords) = try Self.song()
        let workspace = DirectorScratchWorkspace(song: song)
        #expect(SongPlayback.plan(for: song, mediaURL: { _ in nil }).instrumentInserts[chords] == .rotarySlow)
        let read = WritingFixture.json(await WritingFixture.run(WritingFixture.toolbox(workspace), "read_mix", #"{"section":""}"#))
        let strips = read["strips"] as? [[String: Any]] ?? []
        #expect(strips.first?["insert"] as? String == "rotating speaker, slow (its instrument's own)", "\(strips)")
        #expect((read["returns"] as? String)?.hasPrefix("reverb room; echo every dotted eighth") == true)
    }

    @Test("set_effects turns the speaker fast in the chorus alone, and changes the returns")
    func sectionAndReturns() async throws {
        let (song, chords) = try Self.song()
        let workspace = DirectorScratchWorkspace(song: song)
        let box = WritingFixture.toolbox(workspace)
        let fast = await WritingFixture.run(box, "set_effects",
            #"{"part":"Organ chords","insert":"rotary-fast","echo":"keep","section":"Chorus","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"lift the chorus"}"#)
        #expect(!fast.isError, "\(fast.content)")
        let chorus = try #require(song.sections.last?.id), verse = try #require(song.sections.first?.id)
        var mix = try #require(Self.mix(workspace))
        #expect(mix.insert(for: chords, in: chorus, instrument: .rotarySlow)?.fast == true)
        #expect(mix.insert(for: chords, in: verse, instrument: .rotarySlow)?.fast == false)
        #expect(WritingFixture.json(fast)["strip"] as? String == "Organ chords in Chorus: through a rotating speaker, fast, no echo")

        let returns = await WritingFixture.run(box, "set_effects",
            #"{"part":"","insert":"keep","echo":"keep","section":"","room":"plate","echo_time":"dotted quarter","echo_feedback":0.5,"reason":"a soul record's plate"}"#)
        #expect(!returns.isError, "\(returns.content)")
        mix = try #require(Self.mix(workspace))
        #expect(mix.room == .plate && mix.echoSettings.beats == 1.5 && mix.echoSettings.feedback == 0.5)
        // The section's speed survived the second move.
        #expect(mix.insert(for: chords, in: chorus, instrument: .rotarySlow)?.fast == true)
    }

    @Test("An amp and an echo send go on a strip everywhere; a section sets only speed and echo")
    func stripAndRefusals() async throws {
        let (song, chords) = try Self.song()
        let workspace = DirectorScratchWorkspace(song: song)
        let box = WritingFixture.toolbox(workspace)
        let amp = await WritingFixture.run(box, "set_effects",
            #"{"part":"Organ chords","insert":"amp-crunch","echo":"-12","section":"","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"dirt"}"#)
        #expect(!amp.isError, "\(amp.content)")
        let mix = try #require(Self.mix(workspace))
        #expect(mix.strip(for: chords)?.insert == .ampCrunch && mix.strip(for: chords)?.echoDB == -12)

        let wrong = await WritingFixture.run(box, "set_effects",
            #"{"part":"Organ chords","insert":"amp-lead","echo":"keep","section":"Chorus","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"x"}"#)
        #expect(wrong.isError && wrong.content.contains("speaker's speed"), "\(wrong.content)")
        // With the amp in, there is no speaker for a section to speed up.
        let noSpeaker = await WritingFixture.run(box, "set_effects",
            #"{"part":"Organ chords","insert":"rotary-fast","echo":"keep","section":"Chorus","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"x"}"#)
        #expect(noSpeaker.isError && noSpeaker.content.contains("no rotating speaker"), "\(noSpeaker.content)")
        let nothing = await WritingFixture.run(box, "set_effects",
            #"{"part":"","insert":"keep","echo":"keep","section":"","room":"keep","echo_time":"keep","echo_feedback":-1,"reason":"x"}"#)
        #expect(nothing.isError && nothing.content.contains("Nothing changed"))
    }

    @Test("A mix that changes an effect by section is rendered and played section by section, as one that changes a level is")
    func stepsBySection() throws {
        let (song, chords) = try Self.song()
        var mix = Mix()
        #expect(!mix.changesBySection)
        let chorus = try #require(song.sections.last?.id)
        mix.setSectionEffect(SectionEffect(section: chorus, part: chords, fast: true))
        #expect(mix.changesBySection)
        var withMix = song
        try withMix.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: "fast chorus"))
        let plan = SongPlayback.plan(for: withMix, mediaURL: { _ in nil })
        let clock = TransportClock(tempo: plan.tempo, timeSignature: plan.timeSignature, sampleRate: 48_000)
        // Before, only a level by section split the render, and the chorus turned slow in every export.
        #expect(SectionBounce.sectionBoundaries(of: plan, clock: clock, sampleRate: 48_000).map(\.section) == [chorus])
    }

    @Test("The Mixer says what moved: an insert, an echo send, the room, a section's speed")
    func describes() {
        let part = PartID(), chorus = SectionID()
        var after = Mix()
        after.set(Strip(part: part, label: "Organ", insert: .rotaryFast, echoDB: -9))
        after.room = .hall
        after.setSectionEffect(SectionEffect(section: chorus, part: part, fast: true))
        let said = MixerModel.describe(from: Mix(), to: after, labels: [part: "Organ"], sections: [chorus: "Chorus"])
        #expect(said.contains("Organ through a rotating speaker, fast") && said.contains("Organ echo -9.0 dB")
                && said.contains("reverb hall") && said.contains("Organ speaker fast in Chorus"), "\(said)")
    }
}

/// The tonewheel organ: a held note loops without a seam, it is in tune, its percussion is at
/// the front and gone by the loop, and it comes with its speaker.
@Suite("Drawbar organ")
struct DrawbarOrganTests {
    static let rate = 48_000.0

    @Test("A held note loops on a stretch every wheel turns a whole number of times in: no seam")
    func seamless() {
        for midi in [36, 48, 60, 72, 84] {
            let samples = InstrumentSynthesizer.render(.organ, midi: midi, velocity: 110, sampleRate: Self.rate)
            let loop = InstrumentSynthesizer.drawbarLoop(midi: midi, sampleRate: Self.rate)
            #expect(samples.count == loop.start + loop.length)
            // The step from the loop's last sample back to its first is no bigger than the steps
            // inside it.
            let jump = abs(samples[loop.start] - samples[loop.start + loop.length - 1])
            var largest: Float = 0
            for i in loop.start..<(loop.start + loop.length - 1) { largest = max(largest, abs(samples[i + 1] - samples[i])) }
            #expect(jump <= largest * 1.01, "MIDI \(midi): a seam of \(jump) against steps of \(largest)")
        }
    }

    @Test("Its note is in tune: the loop moves the wheels a couple of cents at most")
    func inTune() {
        for midi in [36, 60, 84] {
            let samples = InstrumentSynthesizer.render(.organ, midi: midi, velocity: 110, sampleRate: Self.rate)
            let loop = InstrumentSynthesizer.drawbarLoop(midi: midi, sampleRate: Self.rate)
            let expected = InstrumentSynthesizer.frequency(ofMIDI: midi)
            let window = Array(samples[loop.start..<(loop.start + Int(Self.rate))])
            let found = SynthMeasure.dominantFrequency(window, in: 0..<window.count, band: (expected * 0.9)...(expected * 1.1),
                                                       sampleRate: Self.rate, resolution: 0.1)
            #expect(abs(1_200 * log2(found / expected)) < 3, "MIDI \(midi): \(found) Hz for \(expected)")
        }
    }

    @Test("The jazz organ's percussion rings at the front of the note and is gone by the loop")
    func percussion() {
        let midi = 60
        let jazz = InstrumentSynthesizer.render(.jazzOrgan, midi: midi, velocity: 110, sampleRate: Self.rate)
        let plain = InstrumentSynthesizer.render(.organ, midi: midi, velocity: 110, sampleRate: Self.rate)
        let third = InstrumentSynthesizer.frequency(ofMIDI: midi) * InstrumentVoiceSpec.Drawbars.ratios[4]
        func at(_ samples: [Float], from: Int) -> Double {
            SynthMeasure.magnitude(samples, at: third, in: from..<(from + 4_800), sampleRate: Self.rate)
        }
        #expect(at(jazz, from: 480) > 4 * at(plain, from: 480), "a strike at the front")
        let loop = InstrumentSynthesizer.drawbarLoop(midi: midi, sampleRate: Self.rate)
        #expect(at(jazz, from: loop.start) < 1.2 * at(plain, from: loop.start) + 1e-3, "and none by the loop")
    }

    @Test("The organs are tonewheels with their speakers; the rock organ's is driven")
    func presets() {
        for spec in [InstrumentVoiceSpec.organ, .rockOrgan, .jazzOrgan, .gospelOrgan] {
            #expect(spec.engine == .drawbar && spec.insert?.kind == .rotary, "\(spec.id)")
        }
        #expect((InstrumentVoiceSpec.rockOrgan.insert?.drive ?? 0) > 0.3)
        #expect(InstrumentVoiceSpec.preset(id: "jazz-organ")?.drawbars?.percussion?.harmonic == 3)
    }
}
