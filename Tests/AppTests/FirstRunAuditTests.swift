import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The first-run and menus audit, and the stale sheets from the tempo audit: each test is one of
// what they found, fixed.

@Suite("First run and menus, audited", .serialized) @MainActor
struct FirstRunAuditTests {

    @Test("a surface that makes parts, opened with no song, starts one, and what is made there is kept")
    func aSurfaceStartsASong() throws {
        let (app, directory, _) = CompletenessFixture.app("first-grid")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(app.song == nil)
        let id = try #require(app.perform(Guidance.dockAction(for: .grid, in: nil)))
        let song = try #require(app.song, "a song to keep the beat in")
        #expect(song.title.hasPrefix("Untitled"))
        #expect(app.bench.items.contains { $0.id == id && $0.kind == .grid })
        #expect(app.record(TransportFixture.grooveVersion()), "a version made there has a song to go in")

        // The Record surface makes its own song on import, and a mashup chooses two; neither starts one.
        let (other, otherDirectory, _) = CompletenessFixture.app("first-record")
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        _ = other.perform(Guidance.dockAction(for: .importRecord, in: nil))
        #expect(other.song == nil)
    }

    @Test("the band's failures say what happened and what to do, in the app's words")
    func bandSentences() {
        #expect(!ClaudeError.missingAPIKey.sentence.contains("ANTHROPIC_API_KEY"))
        #expect(ClaudeError.missingAPIKey.sentence.contains("Set the key…"))
        let refused = ClaudeError.http(status: 401, type: "authentication_error", message: "invalid x-api-key", requestID: "req_1")
        #expect(refused.sentence == ClaudeError.keyRefused && !refused.sentence.contains("HTTP"))
        #expect(ClaudeError.transport("offline").sentence.contains("could not reach"))
        #expect(ClaudeError.http(status: 529, type: "overloaded_error", message: "", requestID: nil).sentence.contains("busy"))
        #expect(ClaudeError.malformedStream("x").sentence == ClaudeError.malformedStream("x").description)
    }

    @Test("Structure's length line follows the song's tempo and meter; an open Chords sheet writes in the new meter")
    func sheetsFollowTheSong() throws {
        let (app, directory, _) = CompletenessFixture.app("first-sheets")
        defer { try? FileManager.default.removeItem(at: directory) }
        app.open(Song.new(title: "Glass", tempo: 120))
        let structureID = try #require(app.perform(SurfaceAction(surface: .structure, title: "Glass")))
        let form = try #require(app.bench.items.first { $0.id == structureID })
        #expect(SurfaceWiring.shared.structureModel(for: form, app: app).tempo == 120)
        #expect(app.setTempo(90))
        let structure = SurfaceWiring.shared.structureModel(for: form, app: app)
        structure.sync(with: app.song)
        #expect(structure.tempo == 90)

        let chordsID = try #require(app.perform(SurfaceAction(surface: .chords, title: "Chords")))
        let item = try #require(app.bench.items.first { $0.id == chordsID })
        let sheet = SurfaceWiring.shared.chordsModel(for: item, app: app)
        #expect(sheet.beatsPerBar == 4)
        #expect(app.setTimeSignature(TimeSignature(beatsPerBar: 3)))
        #expect(SurfaceWiring.shared.chordsModel(for: item, app: app).beatsPerBar == 3)
    }
}
