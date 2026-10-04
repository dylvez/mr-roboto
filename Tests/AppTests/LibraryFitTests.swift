import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// What goes with the open song: every record, idea and sample fitted to its key and tempo by the
// arithmetic Sources uses, said in its sentences, ranked by how far each has to go.

@Suite("What goes with the open song") @MainActor
struct LibraryFitTests {
    typealias Fixture = LibraryIndexFixture

    private func target(_ key: String?, _ tempo: Double) -> FitTarget {
        FitTarget(Song(title: "Night Bus", key: key.flatMap(Key.init(parsing:)), tempo: tempo))
    }

    @Test("fixture pairs: the semitones, the stretch, the tuning, and how far that is")
    func pairs() throws {
        let shelf = Fixture.shelf()
        let song = target("C major", 85)

        // Brass Band 78: A minor is C major's relative, and its grid reads 85.
        let brass = try #require(LibraryFitting.fit(shelf.brass, into: song))
        #expect(brass.semitones == 0 && brass.tempoFactor == 1 && abs(brass.ratio - 1) < 1e-9 && brass.cents == 0)
        #expect(brass.verdict == .asIs && brass.cost == 0 && brass.short == "as it is")

        // Drifter: D minor into C major is five down to A minor; 100 stretched to 85; 12 cents sharp.
        let drifter = try #require(LibraryFitting.fit(shelf.drifter, into: song))
        #expect(drifter.semitones == -5 && drifter.tempoFactor == 1)
        #expect(abs(drifter.ratio - 100.0 / 85) < 1e-9 && drifter.cents == -12)
        #expect(drifter.verdict == .far, "past four semitones")
        #expect(drifter.flags.contains { $0.contains("past 4") })
        #expect(drifter.sentences.contains { $0.contains("down 5 semitones to A minor") })
        #expect(drifter.sentences.contains("Down 12 cents to concert pitch: the record sits that far sharp."))
        #expect(drifter.short == "−5 st, ×1.18")

        #expect(LibraryFitting.fit(shelf.ferry, into: song) == nil, "not read: nothing to fit")

        // The chop has a tempo and no key: stretched, never moved.
        let chop = try #require(LibraryFitting.fit(shelf.chop, into: song))
        #expect(chop.semitones == 0 && chop.verdict == .moves && abs(chop.cost - (100.0 / 85 - 1) * 100 / 3) < 1e-9)

        // A written part moves by arithmetic, which costs its sound nothing.
        let idea = try #require(LibraryFitting.fit(shelf.idea, into: target("D major", 85)))
        #expect(idea.semitones == 2 && idea.cost == 0 && idea.verdict == .near)
        #expect(LibraryFitting.fit(shelf.idea, into: song)?.verdict == .asIs)
    }

    @Test("double and half time come before a stretch past twelve percent, and cost a step")
    func halfAndDouble() throws {
        let shelf = Fixture.shelf()
        // Brass reads 85; a song at 170 takes it doubled, exactly.
        let doubled = try #require(LibraryFitting.fit(shelf.brass, into: target("C major", 170)))
        #expect(doubled.tempoFactor == 2 && abs(doubled.ratio - 1) < 1e-9 && doubled.cost == 0.5)
        #expect(doubled.short == "2×" && doubled.verdict == .near, "read at double time, not stretched")
    }

    @Test("the sentence is the one Sources gives for the same record and song")
    func sameAsSources() throws {
        var open = Song(title: "Night Bus", key: Key(parsing: "C major"), tempo: 85)
        try open.append(TransportFixture.grooveVersion())
        let built = try ListeningFixture.built("fit-sources", open: open)
        defer { try? FileManager.default.removeItem(at: built.directory) }
        var record = built.record
        record.tuning = 20
        built.app.library = Library(records: [record])
        let fit = try #require(LibraryFitting.fit(record, into: FitTarget(built.app.song!)))
        let pick = try built.app.sourcePick(SourceRequest(.record(record.id), stem: Mashups.full))
        #expect(!fit.sentences.isEmpty)
        for sentence in fit.sentences { #expect(pick.plan.sentences.contains(sentence), "\(sentence)") }
        #expect(fit.semitones == pick.plan.move.semitones && fit.ratio == pick.plan.move.ratio && fit.cents == pick.plan.move.cents)
    }

    @Test("the index fits to the open song, follows its key and tempo, and fits nothing with none open")
    func index() throws {
        let shelf = Fixture.shelf()
        #expect(LibraryIndex(library: shelf.library).facts(.record(shelf.brass.id))?.fit == nil)
        var index = LibraryIndex(library: shelf.library, openSong: shelf.nightBus)
        #expect(index.fitTarget?.title == "Night Bus")
        #expect(index.facts(.record(shelf.brass.id))?.fit?.verdict == .asIs)
        #expect(index.facts(.sample(shelf.chop.id))?.fit != nil && index.facts(.idea(shelf.idea.id))?.fit != nil)
        #expect(index.facts(.song(shelf.river.id))?.fit == nil, "a song is not fitted to another")

        var moved = shelf.nightBus
        moved.key = Key(parsing: "D minor")
        index.refresh(moved)
        #expect(index.facts(.record(shelf.drifter.id))?.fit?.semitones == 0, "Drifter's own key now")
        #expect(index.facts(.record(shelf.drifter.id))?.fit?.verdict == .moves, "still stretched 100 to 85: 18%")
        #expect(index.facts(.record(shelf.brass.id))?.fit?.semitones == 5)

        // A song not saved yet is still what everything is fitted to, once it holds something.
        var fresh = Song(title: "Sketch", key: Key(parsing: "A minor"), tempo: 85)
        #expect(LibraryIndex(library: shelf.library, openSong: fresh).fitTarget == nil,
                "a blank song takes the first record's key and tempo: everything goes with it")
        try fresh.append(TransportFixture.grooveVersion())
        #expect(LibraryIndex(library: shelf.library, openSong: fresh).facts(.record(shelf.brass.id))?.fit?.verdict == .asIs)
    }

    @Test("goes with: only what a sample bears, nearest first; nothing held back with no song open")
    func goesWith() {
        let shelf = Fixture.shelf()
        let open = LibraryIndex(library: shelf.library, openSong: shelf.nightBus)
        let query = LibraryQuery(shelf: .records, goesWith: true, sort: .init(.fit))
        #expect(query.run(open).map(\.title) == ["Brass Band 78"], "Drifter is five semitones off; Ferry Bells has not been read")
        #expect(LibraryQuery(shelf: .records, sort: .init(.fit)).run(open).map(\.title) == ["Brass Band 78", "Drifter", "Ferry Bells"])
        #expect(LibraryQuery(shelf: .samples, goesWith: true).run(open).map(\.title) == ["Drifter hit"])
        #expect(query.run(LibraryIndex(library: shelf.library)).count == 3, "no song open: the filter means nothing")
        #expect(query.narrows)
    }

    @Test("the browser offers it only with a song open, and turning it on orders by fit")
    func browser() {
        let (closed, _) = LibraryBrowserFixture.app()
        let none = LibraryBrowserModel(app: closed, memory: .inMemory())
        none.choose(.records)
        #expect(!none.filters.contains(.goesWith))
        #expect(LibrarySurfaceView.columns(for: .records, width: 1400, fitting: false).contains(.fit) == false)

        let (open, shelf) = LibraryBrowserFixture.app(open: { $0.nightBus })
        let model = LibraryBrowserModel(app: open, memory: .inMemory())
        model.choose(.records)
        #expect(model.filters.first == .goesWith)
        #expect(LibrarySurfaceView.columns(for: .records, width: 1400, fitting: true)[1] == .fit)
        model.toggleGoesWith()
        #expect(model.query.goesWith == true && model.query.sort == .init(.fit))
        #expect(model.rows.map(\.id) == [.record(shelf.brass.id)])
        model.toggleGoesWith()
        #expect(model.query.goesWith == nil && model.query.sort == nil)
    }

    @Test("a song's detail says which bars of a record it takes")
    func bars() {
        let shelf = Fixture.shelf()
        let index = LibraryIndex(library: shelf.library)
        let uses = index.uses(of: shelf.drifter.id)
        #expect(uses.first?.bars == 4..<8)
        #expect(uses.map(\.bars) == [4..<8, nil, nil])
    }
}
