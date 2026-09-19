import AVFAudio
import AudioEngine
import Foundation
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M5 R3–R5: the Booth keeps a take on the bar it was sung on; Takes comps them; Sing is on the path.

@MainActor
private final class StubBoothHost: BoothHosting, TakesHosting {
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
    func stop() async { isPlaying = false }
    func recorder() async throws -> Recorder {
        Recorder(source: try BufferSource(buffers, latencySeconds: 0.01, name: "Stub mic"), transport: transport)
    }
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
    func audio(of version: PartVersion) -> Comp.TakeAudio? { audioByVersion[version.id] }
    func audition(_ version: PartVersion) async {}
    func stopAudition() {}
    func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion? {
        comps.append((rendered, plan))
        let audio = Audio(media: MediaRef(hash: ContentHash(hex: String(repeating: "b", count: 64))!, fileExtension: "wav"), role: .take,
                          sampleRate: rendered.sampleRate, channelCount: rendered.planar.count,
                          duration: Double(rendered.planar[0].count) / rendered.sampleRate, alignmentOffset: rendered.alignmentSeconds, comp: plan)
        return PartVersion(partID: takes[0].partID, kind: .audio(audio), author: .user, parents: takes.map(\.id), operation: Operation.comped, note: "Comp")
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

    private func song() -> Song {
        var song = FormFixture.build(tempo: 120).song
        let ids = [Guidance.grooves(in: song).last!.id, Guidance.basslines(in: song).last!.id]
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

        let model = BoothModel(host: host)
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

    @Test("with no input the Booth says so and stays idle")
    func noInput() async {
        let host = StubBoothHost(song: song())
        host.buffers = []
        let model = BoothModel(host: host)
        await model.record()
        #expect(model.state == .idle && model.lastError != nil)
    }

    @Test("the Takes surface chooses bars from takes and keeps a comp with the takes as parents")
    func comping() throws {
        let host = StubBoothHost(song: song())
        let model0 = BoothModel(host: host)
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
        #expect(takes.keepComp(), "\(takes.lastError ?? "")")
        let comp = try #require(takes.comp)
        #expect(comp.operation == Operation.comped && comp.parents == [one.id, two.id] && comp.partID == one.partID)
        #expect(Guidance.audio(of: comp)?.comp?.spans.count == 3)
        #expect(host.comps.first?.0.seams.count == 2)
        #expect(PartLabel.title(of: comp) == "Comp")
    }

    @Test("Sing is the last step on both paths, opens the Booth, then the takes")
    func singOnThePath() {
        var song = self.song()
        #expect(WorkPath.of(song).steps.last == .sing)
        #expect(WorkPath.beat.steps.last == .sing)
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
