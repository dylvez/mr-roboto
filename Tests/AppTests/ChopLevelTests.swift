import AVFAudio
import AudioEngine
import Foundation
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A chop played at whatever level its bar of the media had. A bar of a stem the separator had left
// nearly empty sat 20 dB under the record, the song bounced 19 LU under its target, and the only
// fix on offer was the master, which went up 18.8 dB. These are a quiet bar brought up when it is
// cut, at the chop, heard at that level wherever the chop is; and the Engineer and the Director
// answering one that was not with the chop's own level.

@MainActor
enum ChopLevelFixture {
    /// A song in a package, holding a bar of real audio as its media. `scale` is the bar's level
    /// against the clean bar's own.
    static func app(_ label: String, scale: Float) throws -> (app: AppState, directory: URL, media: MediaRef) {
        let (app, directory, _) = CompletenessFixture.app(label)
        let song = Song(title: "Quiet", tempo: ChopLaneFixtures.bpm)
        app.open(song)
        app.save()
        let package = try #require(app.store).songStore(for: song.id)
        let scratch = directory.appendingPathComponent("bar-\(UUID().uuidString).wav")
        let bar = ChopLaneFixtures.cleanBar().map { $0 * scale }
        try ChopAudio.writeWAV([bar, bar], to: scratch, sampleRate: ChopLaneFixtures.sampleRate)
        return (app, directory, try package.addMedia(copying: scratch))
    }

    static func chop(_ media: MediaRef, gainDB: Double? = nil) -> PartVersion {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let sample = Sample(media: media, slices: lane.sliceMarkers, detectedTempo: ChopLaneFixtures.bpm,
                            span: SongGraph.TimeRange(start: 0, end: ChopLaneFixtures.barLength), gainDB: gainDB)
        return PartVersion(partID: PartID(), kind: .sample(sample), author: .user, operation: Operation.chop, note: "Bar 1 of other stem")
    }

    static func gain(of version: PartVersion?) -> Double? {
        guard case .sample(let sample)? = version?.kind else { return nil }
        return sample.gainDB
    }

    static func rms(_ planar: [[Float]]) -> Double {
        let channel = planar.first ?? []
        return (channel.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, channel.count))).squareRoot()
    }
}

/// The loop the transport would play for a chop, as one number.
@AudioActor
private func loopRMS(_ track: SongPlayback.ChopTrack) throws -> Double {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: ChopLaneFixtures.sampleRate, channels: 2) else { return 0 }
    let buffer = try LiveSongPlayer.dustyChop(track, format: format)
    guard let data = buffer.floatChannelData else { return 0 }
    let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
    return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
}

@Suite("A quiet chop has a level of its own", .serialized) @MainActor
struct ChopLevelTests {

    @Test("a bar far under where an instrument sits asks for the gap, as far as its peak allows; a loud one asks for nothing")
    func theRule() {
        let quiet = ChopLevel.Reading(loudnessDBFS: -30, peakDBFS: -22)
        #expect(quiet.gainDB == 16, "to −14")
        #expect(ChopLevel.Reading(loudnessDBFS: -30, peakDBFS: -10).gainDB == 9, "held by the ceiling at −1")
        #expect(ChopLevel.Reading(loudnessDBFS: -60, peakDBFS: -50).gainDB == 24, "and never by more than 24")
        #expect(ChopLevel.Reading(loudnessDBFS: -18, peakDBFS: -6).gainDB == nil, "4 dB under is loud enough")
        #expect(ChopLevel.Reading(loudnessDBFS: -8, peakDBFS: -0.5).gainDB == nil, "a bar of a mastered record is left alone")

        let bar = ChopLaneFixtures.cleanBar()
        let loud = try! #require(ChopLevel.read([bar, bar], sampleRate: ChopLaneFixtures.sampleRate))
        let soft = try! #require(ChopLevel.read([bar.map { $0 * 0.05 }], sampleRate: ChopLaneFixtures.sampleRate))
        #expect(abs((loud.loudnessDBFS - soft.loudnessDBFS) - 26.02) < 0.1 && abs((loud.peakDBFS - soft.peakDBFS) - 26.02) < 0.1)
        #expect(ChopLevel.read([[Float](repeating: 0, count: 4_800)], sampleRate: 48_000) == nil, "silence has no level to bring up")

        // Crackle: a few samples of a 78's surface far over the music do not hold the bar down,
        // and are held at the ceiling once it is brought up.
        var crackled = bar.map { $0 * 0.05 }
        for index in stride(from: 1_000, to: crackled.count, by: crackled.count / 20) { crackled[index] = 0.5 }
        let read = try! #require(ChopLevel.read([crackled], sampleRate: ChopLaneFixtures.sampleRate))
        #expect(abs(read.peakDBFS - soft.peakDBFS) < 0.5 && abs((read.gainDB ?? 0) - (soft.gainDB ?? 99)) < 1.5, "\(read) against \(soft)")
        let levelled = AudioRegion.Span(planar: [crackled], sampleRate: ChopLaneFixtures.sampleRate).levelled(by: read.gainDB)
        let reach = levelled.planar[0].map(abs).max() ?? 0
        #expect(abs(20 * log10(Double(reach)) - ChopLevel.ceilingDBFS) < 0.01, "nothing over the ceiling: \(reach)")
        #expect(AudioRegion.Span(planar: [crackled], sampleRate: 48_000).levelled(by: nil).planar[0] == crackled, "as recorded is untouched")
    }

    @Test("a chop that plays as recorded is written as it always was; a level round-trips")
    func coding() throws {
        let plain = Sample(media: ChopLaneFixtures.media, slices: [SliceMarker(position: 0)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("gainDB"))
        var levelled = plain
        levelled.gainDB = 16
        #expect(try JSONDecoder().decode(Sample.self, from: try encoder.encode(levelled)) == levelled)
    }

    @Test("a quiet bar is brought up as it is cut, the rail says by how much, and the transport plays it at that level")
    func levelledAsItIsCut() async throws {
        let (app, directory, media) = try ChopLevelFixture.app("level-cut", scale: 0.05)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cut = ChopLevelFixture.chop(media)
        #expect(app.record(cut))
        let kept = try #require(app.song?.version(cut.id))
        let gain = try #require(ChopLevelFixture.gain(of: kept))
        let reading = try #require(app.chopReading(cut))
        #expect(gain == reading.gainDB && gain > 15 && gain <= 24, "\(gain)")
        let line = try #require(app.log.last { $0.text.hasPrefix("Bar 1 of other stem is quiet: brought up") })
        #expect(line.detail?.contains("Nothing in the mix moved") == true)

        // The loop the song plays is that much louder than the bar on disk, and so is the kit a
        // groove on its slices plays.
        let track = try #require(app.chopTrack(cut.partID))
        #expect(track.gainDB == gain)
        var asRecorded = track
        asRecorded.gainDB = nil
        let levelled = try await loopRMS(track), recorded = try await loopRMS(asRecorded)
        #expect(abs(20 * log10(levelled / recorded) - gain) < 0.1)
        #expect(abs(20 * log10(ChopLevelFixture.rms(try ChopGroove.prepare(track).playing)
                               / ChopLevelFixture.rms(try ChopGroove.prepare(asRecorded).playing)) - gain) < 0.1)
    }

    @Test("a bar that is loud enough comes in exactly as it was, and so does a later version of a chop")
    func loudIsLeft() throws {
        let (app, directory, media) = try ChopLevelFixture.app("level-loud", scale: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cut = ChopLevelFixture.chop(media)
        #expect(app.record(cut))
        #expect(app.song?.version(cut.id) == cut)
        #expect(!app.log.contains { $0.text.contains("is quiet") })

        // Only a chop new to the song is measured: a version of one that plays as recorded stays so.
        let (quiet, quietDirectory, quietMedia) = try ChopLevelFixture.app("level-later", scale: 0.05)
        defer { try? FileManager.default.removeItem(at: quietDirectory) }
        // Kept as an arrangement is, not recorded: a chop from before chops were levelled.
        let old = ChopLevelFixture.chop(quietMedia)
        #expect(quiet.keep([old], arranged: []))
        let next = old.deriving(old.kind, by: .user, operation: Operation.chop, note: old.note)
        #expect(quiet.record(next))
        #expect(ChopLevelFixture.gain(of: quiet.song?.version(next.id)) == nil)
    }

    @Test("a chop the song already holds is levelled as its next version, and put back as recorded the same way")
    func levelledLater() throws {
        let (app, directory, media) = try ChopLevelFixture.app("level-later-move", scale: 0.05)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ChopLevelFixture.chop(media)
        #expect(app.keep([old], arranged: []))

        let level = try #require(app.levelChop(old.partID))
        let newest = try #require(app.song?.latestVersion(of: old.partID))
        #expect(newest.operation == Operation.level && newest.parents == [old.id] && ChopLevelFixture.gain(of: newest) == level)
        #expect(app.levelChop(old.partID) == nil, "already there")
        #expect(app.levelChop(old.partID, to: 0) == 0)
        #expect(ChopLevelFixture.gain(of: app.song?.latestVersion(of: old.partID)) == nil)
    }

    @Test("the lane keeps a chop's level through a re-cut")
    func theLaneCarriesIt() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        let first = try lane.commitChop(note: "Bar 1")
        guard case .sample(var sample) = first.kind else { Issue.record("not a sample"); return }
        sample.gainDB = 12
        let levelled = first.deriving(.sample(sample), by: .user, operation: Operation.level, note: first.note)
        #expect(host.record(levelled))
        lane.override(slice: 1, as: .kick)
        let recut = try lane.commitChop(note: "Bar 1")
        #expect(recut.parents == [levelled.id] && ChopLevelFixture.gain(of: recut) == 12)
    }

    @Test("the Engineer answers a quiet chop at the chop: it is flagged first, and the master is not offered until it is levelled")
    func theEngineerFlagsIt() throws {
        let observation = MixObservation(label: "Quiet", integratedLUFS: -32.8, peakDBFS: -11.2, crestDB: 14, tiltDB: 0, bandwidthHz: 16_000)
        let chop = PartID()
        let quiet = QuietChop(part: chop, label: "Bar 1 of other stem", loudnessDBFS: -30, gainDB: 16)
        let flagged = CriticBoard.standard.review(MixReview(observation: observation, master: Master(), quietChops: [quiet]))
        #expect(flagged.map(\.critic) == [.quietSource], "\(flagged.map(\.headline))")
        #expect(flagged[0].headline == "Bar 1 of other stem is quiet at its source: -30 dBFS at its loudest")
        #expect(flagged[0].fixes[0].title == "Level Bar 1 of other stem +16 dB, at the chop")
        #expect(flagged[0].fixes[0].change == .levelChop(part: chop, gainDB: 16) && flagged[0].fixes[1].change == .accept)
        // With nothing quiet at its source, an under-target master is the master's, as before.
        let plain = CriticBoard.standard.review(MixReview(observation: observation, master: Master()))
        #expect(plain.map(\.critic) == [.hotMaster])
    }

    @Test("the plan's quiet chops are found once each, and not once they are levelled; level_chop levels one by name")
    func theDirectorLevelsIt() async throws {
        let (app, directory, media) = try ChopLevelFixture.app("level-tool", scale: 0.05)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ChopLevelFixture.chop(media)
        // A groove on its slices and the loop itself, in one section: one chop, found once.
        let groove = old.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove, note: "Lo-Fi Hip-Hop on Bar 1 of other stem")
        #expect(app.keep([old, groove, ChopGrooveFixture.pick(ChopSound.id(for: old.partID), for: groove.partID)],
                         arranged: [Section(name: "Intro", stitch: [groove.partID, old.partID].lanes, lengthInBars: 4)]))

        let quiet = ChopLevel.quiet(in: app.playback)
        #expect(quiet.map(\.part) == [old.partID] && quiet.first?.label == "Bar 1 of other stem")
        let asks = try #require(quiet.first?.gainDB)

        let tool = LevelChopTool(workspace: AppStateWorkspace(app))
        let output = try await tool.run(.init(part: "bar 1 of other stem", asRecorded: false))
        #expect(output.gainDB == asks && output.part == old.partID.description)
        let newest = try #require(app.song?.latestVersion(of: old.partID))
        #expect(newest.author == .persona("Director") && ChopLevelFixture.gain(of: newest) == asks)
        #expect(ChopLevel.quiet(in: app.playback).isEmpty)
        #expect(app.playback.segments.first?.voices.compactMap { $0.kit?.gainDB ?? $0.chop?.gainDB } == [asks, asks], "the groove's kit and the loop")

        await #expect(throws: DirectorToolFailure.self) { _ = try await tool.run(.init(part: "bar 1 of other stem", asRecorded: false)) }
        #expect(try await tool.run(.init(part: old.partID.description, asRecorded: true)).gainDB == 0)
        #expect(DirectorTools.names.last == "level_chop" && DirectorPrompt.system.contains("level_chop"))
    }
}
