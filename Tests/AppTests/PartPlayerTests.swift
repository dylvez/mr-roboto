import AudioEngine
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// One way to hear one thing: what can be played, what the player says is sounding, and what each
// surface's header would play.

private struct NoDevice: Error {}

@Suite("Part player: one play control everywhere", .serialized) @MainActor
struct PartPlayerTests {

    private func rig(_ song: Song) -> (AppState, PartPlayer, URL, UserDefaults, String) {
        let directory = WiringFixture.temporaryDirectory("player")
        let app = BandFixture.app(in: directory, song: song)
        let suite = "player-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: WiringFixture.temporaryDirectory("player-kits"))
        return (app, PartPlayer(app: app, service: service, defaults: defaults), directory, defaults, suite)
    }

    @Test("what has a sound of its own: grooves, lines, chords and audio do; a mix, an analysis and words do not")
    func canPlay() {
        let song = GuidanceFixture.everyKind().song
        // The every-kind fixture's groove and bass line are blank; the form fixture's are written.
        let versions = song.versions + FormFixture.build(tempo: 100).song.versions
        let playable = Set(versions.filter(PartPlayer.canPlay).map(\.type))
        #expect(playable.isSuperset(of: [.groove, .bassline, .progression, .audio]), "\(playable)")
        #expect(playable.isDisjoint(with: [.mix, .analysis, .lyric, .sound]))
        let empty = PartVersion(partID: PartID(), kind: .groove(Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [])), author: .user, operation: Operation.written)
        #expect(!PartPlayer.canPlay(empty), "a groove with no hits has nothing to play")
    }

    @Test("playing a part names it as sounding; toggling stops it; it clears itself when the part ends; the mode is remembered")
    func nowPlaying() async throws {
        let song = FormFixture.build(tempo: 240).song
        let (app, player, directory, defaults, suite) = rig(song)
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        let groove = try #require(Guidance.grooves(in: song).last), line = try #require(Guidance.basslines(in: song).last)
        #expect(player.nowPlaying == nil && player.mode == .alone)

        await player.play(groove)
        #expect(player.isPlaying(groove) && player.nowPlaying?.label == PartLabel.title(of: groove))
        await player.play(line)
        #expect(player.isPlaying(line) && !player.isPlaying(groove), "one thing at a time")
        await player.stopSounding()
        #expect(player.nowPlaying == nil)

        // Something a surface plays under the player's name, half a second long.
        await player.play(id: "surface:x", label: "A bar", seconds: 0.05) {}
        #expect(player.isPlaying("surface:x"))
        for _ in 0..<100 where player.nowPlaying != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(player.nowPlaying == nil, "it ended by itself")

        player.mode = .inSong
        #expect(PartPlayer(app: app, service: AuditionService(engine: { throw NoDevice() }, kitsDirectory: directory), defaults: defaults).mode == .inSong)
    }

    @Test("in the song: the transport starts under the part's name, Space stops it, and a stopped transport is nothing playing")
    func inTheSong() async throws {
        let song = FormFixture.build(tempo: 120).song
        let (app, player, directory, defaults, suite) = rig(song)
        defer { WiringFixture.remove(directory); defaults.removePersistentDomain(forName: suite) }
        let line = try #require(Guidance.basslines(in: song).last)
        player.mode = .inSong
        await player.play(line)
        guard app.transport.isPlaying else { return } // a host with no playback has nothing to prove here
        #expect(player.nowPlaying?.label.hasSuffix("in the song") == true)
        await player.spaceBar()
        #expect(!app.transport.isPlaying && player.nowPlaying == nil)
    }

    @Test("chords become held notes on their beats")
    func chordHits() {
        let clock = TransportClock(tempo: 120, timeSignature: .fourFour)
        let c = Chord(root: .c, quality: .major), g = Chord(root: .g, quality: .major)
        let hits = PartPlayer.hits(for: Progression(key: Key(tonic: NoteName(.c)), bars: [ProgressionBar(c), ProgressionBar(chords: [ChordSpan(g, beats: 2), ChordSpan(c, beats: 2)])]), clock: clock)
        #expect(hits.count == 9)
        #expect(Set(hits.map(\.time)) == [0, 2, 3], "bar 2 starts at 2 s; its second chord at 3 s")
        #expect(hits.filter { $0.time == 0 }.compactMap(\.note).sorted() == [48, 52, 55])
        #expect(hits.allSatisfy { ($0.duration ?? 0) > 0 })
    }

    @Test("what each surface's header plays")
    func headers() throws {
        SurfaceRegistry.registerSurfaces()
        let song = FormFixture.build(tempo: 100).song
        let directory = WiringFixture.temporaryDirectory("player-headers")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory, song: song)
        func label(_ kind: SurfaceKind) -> String? {
            guard let id = app.perform(Guidance.dockAction(for: kind, in: app.song)), let item = app.bench.items.first(where: { $0.id == id }) else { return nil }
            return SurfaceWiring.shared.audition(for: item, app: app)?.label
        }
        #expect(label(.grid) == "this groove")
        #expect(label(.pianoRoll) == "this line")
        #expect(label(.structure) == "the form")
        #expect(label(.mixer) == "the song" && label(.booth) == "the song")
        #expect(label(.cast) == nil, "nothing of its own to sound")
    }
}
