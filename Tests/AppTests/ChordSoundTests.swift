import AudioEngine
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// A sound for the chords kept by name across songs: the instrument, the way the chords are played,
// and what their strip does — put on a sheet in one press, saved from one under a name.

private struct NoDevice: Error {}

/// A host that keeps what the sheet hands it: the chords, the instrument, the strip.
@MainActor
private final class SoundHost: ChordsHosting {
    var kept: [PartVersion] = []
    var instruments: [PartID?: String] = [:]
    var strips: [PartID?: StripSound] = [:]
    var instrument: String { instruments[nil] ?? "rhodes" }
    func audition(pitches: [Int], duration: Double) async {}
    func setInstrument(_ id: String, for part: PartID?) { instruments[part] = id }
    func instrument(for part: PartID?) -> String { instruments[part] ?? instrument }
    func commit(_ version: PartVersion) -> Bool { kept.append(version); return true }
    func newest(of part: PartID) -> PartVersion? { kept.last { $0.partID == part } }
    func stripSound(for part: PartID?) -> StripSound { strips[part] ?? StripSound() }
    func setStripSound(_ sound: StripSound, for part: PartID?) -> Bool { strips[part] = sound; return true }
}

@Suite("Chord sounds: kept by name, put on the chords in one press", .serialized) @MainActor
struct ChordSoundTests {

    private func shelf() -> (ChordSoundShelf, () -> Void) {
        let suite = "chord-sounds-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ChordSoundShelf(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test("the starters are there with an instrument to play them; a sound saved is kept, a name saved again replaces it, and a starter is not forgotten")
    func theShelf() throws {
        let (shelf, clean) = shelf()
        defer { clean() }
        #expect(ChordSound.starters.count == 5, "every starter's instrument ships with the app")
        #expect(shelf.sounds.map(\.name) == ChordSound.starters.map(\.name) && shelf.saved.isEmpty)
        #expect(ChordSound.starters.allSatisfy { $0.playing.seed == 0 }, "the seed is the song's")
        let mine = ChordSound(name: "Mine", instrument: "wurlitzer",
                              playing: ChordPlaying(.backbeat, .rootless, seed: 44, roll: .strum),
                              strip: StripSound(insert: .ampCrunch, echoDB: -12))
        shelf.save(mine)
        #expect(shelf.saved == [mine] && mine.playing.seed == 0)
        #expect(shelf.sounds.last == mine)
        var again = mine
        again.instrument = "rhodes"
        shelf.save(again)
        #expect(shelf.saved == [again], "the same name replaces")
        // A sound saved under a starter's name stands in its place.
        let starter = try #require(ChordSound.starters.first)
        shelf.save(ChordSound(name: starter.name, instrument: "juno", playing: ChordPlaying(.held, .close)))
        #expect(shelf.sounds.filter { $0.name == starter.name }.map(\.instrument) == ["juno"])
        shelf.remove(named: starter.name)
        #expect(shelf.sounds.filter { $0.name == starter.name } == [starter], "the starter is the app's, and comes back")
        shelf.remove(named: "Mine")
        #expect(shelf.saved.isEmpty)
        #expect(mine.summary.hasPrefix("Wurlitzer · backbeat, rootless, strummed · "), "\(mine.summary)")
        #expect(StripSound().words == "dry" && mine.strip.words == "amp-crunch, the echo at -12 dB")
    }

    @Test("a sound put on a sheet plays its way as one step of ⌘Z, and its instrument and strip go on the chords' part")
    func useOnASheet() throws {
        let host = SoundHost()
        let model = ChordsModel(host: host, key: Key.cMajor)
        model.autoKeep.delay = nil
        let (shelf, clean) = shelf()
        defer { clean() }
        model.shelf = shelf
        model.text = "Dm7 | G7 | Cmaj7"
        let sound = try #require(ChordSound.starters.first { $0.name == "Nylon strum" })
        model.use(sound)
        let part = try #require(model.part, "chords that were not a part are kept, so the sound has one")
        #expect(model.pattern == .eighths && model.voicing == .spread && model.roll == .strum && model.isSloppy)
        #expect(model.progression?.playing?.seed != 0, "a hand of its own")
        #expect(host.instruments[part] == "nylon-guitar" && host.strips[part] == sound.strip)
        #expect(model.soundInUse?.name == "Nylon strum")
        #expect(!model.hasUnkeptChanges, "kept as it is put on")
        // Changing any of the three is no longer that sound.
        model.setRoll(.together)
        #expect(model.soundInUse == nil)
        model.undo()
        #expect(model.soundInUse?.name == "Nylon strum")
        model.undo()
        #expect(model.pattern == .held && model.roll == .together, "the playing as it was before the sound")

        // Saved from the sheet: what it plays now, under a name, for the next song.
        model.use(sound)
        model.setVoicing(.led)
        model.saveSound(named: "  My strum ")
        let saved = try #require(model.shelf.saved.first)
        #expect(saved.name == "My strum" && saved.instrument == "nylon-guitar" && saved.playing.keysVoicing == .led)
        #expect(saved.strip == sound.strip && saved.playing.seed == 0)
        #expect(model.soundInUse?.name == "My strum")
        model.forgetSound(named: "My strum")
        #expect(model.shelf.saved.isEmpty && model.soundInUse == nil)
        model.saveSound(named: "   ")
        #expect(model.shelf.saved.isEmpty, "a sound needs a name")
    }

    @Test("in the app the strip's sound is the mix's next version, the level and the pan left where the song has them")
    func stripInTheMix() throws {
        let directory = WiringFixture.temporaryDirectory("chord-sounds")
        defer { WiringFixture.remove(directory) }
        let app = BandFixture.app(in: directory, song: FormFixture.build(tempo: 100).song)
        let service = AuditionService(engine: { throw NoDevice() }, kitsDirectory: directory)
        let adapter = ChordsAdapter(app: app, service: service)
        let song = try #require(app.song)
        let part = try #require(Guidance.progressions(in: song).last?.partID)
        // A level and a pan the song already has on the strip.
        var mix = Guidance.mix(in: song) ?? Mix()
        var strip = mix.strip(for: part, label: "Chords")
        strip.gainDB = -4
        strip.pan = 0.3
        mix.set(strip)
        _ = MixAdapter(app: app).commit(mix, base: Guidance.mixes(in: song).last, note: "set by hand")
        let before = app.song!.versions.count

        let sound = StripSound(insert: .rotarySlow, modulation: .chorus, sendDB: -12, echoDB: -20)
        #expect(adapter.setStripSound(sound, for: part))
        #expect(app.song!.versions.count == before + 1)
        let kept = try #require(Guidance.mix(in: app.song!)?.strip(for: part))
        #expect(kept.insert == .rotarySlow && kept.modulation == .chorus && kept.sendDB == -12 && kept.echoDB == -20)
        #expect(kept.gainDB == -4 && kept.pan == 0.3)
        #expect(adapter.stripSound(for: part) == sound)
        #expect(Guidance.mixes(in: app.song!).last?.note?.contains("from a saved sound") == true)
        // The same again moves nothing and records nothing.
        #expect(adapter.setStripSound(sound, for: part) && app.song!.versions.count == before + 1)
        #expect(!adapter.setStripSound(sound, for: nil), "no part, no strip")
    }
}
