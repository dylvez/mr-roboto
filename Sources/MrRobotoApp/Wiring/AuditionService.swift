import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// The one place in the app that makes a sound on a touch.
///
/// Every surface's contract says the same thing — a candidate, a slice, a step or a knob plays
/// *immediately*, with no agent round trip — and none of the four could satisfy it alone, because
/// each of them was written against a host protocol and none of them owns an engine. This is that
/// engine, and it is deliberately the only one the wiring builds:
///
/// * **one `AudioEngine.Engine`**, taken from the frame (`AppState.engine()`), so a surface
///   auditioning and the transport playing are the same graph rather than two that fight over the
///   output device;
/// * **one `Instrument.VoiceSampler`**, attached to that graph once and then only ever handed new
///   kits — `prepare(_:)` is documented as safe to call again while rendering, and a kit swap is
///   what switching machine or re-cutting a chop actually is;
/// * **started lazily, on the first audition, and never restarted per touch**. The whole point of
///   "plays on touch" is that the second touch is as fast as the first.
///
/// Two lifetime rules from the modules below are honoured here rather than rediscovered:
///
/// 1. `VoiceSampler.unprepare()` frees the memory its render block reads, so the node is detached
///    from the `AVAudioEngine` **first**. `shutdown()` is the only place either happens.
/// 2. Every `connectNode` call passes an explicit format. `Engine`'s own initializer carries the
///    measurement: an implicit format leaves the node's output bus at 44.1 kHz while the graph
///    renders at 48, and every scheduled hit drifts 8.84% late, cumulatively and silently.
///
/// This shell has no audio device, so nothing here is verified by listening. It is verified by
/// driving it through the engine's offline manual-rendering mode, exactly as `InstrumentTests` and
/// `AudioEngineTests` do.
@AudioActor
public final class AuditionService {

    /// How the service gets at the app's engine. A closure rather than the `Engine` itself so the
    /// engine stays lazily built (launching on a machine with no output device must not fail until
    /// someone asks for a sound) and so a test can hand in one already in manual-rendering mode.
    public typealias EngineProvider = @Sendable () async throws -> Engine

    // MARK: Collaborators

    private let provideEngine: EngineProvider
    private let kitsDirectory: URL
    private let cache = SampleCache()

    private var engine: Engine?
    private var sampler: VoiceSampler?
    private var samplerNodeAttached = false
    /// The bass has a sampler of its own: a sampler holds one kit, and the bass line and the drums
    /// play at once. Built on first use and kept, with its own node on the same mixer.
    private var bassSampler: VoiceSampler?
    private var bassSamplerNodeAttached = false
    public private(set) var currentBassID: String?
    private var player: AVAudioPlayerNode?

    /// Which kit the one sampler is currently holding. Surfaces share the sampler, so a Grid step
    /// and a chop pad can take it from each other; each adapter checks this and re-prepares its own
    /// kit when it has been displaced, which costs one prepare rather than a wrong sound.
    public private(set) var currentKitID: String?

    /// The last thing that went wrong, in the words the underlying module used. Nothing here throws
    /// at a touch: a surface that cannot make a sound stays quiet and says so, it never traps.
    public private(set) var lastFailure: String?

    // MARK: Init

    /// - Parameters:
    ///   - engine: the app's engine, fetched on first use.
    ///   - kitsDirectory: where synthesized machines and rendered chops are cached. Regenerable.
    public nonisolated init(engine: @escaping EngineProvider,
                            kitsDirectory: URL = AuditionService.defaultKitsDirectory) {
        self.provideEngine = engine
        self.kitsDirectory = kitsDirectory
    }

    /// `~/Library/Caches/MrRoboto/audition`. Deleting it costs one re-render, never a version.
    public nonisolated static var defaultKitsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("MrRoboto/audition", isDirectory: true)
    }

    // MARK: Raw samples — what Sound and Import play
    //
    // Sound hands over the floats `DrumSynthesizer.render` produced (optionally through the
    // degradation chain); Import hands over a span of the record it just read off disk. Neither is
    // a performance, so both go to one dedicated player node that the next audition interrupts.

    /// Play mono float samples at their own rate, now.
    public func play(_ samples: [Float], sampleRate: Double) async {
        await play(planar: [samples], sampleRate: sampleRate)
    }

    /// Play planar float channels at their own rate, now.
    ///
    /// The rate and channel count are converted to the graph's on the way in, rather than
    /// reconnecting the node per audition: a 44.1 kHz record and a 48 kHz render of an 808 kick are
    /// both ordinary here.
    public func play(planar: [[Float]], sampleRate: Double) async {
        guard sampleRate > 0, let frames = planar.first?.count, frames > 0 else { return }
        do {
            let engine = try await running()
            let node = try playerNode(on: engine)
            guard let buffer = Self.buffer(planar: planar, sampleRate: sampleRate, in: engine.format) else {
                lastFailure = "could not build an audition buffer at \(sampleRate) Hz"
                return
            }
            try hand(buffer, to: node)
            lastFailure = nil
        } catch {
            lastFailure = "\(error)"
        }
    }

    // MARK: A dirtied part — what Sound, the Compare and the Check play
    //
    // A dusty chop or groove is played through its own chain, and through `Dust.render`, which is
    // the one definition of what a pass sounds like. The transport's bounce goes through the same
    // call, so an audition of a version and the transport playing it are the same samples.

    /// Play planar audio as the part it came from sounds: through every pass of its chain, in order.
    /// No passes is the dry signal, bit for bit.
    public func play(planar: [[Float]], sampleRate: Double, through passes: [Degradation]) async {
        do {
            let wet = try Dust.render(planar, sampleRate: sampleRate, passes: passes)
            await play(planar: wet, sampleRate: sampleRate)
        } catch {
            lastFailure = "the chain could not run: \(error)"
        }
    }

    /// Play a groove through its chain. A dry groove goes to the shared sampler as hits, exactly as
    /// the Grid plays it; a dusty one is bounced (`bounce(_:machine:seconds:)`), put through its
    /// passes and played as audio, because the chain is a buffer process and the sampler's output
    /// is not a buffer anything here can reach while it renders.
    public func play(groove: Groove, machine: SynthMachine, tempo: Double,
                     timeSignature: TimeSignature, through passes: [Degradation]) async {
        let hits = Dust.hits(for: groove, tempo: tempo, timeSignature: timeSignature)
        guard !hits.isEmpty else { return }
        guard !passes.isEmpty else {
            do {
                try await prepare(machine: machine)
            } catch {
                lastFailure = "\(error)"
                return
            }
            await play(hits)
            return
        }
        do {
            let seconds = Dust.duration(of: groove, tempo: tempo, timeSignature: timeSignature) + Dust.tail
            let dry = try await bounce(hits, machine: machine, seconds: seconds)
            await play(planar: dry.planar, sampleRate: dry.sampleRate, through: passes)
        } catch {
            lastFailure = "\(error)"
        }
    }

    /// Hits on a machine, rendered offline to planar floats: a bounce.
    ///
    /// On its **own** engine in manual rendering mode with its own sampler, never the shared one —
    /// an offline graph touches no output device, and borrowing the shared sampler would cut off
    /// whatever a surface was auditioning. The kit is the same cached one the shared sampler plays,
    /// and the sampler core is the same C, so a bounce of a dry groove is the groove the transport
    /// plays; and `VoiceSampler.transportDidStart` resets its round robin, so two bounces of the same
    /// hits are the same bytes.
    ///
    /// - Parameters:
    ///   - seconds: how much to render, tail included.
    ///   - sampleRate: the bounce's rate. The live graph's when there is one, so the transport does
    ///     not resample what it bounced; 48 kHz otherwise.
    public func bounce(_ hits: [VoiceSampler.Hit], machine: SynthMachine, seconds: Double,
                       sampleRate: Double? = nil, channels: Int = 2) async throws -> Bounce {
        let rate = sampleRate ?? engine?.format.sampleRate ?? 48_000
        let offline = try Engine(playerCount: 1, sampleRate: rate, channels: AVAudioChannelCount(channels))
        try offline.prepare(offlineSampleRate: rate, maximumFrames: 4_096)
        let folder = kitsDirectory.appendingPathComponent(machine.id, isDirectory: true)
        let kit: LoadedKit
        if let existing = try? KitStore.load(from: folder) {
            kit = existing
        } else {
            kit = try SynthesizedKit.build(machine, in: folder, sampleRate: rate)
        }
        let sampler = VoiceSampler(cache: cache)
        try sampler.prepare(kit, sampleRate: offline.format.sampleRate, channels: Int(offline.format.channelCount))
        guard let node = sampler.node else {
            sampler.unprepare()
            throw AuditionUnavailable(what: "the bounce sampler has no node")
        }
        offline.avEngine.attach(node)
        defer {
            offline.stopTransport()
            offline.stop()
            offline.avEngine.detach(node)
            sampler.unprepare()
        }
        try offline.avEngine.connectNode(node, to: offline.mainMixer, format: offline.format)
        try offline.start()
        offline.add(sampler)
        sampler.enqueue(hits)
        _ = try offline.startTransport(clock: TransportClock(tempo: 120, sampleRate: rate))
        let frames = AVAudioFramePosition((max(0, seconds) * rate).rounded())
        let out = try OfflineRenderer.renderBuffer(engine: offline, frames: frames)
        offline.remove(sampler)
        return Bounce(planar: Self.planar(out), sampleRate: rate)
    }

    /// Planar floats out of a buffer, whatever its stride.
    static func planar(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        let stride = buffer.stride
        let frames = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            stride == 1
                ? Array(UnsafeBufferPointer(start: data[channel], count: frames))
                : (0..<frames).map { data[channel][$0 * stride] }
        }
    }

    // MARK: Kits and hits — what the Chop lane and the Grid play

    /// Make a synthesized drum machine playable. Kits are built once into the cache and reused.
    public func prepare(machine: SynthMachine) async throws {
        let engine = try await liveEngine()
        guard currentKitID != machine.id else { return }
        let folder = kitsDirectory.appendingPathComponent(machine.id, isDirectory: true)
        let loaded: LoadedKit
        if let existing = try? KitStore.load(from: folder) {
            loaded = existing
        } else {
            loaded = try SynthesizedKit.build(machine, in: folder, sampleRate: engine.format.sampleRate)
        }
        try install(loaded, id: machine.id, on: engine)
    }

    /// Make a rendered chop playable. `id` names the kit so a surface can tell whether the sampler
    /// is still holding its own.
    public func prepare(chop: ChopKit, id: String) async throws {
        let engine = try await liveEngine()
        let folder = kitsDirectory.appendingPathComponent("chops/\(Self.safe(id))", isDirectory: true)
        let loaded = try chop.write(to: folder)
        try install(loaded, id: id, on: engine)
    }

    /// Play hits against whatever kit is loaded, now. `Hit.time` is seconds from this instant.
    public func play(_ hits: [VoiceSampler.Hit]) async {
        guard !hits.isEmpty else { return }
        guard let sampler, sampler.kit != nil else {
            lastFailure = "nothing is prepared to play"
            return
        }
        do {
            let engine = try await running()
            // A single pad is always at time 0, and a hit whose frame is in the past is applied at
            // the first frame of the current block — which is exactly "now". A set that *spans*
            // time (a bar played back, a re-groove) needs its origin anchored to now, or every hit
            // in it would resolve to the past and fire at once.
            if hits.contains(where: { $0.time > 0 }) { anchorNow(on: engine) }
            _ = try sampler.play(hits)
            lastFailure = nil
        } catch {
            lastFailure = "\(error)"
        }
    }

    // MARK: The transport
    //
    // The frame's transport plays the *song*, which is a different job from auditioning — but it
    // must be the same graph. These two are the whole of what `LiveSongPlayer` needs, and they are
    // deliberately the only way in: it gets the engine this service already owns and the sampler
    // this service already attached, so a groove playing and a pad being touched are one sampler on
    // one engine rather than two of each fighting over the output device.

    /// The app's engine, built on first use exactly as an audition builds it. Not started: the
    /// transport's own host starts it, in whichever mode it was prepared for.
    public func playbackEngine() async throws -> Engine {
        try await liveEngine()
    }

    /// The one sampler, holding `machine`'s kit.
    ///
    /// Goes through `prepare(machine:)`, so a machine already loaded costs nothing and one that is
    /// not displaces whatever a surface had put there — which is correct: the transport is playing
    /// the song, and the song's own machine is what it should sound like.
    public func playbackSampler(machine: SynthMachine) async throws -> VoiceSampler {
        try await prepare(machine: machine)
        guard let sampler else { throw AuditionUnavailable(what: "the sampler was not prepared") }
        return sampler
    }

    // MARK: The bass

    /// The bass sampler, holding `voice`'s kit — built into the kits directory the first time,
    /// loaded from there after. A voice already loaded costs nothing.
    public func prepare(bass voice: BassVoiceSpec) async throws {
        let engine = try await liveEngine()
        guard currentBassID != voice.id else { return }
        let folder = kitsDirectory.appendingPathComponent(SynthesizedBass.folderName(for: voice), isDirectory: true)
        let loaded: LoadedKit
        if let existing = try? KitStore.load(from: folder) {
            loaded = existing
        } else {
            loaded = try SynthesizedBass.build(voice, in: folder, sampleRate: engine.format.sampleRate)
        }
        let format = engine.format
        let sampler = bassSampler ?? VoiceSampler(cache: cache)
        bassSampler = sampler
        if sampler.kit != nil { sampler.unprepare() }
        try sampler.prepare(loaded, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        if !bassSamplerNodeAttached, let node = sampler.node {
            engine.avEngine.attach(node)
            try engine.avEngine.connectNode(node, to: engine.mainMixer, format: format)
            bassSamplerNodeAttached = true
        }
        currentBassID = voice.id
    }

    /// The bass sampler for the transport, holding `voice`'s kit.
    public func playbackBassSampler(voice: BassVoiceSpec) async throws -> VoiceSampler {
        try await prepare(bass: voice)
        guard let bassSampler else { throw AuditionUnavailable(what: "the bass sampler was not prepared") }
        return bassSampler
    }

    /// Play bass hits now, on whichever bass voice is loaded. `Hit.time` is seconds from this instant.
    /// The handles stop a held note (`stopBass`) — a key on a controller, let go.
    @discardableResult
    public func playBass(_ hits: [VoiceSampler.Hit]) async -> [VoiceSampler.VoiceHandle] {
        guard !hits.isEmpty else { return [] }
        guard let bassSampler, bassSampler.kit != nil else {
            lastFailure = "no bass is prepared to play"
            return []
        }
        do {
            let engine = try await running()
            let now = renderPosition(on: engine, node: bassSampler.node)
            bassSampler.transportDidStart(originSampleTime: now, sampleRate: engine.format.sampleRate)
            let handles = try bassSampler.play(hits)
            lastFailure = nil
            return handles
        } catch {
            lastFailure = "\(error)"
            return []
        }
    }

    /// Lets go of held bass notes, now.
    public func stopBass(_ handles: [VoiceSampler.VoiceHandle]) {
        guard let bassSampler else { return }
        for handle in handles { bassSampler.stop(handle) }
    }

    // MARK: Stopping

    /// Silence everything this service is playing. Never throws: stopping is always allowed.
    public func stop() async {
        sampler?.allNotesOff()
        bassSampler?.allNotesOff()
        player?.stop()
    }

    /// Give the graph back. Detaches the sampler's node **before** `unprepare()`, which is the
    /// lifetime contract `VoiceSampler` documents: `unprepare` frees the memory the render block
    /// reads, so an attached node would be reading freed samples.
    public func shutdown() async {
        await stop()
        if let engine {
            if samplerNodeAttached, let node = sampler?.node { engine.avEngine.detach(node) }
            if bassSamplerNodeAttached, let node = bassSampler?.node { engine.avEngine.detach(node) }
            if let player { engine.avEngine.detach(player) }
        }
        samplerNodeAttached = false
        bassSamplerNodeAttached = false
        player = nil
        sampler?.unprepare()
        sampler = nil
        bassSampler?.unprepare()
        bassSampler = nil
        currentKitID = nil
        currentBassID = nil
        engine = nil
    }

    // MARK: - Internals

    private func liveEngine() async throws -> Engine {
        if let engine { return engine }
        let built = try await provideEngine()
        engine = built
        return built
    }

    /// The engine, started if it is not already. Started once, in whichever mode it was prepared
    /// for — realtime in the app, manual rendering in a test — and never restarted per touch.
    private func running() async throws -> Engine {
        let engine = try await liveEngine()
        if !engine.isRunning { try engine.start() }
        return engine
    }

    /// Schedule and start, synchronously.
    ///
    /// Not `async`, deliberately: `scheduleBuffer`'s async alternative waits for the buffer to
    /// finish playing, and an audition is fire-and-forget — it is interrupted by the next one, and
    /// nothing is waiting for it to end.
    private func hand(_ buffer: AVAudioPCMBuffer, to node: AVAudioPlayerNode) throws {
        // Stop first: an audition is interrupted by the next one, and stopping also flushes the
        // node's scheduling hand-off, which offline can otherwise be overtaken by the render loop
        // and silently dropped (the reason `Engine.commitOfflineScheduling` exists).
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        try node.playAudio()
    }

    private func playerNode(on engine: Engine) throws -> AVAudioPlayerNode {
        if let player { return player }
        let node = AVAudioPlayerNode()
        engine.avEngine.attach(node)
        // Explicit format. See the note in `Engine.init`: an implicit one is 8.84% of drift.
        try engine.avEngine.connectNode(node, to: engine.mainMixer, format: engine.format)
        player = node
        return node
    }

    private func install(_ kit: LoadedKit, id: String, on engine: Engine) throws {
        let format = engine.format
        let sampler = self.sampler ?? VoiceSampler(cache: cache)
        self.sampler = sampler
        // The sampler's format is locked by its first `prepare`, so it is the graph's from the
        // start — a sampler rendering at another rate would put every hit on the wrong frame.
        try sampler.prepare(kit, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        if !samplerNodeAttached, let node = sampler.node {
            engine.avEngine.attach(node)
            try engine.avEngine.connectNode(node, to: engine.mainMixer, format: format)
            samplerNodeAttached = true
        }
        currentKitID = id
    }

    /// Anchor the sampler's clock at the current render position, so hit times are seconds from now.
    private func anchorNow(on engine: Engine) {
        guard let sampler else { return }
        sampler.transportDidStart(originSampleTime: renderPosition(on: engine, node: sampler.node),
                                  sampleRate: engine.format.sampleRate)
    }

    /// The current render position, in sample time, from a node's clock or the mixer's.
    private func renderPosition(on engine: Engine, node: AVAudioNode?) -> Int64 {
        if engine.mode.isOffline { return Int64(engine.manualRenderingSampleTime) }
        if let anchor = node?.lastRenderTime ?? engine.mainMixer.lastRenderTime, anchor.isSampleTimeValid {
            return Int64(anchor.sampleTime)
        }
        return 0
    }

    /// Planar floats at one rate, as a buffer in the graph's format.
    static func buffer(planar: [[Float]], sampleRate: Double, in target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = max(1, planar.count)
        let frames = planar.map(\.count).min() ?? 0
        guard frames > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)),
              let data = input.floatChannelData else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            planar[channel].withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: frames) }
        }
        if source.sampleRate == target.sampleRate && source.channelCount == target.channelCount {
            return input
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
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
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// A directory-safe name for a kit id, so two chops never share a cache folder.
    private static func safe(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scrubbed)
    }
}

/// A rendered stretch of audio: planar floats at one rate.
public struct Bounce: Sendable {
    public var planar: [[Float]]
    public var sampleRate: Double

    public init(planar: [[Float]], sampleRate: Double) {
        self.planar = planar
        self.sampleRate = sampleRate
    }

    public var duration: Double {
        sampleRate > 0 ? Double(planar.first?.count ?? 0) / sampleRate : 0
    }
}

/// The audition rig could not give something out. Carries the reason verbatim: nothing in this
/// layer ever fails with a shrug.
public struct AuditionUnavailable: Error, CustomStringConvertible, Sendable {
    public let what: String
    public init(what: String) { self.what = what }
    public var description: String { what }
}
