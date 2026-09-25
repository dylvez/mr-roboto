import AVFAudio
import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph

/// The Booth's and the Takes surface's host: the frame's transport and engine, the song's package
/// for media, and `AppState.record` for versions.
@MainActor
final class BoothAdapter: BoothHosting, TakesHosting {
    private let app: AppState
    private let service: AuditionService

    init(app: AppState, service: AuditionService) {
        self.app = app
        self.service = service
    }

    // MARK: BoothHosting

    var song: Song? { app.song }
    var clock: TransportClock { app.clock }
    var isPlaying: Bool { app.transport.isPlaying }
    var playhead: Double { app.playhead }

    func play() async { await app.startTransport() }
    func play(from section: SectionID?) async { await app.startTransport(fromSection: section) }
    func play(from section: SectionID?, countInBars: Int, click: Bool) async {
        await app.startTransport(fromSection: section, countInBars: countInBars, click: click)
    }
    func stop() async { await app.stopTransport() }

    /// The Takes surface's way into the Booth, on the song's active section.
    func openBooth() { app.perform(Guidance.dockAction(for: .booth, in: app.song)) }

    func recorder() async throws -> Recorder {
        let engine = try await app.engine()
        let choice = input
        let device = choice.device(in: inputs)
        // The transport counts from where it started; a take is placed in the song. When the song
        // was started from a section, the recorder is handed a transport whose zero is the song's
        // top, so the take's alignment is a song time and lands on the bar it was sung on.
        let offset = app.playbackStartBar != 0 ? app.clock.seconds(forBar: app.playbackStartBar) : 0
        return try await Self.recorder(on: engine, uid: device?.uid, channel: choice.channel(on: device),
                                       deviceName: device?.name ?? "Input", songOffset: offset)
    }

    var inputs: [AudioInputDevice] { AudioDevices.inputs() }

    var input: InputChoice {
        get { InputSettings().choice }
        set { InputSettings().choice = newValue }
    }

    @AudioActor
    private static func recorder(on engine: Engine, uid: String?, channel: Int?, deviceName: String,
                                 songOffset: Double = 0) throws -> Recorder {
        guard let transport = engine.transport else { throw RecorderError.notRecording }
        // The chosen device on the input node; a device that cannot be set leaves the default, and the take says which.
        var name = deviceName
        do { try engine.setInputDevice(uid: uid) } catch { name = "Input" }
        return Recorder(source: InputNodeSource(engine: engine.avEngine, channel: channel, deviceName: name),
                        transport: Self.shifted(transport, by: songOffset))
    }

    /// The same transport with its zero `seconds` earlier, so a time read against it is a song
    /// time when the engine started partway through the song. The engine keeps its own.
    /// Negative `seconds` — a transport started during a count-in, before the song's first bar —
    /// moves zero later.
    nonisolated static func shifted(_ transport: Transport, by seconds: Double) -> Transport {
        guard seconds != 0 else { return transport }
        var clock = transport.clock
        if let start = clock.startHostTime {
            let ticks = TransportClock.hostTicks(forSeconds: abs(seconds))
            clock.startHostTime = seconds > 0 ? (ticks > start ? 0 : start - ticks) : start &+ ticks
        }
        return Transport(clock: clock, mode: transport.mode,
                         originSampleTime: transport.originSampleTime - clock.frame(forSeconds: seconds))
    }

    func scratchURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MrRoboto/takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("take-\(UUID().uuidString).wav")
    }

    func keep(_ recording: Recorder.Recording, take: Take) -> PartVersion? {
        guard let song = app.song else { return nil }
        guard let media = store(recording.url, in: song) else { return nil }
        let audio = Audio(media: media, role: .take, sampleRate: recording.sampleRate, channelCount: recording.channelCount,
                          duration: recording.duration, alignmentOffset: recording.alignmentSeconds, take: take)
        // Takes of one section are one part: the second take is a version of the first's part.
        let partID = Guidance.takes(in: song).last { Guidance.audio(of: $0)?.take?.section == take.section }?.partID ?? PartID()
        let sectionName = take.section.flatMap { id in song.sections.first { $0.id == id }?.name }
        let version = PartVersion(partID: partID, kind: .audio(audio), author: .user, operation: Operation.recorded,
                                  note: "Take \(take.pass)\(sectionName.map { ", \($0)" } ?? ""), from bar \(take.startBar + 1)")
        guard app.record(version) else { return nil }
        try? FileManager.default.removeItem(at: recording.url)
        return version
    }

    func note(_ text: String, detail: String?) { app.note(.session, text, detail: detail) }

    func recordingStarted(section: SectionID?, startedAt: Double) {
        let midi = SurfaceWiring.shared.midi(for: app)
        guard midi.mode != .off else { return }
        Task {
            guard let clock = await songClock() else { return }
            midi.beginCapture(section: section, clock: clock, startedAt: startedAt)
        }
    }

    /// The running transport's clock with its zero at the song's top, so a host time read against
    /// it is a song time — as the recorder reads a take. The controller's capture used the engine's
    /// own clock, whose zero is wherever playback started; since the Booth plays from the section
    /// it records, every note played into the Verse was measured from the Verse and then placed as
    /// if from the top, and a counted-in take lost its notes before the section altogether.
    func songClock() async -> TransportClock? {
        guard let engine = try? await app.engine(), let transport = await engine.transport else { return nil }
        let offset = app.playbackStartBar != 0 ? app.clock.seconds(forBar: app.playbackStartBar) : 0
        return Self.shifted(transport, by: offset).clock
    }

    func recordingEnded(endedAt: Double) {
        SurfaceWiring.shared.midi(for: app).endCapture(endedAt: endedAt)
    }

    /// Media into the song's package, saving the song first when it has no package yet.
    private func store(_ url: URL, in song: Song) -> MediaRef? {
        app.keepMedia(copying: url, what: "the take")
    }

    // MARK: TakesHosting

    var key: Key? { app.song?.key }

    func openCheck(_ finding: Finding, on take: PartVersion) {
        let id = app.openSurface(.check, title: "\(finding.criticName): \(PartLabel.title(of: take)), \(finding.subject.named)", bound: [take.id])
        app.file(.check(finding), for: id)
        app.note(.persona(Cast.standard.persona(finding.persona)?.bible.name ?? finding.persona.rawValue), finding.headline,
                 detail: "\(finding.why) \(finding.measurement.description)")
    }

    func audio(of version: PartVersion) -> Comp.TakeAudio? {
        guard let audio = Guidance.audio(of: version), let store = app.store,
              let url = try? store.mediaURL(for: audio.media, song: app.song?.id),
              let planar = try? Self.planar(url) else { return nil }
        let aligned = audio.alignmentOffset ?? audio.take.map { clock.seconds(forBar: $0.startBar) + $0.startBeat * clock.secondsPerBeat } ?? 0
        return Comp.TakeAudio(planar: planar.planar, sampleRate: planar.sampleRate, alignmentSeconds: aligned)
    }

    nonisolated static func planar(_ url: URL) throws -> (planar: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return ([], format.sampleRate) }
        let frames = Int(buffer.frameLength)
        let planar = (0..<Int(format.channelCount)).map { channel in Array(UnsafeBufferPointer(start: data[channel], count: frames)) }
        return (planar, format.sampleRate)
    }

    func audition(_ version: PartVersion) async {
        guard let take = audio(of: version) else {
            app.note(.session, "\(PartLabel.title(of: version)) has no audio to play")
            return
        }
        await service.play(planar: take.planar, sampleRate: take.sampleRate)
    }

    func stopAudition() { Task { await service.stop() } }

    func audition(_ rendered: Comp.Rendered) async {
        await service.play(planar: rendered.planar, sampleRate: rendered.sampleRate)
    }

    func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion? {
        guard app.song != nil, let first = takes.first else { return nil }
        guard let media = app.keepAudio(rendered.planar, sampleRate: rendered.sampleRate, what: "the comp") else { return nil }
        let duration = Double(rendered.planar.first?.count ?? 0) / rendered.sampleRate
        let audio = Audio(media: media, role: .take, sampleRate: rendered.sampleRate, channelCount: rendered.planar.count,
                          duration: duration, alignmentOffset: rendered.alignmentSeconds, comp: plan)
        let version = PartVersion(partID: first.partID, kind: .audio(audio), author: .user, parents: takes.map(\.id),
                                  operation: Operation.comped,
                                  note: "Comp of \(takes.count) take\(takes.count == 1 ? "" : "s"): " + plan.spans.map { span in
                                      let name = takes.first { $0.id == span.take }.map(PartLabel.title(of:)) ?? "?"
                                      return span.endBar - span.startBar == 1 ? "bar \(span.startBar + 1) \(name)" : "bars \(span.startBar + 1)–\(span.endBar) \(name)"
                                  }.joined(separator: ", "))
        guard app.record(version) else { return nil }
        return version
    }

    nonisolated static func write(_ planar: [[Float]], sampleRate: Double, to url: URL) throws {
        let channels = AVAudioChannelCount(max(1, planar.count))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = planar.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let lane = planar[min(channel, planar.count - 1)]
            for i in 0..<frames { buffer.floatChannelData![channel][i] = lane[i] }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
