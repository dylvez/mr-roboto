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
    private var player: AVAudioPlayerNode?

    /// Which sampler a sound wants.
    ///
    /// A sampler holds **one** kit, which is why the bass has never shared the drums'. Three
    /// families, because grooves, bass lines and pitched parts are three kinds of kit — and a
    /// `part`, because two lanes of the same family can sound at once now: a pad holding the chords
    /// under a lead playing the tune is two instrument kits, not one.
    ///
    /// `part == nil` is the **surface's** sampler: a Grid step, a chop pad, a key on the piano
    /// roll. A surface has no lane; it is playing what is under your finger. It is deliberately not
    /// the same sampler the transport uses for that part, so the song going on playing a Wurlitzer
    /// while you audition a Juno is two kits, not a fight over one.
    public struct SamplerKey: Hashable, Sendable {
        public enum Family: String, Sendable { case drums, bass, instrument }
        public var family: Family
        public var part: PartID?

        public init(_ family: Family, part: PartID? = nil) {
            self.family = family
            self.part = part
        }
    }

    /// One sampler and what is true about it for its lifetime.
    private final class Loaded {
        let sampler: VoiceSampler
        var attached = false
        var kitID: String?
        init(_ sampler: VoiceSampler) { self.sampler = sampler }
    }

    private var samplers: [SamplerKey: Loaded] = [:]
    /// The last render of each chop kit, by the id it was prepared under, so the next render can
    /// let it go.
    private var chopRenders: [String: LoadedKit] = [:]

    /// Which kit the surface's drum sampler is holding. Surfaces share it, so a Grid step and a
    /// chop pad can take it from each other; each adapter checks this and re-prepares its own kit
    /// when it has been displaced, which costs one prepare rather than a wrong sound. The
    /// transport's samplers are keyed by part and never displace this one.
    public var currentKitID: String? { samplers[SamplerKey(.drums)]?.kitID }
    public var currentBassID: String? { samplers[SamplerKey(.bass)]?.kitID }
    public var currentInstrumentID: String? { samplers[SamplerKey(.instrument)]?.kitID }

    /// The parts that currently hold a sampler of their own. What a test asserts on to see that a
    /// lane's kit was let go of rather than kept resident.
    public var laneParts: Set<PartID> { Set(samplers.keys.compactMap(\.part)) }

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
        let folder = kitsDirectory.appendingPathComponent(SynthesizedKit.folderName(for: machine), isDirectory: true)
        let kit: LoadedKit
        if let existing = try? KitStore.load(from: folder) {
            kit = existing
        } else {
            kit = try SynthesizedKit.build(machine, in: folder, sampleRate: rate)
        }
        return try bounce(hits, on: kit, cache: cache, seconds: seconds, sampleRate: rate, channels: channels)
    }

    /// Hits on a rendered chop, bounced the same way: what a groove played on a chop sounds like.
    ///
    /// The kit gets a folder and a cache of its own, and both are thrown away after the bounce. A
    /// chop's kit is rendered again whenever its cut or its groove changes, and the shared cache
    /// keys buffers by file. A kit rewritten in place would be heard as the one before it.
    public func bounce(_ hits: [VoiceSampler.Hit], chop: ChopKit, seconds: Double,
                       sampleRate: Double? = nil, channels: Int = 2) async throws -> Bounce {
        let rate = sampleRate ?? engine?.format.sampleRate ?? 48_000
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-roboto-chop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kit = try chop.write(to: folder)
        return try bounce(hits, on: kit, cache: SampleCache(), seconds: seconds, sampleRate: rate, channels: channels)
    }

    private func bounce(_ hits: [VoiceSampler.Hit], on kit: LoadedKit, cache: SampleCache, seconds: Double,
                        sampleRate rate: Double, channels: Int) throws -> Bounce {
        let offline = try Engine(playerCount: 1, sampleRate: rate, channels: AVAudioChannelCount(channels))
        try offline.prepare(offlineSampleRate: rate, maximumFrames: 4_096)
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
        try await prepare(machine: machine, for: nil)
    }

    /// The same, for one lane of the song rather than for the surfaces.
    @discardableResult
    public func prepare(machine: SynthMachine, for part: PartID?) async throws -> VoiceSampler {
        let engine = try await liveEngine()
        let key = SamplerKey(.drums, part: part)
        if let entry = samplers[key], entry.kitID == machine.id { return entry.sampler }
        return try install(drumKit(machine, on: engine), id: machine.id, for: key, on: engine)
    }

    /// Make a rendered chop playable. `id` names the kit so a surface can tell whether the sampler
    /// is still holding its own.
    ///
    /// Every call installs what it is handed, even under an id the sampler already holds: a lane
    /// renders its kit again after every cut, class and trim, under the one id. Each render is
    /// written to a folder of its own because the cache keys buffers by file. A kit rewritten in
    /// place would come back as the one before it. The render before is dropped from the cache
    /// and the disk once this one is in. The sampler keeps its own hold on the old buffers until
    /// the swap is acknowledged, so a voice still ringing on them is not cut off.
    public func prepare(chop: ChopKit, id: String) async throws {
        let engine = try await liveEngine()
        let root = kitsDirectory.appendingPathComponent("chops/\(Self.safe(id))", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let loaded = try chop.write(to: folder)
        try install(loaded, id: id, for: SamplerKey(.drums), on: engine, replacing: true)
        if let previous = chopRenders[id] {
            for url in previous.sampleURLs { cache.remove(url: url, sampleRate: engine.format.sampleRate) }
            try? FileManager.default.removeItem(at: previous.folder)
        }
        chopRenders[id] = loaded
    }

    /// Play hits against whatever kit is loaded, now. `Hit.time` is seconds from this instant.
    public func play(_ hits: [VoiceSampler.Hit]) async {
        guard !hits.isEmpty else { return }
        guard let sampler = samplers[SamplerKey(.drums)]?.sampler, sampler.kit != nil else {
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

    /// The sampler a groove lane plays on, holding `machine`'s kit.
    ///
    /// Keyed by the part, so the transport never displaces what a surface has loaded: the song can
    /// go on playing an 808 while you audition an SP-1200 under your finger. It used to take the
    /// one sampler from whichever surface had it, which cost a re-prepare on the next touch.
    public func playbackSampler(machine: SynthMachine, for part: PartID? = nil) async throws -> VoiceSampler {
        try await prepare(machine: machine, for: part)
    }

    // MARK: The bass

    /// The bass sampler, holding `voice`'s kit — built into the kits directory the first time,
    /// loaded from there after. A voice already loaded costs nothing.
    public func prepare(bass voice: BassVoiceSpec) async throws {
        try await prepare(bass: voice, for: nil)
    }

    @discardableResult
    public func prepare(bass voice: BassVoiceSpec, for part: PartID?) async throws -> VoiceSampler {
        let engine = try await liveEngine()
        let key = SamplerKey(.bass, part: part)
        if let entry = samplers[key], entry.kitID == voice.id { return entry.sampler }
        return try install(bassKit(voice, on: engine), id: voice.id, for: key, on: engine)
    }

    /// The instrument sampler, holding `spec`'s kit. Built into the kits directory the first time —
    /// a pitched kit is 19 roots × its velocity layers, so the first build of a preset takes a
    /// moment — and loaded from there ever after.
    public func prepare(instrument spec: InstrumentVoiceSpec) async throws {
        try await prepare(instrument: spec, for: nil)
    }

    @discardableResult
    public func prepare(instrument spec: InstrumentVoiceSpec, for part: PartID?) async throws -> VoiceSampler {
        let engine = try await liveEngine()
        let key = SamplerKey(.instrument, part: part)
        if let entry = samplers[key], entry.kitID == spec.id { return entry.sampler }
        return try install(instrumentKit(spec, on: engine), id: spec.id, for: key, on: engine)
    }

    /// The sampler a pitched lane plays on, holding `spec`'s kit. One per part, which is what lets
    /// a pad hold the chords while a lead plays the tune over them.
    public func playbackInstrumentSampler(_ spec: InstrumentVoiceSpec, for part: PartID? = nil) async throws -> VoiceSampler {
        try await prepare(instrument: spec, for: part)
    }

    /// Play notes on the loaded instrument now. `Hit.time` is seconds from this instant, so a
    /// chord is three hits at 0 and a phrase is hits at their beats.
    @discardableResult
    public func playInstrument(_ hits: [VoiceSampler.Hit]) async -> [VoiceSampler.VoiceHandle] {
        guard !hits.isEmpty else { return [] }
        guard let instrumentSampler = samplers[SamplerKey(.instrument)]?.sampler,
              instrumentSampler.kit != nil else {
            lastFailure = "no instrument is prepared to play"
            return []
        }
        do {
            let engine = try await running()
            let now = renderPosition(on: engine, node: instrumentSampler.node)
            instrumentSampler.transportDidStart(originSampleTime: now, sampleRate: engine.format.sampleRate)
            let handles = try instrumentSampler.play(hits)
            lastFailure = nil
            return handles
        } catch {
            lastFailure = "\(error)"
            return []
        }
    }

    /// Lets go of held instrument notes, now.
    public func stopInstrument(_ handles: [VoiceSampler.VoiceHandle]) {
        guard let instrumentSampler = samplers[SamplerKey(.instrument)]?.sampler else { return }
        for handle in handles { instrumentSampler.stop(handle) }
    }

    /// The sampler a bass lane plays on, holding `voice`'s kit.
    public func playbackBassSampler(voice: BassVoiceSpec, for part: PartID? = nil) async throws -> VoiceSampler {
        try await prepare(bass: voice, for: part)
    }

    /// Play bass hits now, on whichever bass voice is loaded. `Hit.time` is seconds from this instant.
    /// The handles stop a held note (`stopBass`) — a key on a controller, let go.
    @discardableResult
    public func playBass(_ hits: [VoiceSampler.Hit]) async -> [VoiceSampler.VoiceHandle] {
        guard !hits.isEmpty else { return [] }
        guard let bassSampler = samplers[SamplerKey(.bass)]?.sampler, bassSampler.kit != nil else {
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
        guard let bassSampler = samplers[SamplerKey(.bass)]?.sampler else { return }
        for handle in handles { bassSampler.stop(handle) }
    }

    // MARK: Stopping

    /// Silence everything this service is playing. Never throws: stopping is always allowed.
    public func stop() async {
        for entry in samplers.values { entry.sampler.allNotesOff() }
        player?.stop()
    }

    /// Give the graph back. Detaches the sampler's node **before** `unprepare()`, which is the
    /// lifetime contract `VoiceSampler` documents: `unprepare` frees the memory the render block
    /// reads, so an attached node would be reading freed samples.
    public func shutdown() async {
        await stop()
        // Two loops, in this order: every attached node comes off the engine before any sampler is
        // unprepared. One loop doing both would free the zones of the first sampler while the
        // second was still attached and rendering.
        if let engine {
            for entry in samplers.values where entry.attached {
                if let node = entry.sampler.node { engine.avEngine.detach(node) }
                entry.attached = false
            }
            if let player { engine.avEngine.detach(player) }
        }
        player = nil
        for entry in samplers.values { entry.sampler.unprepare() }
        samplers = [:]
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

    /// The one door every kit goes through: the sampler for a key, holding `kit`.
    ///
    /// Swap the kit in place. `unprepare()` here would destroy the node, `prepare` would build a
    /// new one, and the attach-once flag below would leave that new node unattached — then the
    /// first note asks an engine-less node for its render time and AVFAudio raises. That is the
    /// Rhodes-to-Wurlitzer crash. `prepare` is safe to call again while rendering: it retires the
    /// old zones by epoch and keeps the node. There are N samplers now rather than three, which is
    /// more chances to get this wrong, not fewer.
    @discardableResult
    private func install(_ kit: LoadedKit, id: String, for key: SamplerKey, on engine: Engine,
                         replacing: Bool = false) throws -> VoiceSampler {
        let format = engine.format
        let entry = samplers[key] ?? Loaded(VoiceSampler(cache: cache))
        samplers[key] = entry
        guard replacing || entry.kitID != id else { return entry.sampler }
        // The sampler's format is locked by its first `prepare`, so it is the graph's from the
        // start — a sampler rendering at another rate would put every hit on the wrong frame.
        try entry.sampler.prepare(kit, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        if !entry.attached, let node = entry.sampler.node {
            engine.avEngine.attach(node)
            try engine.avEngine.connectNode(node, to: engine.mainMixer, format: format)
            entry.attached = true
        }
        entry.kitID = id
        return entry.sampler
    }

    /// The kit for a drum machine, built into the cache on first use.
    private func drumKit(_ machine: SynthMachine, on engine: Engine) throws -> LoadedKit {
        let name = SynthesizedKit.folderName(for: machine)
        let folder = kitsDirectory.appendingPathComponent(name, isDirectory: true)
        if let existing = try? KitStore.load(from: folder) { return existing }
        let built = try SynthesizedKit.build(machine, in: folder, sampleRate: engine.format.sampleRate)
        clearStaleKits(prefix: machine.id, keeping: name)
        return built
    }

    private func bassKit(_ voice: BassVoiceSpec, on engine: Engine) throws -> LoadedKit {
        let name = SynthesizedBass.folderName(for: voice)
        let folder = kitsDirectory.appendingPathComponent(name, isDirectory: true)
        if let existing = try? KitStore.load(from: folder) { return existing }
        let built = try SynthesizedBass.build(voice, in: folder, sampleRate: engine.format.sampleRate)
        clearStaleKits(prefix: "bass-\(voice.id)", keeping: name)
        return built
    }

    private func instrumentKit(_ spec: InstrumentVoiceSpec, on engine: Engine) throws -> LoadedKit {
        // An imported instrument is its own kit, in the library; nothing is rendered or cached.
        if spec.engine == .sampled { return try SynthesizedInstrument.build(spec, in: kitsDirectory) }
        let name = SynthesizedInstrument.folderName(for: spec)
        let folder = kitsDirectory.appendingPathComponent(name, isDirectory: true)
        if let existing = try? KitStore.load(from: folder) { return existing }
        let built = try SynthesizedInstrument.build(spec, in: folder, sampleRate: engine.format.sampleRate)
        clearStaleKits(prefix: "instrument-\(spec.id)", keeping: name)
        return built
    }

    /// The renders of a voice from before its settings changed: nothing loads them again.
    private func clearStaleKits(prefix: String, keeping current: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: kitsDirectory.path)) ?? []
        for name in names where KitFingerprint.isStale(name, prefix: prefix, current: current) {
            try? FileManager.default.removeItem(at: kitsDirectory.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Lets go of every lane sampler whose part is not in `parts`, so a song closed or a form
    /// rewritten does not leave its kits resident forever. The surfaces' samplers — the `part: nil`
    /// three — are never retired: they belong to the app, not to a plan.
    ///
    /// Called from `LiveSongPlayer.end()` *after* every source has come off the engine, which is
    /// the one window where no render block is reading these zones. Detach before unprepare, as
    /// everywhere else.
    public func retire(partsOtherThan parts: Set<PartID>) async {
        for (key, entry) in samplers {
            guard let part = key.part, !parts.contains(part) else { continue }
            entry.sampler.allNotesOff()
            if entry.attached, let node = entry.sampler.node { engine?.avEngine.detach(node) }
            entry.sampler.unprepare()
            samplers[key] = nil
        }
    }

    /// Anchor the sampler's clock at the current render position, so hit times are seconds from now.
    private func anchorNow(on engine: Engine) {
        guard let sampler = samplers[SamplerKey(.drums)]?.sampler else { return }
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
