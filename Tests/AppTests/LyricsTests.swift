import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// The Lyrics surface, driven through a stub host: the page keeps what is typed as a version, and
// the keep control knows when there is nothing new to keep.

@MainActor
final class LyricsStub: LyricsHosting {
    var committed: [PartVersion] = []
    /// A host with no song to take the version, so the surface has to say so.
    var refuses = false

    func commit(_ version: PartVersion) async -> Bool {
        if refuses { return false }
        committed.append(version)
        return true
    }
}

@Suite("Lyrics") @MainActor
struct LyricsTests {

    @Test("the keep control follows the words: nothing on an empty page, nothing after a keep, something after an edit")
    func unkeptChanges() async throws {
        let stub = LyricsStub()
        let model = LyricsModel(host: stub, corpus: LyricCorpus([]))
        #expect(!model.hasUnkeptChanges, "an empty page has nothing to keep")
        let none = await model.commit()
        #expect(none == nil)
        #expect(model.lastError == "Nothing to keep.")

        model.text = "Down by the water\nWhere the light goes thin"
        #expect(model.hasUnkeptChanges)
        let first = try #require(await model.commit())
        #expect(!model.hasUnkeptChanges)
        #expect(model.lastKept?.id == first.id)
        #expect(stub.committed.map(\.id) == [first.id])

        model.text += "\nAnd the boats come in"
        #expect(model.hasUnkeptChanges)
        model.text = "Down by the water\nWhere the light goes thin"
        #expect(!model.hasUnkeptChanges, "back to the kept words")

        // Opened on a version: nothing to keep until the words change, and an edit derives.
        let editor = LyricsModel(host: stub, lyric: first, corpus: LyricCorpus([]))
        #expect(editor.text == "Down by the water\nWhere the light goes thin")
        #expect(!editor.hasUnkeptChanges)
        editor.text = "Down by the river"
        #expect(editor.hasUnkeptChanges)
        let second = try #require(await editor.commit())
        #expect(second.parents == [first.id])
        #expect(!editor.hasUnkeptChanges)
        #expect(editor.lastKept?.id == second.id)
    }

    @Test("a host that refuses the version says so, keeps nothing, and leaves the control live")
    func refused() async {
        let stub = LyricsStub()
        stub.refuses = true
        let model = LyricsModel(host: stub, corpus: LyricCorpus([]))
        model.text = "One line"
        let none = await model.commit()
        #expect(none == nil)
        #expect(model.lastError != nil)
        #expect(model.versions.isEmpty)
        #expect(model.lastKept == nil)
        #expect(model.hasUnkeptChanges)
    }
}
