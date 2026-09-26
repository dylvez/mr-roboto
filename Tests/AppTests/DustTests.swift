import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A clean chop made dusty — the single most common move in the app's first idiom — end to end.
//
// The live run's gap was that the Sound surface only took a `.sound` part, so there was no way to
// say "run this chop through the SP-1200". These tests hold the fix to its properties: the dirtied
// chop is a real version with the dry one as its parent; the dry one is untouched; the seed survives
// the trip to disk; a bounce is the same bytes twice; the Sound surface, the audition service, the
// transport and the Compare's dust lever all mean the same chain; and a second lossy machine over a
// dusty chop is flagged by the chain critic rather than silently allowed.
//
// Real `AppState`, real temporary library, real WAV on disk. No audio device: everything that would
// make a sound is rendered through an engine in manual rendering mode.

enum DustFixture {
    static let sampleRate: Double = 48_000
    static let bpm: Double = 96
    static var barLength: Double { 4 * 60 / bpm }
    static let bars = 4

    /// Four bars of a kick on every beat with a little hiss-free tone under it: loud, clean and
    /// deterministic, so anything the chain adds is the chain's.
    static func record() -> [Float] {
        let beat = 60 / bpm
        let total = Int(Double(bars) * barLength * sampleRate)
        var out = [Float](repeating: 0, count: total)
        var time = 0.0
        while time < Double(total) / sampleRate {
            let start = Int(time * sampleRate)
            for i in 0..<Int(0.12 * sampleRate) where start + i < total {
                let t = Double(i) / sampleRate
                out[start + i] += Float(sin(2 * .pi * 70 * t) * exp(-t * 26) * 0.7)
            }
            time += beat
        }
        for i in 0..<total {
            out[i] += Float(sin(2 * .pi * 3_000 * Double(i) / sampleRate) * 0.05)
        }
        return out
    }

    struct Built {
        var app: AppState
        var store: LibraryStore
        var directory: URL
        var stem: PartVersion
        var dry: PartVersion
        var groove: PartVersion
        /// The dry chop's bar, as the lane and the transport read it.
        var region: SongGraph.TimeRange
    }

    /// A song holding a drums stem on disk, the analysis that found its bars, a dry chop of bar 2
    /// cut from the stem, and a groove re-grooved off the chop.
    @MainActor
    static func build(_ label: String = "dust", withGroove: Bool = true) throws -> Built {
        let directory = WiringFixture.temporaryDirectory(label)
        let store = LibraryStore(directoryURL: directory)
        let wav = directory.appendingPathComponent("drums.wav")
        try ChopAudio.writeWAV([record()], to: wav, sampleRate: sampleRate)
        let media = try store.addMedia(copying: wav, kind: .record)

        let barRanges = (0..<bars).map {
            SongGraph.TimeRange(start: Double($0) * barLength, end: Double($0 + 1) * barLength)
        }
        let beats = stride(from: 0.0, to: Double(bars) * barLength, by: 60 / bpm).enumerated().map {
            BeatMarker(time: $0.element, isDownbeat: $0.offset % 4 == 0)
        }
        var song = Song(title: "Arrival", tempo: bpm)
        try song.append(PartVersion(partID: PartID(),
                                    kind: .analysis(MusicAnalysis(duration: Double(bars) * barLength,
                                                                  beats: beats, bars: barRanges)),
                                    author: .user, operation: Operation.imported))
        let stem = PartVersion(partID: PartID(),
                               kind: .audio(Audio(media: media, role: .stem, stem: "drums",
                                                  sampleRate: sampleRate, channelCount: 1,
                                                  duration: Double(bars) * barLength)),
                               author: .user, operation: Operation.separate)
        try song.append(stem)
        let bar = barRanges[1]
        let downbeats = beats.map(\.time).filter { $0 >= bar.start && $0 < bar.end }
        let dry = stem.spawning(.sample(Sample(media: media, slices: downbeats.map { SliceMarker(position: $0) },
                                               detectedTempo: bpm)),
                                by: .user, operation: Operation.chop, note: "Bar 2 of Arrival")
        try song.append(dry)
        let groove = dry.spawning(.groove(TransportFixture.groove(bars: 1)), by: .user,
                                  operation: Operation.regroove, note: "Four on the floor")
        if withGroove { try song.append(groove) }

        let app = AppState(library: Library(), song: song, store: store,
                           transportHost: StubTransportHost())
        return Built(app: app, store: store, directory: directory, stem: stem, dry: dry, groove: groove,
                     region: bar)
    }

    /// The wirings the fixtures built. `SoundSurface` holds its host weakly and the wiring is what
    /// owns the adapter, so a test that dropped the wiring would be testing a surface with no host.
    @MainActor static var wirings: [SurfaceWiring] = []

    /// A Sound surface opened on `version` through the real wiring: bench item, binding, adapter.
    @MainActor
    static func sound(on version: PartVersion, in built: Built, kits: URL,
                      levers: [SurfaceLever] = []) -> (SoundSurface, SoundAdapter, SurfaceID) {
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let wiring = SurfaceWiring()
        wiring.use(service)
        wirings.append(wiring)
        let id = built.app.perform(SurfaceAction(surface: .sound, title: PartLabel.title(of: version),
                                                 bound: [version.id], levers: levers))!
        let item = built.app.bench.items.first { $0.id == id }!
        let (surface, adapter) = wiring.soundSurface(for: item, app: built.app)
        return (surface, adapter, id)
    }

    /// A chop's region, dry, as the adapters read it.
    @MainActor
    static func dryRegion(_ built: Built) throws -> AudioRegion.Span {
        guard case .sample(let sample) = built.dry.kind else { throw NoAudioDevice() }
        let url = try built.store.mediaURL(for: sample.media, song: built.app.song?.id)
        return try AudioRegion.read(url, from: built.region.start, to: built.region.end)
    }

    static let sp1200 = DegradeSettings(preset: .sp1200).degradation(from: .sp1200)
    static let mpc60 = DegradeSettings(preset: .mpc60).degradation(from: .mpc60)

    static func peak(_ planar: [[Float]]) -> Float {
        planar.flatMap { $0 }.reduce(0) { max($0, abs($1)) }
    }

    /// The least-squares gain from `reference` to `signal`, and the worst sample left over once it
    /// is applied.
    static func residual(_ signal: [Float], against reference: [Float]) -> (gain: Float, residual: Float) {
        let dot = zip(signal, reference).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let energy = reference.prefix(signal.count).reduce(Float(0)) { $0 + $1 * $1 }
        let gain = energy > 0 ? dot / energy : 0
        return (gain, zip(signal, reference).reduce(0) { max($0, abs($1.0 - gain * $1.1)) })
    }

    static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
}

@Suite("Dust: a clean chop made dusty", .serialized)
struct DustTests {

    // MARK: The Sound surface binds to a sample and to a groove

    @Test("Dust: Sound opens bound to a chop, as its chain, with the dry chop to compare against")
    @MainActor
    func dustSoundOpensOnASample() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (surface, adapter, _) = DustFixture.sound(on: built.dry, in: built, kits: kits)
        #expect(adapter.selectedPart?.id == built.dry.id, "the adapter refused the chop it was bound to")
        #expect(surface.subject == .part(.sample))
        #expect(surface.boundVersion?.id == built.dry.id)
        #expect(surface.panel == .chain)
        #expect(surface.controls(for: .voice).isEmpty, "a chop has no voice knobs to show")
        #expect(!surface.controls(for: .chain).isEmpty)
        #expect(surface.draft.degrade.isBypass, "a dry chop opens with the chain off")

        await surface.waitForDry()
        #expect(surface.dryFailure == nil)
        let dry = try #require(surface.dryPart)
        let expected = try DustFixture.dryRegion(built)
        #expect(dry.sampleRate == expected.sampleRate)
        #expect(dry.planar == expected.planar, "the dry side is not the chop's own bar")

        // The A/B is a true bypass against the dry part: with the chain on, `.dry` is still the chop
        // bit for bit, and `.chain` is not.
        surface.apply(.sp1200)
        #expect(surface.renderedPart(.dry) == expected.planar)
        #expect(surface.renderedPart(.chain) != expected.planar)
        #expect(surface.title.contains("sp1200"))
    }

    @Test("Dust: Sound opens bound to a groove, bounced dry on the song's machine")
    @MainActor
    func dustSoundOpensOnAGroove() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (surface, adapter, _) = DustFixture.sound(on: built.groove, in: built, kits: kits)
        #expect(adapter.selectedPart?.id == built.groove.id)
        #expect(surface.subject == .part(.groove))
        #expect(surface.controls(for: .voice).isEmpty)

        await surface.waitForDry()
        #expect(surface.dryFailure == nil, "\(surface.dryFailure ?? "")")
        let dry = try #require(surface.dryPart)
        #expect(DustFixture.peak(dry.planar) > 0.01, "the groove bounced to silence")
        // One pass at 96 bpm plus the tail.
        #expect(abs(dry.durationSeconds - (DustFixture.barLength + Dust.tail)) < 0.01)

        // Picking the machine keeps it: a choice is a version, as on every surface.
        surface.apply(.vinyl)
        let version = try #require(surface.lastKept)
        #expect(!surface.isDirty)
        #expect(version.parents == [built.groove.id])
        #expect(version.partID == built.groove.partID)
        #expect(version.kind.degradation.map(\.preset) == ["vinyl"])
        guard case .groove(let dusty) = version.kind, case .groove(let original) = built.groove.kind else {
            Issue.record("the dusty groove is not a groove"); return
        }
        #expect(dusty.patterns == original.patterns, "dirtying a groove changed its steps")
    }

    @Test("Dust: an accented chop in the ledger does not hijack Sound opened off the dock")
    @MainActor
    func dustDockSoundStaysAVoice() throws {
        let built = try DustFixture.build()
        defer { WiringFixture.remove(built.directory) }
        built.app.select(built.dry.id)
        let adapter = SoundAdapter(app: built.app, service: WiringFixture.silentService())
        #expect(adapter.selectedPart == nil, "only an explicit binding opens Sound on a chop")
    }

    // MARK: The graph model

    @Test("Dust: the SP-1200 makes a new version whose parent is the dry chop, and the dry chop is untouched")
    @MainActor
    func dustApplyingSP1200MakesANewVersion() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }
        let before = built.app.versions.count

        let (surface, _, _) = DustFixture.sound(on: built.dry, in: built, kits: kits)
        await surface.waitForDry()
        surface.apply(.sp1200)
        #expect(!surface.isDirty, "a machine picked is kept at once")
        let dusty = try #require(surface.lastKept)

        #expect(built.app.versions.count == before + 1)
        #expect(dusty.parents == [built.dry.id], "the dusty chop does not name the dry one as its parent")
        #expect(dusty.partID == built.dry.partID, "a dusty chop is a version of the chop, not a new part")
        #expect(dusty.operation == Operation.degrade)
        #expect(dusty.author == .user)
        #expect(try #require(built.app.song).ancestors(of: dusty.id).map(\.id).contains(built.dry.id))

        // It is still a chop: the same media, the same slices, the same tempo — plus the chain.
        guard case .sample(let wet) = dusty.kind, case .sample(let clean) = built.dry.kind else {
            Issue.record("the dusty chop is not a sample"); return
        }
        #expect(wet.media == clean.media)
        #expect(wet.slices == clean.slices)
        #expect(wet.detectedTempo == clean.detectedTempo)
        #expect(wet.degradation == [DustFixture.sp1200])
        #expect(DegradeSettings(wet.degradation[0]) == DegradeSettings(preset: .sp1200))

        // The dry chop is exactly what it was, and still in the song to be played.
        #expect(built.app.version(built.dry.id) == built.dry)
        #expect(clean.degradation.isEmpty)
        #expect(PartActions.primary(for: built.dry, in: try #require(built.app.song)) != nil)

        // And the ledger can say what happened.
        #expect(built.app.provenanceLine(for: dusty).contains("degrade"))
        #expect(built.app.provenanceLine(for: dusty).contains("from v1"))
        #expect(PartLabel.title(of: dusty) == "Bar 2 of Arrival", "dirtying a chop renamed it")
        #expect(dusty.note?.contains("sp1200") == true)
        #expect(built.app.versionNumber(of: dusty.id) == 2)
    }

    @Test("Dust: the seed is a UInt64 on disk and through every JSON path, not a Double")
    func dustTheSeedSurvives() throws {
        let seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        #expect(DustFixture.sp1200.seed == seed, "the preset's seed did not reach the stored pass")
        #expect(UInt64(exactly: Double(seed)) != seed, "the premise: a Double cannot carry this seed")

        var song = Song(title: "Seed", tempo: 90)
        let sample = Sample(media: WiringFixture.media, slices: [SliceMarker(position: 1)],
                            degradation: [DustFixture.sp1200, DustFixture.mpc60])
        let version = PartVersion(partID: PartID(), kind: .sample(sample), author: .user,
                                  operation: Operation.degrade)
        try song.append(version)

        // Straight through the codec.
        let data = try SongGraphCodec.encodeSong(song)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"seed\" : \"\(seed)\""), "the seed is not written as a string")
        let decoded = try SongGraphCodec.decodeSong(from: data)
        #expect(decoded.version(version.id)?.kind.degradation.map(\.seed) == [seed, seed])

        // Through `JSONValue`, which is what every schema migration round-trips a document through.
        let tree = try SongGraphCodec.decode(JSONValue.self, from: data)
        let again = try SongGraphCodec.decode(Song.self, from: try SongGraphCodec.encode(tree))
        #expect(again.version(version.id)?.kind.degradation.map(\.seed) == [seed, seed])
        #expect(again.version(version.id)?.kind == version.kind)

        // A dry part writes exactly what it always wrote: no `degradation` key at all.
        let dryData = try SongGraphCodec.encode(PartKind.sample(Sample(media: WiringFixture.media)))
        #expect(!String(decoding: dryData, as: UTF8.self).contains("degradation"))
        // And every preset reads back as itself.
        for preset in DegradeSettings.Preset.allCases {
            let settings = DegradeSettings(preset: preset)
            #expect(DegradeSettings(settings.degradation(from: preset)) == settings, "\(preset) did not round-trip")
        }
    }

    // MARK: Determinism

    @Test("Dust: rendering the dirtied chop is the same bytes across two offline renders")
    @AudioActor
    func dustRenderingIsDeterministic() async throws {
        let (built, span) = try await MainActor.run { () throws -> (DustFixture.Built, AudioRegion.Span) in
            let built = try DustFixture.build()
            return (built, try DustFixture.dryRegion(built))
        }
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }
        let passes = [DustFixture.sp1200]

        let first = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: passes)
        let second = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: passes)
        #expect(first == second, "two renders of the same dusty chop differ")
        #expect(first != span.planar, "the chain did nothing")
        #expect(first[0].count == span.planar[0].count, "the chain changed the chop's length")

        // A groove bounce is deterministic too — the sampler's round robin resets per bounce — and
        // so is that bounce through the chain.
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let hits = Dust.hits(for: TransportFixture.groove(bars: 1), tempo: DustFixture.bpm,
                             timeSignature: .fourFour)
        let a = try await service.bounce(hits, machine: .tr808, seconds: 2, sampleRate: 48_000, channels: 1)
        let b = try await service.bounce(hits, machine: .tr808, seconds: 2, sampleRate: 48_000, channels: 1)
        #expect(a.planar == b.planar, "two bounces of the same groove differ")
        #expect(DustFixture.peak(a.planar) > 0.01)
        let wetA = try Dust.render(a.planar, sampleRate: a.sampleRate, passes: passes)
        let wetB = try Dust.render(b.planar, sampleRate: b.sampleRate, passes: passes)
        #expect(wetA == wetB)
        await service.shutdown()
    }

    // MARK: Playback honours it

    @AudioActor
    private func offlineEngine(channels: AVAudioChannelCount = 1) throws -> Engine {
        let engine = try Engine(playerCount: 4, sampleRate: DustFixture.sampleRate, channels: channels)
        try engine.prepare(offlineSampleRate: DustFixture.sampleRate, maximumFrames: 4_096)
        try engine.start()
        return engine
    }

    @Test("Dust: the transport plays a dusty chop through its chain, in place of the stem it was cut from")
    @AudioActor
    func dustTransportPlaysTheDustyChop() async throws {
        let setup = try await MainActor.run { () throws -> (DustFixture.Built, AudioRegion.Span, SongPlayback) in
            // No groove in this song, so the render is the chop alone.
            let built = try DustFixture.build(withGroove: false)
            let dusty = built.dry.deriving(built.dry.kind.withDegradation([DustFixture.sp1200])!,
                                           by: .user, operation: Operation.degrade, note: "sp1200")
            #expect(built.app.record(dusty))
            let song = try #require(built.app.song)
            let plan = SongPlayback.plan(for: song) { try? built.store.mediaURL(for: $0, song: song.id) }
            return (built, try DustFixture.dryRegion(built), plan)
        }
        let (built, span, plan) = setup
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let chop = try #require(plan.chop, "the plan has no dusty chop in it")
        #expect(chop.passes == [DustFixture.sp1200])
        #expect(abs(chop.region.start - built.region.start) < 1e-9)
        #expect(plan.tracks.isEmpty, "the drums stem still plays under a loop of one of its own bars")
        #expect(plan.summary.contains("sp1200"))

        let engine = try offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)
        let clock = TransportClock(tempo: DustFixture.bpm, timeSignature: .fourFour, sampleRate: DustFixture.sampleRate)
        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)
        let frames = span.planar[0].count
        let out = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(frames))
        let rendered = WiringFixture.channel(out)

        let expected = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: chop.passes)[0]
        #expect(rendered.count == expected.count)
        #expect(DustFixture.maxDifference(rendered, expected) < 1e-4,
                "the transport did not play the chop through its chain")
        #expect(DustFixture.maxDifference(rendered, span.planar[0]) > 1e-3,
                "the transport played the chop dry")

        await player.end()
        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }

    @Test("Dust: the transport plays a dusty groove as a bounce through its chain")
    @AudioActor
    func dustTransportPlaysTheDustyGroove() async throws {
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(kits) }
        var groove = TransportFixture.groove(bars: 1)
        groove.degradation = [DustFixture.sp1200]
        var plan = SongPlayback(tempo: 120, groove: groove, machine: SynthMachine.tr808.id, lengthInBars: 1)
        plan.loops = false
        #expect(plan.grooveChain == [DustFixture.sp1200])
        #expect(plan.summary == "Groove · sp1200")

        let engine = try offlineEngine()
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let player = LiveSongPlayer(service: service)
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: DustFixture.sampleRate)
        try await player.begin(plan, clock: clock)
        _ = try engine.startTransport(clock: clock)
        let reading = await player.reading()
        #expect(reading.isRunning)
        #expect(reading.scheduledHits == Dust.hits(for: groove, tempo: 120, timeSignature: .fourFour).count)

        let seconds = 1.5
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(seconds * DustFixture.sampleRate))
        let rendered = WiringFixture.channel(out)

        // The same bounce, through the same chain, by hand.
        let hits = Dust.hits(for: groove, tempo: 120, timeSignature: .fourFour)
        let dry = try await service.bounce(hits, machine: .tr808, seconds: 2 + Dust.tail,
                                           sampleRate: DustFixture.sampleRate, channels: 1)
        let wet = try Dust.render(dry.planar, sampleRate: dry.sampleRate, passes: groove.degradation)[0]
        let expected = Array(wet.prefix(rendered.count))
        #expect(DustFixture.maxDifference(rendered, expected) < 1e-4,
                "the transport's groove is not the bounce through its chain")
        #expect(DustFixture.maxDifference(rendered, Array(dry.planar[0].prefix(rendered.count))) > 1e-3,
                "the transport played the groove dry")

        await player.end()
        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }

    @Test("Dust: the audition service plays a dusty chop through its chain")
    @AudioActor
    func dustAuditionPlaysThroughTheChain() async throws {
        let (built, span) = try await MainActor.run { () throws -> (DustFixture.Built, AudioRegion.Span) in
            let built = try DustFixture.build()
            return (built, try DustFixture.dryRegion(built))
        }
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let engine = try offlineEngine()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: DustFixture.sampleRate))
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)
        let passes = [DustFixture.sp1200]

        await service.play(planar: span.planar, sampleRate: span.sampleRate, through: passes)
        #expect(await service.lastFailure == nil)
        let out = try OfflineRenderer.renderBuffer(engine: engine,
                                                   frames: AVAudioFramePosition(span.planar[0].count))
        let rendered = WiringFixture.channel(out)
        let expected = try Dust.render(span.planar, sampleRate: span.sampleRate, passes: passes)[0]
        // The audition's player node reaches the mixer 3 dB down (the mixer's pan law on a node
        // attached at audition time), so the question is asked up to one constant gain: is what came
        // out the chain's output scaled, rather than the dry chop scaled?
        let wetFit = DustFixture.residual(rendered, against: expected)
        let dryFit = DustFixture.residual(rendered, against: span.planar[0])
        #expect(wetFit.gain > 0.5)
        #expect(wetFit.residual < 1e-3, "the audition did not go through the chain")
        #expect(dryFit.residual > 1e-2, "the audition was dry")

        // A dusty groove auditions too: bounced, chained, and played as audio rather than as hits.
        var groove = TransportFixture.groove(bars: 1)
        groove.degradation = passes
        await service.play(groove: groove, machine: .tr808, tempo: 120, timeSignature: .fourFour,
                           through: groove.degradation)
        #expect(await service.lastFailure == nil)
        let grooveOut = try OfflineRenderer.renderBuffer(engine: engine, frames: 24_000)
        #expect(WiringFixture.peak(grooveOut) > 0.01, "the dusty groove audition was silent")

        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }

    @Test("Dust: the Compare's dust lever is the pass a Sound surface commits at the same amount")
    @MainActor
    func dustCompareLeverMeansTheSameThing() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (surface, _, _) = DustFixture.sound(on: built.dry, in: built, kits: kits)
        await surface.waitForDry()
        surface.apply(.sp1200)
        let dusty = try #require(surface.lastKept)

        // At full, the lever is exactly what pressing sp1200 on the Sound surface committed.
        #expect(CompareAdapter.passes(for: built.dry, levers: [.degradeMix: 1]) == dusty.kind.degradation)
        // With no lever each row plays as its version says it sounds…
        #expect(CompareAdapter.passes(for: dusty, levers: [:]) == [DustFixture.sp1200])
        #expect(CompareAdapter.passes(for: built.dry, levers: [:]).isEmpty)
        // …and with one, every row plays its dry part through the lever's one pass, so a dusty row
        // never gets a second machine stacked on the lever's.
        #expect(CompareAdapter.passes(for: dusty, levers: [.degradeMix: 0.45]) == [Dust.pass(0.45)])
        #expect(DegradeSettings(Dust.pass(0.45)).mix == 0.45)
        #expect(DegradeSettings(Dust.pass(0.45)).seed == DustFixture.sp1200.seed)

        // The Director's dust lever on a Sound surface starts the draft at the same pass.
        let (levered, _, _) = DustFixture.sound(on: built.dry, in: built, kits: kits,
                                                levers: [SurfaceLever(quantity: .dust, label: "Dustier", value: 0.45)])
        #expect(levered.draft.degrade == Dust.lever(0.45))
        #expect(levered.chainPasses == [Dust.pass(0.45)])
        #expect(levered.isDirty, "the lever's chain is a draft to keep, not a version already written")
    }

    // MARK: The choice validator

    @Test("Dust: the choice validator admits Sound on a chop or a groove, and still refuses the rest")
    @MainActor
    func dustChoiceAdmitsSoundOnAChopOrGroove() throws {
        let built = DirectorChoiceTests.build()
        defer { DirectorChoiceTests.clean(built) }

        let onChop = try DirectorSurfaceChoice.make(
            surface: .sound, title: "Dustier", fill: .parts([built.sample]),
            levers: [SurfaceLever(quantity: .dust, label: "Dustier", value: 0.6)],
            because: "Dirt is a sound job.", in: built.stage)
        #expect(onChop.action.surface == .sound)
        #expect(onChop.action.bound == [built.sample])

        let onGroove = try DirectorSurfaceChoice.make(
            surface: .sound, title: "Dustier groove", fill: .parts([built.grooves[0]]),
            because: "The groove through the SP-1200.", in: built.stage)
        #expect(onGroove.action.bound == [built.grooves[0]])

        // Still a voice, too.
        _ = try DirectorSurfaceChoice.make(surface: .sound, title: "Kick", fill: .parts([built.sound]),
                                           because: "", in: built.stage)
        // A take is not something dust is carried on.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .sound, title: "No", fill: .parts([built.take]),
                                           because: "", in: built.stage)
        }
        // And a lever the Sound surface has no number for is still refused on a chop.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .sound, title: "No", fill: .parts([built.sample]),
                                           levers: [SurfaceLever(quantity: .swing, label: "Swing", value: 60)],
                                           because: "", in: built.stage)
        }
        // Opening it through the stage lands a Sound surface bound to the chop.
        let id = try #require(built.stage.open(onChop))
        let (surface, _) = SurfaceWiring().soundSurface(
            for: try #require(built.app.bench.items.first { $0.id == id }), app: built.app)
        #expect(surface.subject == .part(.sample))
        #expect(surface.draft.degrade == Dust.lever(0.6))
    }

    // MARK: The chain critic

    @Test("Dust: a second lossy chain over a dusty chop raises the stacking critic's finding")
    @MainActor
    func dustStackingIsFlagged() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        // The first machine: no finding, because the source had not been through one.
        let (first, _, _) = DustFixture.sound(on: built.dry, in: built, kits: kits)
        await first.waitForDry()
        first.apply(.sp1200)
        #expect(first.chainFindings.filter { $0.measurement.feature == .bitDepth }.isEmpty)
        let dusty = try #require(first.lastKept)
        #expect(Dust.findings(for: dusty).isEmpty)

        // The second, stacked on top: the critic flags it on the draft, before anything is written…
        let (second, _, _) = DustFixture.sound(on: dusty, in: built, kits: kits)
        await second.waitForDry()
        #expect(second.draft.degrade == DegradeSettings(preset: .sp1200), "it opens on the chop's own chain")
        second.setStacking(true)
        #expect(second.beneath == [DustFixture.sp1200])
        second.apply(.mpc60)
        let flagged = try #require(second.chainFindings.first { $0.measurement.feature == .bitDepth })
        #expect(flagged.critic == .degradeStack)
        #expect(flagged.severity == .warn)
        #expect(flagged.headline.contains("MPC60 over SP-1200"))
        #expect(flagged.fixes.count == 2)

        // …it is allowed, not refused — stacking is a real thing people do — and it is a real version…
        let stacked = try #require(second.lastKept)
        #expect(stacked.parents == [dusty.id])
        #expect(stacked.kind.degradation == [DustFixture.sp1200, DustFixture.mpc60])

        // …and the finding follows the version: the board raises it, and the rail says it in the
        // Sampler's name rather than letting it pass silently.
        let review = Dust.review(label: "Bar 2", passes: stacked.kind.degradation)
        #expect(CriticBoard.standard.review(review).contains { $0.critic == .degradeStack && $0.severity == .warn })
        #expect(Dust.findings(for: stacked).contains { $0.measurement.feature == .bitDepth })
        #expect(built.app.log.contains { entry in
            if case .persona = entry.source { return entry.text.contains("Second quantiser") }
            return false
        }, "the stacked chain landed without the Sampler saying anything")

        // The critic's own first fix is now a real version on a dusty chop: the second quantiser off.
        let fix = try #require(flagged.fix("bits-off"))
        let fixed = try #require(CheckAdapter.applying(fix.change, to: stacked.kind))
        #expect(fixed.degradation.map(\.preset) == ["sp1200", "cassette"])
        #expect(Dust.findings(for: stacked.deriving(fixed, by: .user, operation: Operation.degrade))
            .filter { $0.measurement.feature == .bitDepth }.isEmpty)

        // A non-lossy second pass is not a stacking finding: that is the fix, not the fault.
        let tape = Dust.review(label: "Bar 2", passes: [DustFixture.sp1200,
                                                        DegradeSettings(preset: .cassette).degradation(from: .cassette)])
        #expect(DegradeStackCritic().review(tape).filter { $0.measurement.feature == .bitDepth }.isEmpty)
    }
}
