import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Two more audits: the bass line and the chords after a groove, and the groove made from a chop.
// Each test is one of what they found, fixed.

@Suite("The bass and chords path, audited", .serialized) @MainActor
struct BassChordsAuditTests {
    private static let cMajor = Key(parsing: "C major")!

    private func progression(_ text: String) throws -> Progression {
        try Progression.parse(text, key: Self.cMajor).get()
    }

    @Test("a restore reaches a Chords sheet opened on nothing, and its next keep builds on it")
    func restoreReachesTheSheet() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.discardSurfaceModel = { SurfaceWiring.shared.discardModel(for: $0) }
        app.open(Song.new(title: "Glass", tempo: 96))
        let id = try #require(app.perform(SurfaceAction(surface: .chords, title: "Chords")))
        let item = try #require(app.bench.items.first { $0.id == id })
        let sheet = SurfaceWiring.shared.chordsModel(for: item, app: app)
        sheet.autoKeep.delay = nil
        sheet.text = "Dm7 G7 | Cmaj7"
        let first = try #require(sheet.commit())
        sheet.text = "Em7 A7 | Dmaj7"
        #expect(sheet.commit() != nil)
        #expect(app.bound(for: id).contains { app.version($0)?.partID == first.partID }, "the sheet follows what it keeps")

        #expect(app.restore(first.id))
        let reopened = SurfaceWiring.shared.chordsModel(for: item, app: app)
        #expect(reopened.progression == (try progression("Dm7 G7 | Cmaj7")), "the restore is what the sheet shows")
        #expect(!reopened.hasUnkeptChanges)
    }

    @Test("chords that split a bar unevenly are not rewritten by being opened")
    func unevenBeatsSurvive() throws {
        var uneven = try progression("C Dm7 | G7")
        uneven.bars[0].chords[0].beats = 3
        uneven.bars[0].chords[1].beats = 1
        let version = PartVersion(partID: PartID(), kind: .progression(uneven), author: .user, operation: Operation.imported)
        let sheet = ChordsModel(host: ChordsStub(), key: Self.cMajor, progression: version)
        #expect(sheet.progression == uneven)
        #expect(!sheet.hasUnkeptChanges)
        sheet.text = "C Dm7 | G7 | C"
        #expect(sheet.hasUnkeptChanges, "an edit is still an edit")
    }

    @Test("a sheet auditions on its part's instrument, which is what the song plays it on")
    func sheetUsesThePartsInstrument() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-instrument")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Glass", tempo: 96))
        let id = try #require(app.perform(SurfaceAction(surface: .chords, title: "Chords")))
        let sheet = SurfaceWiring.shared.chordsModel(for: app.bench.items.first { $0.id == id }!, app: app)
        sheet.autoKeep.delay = nil
        sheet.text = "Dm7 G7 | Cmaj7"
        let kept = try #require(sheet.commit())
        sheet.setInstrument(InstrumentVoiceSpec.all.first { $0.id != SongPlayback.instrumentID(in: app.song!) }!.id)
        #expect(sheet.instrument == SongPlayback.instrumentID(for: kept.partID, in: app.song!))
        #expect(sheet.instrument != SongPlayback.instrumentID(in: app.song!), "not the song's")
    }

    @Test("an open Piano roll writes against the chords kept after it opened, in the key Song settings say")
    func rollFollowsTheSong() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-roll")
        defer { try? FileManager.default.removeItem(at: directory) }
        var song = Song.new(title: "Glass", tempo: 96)
        song.key = Key(parsing: "F major")
        app.open(song)
        #expect(app.record(TransportFixture.grooveVersion()))
        let id = try #require(app.perform(SurfaceAction(surface: .pianoRoll, title: "Bass")))
        let item = try #require(app.bench.items.first { $0.id == id })
        let roll = SurfaceWiring.shared.pianoRollModel(for: item, app: app)
        #expect(roll.key == Key(parsing: "F major"))
        #expect(roll.usesDefaultChords)

        let chords = try progression("Dm7 G7 | Cmaj7")
        #expect(app.record(PartVersion(partID: PartID(), kind: .progression(chords), author: .user, operation: Operation.written)))
        let same = SurfaceWiring.shared.pianoRollModel(for: item, app: app)
        #expect(same === roll)
        #expect(roll.chords == chords.spans && !roll.usesDefaultChords)
    }

    @Test("switching a roll to melody mode keeps nothing; a tune taken out of the form stays out")
    func nothingJoinsUninvited() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-join")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Glass", tempo: 96))
        let bass = PartVersion(partID: PartID(), kind: .bassline(Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1)],
                                                                         sound: "finger")),
                               author: .user, operation: Operation.written)
        #expect(app.record(bass))
        let roll = PianoRollModel(host: RollStub(), groove: nil, key: Self.cMajor, tempo: 96, bassline: bass)
        roll.setMode(.melody)
        #expect(!roll.hasUnkeptChanges, "the bass line's notes are not a tune until they are played with")

        let tune = TransportFixture.melodyVersion()
        #expect(app.record(tune))
        app.arrange(app.song!.sections.map { section in
            var section = section
            section.stitch.removeAll { $0.part == tune.partID }
            return section
        })
        let edited = tune.deriving(.melody(Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1)])),
                                   by: .user, operation: Operation.edit)
        #expect(app.record(edited))
        #expect(!app.song!.sections.contains { $0.stitch.contains(part: tune.partID) }, "its next edit is not an invitation back")
    }

    @Test("a bass line played in is a pass as long as its section")
    func capturedBassHasALength() {
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)
        let played = [PlayedNote(note: 38, velocity: 100, start: 0, end: 0.5)]
        let line = MIDICapture.bassline(played, clock: clock, sectionStart: 0, end: 6, key: nil, sound: nil, bars: 4)
        #expect(line?.lengthInBars == 4 && line?.loopBars(beatsPerBar: 4) == 4)
    }

    @Test("the MIDI file's chords are the voicing the song plays")
    func midiChordsAreTheHeardVoicing() throws {
        let chords = try progression("C/E | F")
        var song = Song.new(title: "Glass", tempo: 96)
        try song.append(PartVersion(partID: PartID(), kind: .progression(chords), author: .user, operation: Operation.written))
        let file = MIDIExport.file(for: song)
        let track = try #require(file.tracks.first { $0.program == 4 })
        let firstChord = Set(track.notes.filter { $0.start == 0 }.map(\.pitch))
        let heard = Set(Voicing.notes(for: chords).filter { $0.start == 0 }.map(\.pitch.midi))
        #expect(firstChord == heard)

        // And back: C over E is still C over E, not a chord built on E.
        let back = MIDIImport.parts(from: try MIDIFile(data: file.data()), key: Self.cMajor)
        guard case .progression(let read)? = back.parts.first(where: { $0.kind.type == .progression })?.kind else {
            Issue.record("no chords came back"); return
        }
        #expect(read.chords.first == chords.chords.first, "\(read.chords.map { $0.symbol() })")
        #expect(read.bars.map { $0.chords.map(\.beats) } == chords.bars.map { $0.chords.map(\.beats) })
    }

    @Test("a note tied over a section's end is let go there")
    func notesStopAtTheSection() {
        let hits = [VoiceSampler.Hit(note: 40, velocity: 90, at: 1, duration: 3),
                    VoiceSampler.Hit(note: 43, velocity: 90, at: 2.5, duration: 0.5)]
        let bass = BasslinePlayer.clipped(hits, at: 2)
        #expect(bass.count == 1 && bass[0].duration == 1)
        #expect(KeysPlayer.clipped(hits, at: 2) == bass)
    }

    @Test("a note clicked in the last sixteenth lands on it, inside the loop")
    func lastSixteenth() {
        let roll = PianoRollModel(host: RollStub(), groove: nil, key: Self.cMajor, tempo: 96)
        roll.addNote(pitch: 40, at: roll.totalBeats - 0.01)
        let note = roll.notes.last { $0.pitch.midi == 40 }
        #expect(note?.start == roll.totalBeats - 0.25)
        #expect((note?.end ?? 99) <= roll.totalBeats)
    }
}

@Suite("The groove made from a chop, audited", .serialized) @MainActor
struct ChopGrooveAuditTests {

    @Test("with no sections, a chop under its own groove is not played twice")
    func flatPlanDropsTheLoop() throws {
        let directory = TransportFixture.temporaryDirectory("audit-flat")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, url) = try ChopGrooveFixture.keptChop(in: directory)
        let groove = TransportFixture.grooveVersion()
        var song = Song(title: "Flip", tempo: ChopLaneFixtures.bpm)
        try song.append(sample)
        try song.append(groove)
        try song.append(ChopGrooveFixture.pick(ChopSound.id(for: sample.partID), for: groove.partID))
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(url))
        #expect(plan.voices.contains { $0.kit != nil })
        #expect(!plan.voices.contains { $0.chop != nil }, "the loop is the groove now")
        #expect(plan.dustyPlayers == 1)
    }

    @Test("a second groove made from the same chop takes the first one's place")
    func secondGrooveReplacesTheFirst() throws {
        let (app, directory, _) = CompletenessFixture.app("audit-second")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, _) = try ChopGrooveFixture.keptChop(in: directory)
        var song = Song(title: "Flip", tempo: ChopLaneFixtures.bpm,
                        sections: [Section(name: "Verse", stitch: [sample.partID].lanes, lengthInBars: 4)])
        try song.append(sample)
        app.open(song)
        let first = TransportFixture.grooveVersion(), second = TransportFixture.grooveVersion()
        #expect(app.record(first))
        #expect(app.playGroove(first.partID, onChop: sample.partID) == ["Verse"])
        #expect(app.record(second))
        #expect(app.playGroove(second.partID, onChop: sample.partID) == ["Verse"])
        #expect(app.song!.sections[0].stitch.map(\.part) == [second.partID])
    }

    @Test("a loop fits the song's tempo: whole bars to whole bars, any other span by the tempo alone")
    func loopLengths() {
        func track(bars: Double, tempo: Double) -> SongPlayback.ChopTrack {
            SongPlayback.ChopTrack(version: VersionID(), name: "Bar", url: URL(fileURLWithPath: "/dev/null"),
                                   region: SongGraph.TimeRange(start: 0, end: bars * 240 / tempo), passes: [], tempo: tempo)
        }
        let partBar = track(bars: 0.6, tempo: 90)
        #expect(abs(partBar.loopSeconds(songTempo: 90, beatsPerBar: 4)! - partBar.region.duration) < 1e-9, "no stretch at its own tempo")
        #expect(abs(partBar.loopSeconds(songTempo: 120, beatsPerBar: 4)! - partBar.region.duration * 90 / 120) < 1e-9)
        let nearlyTwo = track(bars: 1.95, tempo: 90)
        #expect(abs(nearlyTwo.loopSeconds(songTempo: 120, beatsPerBar: 4)! - 4.0) < 1e-9, "two bars at 120")
    }

    @Test("a bar never cut is kept as the lane cut it before a groove is made from it")
    func neverCutBarIsKeptFirst() throws {
        let host = ChopLaneHostStub()
        let promoted = PartVersion(partID: PartID(), kind: .sample(Sample(media: ChopLaneFixtures.media,
                                                                          slices: [SliceMarker(position: 0)],
                                                                          detectedTempo: ChopLaneFixtures.bpm)),
                                   author: .user, operation: Operation.chop)
        host.record(promoted)
        var source = ChopLaneFixtures.source(ChopLaneFixtures.cleanBar(), label: "Bar 1")
        source.partID = promoted.partID
        let lane = ChopLaneSurface(source: source, host: host, version: promoted.id)
        lane.feelName = "Boom-Bap Pocket"
        lane.playRegroove()
        lane.keepRegroove()
        #expect(lane.lastError == nil)
        let cuts = host.madeVersions.compactMap { version -> Sample? in
            if case .sample(let sample) = version.kind { return sample } else { return nil }
        }
        #expect(cuts.last?.slices.count == lane.sliceCount && lane.sliceCount > 1, "the cut the lane played is kept")
        #expect(host.madeVersions.last?.type == .groove)
    }

    @Test("classes and trims go back on the slices at their markers, whatever was lost between")
    func carriedByPosition() {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let kept = lane.sliceMarkers
        let classes = ChopLaneSurface.overrides(from: kept)
        func recut(_ positions: [Double]) -> Chop {
            ChopLaneSurface.recut(at: positions, signal: ChopLaneFixtures.cleanBar(),
                                  sampleRate: ChopLaneFixtures.sampleRate, sourceOffset: 0, detectedTempo: 90)
        }
        #expect(recut(kept.map(\.position)).count == kept.count, "an exact re-cut keeps every slice")

        // One marker lost: every later slice moves up one place in the list.
        var positions = kept.map(\.position)
        positions.remove(at: 1)
        let fewer = recut(positions)
        #expect(fewer.count == kept.count - 1)
        let carried = ChopLaneSurface.carried(kept, pads: [PadTrim(slice: 3, reverse: true)], onto: fewer)
        #expect(carried.overrides[1] == classes[2] && carried.overrides[2] == classes[3], "each class stays at its marker")
        #expect(carried.edits[2]?.reverse == true && carried.edits[3] == nil, "slice 3's trim moved with slice 3")
    }

    @Test("a groove whose chop cannot be read plays on the 808, and the song still starts")
    func unreadableChopFallsBack() async throws {
        let directory = TransportFixture.temporaryDirectory("audit-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = SongPlayback.ChopTrack(version: VersionID(), name: "Gone", url: directory.appendingPathComponent("gone.wav"),
                                            region: SongGraph.TimeRange(start: 0, end: 2), passes: [], part: PartID(),
                                            slices: [SliceMarker(position: 0), SliceMarker(position: 1)], tempo: 120)
        var plan = SongPlayback(tempo: 120, loops: false, lengthInBars: 1)
        plan.segments = [SongPlayback.Segment(section: SectionID(), name: "Verse", startBar: 0, lengthInBars: 1,
                                              voices: [.groove(TransportFixture.groove(), part: PartID(), kit: broken)])]
        let stems = try await SectionBounce.render(plan, kitsDirectory: directory.appendingPathComponent("kits"), onlyTheMix: true)
        #expect((stems.mix.first ?? []).contains { abs($0) > 0.001 }, "the groove sounds, on a machine")
    }
}
