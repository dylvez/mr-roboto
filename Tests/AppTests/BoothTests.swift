import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M5 R3–R5: the Booth keeps a take on the bar it was sung on; Takes comps them; Sing is on the path.

/// A Booth's host with no engine: buffers for a recorder, a song to keep takes in, and a transport
/// that starts where it is told. Shared with `SingingTests`.
@MainActor
final class StubBoothHost: BoothHosting, TakesHosting {
    var song: Song?
    var clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: 48_000)
    var isPlaying = false
    var playhead = 0.0
    var kept: [PartVersion] = []
    var comps: [(Comp.Rendered, CompPlan)] = []
    var audioByVersion: [VersionID: Comp.TakeAudio] = [:]
    var notes: [String] = []
    var buffers: [(AVAudioPCMBuffer, AVAudioTime)] = []
    var transport: Transport?

    init(song: Song) { self.song = song }

    func play() async { isPlaying = true; playhead = 0 }
    /// What Record asked for, in order.
    var plays: [(section: SectionID?, countInBars: Int, click: Bool)] = []
    /// Starts in song time, as the app's transport does: the count-in reads before the section's
    /// first bar, below zero when that is the top.
    func play(from section: SectionID?, countInBars: Int, click: Bool) async {
        plays.append((section, countInBars, click))
        var start = 0
        for candidate in song?.sections ?? [] {
            if candidate.id == section { break }
            start += candidate.lengthInBars
        }
        if section == nil || song?.sections.contains(where: { $0.id == section }) != true { start = 0 }
        isPlaying = true
        playhead = clock.seconds(forBar: start) - Double(countInBars) * clock.secondsPerBar
    }
    func stop() async { isPlaying = false }
    func recorder() async throws -> Recorder {
        let source: any RecordingSource = try BufferSource(buffers, latencySeconds: 0.01, name: "Stub mic")
        if let channel = input.channel { return Recorder(source: ChannelSource(source, channel: channel), transport: transport) }
        return Recorder(source: source, transport: transport)
    }
    var inputs: [AudioInputDevice] = [
        AudioInputDevice(id: 1, name: "MacBook Pro Microphone", uid: "builtin", inputChannels: 1, isDefault: true),
        AudioInputDevice(id: 2, name: "Scarlett 2i2", uid: "scarlett", inputChannels: 2, isDefault: false),
    ]
    var input = InputChoice()
    func scratchURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("booth-\(UUID().uuidString).wav") }
    func keep(_ recording: Recorder.Recording, take: Take) -> PartVersion? {
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "a", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: recording.sampleRate, channelCount: recording.channelCount, duration: recording.duration,
                          alignmentOffset: recording.alignmentSeconds, take: take)
        let partID = kept.last?.partID ?? PartID()
        let version = PartVersion(partID: partID, kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take \(take.pass)")
        kept.append(version)
        try? song?.append(version)
        return version
    }
    func note(_ text: String, detail: String?) { notes.append(text) }
    var key: Key? { song?.key }
    var checks: [(Finding, PartVersion)] = []
    func openCheck(_ finding: Finding, on take: PartVersion) { checks.append((finding, take)) }
    func audio(of version: PartVersion) -> Comp.TakeAudio? { audioByVersion[version.id] }
    func audition(_ version: PartVersion) async {}
    var heard: [Comp.Rendered] = []
    func audition(_ rendered: Comp.Rendered) async { heard.append(rendered) }
    func stopAudition() {}
    func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion? {
        comps.append((rendered, plan))
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "b", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: rendered.sampleRate, channelCount: rendered.planar.count,
                          duration: Double(rendered.planar[0].count) / rendered.sampleRate, alignmentOffset: rendered.alignmentSeconds, comp: plan)
        return PartVersion(partID: takes[0].partID, kind: .audio(audio), author: .user, parents: takes.map(\.id), operation: Operation.comped, note: "Comp")
    }
}

/// Waits for the model's own tasks — the meter's poll, an audition's end — to land.
@MainActor
private func settle(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private func tone(frames: Int, rate: Double, hz: Double) -> AVAudioPCMBuffer {

    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.4 * sin(2 * .pi * hz * Double(i) / rate)) }
    return buffer
}

@Suite("Booth: a take lands on its bar", .serialized) @MainActor
struct BoothTests {

    /// These tests are about where a take lands, on a stub whose transport never moves, so they
    /// sing with no count-in. The Booth reads its settings when it is made, so the domain that
    /// said "off" is gone again before the test runs. (Not `register(defaults:)`: that domain is
    /// the whole process's, and would reach every other Booth under test.)
    private func booth(_ host: StubBoothHost) -> BoothModel {
        let suite = "booth-tests-\(UUID().uuidString)"
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

    @Test("record while the song plays, stop, and the take is a version with its bar, pass and section")
    func aTake() async throws {
        let host = StubBoothHost(song: song())
        // An offline transport whose origin is frame 0: buffers stamped from bar 2 (4 s at 120).
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        let start = host.clock.frame(forBar: 2)
        host.buffers = (0..<4).map { i in (tone(frames: 2_048, rate: 48_000, hz: 220), AVAudioTime(sampleTime: start + AVAudioFramePosition(i * 2_048), atRate: 48_000)) }

        let model = booth(host)
        #expect(model.section == host.song?.sections.first?.id)
        #expect(model.sectionBars == 0..<4)
        #expect(model.nextPass == 1)
        model.arm()
        #expect(model.state == .armed)

        await model.record()
        #expect(model.state == .recording && host.isPlaying)
        let version = await model.stopRecording(stopSong: true)
        #expect(model.state == .idle && !host.isPlaying)
        let kept = try #require(version)
        let take = try #require(Guidance.audio(of: kept)?.take)
        // Bar 2, less 10 ms of latency: bar 1, beat 3.98 — the take knows it started a hair early.
        #expect(take.startBar == 1 && take.startBeat > 3.9, "\(take.startBar) \(take.startBeat)")
        #expect(take.pass == 1 && take.section == model.section && take.input == "Stub mic")
        #expect(abs(take.latencyCompensation - 0.01) < 1e-9)
        #expect(model.takes.count == 1 && model.nextPass == 2)
        #expect(Guidance.takes(in: host.song!).count == 1)
        #expect(PartLabel.title(of: version!) == "Take 1")

        // A second take of the same section is the second version of the same part.
        await model.record()
        let second = await model.stopRecording(stopSong: true)
        #expect(second?.partID == version?.partID && Guidance.audio(of: second!)?.take?.pass == 2)
    }

    @Test("a channel chosen on a two-input interface records mono, and the take names the input")
    func channelChoice() async throws {
        let host = StubBoothHost(song: song())
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        host.buffers = (0..<3).map { i in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)!
            buffer.frameLength = 2_048
            for f in 0..<2_048 { buffer.floatChannelData![0][f] = Float(0.4 * sin(2 * .pi * 220 * Double(f) / 48_000)); buffer.floatChannelData![1][f] = 0 }
            return (buffer, AVAudioTime(sampleTime: host.clock.frame(forBar: 1) + AVAudioFramePosition(i * 2_048), atRate: 48_000))
        }
        let model = booth(host)
        #expect(model.inputLine == "MacBook Pro Microphone — the system's default input.")
        model.input = InputChoice(deviceUID: "scarlett", channel: 0)
        #expect(host.input == model.input, "the choice reaches the host")
        #expect(model.inputDevice?.name == "Scarlett 2i2")
        #expect(model.inputLine == "Scarlett 2i2, input 1")
        await model.record()
        let version = try #require(await model.stopRecording(stopSong: true))
        let audio = try #require(Guidance.audio(of: version))
        #expect(audio.channelCount == 1)
        #expect(audio.take?.input == "Stub mic, input 1")
    }

    @Test("the input choice: a missing device falls back to the default and says so; the choice is remembered")
    func inputChoice() throws {
        let devices = StubBoothHost(song: song()).inputs
        let gone = InputChoice(deviceUID: "old-interface", channel: 1)
        #expect(gone.isFallingBack(in: devices) && gone.device(in: devices)?.uid == "builtin")
        #expect(gone.channel(on: gone.device(in: devices)) == nil, "a mono default has no channel to pick")
        #expect(gone.describe(in: devices).hasSuffix("the remembered device is not here, so this is the system's default."))
        #expect(InputChoice(deviceUID: "scarlett", channel: 5).describe(in: devices) == "Scarlett 2i2", "a channel past the device is every channel")
        #expect(InputChoice().describe(in: []) == "No input device is here.")

        let suite = "inputs-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = InputSettings(defaults: defaults)
        #expect(settings.choice == InputChoice())
        settings.choice = InputChoice(deviceUID: "scarlett", channel: 1)
        #expect(InputSettings(defaults: defaults).choice == InputChoice(deviceUID: "scarlett", channel: 1))
        settings.choice = InputChoice()
        #expect(InputSettings(defaults: defaults).choice == InputChoice())
    }

    @Test("with no input the Booth says so and stays idle")
    func noInput() async {
        let host = StubBoothHost(song: song())
        host.buffers = []
        let model = booth(host)
        await model.record()
        #expect(model.state == .idle && model.lastError != nil)
    }

    @Test("the Takes surface chooses bars from takes, plays the comp lane without keeping it, and keeps a comp with the takes as parents")
    func comping() async throws {
        let host = StubBoothHost(song: song())
        let model0 = booth(host)
        // Two takes of the verse (bars 0–4 at 120 = 8 s), placed at 0 by hand.
        func take(_ pass: Int, hz: Double) -> PartVersion {
            let rec = Recorder.Recording(url: URL(fileURLWithPath: "/dev/null"), sampleRate: 48_000, channelCount: 1, frames: 8 * 48_000,
                                         capturedAt: 0, latencySeconds: 0, input: "Stub mic")
            let version = host.keep(rec, take: Take(section: model0.section, startBar: 0, pass: pass))!
            host.audioByVersion[version.id] = Comp.TakeAudio(planar: [(0..<(8 * 48_000)).map { Float(0.3 * sin(2 * .pi * hz * Double($0) / 48_000)) }],
                                                             sampleRate: 48_000, alignmentSeconds: 0)
            return version
        }
        let one = take(1, hz: 220), two = take(2, hz: 330)
        let takes = TakesModel(host: host, takes: [one, two], song: host.song)
        #expect(takes.bars == 0..<4 && takes.sectionName == "Verse")
        #expect(takes.take(forBar: 0) == two.id, "a bar with no choice comes from the newest take")
        takes.choose(one.id, forBars: 0..<2)
        takes.choose(two.id, forBar: 2)
        takes.choose(one.id, forBar: 3)
        let plan = takes.plan
        #expect(plan.spans.map { ($0.startBar, $0.endBar) }.map { "\($0.0)-\($0.1)" } == ["0-2", "2-3", "3-4"])
        #expect(plan.takes == [one.id, two.id])

        // Heard first: the same render, played, and nothing kept.
        await takes.hearComp()
        #expect(takes.isHearingComp && takes.playing == nil)
        #expect(host.heard.count == 1 && host.heard[0].seams.count == 2 && host.comps.isEmpty, "played, not kept")
        #expect(takes.comp == nil && !takes.compIsCurrent)
        takes.stopAudition()
        #expect(!takes.isHearingComp)

        #expect(takes.keepComp(), "\(takes.lastError ?? "")")
        let comp = try #require(takes.comp)
        #expect(comp.operation == Operation.comped && comp.parents == [one.id, two.id] && comp.partID == one.partID)
        #expect(Guidance.audio(of: comp)?.comp?.spans.count == 3)
        #expect(host.comps.first?.0.seams.count == 2)
        #expect(PartLabel.title(of: comp) == "Comp")
    }

    @Test("the Takes surface with nothing bound has no lane and no comp to keep: its empty state is the Booth's door")
    func noTakes() {
        let host = StubBoothHost(song: song())
        let takes = TakesModel(host: host, takes: [], song: host.song)
        #expect(takes.takes.isEmpty, "the view draws the empty note off this")
        #expect(takes.plan.spans.isEmpty)
        #expect(takes.take(forBar: 0) == nil)
        #expect(!takes.keepComp())
        #expect(takes.lastError == "No bars to comp.")
        #expect(host.comps.isEmpty)
    }

    @Test("a take's play control follows the take: it goes back by itself when the take runs out, and a new audition supersedes it")
    func auditionEnds() async throws {
        let host = StubBoothHost(song: song())
        let booth = self.booth(host)
        func take(_ pass: Int, seconds: Double) -> PartVersion {
            let frames = AVAudioFramePosition(seconds * 48_000)
            let rec = Recorder.Recording(url: URL(fileURLWithPath: "/dev/null"), sampleRate: 48_000, channelCount: 1, frames: frames,
                                         capturedAt: 0, latencySeconds: 0, input: "Stub mic")
            return host.keep(rec, take: Take(section: booth.section, startBar: 0, pass: pass))!
        }
        let short = take(1, seconds: 0.1), long = take(2, seconds: 8)
        let takes = TakesModel(host: host, takes: [short, long], song: host.song)

        // The host's audition returns at once; the surface keeps the mark up for the take's length.
        await takes.audition(short)
        #expect(takes.playing == short.id)
        await settle { takes.playing == nil }
        #expect(takes.playing == nil, "a finished take still read as playing")

        // A second audition before the first ends takes over, and the first's end does not clear it.
        await takes.audition(short)
        await takes.audition(long)
        try await Task.sleep(for: .milliseconds(300))
        #expect(takes.playing == long.id, "the short take's end cleared the long take's mark")

        takes.stopAudition()
        #expect(takes.playing == nil)
    }

    @Test("the meter follows the recorder's peak while a take records and rests at zero otherwise")
    func meter() async throws {
        let host = StubBoothHost(song: song())
        host.transport = Transport(clock: host.clock, mode: .offline(sampleRate: 48_000, maximumFrames: 4_096), originSampleTime: 0)
        let start = host.clock.frame(forBar: 2)
        host.buffers = (0..<4).map { i in (tone(frames: 2_048, rate: 48_000, hz: 220), AVAudioTime(sampleTime: start + AVAudioFramePosition(i * 2_048), atRate: 48_000)) }
        let model = booth(host)
        #expect(model.level == 0, "nothing hears the input before a take: the recorder is the only tap on it")

        await model.record()
        await settle { model.level > 0.3 }
        #expect(abs(model.level - 0.4) < 0.01, "the 0.4 tone's peak, buffer by buffer: \(model.level)")

        _ = await model.stopRecording(stopSong: true)
        #expect(model.level == 0, "a stopped take leaves the meter at rest")
    }


    @Test("Sing is the last step on both paths, opens the Booth, then the takes")
    func singOnThePath() {
        var song = self.song()
        // Sing sits before Mix, the last step since M6.
        #expect(WorkPath.of(song).steps.dropLast().last == .sing)
        #expect(WorkPath.beat.steps.dropLast().last == .sing)
        let before = WorkPath.steps(for: song, active: nil, canPerform: { _ in true }).steps
        let sing = before.first { $0.kind == .sing }!
        #expect(sing.count == 0 && sing.action?.surface == .booth)
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "c", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: 48_000, channelCount: 1, duration: 8, alignmentOffset: 0, take: Take(section: song.sections[0].id, startBar: 0))
        try? song.append(PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.recorded, note: "Take 1"))
        let after = WorkPath.steps(for: song, active: (kind: .takes, bound: []), canPerform: { _ in true }).steps
        let sung = after.first { $0.kind == .sing }!
        #expect(sung.count == 1 && sung.isHere && sung.action?.surface == .takes && sung.action?.title == "Verse takes")
        #expect(WorkPath.of(song) == WorkPath.of(self.song()), "a recorded take does not change which path the song is on")
    }
}
