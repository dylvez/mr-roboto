import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// Someone in the band always asks what you want to do next: from launch, in an empty song, and at
// every step of one in progress, ranked by the order the work goes in, what just happened, and
// what you have chosen before.

@Suite("The band asks what next", .serialized) @MainActor
struct NextQuestionTests {

    private func beat(groove: PartVersion = TransportFixture.grooveVersion()) -> Song {
        TransportFixture.song([groove], sections: [])
    }

    @Test("with no song open the Director asks where to start: a new song or a record, and a song you were in first")
    func atLaunch() throws {
        let (app, directory, defaults) = CompletenessFixture.app("next-launch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = app.nextQuestion
        #expect(empty.asker == .director && empty.stage == "launch")
        #expect(empty.options.map(\.kind) == ["newSong", "importRecord"])
        #expect(empty.question == "How do you want to start?" && empty.observation == "The library is empty.")

        let song = beat()
        let (again, againDirectory, againDefaults) = CompletenessFixture.app("next-launch-last", library: Library(songs: [song]))
        defer { try? FileManager.default.removeItem(at: againDirectory) }
        againDefaults.set(song.id.rawValue.uuidString, forKey: AppState.lastOpenedSongKey)
        let back = again.nextQuestion
        let first = try #require(back.options.first)
        #expect(first.move == .openSong(song.id) && first.title == "Pick up \(song.title)")
        #expect(back.observation == "Last time you were in \(song.title).")
        #expect(first.rationale.contains("next on its path: bass"), "\(first.rationale)")
        _ = defaults
    }

    @Test("in an empty song: name it and set its clock first, then a groove")
    func emptySong() {
        let (app, directory, _) = CompletenessFixture.app("next-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song(title: "Untitled, Sep 26", tempo: 120))
        #expect(app.nextQuestion.options.first?.kind == "songSettings")
        #expect(app.nextQuestion.question == "How do you want to start it?")
        app.open(Song(title: "Glass", key: Key(parsing: "F minor"), tempo: 88))
        let question = app.nextQuestion
        #expect(question.options.first?.kind == "groove")
        #expect(question.options.contains { $0.kind == "askBand" })
    }

    @Test("a groove just kept: the Bassist asks, a bass line first, in the song's numbers")
    func afterAGroove() throws {
        let (app, directory, _) = CompletenessFixture.app("next-groove")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(beat())
        let question = app.nextQuestion
        #expect(question.stage == "beat.bass")
        #expect(question.asker == .persona("Bassist"))
        #expect(question.options.first?.kind == "bass", "\(question.options.map(\.kind))")
        #expect(question.options.count <= NextAdvisor.maximumOptions)
        #expect(question.question.hasPrefix("A bass line next, or "), "\(question.question)")
        #expect(question.observation.contains("% swing"), "\(question.observation)")
    }

    @Test("what you choose here rises here and says so; Not this takes it away and sinks it")
    func preferences() throws {
        let (app, directory, _) = CompletenessFixture.app("next-prefs")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(beat())
        let before = app.nextQuestion
        #expect(before.options.first?.kind == "bass")
        for _ in 0..<3 { app.nextPreferences.chose("chords", at: before.stage, offered: before.options.map(\.kind)) }
        let after = app.nextQuestion
        let chords = try #require(after.options.first)
        #expect(chords.kind == "chords" && chords.isYourUsual, "\(after.options.map(\.kind))")
        #expect(after.question.hasPrefix("Chords next"), "\(after.question)")

        let liked = app.nextPreferences.weight(of: "chords", at: after.stage)
        app.decline(chords, in: after)
        #expect(!app.nextQuestion.options.contains { $0.kind == "chords" })
        #expect(app.nextPreferences.weight(of: "chords", at: after.stage) < liked - 1.4, "Not this sinks it")

        // Remembered across launches, in the app's defaults.
        let reread = NextPreferences(defaults: app.defaults)
        #expect(reread.weight(of: "chords", at: after.stage) == app.nextPreferences.weight(of: "chords", at: after.stage))
    }

    @Test("taking an option does it and remembers it; what is open already is not offered")
    func takeAndWhereYouAre() throws {
        let (app, directory, _) = CompletenessFixture.app("next-take")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(beat())
        let question = app.nextQuestion
        let bass = try #require(question.options.first { $0.kind == "bass" })
        app.take(bass, from: question)
        #expect(app.bench.active?.kind == .pianoRoll)
        #expect(app.nextPreferences.weight(of: "bass", at: question.stage) > 0)
        #expect(!app.nextQuestion.options.contains { $0.kind == "bass" }, "the roll is open on it")
    }

    @Test("folded away, the question is in the dock; on an empty bench it is the bench's")
    func placement() {
        let (app, directory, _) = CompletenessFixture.app("next-dock")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(beat())
        app.closeAllSurfaces()
        #expect(!app.regions.isCollapsed(.rail), "the band is open from the first launch")
        #expect(app.dockQuestion == nil, "the band's column is showing it")
        app.regions.setCollapsed(true, for: .rail)
        #expect(app.dockQuestion == nil, "the empty bench carries the whole card")
        _ = app.perform(Guidance.dockAction(for: .grid, in: app.song))
        let docked = app.dockQuestion
        #expect(docked?.option == app.nextQuestion.options.first)
        app.regions.setCollapsed(false, for: .rail)
        #expect(app.dockQuestion == nil, "the band's column is showing it")
    }
}
