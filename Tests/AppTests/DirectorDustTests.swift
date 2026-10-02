import CryptoKit
import Foundation
import Instrument
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// The band making a part dusty: `degrade_part`, what it writes, what the chain check does to it, and
// what adding it did not do to the tool list's cached prefix.
//
// Everything runs over `DustFixture` — a real drums stem on disk, a real dry chop of bar 2, a real
// groove — through `AppStateWorkspace`, so a version the tool writes lands in the same song graph
// the Sound surface writes into. No network anywhere.

// MARK: - What the tool writes

@Suite("DirectorDust: degrade_part writes dust onto the part", .serialized)
@MainActor
struct DirectorDustToolTests {

    private func tool(_ built: DustFixture.Built, acting: String = CreatePartVersionTool.director) -> DegradePartTool {
        DegradePartTool(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                        workspace: AppStateWorkspace(built.app), acting: acting)
    }

    private func input(_ version: PartVersion, _ preset: String, _ mix: Double) -> DegradePartTool.Input {
        DegradePartTool.Input(version: version.id.description, preset: preset, mix: mix)
    }

    @Test("A degrade version of the same part, the dry chop as its parent, the named preset at the mix")
    func writesADegradeVersion() async throws {
        let built = try DustFixture.build("director-dust-write")
        defer { WiringFixture.remove(built.directory) }

        let output = try await tool(built).run(input(built.dry, "sp1200", 0.6))

        #expect(output.recorded)
        #expect(output.operation == Operation.degrade)
        #expect(output.parent == built.dry.id.description)
        #expect(output.dry == built.dry.id.description, "the dry version is one parent back")
        #expect(output.chain == "sp1200 at 60%")
        #expect(output.author == "Director")

        let id = try #require(VersionID(uuidString: output.version))
        let dusty = try #require(built.app.version(id))
        #expect(dusty.partID == built.dry.partID, "a new version of the chop, not a new part")
        #expect(dusty.parents == [built.dry.id])
        #expect(dusty.operation == Operation.degrade)
        #expect(dusty.author == .persona("Director"))
        #expect(dusty.type == .sample)

        // The chain is the named preset exactly, at the mix, and nothing else moved.
        let pass = try #require(dusty.kind.degradation.first)
        #expect(dusty.kind.degradation.count == 1)
        #expect(pass == Dust.pass(.sp1200, mix: 0.6))
        #expect(pass.preset == "sp1200")
        var expected = DegradeSettings(preset: .sp1200)
        expected.mix = 0.6
        #expect(DegradeSettings(pass) == expected)
        #expect(dusty.kind.dry == built.dry.kind, "the media and the markers are the dry chop's")

        // The dry chop is untouched and still plays clean.
        #expect(built.app.version(built.dry.id)?.kind.degradation.isEmpty == true)

        // The same construction the Sound surface's commit goes through: same payload, same note.
        let byHand = try #require(Dust.version(dirtying: built.dry, through: [pass], by: .user))
        #expect(byHand.kind == dusty.kind)
        #expect(byHand.note == dusty.note)
        #expect(dusty.note == "Bar 2 of Arrival — sp1200")
        #expect(PartLabel.title(of: dusty) == "Bar 2 of Arrival", "the ledger still names the chop")
    }

    @Test("The seed is the preset's, never the model's, and survives the codec and a migration")
    func theSeedIsThePresets() async throws {
        let built = try DustFixture.build("director-dust-seed")
        defer { WiringFixture.remove(built.directory) }
        let seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        #expect(DegradeSettings(preset: .mpc60).seed == seed)

        // The schema has no seed to set, and a seed the model sends anyway goes nowhere.
        let schema = tool(built).schema
        guard case .object(let properties)? = schema["properties"] else {
            Issue.record("degrade_part has no properties")
            return
        }
        #expect(properties.keys.sorted() == ["mix", "preset", "version"])
        let result = try await tool(built).erased().invoke(arguments: .object([
            .init("version", .string(built.dry.id.description)),
            .init("preset", .string("mpc60")),
            .init("mix", .double(0.5)),
            .init("seed", .int(7)),
        ]))
        let id = try #require(result["version"]?.stringValue.flatMap(VersionID.init(uuidString:)))
        let dusty = try #require(built.app.version(id))
        #expect(dusty.kind.degradation.map(\.seed) == [seed])

        // Through the codec as a string, and through `JSONValue` the way every migration goes.
        let song = try #require(built.app.song)
        let data = try SongGraphCodec.encodeSong(song)
        #expect(String(decoding: data, as: UTF8.self).contains("\"seed\" : \"\(seed)\""))
        let decoded = try SongGraphCodec.decodeSong(from: data)
        #expect(decoded.version(id)?.kind.degradation.map(\.seed) == [seed])
        let tree = try SongGraphCodec.decode(JSONValue.self, from: data)
        let migrated = try SongGraphCodec.decode(Song.self, from: try SongGraphCodec.encode(tree))
        #expect(migrated.version(id)?.kind == dusty.kind)
    }

    @Test("A groove carries a chain the same way, and every machine in the vocabulary is one preset")
    func grooveAndVocabulary() async throws {
        let built = try DustFixture.build("director-dust-groove")
        defer { WiringFixture.remove(built.directory) }

        let output = try await tool(built).run(input(built.groove, "cassette", 0.4))
        let id = try #require(VersionID(uuidString: output.version))
        let dusty = try #require(built.app.version(id))
        #expect(dusty.type == .groove)
        #expect(dusty.parents == [built.groove.id])
        #expect(dusty.kind.degradation == [Dust.pass(.cassette, mix: 0.4)])
        #expect(output.findings.isEmpty, "a groove has no source rolloff to put a corner above")

        // The vocabulary is the five machines, as the model says them.
        #expect(DegradePartTool.presets.map(\.rawValue) == ["sp1200", "mpc60", "cassette", "vinyl", "radio"])
        let spelled = try await tool(built).run(input(built.groove, "SP-1200", 1))
        #expect(spelled.chain == "sp1200 at 100%")
    }

    @Test("A persona-scoped band signs the dust with its own name")
    func personaSigns() async throws {
        let built = try DustFixture.build("director-dust-persona")
        defer { WiringFixture.remove(built.directory) }
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                            workspace: AppStateWorkspace(built.app), persona: "Sampler")
        let result = await toolbox.run(ClaudeToolUse(id: "d", name: "degrade_part", input: .object([
            .init("version", .string(built.groove.id.description)),
            .init("preset", .string("vinyl")),
            .init("mix", .double(0.5)),
        ])))
        #expect(!result.isError, "\(result.content)")
        let value = try DirectorJSON.parse(Data(result.content.utf8))
        #expect(value["author"]?.stringValue == "Sampler")
    }

    @Test("What it will not do comes back as a reason the model can act on")
    func refusals() async throws {
        let built = try DustFixture.build("director-dust-refusals")
        defer { WiringFixture.remove(built.directory) }

        await #expect(throws: DirectorToolFailure.self) {
            _ = try await tool(built).run(input(built.stem, "sp1200", 0.6))
        }
        do {
            _ = try await tool(built).run(input(built.stem, "sp1200", 0.6))
        } catch let failure as DirectorToolFailure {
            #expect(failure.reason.contains("carries no chain"))
        }
        do {
            _ = try await tool(built).run(input(built.dry, "tape", 0.6))
            Issue.record("an unknown machine was accepted")
        } catch let failure as DirectorToolFailure {
            #expect(failure.suggestion?.contains("sp1200, mpc60, cassette, vinyl, radio") == true)
        }
        for mix in [0.0, 60, -1] {
            do {
                _ = try await tool(built).run(input(built.dry, "sp1200", mix))
                Issue.record("a mix of \(mix) was accepted")
            } catch let failure as DirectorToolFailure {
                #expect(failure.suggestion?.contains("0.6 is \"at 60%\"") == true)
            }
        }
        // None of that wrote anything.
        #expect(built.app.song?.versions.filter { $0.operation == Operation.degrade }.isEmpty == true)
    }
}

// MARK: - The critics

@Suite("DirectorDust: the chain check applies to what the band writes", .serialized)
@MainActor
struct DirectorDustCriticTests {

    private func toolbox(_ built: DustFixture.Built) -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                              workspace: AppStateWorkspace(built.app))
    }

    private func call(_ version: PartVersion, _ preset: String, _ mix: Double) -> ClaudeToolUse {
        ClaudeToolUse(id: "d", name: "degrade_part", input: .object([
            .init("version", .string(version.id.description)),
            .init("preset", .string(preset)),
            .init("mix", .double(mix)),
        ]))
    }

    @Test("A second quantiser over a dusty chop is refused, and the reason reaches the tool result and the rail")
    func stackingIsRefusedWithItsReason() async throws {
        let built = try DustFixture.build("director-dust-stack")
        defer { WiringFixture.remove(built.directory) }
        let toolbox = toolbox(built)

        let first = await toolbox.run(call(built.dry, "sp1200", 0.6))
        #expect(!first.isError, "\(first.content)")
        let dustyID = try #require(DirectorJSON.parse(Data(first.content.utf8))["version"]?.stringValue)
        let dusty = try #require(VersionID(uuidString: dustyID).flatMap(built.app.version))
        let before = built.app.song?.versions.count

        // The stack: the critic's finding is the failure, and nothing is written.
        let stacked = await toolbox.run(call(dusty, "mpc60", 1))
        #expect(stacked.isError)
        #expect(built.app.song?.versions.count == before, "a refused stack wrote a version")

        // The reason, not the name: the finding's own sentence, then what it measured…
        #expect(stacked.content.hasPrefix("Chain check: The source is already on a 12-bit lattice from SP-1200"))
        #expect(stacked.content.contains("Second quantiser"))
        #expect(stacked.content.contains("Nothing was written."))
        // …and the critic's two fixes, said as this tool's arguments.
        #expect(stacked.content.contains("the same call with preset cassette"))
        #expect(stacked.content.contains("name its dry version \(built.dry.id.description)"))

        // What the user reads is the reason: the rail keeps the first sentence, which is the why.
        let rail = DirectorSession.refusals([.init(tool: "degrade_part", reason: stacked.content)])
        #expect(rail.hasPrefix("degrade_part — Chain check: The source is already on a 12-bit lattice"))
        #expect(rail.contains("adds quantisation error"))
        #expect(!rail.contains("Nothing was written"), "the suggestion to the model stays with the model")

        // The critic's first fix is a real call: tape over the sampler, no second lattice.
        let tape = await toolbox.run(call(dusty, "cassette", 1))
        #expect(!tape.isError, "\(tape.content)")
        let value = try DirectorJSON.parse(Data(tape.content.utf8))
        #expect(value["chain"]?.stringValue == "cassette at 100% over sp1200 at 60%")
        #expect(value["parent"]?.stringValue == dusty.id.description)
        #expect(value["dry"]?.stringValue == built.dry.id.description)
        let tapeID = try #require(value["version"]?.stringValue.flatMap(VersionID.init(uuidString:)))
        #expect(built.app.version(tapeID)?.kind.degradation
                == [Dust.pass(.sp1200, mix: 0.6), Dust.pass(.cassette, mix: 1)])
    }

    @Test("A groove playing a chop's slices is measured by its chop: a corner above the chop's rolloff is flagged")
    func grooveOnAChopIsMeasured() async throws {
        let built = try DustFixture.build("director-dust-chop-groove")
        defer { WiringFixture.remove(built.directory) }
        #expect(built.app.setChop(built.dry.partID, for: built.groove.partID))

        let result = await toolbox(built).run(call(built.groove, "sp1200", 0.6))
        #expect(!result.isError, "\(result.content)")
        let value = try DirectorJSON.parse(Data(result.content.utf8))
        let findings = value["findings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(findings.first?.hasPrefix("Chain check: There is nothing above the corner left to remove") == true,
                "\(findings)")
    }

    @Test("A corner above the source's own rolloff is written, flagged to the model, and said on the rail")
    func cornerAboveRolloffIsFlagged() async throws {
        let built = try DustFixture.build("director-dust-corner")
        defer { WiringFixture.remove(built.directory) }

        // The fixture's drums are a 70 Hz kick and a 3 kHz tone: nothing near SP-1200's 12 kHz corner.
        let span = try DustFixture.dryRegion(built)
        let rolloff = SourceMeasurement.rolloff(ChopAudio.mono(span.planar), sampleRate: span.sampleRate)
        try #require(rolloff < DegradeSettings(preset: .sp1200).highCut, "the premise: a dark source")

        let result = await toolbox(built).run(call(built.dry, "sp1200", 0.6))
        #expect(!result.isError, "a note is flagged, never refused: \(result.content)")
        let value = try DirectorJSON.parse(Data(result.content.utf8))
        #expect(value["recorded"]?.boolValue == true)
        let findings = value["findings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(findings.count == 1)
        #expect(findings.first?.hasPrefix("Chain check: There is nothing above the corner left to remove") == true)
        #expect(findings.first?.contains("the same call with mix 0.33") == true)

        // The user reads it on the rail with its reason, not just the check's name.
        let line = built.app.log.last { $0.text.hasPrefix("Chain check:") }
        #expect(line != nil, "the finding never reached the rail")
        #expect(line?.detail?.contains("There is nothing above the corner left to remove") == true)
    }
}

// MARK: - The tool list

@Suite("DirectorDust: degrade_part is appended and costs the prefix nothing")
@MainActor
struct DirectorDustToolboxTests {

    private func toolbox(stage: Bool) -> DirectorToolbox {
        let app = FrameFixture.state()
        return DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                     workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song()),
                                     audition: DirectorSilentAudition(),
                                     stage: stage ? AppStateStage(app) : nil,
                                     pad: stage ? DirectorStagePad() : nil)
    }

    /// SHA-256 of every tool's definition as it goes on the wire (name, description, schema,
    /// strictness — everything but the cache marker), taken from the toolbox **before**
    /// `degrade_part` existed. If one of these moves, a schema that was already in the field changed.
    static let before: [(String, String)] = [
        ("read_song", "10626fba3f9ec72db432d4fd63add5b690d8d875cbea72ef036c902d529c62d5"),
        ("import_record", "04e0dee66856bf1f281c855e7541d79dd7f8047268cdea2c6888f690a2652046"),
        ("analyse_record", "a42fc108df503519941fc9514b8f59bbd8a36d701dcdd7afe925a82ee7beb9d1"),
        ("list_bars", "acb70e206f27579643cac3e264facb0401d1846f7e89a2f734e9180bd950f5bb"),
        ("separate_stems", "2a241e427e5f3af03e8b065ce721b20d44d3c09f1ece42be293016bf0276951b"),
        ("chop_bar", "28552c37cc1da03731c85b73f7624068b88ecaef43badf8190084be45816ce1f"),
        ("classify_slices", "ff7f1a8732c54579b55225da582dc6a7e8b1e5eac0fef4ca4ecbc0aad45c7f85"),
        ("list_feels", "e73c6a6d1a9879ddc5ae4b145d04d9ef2a6771f29c4c891f2bb1e203a3a8b505"),  // limit up to 60: the library has 51
        ("describe_feel", "c51e563c303367f5e62a7b88c13a9f8f0aae2bb4c7f6f5f37fca2485fae7e889"),
        ("regroove_chop", "bc63be6e8be7397119befd24331d9017911413bfbf24d611714963931fb2846d"),
        ("set_swing", "050fe055aebc9a46a0073042d4cd8bef2a077a7ff72c08ece51504e7a2331e4f"),
        ("set_velocity", "886ae8216deef152f1773180aa0db83d6f2fdfae811715267e2db41998abc6d1"),
        ("audition", "9193a56ec875043aeaa9686fe15333b25b2e4e10301ac740822e91e0c0fb0dac"),
        ("create_part_version", "7c6cc618b2eea4d7eeb1bba7503086bc9ea84210ac3698116bdcdee71e42d67c"),
        // Both of these enumerate `SurfaceKind.allCases` in their schema, so they changed bytes
        // exactly once, on 2026-09-18, when M2 added Chords and the Piano roll to the catalog —
        // the cached prefix moved once, as it did for degrade_part's prompt. A change here that
        // is not a new surface is the accident this test exists to catch.
        // (And again the same day, for the `lag` lever on a Compare of bass lines; and once more
        // for Gate C's Structure surface; once each for M3's Album and Merge surfaces; and once
        // for M4's Cast surface and again for its Lyrics surface.)
        // M5 (Booth, Takes) and M6 (Mixer, Master) joined `SurfaceKind`, so the two schemas that enumerate it changed bytes again.
        // And once on 2026-09-29, on purpose: its sentence still said the bench holds three and
        // retires the oldest, which stopped being true when the bench became one of each kind.
        ("open_surface", "240f1ecab4bc1a1801fe3fcb6129f6f3bd443f8ca498662e068709aa7e1c945d"),
        ("propose", "73b187c5950d5b6591791c0f66b0b45e6343337a630be23e6879859b8ee7c44f"),
    ]

    static func digest(_ definition: ClaudeToolDefinition) throws -> String {
        var bare = definition
        bare.cacheControl = nil
        return SHA256.hash(data: try ClaudeCoding.encode(bare)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Every schema that existed before is byte-identical; degrade_part is the fifteenth")
    func existingSchemasAreByteIdentical() throws {
        let full = toolbox(stage: true)
        #expect(full.names == DirectorTools.names + DirectorTools.stageNames)
        #expect(DirectorTools.names.count == 51)
        #expect(DirectorTools.names[14] == "degrade_part")
        #expect(Array(DirectorTools.names.prefix(14)) == Self.before.prefix(14).map(\.0),
                "the fourteen are in their old order, with nothing inserted among them")

        let appended: Set<String> = ["degrade_part", "set_progression", "write_bassline", "stitch_section", "arrange",
                                     "read_library", "adopt", "merge", "cast", "convene", "read_take", "read_mix", "set_mix", "master", "export", "read_album", "sequence", "release", "plan_mashup", "mashup", "start_song", "write_groove",
                                     "write_melody", "write_lyrics", "set_song", "set_instrument", "comp_takes", "open_song",
                                     "list_genres", "read_genre", "set_genre", "develop", "play_chords",
                                     "set_intensity", "compare_section", "reharmonize", "vary_tune"]
        let now = try full.tools.filter { !appended.contains($0.name) }.map { ($0.name, try Self.digest($0.definition)) }
        #expect(now.map(\.0) == Self.before.map(\.0))
        for ((name, hash), (_, old)) in zip(now, Self.before) {
            #expect(hash == old, "\(name)'s definition changed bytes: now \(hash)")
        }
        // And the frame-free list is the framed one's prefix, degrade_part included.
        let bare = toolbox(stage: false)
        #expect(Array(full.names.prefix(bare.names.count)) == bare.names)
        #expect(bare.names.last == "vary_tune")
    }

    @Test("Its schema stays inside every limit the API enforced, and spends none of the optional budget")
    func schemaInsideTheLimits() throws {
        let full = toolbox(stage: true)
        let degrade = try #require(full.tool(named: "degrade_part"))
        let schema = degrade.definition.inputSchema
        #expect(!degrade.definition.strict, "strict mode was refused at this size")
        #expect(schema["additionalProperties"]?.boolValue == false)
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(required == ["version", "preset", "mix"], "every parameter required: zero optional")
        guard case .object(let properties)? = schema["properties"] else {
            Issue.record("no properties")
            return
        }
        for member in properties.members {
            #expect(member.value["type"]?.stringValue != nil, "\(member.key): no union types")
            #expect(member.value["minimum"] == nil && member.value["maximum"] == nil,
                    "\(member.key): the API rejects bound keywords")
        }
        #expect(properties["preset"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
                == ["sp1200", "mpc60", "cassette", "vinyl", "radio"])
        #expect(properties["mix"]?["type"]?.stringValue == "number")

        // The optional budget across everything a running app sends — framed toolbox included.
        var optional = 0
        for tool in full.tools {
            guard case .object(let props)? = tool.definition.inputSchema["properties"] else { continue }
            let req = tool.definition.inputSchema["required"]?.arrayValue?.count ?? 0
            optional += props.keys.count - req
        }
        #expect(optional <= 24, "\(optional) optional parameters; the API's limit is 24")
        #expect(full.definitions.last?.name == "propose", "the breakpoint is still on the last tool")
    }

    @Test("The prompt says dust is a sound job on the part, and is still all constants")
    func thePromptLearnsIt() {
        let prompt = DirectorPrompt.system
        let answer = prompt.range(of: "How you answer.")
        let dust = prompt.range(of: "Dust is a sound job, and it is yours")
        #expect(dust != nil)
        if let answer, let dust { #expect(answer.upperBound <= dust.lowerBound, "it belongs to How you answer") }
        #expect(prompt.contains("degrade_part"))
        #expect(prompt.contains("the dry version one parent back"))
        #expect(prompt.contains("open the Sound surface on the dusty version"))
        #expect(prompt.contains("\"SP-1200 at 60%\""))
        #expect(prompt.contains("not only that it refused."))
        #expect(prompt.contains("the line is written to the key and you say so."))
        #expect(prompt.contains("and the transport plays the sections in order."))
        #expect(prompt.hasSuffix("the ledger and the rail if they want them."), "M3's library paragraph is now the last thing in the prefix")
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        #expect(!prompt.contains("\(year)"))
        #expect(DirectorPrompt.systemBlocks.map(\.text) == [prompt])
    }
}

@Suite("Dust: the critic names the machine") @MainActor
struct DustCriticNamingTests {
    @Test("a machine at a partial mix is still called by its name")
    func namedAtAnyMix() {
        let settings = Dust.settings(.sp1200, mix: 0.6)
        #expect(settings.matchingPreset == nil, "the exact match fails once the mix moves — which was the bug")
        #expect(settings.presetIgnoringMix == .sp1200)
        let review = Dust.review(label: "Bar 9", passes: [Dust.pass(.mpc60, mix: 1), Dust.pass(.sp1200, mix: 0.6)])
        let headlines = DegradeStackCritic().review(review).map(\.headline)
        #expect(headlines.contains { $0.hasPrefix("Second quantiser: SP-1200 over") }, "\(headlines)")
    }
}
