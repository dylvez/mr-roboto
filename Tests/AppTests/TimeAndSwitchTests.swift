import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// Two audits: song time against transport time, and what a song switch leaves running. Each test
// is one of what they found, fixed.

@MainActor
private func waitFor(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<500 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(4))
    }
}

private func tone(frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * .pi * 220 * Double(i) / 48_000)) }
    return buffer
}

@Suite("Time bases: takes, loops and renders read the song's time", .serialized) @MainActor
struct TimeBaseTests {

    private func booth(_ host: StubBoothHost) -> BoothModel {
        let suite = "timebase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(0, forKey: "booth.countInBars")
        let model = BoothModel(host: host, defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        return model
    }

    private func song() -> Song {
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!, Guidance.basslines(in: song).last!].lanes
        song.sections = [Section(name: "Verse", stitch: ids, lengthInBars: 4), Section(name: "Hook", stitch: ids, lengthInBars: 2)]
        return song
    }

    private func arranged() -> (app: AppState, host: StubPlaybackHost, verse: SectionID) {
        let (app, _, _) = CompletenessFixture.app("timebase")
        let groove = TransportFixture.grooveVersion()
        var song = TransportFixture.song([groove])
        song.sections = [Section(name: "Intro", stitch: [Lane(part: groove.partID)], lengthInBars: 4),
                         Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 8)]
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(song)
        return (app, host, song.sections[1].id)
    }

    @Test("Record while the song is already past the chosen section starts it again from the section, and records")
    func recordPastTheSection() async throws {
        let host = StubBoothHost(song: song())
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        host.buffers = (0..<4).map { i in (tone(frames: 2_048), AVAudioTime(sampleTime: AVAudioFramePosition(i * 2_048), atRate: 48_000)) }
        host.isPlaying = true
        host.playhead = host.clock.seconds(forBar: 5)
        let model = booth(host)
        #expect(model.section == host.song?.sections.first?.id)
        await model.record()
        #expect(host.plays.count == 1 && host.plays[0].section == model.section, "started again from the Verse")
        #expect(model.state == .recording, "not punched out at once: \(model.lastError ?? "")")
        #expect(model.finishTake(keeping: false) == nil)
        #expect(model.state == .idle && host.kept.isEmpty, "let go, not kept")
    }

    @Test("A section rendered on its own takes the takes with it: the Hook's take at 0, the Verse's gone")
    func sectionRenderMovesTheTakes() throws {
        let groove = TransportFixture.grooveVersion()
        var song = TransportFixture.song([groove], sections: [
            Section(name: "Verse", stitch: [Lane(part: groove.partID)], lengthInBars: 4),
            Section(name: "Hook", stitch: [Lane(part: groove.partID)], lengthInBars: 2),
        ])
        let hookTake = Audio(media: GuidanceFixture.media("c"), role: .take, sampleRate: 48_000, channelCount: 1,
                             duration: 4, alignmentOffset: 8, take: Take(section: song.sections[1].id, startBar: 4))
        let verseTake = Audio(media: GuidanceFixture.media("d"), role: .take, sampleRate: 48_000, channelCount: 1,
                              duration: 8, alignmentOffset: 0, take: Take(section: song.sections[0].id, startBar: 0))
        try song.append(PartVersion(partID: PartID(), kind: .audio(hookTake), author: .user, operation: Operation.recorded, note: "Hook take"))
        try song.append(PartVersion(partID: PartID(), kind: .audio(verseTake), author: .user, operation: Operation.recorded, note: "Verse take"))
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null")))
        let (isolated, label, bars) = try SectionBounce.isolate(plan, section: song.sections[1].id)
        #expect(label == "Hook" && bars == 2)
        #expect(isolated.segments.map(\.startBar) == [0] && isolated.lengthInBars == 2)
        #expect(isolated.tracks.count == 1, "\(isolated.tracks.map { ($0.name, $0.startsAt) })")
        #expect(isolated.tracks.first.map { abs($0.startsAt) < 1e-9 && $0.skip == 0 } == true, "the Hook's take on the render's first bar")
    }

    @Test("A counted-in take's length is what is scheduled: the file after its skipped head")
    func durationAfterTheSkip() {
        let audio = Audio(media: GuidanceFixture.media("e"), role: .take, sampleRate: 48_000, channelCount: 1,
                          duration: 10, alignmentOffset: -2, take: Take(startBar: 0))
        let song = TransportFixture.song([PartVersion(partID: PartID(), kind: .audio(audio), author: .user,
                                                      operation: Operation.recorded, note: "Take 1")])
        let plan = SongPlayback.plan(for: song, mediaURL: TransportFixture.resolver(URL(fileURLWithPath: "/dev/null")))
        let track = plan.tracks[0]
        #expect(plan.audioDuration.map { abs($0 - (track.startsAt + track.duration - track.skip)) < 1e-9 } == true)
    }

    @Test("A counted-in run is one pass, counts in to its own section, and is named for it")
    func countedInIsOnePass() async {
        let (app, host, verse) = arranged()
        app.toggleLoop()
        await app.startTransport(fromSection: verse, countInBars: 1, click: false)
        let plan = await host.began.last
        #expect(plan?.loops == false && plan?.countInBars == 1, "a take is one pass")
        #expect(app.countInTargetBar == 4 && app.isCountingIn)
        #expect(app.positionText == "In 1", "counting in to the Verse, not only to bar 1")
        #expect(app.log.last(where: { $0.source == .you })?.text == "Play from Verse", "named for the Verse, not the count-in bar")
        await app.stopTransport()
        #expect(app.countInTargetBar == nil && !app.isCountingIn)
    }

    @Test("Looping, the readout comes round with the form instead of counting past the song's end")
    func loopingReadoutComesRound() async {
        let (app, host, verse) = arranged()
        app.toggleLoop()
        await app.startTransport(fromSection: verse)
        #expect(app.isRunningALoop)
        // From the Verse the loop is 8 bars, 16 s at 120: 18 engine seconds is the Verse's bar 2.
        await host.report(PlaybackReading(isRunning: true, seconds: 18))
        await waitFor { abs(app.playhead - 10) < 0.01 }
        #expect(abs(app.playhead - 10) < 0.01, "\(app.playhead)")
        #expect(app.positionText == "6.1" && app.activeSection == verse)
        await app.stopTransport()
    }
}

@Suite("Switching songs: what was running ends with its song", .serialized) @MainActor
struct SongSwitchTests {

    @Test("Opening another song stops the transport, and the engine's stop follows")
    func switchingStopsTheTransport() async {
        let (app, _, _) = CompletenessFixture.app("switch-transport")
        let host = StubPlaybackHost()
        app.attach(playback: host)
        app.open(CompletenessFixture.song("Arrival"))
        await app.startTransport()
        #expect(app.transport.isPlaying)
        app.open(CompletenessFixture.song("Night Bus"))
        #expect(!app.transport.isPlaying && app.playbackStartBar == 0 && app.playhead == 0)
        for _ in 0..<100 {
            if await host.ended > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let ended = await host.ended
        #expect(ended == 1, "the old song's player was ended")
        await app.startTransport()
        let began = await host.began.count
        #expect(app.transport.isPlaying && began == 2, "and the new one starts after it")
        await app.stopTransport()
    }

    @Test("A song whose save fails stays open rather than dropping what it could not write")
    func failedSaveStaysOpen() {
        let nowhere = URL(fileURLWithPath: "/dev/null/nowhere", isDirectory: true)
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: nowhere), status: .empty(nowhere),
                           transportHost: StubTransportHost())
        app.autosaveDelay = nil
        app.open(CompletenessFixture.song("Arrival"))
        #expect(app.setTempo(84))
        #expect(app.hasUnsavedChanges)
        app.open(CompletenessFixture.song("Night Bus"))
        #expect(app.song?.title == "Arrival", "still open")
        #expect(app.song?.tempo == 84 && app.hasUnsavedChanges, "and still holding the change")
        #expect(app.log.contains { $0.text == "Arrival could not be saved, so it stays open" })
    }

    @Test("Work for a song that is not open lands in that song's package, not the open one")
    func lateWorkLandsInItsOwnSong() {
        let (app, directory, _) = CompletenessFixture.app("switch-late")
        defer { try? FileManager.default.removeItem(at: directory) }
        let arrival = CompletenessFixture.song("Arrival")
        app.open(arrival)
        app.save()
        app.open(CompletenessFixture.song("Night Bus"))
        let before = app.song!.versions.count
        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [NoteEvent(pitch: Pitch(midi: 72), start: 0, duration: 1)])),
                               author: .user, operation: Operation.written, note: "Tune")
        #expect(app.record(tune, intoLibrarySong: arrival.id))
        #expect(app.song?.title == "Night Bus" && app.song!.versions.count == before, "the open song is untouched")
        #expect(app.library.song(arrival.id)?.versions.contains { $0.id == tune.id } == true)
        #expect(app.log.last?.text == "Tune is in Arrival")
    }
}

/// A transport that holds the request until released, then fails it: a turn suspended mid-flight.
private actor HeldTransport: ClaudeTransport {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse {
        entered = true
        await withCheckedContinuation { waiting = $0 }
        throw ClaudeError.transport("released")
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

@Suite("Director: a thread cleared under a turn stays cleared")
struct DirectorClearedThreadTests {
    @Test("the song changes while a turn waits on the model: when the turn unwinds, it does not write the old thread back")
    func clearedStaysCleared() async throws {
        let transport = HeldTransport()
        let client = ClaudeClient(keySource: DirectorTestClient.key, transport: transport,
                                  sleeper: DirectorRecordingSleeper(), retry: .none)
        let conversation = DirectorConversation(client: client, toolbox: DirectorToolbox([]))
        let turn = Task { try await conversation.ask("make the hook louder") }
        for _ in 0..<500 {
            if await transport.entered { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await transport.entered)
        await conversation.clear()
        await transport.release()
        _ = try? await turn.value
        let messages = await conversation.messages
        #expect(messages.isEmpty, "the old song's thread came back: \(messages.count) turns")
    }
}
