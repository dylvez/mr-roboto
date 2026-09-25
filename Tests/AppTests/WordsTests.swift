import AppKit
import Foundation
import MusicTheory
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// The words are connected to the music: a stanza is named after the section it is sung in, and the
// words are set to a melody one syllable to a note, so the Lyricist can hear where a stress lands.
// Both are edits on the Lyrics surface — counted as unkept, undone with ⌘Z, kept like typing.

/// A host with a song around the words: melodies by version, section names, a 4/4 bar.
@MainActor
final class WordsHost: LyricsHosting {
    var committed: [PartVersion] = []
    /// Melody versions in graph order; a part's newest is the last of its versions here.
    var melodyVersions: [PartVersion] = []
    var sections: [String] = []

    func commit(_ version: PartVersion) -> Bool {
        committed.append(version)
        return true
    }

    var melodies: [LyricsMelody] {
        var parts: [PartID] = []
        for version in melodyVersions where !parts.contains(version.partID) { parts.append(version.partID) }
        return parts.compactMap { part in melodyVersions.last { $0.partID == part }.flatMap(Self.melody(of:)) }
    }

    func melody(_ version: VersionID) -> LyricsMelody? {
        melodyVersions.first { $0.id == version }.flatMap(Self.melody(of:))
    }

    var sectionNames: [String] { sections }

    private static func melody(of version: PartVersion) -> LyricsMelody? {
        guard case .melody(let melody) = version.kind else { return nil }
        return LyricsMelody(version: version.id, part: version.partID, title: version.note ?? "Melody", melody: melody)
    }

    /// A melody of `starts.count` notes, one at each start, a beat long at most.
    @discardableResult
    func addMelody(_ starts: [Double], deriving parent: PartVersion? = nil, title: String = "Tune") -> PartVersion {
        let melody = Melody(notes: starts.map { NoteEvent(pitch: Pitch(midi: 64), start: $0, duration: 0.5) })
        let version = parent?.deriving(.melody(melody), by: .user, operation: Operation.edit, note: title)
            ?? PartVersion(partID: PartID(), kind: .melody(melody), author: .user, operation: Operation.written, note: title)
        melodyVersions.append(version)
        return version
    }
}

@Suite("Words: labels and the setting, as edits on the Lyrics surface") @MainActor
struct WordsTests {

    private func model(_ host: WordsHost, lyric: PartVersion? = nil) -> LyricsModel {
        let model = LyricsModel(host: host, lyric: lyric, corpus: LyricCorpus([]), title: "Soft Machine")
        model.autoKeep.delay = nil
        return model
    }

    @Test("a label is an edit: unkept until kept, its own step of undo, and kept in the version")
    func labelIsAnEdit() throws {
        let host = WordsHost()
        host.sections = ["Intro", "Verse", "Hook", "Verse", "hook"]
        let model = model(host)
        #expect(model.labelChoices == ["Intro", "Verse", "Hook"], "each name once, in form order")

        model.text = "down by the water\nwhere the light goes thin"
        try #require(model.commit())
        #expect(!model.hasUnkeptChanges)

        model.label("Verse")
        #expect(model.text == "[Verse]\ndown by the water\nwhere the light goes thin")
        #expect(model.lyric.labels == [Lyric.StanzaLabel(line: 0, name: "Verse")])
        #expect(model.lyric.lines.count == 2, "the label is not a sung line")
        #expect(model.hasUnkeptChanges, "the lines are the same; the labels are not")
        #expect(model.stanzaLabels == [0: "Verse"])

        let kept = try #require(model.commit())
        guard case .lyric(let words) = kept.kind else { Issue.record("a lyric"); return }
        #expect(words.labels?.map(\.name) == ["Verse"])
        #expect(!model.hasUnkeptChanges)

        // Renamed, not labelled twice; and a chip press is undone on its own.
        model.label("Hook", atRow: 1)
        #expect(model.text == "[Hook]\ndown by the water\nwhere the light goes thin")
        model.undo()
        #expect(model.text == "[Verse]\ndown by the water\nwhere the light goes thin")
        #expect(!model.hasUnkeptChanges, "back to what was kept")
        model.undo()
        #expect(model.lyric.labels == nil && model.hasUnkeptChanges)
        model.redo()
        #expect(model.lyric.labels?.first?.name == "Verse")

        // Opened on the kept version, the words read back labelled and there is nothing to keep.
        let reopened = self.model(host, lyric: kept)
        #expect(reopened.text == "[Verse]\ndown by the water\nwhere the light goes thin")
        #expect(!reopened.hasUnkeptChanges)
    }

    @Test("a label chip names the stanza the caret is in, else the first with no name, else starts a new one")
    func labelling() {
        let text = "one\ntwo\n\nthree\nfour"
        func label(_ text: String, _ row: Int?) -> String? { LyricsModel.labelling(text, as: "Hook", atRow: row) }
        #expect(label(text, 3) == "one\ntwo\n\n[Hook]\nthree\nfour", "the caret's stanza")
        #expect(label(text, 4) == "one\ntwo\n\n[Hook]\nthree\nfour", "anywhere in it")
        #expect(label(text, 0) == "[Hook]\none\ntwo\n\nthree\nfour")
        #expect(label(text, nil) == "[Hook]\none\ntwo\n\nthree\nfour", "no caret: the first with no name")
        #expect(label("[Verse]\none\ntwo\n\nthree", nil) == "[Verse]\none\ntwo\n\n[Hook]\nthree", "the first with no name")
        #expect(label("[Verse]\n\none", nil) == "[Verse]\n\none\n\n[Hook]\n",
                "a label over a blank line still names the stanza under it, so every stanza is named and the chip starts the next")
        #expect(label("[Verse]\none", 0) == "[Hook]\none", "on a label: renamed")
        #expect(label("[Verse]\none", 1) == "[Hook]\none", "in a named stanza: renamed")
        #expect(label("[Hook]\none", 1) == nil, "already so named: nothing to change")
        #expect(label("one\n\nthree", 1) == "one\n\n[Hook]\nthree", "a blank line above a stanza names that stanza")
        #expect(label("one\ntwo\n", 2) == "one\ntwo\n\n[Hook]\n", "a blank line with nothing under it starts one there")
        #expect(label("", nil) == "[Hook]\n", "an empty page starts with the label")
        #expect(label(text, 99) == "[Hook]\none\ntwo\n\nthree\nfour", "a row past the end is no caret")

        // Whatever the chip wrote, the parser reads as the same label.
        let labelled = Lyricist.lyric(from: label(text, 3)!)
        #expect(labelled.labels == [Lyric.StanzaLabel(line: 3, name: "Hook")])
        #expect(labelled.stanza(named: "Hook")?.map(\.text) == ["three", "four"])
    }

    @Test("set to a melody: counted as it landed, following the words as they change, and undone with ⌘Z")
    func setToAMelody() throws {
        let host = WordsHost()
        let tune = host.addMelody([0, 1, 2, 3])
        let model = model(host)
        model.text = "go home now\nsing it slow"
        #expect(model.lyric.syllableCount == 6)
        try #require(model.commit())
        #expect(model.melodyChoices.map(\.version) == [tune.id])
        #expect(model.setting == nil && model.setTo == nil)

        model.setMelody(tune.id)
        #expect(model.setTo == tune.id && model.lyric.alignedTo == tune.id)
        #expect(model.lyric.lines.flatMap(\.syllables).map(\.noteIndex) == [0, 1, 2, 3, nil, nil])
        #expect(model.setting?.line == "6 syllables · 4 set to notes · 2 past the last note")
        #expect(model.hasUnkeptChanges, "the words are the same; their setting is not")
        let kept = try #require(model.commit())
        #expect(kept.note?.hasSuffix("set to Tune") == true, "\(kept.note ?? "")")
        guard case .lyric(let keptWords) = kept.kind else { Issue.record("a lyric"); return }
        #expect(keptWords.alignedTo == tune.id && keptWords.setSyllableCount == 4)

        // Retyped, the setting follows the words.
        model.text = "go home now\nsing"
        #expect(model.lyric.alignedTo == tune.id)
        #expect(model.setting?.line == "4 syllables · 4 set to notes · one to each")
        model.text = "go home"
        #expect(model.setting?.line == "2 syllables · 2 set to notes · 2 notes with no syllable")

        // ⌘Z: the typing (one pause's worth), then the setting itself.
        model.undo()
        #expect(model.text == "go home now\nsing it slow" && model.setTo == tune.id)
        #expect(!model.hasUnkeptChanges)
        model.undo()
        #expect(model.setTo == nil && model.lyric.alignedTo == nil && model.lyric.setSyllableCount == 0)
        model.redo()
        #expect(model.setTo == tune.id && model.lyric.setSyllableCount == 4)

        // "Not set" is an edit too, and a melody the song does not hold is not offered.
        model.setMelody(nil)
        #expect(model.lyric.alignedTo == nil && model.hasUnkeptChanges)
        model.setMelody(VersionID())
        #expect(model.setTo == nil)
        model.undo()
        #expect(model.setTo == tune.id)

        // A newer version of the tune: the words stay set to the one their indices are for, and
        // the surface says there is a newer one.
        let newer = host.addMelody([0, 0.5, 1, 1.5, 2, 2.5, 3], deriving: tune, title: "Tune, busier")
        #expect(model.setTo == tune.id && model.setToOlderVersion)
        #expect(model.melodyChoices.map(\.version) == [newer.id], "the newest of each melody")
        model.setMelody(newer.id)
        #expect(!model.setToOlderVersion)
        #expect(model.setting?.line == "6 syllables · 6 set to notes · 1 note with no syllable")

        // Opened on the kept, set version: set, and nothing to keep.
        let reopened = self.model(host, lyric: kept)
        #expect(reopened.setTo == tune.id && reopened.lyric == keptWords)
        #expect(!reopened.hasUnkeptChanges)
    }

    @Test("the Lyricist reads the setting on the surface: a stress off the beat is flagged, and the hook is held to the title")
    func readsTheSetting() throws {
        let host = WordsHost()
        // "now" — the third syllable — starts on the and of 2.
        let tune = host.addMelody([0, 1, 1.5, 2, 3, 4])
        let model = model(host)
        model.text = "[Verse]\ngo home now\nsing it slow"
        #expect(!model.readings.contains { $0.rule == "lyricist.stressed-on-strong" }, "not set, not read")
        #expect(!model.readings.contains { $0.rule == "lyricist.title-in-the-hook" }, "no hook, not read")

        model.setMelody(tune.id)
        let stress = try #require(model.readings.first { $0.rule == "lyricist.stressed-on-strong" })
        #expect(!stress.holds)
        #expect(stress.says == "\"now\" in line 1 lands on the and of 2, bar 1 — move the note or the word.", "\(stress.says)")
        #expect(model.observation?.setting?.offBeat.map { [$0.line, $0.syllable] } == [[0, 2]])

        model.text = "[Verse]\ngo home now\nsing it slow\n\n[Hook]\nsoft machine\nsoft machine"
        let hook = try #require(model.readings.first { $0.rule == "lyricist.title-in-the-hook" })
        #expect(hook.holds, "\(hook.says)")
        #expect(model.stanzaLabels == [0: "Verse", 3: "Hook"])
        #expect(model.schemeLetters.count == model.lyric.lines.count)
    }

    @Test("the adapter offers the song's melodies and section names, and the rail hears a stress off the beat")
    func adapter() throws {
        let directory = WiringFixture.temporaryDirectory("words-adapter")
        defer { WiringFixture.remove(directory) }
        var song = FormFixture.build(tempo: 100).song
        song.title = "Soft Machine"
        song.sections = [Section(name: "Verse", stitch: [], lengthInBars: 4), Section(name: "Hook", stitch: [], lengthInBars: 2),
                         Section(name: "Verse", stitch: [], lengthInBars: 4)]
        let tune = PartVersion(partID: PartID(), kind: .melody(Melody(notes: [0, 1, 1.5, 2].map {
            NoteEvent(pitch: Pitch(midi: 64), start: $0, duration: 0.5)
        })), author: .user, operation: Operation.written, note: "Lead")
        try song.append(tune)
        let app = BandFixture.app(in: directory, song: song)
        let adapter = LyricsAdapter(app: app)
        #expect(adapter.sectionNames == ["Verse", "Hook"])
        #expect(adapter.beatsPerBar == 4)
        #expect(adapter.melodies.contains { $0.version == tune.id && $0.melody.notes.count == 4 })
        #expect(adapter.melody(tune.id)?.part == tune.partID)
        #expect(adapter.melody(song.versions.first { $0.type != .melody }!.id) == nil, "only melodies")

        let words = Lyricist.lyric(from: "go home now\nsing it slow").aligned(to: adapter.melody(tune.id)!.melody, version: tune.id)
        let before = app.log.count
        #expect(adapter.commit(PartVersion(partID: PartID(), kind: .lyric(words), author: .user, operation: Operation.written, note: "")))
        #expect(app.log.dropFirst(before).contains { $0.source == .persona("Lyricist") && $0.text.contains("lands on the and of 2") },
                "\(app.log.dropFirst(before).map(\.text))")
    }

    @Test("the Lyrics surface drawn at the bench's minimum and its default: labelled, set to a tune, one stress off the beat",
          .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] != nil, "set MRROBOTO_RENDER to a directory to write the renders"))
    func render() throws {
        FontRegistration.registerBundledFonts()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MRROBOTO_RENDER"] ?? NSTemporaryDirectory())
        let host = WordsHost()
        host.sections = ["Intro", "Verse", "Hook", "Bridge"]
        let tune = host.addMelody([0, 0.5, 1, 2, 2.5, 3, 4, 4.5, 5, 6, 6.5, 7, 8, 9, 10, 11, 12, 12.5, 13, 14], title: "Lead")
        let model = model(host)
        model.text = "[Verse]\nI put the coffee on at six\nI watched it make itself\n\n[Hook]\nsoft machine\nsoft machine, humming"
        model.setMelody(tune.id)
        for (size, name) in [(SurfaceGeometry.minimum, "lyrics-minimum"), (SurfaceGeometry.standard, "lyrics-standard")] {
            let renderer = ImageRenderer(content: LyricsSurfaceView(model: model).frame(width: size.width, height: size.height))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
