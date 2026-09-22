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
/// * a **bass line** becomes a `Performance.BasslinePlayer` on the shared bass sampler;
/// * the **chords** and the **tune** become `Performance.KeysPlayer`s on the shared instrument
///   sampler — the same one the Chords surface and the Piano roll audition through, so what the
///   form plays back is what you heard when you wrote it;
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
    private var bassPlayer: BasslinePlayer?
    /// The chords and the tune, in that order, on the one instrument sampler.
    private var keysPlayers: [KeysPlayer] = []
    private var tracks: [AudioTrackSource] = []
    /// An arranged song's players: one groove, one bass and up to two keys players per section that
    /// has them, all on the three shared samplers, and one sequence per dusty kind on a player node.
    private var sectionGrooves: [GroovePlayer] = []
    private var sectionBasses: [BasslinePlayer] = []
    private var sectionKeys: [KeysPlayer] = []
    private var sequences: [SequenceTrackSource] = []
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
        // M6: the strips. Every source below is routed through its part's strip, and the mix the
        // plan carries is applied before a frame renders.
        let graph = try engine.mixGraph()
        graph.apply(plan.mix ?? .unity, section: plan.segments.first?.section)
        lastMix = plan.mix

        if plan.isArranged {
            try await beginArranged(plan, clock: clock, engine: engine, graph: graph)
            return
        }

        if let groove = plan.groove, plan.grooveChain.isEmpty {
            let machine = SynthMachine.preset(id: plan.machine) ?? .tr808
            let sampler = try await service.playbackSampler(machine: machine)
            try Self.route(sampler.node, part: plan.groovePart, on: graph)
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature)
            let player = GroovePlayer(sampler: sampler, groove: groove, timeline: timeline)
            // With the loop off, a groove plays the song's own length and stops; with it on it plays
            // until you stop it. `GroovePlayer` rounds bars up to whole iterations, because a feel
            // is a phrase and half of one is not a feel.
            player.bars = plan.loops ? nil : plan.lengthInBars
            engine.add(player)
            groovePlayer = player
        }

        if let bassline = plan.bassline {
            let voice = BassVoiceSpec.all.first { $0.id == plan.bassSound } ?? .finger
            let sampler = try await service.playbackBassSampler(voice: voice)
            try Self.route(sampler.node, part: plan.basslinePart, on: graph)
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature)
            let player = BasslinePlayer(sampler: sampler, bassline: bassline, timeline: timeline)
            player.bars = plan.loops ? nil : plan.lengthInBars
            engine.add(player)
            bassPlayer = player
        }

        // The chords and the tune, on one sampler. Two players rather than one merged phrase, so
        // each keeps its own loop length: four bars of chords under an eight-bar melody is a normal
        // thing to write, and flattening them together would force one length on both.
        if plan.progression != nil || plan.melody != nil {
            let spec = InstrumentVoiceSpec.preset(id: plan.instrument) ?? .rhodes
            let sampler = try await service.playbackInstrumentSampler(spec)
            try Self.route(sampler.node, part: plan.progressionPart ?? plan.melodyPart, on: graph)
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature)
            if let progression = plan.progression {
                let player = KeysPlayer(sampler: sampler, progression: progression, timeline: timeline)
                player.bars = plan.loops ? nil : plan.lengthInBars
                engine.add(player)
                keysPlayers.append(player)
            }
            if let melody = plan.melody {
                let player = KeysPlayer(sampler: sampler, melody: melody, timeline: timeline)
                player.bars = plan.loops ? nil : plan.lengthInBars
                // One sampler, two players: only the first forwards the transport to it.
                player.drivesSampler = keysPlayers.isEmpty
                engine.add(player)
                keysPlayers.append(player)
            }
        }

        for (index, track) in plan.tracks.enumerated() {
            guard index < engine.players.count else { break }
            let buffer: AVAudioPCMBuffer
            do {
                buffer = try Self.read(track.url, in: engine.format)
            } catch {
                throw Failure.unreadable(track.name, "\(error)")
            }
            let node = try engine.player(index)
            try Self.route(node, part: track.part, on: graph)
            let source = AudioTrackSource(player: node,
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
            let node = try engine.player(next)
            try Self.route(node, part: plan.groovePart, on: graph)
            let source = AudioTrackSource(player: node, buffer: bounce.buffer,
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
            let node = try engine.player(next)
            try Self.route(node, part: chop.part, on: graph)
            let source = AudioTrackSource(player: node, buffer: buffer,
                                          startsAt: 0, loops: plan.loops)
            engine.add(source)
            tracks.append(source)
            next += 1
        }

        guard groovePlayer != nil || bassPlayer != nil || !keysPlayers.isEmpty || !tracks.isEmpty else {
            throw Failure.nothingScheduled
        }

        // When only audio is playing and nothing loops, the plan has an end; a groove loops (or runs
        // to the song's length, which `GroovePlayer.endTime` already knows) so the reading below
        // asks it rather than guessing.
        endsAt = plan.loops ? nil : Self.end(of: plan, groove: groovePlayer, bass: bassPlayer,
                                             keys: keysPlayers,
                                             longestTrack: tracks.map { $0.startsAt + $0.duration }.max())
    }

    /// The form: each section's groove and bass line as players of their own on the shared
    /// samplers, placed at the section's bar and clipped to its length; each section's dusty
    /// groove bounced and each chop rendered, and laid end to end on one player node per kind.
    /// With the loop on everything cycles with the form's own length.
    private func beginArranged(_ plan: SongPlayback, clock: TransportClock, engine: Engine, graph: MixGraph) async throws {
        let beatsPerBar = clock.timeSignature.beatsPerBar
        let cycleBeats: Double? = plan.loops ? plan.lengthInBars.map { Double($0 * beatsPerBar) } : nil
        let cycleSeconds: Double? = plan.loops ? plan.formSeconds : nil
        func start(_ segment: SongPlayback.Segment) -> Double {
            clock.seconds(forBeat: Double(segment.startBar * beatsPerBar))
        }
        func seconds(_ segment: SongPlayback.Segment) -> Double {
            clock.seconds(forBeat: Double(segment.endBar * beatsPerBar)) - start(segment)
        }

        var drumSampler: VoiceSampler?
        var bassSampler: VoiceSampler?
        var keysSampler: VoiceSampler?
        var bounces: [(AVAudioPCMBuffer, Double)] = []
        var chops: [(AVAudioPCMBuffer, Double)] = []

        for segment in plan.segments {
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature,
                                                startingAt: start(segment))
            if let groove = segment.groove, segment.grooveChain.isEmpty {
                if drumSampler == nil {
                    let machine = SynthMachine.preset(id: plan.machine) ?? .tr808
                    drumSampler = try await service.playbackSampler(machine: machine)
                    // One sampler for every section's groove: it plays through the first's strip.
                    try Self.route(drumSampler?.node, part: segment.groovePart, on: graph)
                }
                let player = GroovePlayer(sampler: drumSampler!, groove: groove, timeline: timeline)
                player.bars = segment.lengthInBars
                player.clipsToBars = true
                player.cycleBeats = cycleBeats
                // One sampler, many players: only the first forwards the transport to it.
                player.drivesSampler = sectionGrooves.isEmpty
                engine.add(player)
                sectionGrooves.append(player)
            } else if let groove = segment.groove {
                let bounce = try await Self.dustyGroove(groove, chain: segment.grooveChain, machine: plan.machine,
                                                        bars: segment.lengthInBars, seconds: seconds(segment),
                                                        clock: clock, service: service, format: engine.format)
                bounces.append((bounce.buffer, start(segment)))
                bouncedHits += bounce.hits
            }
            if let bassline = segment.bassline {
                let voice = BassVoiceSpec.all.first { $0.id == segment.bassSound } ?? .finger
                if bassSampler == nil {
                    bassSampler = try await service.playbackBassSampler(voice: voice)
                    try Self.route(bassSampler?.node, part: segment.basslinePart, on: graph)
                }
                let player = BasslinePlayer(sampler: bassSampler!, bassline: bassline, timeline: timeline)
                player.bars = segment.lengthInBars
                player.clipsToBars = true
                player.cycleBeats = cycleBeats
                player.drivesSampler = sectionBasses.isEmpty
                engine.add(player)
                sectionBasses.append(player)
            }
            // The chords and the tune. One sampler for every section's, as above: the song names
            // one pitched instrument, so a verse's pad and a hook's pad are the same pad.
            if segment.progression != nil || segment.melody != nil {
                if keysSampler == nil {
                    let spec = InstrumentVoiceSpec.preset(id: plan.instrument) ?? .rhodes
                    keysSampler = try await service.playbackInstrumentSampler(spec)
                    try Self.route(keysSampler?.node,
                                   part: segment.progressionPart ?? segment.melodyPart, on: graph)
                }
                func place(_ player: KeysPlayer) {
                    player.bars = segment.lengthInBars
                    player.clipsToBars = true
                    player.cycleBeats = cycleBeats
                    // One sampler, many players: only the first forwards the transport to it.
                    player.drivesSampler = sectionKeys.isEmpty
                    engine.add(player)
                    sectionKeys.append(player)
                }
                if let progression = segment.progression {
                    place(KeysPlayer(sampler: keysSampler!, progression: progression, timeline: timeline))
                }
                if let melody = segment.melody {
                    place(KeysPlayer(sampler: keysSampler!, melody: melody, timeline: timeline))
                }
            }
            if let chop = segment.chop {
                let buffer: AVAudioPCMBuffer
                do {
                    buffer = try Self.dustyChop(chop, format: engine.format, repeatedTo: seconds(segment))
                } catch {
                    throw Failure.unreadable(chop.name, "\(error)")
                }
                chops.append((buffer, start(segment)))
            }
        }

        var next = 0
        let bouncePart = plan.segments.first { $0.groove != nil && !$0.grooveChain.isEmpty }?.groovePart
        let chopPart = plan.segments.first { $0.chop != nil }?.chop?.part
        for (events, part) in [(bounces, bouncePart), (chops, chopPart)] where !events.isEmpty {
            guard next < engine.players.count else { throw Failure.unreadable("The dusty sections", "no player node is free") }
            let node = try engine.player(next)
            try Self.route(node, part: part, on: graph)
            let source = SequenceTrackSource(player: node, events: events, cycle: cycleSeconds)
            engine.add(source)
            sequences.append(source)
            next += 1
        }

        guard !sectionGrooves.isEmpty || !sectionBasses.isEmpty || !sectionKeys.isEmpty
                || !sequences.isEmpty else {
            throw Failure.nothingScheduled
        }
        endsAt = plan.loops ? nil : plan.formSeconds
    }

    func end() async {
        if let engine {
            (try? engine.mixGraph())?.releaseSlots()
            if let groovePlayer { engine.remove(groovePlayer) }
            if let bassPlayer { engine.remove(bassPlayer) }
            for player in keysPlayers { engine.remove(player) }
            for track in tracks { engine.remove(track) }
            for player in sectionGrooves { engine.remove(player) }
            for player in sectionBasses { engine.remove(player) }
            for player in sectionKeys { engine.remove(player) }
            for source in sequences { engine.remove(source) }
        }
        groovePlayer?.transportWillStop()
        bassPlayer?.transportWillStop()
        for player in keysPlayers { player.transportWillStop() }
        for track in tracks { track.transportWillStop() }
        for player in sectionGrooves { player.transportWillStop() }
        for player in sectionBasses { player.transportWillStop() }
        for player in sectionKeys { player.transportWillStop() }
        for source in sequences { source.transportWillStop() }
        groovePlayer = nil
        bassPlayer = nil
        keysPlayers = []
        tracks = []
        sectionGrooves = []
        sectionBasses = []
        sectionKeys = []
        sequences = []
        bouncedHits = 0
        endsAt = nil
        engine = nil
    }

    /// The mix as last applied, so a section change is a move and not a re-apply.
    private var lastMix: Mix?

    func mixChanged(_ mix: Mix?, section: SectionID?) async {
        guard let engine, let graph = try? engine.mixGraph() else { return }
        if mix == lastMix {
            graph.move(to: section)
        } else {
            graph.apply(mix ?? .unity, section: section)
            lastMix = mix
        }
    }

    /// A node through its part's strip, or straight to the main mixer when it has no part.
    private static func route(_ node: AVAudioNode?, part: PartID?, on graph: MixGraph) throws {
        guard let node else { return }
        if let part { try graph.route(node, to: part) } else { try graph.unroute(node) }
    }

    func reading() async -> PlaybackReading {
        guard let engine, engine.isTransportRunning else { return .stopped }
        // Negative during the realtime lead time, when transport zero is still in the future.
        let seconds = max(0, engine.transportSeconds ?? 0)
        let hits = (groovePlayer?.scheduledHitCount ?? 0) + (bassPlayer?.scheduledHitCount ?? 0) + bouncedHits
            + keysPlayers.reduce(0) { $0 + $1.scheduledHitCount }
            + sectionGrooves.reduce(0) { $0 + $1.scheduledHitCount }
            + sectionBasses.reduce(0) { $0 + $1.scheduledHitCount }
            + sectionKeys.reduce(0) { $0 + $1.scheduledHitCount }
        if let endsAt, seconds >= endsAt {
            return PlaybackReading(isRunning: false, seconds: endsAt, scheduledHits: hits)
        }
        return PlaybackReading(isRunning: true, seconds: seconds, scheduledHits: hits)
    }

    // MARK: Internals

    private static func end(of plan: SongPlayback, groove: GroovePlayer?, bass: BasslinePlayer?,
                            keys: [KeysPlayer], longestTrack: Double?) -> Double? {
        let audio = [plan.audioDuration, longestTrack].compactMap { $0 }.max()
        var end = audio
        if let groove {
            guard let grooveEnd = groove.endTime else { return nil }
            end = max(grooveEnd, end ?? 0)
        }
        if let bass {
            guard let bassEnd = bass.endTime else { return nil }
            end = max(bassEnd, end ?? 0)
        }
        for player in keys {
            guard let keysEnd = player.endTime else { return nil }
            end = max(keysEnd, end ?? 0)
        }
        return end
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

    /// A section's dusty groove: `bars` of it bounced through its chain and cut at the section's
    /// end, so the next section on the same node starts clean where this one stops.
    static func dustyGroove(_ groove: Groove, chain: [Degradation], machine machineID: String, bars: Int,
                            seconds: Double, clock: TransportClock, service: AuditionService,
                            format: AVAudioFormat) async throws -> (buffer: AVAudioPCMBuffer, hits: Int) {
        let machine = SynthMachine.preset(id: machineID) ?? .tr808
        let pass = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature)
        let barsPerPass = max(1, groove.bars)
        let passes = max(1, (bars + barsPerPass - 1) / barsPerPass)
        let hits = Dust.hits(for: groove, tempo: clock.tempo, timeSignature: clock.timeSignature, repeats: passes)
            .filter { $0.time < seconds }
        let bounce = try await service.bounce(hits, machine: machine, seconds: Double(passes) * pass + Dust.tail,
                                              sampleRate: format.sampleRate, channels: Int(format.channelCount))
        let wet = try Dust.render(bounce.planar, sampleRate: bounce.sampleRate, passes: chain)
        let frames = Int((seconds * bounce.sampleRate).rounded())
        let cut = wet.map { Array($0.prefix(frames)) }
        guard let buffer = AuditionService.buffer(planar: cut, sampleRate: bounce.sampleRate, in: format) else {
            throw EngineError.renderFailed("the dusty groove could not be put in the graph's format")
        }
        return (buffer, hits.count)
    }

    /// A dusty chop as a buffer: its bar of the record, through its chain, in the graph's format.
    /// `repeatedTo` lays the bar end to end to fill that many seconds — a section's worth — and
    /// cuts the last copy where the section ends.
    static func dustyChop(_ chop: SongPlayback.ChopTrack, format: AVAudioFormat,
                          repeatedTo seconds: Double? = nil) throws -> AVAudioPCMBuffer {
        let span = try AudioRegion.read(chop.url, from: chop.region.start, to: chop.region.end)
        guard !span.planar.isEmpty, span.planar[0].count > 0 else {
            throw EngineError.invalidRegion("\(chop.name) is empty between "
                + String(format: "%.2f s and %.2f s", chop.region.start, chop.region.end))
        }
        var wet = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: chop.passes)
        if let seconds, seconds > 0 {
            let frames = Int((seconds * span.sampleRate).rounded())
            let copies = max(1, (frames + wet[0].count - 1) / max(1, wet[0].count))
            wet = wet.map { channel in Array([[Float]](repeating: channel, count: copies).joined().prefix(frames)) }
        }
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


// MARK: - Buffers laid end to end on one node

/// Several buffers at their own transport times on one player node — an arranged song's dusty
/// sections, which never sound at once and so never need a node each. `cycle` repeats the whole
/// list that many seconds on, for as long as the transport runs: the form, looping.
@AudioActor
final class SequenceTrackSource: ScheduledSource {

    let player: AVAudioPlayerNode
    /// Each buffer and the transport second its first frame sounds on, in time order.
    let events: [(buffer: AVAudioPCMBuffer, startsAt: Double)]
    let cycle: Double?
    var preroll: Double = 0.5

    private var transport: Transport?
    private(set) var scheduled = 0

    init(player: AVAudioPlayerNode, events: [(AVAudioPCMBuffer, Double)], cycle: Double? = nil) {
        self.player = player
        self.events = events.map { (buffer: $0.0, startsAt: max(0, $0.1)) }.sorted { $0.startsAt < $1.startsAt }
        self.cycle = cycle
    }

    func transportDidStart(_ transport: Transport) {
        self.transport = transport
        scheduled = 0
    }

    func schedule(through seconds: Double) {
        guard let transport, !events.isEmpty else { return }
        let horizon = seconds + preroll
        while true {
            let pass = scheduled / events.count
            if pass > 0 && cycle == nil { return }
            let event = events[scheduled % events.count]
            let start = event.startsAt + Double(pass) * (cycle ?? 0)
            guard start < horizon else { return }
            player.scheduleBuffer(event.buffer, at: transport.playerTime(atSeconds: start),
                                  options: [], completionHandler: nil)
            scheduled += 1
        }
    }

    func transportWillStop() {
        player.stop()
        transport = nil
    }
}
