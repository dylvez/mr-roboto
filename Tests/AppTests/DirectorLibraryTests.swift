import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// M3 Gate C, without the network: read_library says what the library holds with keys and tempos,
// adopt brings an item in, merge plans by the Sampler's rules and — with a section named — renders
// and stitches; the Sampler's refusals are the tool's failures. Then the scripted proof.

@MainActor
private enum LibraryToolFixture {
    struct Rig {
        var app: AppState
        var toolbox: DirectorToolbox
        var record: Record
        var sample: SampleID
        var bass: VersionID
        var directory: URL
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A library with a record and a saved dusty chop in G major at 100 from it, and an open song in
    /// D major at 92 holding a groove and a bass line in E minor.
    static func rig() throws -> Rig {
        let built = try MergeFixture.build("tools")
        let app = built.app
        let saved = try #require(app.saveToSamples(built.sample.id, name: "Horns bar"))
        // The bench reaches the library by id, as the live one does.
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4),
                                          libraryLoader: DirectorWorkbench.libraryLoader { id in
                                              try await MainActor.run { try app.libraryAudio(id: id) }
                                          })
        let toolbox = DirectorTools.toolbox(workbench: workbench, workspace: AppStateWorkspace(app))
        return Rig(app: app, toolbox: toolbox, record: built.record, sample: saved, bass: built.bass.id, directory: built.directory)
    }

    static func json(_ result: ClaudeToolResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

@Suite("Director: read_library, adopt and merge", .serialized) @MainActor
struct DirectorLibraryToolTests {

    @Test("read_library lists everything with its key and tempo; read_song says each version's key")
    func reads() async throws {
        let rig = try LibraryToolFixture.rig()
        defer { rig.clean() }
        let result = await rig.toolbox.run(ClaudeToolUse(id: "l", name: "read_library", input: .object([])))
        #expect(!result.isError, "\(result.content)")
        let out = LibraryToolFixture.json(result)
        let records = out["records"] as? [[String: Any]] ?? []
        #expect(records.count == 1 && records[0]["key"] as? String == "D major" && records[0]["in_song"] as? Bool == false)
        let samples = out["samples"] as? [[String: Any]] ?? []
        #expect(samples.count == 1)
        #expect(samples[0]["key"] as? String == "G major" && samples[0]["tempo"] as? Double == 100 && samples[0]["dusty"] as? Bool == true)
        #expect(samples[0]["source"] as? String == "Vessel – Horns")
        #expect((out["songs"] as? [[String: Any]])?.first?["is_open"] as? Bool == true)

        let song = await rig.toolbox.run(ClaudeToolUse(id: "s", name: "read_song", input: .object([])))
        let versions = LibraryToolFixture.json(song)["versions"] as? [[String: Any]] ?? []
        let bass = try #require(versions.first { $0["id"] as? String == rig.bass.description })
        #expect(bass["key"] as? String == "E minor")
        let chop = try #require(versions.first { $0["type"] as? String == "sample" })
        #expect(chop["key"] as? String == "G major" && chop["tempo"] as? Double == 100)
    }

    @Test("chop_bar takes a record from the crate by its id, no file path asked, and each slice says its step")
    func chopsByID() async throws {
        let rig = try LibraryToolFixture.rig()
        defer { rig.clean() }
        let result = await rig.toolbox.run(ClaudeToolUse(id: "c", name: "chop_bar", input: .object([
            .init("audio", .string(rig.record.id.description)),
            .init("start_seconds", .double(0)), .init("end_seconds", .double(2)),
            .init("method", .string("divisions")), .init("division", .int(4)),
        ])))
        #expect(!result.isError, "\(result.content)")
        let out = LibraryToolFixture.json(result)
        #expect((out["audio"] as? String)?.hasPrefix("audio-") == true, "the excerpt is a handle of its own, as a cut from any record is")
        let slices = out["slices"] as? [[String: Any]] ?? []
        #expect(slices.map { $0["step"] as? Int } == [0, 4, 8, 12], "four even slices of the span land on its quarters: \(slices)")
        // An id the library does not hold is still unknown.
        let nobody = await rig.toolbox.run(ClaudeToolUse(id: "n", name: "chop_bar", input: .object([
            .init("audio", .string(UUID().uuidString)), .init("start_seconds", .double(0)), .init("end_seconds", .double(1)),
        ])))
        #expect(nobody.isError)
    }

    @Test("adopt brings a sample in as a chop, and refuses what the library does not hold")
    func adopts() async throws {
        let rig = try LibraryToolFixture.rig()
        defer { rig.clean() }
        let before = rig.app.song!.versions.count
        let result = await rig.toolbox.run(ClaudeToolUse(id: "a", name: "adopt", input: .object([
            .init("kind", .string("sample")), .init("id", .string(rig.sample.description)),
        ])))
        #expect(!result.isError, "\(result.content)")
        let out = LibraryToolFixture.json(result)
        #expect(out["type"] as? String == "sample" && out["key"] as? String == "G major")
        #expect(rig.app.song?.versions.count == before + 1)
        #expect(rig.app.song?.versions.last?.operation == Operation.adopted)

        let missing = await rig.toolbox.run(ClaudeToolUse(id: "m", name: "adopt", input: .object([
            .init("kind", .string("idea")), .init("id", .string(UUID().uuidString)),
        ])))
        #expect(missing.isError && missing.content.contains("holds no idea"))
        let wrong = await rig.toolbox.run(ClaudeToolUse(id: "w", name: "adopt", input: .object([
            .init("kind", .string("song")), .init("id", .string(UUID().uuidString)),
        ])))
        #expect(wrong.isError)
        // A number where the pair of bars goes is read as one bar, not refused: the band wrote the
        // idea's bar count there and the whole call used to fail on its arguments.
        let numbered = await rig.toolbox.run(ClaudeToolUse(id: "n", name: "adopt", input: .object([
            .init("kind", .string("idea")), .init("id", .string(UUID().uuidString)), .init("bars", .int(3)),
        ])))
        #expect(numbered.isError && numbered.content.contains("holds no idea"), "\(numbered.content)")
        let paired = try JSONDecoder().decode(AdoptTool.Input.self, from: Data(#"{"kind":"record","id":"x","stem":"drums","bars":[9,10]}"#.utf8))
        #expect(paired.bars == [9, 10])
        let single = try JSONDecoder().decode(AdoptTool.Input.self, from: Data(#"{"kind":"record","id":"x","bars":4}"#.utf8))
        #expect(single.bars == [4, 4])
    }

    @Test("merge plans only without a section, renders and stitches with one, and carries the Sampler's flags")
    func merges() async throws {
        let rig = try LibraryToolFixture.rig()
        defer { rig.clean() }
        let chop = try #require(rig.app.song?.versions.first { $0.type == .sample }).id
        let planOnly = await rig.toolbox.run(ClaudeToolUse(id: "p", name: "merge", input: .object([
            .init("a", .string(chop.description)), .init("b", .string(rig.bass.description)),
            .init("key", .string("")), .init("tempo", .double(0)), .init("section", .string("")), .init("bars", .int(0)),
        ])))
        #expect(!planOnly.isError, "\(planOnly.content)")
        var out = LibraryToolFixture.json(planOnly)
        #expect(out["stitched"] as? Bool == false)
        #expect(out["target_key"] as? String == "D major" && out["target_tempo"] as? Double == 92)
        let a = out["a"] as? [String: Any] ?? [:]
        #expect(a["semitones"] as? Int == -5 && (a["sentence"] as? String)?.contains("stretched ×1.09") == true)
        #expect((out["b"] as? [String: Any])?["sentence"] as? String == "Bass line down 5 semitones to B minor.")
        let flags = out["flags"] as? [String] ?? []
        #expect(flags.contains { $0.contains("timbre") }, "\(flags)")
        #expect(flags.contains { $0.contains("Uncleared: Vessel – Horns") }, "\(flags)")
        #expect(rig.app.song?.sections.isEmpty == true && rig.app.song?.versions.filter { $0.operation == Operation.merge }.isEmpty == true)

        let stitched = await rig.toolbox.run(ClaudeToolUse(id: "s", name: "merge", input: .object([
            .init("a", .string(chop.description)), .init("b", .string(rig.bass.description)),
            .init("key", .string("")), .init("tempo", .double(0)), .init("section", .string("Verse")), .init("bars", .int(4)),
        ])))
        #expect(!stitched.isError, "\(stitched.content)")
        out = LibraryToolFixture.json(stitched)
        #expect(out["stitched"] as? Bool == true && out["section_name"] as? String == "Verse" && out["bars"] as? Int == 4)
        let song = try #require(rig.app.song)
        #expect(song.sections.count == 1)
        let moved = song.versions(playing: song.sections[0])
        #expect(moved.count == 2 && moved.allSatisfy { $0.operation == Operation.merge })
        #expect(rig.app.playback.isArranged && rig.app.playback.segments[0].chop != nil && rig.app.playback.segments[0].bassline != nil)

        // Into the sample's own key: nothing rendered, the originals stitched as they are.
        let still = await rig.toolbox.run(ClaudeToolUse(id: "g", name: "merge", input: .object([
            .init("a", .string(chop.description)), .init("b", .string(rig.bass.description)),
            .init("key", .string("G major")), .init("tempo", .double(100)), .init("section", .string("Hook")), .init("bars", .int(2)),
        ])))
        #expect(!still.isError, "\(still.content)")
        #expect((LibraryToolFixture.json(still)["versions"] as? [String]) == [chop.description, rig.bass.description])
        #expect(rig.app.song?.sections.count == 2)

        // Two records' drums in one section: the Sampler refuses, and its reason and counter are
        // the failure. (A tritone is the furthest the rules ever move a sample, so the past-seven
        // refusal is only reachable from the surface's own stepper.)
        let form = FormFixture.build()
        let second = try #require(form.song.latestVersion(of: form.groove))
        let secondGroove = PartVersion(partID: PartID(), kind: second.kind, author: .user, operation: Operation.written, note: "Second break")
        #expect(rig.app.record(secondGroove))
        let firstGroove = try #require(rig.app.song?.versions.first { $0.type == .groove }).id
        let far = await rig.toolbox.run(ClaudeToolUse(id: "f", name: "merge", input: .object([
            .init("a", .string(firstGroove.description)), .init("b", .string(secondGroove.id.description)),
            .init("key", .string("")), .init("tempo", .double(0)), .init("section", .string("Bridge")), .init("bars", .int(4)),
        ])))
        #expect(far.isError, "\(far.content)")
        #expect(far.content.contains("The Sampler:") && far.content.contains("one record's drums"))
        #expect(rig.app.song?.sections.count == 2)

        // The wrong kind, and a version the song does not hold.
        let groove = try #require(rig.app.song?.versions.first { $0.type == .groove }).id
        let twoDrums = await rig.toolbox.run(ClaudeToolUse(id: "d", name: "merge", input: .object([
            .init("a", .string(chop.description)), .init("b", .string(groove.description)),
            .init("key", .string("G major")), .init("tempo", .double(100)), .init("section", .string("")), .init("bars", .int(0)),
        ])))
        #expect(!twoDrums.isError, "a chop and a groove plan fine when only one carries drums: \(twoDrums.content)")
        let ghost = await rig.toolbox.run(ClaudeToolUse(id: "x", name: "merge", input: .object([
            .init("a", .string(chop.description)), .init("b", .string(UUID().uuidString)),
            .init("key", .string("")), .init("tempo", .double(0)), .init("section", .string("")), .init("bars", .int(0)),
        ])))
        #expect(ghost.isError)
    }
}

// MARK: - The proof

@Suite("Director: the M3 proof", .serialized)
struct DirectorMergeProofTests {

    @Test("Bring these two together as a verse")
    func theMergeProof() async throws {
        let workspace = SendableBox<AppStateWorkspace?>(nil)
        let sampleID = SendableBox<String>("")

        var replies: [@Sendable () async -> String] = []
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t1", "read_library", "{}")))
        replies.append({
            DirectorTurnFixture.call("t2", "adopt", #"{"kind":"sample","id":"\#(sampleID.value)"}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorTurnFixture.call("t3", "read_song", "{}")))
        replies.append({
            let chops = await DirectorTurnFixture.versions(workspace.value, ofType: .sample)
            let lines = await DirectorTurnFixture.versions(workspace.value, ofType: .bassline)
            return DirectorTurnFixture.call(
                "t4", "merge",
                #"{"a":"\#(chops[0])","b":"\#(lines[0])","key":"","tempo":0,"section":"Verse","bars":4}"#)
        })
        replies.append({
            let chops = await DirectorTurnFixture.versions(workspace.value, ofType: .sample)
            let lines = await DirectorTurnFixture.versions(workspace.value, ofType: .bassline)
            return DirectorTurnFixture.call(
                "t5", "open_surface",
                #"{"surface":"Merge","title":"Horns under the line","bound":["\#(chops[0])","\#(lines[0])"],"reference":null,"finding":null,"because":"So you hear each and both, moved as the plan says.","levers":[]}"#)
        })
        replies.append(DirectorLateTransport.fixed(DirectorSSE.reply(
            "Stitched as a verse: the Horns bar down 5 semitones to D major, stretched ×1.09 from 100 to 92, "
            + "and the bass line down 5 semitones to B minor. The Sampler flags the horns past four — the "
            + "timbre will tell — and the source, Vessel – Horns, is uncleared. The Merge surface is open on the two.")))

        let rig = try await MainActor.run { try DirectorTurnFixture.rig(replies) }
        defer { rig.clean() }
        workspace.value = rig.workspace

        // The song in D major at 92 with a bass line in E minor; the library holds a record and a
        // dusty chop of it saved as a sample in G major at 100.
        try await MainActor.run {
            let app = rig.app
            var song = Song(title: "Arrival", artist: "Vessel", key: Key(parsing: "D major"), tempo: 92)
            let line = Bassline(notes: [NoteEvent(pitch: Pitch(midi: 40), start: 0, duration: 1),
                                        NoteEvent(pitch: Pitch(midi: 43), start: 2, duration: 1)], sound: "finger", key: Key(parsing: "E minor"))
            try song.append(PartVersion(partID: PartID(), kind: .bassline(line), author: .persona("Bassist"),
                                        operation: Operation.written, note: "Bass line"))
            app.open(song)
            let store = try #require(app.store)
            let record = try LibraryFixture.record("Horns", in: store.directoryURL, store: store, frequency: 98)
            let sample = LibrarySample(name: "Horns bar",
                                       sample: Sample(media: record.media, slices: [SliceMarker(position: 0)], detectedTempo: 100,
                                                      sourceRecord: record.id, degradation: [Dust.pass(.sp1200, mix: 0.5)],
                                                      key: Key(parsing: "G major")),
                                       tags: ["horns"])
            #expect(app.writeLibrary(Library(records: [record], samples: [sample])))
            sampleID.value = sample.id.description
            app.save()
        }

        let turn = await rig.director.direct("Bring these two together as a verse")

        #expect(turn.ending == .answered)
        #expect(turn.calls == ["read_library", "adopt", "read_song", "merge", "open_surface"])
        try await MainActor.run {
            let song = try #require(rig.app.song)
            #expect(song.sections.map(\.name) == ["Verse"])
            let moved = song.versions(playing: song.sections[0])
            #expect(moved.count == 2)
            #expect(moved.allSatisfy { $0.operation == Operation.merge })
            #expect(moved.first { $0.type == .sample }?.note?.contains("down 5 semitones to D major") == true)
            #expect(moved.first { $0.type == .bassline }?.note == "Bass line down 5 semitones to B minor.")
            #expect(rig.app.playback.isArranged && rig.app.playback.isPlayable)
            #expect(rig.app.bench.items.contains { $0.kind == .merge })
        }
        // The tool told the model the plan in sentences, with the flags.
        let mergeResult = try await rig.transport.request(4).bodyJSON().jsonText
        #expect(mergeResult.contains("down 5 semitones to B minor"))
        #expect(mergeResult.contains("timbre"))
        #expect(turn.opened.count == 1 && turn.opened.first?.surface == .merge)
        #expect(turn.say.contains("B minor"))
    }
}
