import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// The transport, actually playing.
///
/// `SongPlayback` decides *what*; this decides *how*, and it does so through the one
/// `AuditionService` rather than building a second engine. That is the whole reason it lives beside
/// the service instead of inside `AppState`: the service already owns the app's single
/// `AudioEngine.Engine` and its single `Instrument.VoiceSampler`, attached once and only ever handed
/// new kits. A transport that built its own graph would be a second `AVAudioEngine` contending with
/// the surfaces for one output device, which is exactly the failure `AuditionService` was written to
/// prevent.
///
/// What it schedules:
///
/// * a **groove** becomes a `Performance.GroovePlayer` on the shared sampler, added to the engine as
///   a `ScheduledSource` so the engine's own look-ahead drives it — the same path `GroovePlayerTests`
///   exercises, and the same one a Grid pattern loops through;
/// * each **audio track** becomes an `AudioTrackSource` on one of the engine's player nodes, placed
///   at its transport time.
///
/// Both are ordinary `ScheduledSource`s, which means the whole thing works identically in manual
/// rendering mode. This shell has no audio device, so that is not a nicety: it is the only way any
/// of this is verified (`TransportPlaybackTests` renders a started transport offline and asks
/// whether samples came out at the frames they were scheduled for).
@AudioActor
final class LiveSongPlayer: SongPlaybackHost {

    /// What went wrong, in words the frame can show.
    enum Failure: Error, CustomStringConvertible {
        case nothingScheduled
        case unreadable(String, String)

        var description: String {
            switch self {
            case .nothingScheduled:
                return "nothing in the plan could be scheduled"
            case .unreadable(let name, let reason):
                return "\(name) could not be read: \(reason)"
            }
        }
    }

    private let service: AuditionService

    private var engine: Engine?
    private var groovePlayer: GroovePlayer?
    private var tracks: [AudioTrackSource] = []
    /// Hits a dusty groove's bounce held, reported as scheduled: the bounce is the groove, so the
    /// reading must not say nothing was scheduled because no `GroovePlayer` was involved.
    private var bouncedHits = 0
    /// Transport seconds at which the plan runs out, or nil when it loops forever.
    private var endsAt: Double?

    nonisolated init(service: AuditionService) {
        self.service = service
    }

    // MARK: SongPlaybackHost

    func begin(_ plan: SongPlayback, clock: TransportClock) async throws {
        await end()
        let engine = try await service.playbackEngine()
        self.engine = engine

        if let groove = plan.groove, plan.grooveChain.isEmpty {
            let machine = SynthMachine.preset(id: plan.machine) ?? .tr808
            let sampler = try await service.playbackSampler(machine: machine)
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature)
            let player = GroovePlayer(sampler: sampler, groove: groove, timeline: timeline)
            // With the loop off, a groove plays the song's own length and stops; with it on it plays
            // until you stop it. `GroovePlayer` rounds bars up to whole iterations, because a feel
            // is a phrase and half of one is not a feel.
            player.bars = plan.loops ? nil : plan.lengthInBars
            engine.add(player)
            groovePlayer = player
        }

        for (index, track) in plan.tracks.enumerated() {
            guard index < engine.players.count else { break }
            let buffer: AVAudioPCMBuffer
            do {
                buffer = try Self.read(track.url, in: engine.format)
            } catch {
                throw Failure.unreadable(track.name, "\(error)")
            }
            let source = AudioTrackSource(player: try engine.player(index),
                                          buffer: buffer,
                                          startsAt: track.startsAt,
                                          loops: plan.loops)
            engine.add(source)
            tracks.append(source)
        }

        // The dusty sources, on the player nodes after the tracks. `SongPlayback.plan` left room
        // for them; a hand-built plan that did not is told so rather than silently dropping one.
        var next = tracks.count
        if let groove = plan.groove, !plan.grooveChain.isEmpty {
            guard next < engine.players.count else { throw Failure.unreadable("The dusty groove", "no player node is free") }
            let bounce = try await Self.dustyGroove(groove, plan: plan, clock: clock, service: service,
                                                    format: engine.format)
            let source = AudioTrackSource(player: try engine.player(next), buffer: bounce.buffer,
                                          startsAt: 0, loops: plan.loops)
            engine.add(source)
            tracks.append(source)
            bouncedHits = bounce.hits
            next += 1
        }
        if let chop = plan.chop {
            guard next < engine.players.count else { throw Failure.unreadable(chop.name, "no player node is free") }
            let buffer: AVAudioPCMBuffer
            do {
                buffer = try Self.dustyChop(chop, format: engine.format)
            } catch {
                throw Failure.unreadable(chop.name, "\(error)")
            }
            let source = AudioTrackSource(player: try engine.player(next), buffer: buffer,
                                          startsAt: 0, loops: plan.loops)
            engine.add(source)
            tracks.append(source)
            next += 1
        }

        guard groovePlayer != nil || !tracks.isEmpty else { throw Failure.nothingScheduled }

        // When only audio is playing and nothing loops, the plan has an end; a groove loops (or runs
        // to the song's length, which `GroovePlayer.endTime` already knows) so the reading below
        // asks it rather than guessing.
        endsAt = plan.loops ? nil : Self.end(of: plan, groove: groovePlayer,
                                             longestTrack: tracks.map { $0.startsAt + $0.duration }.max())
    }

    func end() async {
        if let engine {
            if let groovePlayer { engine.remove(groovePlayer) }
            for track in tracks { engine.remove(track) }
        }
        groovePlayer?.transportWillStop()
        for track in tracks { track.transportWillStop() }
        groovePlayer = nil
        tracks = []
        bouncedHits = 0
        endsAt = nil
        engine = nil
    }

    func reading() async -> PlaybackReading {
        guard let engine, engine.isTransportRunning else { return .stopped }
        // Negative during the realtime lead time, when transport zero is still in the future.
        let seconds = max(0, engine.transportSeconds ?? 0)
        let hits = (groovePlayer?.scheduledHitCount ?? 0) + bouncedHits
        if let endsAt, seconds >= endsAt {
            return PlaybackReading(isRunning: false, seconds: endsAt, scheduledHits: hits)
        }
        return PlaybackReading(isRunning: true, seconds: seconds, scheduledHits: hits)
    }

    // MARK: Internals

    private static func end(of plan: SongPlayback, groove: GroovePlayer?, longestTrack: Double?) -> Double? {
        let audio = [plan.audioDuration, longestTrack].compactMap { $0 }.max()
        guard let groove else { return audio }
        guard let grooveEnd = groove.endTime else { return nil }
        return max(grooveEnd, audio ?? 0)
    }

    // MARK: The dusty sources

    /// A dusty groove as a buffer: bounced on the song's machine and put through its chain.
    ///
    /// Looping, it is one pass rendered as the *second* of two, so the buffer carries the tails the
    /// previous pass rings into it and loops without a gap where the kick's decay should be. Not
    /// looping, it is the song's length in whole passes — `GroovePlayer`'s own rounding — plus the
    /// last hit's tail. Either way it goes through `Dust.render`, the same call an audition makes,
    /// so the transport and the audition service play the same samples of the same version.
    static func dustyGroove(_ groove: Groove, plan: SongPlayback, clock: TransportClock,
                            service: AuditionService, format: AVAudioFormat) async throws
        -> (buffer: AVAudioPCMBuffer, hits: Int) {
        let machine = SynthMachine.preset(id: plan.machine) ?? .tr808
        let pass = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature)
        let barsPerPass = max(1, groove.bars)
        let passes = plan.loops ? 2 : max(1, ((plan.lengthInBars ?? barsPerPass) + barsPerPass - 1) / barsPerPass)
        let hits = Dust.hits(for: groove, tempo: clock.tempo, timeSignature: clock.timeSignature, repeats: passes)
        let seconds = plan.loops ? 2 * pass : Double(passes) * pass + Dust.tail
        let bounce = try await service.bounce(hits, machine: machine, seconds: seconds,
                                              sampleRate: format.sampleRate,
                                              channels: Int(format.channelCount))
        var wet = try Dust.render(bounce.planar, sampleRate: bounce.sampleRate, passes: plan.grooveChain)
        if plan.loops {
            let frames = Int((pass * bounce.sampleRate).rounded())
            wet = wet.map { Array($0.suffix(frames)) }
        }
        guard let buffer = AuditionService.buffer(planar: wet, sampleRate: bounce.sampleRate, in: format) else {
            throw EngineError.renderFailed("the dusty groove could not be put in the graph's format")
        }
        return (buffer, plan.loops ? hits.count / 2 : hits.count)
    }

    /// A dusty chop as a buffer: its bar of the record, through its chain, in the graph's format.
    static func dustyChop(_ chop: SongPlayback.ChopTrack, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let span = try AudioRegion.read(chop.url, from: chop.region.start, to: chop.region.end)
        guard !span.planar.isEmpty, span.planar[0].count > 0 else {
            throw EngineError.invalidRegion("\(chop.name) is empty between "
                + String(format: "%.2f s and %.2f s", chop.region.start, chop.region.end))
        }
        let wet = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: chop.passes)
        guard let buffer = AuditionService.buffer(planar: wet, sampleRate: span.sampleRate, in: format) else {
            throw EngineError.renderFailed("\(chop.name) could not be put in the graph's format")
        }
        return buffer
    }

    /// The whole file, in the graph's format.
    ///
    /// Read rather than streamed on purpose: `AVAudioPlayerNode.scheduleFile` hands the node a file
    /// whose processing format is its own, and the drift note in `Engine.init` is about exactly that
    /// — a bus left at the file's rate while the graph renders at another is 8.84% of cumulative,
    /// silent error. A buffer converted once on the way in cannot drift.
    static func read(_ url: URL, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
              let scratch = AVAudioPCMBuffer(pcmFormat: source,
                                             frameCapacity: min(frames, 1 << 16)) else {
            throw EngineError.invalidRegion("\(url.lastPathComponent) holds no frames")
        }
        // Read into a scratch buffer and copy, rather than reading repeatedly into `input`.
        // `AVAudioFile.read(into:)` *sets* the buffer's `frameLength` to what it read rather than
        // appending, and a single call can stop on an internal block boundary without throwing
        // (the measurement is in `SampleCache`), so reading into the destination twice both loses
        // the first chunk and asks for more frames than remain — which is an `eofErr`, not a short
        // read. Accumulating explicitly is the only shape that is right for both.
        let channels = Int(source.channelCount)
        var filled: AVAudioFrameCount = 0
        while filled < frames {
            scratch.frameLength = 0
            try file.read(into: scratch, frameCount: min(frames - filled, scratch.frameCapacity))
            let produced = Int(scratch.frameLength)
            guard produced > 0, let from = scratch.floatChannelData,
                  let into = input.floatChannelData else { break }
            let sourceStride = scratch.stride
            let targetStride = input.stride
            let offset = Int(filled)
            for channel in 0..<channels {
                if sourceStride == 1 && targetStride == 1 {
                    (into[channel] + offset).update(from: from[channel], count: produced)
                } else {
                    for frame in 0..<produced {
                        into[channel][(offset + frame) * targetStride] = from[channel][frame * sourceStride]
                    }
                }
            }
            filled += AVAudioFrameCount(produced)
        }
        input.frameLength = filled
        guard filled > 0 else {
            throw EngineError.invalidRegion("\(url.lastPathComponent) decoded to nothing")
        }
        guard source.sampleRate != format.sampleRate || source.channelCount != format.channelCount else {
            return input
        }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw EngineError.formatMismatch("cannot convert \(source) to \(format)")
        }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw EngineError.renderFailed("could not allocate \(capacity) frames")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else {
            throw EngineError.renderFailed(error.map { "\($0)" } ?? "conversion produced nothing")
        }
        return output
    }
}

// MARK: - One audio file on the transport

/// A take or a stem, placed on the transport's timeline.
///
/// Deliberately not `LoopPlayer`: that one exists to loop a *bar region* of a buffer against a
/// `BeatGrid`, which is what the Chop lane and `m0 loop` want. Playing a record from the transport
/// position is the simpler thing — one buffer, at one time — and its only subtlety is the one below:
/// the buffer is handed over ahead of its own start, so it is never scheduled after it was due.
@AudioActor
final class AudioTrackSource: ScheduledSource {

    let player: AVAudioPlayerNode
    let buffer: AVAudioPCMBuffer
    /// Transport seconds at which frame 0 sounds.
    let startsAt: Double
    /// Whether the file repeats end to end. The frame's loop flag.
    let loops: Bool
    /// How far ahead of its start the buffer is handed to the node. Larger than the engine's
    /// look-ahead, for the same reason `GroovePlayer.preroll` is.
    var preroll: Double = 0.5

    private var transport: Transport?
    private(set) var iterationsScheduled = 0

    var duration: Double {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    init(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, startsAt: Double, loops: Bool = false) {
        self.player = player
        self.buffer = buffer
        self.startsAt = max(0, startsAt)
        self.loops = loops
    }

    // MARK: ScheduledSource

    func transportDidStart(_ transport: Transport) {
        self.transport = transport
        iterationsScheduled = 0
    }

    func schedule(through seconds: Double) {
        guard let transport, duration > 0 else { return }
        let horizon = seconds + preroll
        while loops || iterationsScheduled == 0 {
            let start = startsAt + Double(iterationsScheduled) * duration
            guard start < horizon else { return }
            player.scheduleBuffer(buffer, at: transport.playerTime(atSeconds: start),
                                  options: [], completionHandler: nil)
            iterationsScheduled += 1
        }
    }

    func transportWillStop() {
        player.stop()
        transport = nil
    }
}
