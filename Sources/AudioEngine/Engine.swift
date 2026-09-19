import AVFAudio
import AudioToolbox
import Foundation

// MARK: - Errors

public enum EngineError: Error, Sendable, Equatable {
    case notRunning
    case alreadyRunning
    case notInOfflineMode
    case transportNotStarted
    case transportAlreadyStarted
    case playerIndexOutOfRange(Int)
    case formatMismatch(String)
    case invalidRegion(String)
    case renderFailed(String)
    case noAudioFiles(URL)
}

// MARK: - Mode

public enum EngineMode: Sendable, Equatable {
    /// Rendering to the default output device.
    case realtime
    /// Manual rendering mode (`AVAudioEngine.enableManualRenderingMode(.offline, ...)`).
    case offline(sampleRate: Double, maximumFrames: AVAudioFrameCount)

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

// MARK: - Transport

/// A running transport: the clock plus the anchors that map transport seconds onto
/// the player-node timelines and the audio-unit render timeline.
///
/// Player nodes are all started at transport zero, so their sample time 0 *is* transport
/// zero. Audio units (the sampler) see the engine's render sample time, whose value at
/// transport zero is `originSampleTime`.
public struct Transport: Sendable {
    public let clock: TransportClock
    public let mode: EngineMode
    /// Engine render-timeline sample time at transport zero.
    public let originSampleTime: AVAudioFramePosition

    public init(clock: TransportClock, mode: EngineMode, originSampleTime: AVAudioFramePosition) {
        self.clock = clock
        self.mode = mode
        self.originSampleTime = originSampleTime
    }

    public var sampleRate: Double { clock.sampleRate }

    /// Player-node relative frame for a transport time.
    public func playerFrame(atSeconds seconds: Double) -> AVAudioFramePosition {
        clock.frame(forSeconds: seconds)
    }

    /// `AVAudioTime` to hand to `AVAudioPlayerNode.scheduleBuffer(_:at:...)`.
    /// Host time in realtime; sample time (player relative) offline.
    public func playerTime(atSeconds seconds: Double) -> AVAudioTime {
        clock.audioTime(forSeconds: seconds)
    }

    /// Same as `playerTime(atSeconds:)` but from a player-relative frame, so callers that
    /// do integer frame arithmetic (loops) stay sample-exact offline.
    public func playerTime(atFrame frame: AVAudioFramePosition) -> AVAudioTime {
        if mode.isOffline || clock.startHostTime == nil {
            return AVAudioTime(sampleTime: frame, atRate: sampleRate)
        }
        return clock.audioTime(forSeconds: clock.seconds(forFrame: frame))
    }

    public func playerTime(atBeat beat: Double) -> AVAudioTime {
        playerTime(atSeconds: clock.seconds(forBeat: beat))
    }

    /// Audio-unit event sample time (for `AUScheduleMIDIEventBlock`) for a transport time.
    public func auSampleTime(atSeconds seconds: Double) -> AUEventSampleTime {
        originSampleTime + clock.frame(forSeconds: seconds)
    }
}

// MARK: - ScheduledSource

/// Something that schedules audio or MIDI ahead of the transport.
///
/// The engine calls `schedule(through:)` with a monotonically increasing transport time;
/// the source must schedule every event whose time is `< through` that it has not yet
/// scheduled. In realtime the engine's look-ahead timer drives this; offline the
/// `OfflineRenderer` calls it before each render chunk. Scheduling therefore never depends
/// on a render callback in either mode.
@AudioActor
public protocol ScheduledSource: AnyObject {
    /// Called once when the transport starts; reset any per-run scheduling state.
    func transportDidStart(_ transport: Transport)
    /// Schedule all events with transport time `< seconds` that are not yet scheduled.
    func schedule(through seconds: Double)
    /// Called before the transport stops.
    func transportWillStop()
}

// MARK: - Engine

/// Owns the `AVAudioEngine` graph: N player nodes and one sampler into the main mixer.
///
/// The same instance runs in realtime (`start()`) or in manual rendering mode
/// (`prepare(offlineSampleRate:maximumFrames:)` then `start()`); sources built on it
/// schedule through `Transport`, which hides the difference.
@AudioActor
public final class Engine {
    public let avEngine: AVAudioEngine
    public let mainMixer: AVAudioMixerNode
    public let sampler: AVAudioUnitSampler
    public let players: [AVAudioPlayerNode]
    /// The format on every source -> mixer connection. Player timelines and the sampler's
    /// render timeline run at this sample rate; offline rendering reconnects the graph at
    /// the render rate so the two never disagree.
    public private(set) var format: AVAudioFormat

    public private(set) var mode: EngineMode = .realtime
    public private(set) var transport: Transport?

    /// How far ahead of "now" the realtime look-ahead timer schedules, in seconds.
    public var lookAhead: Double = 0.25
    /// Period of the realtime look-ahead timer, in seconds.
    public var lookAheadInterval: Double = 0.05

    public var isRunning: Bool { avEngine.isRunning }
    public var isTransportRunning: Bool { transport != nil }
    public var manualRenderingSampleTime: AVAudioFramePosition { avEngine.manualRenderingSampleTime }

    private var sources: [ObjectIdentifier: any ScheduledSource] = [:]
    private var sourceOrder: [ObjectIdentifier] = []
    private var scheduledThrough: Double = -.infinity
    private var lookAheadTask: Task<Void, Never>?

    /// Builds and connects the graph. Nothing is started.
    /// - Parameters:
    ///   - playerCount: number of `AVAudioPlayerNode`s to create.
    ///   - sampleRate: sample rate of the internal connections.
    ///   - channels: channel count of the internal connections.
    public init(playerCount: Int = 4, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) throws {
        precondition(playerCount >= 1)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw EngineError.formatMismatch("could not create format \(sampleRate)/\(channels)")
        }
        self.format = format
        let engine = AVAudioEngine()
        self.avEngine = engine
        self.mainMixer = engine.mainMixerNode
        self.sampler = AVAudioUnitSampler()
        self.players = (0..<playerCount).map { _ in AVAudioPlayerNode() }

        engine.attach(sampler)
        // The explicit `format` here is load-bearing, not tidiness. `scheduleMIDIEventBlock`
        // timestamps are in the sampler's OUTPUT BUS sample rate. Connecting with `format: nil`
        // leaves that bus at 44.1 kHz while the engine renders at 48 kHz, and every scheduled hit
        // drifts 8.84% late, cumulatively (measured: 176 ms of error 2 s in). Silent and very hard
        // to diagnose. Keep the format explicit here and in `reconnect(format:)`.
        try engine.connectNode(sampler, to: mainMixer, format: format)
        for player in players {
            engine.attach(player)
            try engine.connectNode(player, to: mainMixer, format: format)
        }
    }

    // MARK: lifecycle

    /// Put the engine in manual rendering mode. Must be called while stopped.
    public func prepare(offlineSampleRate sampleRate: Double, channels: AVAudioChannelCount? = nil,
                        maximumFrames: AVAudioFrameCount = 4096) throws {
        guard !avEngine.isRunning else { throw EngineError.alreadyRunning }
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                               channels: channels ?? format.channelCount) else {
            throw EngineError.formatMismatch("could not create render format")
        }
        try avEngine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maximumFrames)
        if renderFormat.sampleRate != format.sampleRate || renderFormat.channelCount != format.channelCount {
            try reconnect(format: renderFormat)
        }
        mode = .offline(sampleRate: sampleRate, maximumFrames: maximumFrames)
    }

    /// Reconnect every source to the mixer with a new format.
    private func reconnect(format newFormat: AVAudioFormat) throws {
        // See the note in the initializer: an implicit format here reintroduces sampler drift.
        try avEngine.connectNode(sampler, to: mainMixer, format: newFormat)
        for player in players {
            try avEngine.connectNode(player, to: mainMixer, format: newFormat)
        }
        format = newFormat
    }

    /// Leave manual rendering mode. Must be called while stopped.
    public func prepareRealtime() throws {
        guard !avEngine.isRunning else { throw EngineError.alreadyRunning }
        if avEngine.isInManualRenderingMode { avEngine.disableManualRenderingMode() }
        mode = .realtime
    }

    /// Start the engine in whichever mode it is prepared for.
    public func start() throws {
        guard !avEngine.isRunning else { return }
        avEngine.prepare()
        try avEngine.start()
    }

    /// Stop the transport (if running) and the engine.
    public func stop() {
        stopTransport()
        avEngine.stop()
    }

    // MARK: players

    public func player(_ index: Int) throws -> AVAudioPlayerNode {
        guard players.indices.contains(index) else { throw EngineError.playerIndexOutOfRange(index) }
        return players[index]
    }

    // MARK: sources

    public func add(_ source: any ScheduledSource) {
        let id = ObjectIdentifier(source)
        guard sources[id] == nil else { return }
        sources[id] = source
        sourceOrder.append(id)
        if let transport {
            source.transportDidStart(transport)
            if scheduledThrough > -.infinity { source.schedule(through: scheduledThrough) }
        }
    }

    public func remove(_ source: any ScheduledSource) {
        let id = ObjectIdentifier(source)
        sources[id] = nil
        sourceOrder.removeAll { $0 == id }
    }

    // MARK: transport

    /// Start the transport: anchors the clock, starts every player node at transport zero
    /// and (in realtime) the look-ahead scheduling timer.
    ///
    /// - Parameters:
    ///   - clock: tempo / time signature. `sampleRate` and `startHostTime` are overwritten.
    ///   - leadTime: realtime only; how far in the future transport zero is placed so the
    ///     first events are not already in the past when they are scheduled.
    @discardableResult
    public func startTransport(clock: TransportClock, leadTime: Double = 0.1) throws -> Transport {
        guard avEngine.isRunning else { throw EngineError.notRunning }
        guard transport == nil else { throw EngineError.transportAlreadyStarted }

        var clock = clock
        let transport: Transport
        let playerStartTime: AVAudioTime?
        switch mode {
        case .offline(let sampleRate, _):
            clock.sampleRate = sampleRate
            clock.startHostTime = nil
            // Players started without a time begin at the next render call, i.e. at the
            // current manual-rendering sample time.
            playerStartTime = nil
            transport = Transport(clock: clock, mode: mode, originSampleTime: avEngine.manualRenderingSampleTime)

        case .realtime:
            // Player timelines and the sampler render at the graph format's rate, even if
            // the output device runs at another rate (the mixer converts).
            clock.sampleRate = format.sampleRate
            let startHost = mach_absolute_time() &+ TransportClock.hostTicks(forSeconds: max(0, leadTime))
            clock.startHostTime = startHost
            playerStartTime = AVAudioTime(hostTime: startHost)
            // Extrapolate the sampler's (hostTime, sampleTime) pair to transport zero so
            // audio-unit events can be scheduled in its render sample time.
            var origin: AVAudioFramePosition = 0
            let anchor = sampler.lastRenderTime ?? mainMixer.lastRenderTime
            if let last = anchor, last.isHostTimeValid, last.isSampleTimeValid {
                let delta: Double = startHost >= last.hostTime
                    ? TransportClock.seconds(forHostTicks: startHost - last.hostTime)
                    : -TransportClock.seconds(forHostTicks: last.hostTime - startHost)
                origin = last.sampleTime + AVAudioFramePosition((delta * clock.sampleRate).rounded())
            }
            transport = Transport(clock: clock, mode: mode, originSampleTime: origin)
        }

        self.transport = transport
        scheduledThrough = -.infinity
        for id in sourceOrder { sources[id]?.transportDidStart(transport) }

        // Schedule the first look-ahead window BEFORE starting the players. A buffer
        // scheduled on a player that is not yet playing is handed to the render side
        // synchronously; one scheduled on a playing player is handed off asynchronously and
        // (in manual rendering mode) can be overtaken by the render loop and silently
        // dropped. See `commitOfflineScheduling()` for the steady-state guard.
        schedule(through: lookAhead)
        for player in players { try player.playAudio(at: playerStartTime) }

        if case .realtime = mode {
            startLookAheadTimer()
        }
        return transport
    }

    /// Manual rendering mode only: make every buffer scheduled so far visible to the render
    /// loop before the next `renderOffline`.
    ///
    /// `AVAudioPlayerNode.scheduleBuffer` on a *playing* node hands the buffer to the render
    /// side asynchronously. In realtime that latency is hidden by the look-ahead; offline the
    /// render loop runs faster than the hand-off, so a buffer can arrive "late" by more than
    /// its own length and be trimmed to nothing. Pausing and resuming the player flushes
    /// the hand-off synchronously, and since no frames render while paused the player
    /// timeline is untouched (verified sample-exact on macOS 27).
    public func commitOfflineScheduling() throws {
        guard mode.isOffline, transport != nil else { return }
        for player in players where player.isPlaying {
            player.pause()
            try player.playAudio()
        }
    }

    /// Stop the transport: cancels the look-ahead timer, notifies sources and stops the players.
    public func stopTransport() {
        guard transport != nil else { return }
        lookAheadTask?.cancel()
        lookAheadTask = nil
        for id in sourceOrder { sources[id]?.transportWillStop() }
        for player in players { player.stop() }
        transport = nil
        scheduledThrough = -.infinity
    }

    /// Ask every source to schedule events up to `seconds` (transport time). Monotonic:
    /// earlier values are ignored.
    public func schedule(through seconds: Double) {
        guard transport != nil, seconds > scheduledThrough else { return }
        scheduledThrough = seconds
        for id in sourceOrder { sources[id]?.schedule(through: seconds) }
    }

    /// Transport time "now" in realtime, or the render position offline.
    public var transportSeconds: Double? {
        guard let transport else { return nil }
        switch transport.mode {
        case .offline:
            return Double(avEngine.manualRenderingSampleTime - transport.originSampleTime) / transport.sampleRate
        case .realtime:
            return transport.clock.seconds(forHostTime: mach_absolute_time())
        }
    }

    private func startLookAheadTimer() {
        lookAheadTask?.cancel()
        let interval = lookAheadInterval
        lookAheadTask = Task { @AudioActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tickLookAhead()
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
    }

    private func tickLookAhead() {
        guard let now = transportSeconds else { return }
        schedule(through: now + lookAhead)
    }

    // MARK: offline rendering primitive

    /// Render `frames` frames into `buffer` in manual rendering mode. Sources are asked to
    /// schedule through the end of this chunk plus `lookAhead` first.
    @discardableResult
    public func renderOffline(frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        guard case .offline(let sampleRate, _) = mode else { throw EngineError.notInOfflineMode }
        guard avEngine.isRunning else { throw EngineError.notRunning }
        if let transport {
            let end = Double(avEngine.manualRenderingSampleTime + AVAudioFramePosition(frames) - transport.originSampleTime) / sampleRate
            schedule(through: end + lookAhead)
            try commitOfflineScheduling()
        }
        return try avEngine.renderOffline(frames, to: buffer)
    }
}
