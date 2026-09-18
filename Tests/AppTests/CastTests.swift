import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// M4 Gate A, P4: the cast is the project's. A song says who is in the room; the Director consults
// only them; the cast and the house calls survive a save and a reopen.

@Suite("Cast: the song's", .serialized) @MainActor
struct CastTests {

    @Test("a song with no list has everyone; a list filters the roster in roster order")
    func inRoom() {
        #expect(Cast.standard.inRoom(for: nil).ids == Cast.standard.ids)
        var song = Song(title: "Blank")
        #expect(Cast.standard.inRoom(for: song).ids == Cast.standard.ids)
        song.cast = ["bassist", "beatmaker"]
        #expect(Cast.standard.inRoom(for: song).ids == [.beatmaker, .bassist], "roster order, not list order")
        song.cast = ["nobody"]
        #expect(Cast.standard.inRoom(for: song).ids.isEmpty)
        // A document persona joins a cast once, by id.
        let widened = Cast.standard.adding([Bassist.bible, Sampler.bible])
        #expect(widened.ids == Cast.standard.ids)
    }

    @Test("set on the surface, the cast and a house call survive a save and a reopen; an older song reads as everyone")
    func persists() throws {
        let directory = GuidanceFixture.temporaryDirectory("cast")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = LibraryFixture.app(directory)
        app.open(Song(title: "Arrival", tempo: 92))
        #expect(app.castInRoom.ids.count == Cast.standard.ids.count)
        #expect(app.setCast([.beatmaker, .bassist]))
        #expect(app.song?.cast == ["beatmaker", "bassist"])
        #expect(app.castInRoom.ids == [.beatmaker, .bassist])
        #expect(app.hasUnsavedChanges)
        #expect(app.recordHouseCall(question: "beatmaker.oq.snare-direction", choice: .alternative, how: "by ear"))
        #expect(app.song?.houseCalls?.count == 1)
        #expect(app.recordHouseCall(question: "beatmaker.oq.snare-direction", choice: .encoded, how: "changed my mind"))
        #expect(app.song?.houseCalls?.count == 1 && app.song?.houseCalls?.first?.choice == "encoded")
        app.save()

        let later = LibraryFixture.app(directory)
        later.reloadLibrary()
        later.openSong(app.song!.id)
        #expect(later.song?.cast == ["beatmaker", "bassist"])
        #expect(later.castInRoom.ids == [.beatmaker, .bassist])
        #expect(later.song?.houseCalls?.first?.how == "changed my mind")
        #expect(later.setCast([]))
        #expect(later.song?.cast == nil, "everyone is the absence of a list")

        // A song written before casts existed decodes with no list.
        let data = try SongGraphCodec.encode(Song(title: "Old"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"cast\""), "an unset cast is not written")
        #expect(try SongGraphCodec.decode(Song.self, from: data).cast == nil)
    }

    @Test("the band consults only the room: without the Beatmaker a swing question finds nobody")
    func directorConsultsTheRoom() async throws {
        let directory = GuidanceFixture.temporaryDirectory("cast-band")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = BandFixture.app(in: directory)
        let band = BandDirector(app: app)

        let everyone = await band.ask("put the swing at 80")
        #expect(everyone.verdicts.map(\.persona) == Cast.standard.ids)
        #expect(everyone.owner == .beatmaker)

        #expect(app.setCast([.sampler, .bassist]))
        let count = app.log.count
        let without = await band.ask("put the swing at 80")
        #expect(without.verdicts.map(\.persona) == [.sampler, .bassist])
        #expect(without.owner == nil, "nobody in the room takes a swing question")
        #expect(app.log.dropFirst(count).contains { $0.text.contains("Nobody in the band takes that one") })

        #expect(app.setCast([.beatmaker]))
        let only = await band.ask("put the swing at 80")
        #expect(only.verdicts.map(\.persona) == [.beatmaker])
        #expect(only.wasRefused, "80% is past the Beatmaker's ceiling")
    }
}
