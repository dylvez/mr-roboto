import AVFAudio
import Analysis
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M6 X10–X12: the door. MIDI leaves and comes back as the same parts; the master leaves as a
// 24-bit WAV that reads at the report's loudness, and comes back through the analyser.

@Suite("Interop: MIDI out and back")
struct MIDIInteropTests {

    @Test("a groove, a bass line and a progression leave as tracks and come back as the same parts")
    func midiRoundTrip() throws {
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d)), tempo: 92)
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : ($0 == "g" ? .ghost : ($0 == "A" ? .accent : .rest)) })
        }
        let groove = Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            line(.kick, "x-----x---------x-----x---g-----"),
            line(.snare, "----A-------A-------A-------A---"),
            line(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-"),
        ])
        let bass = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 38), start: 0, duration: 1.5, velocity: 100),
                                    NoteEvent(pitch: Pitch(midi: 45), start: 2.5, duration: 0.5, velocity: 90),
                                    NoteEvent(pitch: Pitch(midi: 38), start: 4, duration: 2, velocity: 100)], sound: "finger", key: song.key)
        let d = PitchClass(wrapping: 2), g = PitchClass(wrapping: 7), a = PitchClass(wrapping: 9), b = PitchClass(wrapping: 11)
        let progression = Progression(key: song.key!, bars: [ProgressionBar(Chord(d, .major)), ProgressionBar(Chord(b, .minor)),
                                                              ProgressionBar(chords: [ChordSpan(Chord(g, .major), beats: 2), ChordSpan(Chord(a, .major), beats: 2)])])
        try song.append(PartVersion(partID: PartID(), kind: .groove(groove), author: .user, operation: Operation.written, note: "Boom-bap pocket"))
        try song.append(PartVersion(partID: PartID(), kind: .bassline(bass), author: .user, operation: Operation.written, note: "Palladino line"))
        try song.append(PartVersion(partID: PartID(), kind: .progression(progression), author: .user, operation: Operation.written, note: "Chords"))
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 2), Section(name: "Hook", stitch: [], lengthInBars: 2)]

        let file = MIDIExport.file(for: song)
        #expect(file.tracks.count == 3 && abs(file.tempo - 92) < 0.01)
        #expect(file.tracks[0].isDrums && file.tracks[0].markers.map(\.text) == ["Verse", "Hook"])
        #expect(file.tracks[0].markers[1].tick == 480 * 8)
        let back = try MIDIFile(data: file.data())
        let imported = MIDIImport.parts(from: back, key: song.key)
        #expect(abs(imported.tempo - 92) < 0.01)
        #expect(imported.parts.map(\.name) == ["Boom-bap pocket", "Palladino line", "Chords"])
        guard case .groove(let groove2) = imported.parts[0].kind else { Issue.record("no groove"); return }
        #expect(groove2.bars == 2 && groove2.stepsPerBar == 16)
        for pattern in groove.patterns {
            #expect(groove2.patterns.first { $0.voice == pattern.voice }?.steps == pattern.steps, "\(pattern.voice)")
        }
        guard case .bassline(let bass2) = imported.parts[1].kind else { Issue.record("no bass line"); return }
        #expect(bass2.notes.map(\.pitch.midi) == bass.notes.map(\.pitch.midi))
        #expect(zip(bass2.notes, bass.notes).allSatisfy { abs($0.start - $1.start) < 0.003 && abs($0.duration - $1.duration) < 0.003 })
        guard case .progression(let chords2) = imported.parts[2].kind else { Issue.record("no progression"); return }
        #expect(chords2.chords.map { $0.symbol() } == progression.chords.map { $0.symbol() }, "\(chords2.chords.map { $0.symbol() })")
        #expect(chords2.bars.count == 3 && chords2.bars[2].chords.map(\.beats) == [2, 2])
    }
}

@Suite("Interop: the master out, and back through the analyser", .serialized) @MainActor
struct MasterExportTests {

    private func song() -> Song {
        var song = FormFixture.build(tempo: 92).song
        let ids = [Guidance.grooves(in: song).last!.id, Guidance.basslines(in: song).last!.id]
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 4), Section(name: "Hook", stitch: ids, lengthInBars: 4)]
        return song
    }

    @Test("the master is a 24-bit WAV beside a report, and reads back at the report's loudness within 0.1 LU")
    func master() async throws {
        let directory = LibraryFixture.directory("export")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory), status: .empty(directory), transportHost: StubTransportHost())
        var song = self.song()
        var mix = Mix()
        mix.master = Master(gainDB: 6, ceilingDBTP: -1, targetLUFS: -14)
        try song.append(PartVersion(partID: PartID(), kind: .mix(mix), author: .user, operation: Operation.mix, note: "master +6.0 dB"))
        app.open(song)
        let out = directory.appendingPathComponent("out", isDirectory: true)
        let result = try await Export.master(app, to: out)
        #expect(result.wav.lastPathComponent == "Arrival — master.wav" && FileManager.default.fileExists(atPath: result.report.path))
        let file = try AVAudioFile(forReading: result.wav)
        #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24, "\(file.fileFormat.settings)")
        let planar = try BoothAdapter.planar(result.wav)
        let lufs = MixMeter.integratedLoudness(planar.planar, sampleRate: planar.sampleRate)
        #expect(abs(lufs - result.summary.integratedLUFS) < 0.1, "\(lufs) vs \(result.summary.integratedLUFS)")
        #expect(result.summary.truePeakDBTP <= -1.0 && result.summary.bitDepth == 24 && result.summary.tempo == 92)
        #expect(abs(result.summary.durationSeconds - (8 * 4 * 60 / 92 + 0.5)) < 0.01)
        let decoded = try JSONDecoder().decode(Export.MasterReport.self, from: Data(contentsOf: result.report))
        #expect(decoded.song == "Arrival" && decoded.mixVersion != nil)

        // The stems: one per strip, dry of the master's +6.
        let stems = try await Export.stems(app, to: out)
        #expect(stems.count == 2, "\(stems.map(\.lastPathComponent))")
        let stemPlanar = try BoothAdapter.planar(stems[0])
        #expect(MixMeter.samplePeakDB(stemPlanar.planar) < result.summary.truePeakDBTP + 0.5)

        // The MIDI.
        let midi = try Export.midi(app, to: out)
        #expect(try MIDIFile(contentsOf: midi).tracks.count >= 2)

        // Back in through the analyser: the loudness the report says, within a LU.
        let report = try await MusicUnderstandingProvider().analyze(url: result.wav)
        let analysed = try #require(report.loudness?.integrated)
        #expect(abs(analysed - result.summary.integratedLUFS) < 1.0, "analysed \(analysed) vs exported \(result.summary.integratedLUFS)")
        if let bpm = report.beats?.bpm {
            let near = [bpm, bpm * 2, bpm / 2].contains { abs($0 - 92) < 4 }
            #expect(near, "tempo read as \(bpm)")
        }
        if let key = report.key?.dominantKey { print("[export] key read as \(key)") }
        // And as a record in the library: the same path the Import surface takes.
        let inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appendingPathComponent("Arrival master.wav")
        try FileManager.default.copyItem(at: result.wav, to: copy)
        let outcome = app.importFromInbox(copy)
        guard case .idea(let id) = outcome else { Issue.record("\(outcome)"); return }
        #expect(app.library.ideas.contains { $0.id == id })
    }

    @Test("the export tool writes MIDI through a scratch workspace and names the files")
    func exportTool() async throws {
        let workspace = DirectorScratchWorkspace(song: song())
        let box = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4)), workspace: workspace)
        let result = await box.run(ClaudeToolUse(id: "e", name: "export", input: .object([.init("what", .string("midi"))])))
        #expect(!result.isError && result.content.contains("Arrival.mid"), "\(result.content)")
        let refused = await box.run(ClaudeToolUse(id: "m", name: "export", input: .object([.init("what", .string("master"))])))
        #expect(refused.isError)
    }
}
