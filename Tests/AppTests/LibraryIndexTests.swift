import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The library browser's index and its queries: facts read from what the frame holds, relations
// both ways, and searching, filtering and sorting that touch nothing.

enum LibraryIndexFixture {
    static func media(_ c: Character) -> MediaRef {
        MediaRef(hash: ContentHash(hex: String(repeating: c, count: 64))!, fileExtension: "wav")
    }

    static let day = Date(timeIntervalSince1970: 1_790_000_000)

    /// Three records, four songs, a chop, an idea and an album, related every way the index reads.
    struct Shelf {
        var library: Library
        var drifter: Record, ferry: Record, brass: Record
        var nightBus: Song, river: Song, quiet: Song, cafe: Song
        var chop: LibrarySample
        var idea: PartVersion
        var album: Album
    }

    static func shelf() -> Shelf {
        let drifterBass = media("b"), drifterDrums = media("d")
        let drifter = Record(title: "Drifter", artist: "The Tides", media: media("a"),
                             analysis: PartVersion(partID: PartID(), kind: .analysis(MusicAnalysis(
                                duration: 19.2, keys: [KeyRange(start: 0, end: 19.2, key: Key(parsing: "D minor")!)],
                                bars: (0..<8).map { TimeRange(start: Double($0) * 2.4, end: Double($0 + 1) * 2.4) },
                                tempo: [TempoRange(start: 0, end: 19.2, bpm: 100)],
                                loudness: Loudness(integrated: -12.5))),
                                author: .user, operation: Operation.analyzed),
                             importedAt: day,
                             stems: [RecordStem(name: "drums", media: drifterDrums, sampleRate: 44100, channelCount: 2, duration: 19.2),
                                     RecordStem(name: "bass", media: drifterBass, sampleRate: 44100, channelCount: 2, duration: 19.2)],
                             tuning: 12)
        let ferry = Record(title: "Ferry Bells", media: media("c"), importedAt: day.addingTimeInterval(60))
        let brass = Record(title: "Brass Band 78", media: media("e"),
                           analysis: PartVersion(partID: PartID(), kind: .analysis(MusicAnalysis(
                              duration: 30, keys: [KeyRange(start: 0, end: 30, key: Key(parsing: "A minor")!)],
                              tempo: [TempoRange(start: 0, end: 30, bpm: 170)])),
                              author: .user, operation: Operation.analyzed),
                           importedAt: day.addingTimeInterval(120), grid: RecordGrid(tempo: 0.5), tuning: -3)

        // Night Bus: a chop fitted from Drifter's drums, and the library's chop of Drifter.
        let chopSample = Sample(media: media("f"), slices: [SliceMarker(position: 0), SliceMarker(position: 1)],
                                rootPitch: Pitch(midi: 50), detectedTempo: 100, sourceRecord: drifter.id)
        let chop = LibrarySample(name: "Drifter hit", sample: chopSample, tags: ["dusty"], addedAt: day.addingTimeInterval(300))
        var nightBus = Song(title: "Night Bus", key: Key(parsing: "C major"), tempo: 85, createdAt: day)
        let fitted = Sample(media: media("1"), fit: SourceFit(label: "Drifter", media: drifterDrums, stem: "drums", start: 0, record: drifter.id))
        let fittedPart = PartID()
        try! nightBus.append(PartVersion(partID: fittedPart, kind: .sample(fitted), createdAt: day.addingTimeInterval(1000),
                                         author: .user, operation: Operation.adopted, note: "Drums of Drifter"))
        try! nightBus.append(PartVersion(partID: fittedPart, kind: .sample(fitted), createdAt: day.addingTimeInterval(2000),
                                         author: .user, operation: Operation.adopted, note: "Drums of Drifter, again"))
        try! nightBus.append(PartVersion(partID: PartID(), kind: .sample(chopSample), createdAt: day.addingTimeInterval(1500),
                                         author: .user, operation: Operation.adopted))
        nightBus.sections = [Section(name: "Song", stitch: [Lane(part: fittedPart)], lengthInBars: 16)]

        // River: grew from Ferry Bells, and plays Drifter's bass stem as it was separated.
        var river = Song(title: "River", key: Key(parsing: "B minor"), tempo: 170, createdAt: day)
        river.seeds = [Seed(kind: .importedRecord(ferry.id))]
        try! river.append(PartVersion(partID: PartID(), kind: .audio(Audio(media: drifterBass, role: .stem, stem: "bass",
                                                                             sampleRate: 44100, channelCount: 2, duration: 19.2)),
                                      createdAt: day.addingTimeInterval(500), author: .user, operation: Operation.adopted))

        // Quiet: house, said; a brief; the idea's chords.
        let idea = PartVersion(partID: PartID(), kind: .progression(TransportFixture.progression()), createdAt: day,
                               author: .user, operation: Operation.written, note: "the changes")
        var quiet = Song(title: "Quiet", artist: "Vessel", key: Key(parsing: "D minor"), tempo: 122, createdAt: day)
        quiet.genre = "house"
        quiet.setBrief("a slow walk home after the last train")
        try! quiet.append(PartVersion(partID: PartID(), kind: idea.kind, createdAt: day.addingTimeInterval(50),
                                      author: .user, operation: Operation.adopted))

        let cafe = Song(title: "Café Noir", key: Key(parsing: "F# minor"), tempo: 85, createdAt: day.addingTimeInterval(9000))

        var album = Album(title: "Late", songs: [nightBus.id, quiet.id], createdAt: day)
        album.releases[nightBus.id] = TrackRelease(mixVersion: nil, integratedLUFS: -13.2, truePeakDBTP: -1, durationSeconds: 45,
                                                   trimDB: 0, releasedAt: day.addingTimeInterval(4000))

        var library = Library(songs: [nightBus, river, quiet, cafe], albums: [album], ideas: [idea],
                              records: [drifter, ferry, brass], samples: [chop])
        library.voice = nil
        return Shelf(library: library, drifter: drifter, ferry: ferry, brass: brass, nightBus: nightBus, river: river,
                     quiet: quiet, cafe: cafe, chop: chop, idea: idea, album: album)
    }
}

@Suite("The library's index") @MainActor
struct LibraryIndexTests {
    typealias Fixture = LibraryIndexFixture

    @Test("a song is described without opening it: key, tempo, length, genre, brief, when, how loud")
    func songFacts() throws {
        let shelf = Fixture.shelf()
        let index = LibraryIndex(library: shelf.library)
        let bus = try #require(index.facts(.song(shelf.nightBus.id)))
        #expect(bus.key == Key(parsing: "C major"))
        #expect(bus.tempo == 85 && bus.bars == 16)
        #expect(abs((bus.seconds ?? 0) - 16 * 4 * 60 / 85) < 1e-9)
        #expect(bus.changed == Fixture.day.addingTimeInterval(2000), "its newest version")
        #expect(bus.loudness == -13.2, "what its release measured")
        #expect(bus.records == 1 && bus.albums == 1)

        let quiet = try #require(index.facts(.song(shelf.quiet.id)))
        #expect(quiet.genreID == "house" && quiet.genre == "House" && !quiet.genreIsGuessed)
        #expect(quiet.brief == "a slow walk home after the last train")
        #expect(quiet.loudness == nil, "never released, so never measured")

        let cafe = try #require(index.facts(.song(shelf.cafe.id)))
        #expect(cafe.seconds == nil, "no form, no length")
        #expect(cafe.changed == Fixture.day.addingTimeInterval(9000), "no versions: when it was made")
    }

    @Test("a record, a chop, an idea and an album say what they are")
    func otherFacts() throws {
        let shelf = Fixture.shelf()
        let index = LibraryIndex(library: shelf.library)
        let drifter = try #require(index.facts(.record(shelf.drifter.id)))
        #expect(drifter.key == Key(parsing: "D minor"))
        #expect(drifter.tempo == 100 && drifter.grid == nil)
        #expect(drifter.bars == 8 && drifter.stems == 2 && drifter.tuning == 12 && drifter.loudness == -12.5)
        #expect(drifter.isOffPitch)
        #expect(drifter.songs == 2, "Night Bus and River")
        let ferry = try #require(index.facts(.record(shelf.ferry.id)))
        #expect(ferry.tempo == nil && ferry.stems == nil && ferry.songs == 1)
        let brass = try #require(index.facts(.record(shelf.brass.id)))
        #expect(brass.tempo == 85 && brass.grid == "halved", "read through its grid")
        #expect(!brass.isOffPitch, "3 cents is at pitch")

        let chop = try #require(index.facts(.sample(shelf.chop.id)))
        #expect(chop.root == Pitch(midi: 50) && chop.slices == 2 && chop.source == "Drifter" && chop.tags == ["dusty"])
        #expect(chop.songs == 1)
        let idea = try #require(index.facts(.idea(shelf.idea.id)))
        #expect(idea.kind == .progression && idea.key == Key(parsing: "C major") && idea.bars == 4 && idea.note == "the changes")
        #expect(idea.songs == 1)
        let album = try #require(index.facts(.album(shelf.album.id)))
        #expect(album.songs == 2)
        #expect(abs((album.seconds ?? 0) - (16 * 4 * 60 / 85 + Album.defaultGap)) < 1e-9, "Quiet has no form, so only Night Bus counts")
        #expect(album.changed == Fixture.day.addingTimeInterval(4000), "its last release")
    }

    @Test("relations run both ways: made from, used in, on an album, cut from")
    func relations() {
        let shelf = Fixture.shelf()
        let index = LibraryIndex(library: shelf.library)
        #expect(index.records(in: shelf.nightBus.id) == [shelf.drifter.id])
        #expect(index.records(in: shelf.river.id) == [shelf.drifter.id, shelf.ferry.id], "a part first, then the record it grew from")
        #expect(index.records(in: shelf.cafe.id).isEmpty)

        let uses = index.uses(of: shelf.drifter.id)
        #expect(uses.map(\.song) == [shelf.nightBus.id, shelf.nightBus.id, shelf.river.id], "the fitted drums, the chop, the bass")
        #expect(uses.map(\.stem) == ["drums", nil, "bass"])
        #expect(uses.map(\.title) == ["Drums of Drifter, again", "Chop", "Bass stem"], "one use per part, as its newest version says it")
        #expect(index.songs(using: shelf.drifter.id) == [shelf.nightBus.id, shelf.river.id])
        #expect(index.songs(using: shelf.ferry.id) == [shelf.river.id])
        #expect(index.uses(of: shelf.ferry.id).first?.part == nil, "grown from, with no part from it")
        #expect(index.songs(using: shelf.brass.id).isEmpty)

        #expect(index.albums(holding: shelf.nightBus.id) == [shelf.album.id])
        #expect(index.source(of: .sample(shelf.chop.id)) == shelf.drifter.id)
        #expect(index.chops(of: shelf.drifter.id) == [shelf.chop.id])
        #expect(index.songs(holding: .sample(shelf.chop.id)) == [shelf.nightBus.id])
        #expect(index.songs(holding: .idea(shelf.idea.id)) == [shelf.quiet.id])
    }

    @Test("the open song is read as it stands, and a song the library does not hold is not listed")
    func openSong() throws {
        let shelf = Fixture.shelf()
        var changed = shelf.cafe
        changed.tempo = 90
        let index = LibraryIndex(library: shelf.library, openSong: changed)
        #expect(index.facts(.song(shelf.cafe.id))?.tempo == 90)
        let stranger = LibraryIndex(library: shelf.library, openSong: Song(title: "Unsaved"))
        #expect(stranger.items(on: .songs).count == 4)
    }

    @Test("refreshing the open song moves its relations and every count that reads them")
    func refresh() throws {
        let shelf = Fixture.shelf()
        var index = LibraryIndex(library: shelf.library)
        var cafe = shelf.cafe
        try cafe.append(PartVersion(partID: PartID(), kind: .audio(Audio(media: shelf.brass.media, role: .take, sampleRate: 44100,
                                                                         channelCount: 2, duration: 30)),
                                    author: .user, operation: Operation.adopted))
        try cafe.append(PartVersion(partID: PartID(), kind: .progression(TransportFixture.progression()),
                                    author: .user, operation: Operation.adopted))
        index.refresh(cafe)
        #expect(index.records(in: cafe.id) == [shelf.brass.id])
        #expect(index.facts(.record(shelf.brass.id))?.songs == 1)
        #expect(index.songs(holding: .idea(shelf.idea.id)) == [shelf.quiet.id, cafe.id], "in the library's order")
        #expect(index.facts(.idea(shelf.idea.id))?.songs == 2)
        #expect(index.facts(.song(cafe.id))?.records == 1)

        // And back: Night Bus lets Drifter go.
        var bus = shelf.nightBus
        bus.title = "Night Bus (no drums)"
        let without = Song(id: bus.id, title: bus.title, key: bus.key, tempo: bus.tempo, sections: [], createdAt: Fixture.day)
        index.refresh(without)
        #expect(index.songs(using: shelf.drifter.id) == [shelf.river.id])
        #expect(index.facts(.record(shelf.drifter.id))?.songs == 1)
        #expect(index.facts(.sample(shelf.chop.id))?.songs == 0)
        #expect(index.facts(.album(shelf.album.id))?.seconds == nil, "neither of its songs has a form now")
        #expect(index.facts(.song(bus.id))?.title == "Night Bus (no drums)")
    }

    @Test("the frame's index follows the open song without a save, and the library when it is written")
    func frameFollows() throws {
        let shelf = Fixture.shelf()
        let app = AppState(library: shelf.library, song: shelf.cafe, transportHost: StubTransportHost())
        #expect(app.libraryIndex.facts(.song(shelf.cafe.id))?.tempo == 85)
        #expect(app.setTempo(96))
        #expect(app.libraryIndex.facts(.song(shelf.cafe.id))?.tempo == 96, "unsaved, and already so")
        #expect(app.library.song(shelf.cafe.id)?.tempo == 85)

        var smaller = shelf.library
        smaller.records.removeAll { $0.id == shelf.ferry.id }
        app.library = smaller
        #expect(app.libraryIndex.facts(.record(shelf.ferry.id)) == nil)
        #expect(app.libraryIndex.records(in: shelf.river.id) == [shelf.drifter.id], "a record off the shelf is no relation")
        #expect(app.libraryIndex.facts(.song(shelf.cafe.id))?.tempo == 96, "still the open song as it stands")
    }
}

@Suite("Querying the library") @MainActor
struct LibraryQueryTests {
    typealias Fixture = LibraryIndexFixture

    private func titles(_ query: LibraryQuery, _ index: LibraryIndex) -> [String] { query.run(index).map(\.title) }

    @Test("every word must be found somewhere, without case, accents or the way ♯ is written")
    func words() {
        let index = LibraryIndex(library: Fixture.shelf().library)
        #expect(titles(LibraryQuery(shelf: .songs, text: "night"), index) == ["Night Bus"])
        #expect(titles(LibraryQuery(shelf: .songs, text: "BUS night"), index) == ["Night Bus"])
        #expect(titles(LibraryQuery(shelf: .songs, text: "night quiet"), index).isEmpty)
        #expect(titles(LibraryQuery(shelf: .songs, text: "cafe"), index) == ["Café Noir"])
        #expect(titles(LibraryQuery(shelf: .songs, text: "f# minor"), index) == ["Café Noir"])
        #expect(titles(LibraryQuery(shelf: .songs, text: "85 bpm"), index) == ["Night Bus", "Café Noir"])
        #expect(titles(LibraryQuery(shelf: .songs, text: "house train"), index) == ["Quiet"], "the genre and the brief")
        #expect(titles(LibraryQuery(shelf: .records, text: "tides"), index) == ["Drifter"], "the artist")
        #expect(titles(LibraryQuery(shelf: .records, text: "bass"), index) == ["Drifter"], "a stem's name")
        #expect(titles(LibraryQuery(shelf: .samples, text: "drifter dusty"), index) == ["Drifter hit"], "its source and its tags")
        #expect(titles(LibraryQuery(shelf: .songs, text: "  "), index).count == 4)
    }

    @Test("a key admits its relative, and keys within so many semitones as a merge moves them")
    func keys() {
        let index = LibraryIndex(library: Fixture.shelf().library)
        let c = Key(parsing: "C major")!
        #expect(titles(LibraryQuery(shelf: .records, key: .init(c)), index) == ["Brass Band 78"], "A minor is C major's relative")
        #expect(titles(LibraryQuery(shelf: .songs, key: .init(c)), index) == ["Night Bus"])
        #expect(titles(LibraryQuery(shelf: .songs, key: .init(c, within: 2)), index) == ["Night Bus", "River"], "B minor is two down")
        #expect(titles(LibraryQuery(shelf: .songs, key: .init(c, within: 3)), index) == ["Night Bus", "River", "Café Noir"], "F♯ minor is three, D minor five")
        #expect(LibraryQuery.KeyFilter(c).semitones(from: Key(parsing: "B minor")) == -2)
        #expect(!LibraryQuery.KeyFilter(c, within: 6).admits(nil), "a groove has no key to admit")
    }

    @Test("a tempo range counts half and double time unless told not to")
    func tempos() {
        let index = LibraryIndex(library: Fixture.shelf().library)
        let range = LibraryQuery.TempoFilter(80, 90)
        #expect(range.reading(of: 85) == .asIs && range.reading(of: 170) == .halved && range.reading(of: 42.5) == .doubled)
        #expect(range.reading(of: 122) == nil && range.reading(of: nil) == nil)
        #expect(titles(LibraryQuery(shelf: .songs, tempo: range), index) == ["Night Bus", "River", "Café Noir"])
        #expect(titles(LibraryQuery(shelf: .songs, tempo: .init(80, 90, halfAndDouble: false)), index) == ["Night Bus", "Café Noir"])
        let near170 = LibraryQuery(shelf: .records, tempo: .around(170, percent: 2, halfAndDouble: false))
        #expect(titles(near170, index).isEmpty, "Brass Band 78 reads 85 through its grid")
        #expect(titles(near170.with(halfAndDouble: true), index) == ["Brass Band 78"], "and 85 doubled is 170")
    }

    @Test("stems, used or not, genre and pitch narrow a shelf")
    func filters() {
        let index = LibraryIndex(library: Fixture.shelf().library)
        #expect(titles(LibraryQuery(shelf: .records, hasStems: true), index) == ["Drifter"])
        #expect(titles(LibraryQuery(shelf: .records, hasStems: false), index) == ["Ferry Bells", "Brass Band 78"])
        #expect(titles(LibraryQuery(shelf: .records, usage: .unused), index) == ["Brass Band 78"])
        #expect(titles(LibraryQuery(shelf: .records, usage: .used), index) == ["Drifter", "Ferry Bells"])
        #expect(titles(LibraryQuery(shelf: .songs, usage: .used), index) == ["Night Bus", "Quiet"], "a song is used on an album")
        #expect(titles(LibraryQuery(shelf: .songs, genre: "House"), index) == ["Quiet"])
        #expect(titles(LibraryQuery(shelf: .records, offPitch: true), index) == ["Drifter"])
        #expect(!LibraryQuery(shelf: .songs, sort: .init(.title)).narrows)
        #expect(LibraryQuery(shelf: .songs, usage: .used).narrows)
    }

    @Test("sorting is stable, either way, with what lacks the fact last")
    func sorting() {
        let index = LibraryIndex(library: Fixture.shelf().library)
        #expect(titles(LibraryQuery(shelf: .songs, sort: .init(.tempo)), index) == ["Night Bus", "Café Noir", "Quiet", "River"],
                "the two at 85 keep the library's order")
        #expect(titles(LibraryQuery(shelf: .songs, sort: .init(.tempo, ascending: false)), index) == ["River", "Quiet", "Night Bus", "Café Noir"],
                "and keep it going down too")
        #expect(titles(LibraryQuery(shelf: .records, sort: .init(.tempo)), index) == ["Brass Band 78", "Drifter", "Ferry Bells"])
        #expect(titles(LibraryQuery(shelf: .records, sort: .init(.tempo, ascending: false)), index) == ["Drifter", "Brass Band 78", "Ferry Bells"],
                "unread, last both ways")
        #expect(titles(LibraryQuery(shelf: .songs, sort: .init(.title)), index) == ["Café Noir", "Night Bus", "Quiet", "River"])
        #expect(titles(LibraryQuery(shelf: .songs, sort: .init(.key)), index) == ["Night Bus", "Quiet", "Café Noir", "River"])
        #expect(titles(LibraryQuery(shelf: .songs, sort: .init(.changed, ascending: false)), index).first == "Café Noir")
        #expect(titles(LibraryQuery(shelf: .records, sort: .init(.tuning, ascending: false)), index) == ["Drifter", "Brass Band 78", "Ferry Bells"],
                "furthest off pitch first, sharp or flat")
        #expect(titles(LibraryQuery(shelf: .songs), index) == ["Night Bus", "River", "Quiet", "Café Noir"], "no sort: the library's order")
    }

    @Test("a query keeps as JSON, for a filter to be saved by name")
    func codable() throws {
        let query = LibraryQuery(shelf: .records, text: "drift", key: .init(Key(parsing: "D minor")!, within: 2),
                                 tempo: .around(90), hasStems: true, usage: .unused, genre: "house", offPitch: false,
                                 sort: .init(.tempo, ascending: false))
        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(LibraryQuery.self, from: data) == query)
    }
}

private extension LibraryQuery {
    func with(halfAndDouble: Bool) -> LibraryQuery {
        var copy = self
        copy.tempo?.halfAndDouble = halfAndDouble
        return copy
    }
}
