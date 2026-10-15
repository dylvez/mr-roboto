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
// The live run's gap was that there was no way to say "run this chop through the SP-1200". These
// tests hold the fix to its properties: the dirtied chop is a real version with the dry one as its
// parent; the dry one is untouched; the seed survives the trip to disk; a bounce is the same bytes
// twice; the Shape popover, the Dust menu, the audition service, the transport and the Compare's
// dust lever all mean the same chain; and a second lossy machine over a dusty chop is flagged by
// the chain critic rather than silently allowed.
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

    /// A Shape popover's model opened on `version`'s chain through the real adapter, as a Dust
    /// menu's last item opens it.
    @MainActor
    static func shaping(on version: PartVersion, in built: Built, kits: URL,
                        lever: Double? = nil) -> (SoundShaping, SoundShapingAdapter) {
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let adapter = SoundShapingAdapter(app: built.app, service: service)
        return (SoundShaping(host: adapter, part: version, lever: lever), adapter)
    }

    /// The wirings the fixtures built, so a grid's adapter outlives the call that made it.
    @MainActor static var wirings: [SurfaceWiring] = []

    /// A Grid opened on `version` through the real wiring, as the dock opens it.
    @MainActor
    static func grid(on version: PartVersion, in built: Built, kits: URL) -> GridModel {
        let service = AuditionService(engine: { throw NoAudioDevice() }, kitsDirectory: kits)
        let wiring = SurfaceWiring()
        wiring.use(service)
        wirings.append(wiring)
        let id = built.app.perform(SurfaceAction(surface: .grid, title: PartLabel.title(of: version), bound: [version.id]))!
        let item = built.app.bench.items.first { $0.id == id }!
        return wiring.gridModel(for: item, app: built.app)
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

    // MARK: The popover opens on a sample and on a groove

    @Test("Dust: the popover opens on a chop as its chain, with the dry chop to compare against")
    @MainActor
    func dustPopoverOpensOnASample() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (shaping, _) = DustFixture.shaping(on: built.dry, in: built, kits: kits)
        #expect(shaping.subject == .part(.sample))
        #expect(shaping.boundVersion?.id == built.dry.id)
        #expect(shaping.voiceControls.isEmpty, "a chop has no voice knobs to show")
        #expect(!shaping.chainControls.isEmpty)
        #expect(shaping.draft.degrade.isBypass, "a dry chop opens with the chain off")

        await shaping.waitForDry()
        #expect(shaping.dryFailure == nil)
        let dry = try #require(shaping.dryPart)
        let expected = try DustFixture.dryRegion(built)
        #expect(dry.sampleRate == expected.sampleRate)
        #expect(dry.planar == expected.planar, "the dry side is not the chop's own bar")

        // The A/B is a true bypass against the dry part: with the chain on, `.dry` is still the chop
        // bit for bit, and `.chain` is not.
        shaping.apply(.sp1200)
        #expect(shaping.renderedPart(.dry) == expected.planar)
        #expect(shaping.renderedPart(.chain) != expected.planar)
        #expect(shaping.title.contains("sp1200"))
    }

    @Test("Dust: the popover opens on a groove, bounced dry on the song's machine")
    @MainActor
    func dustPopoverOpensOnAGroove() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (shaping, _) = DustFixture.shaping(on: built.groove, in: built, kits: kits)
        #expect(shaping.subject == .part(.groove))
        #expect(shaping.voiceControls.isEmpty)

        await shaping.waitForDry()
        #expect(shaping.dryFailure == nil, "\(shaping.dryFailure ?? "")")
        let dry = try #require(shaping.dryPart)
        #expect(DustFixture.peak(dry.planar) > 0.01, "the groove bounced to silence")
        // One pass at 96 bpm plus the tail.
        #expect(abs(dry.durationSeconds - (DustFixture.barLength + Dust.tail)) < 0.01)

        // Picking the machine keeps it: a choice is a version, as on every surface.
        shaping.apply(.vinyl)
        let version = try #require(shaping.lastKept)
        #expect(!shaping.isDirty)
        #expect(version.parents == [built.groove.id])
        #expect(version.partID == built.groove.partID)
        #expect(version.kind.degradation.map(\.preset) == ["vinyl"])
        guard case .groove(let dusty) = version.kind, case .groove(let original) = built.groove.kind else {
            Issue.record("the dusty groove is not a groove"); return
        }
        #expect(dusty.patterns == original.patterns, "dirtying a groove changed its steps")
    }

    @Test("Dust: the Grid's Dust menu keeps the groove through a machine, replaces it, and takes it off")
    @MainActor
    func dustGridMenuKeepsVersions() throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }
        let model = DustFixture.grid(on: built.groove, in: built, kits: kits)
        let before = built.app.versions.count
        #expect(model.canDust && model.degradation.isEmpty)
        #expect(Dust.chip(model.degradation) == "Clean")

        // Two clicks: the menu, the machine. A version of the groove through it, the dry one its parent.
        model.setDust(.sp1200)
        let dusty = try #require(model.lastKept)
        #expect(built.app.versions.count == before + 1)
        #expect(dusty.parents == [built.groove.id] && dusty.partID == built.groove.partID)
        #expect(dusty.operation == Operation.degrade && dusty.author == .user)
        #expect(dusty.kind.degradation == [DustFixture.sp1200], "exactly the pass the popover commits")
        #expect(model.degradation == [DustFixture.sp1200], "the grid carries what it kept")
        #expect(Dust.chip(model.degradation) == "SP-1200" && Dust.preset(on: model.degradation) == .sp1200)
        #expect(built.app.version(built.groove.id) == built.groove, "the dry groove is untouched")

        // The same machine again writes nothing; another replaces it on top; Clean takes it off.
        model.setDust(.sp1200)
        #expect(built.app.versions.count == before + 1)
        model.setDust(.vinyl)
        #expect(built.app.versions.count == before + 2)
        #expect(model.degradation.map(\.preset) == ["vinyl"])
        #expect(model.lastKept?.parents == [dusty.id])
        model.setDust(.clean)
        #expect(built.app.versions.count == before + 3)
        #expect(model.degradation.isEmpty && Dust.chip(model.degradation) == "Clean")
        model.setDust(.clean)
        #expect(built.app.versions.count == before + 3, "clean on clean is not a version")

        // Steps painted since are kept first, so the dusty version plays what is on screen; and
        // the next keep of the steps carries the chain.
        model.toggle(.kick, step: 2)
        model.setDust(.mpc60)
        let kept = try #require(built.app.song?.versions.suffix(2).map { $0 })
        #expect(kept.count == 2 && kept[0].kind.degradation.isEmpty && kept[0].operation == Operation.edit)
        #expect(kept[1].kind.degradation.map(\.preset) == ["mpc60"] && kept[1].parents == [kept[0].id])
        model.toggle(.kick, step: 6)
        let next = model.commit()
        #expect(next.kind.degradation.map(\.preset) == ["mpc60"], "painting a step is not a request to clean the groove")

        // The chain kept from the popover comes back to the grid.
        let (shaping, _) = DustFixture.shaping(on: next, in: built, kits: kits)
        shaping.kept = { model.adopt($0) }
        shaping.apply(.radio)
        #expect(model.degradation.map(\.preset) == ["radio"] && model.lastKept?.id == shaping.lastKept?.id)
    }

    // MARK: The graph model

    @Test("Dust: the SP-1200 makes a new version whose parent is the dry chop, and the dry chop is untouched")
    @MainActor
    func dustApplyingSP1200MakesANewVersion() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }
        let before = built.app.versions.count

        let (shaping, _) = DustFixture.shaping(on: built.dry, in: built, kits: kits)
        await shaping.waitForDry()
        shaping.apply(.sp1200)
        #expect(!shaping.isDirty, "a machine picked is kept at once")
        let dusty = try #require(shaping.lastKept)

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

    @Test("Dust: the Compare's dust lever is the pass the popover commits at the same amount")
    @MainActor
    func dustCompareLeverMeansTheSameThing() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        let (shaping, _) = DustFixture.shaping(on: built.dry, in: built, kits: kits)
        await shaping.waitForDry()
        shaping.apply(.sp1200)
        let dusty = try #require(shaping.lastKept)

        // At full, the lever is exactly what choosing sp1200 in the popover committed.
        #expect(CompareAdapter.passes(for: built.dry, levers: [.degradeMix: 1]) == dusty.kind.degradation)
        // With no lever each row plays as its version says it sounds…
        #expect(CompareAdapter.passes(for: dusty, levers: [:]) == [DustFixture.sp1200])
        #expect(CompareAdapter.passes(for: built.dry, levers: [:]).isEmpty)
        // …and with one, every row plays its dry part through the lever's one pass, so a dusty row
        // never gets a second machine stacked on the lever's.
        #expect(CompareAdapter.passes(for: dusty, levers: [.degradeMix: 0.45]) == [Dust.pass(0.45)])
        #expect(DegradeSettings(Dust.pass(0.45)).mix == 0.45)
        #expect(DegradeSettings(Dust.pass(0.45)).seed == DustFixture.sp1200.seed)

        // A popover opened with a lever starts its draft at the same pass.
        let (levered, _) = DustFixture.shaping(on: built.dry, in: built, kits: kits, lever: 0.45)
        #expect(levered.draft.degrade == Dust.lever(0.45))
        #expect(levered.chainPasses == [Dust.pass(0.45)])
        #expect(levered.isDirty, "the lever's chain is a draft to keep, not a version already written")
    }

    // MARK: The choice validator

    @Test("Dust: a dust lever hangs on the Chop lane and the Compare, and a dusty part opens on its own surface")
    @MainActor
    func dustChoiceHangsWhereDustIs() throws {
        let built = DirectorChoiceTests.build()
        defer { DirectorChoiceTests.clean(built) }

        #expect(SurfaceLever.Quantity.dust.surfaces == [.chopLane, .compare])
        let onChop = try DirectorSurfaceChoice.make(
            surface: .chopLane, title: "Dustier", fill: .parts([built.sample]),
            levers: [SurfaceLever(quantity: .dust, label: "Dustier", value: 0.6)],
            because: "Dirt is a sound job.", in: built.stage)
        #expect(onChop.action.surface == .chopLane && onChop.action.bound == [built.sample])

        // The Grid takes a groove, dusty or not, and no dust lever: its Dust menu is the chain.
        let onGroove = try DirectorSurfaceChoice.make(
            surface: .grid, title: "Dustier groove", fill: .parts([built.grooves[0]]),
            because: "The groove through the SP-1200.", in: built.stage)
        #expect(onGroove.action.bound == [built.grooves[0]])
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .grid, title: "No", fill: .parts([built.grooves[0]]),
                                           levers: [SurfaceLever(quantity: .dust, label: "Dustier", value: 0.6)],
                                           because: "", in: built.stage)
        }
        // A lever the lane has no number for is still refused on a chop.
        #expect(throws: DirectorChoiceProblem.self) {
            try DirectorSurfaceChoice.make(surface: .chopLane, title: "No", fill: .parts([built.sample]),
                                           levers: [SurfaceLever(quantity: .lag, label: "Lag", value: 20)],
                                           because: "", in: built.stage)
        }
        // Where the path and the ledger send a dusty part: the Grid for a groove, the lane for a chop.
        let song = try #require(built.app.song)
        let groove = try #require(song.version(built.grooves[0]))
        let dustyGroove = try #require(Dust.version(choosing: .sp1200, on: groove, by: .user))
        #expect(WorkPath.dustAction(on: dustyGroove)?.surface == .grid)
        let sample = try #require(song.version(built.sample))
        let dustySample = try #require(Dust.version(choosing: .sp1200, on: sample, by: .user))
        #expect(WorkPath.dustAction(on: dustySample)?.surface == .chopLane)
        #expect(LedgerGroups.action(for: dustySample, in: song)?.surface == .chopLane)
    }

    // MARK: The chain critic

    @Test("Dust: a second lossy chain over a dusty chop raises the stacking critic's finding")
    @MainActor
    func dustStackingIsFlagged() async throws {
        let built = try DustFixture.build()
        let kits = WiringFixture.temporaryDirectory("dust-kits")
        defer { WiringFixture.remove(built.directory); WiringFixture.remove(kits) }

        // The first machine: no finding, because the source had not been through one.
        let (first, _) = DustFixture.shaping(on: built.dry, in: built, kits: kits)
        await first.waitForDry()
        first.apply(.sp1200)
        #expect(first.chainFindings.filter { $0.measurement.feature == .bitDepth }.isEmpty)
        let dusty = try #require(first.lastKept)
        #expect(Dust.findings(for: dusty).isEmpty)

        // The second, stacked on top: the critic flags it on the draft, before anything is written…
        let (second, _) = DustFixture.shaping(on: dusty, in: built, kits: kits)
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
