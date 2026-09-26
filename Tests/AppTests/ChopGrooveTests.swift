import AVFAudio
import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// "Make the groove" in the Chop lane used to save the feel's stock pattern on a drum machine: the
// song then played an 808 over the looped bar it was made from. These are the groove playing the
// chop's own slices, from the lane to the plan to the audio.

@MainActor
enum ChopGrooveFixture {
    /// The clean bar, cut and kept by a lane, as a sample the song holds: its media on disk, its
    /// markers labelled with the classes the lane called them.
    static func keptChop(in directory: URL) throws -> (sample: PartVersion, lane: ChopLaneSurface, url: URL) {
        let (lane, _) = ChopLaneFixtures.cleanLane()
        let bar = ChopLaneFixtures.cleanBar()
        let url = directory.appendingPathComponent("bar.wav")
        try ChopAudio.writeWAV([bar, bar], to: url, sampleRate: ChopLaneFixtures.sampleRate)
        let sample = Sample(media: ChopLaneFixtures.media, slices: lane.sliceMarkers,
                            detectedTempo: ChopLaneFixtures.bpm,
                            span: SongGraph.TimeRange(start: 0, end: ChopLaneFixtures.barLength))
        let version = PartVersion(partID: PartID(), kind: .sample(sample), author: .user,
                                  operation: Operation.chop, note: "Bar 1")
        return (version, lane, url)
    }

    static func track(_ sample: PartVersion, url: URL) -> SongPlayback.ChopTrack {
        guard case .sample(let payload) = sample.kind else { fatalError("not a sample") }
        return SongPlayback.ChopTrack(version: sample.id, name: "Bar 1", url: url,
                                      region: payload.span!, passes: [], part: sample.partID,
                                      slices: payload.slices, tempo: payload.detectedTempo)
    }

    /// A song at the bar's tempo, holding the chop and a groove, in one four-bar section.
    static func song(chop: PartVersion, groove: PartVersion, stitch: [PartID]) -> Song {
        var song = Song(title: "Flip", artist: "Tests", tempo: ChopLaneFixtures.bpm,
                        sections: [Section(name: "Verse", stitch: stitch.lanes, lengthInBars: 4)])
        try? song.append(chop)
        try? song.append(groove)
        return song
    }

    static func pick(_ instrument: String, for part: PartID) -> PartVersion {
        PartVersion(partID: PartID(), kind: .sound(Sound(instrument: instrument, forPart: part)),
                    author: .user, operation: Operation.written)
    }
}

@Suite("A groove made from a chop plays the chop's slices", .serialized) @MainActor
struct ChopGrooveTests {

    @Test("the song cuts the chop where the lane kept it, and calls each slice what the lane did")
    func restoresTheCut() throws {
        let directory = TransportFixture.temporaryDirectory("chop-cut")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, lane, url) = try ChopGrooveFixture.keptChop(in: directory)
        let prepared = try ChopGroove.prepare(ChopGrooveFixture.track(sample, url: url))
        #expect(prepared.map.chop.count == lane.sliceCount)
        #expect(prepared.map.chop.slices.map(\.start) == lane.chop.slices.map(\.start))
        #expect(prepared.classifications.map(\.kind) == lane.classifications.map(\.kind))
        #expect(prepared.map.voices == lane.chopMap.voices, "the same pad is the kick")
    }

    @Test("each step lands on a slice of its own class, pass after pass, at the song's tempo")
    func stepsLandOnTheirClass() throws {
        let directory = TransportFixture.temporaryDirectory("chop-steps")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, url) = try ChopGrooveFixture.keptChop(in: directory)
        let prepared = try ChopGroove.prepare(ChopGrooveFixture.track(sample, url: url))
        let groove = TransportFixture.groove()
        let played = try ChopGroove.perform(groove, on: prepared, tempo: 120, timeSignature: .fourFour, passes: 2)

        let kicks = played.hits.filter { hit in
            hit.note.flatMap { prepared.map.slice(forNote: $0) }.flatMap { slice in
                prepared.classifications.first { $0.sliceIndex == slice.index }?.kind
            } == .kick
        }
        #expect(kicks.map(\.time) == (0..<8).map { Double($0) * 0.5 }, "a kick on every beat of two bars at 120")
        #expect(played.hits.allSatisfy { $0.note != nil && $0.time < 4 })
        #expect(played.kit.frameCount > 0)
    }

    @Test("a groove picked onto a chop plays on it; picking a machine takes it back off")
    func thePlanFollowsThePick() throws {
        let directory = TransportFixture.temporaryDirectory("chop-plan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, url) = try ChopGrooveFixture.keptChop(in: directory)
        let groove = TransportFixture.grooveVersion()
        var song = ChopGrooveFixture.song(chop: sample, groove: groove, stitch: [groove.partID])
        let resolver = TransportFixture.resolver(url)

        var voice = try #require(SongPlayback.plan(for: song, mediaURL: resolver).segments.first?.voices.first)
        #expect(voice.kit == nil && !voice.isBounced, "on its machine, live, until it is picked")

        try song.append(ChopGrooveFixture.pick(ChopSound.id(for: sample.partID), for: groove.partID))
        var plan = SongPlayback.plan(for: song, mediaURL: resolver)
        voice = try #require(plan.segments.first?.voices.first)
        #expect(voice.kit?.part == sample.partID && voice.kit?.slices.count == 8)
        #expect(voice.sound == ChopSound.id(for: sample.partID) && voice.isBounced)
        #expect(plan.dustyPlayers == 1, "a node of its own")

        try song.append(ChopGrooveFixture.pick("tr909", for: groove.partID))
        plan = SongPlayback.plan(for: song, mediaURL: resolver)
        voice = try #require(plan.segments.first?.voices.first)
        #expect(voice.kit == nil && voice.sound == "tr909")
        #expect(SongPlayback.drumSoundID(for: groove.partID, in: song) == "tr909")
    }

    @Test("the render is the chop, not the machine: the same groove sounds different on its slices")
    func rendersTheChop() async throws {
        let directory = TransportFixture.temporaryDirectory("chop-render")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, url) = try ChopGrooveFixture.keptChop(in: directory)
        let groove = TransportFixture.grooveVersion()
        var song = ChopGrooveFixture.song(chop: sample, groove: groove, stitch: [groove.partID])
        song.sections[0].lengthInBars = 1
        let resolver = TransportFixture.resolver(url)
        let kits = directory.appendingPathComponent("kits", isDirectory: true)

        let onMachine = try await SectionBounce.render(SongPlayback.plan(for: song, mediaURL: resolver),
                                                       kitsDirectory: kits, onlyTheMix: true)
        try song.append(ChopGrooveFixture.pick(ChopSound.id(for: sample.partID), for: groove.partID))
        let onChop = try await SectionBounce.render(SongPlayback.plan(for: song, mediaURL: resolver),
                                                    kitsDirectory: kits, onlyTheMix: true)

        func rms(_ planar: [[Float]]) -> Double {
            let left = planar.first ?? []
            return (left.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, left.count))).squareRoot()
        }
        #expect(rms(onChop.mix) > 0.001, "the chop's slices sound")
        let frames = min(onChop.mix[0].count, onMachine.mix[0].count)
        let difference = (0..<frames).reduce(0.0) { $0 + abs(Double(onChop.mix[0][$1] - onMachine.mix[0][$1])) }
        #expect(difference / Double(frames) > 0.001, "and they are not the 808")
    }

    @Test("made in the lane, the groove takes the looped bar's place and plays the chop")
    func takesTheChopsPlace() throws {
        let (app, directory, _) = CompletenessFixture.app("chop-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, _) = try ChopGrooveFixture.keptChop(in: directory)
        let stock = TransportFixture.grooveVersion()
        let made = TransportFixture.grooveVersion()
        var song = Song(title: "Flip", tempo: ChopLaneFixtures.bpm,
                        sections: [Section(name: "Intro", stitch: [stock.partID].lanes, lengthInBars: 2),
                                   Section(name: "Verse", stitch: [sample.partID, stock.partID].lanes, lengthInBars: 4)])
        try song.append(sample)
        try song.append(stock)
        app.open(song)
        #expect(app.record(made))

        #expect(app.playGroove(made.partID, onChop: sample.partID) == ["Verse"])
        let verse = try #require(app.song?.sections.last)
        #expect(verse.stitch.map(\.part) == [made.partID], "the loop and the stock groove are out, the new groove in once")
        #expect(app.song?.sections.first?.stitch.map(\.part) == [stock.partID], "a section without the chop is left alone")
        #expect(SongPlayback.drumSoundID(for: made.partID, in: app.song!) == ChopSound.id(for: sample.partID))

        let pick = try #require(app.song?.versions.last { $0.type == .sound })
        #expect(PartLabel.title(of: pick) == "Bar 1's slices for four on the floor", "named for a person, not by a uuid")
        #expect(PartActions.primary(for: pick, in: app.song!)?.action.surface == .chopLane, "opens where the slices are cut")
        #expect(Guidance.shapeableSounds(in: app.song!).isEmpty, "and is not offered to Sound")

        // The machine the part picked before is picked again, not refused as already playing.
        #expect(app.setMachine(SynthMachine.tr808.id, for: made.partID))
        #expect(SongPlayback.drumSoundID(for: made.partID, in: app.song!) == SynthMachine.tr808.id)
        let picks = app.song!.versions.filter { $0.type == .sound }
        #expect(Set(picks.map(\.partID)).count == 1, "one pick, versioned")
    }

    @Test("the Grid opens a chop groove on its slices, and its kit picker moves it on and off the chop")
    func gridOffersTheChop() throws {
        let (app, directory, _) = CompletenessFixture.app("chop-grid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, _) = try ChopGrooveFixture.keptChop(in: directory)
        let made = sample.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove,
                                   note: "Boom-Bap Pocket at 90 bpm")
        var song = Song(title: "Flip", tempo: ChopLaneFixtures.bpm,
                        sections: [Section(name: "Verse", stitch: [sample.partID].lanes, lengthInBars: 4)])
        try song.append(sample)
        app.open(song)
        #expect(app.record(made))
        app.playGroove(made.partID, onChop: sample.partID)

        let id = try #require(app.perform(SurfaceAction(surface: .grid, title: "Grid", bound: [made.id])))
        let item = try #require(app.bench.items.first { $0.id == id })
        let grid = SurfaceWiring.shared.gridModel(for: item, app: app)
        #expect(grid.chopKit?.part == sample.partID && grid.playsOnChop)
        #expect(grid.kitName == "Bar 1's slices" && grid.machineSounds(.ride), "every voice has a slice")

        grid.setMachine(SynthMachine.preset(id: "tr909")!)
        #expect(SongPlayback.drumSoundID(for: made.partID, in: app.song!) == "tr909")
        #expect(!grid.playsOnChop && grid.chopKit != nil, "still offered, one pick away")

        grid.playOnChop()
        #expect(SongPlayback.drumSoundID(for: made.partID, in: app.song!) == ChopSound.id(for: sample.partID))
        #expect(grid.playsOnChop)
    }

    @Test("a step touch on a chop plays the slice the song would: every voice named on a pad of its class")
    func padsNameEveryVoice() throws {
        let directory = TransportFixture.temporaryDirectory("chop-pads")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (sample, _, url) = try ChopGrooveFixture.keptChop(in: directory)
        let prepared = try ChopGroove.prepare(ChopGrooveFixture.track(sample, url: url))
        let kit = try ChopGroove.padKit(prepared)
        func kind(of voice: DrumVoice) -> SliceClass? {
            guard let note = kit.manifest.voices[voice.rawValue],
                  let slice = prepared.map.slice(forNote: note) else { return nil }
            return prepared.classifications.first { $0.sliceIndex == slice.index }?.kind
        }
        #expect(kind(of: .kick) == .kick && kind(of: .lowTom) == .kick)
        #expect(kind(of: .snare) == .snare && kind(of: .clap) == .snare)
        #expect(kind(of: .closedHat) == .hat && kind(of: .openHat) == .hat && kind(of: .perc) == .hat)
    }

    @Test("through the frame's adapter: on the chop first, then the Grid opens on it")
    func adapterLinksThenOpens() throws {
        let directory = WiringFixture.temporaryDirectory()
        defer { WiringFixture.remove(directory) }
        let app = WiringFixture.app(in: directory)
        let host = ChopLaneAdapter(app: app, service: WiringFixture.silentService(), surface: SurfaceID())
        let chop = WiringFixture.promotedBar()
        #expect(host.record(chop))
        let groove = chop.spawning(.groove(TransportFixture.groove()), by: .user, operation: Operation.regroove,
                                   note: "Boom-Bap Pocket at 90 bpm")
        #expect(host.record(groove))
        #expect(!app.bench.items.contains { $0.kind == .grid }, "not yet: it is not on the chop")

        host.madeGroove(groove, fromChop: chop.partID)
        #expect(SongPlayback.drumSoundID(for: groove.partID, in: app.song!) == ChopSound.id(for: chop.partID))
        let grid = try #require(app.bench.items.first { $0.kind == .grid })
        #expect(app.bound(for: grid.id) == [groove.id])
    }

    @Test("making the groove tells the host which chop it came from")
    func laneSaysWhichChop() throws {
        let (lane, host) = ChopLaneFixtures.cleanLane()
        lane.feelName = "Boom-Bap Pocket"
        lane.playRegroove()
        lane.keepRegroove()
        #expect(lane.lastError == nil)
        let chop = try #require(host.madeVersions.first)
        let groove = try #require(host.madeVersions.last)
        #expect(host.madeGrooves.count == 1)
        #expect(host.madeGrooves.first?.groove == groove.partID && host.madeGrooves.first?.chop == chop.partID)
    }
}

@Suite("A lane's kit, rendered again, is the kit that plays", .serialized)
struct ChopKitRefreshTests {
    private static let sampleRate: Double = 48_000

    /// One pad: half a second of a steady tone at `level`.
    private func kit(level: Float) throws -> (ChopKit, Int) {
        let tone = (0..<Int(Self.sampleRate / 2)).map { Float(sin(2 * .pi * 220 * Double($0) / Self.sampleRate)) * level }
        let chop = Chopper().sliceByDivisions(tone, sampleRate: Self.sampleRate, divisions: 1)
        let map = ChopMap.pads(chop, name: "Pad")
        return (try map.render(source: [tone]), try #require(map.note(forSlice: 0)))
    }

    @Test("a second kit under the same id replaces the first, rather than being ignored as already loaded")
    @AudioActor
    func secondRenderPlays() async throws {
        let kits = WiringFixture.temporaryDirectory("chop-refresh")
        defer { WiringFixture.remove(kits) }
        let engine = try Engine(playerCount: 1, sampleRate: Self.sampleRate, channels: 1)
        try engine.prepare(offlineSampleRate: Self.sampleRate, maximumFrames: 4096)
        try engine.start()
        _ = try engine.startTransport(clock: TransportClock(tempo: 120, sampleRate: Self.sampleRate))
        let service = AuditionService(engine: { engine }, kitsDirectory: kits)

        let (loud, note) = try kit(level: 0.8)
        try await service.prepare(chop: loud, id: "lane")
        await service.play([VoiceSampler.Hit(note: note, velocity: 127, at: 0)])
        let first = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(Self.sampleRate / 4))

        let (quiet, _) = try kit(level: 0.1)
        try await service.prepare(chop: quiet, id: "lane")
        _ = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(Self.sampleRate / 2))
        await service.play([VoiceSampler.Hit(note: note, velocity: 127, at: 0)])
        let second = try OfflineRenderer.renderBuffer(engine: engine, frames: AVAudioFramePosition(Self.sampleRate / 4))

        #expect(await service.lastFailure == nil)
        #expect(WiringFixture.peak(first) > 0.3, "the first kit sounds")
        #expect(WiringFixture.peak(second) > 0.01 && WiringFixture.peak(second) < 0.3,
                "the second is heard: \(WiringFixture.peak(second))")
        let renders = try FileManager.default.contentsOfDirectory(atPath: kits.appendingPathComponent("chops/lane").path)
        #expect(renders.count == 1, "the render before is gone from the disk")

        await service.shutdown()
        engine.stopTransport()
        engine.stop()
    }
}

@Suite("A looped chop keeps the song's time")
struct ChopFitTests {
    private let rate = 48_000.0

    /// One bar at 90 of a click on every beat.
    private func bar() -> [[Float]] {
        var out = [Float](repeating: 0, count: Int(rate * 8 / 3))
        for beat in 0..<4 { for i in 0..<240 { out[Int(Double(beat) * rate * 2 / 3) + i] = 0.5 } }
        return [out]
    }

    private func track(tempo: Double?) -> SongPlayback.ChopTrack {
        SongPlayback.ChopTrack(version: VersionID(), name: "Bar 1", url: URL(fileURLWithPath: "/dev/null"),
                               region: SongGraph.TimeRange(start: 10, end: 10 + 8.0 / 3), passes: [], tempo: tempo)
    }

    @Test("a bar cut at 90 plays one bar at 120: two seconds, not two and two-thirds")
    func fitsTheSongsBar() throws {
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour, sampleRate: rate)
        let fitted = try LiveSongPlayer.fitted(bar(), sampleRate: rate, of: track(tempo: 90), to: clock)
        #expect(abs(fitted[0].count - Int(2 * rate)) <= 1)
        #expect(track(tempo: 90).bars(beatsPerBar: 4) == 1)
    }

    @Test("left alone when its tempo is unknown, when it fits already, or when the fit is a misreading")
    func leftAlone() throws {
        let original = bar()
        for (tempo, song) in [(nil, 120.0), (90, 90), (90, 200)] as [(Double?, Double)] {
            let clock = TransportClock(tempo: song, timeSignature: .fourFour, sampleRate: rate)
            let fitted = try LiveSongPlayer.fitted(original, sampleRate: rate, of: track(tempo: tempo), to: clock)
            #expect(fitted[0].count == original[0].count, "\(String(describing: tempo)) → \(song)")
        }
    }

    @Test("a song of only a looped chop is as long as the chop, in its own bars")
    func countsInTheSongsLength() {
        let two = SongPlayback.ChopTrack(version: VersionID(), name: "Two bars", url: URL(fileURLWithPath: "/dev/null"),
                                         region: SongGraph.TimeRange(start: 0, end: 16.0 / 3), passes: [], tempo: 90)
        let plan = SongPlayback(tempo: 120, voices: [.chop(two)])
        #expect(SectionBounce.naturalBars(of: plan) == 2)
    }
}
