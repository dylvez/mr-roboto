import AVFAudio
import Analysis
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

    /// The chords and the tune, in that order, on the one instrument sampler.
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
    /// The click, when the plan asks for one: the count-in, or the whole of playback.
    private var metronome: Metronome?
    /// Chops that grooves play on, each read and cut once per run however many sections use it.
    private var chopKits: [VersionID: ChopGroove.Prepared] = [:]
    /// Chops a groove could not be played on this run, and why: those grooves played on a machine.
    private var failedChops: [String] = []

    func chopFailures() async -> [String] { failedChops }

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
        // A slot for every part the plan sounds, before a single source is connected: the pool goes
        // in the plan's own order rather than to whichever source was scheduled first, and a song
        // with more parts than the graph holds says so here instead of growing a dead fader.
        unseated = graph.reserve(plan.parts)
        // `end()` above has taken every source off the engine, so nothing is reading a lane
        // sampler's zones: the window to let go of the ones this plan does not name. Without it a
        // song closed or a form rewritten leaves its kits resident for the life of the app, and a
        // pitched kit is nineteen roots of rendered audio. The surfaces' own samplers — the ones
        // with no part — are never retired; they belong to the app, not to a plan.
        await service.retire(partsOtherThan: Set(plan.parts))
        graph.apply(plan.mix ?? .unity, section: plan.segments.first?.section)
        lastMix = plan.mix

        if plan.isArranged {
            try await beginArranged(plan, clock: clock, engine: engine, graph: graph)
            startClick(plan, clock: clock, engine: engine, graph: graph, firstFreeNode: nodesInUse)
            return
        }

        // Every voice the plan names, on its own part's sampler and strip. One loop rather than
        // one block per kind: a plan can hold two grooves or a pad and a lead, and a block per kind
        // can only ever place the first of each.
        // After a count-in when there is one: the loops wait for the song to begin.
        let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature,
                                            startingAt: plan.voicesStartAt)
        var driving = Set<AuditionService.SamplerKey>()
        for voice in plan.voices {
            // A dusty groove is not played live: it is bounced through its chain below, onto a
            // player node, because the chain is applied to audio and not to a sampler. A groove on
            // a chop is bounced too, on a kit of the chop's own slices.
            if voice.groove != nil, voice.isBounced { continue }
            guard let player = try await source(for: voice, at: nil, timeline: timeline,
                                                driving: &driving, engine: engine, graph: graph) else { continue }
            // With the loop off a part plays the song's own length and stops; with it on it plays
            // until you stop it. The players round bars up to whole iterations, because a feel is a
            // phrase and half of one is not a feel.
            player.run(forBars: plan.loops ? nil : plan.lengthInBars)
            engine.add(player.source)
            keep(player)
        }

        for (index, track) in plan.tracks.enumerated() {
            guard index < engine.players.count else { break }
            let buffer: AVAudioPCMBuffer
            do {
                buffer = Self.skipping(try Self.read(track.url, in: engine.format), seconds: track.skip)
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
        //
        // One loop over the voices, as above. This used to read `plan.groove`/`plan.chop` — the
        // first of each kind — so a plan holding two dusty grooves bounced one and dropped the
        // other, which is the same bug the arranged path had and the last place it lived.
        var next = tracks.count
        for voice in plan.voices where voice.isBounced {
            guard next < engine.players.count else {
                throw Failure.unreadable(voice.name, "no player node is free")
            }
            let buffer: AVAudioPCMBuffer
            if voice.groove != nil {
                let bounce = try await Self.dustyGroove(voice, on: preparedKit(for: voice),
                                                        loops: plan.loops, lengthInBars: plan.lengthInBars,
                                                        clock: clock, service: service, format: engine.format)
                buffer = bounce.buffer
                bouncedHits += bounce.hits
            } else if let chop = voice.chop {
                do {
                    buffer = try Self.dustyChop(chop, format: engine.format, clock: clock)
                } catch {
                    throw Failure.unreadable(chop.name, "\(error)")
                }
            } else {
                continue
            }
            let node = try engine.player(next)
            try Self.route(node, part: voice.part, on: graph)
            let source = AudioTrackSource(player: node, buffer: buffer, startsAt: plan.voicesStartAt, loops: plan.loops)
            engine.add(source)
            tracks.append(source)
            next += 1
        }

        guard !sectionGrooves.isEmpty || !sectionBasses.isEmpty || !sectionKeys.isEmpty
                || !tracks.isEmpty else {
            throw Failure.nothingScheduled
        }
        startClick(plan, clock: clock, engine: engine, graph: graph, firstFreeNode: next)

        // When only audio is playing and nothing loops, the plan has an end; a groove loops (or runs
        // to the song's length, which `GroovePlayer.endTime` already knows) so the reading below
        // asks it rather than guessing.
        endsAt = plan.loops ? nil : Self.end(of: plan, players: placedPlayers,
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

        // A sampler per part, not per kind. Two things follow. A verse's groove and a hook's groove
        // that are different parts no longer share one kit — and no longer share one strip, which
        // is what made a hook's groove metered and soloed under the verse's part. And the "only the
        // first player forwards the transport" rule now has to be asked of the *sampler*: with one
        // per kind, `sectionGrooves.isEmpty` answered it; with one per part it would silently say
        // no to the first player of the second part's sampler, which never then advances.
        var driving = Set<AuditionService.SamplerKey>()
        // Audio laid end to end, one node per part: each dusty groove and each chop through its
        // own part's strip. They used to share two nodes — every dusty groove on the first dusty
        // part's strip, every chop on the first chop's — and only a section's first chop played.
        var laid: [(part: PartID?, events: [(AVAudioPCMBuffer, Double)])] = []
        func lay(_ buffer: AVAudioPCMBuffer, at seconds: Double, on part: PartID?) {
            if let index = laid.firstIndex(where: { $0.part == part }) {
                laid[index].events.append((buffer, seconds))
            } else {
                laid.append((part, [(buffer, seconds)]))
            }
        }

        for segment in plan.segments {
            let timeline = GrooveTimeline.tempo(clock.tempo, timeSignature: clock.timeSignature,
                                                startingAt: start(segment))
            for voice in segment.voices {
                // A dusty groove and a chop are audio through a chain; they are bounced onto player
                // nodes below rather than played on a sampler.
                if let chop = voice.chop {
                    let buffer: AVAudioPCMBuffer
                    do {
                        buffer = try Self.dustyChop(chop, format: engine.format, clock: clock, repeatedTo: seconds(segment))
                    } catch {
                        throw Failure.unreadable(chop.name, "\(error)")
                    }
                    lay(buffer, at: start(segment), on: chop.part)
                    continue
                }
                if voice.groove != nil, voice.isBounced {
                    let bounce = try await Self.dustyGroove(voice, on: preparedKit(for: voice),
                                                            bars: segment.lengthInBars, seconds: seconds(segment),
                                                            clock: clock, service: service, format: engine.format)
                    lay(bounce.buffer, at: start(segment), on: voice.part)
                    bouncedHits += bounce.hits
                    continue
                }
                guard let player = try await source(for: voice, at: start(segment), timeline: timeline,
                                                    driving: &driving, engine: engine, graph: graph)
                else { continue }
                player.clip(toBars: segment.lengthInBars, cycleBeats: cycleBeats)
                engine.add(player.source)
                keep(player)
            }
        }

        var next = 0
        for (part, events) in laid {
            guard next < engine.players.count else { throw Failure.unreadable("The dusty sections", "no player node is free") }
            let node = try engine.player(next)
            try Self.route(node, part: part, on: graph)
            let source = SequenceTrackSource(player: node, events: events, cycle: cycleSeconds)
            engine.add(source)
            sequences.append(source)
            next += 1
        }

        // The takes, each on its own node at the bar it was sung on, and coming round with the
        // form when the loop is on — which is why they are sequences of one rather than
        // `AudioTrackSource`s: that one loops at its own length, not the form's.
        for track in plan.tracks {
            guard next < engine.players.count else { throw Failure.unreadable(track.name, "no player node is free") }
            let buffer: AVAudioPCMBuffer
            do {
                buffer = Self.skipping(try Self.read(track.url, in: engine.format), seconds: track.skip)
            } catch {
                throw Failure.unreadable(track.name, "\(error)")
            }
            let node = try engine.player(next)
            try Self.route(node, part: track.part, on: graph)
            let source = SequenceTrackSource(player: node, events: [(buffer, track.startsAt)], cycle: cycleSeconds)
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

    /// Player nodes the arranged path has taken: one per sequence.
    private var nodesInUse: Int { sequences.count }

    /// The metronome, on the first player node the plan left free, straight to the main mixer (a
    /// click belongs to no part and no strip). The count-in's bars always click; `plan.click`
    /// keeps it going. With every node taken the click is left out rather than a part — a click
    /// is not worth losing the song for.
    private func startClick(_ plan: SongPlayback, clock: TransportClock, engine: Engine, graph: MixGraph,
                            firstFreeNode: Int) {
        guard plan.click || plan.countInBars > 0, firstFreeNode < engine.players.count else { return }
        let bars: Int
        if plan.click {
            // A looping song clicks as long as it plays; a grid of a few hundred bars is that.
            bars = plan.loops ? 512 : plan.countInBars + (plan.lengthInBars ?? 64) + 1
        } else {
            bars = plan.countInBars
        }
        guard bars > 0, let click = try? Metronome(engine: engine, playerIndex: firstFreeNode,
                                                     clock: clock, bars: bars) else { return }
        try? Self.route(click.player, part: nil, on: graph)
        engine.add(click)
        metronome = click
    }

    func end() async {
        if let metronome {
            engine?.remove(metronome)
            metronome.transportWillStop()
            metronome.player.stop()
        }
        metronome = nil
        chopKits = [:]
        failedChops = []
        if let engine {
            (try? engine.mixGraph())?.releaseSlots()
            for track in tracks { engine.remove(track) }
            for player in sectionGrooves { engine.remove(player) }
            for player in sectionBasses { engine.remove(player) }
            for player in sectionKeys { engine.remove(player) }
            for source in sequences { engine.remove(source) }
        }
        for track in tracks { track.transportWillStop() }
        for player in sectionGrooves { player.transportWillStop() }
        for player in sectionBasses { player.transportWillStop() }
        for player in sectionKeys { player.transportWillStop() }
        for source in sequences { source.transportWillStop() }
        tracks = []
        sectionGrooves = []
        sectionBasses = []
        sectionKeys = []
        sequences = []
        bouncedHits = 0
        unseated = []
        endsAt = nil
        engine = nil
    }

    func unmixedParts() async -> [PartID] { unseated }

    /// Parts the pool could not seat when the plan began. Held rather than read back off the graph,
    /// because `end()` gives the slots back and clears it.
    private var unseated: [PartID] = []


    /// The mix as last applied, so a section change is a move and not a re-apply.
    private var lastMix: Mix?

    func fade(_ gain: Double) async {
        guard let engine, let graph = try? engine.mixGraph() else { return }
        graph.setFade(gain)
    }

    func mixChanged(_ mix: Mix?, section: SectionID?) async {
        guard let engine, let graph = try? engine.mixGraph() else { return }
        if mix == lastMix {
            graph.move(to: section)
        } else {
            graph.apply(mix ?? .unity, section: section)
            lastMix = mix
        }
    }

    /// One voice as a scheduled source on its part's sampler and strip.
    ///
    /// The three players have the same shape on purpose — `bars`, `clipsToBars`, `cycleBeats`,
    /// `drivesSampler` — so a section and a flat plan schedule through one function and a fourth
    /// kind is a fourth case here rather than a fourth block in two places.
    ///
    /// `drivesSampler` is asked of the *sampler*, not of a per-kind array: exactly one player per
    /// sampler forwards the transport to it, and with one sampler per part the second part's first
    /// player must drive too.
    private func source(for voice: SongPlayback.Voice, at startSeconds: Double?,
                        timeline: GrooveTimeline, driving: inout Set<AuditionService.SamplerKey>,
                        engine: Engine, graph: MixGraph) async throws -> Placed? {
        func drives(_ key: AuditionService.SamplerKey) -> Bool { driving.insert(key).inserted }

        switch voice.play {
        case .groove(let groove):
            let machine = SynthMachine.preset(id: voice.sound) ?? .tr808
            let key = AuditionService.SamplerKey(.drums, part: voice.part)
            let sampler = try await service.playbackSampler(machine: machine, for: voice.part)
            try Self.route(sampler.node, part: voice.part, on: graph)
            let player = GroovePlayer(sampler: sampler, groove: groove, timeline: timeline)
            player.drivesSampler = drives(key)
            return .groove(player)
        case .bassline(let line):
            let spec = BassVoiceSpec.all.first { $0.id == voice.sound } ?? .finger
            let key = AuditionService.SamplerKey(.bass, part: voice.part)
            let sampler = try await service.playbackBassSampler(voice: spec, for: voice.part)
            try Self.route(sampler.node, part: voice.part, on: graph)
            let player = BasslinePlayer(sampler: sampler, bassline: line, timeline: timeline)
            player.drivesSampler = drives(key)
            return .bass(player)
        case .progression(let progression):
            let player = KeysPlayer(sampler: try await keysSampler(voice, engine: engine, graph: graph),
                                    progression: progression, timeline: timeline)
            player.drivesSampler = drives(AuditionService.SamplerKey(.instrument, part: voice.part))
            return .keys(player)
        case .melody(let melody):
            let player = KeysPlayer(sampler: try await keysSampler(voice, engine: engine, graph: graph),
                                    melody: melody, timeline: timeline)
            player.drivesSampler = drives(AuditionService.SamplerKey(.instrument, part: voice.part))
            return .keys(player)
        case .chop:
            // A chop is audio through a chain, not a sampler: it goes on a player node, below.
            return nil
        }
    }

    private func keysSampler(_ voice: SongPlayback.Voice, engine: Engine, graph: MixGraph) async throws -> VoiceSampler {
        let spec = InstrumentVoiceSpec.preset(id: voice.sound) ?? .rhodes
        let sampler = try await service.playbackInstrumentSampler(spec, for: voice.part)
        try Self.route(sampler.node, part: voice.part, on: graph)
        return sampler
    }

    /// A player and which list it is kept in, so the one scheduling loop can hand it back.
    @AudioActor
    enum Placed {
        case groove(GroovePlayer), bass(BasslinePlayer), keys(KeysPlayer)

        var source: any ScheduledSource {
            switch self {
            case .groove(let p): return p
            case .bass(let p): return p
            case .keys(let p): return p
            }
        }

        /// The whole plan's length, for a flat plan that is not looping.
        func run(forBars bars: Int?) {
            switch self {
            case .groove(let p): p.bars = bars
            case .bass(let p): p.bars = bars
            case .keys(let p): p.bars = bars
            }
        }

        /// A section's own bars, clipped at its end so the next section starts clean, cycling with
        /// the form when the loop is on.
        func clip(toBars bars: Int, cycleBeats: Double?) {
            switch self {
            case .groove(let p): p.bars = bars; p.clipsToBars = true; p.cycleBeats = cycleBeats
            case .bass(let p): p.bars = bars; p.clipsToBars = true; p.cycleBeats = cycleBeats
            case .keys(let p): p.bars = bars; p.clipsToBars = true; p.cycleBeats = cycleBeats
            }
        }

        var endTime: Double? {
            switch self {
            case .groove(let p): return p.endTime
            case .bass(let p): return p.endTime
            case .keys(let p): return p.endTime
            }
        }
    }

    /// Keeps a placed player in the list `end()` and `reading()` walk.
    private func keep(_ placed: Placed) {
        switch placed {
        case .groove(let p): sectionGrooves.append(p)
        case .bass(let p): sectionBasses.append(p)
        case .keys(let p): sectionKeys.append(p)
        }
    }

    /// A node through its part's strip, or straight to the main mixer when it has no part.
    private static func route(_ node: AVAudioNode?, part: PartID?, on graph: MixGraph) throws {
        guard let node else { return }
        if let part { try graph.route(node, to: part) } else { try graph.unroute(node) }
    }

    /// The buffer from `seconds` in: what a take that was already sounding at the bar the
    /// transport started from plays. The whole buffer when there is nothing to skip; an empty
    /// one when the skip is past its end, which the plan already declines to schedule.
    static func skipping(_ buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer {
        guard seconds > 0, buffer.format.sampleRate > 0 else { return buffer }
        let skip = AVAudioFrameCount(min(Double(buffer.frameLength), (seconds * buffer.format.sampleRate).rounded()))
        let remaining = buffer.frameLength - skip
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(1, remaining)) else { return buffer }
        trimmed.frameLength = remaining
        guard remaining > 0, let from = buffer.floatChannelData, let into = trimmed.floatChannelData else { return trimmed }
        for channel in 0..<Int(buffer.format.channelCount) {
            into[channel].update(from: from[channel] + Int(skip), count: Int(remaining))
        }
        return trimmed
    }

    func reading() async -> PlaybackReading {
        guard let engine, engine.isTransportRunning else { return .stopped }
        // Negative during the realtime lead time, when transport zero is still in the future.
        let seconds = max(0, engine.transportSeconds ?? 0)
        let hits = bouncedHits
            + sectionGrooves.reduce(0) { $0 + $1.scheduledHitCount }
            + sectionBasses.reduce(0) { $0 + $1.scheduledHitCount }
            + sectionKeys.reduce(0) { $0 + $1.scheduledHitCount }
        if let endsAt, seconds >= endsAt {
            return PlaybackReading(isRunning: false, seconds: endsAt, scheduledHits: hits)
        }
        return PlaybackReading(isRunning: true, seconds: seconds, scheduledHits: hits)
    }

    // MARK: Internals

    /// Where the plan runs out, or nil when anything in it plays forever.
    private static func end(of plan: SongPlayback, players: [Placed], longestTrack: Double?) -> Double? {
        var end = [plan.audioDuration, longestTrack].compactMap { $0 }.max()
        for player in players {
            guard let playerEnd = player.endTime else { return nil }
            end = max(playerEnd, end ?? 0)
        }
        return end
    }

    /// Every player this run placed, whatever kind it is.
    private var placedPlayers: [Placed] {
        sectionGrooves.map(Placed.groove) + sectionBasses.map(Placed.bass) + sectionKeys.map(Placed.keys)
    }

    // MARK: The dusty sources

    /// The chop a groove plays on, read and cut. Nil for a groove on a machine — and for one whose
    /// chop cannot be played on (its audio gone, no slices in it), which then plays on the 808
    /// rather than keeping the whole song from starting. `chopFailures()` says which.
    private func preparedKit(for voice: SongPlayback.Voice) -> ChopGroove.Prepared? {
        guard let kit = voice.kit else { return nil }
        if let known = chopKits[kit.version] { return known }
        do {
            let prepared = try ChopGroove.prepare(kit)
            chopKits[kit.version] = prepared
            return prepared
        } catch {
            failedChops.append("\(kit.name): \(error)")
            return nil
        }
    }

    /// A bounced groove, looped or run to the song's length, through its chain.
    static func dustyGroove(_ voice: SongPlayback.Voice, on chop: ChopGroove.Prepared?,
                            loops: Bool, lengthInBars: Int?, clock: TransportClock,
                            service: AuditionService, format: AVAudioFormat) async throws
        -> (buffer: AVAudioPCMBuffer, hits: Int) {
        guard let groove = voice.groove else { throw EngineError.renderFailed("\(voice.name) is not a groove") }
        let pass = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature)
        let barsPerPass = max(1, groove.bars)
        let passes = loops ? 2 : max(1, ((lengthInBars ?? barsPerPass) + barsPerPass - 1) / barsPerPass)
        let seconds = loops ? 2 * pass : Double(passes) * pass + Dust.tail
        let dry = try await dryGroove(voice, on: chop, passes: passes, before: nil, seconds: seconds,
                                      clock: clock, service: service, format: format)
        var wet = try Dust.render(dry.bounce.planar, sampleRate: dry.bounce.sampleRate, passes: voice.chain)
        if loops {
            let frames = Int((pass * dry.bounce.sampleRate).rounded())
            wet = wet.map { Array($0.suffix(frames)) }
        }
        guard let buffer = AuditionService.buffer(planar: wet, sampleRate: dry.bounce.sampleRate, in: format) else {
            throw EngineError.renderFailed("the dusty groove could not be put in the graph's format")
        }
        return (buffer, loops ? dry.hits / 2 : dry.hits)
    }

    /// A section's bounced groove: `bars` of it through its chain, cut at the section's end, so
    /// the next section on the same node starts clean where this one stops.
    static func dustyGroove(_ voice: SongPlayback.Voice, on chop: ChopGroove.Prepared?, bars: Int,
                            seconds: Double, clock: TransportClock, service: AuditionService,
                            format: AVAudioFormat) async throws -> (buffer: AVAudioPCMBuffer, hits: Int) {
        guard let groove = voice.groove else { throw EngineError.renderFailed("\(voice.name) is not a groove") }
        let pass = Dust.duration(of: groove, tempo: clock.tempo, timeSignature: clock.timeSignature)
        let barsPerPass = max(1, groove.bars)
        let passes = max(1, (bars + barsPerPass - 1) / barsPerPass)
        let dry = try await dryGroove(voice, on: chop, passes: passes, before: seconds,
                                      seconds: Double(passes) * pass + Dust.tail,
                                      clock: clock, service: service, format: format)
        let wet = try Dust.render(dry.bounce.planar, sampleRate: dry.bounce.sampleRate, passes: voice.chain)
        let frames = Int((seconds * dry.bounce.sampleRate).rounded())
        let cut = wet.map { Array($0.prefix(frames)) }
        guard let buffer = AuditionService.buffer(planar: cut, sampleRate: dry.bounce.sampleRate, in: format) else {
            throw EngineError.renderFailed("the dusty groove could not be put in the graph's format")
        }
        return (buffer, dry.hits)
    }

    /// `passes` passes of a groove's hits, bounced dry. A groove on a chop is played on the chop's
    /// own slices, the way the Chop lane re-grooved them. Any other groove is played on its
    /// machine. `before` drops the hits at or after that many seconds.
    static func dryGroove(_ voice: SongPlayback.Voice, on chop: ChopGroove.Prepared?, passes: Int,
                          before cutoff: Double?, seconds: Double, clock: TransportClock,
                          service: AuditionService, format: AVAudioFormat) async throws
        -> (bounce: Bounce, hits: Int) {
        guard let groove = voice.groove else { throw EngineError.renderFailed("\(voice.name) is not a groove") }
        let channels = Int(format.channelCount)
        if let chop {
            let played = try ChopGroove.perform(groove, on: chop, tempo: clock.tempo,
                                                timeSignature: clock.timeSignature, passes: passes)
            let hits = cutoff.map { end in played.hits.filter { $0.time < end } } ?? played.hits
            let bounce = try await service.bounce(hits, chop: played.kit, seconds: seconds,
                                                  sampleRate: format.sampleRate, channels: channels)
            return (bounce, hits.count)
        }
        let machine = SynthMachine.preset(id: voice.sound) ?? .tr808
        let all = Dust.hits(for: groove, tempo: clock.tempo, timeSignature: clock.timeSignature, repeats: passes)
        let hits = cutoff.map { end in all.filter { $0.time < end } } ?? all
        let bounce = try await service.bounce(hits, machine: machine, seconds: seconds,
                                              sampleRate: format.sampleRate, channels: channels)
        return (bounce, hits.count)
    }

    /// A dusty chop as a buffer: its bar of the record, through its chain, in the graph's format.
    /// `repeatedTo` lays the bar end to end to fill that many seconds — a section's worth — and
    /// cuts the last copy where the section ends.
    ///
    /// With a `clock`, the bar is first fitted to the song's own bars (`fitted`), so a loop cut at
    /// the record's tempo keeps time with a song at another.
    static func dustyChop(_ chop: SongPlayback.ChopTrack, format: AVAudioFormat, clock: TransportClock? = nil,
                          repeatedTo seconds: Double? = nil) throws -> AVAudioPCMBuffer {
        let span = try AudioRegion.read(chop.url, from: chop.region.start, to: chop.region.end)
        guard !span.planar.isEmpty, span.planar[0].count > 0 else {
            throw EngineError.invalidRegion("\(chop.name) is empty between "
                + String(format: "%.2f s and %.2f s", chop.region.start, chop.region.end))
        }
        let dry = try clock.map { try fitted(span.planar, sampleRate: span.sampleRate, of: chop, to: $0) } ?? span.planar
        var wet = try Dust.render(dry, sampleRate: span.sampleRate, passes: chop.passes)
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

    /// A chop's bar stretched to the song's tempo (`ChopTrack.loopSeconds`), with its pitch kept.
    /// Stretched dry, before its dust, so the stretcher does not smear the grit. Left as it is when
    /// its tempo is unknown, when it already fits, or when the fit would more than halve or double
    /// it — a tempo read at half or double time is a misreading, not a request.
    nonisolated static func fitted(_ planar: [[Float]], sampleRate: Double, of chop: SongPlayback.ChopTrack,
                                   to clock: TransportClock) throws -> [[Float]] {
        guard let frames = planar.first?.count, frames > 0, sampleRate > 0,
              let target = chop.loopSeconds(songTempo: clock.tempo, beatsPerBar: clock.timeSignature.beatsPerBar)
        else { return planar }
        let ratio = target / (Double(frames) / sampleRate)
        guard abs(ratio - 1) > 0.001, (0.5...2).contains(ratio) else { return planar }
        return try SignalsmithTimeStretcher(preset: .percussive)
            .stretch(planar: planar, sampleRate: sampleRate, ratio: ratio)
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
