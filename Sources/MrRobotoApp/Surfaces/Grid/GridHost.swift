import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The Grid surface's contract with whatever is hosting it.
//
// Four things, no more: make one voice sound now, hand the engine a new pattern, swap the machine
// under it, and tell the frame a version was made. `AppState` is being built alongside this file, so
// the surface names none of it; a stub of this protocol is all a test needs.

/// What the Grid surface needs from its host.
public protocol GridHosting: Sendable {
    /// One hit, now. Every click on a step plays that step — the Komma lesson, applied.
    func audition(_ voice: DrumVoice, velocity: Int) async

    /// The pattern the engine plays from the next pass on.
    ///
    /// Deliberately a whole-groove hand-off rather than a diff. `GroovePlayer` renders one loop
    /// iteration at a time from whatever `groove` and `options` it holds when that iteration comes
    /// due, so replacing both is exactly "takes effect on the next pass" — painting a step and
    /// moving the swing lever are the same operation to the engine, and neither reloads a kit or
    /// restarts the transport.
    func setPattern(_ groove: Groove, options: GrooveRenderOptions,
                    tempo: Double, timeSignature: TimeSignature) async

    /// Swap the drum machine under the running pattern.
    func loadMachine(_ machine: SynthMachine) async throws

    /// A new part version left the surface. `false` when the host refused it, so the surface can
    /// say so instead of showing a version the song does not have. Synchronous: a keep the frame
    /// asks for before it plays must be in the song before the transport reads it.
    @MainActor @discardableResult
    func commit(_ version: PartVersion) -> Bool

    /// The newest version of a part in the song, so a keep builds on it — and on what another
    /// surface kept in the meantime — rather than on the version this grid last saw.
    @MainActor func newest(of part: PartID) -> PartVersion?

    /// The machine picked on the grid, for the song to play this groove on.
    @MainActor func machineChosen(_ machine: SynthMachine, for part: PartID?)

    /// The chop picked on the grid instead of a machine: the groove plays the chop's slices, in the
    /// song and under a step touch.
    @MainActor func chopChosen(_ chop: PartID, for part: PartID?)
}

extension GridHosting {
    @MainActor public func commit(_ version: PartVersion) -> Bool { true }
    @MainActor public func newest(of part: PartID) -> PartVersion? { nil }
    @MainActor public func machineChosen(_ machine: SynthMachine, for part: PartID?) {}
    @MainActor public func chopChosen(_ chop: PartID, for part: PartID?) {}
}

// MARK: - The live host

/// The host the app installs: a `VoiceSampler` playing a synthesized kit, driven by a `GroovePlayer`
/// on the shared `Engine`.
///
/// Kits are built once per machine into the caches directory and reused; `SynthesizedKit.build`
/// renders every machine from the specs in `Instrument`, so switching machine is a kit swap
/// (safe at any time, including mid-render) rather than a rebuild of the audio graph.
public final class LiveGridHost: GridHosting {
    private let core: Core

    public init(kitsDirectory: URL = LiveGridHost.defaultKitsDirectory) {
        core = Core(kitsDirectory: kitsDirectory)
    }

    /// `~/Library/Caches/MrRoboto/kits`. Regenerable: deleting it costs one re-render.
    public static var defaultKitsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("MrRoboto/kits", isDirectory: true)
    }

    public func audition(_ voice: DrumVoice, velocity: Int) async {
        await core.audition(voice, velocity: velocity)
    }

    public func setPattern(_ groove: Groove, options: GrooveRenderOptions,
                           tempo: Double, timeSignature: TimeSignature) async {
        await core.setPattern(groove, options: options, tempo: tempo, timeSignature: timeSignature)
    }

    public func loadMachine(_ machine: SynthMachine) async throws {
        try await core.loadMachine(machine)
    }

    /// Starts the transport, so the grid loops. Idempotent.
    public func start() async throws {
        try await core.start()
    }

    public func stop() async {
        await core.stop()
    }

    /// Everything that touches AVFAudio, on the one actor that owns it.
    @AudioActor
    private final class Core {
        private let kitsDirectory: URL
        private let cache = SampleCache()
        private var engine: Engine?
        private var sampler: VoiceSampler?
        private var player: GroovePlayer?
        private var loadedMachine: String?

        /// Nonisolated so the host can be built on whatever actor the frame happens to be on; every
        /// method that touches AVFAudio is still on `AudioActor`.
        nonisolated init(kitsDirectory: URL) {
            self.kitsDirectory = kitsDirectory
        }

        private func ensureEngine() throws -> (Engine, VoiceSampler) {
            if let engine, let sampler { return (engine, sampler) }
            let newEngine = try Engine()
            let newSampler = VoiceSampler(cache: cache)
            engine = newEngine
            sampler = newSampler
            return (newEngine, newSampler)
        }

        func loadMachine(_ machine: SynthMachine) throws {
            let (_, sampler) = try ensureEngine()
            guard loadedMachine != machine.id else { return }
            let folder = kitsDirectory.appendingPathComponent(SynthesizedKit.folderName(for: machine), isDirectory: true)
            let kit: LoadedKit
            if let existing = try? KitStore.load(from: folder) {
                kit = existing
            } else {
                kit = try SynthesizedKit.build(machine, in: folder)
            }
            // Swapping a kit is safe while rendering; this is why switching machine does not stop
            // the pattern.
            try sampler.prepare(kit)
            loadedMachine = machine.id
        }

        func setPattern(_ groove: Groove, options: GrooveRenderOptions,
                        tempo: Double, timeSignature: TimeSignature) {
            let timeline = GrooveTimeline.tempo(tempo, timeSignature: timeSignature)
            if let player {
                player.groove = groove
                player.options = options
                player.timeline = timeline
            } else if let sampler {
                player = GroovePlayer(sampler: sampler, groove: groove, timeline: timeline, options: options)
            }
        }

        func start() throws {
            let (engine, _) = try ensureEngine()
            guard let player else { return }
            guard !engine.isTransportRunning else { return }
            engine.add(player)
            try engine.prepareRealtime()
            try engine.start()
            let clock = TransportClock(tempo: player.timeline.bpm ?? 90,
                                       timeSignature: player.timeline.timeSignature)
            _ = try engine.startTransport(clock: clock)
        }

        func stop() {
            engine?.stopTransport()
            engine?.stop()
        }

        func audition(_ voice: DrumVoice, velocity: Int) {
            guard let sampler else { return }
            // A hit at transport zero plays immediately when nothing is running; when the transport
            // is running the sampler places it at the next block, which is what "on touch" means.
            _ = try? sampler.play(VoiceSampler.Hit(voice, velocity: velocity, at: 0))
        }
    }
}
