import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// B7 and B8, without the network: the two M2 tools write real versions, the Bassist's refusals
// come back as the tool's failure with the reason, the Compare reads and plays bass lines, and
// the prompt says whose the bass is.

@MainActor
private enum BassToolFixture {
    struct Rig {
        var app: AppState
        var workspace: AppStateWorkspace
        var toolbox: DirectorToolbox
        var groove: VersionID
        var directory: URL
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A song with a kicking groove, at `tempo`, on the kit `machine` when one is named.
    static func rig(tempo: Double = 92, machine: String? = nil) -> Rig {
        let directory = GuidanceFixture.temporaryDirectory("bass-tools")
        let app = AppState(library: Library(), song: nil, store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        var song = Song(title: "Arrival", artist: "Vessel", key: Key(tonic: NoteName(.d), mode: .aeolian), tempo: tempo)
        func line(_ voice: DrumVoice, _ pattern: String) -> GroovePattern {
            GroovePattern(voice: voice, steps: pattern.map { $0 == "x" ? .normal : .rest })
        }
        let groove = Groove(stepsPerBar: 16, bars: 2, swing: 0, patterns: [
            line(.kick, "x-----x---------x-----x---------"),
            line(.snare, "----x-------x-------x-------x---"),
            line(.closedHat, "x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-x-"),
        ])
        let grooveVersion = PartVersion(partID: PartID(), kind: .groove(groove), author: .user,
                                        operation: Operation.written, note: "Boom-bap pocket")
        try? song.append(grooveVersion)
        if let machine {
            try? song.append(PartVersion(partID: PartID(), kind: .sound(Sound(instrument: machine, preset: nil, parameters: [:])),
                                         author: .user, operation: Operation.written, note: "\(machine) kit"))
        }
        app.open(song)
        let workspace = AppStateWorkspace(app)
        let workbench = DirectorWorkbench(engines: DirectorTestEngines.make(bars: 4))
        let toolbox = DirectorTools.toolbox(workbench: workbench, workspace: workspace)
        return Rig(app: app, workspace: workspace, toolbox: toolbox, groove: grooveVersion.id, directory: directory)
    }

    static func json(_ result: ClaudeToolResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

@Suite("Director: write_bassline and set_progression", .serialized) @MainActor
struct DirectorBassToolTests {

    @Test("write_bassline writes a bass line under the groove, signed by the Bassist, with its readings")
    func writes() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        let result = await rig.toolbox.run(ClaudeToolUse(id: "b", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
            .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(7)),
        ])))
        #expect(!result.isError, "\(result.content)")
        let out = BassToolFixture.json(result)
        #expect(out["hands"] as? String == "palladino")
        #expect(out["sound"] as? String == "finger")
        #expect(out["recorded"] as? Bool == true)
        #expect((out["readings"] as? [String])?.contains { $0.contains("behind the kick") } == true)
        #expect((out["chords"] as? String)?.contains("I–IV–V–I") == true)

        let version = try #require(rig.app.song?.versions.last)
        #expect(version.type == .bassline)
        #expect(version.author == .persona("Bassist"), "every bass line is the Bassist's")
        #expect(version.parents == [rig.groove])
        #expect(version.note?.contains("Palladino") == true)
        if case .bassline(let line) = version.kind {
            #expect(!line.notes.isEmpty)
            #expect(line.sound == "finger")
        } else { Issue.record("not a bass line") }
    }

    @Test("the same seed writes the same line; another seed writes another")
    func seeds() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        func write(_ seed: Int) async -> [NoteEvent] {
            _ = await rig.toolbox.run(ClaudeToolUse(id: "b\(seed)", name: "write_bassline", input: .object([
                .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
                .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(seed)),
            ])))
            if case .bassline(let line)? = rig.app.song?.versions.last?.kind { return line.notes }
            return []
        }
        let a = await write(1), b = await write(1), c = await write(2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("seed 0 draws a new one each call and says which; passing it back writes that line again")
    func unseeded() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        func write(_ seed: Int?) async -> (seed: Int?, notes: [NoteEvent]) {
            var input: [(String, DirectorJSON)] = [
                ("groove", .string(rig.groove.description)), ("hands", .string("palladino")),
                ("lag_ms", .double(40)), ("density", .double(0.6)),
            ]
            input.append(("seed", .int(seed ?? 0)))
            let result = await rig.toolbox.run(ClaudeToolUse(id: "u\(seed ?? -1)", name: "write_bassline",
                                                             input: .object(DirectorJSONObject(input.map { .init($0.0, $0.1) }))))
            let out = BassToolFixture.json(result)
            let notes: [NoteEvent]
            if case .bassline(let line)? = rig.app.song?.versions.last?.kind { notes = line.notes } else { notes = [] }
            return ((out["seed"] as? NSNumber)?.intValue, notes)
        }
        let first = await write(nil), second = await write(nil)
        let a = try #require(first.seed), b = try #require(second.seed)
        #expect(a != b, "two lines nobody seeded are two lines")
        #expect(first.notes != second.notes)
        let again = await write(a)
        #expect(again.seed == a && again.notes == first.notes)
    }

    @Test("the Bassist's refusals are the tool's failure, with the reason and the counter")
    func refusals() async {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        let ahead = await rig.toolbox.run(ClaudeToolUse(id: "a", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
            .init("lag_ms", .double(-30)), .init("density", .double(0.5)), .init("seed", .int(1)),
        ])))
        #expect(ahead.isError)
        #expect(ahead.content.contains("bassist.direction"))
        #expect(ahead.content.contains("rated worst"))
        #expect(ahead.content.contains("Nothing was written"))
        #expect(rig.app.song?.versions.contains { $0.type == .bassline } == false)

        // The rail keeps the reason, not just the name.
        let rail = DirectorSession.refusals([.init(tool: "write_bassline", reason: ahead.content)])
        #expect(rail.contains("ahead of the kick"))
    }

    @Test("a played bass under an 808 is refused; the sub is written instead")
    func eightOhEight() async throws {
        // The TR-808's kick at its preset decay is well under 400 ms, so a long one is set by hand.
        let rig = BassToolFixture.rig(tempo: 140, machine: SynthMachine.tr808.id)
        defer { rig.clean() }
        let decay = SurfaceWiring.kickDecay(in: rig.app.song)
        try #require(decay > 0, "the song's kit says how long its kick rings")
        // Whether the 808's preset kick counts as an 808 here is the kit's own figure.
        let played = await rig.toolbox.run(ClaudeToolUse(id: "p", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
            .init("lag_ms", .double(20)), .init("density", .double(0.5)), .init("seed", .int(1)),
        ])))
        if decay >= Bassist.eightOhEightDecaySeconds {
            #expect(played.isError)
            #expect(played.content.contains("808-is-the-bass"))
        } else {
            #expect(!played.isError)
        }
        let sub = await rig.toolbox.run(ClaudeToolUse(id: "s", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("programmed")),
            .init("lag_ms", .double(0)), .init("density", .double(0.5)), .init("seed", .int(1)),
        ])))
        #expect(!sub.isError, "\(sub.content)")
        #expect(BassToolFixture.json(sub)["sound"] as? String == "sub")
    }

    @Test("a line is put on the bass that is named, a recording among them; one nobody has is refused")
    func sound() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        let spec = InstrumentVoiceSpec(id: "sfz-test-jazz-bass-\(UUID().uuidString.prefix(6).lowercased())", name: "Jazz Bass",
                                       family: "bass", engine: .sampled, summary: "Sampled, from Jazz Bass.sfz.", sampledKit: "/nonexistent")
        ImportedInstruments.register(spec)
        defer { ImportedInstruments.unregister(id: spec.id) }
        func write(_ sound: String) async -> ClaudeToolResult {
            await rig.toolbox.run(ClaudeToolUse(id: "s", name: "write_bassline", input: .object([
                .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
                .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(7)),
                .init("sound", .string(sound)),
            ])))
        }
        let own = await write("")
        #expect(BassToolFixture.json(own)["sound"] as? String == "finger", "empty is the player's own: \(own.content)")
        let upright = await write("upright")
        #expect(BassToolFixture.json(upright)["sound"] as? String == "upright")
        let recorded = await write(spec.id)
        #expect(!recorded.isError, "\(recorded.content)")
        #expect(BassToolFixture.json(recorded)["sound"] as? String == spec.id)
        #expect((BassToolFixture.json(recorded)["note"] as? String)?.contains("Jazz Bass") == true, "said by its name")
        let line = rig.app.song?.versions.last { $0.type == .bassline }
        guard case .bassline(let written)? = line?.kind else {
            Issue.record("no bass line was recorded")
            return
        }
        #expect(written.sound == spec.id)
        let nobody = await write("sfz-nobody")
        #expect(nobody.isError)
        #expect(nobody.content.contains("no bass called") && nobody.content.contains("upright"))
    }

    @Test("bad arguments are refused with a way forward")
    func badArguments() async {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        let notAGroove = await rig.toolbox.run(ClaudeToolUse(id: "n", name: "write_bassline", input: .object([
            .init("groove", .string(UUID().uuidString)), .init("hands", .string("palladino")),
            .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(1)),
        ])))
        #expect(notAGroove.isError)
        #expect(notAGroove.content.contains("not a groove version"))
        let noHands = await rig.toolbox.run(ClaudeToolUse(id: "h", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("flea")),
            .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(1)),
        ])))
        #expect(noHands.isError)
        #expect(noHands.content.contains("palladino, thundercat, programmed"))
    }

    @Test("set_progression records the chords, and write_bassline reads them")
    func progression() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        let set = await rig.toolbox.run(ClaudeToolUse(id: "c", name: "set_progression", input: .object([
            .init("chords", .string("Dm7 | G7 | Cmaj7 | Am7")), .init("key", .string("D minor")),
        ])))
        #expect(!set.isError, "\(set.content)")
        let out = BassToolFixture.json(set)
        #expect(out["bars"] as? Int == 4)
        #expect(out["chords"] as? String == "Dm7 | G7 | Cmaj7 | Am7")
        #expect((out["numerals"] as? [String])?.first == "i7")
        let stored = try #require(rig.app.song?.versions.last)
        #expect(stored.type == .progression)

        let written = await rig.toolbox.run(ClaudeToolUse(id: "b", name: "write_bassline", input: .object([
            .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
            .init("lag_ms", .double(40)), .init("density", .double(0.5)), .init("seed", .int(3)),
        ])))
        #expect(!written.isError, "\(written.content)")
        #expect((BassToolFixture.json(written)["chords"] as? String)?.hasPrefix("Dm7 G7") == true)

        let typo = await rig.toolbox.run(ClaudeToolUse(id: "t", name: "set_progression", input: .object([
            .init("chords", .string("Dm7 | Xq7")), .init("key", .string("D minor")),
        ])))
        #expect(typo.isError)
        #expect(typo.content.contains("Xq7"))
    }

    @Test("the schemas stay inside the API's limits: no optionals, no unions, plain enums")
    func schemas() throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        for name in ["set_progression", "write_bassline"] {
            let tool = try #require(rig.toolbox.tools.first { $0.name == name })
            let schema = tool.definition.inputSchema
            guard case .object(let properties)? = schema["properties"] else {
                Issue.record("\(name) has no properties object"); continue
            }
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            #expect(Set(properties.keys) == required, "\(name): every parameter is required")
            for key in properties.keys {
                #expect(properties[key]?["type"]?.stringValue != nil, "\(name).\(key) has a union type")
            }
        }
    }
}

@Suite("Director: the Compare reads and plays bass lines") @MainActor
struct DirectorBassCompareTests {

    @Test("bass candidates get the Bassist's columns, measured against the song's groove")
    func columns() async throws {
        let rig = BassToolFixture.rig()
        defer { rig.clean() }
        for seed in 1...2 {
            _ = await rig.toolbox.run(ClaudeToolUse(id: "b\(seed)", name: "write_bassline", input: .object([
                .init("groove", .string(rig.groove.description)), .init("hands", .string("palladino")),
                .init("lag_ms", .double(seed == 1 ? 40 : 60)), .init("density", .double(0.5)), .init("seed", .int(seed)),
            ])))
        }
        let song = try #require(rig.app.song)
        let lines = Guidance.basslines(in: song)
        try #require(lines.count == 2)
        let grooveVersion = try #require(rig.app.version(rig.groove))
        #expect(CompareBriefing.features(for: lines[0]) == CompareBriefing.bassFeatures)
        let readings = CompareBriefing.readings(of: lines[1], tempo: song.tempo, features: CompareBriefing.bassFeatures, in: song)
        #expect(readings.count == CompareBriefing.bassFeatures.count)
        let offset = try #require(readings.first { $0.feature == .bassKickOffsetMS })
        #expect(abs(offset.value - 60) < 1, "the second line sits 60 behind: \(offset.value)")
        #expect(offset.unit == "ms, positive = behind the kick")
        // The groove as the reference has no numbers in the bass columns.
        #expect(CompareBriefing.readings(of: grooveVersion, tempo: song.tempo, features: CompareBriefing.bassFeatures, in: song).isEmpty)

        // The frame's brief, built from the binding: reference first, the columns are the candidates'.
        let id = rig.app.openSurface(.compare, title: "Two lines", bound: [rig.groove] + lines.map(\.id))
        let item = try #require(rig.app.bench.items.first { $0.id == id })
        let brief = try #require(CompareBriefing.brief(for: item, app: rig.app))
        #expect(brief.features == CompareBriefing.bassFeatures)
        #expect(brief.candidates.count == 2)
        #expect(brief.candidates.first?.proposedBy == .bassist)
    }

    @Test("the lag lever places the line where it says, whatever was written")
    func lagLever() {
        let notes = [NoteEvent(pitch: Pitch(midi: 38), start: 0.06, duration: 0.5),
                     NoteEvent(pitch: Pitch(midi: 38), start: 1.56, duration: 0.5),
                     NoteEvent(pitch: Pitch(midi: 43), start: 3.5, duration: 0.5)]
        let line = Bassline(notes: notes, sound: "finger")
        let shifted = CompareAdapter.shifted(line, lagMS: 20, tempo: 92)
        let beat = 60.0 / 92
        // The written line sat ~39 ms late; the lever asks for 20.
        #expect(abs((shifted.notes[0].start) * beat * 1000 - 20) < 1)
        #expect(abs((shifted.notes[1].start - 1.5) * beat * 1000 - 20) < 1)
        #expect(CompareAdapter.shifted(line, lagMS: nil, tempo: 92) == line)
        #expect(CompareLever(quantity: SurfaceLever(quantity: .lag, label: "Behind", value: 40)) == .lag)
    }
}

@Suite("Director: the prompt knows whose the bass is")
struct DirectorBassPromptTests {
    @Test("the frozen prompt names write_bassline, the hands, the refusals and the units")
    func prompt() {
        let system = DirectorPrompt.system
        for phrase in ["write_bassline", "palladino, thundercat or programmed", "milliseconds behind the kick",
                       "set_progression", "the Bassist's", "tell the user its reason"] {
            #expect(system.contains(phrase), "\(phrase)")
        }
        // The dust paragraph and everything before it are untouched.
        #expect(system.contains("Dust is a sound job, and it is yours"))
    }
}
