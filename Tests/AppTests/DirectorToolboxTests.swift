import Foundation
import Testing

@testable import MrRobotoApp

/// The tool list as a cached artefact.
///
/// These are the tests that stop a careless edit costing every session in the field its cache: the
/// list has a fixed order, the schemas have fixed key order, and the whole thing is byte-stable.
@Suite("Director: the toolbox")
@MainActor
struct DirectorToolboxTests {

    private func toolbox() -> DirectorToolbox {
        DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                             workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song()),
                             audition: DirectorSilentAudition())
    }

    @Test("The list is exactly the tools the first proof needs, in the order the work happens")
    func theList() {
        #expect(toolbox().names == DirectorTools.names)
        #expect(DirectorTools.names.count == 32)
        // The first thing is reading the song: a proposal about a song nobody read is a guess.
        #expect(DirectorTools.names.first == "read_song")
        // Recording is the last step of the first proof; dust, written onto what was recorded, is
        // appended after it rather than inserted anywhere above (`DirectorDustToolboxTests`).
        #expect(DirectorTools.names[13] == "create_part_version")
        #expect(DirectorTools.names[14] == "degrade_part")
        #expect(Array(DirectorTools.names.suffix(17)) == ["set_progression", "write_bassline", "stitch_section", "arrange",
                                                           "read_library", "adopt", "merge", "cast", "convene", "read_take",
                                                           "read_mix", "set_mix", "master", "export", "read_album", "sequence", "release"],
                "M2's four, M3's three, M4's two, M5's one, M6's four and M7's three, appended in gate order")
    }

    @Test("Every tool has a name the API accepts, a sentence, and an object schema")
    func everyToolIsWellFormed() {
        for tool in toolbox().tools {
            #expect(tool.name.allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber },
                    "\(tool.name) should be snake_case")
            #expect(tool.definition.description.count > 40, "\(tool.name) needs a real sentence")
            let schema = tool.definition.inputSchema
            #expect(schema["type"]?.stringValue == "object", "\(tool.name)")
            #expect(schema["additionalProperties"]?.boolValue == false, "\(tool.name) is strict")
            #expect(schema["properties"] != nil, "\(tool.name)")
            #expect(schema["required"]?.arrayValue != nil, "\(tool.name)")
        }
    }

    /// The four rules the live API turned out to enforce, each of which this toolbox broke.
    ///
    /// This test used to assert the opposite — every property required, optionality as a nullable
    /// type, `strict: true` — which is another vendor's strict mode and is a 400 here. Not one
    /// request the app ever sent was accepted, and no scripted transport could have said so, because
    /// a scripted transport answers whatever it was given. Every clause below quotes the refusal it
    /// came from, so the next person to "tidy" one of them knows what it costs.
    @Test("The schemas obey the limits the live API actually enforces")
    func schemasAreAcceptable() {
        var optionalParameters = 0
        for tool in toolbox().tools {
            let schema = tool.definition.inputSchema
            guard case .object(let properties)? = schema["properties"] else {
                Issue.record("\(tool.name) has no properties object")
                continue
            }
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            #expect(required.isSubset(of: Set(properties.keys)),
                    "\(tool.name): required names a property that does not exist")
            optionalParameters += properties.keys.count - required.count

            for member in properties.members {
                // "For 'integer' type, properties maximum, minimum are not supported" — and the
                // same for 'number'. The bound lives in the description instead.
                #expect(member.value["minimum"] == nil,
                        "\(tool.name).\(member.key): the API rejects a minimum keyword")
                #expect(member.value["maximum"] == nil,
                        "\(tool.name).\(member.key): the API rejects a maximum keyword")
                // "Schemas contains too many parameters with union types … (limit: 16)". None is
                // the simplest way under that, and optionality is absence from `required`.
                #expect(member.value["type"]?.stringValue != nil,
                        "\(tool.name).\(member.key): a union type counts against the API's limit")
            }
            // "The compiled grammar is too large … Simplify your tool schemas or reduce the number
            // of strict tools." Sixteen tools carrying this vocabulary do not fit in one grammar.
            #expect(!tool.definition.strict, "\(tool.name): strict mode is refused at this size")
        }
        // "Schemas contains too many optional parameters (27) … (limit: 24)."
        #expect(optionalParameters <= 24,
                "\(optionalParameters) optional parameters across the toolbox; the API's limit is 24")
    }

    @Test("Every property says what it is for")
    func everyPropertyIsDescribed() {
        for tool in toolbox().tools {
            guard case .object(let properties)? = tool.definition.inputSchema["properties"] else { continue }
            for member in properties.members {
                let description = member.value["description"]?.stringValue ?? ""
                #expect(description.count > 10, "\(tool.name).\(member.key) needs a description")
            }
        }
    }

    @Test("The schemas serialise the same way every time")
    func schemasAreByteStable() {
        let first = toolbox().fingerprint
        for _ in 0..<5 { #expect(toolbox().fingerprint == first) }
        // And a fresh toolbox over fresh engines agrees with it, so nothing about a session leaks
        // into position 0 of the request.
        #expect(toolbox().definitions.map(\.inputSchema).map(\.jsonText)
                == toolbox().definitions.map(\.inputSchema).map(\.jsonText))
    }

    @Test("There is one breakpoint on the tool list, on the last tool")
    func toolListBreakpoint() {
        let definitions = toolbox().definitions
        #expect(definitions.dropLast().allSatisfy { $0.cacheControl == nil })
        #expect(definitions.last?.cacheControl != nil)
    }

    @Test("A tool list plus a system prompt is two breakpoints, well under the four allowed")
    func breakpointBudget() {
        let request = ClaudeRequest(model: .opus5,
                                    system: DirectorPrompt.systemBlocks,
                                    tools: toolbox().definitions,
                                    messages: [.user("hi")])
        #expect(ClaudeClient.cacheBreakpoints(in: request) == 2)
        #expect(ClaudeClient.cacheBreakpoints(in: request) <= ClaudeClient.maximumCacheBreakpoints)
    }

    @Test("The frozen prefix holds nothing that changes between requests")
    func thePrefixIsFrozen() {
        let prompt = DirectorPrompt.system
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        #expect(!prompt.contains("\(year)"), "no date in the prefix")
        // The prefix is a stored constant, so two reads of it are the same bytes by construction;
        // the test that matters is that nothing interpolates into it.
        #expect(DirectorPrompt.system == DirectorPrompt.system)
        #expect(DirectorPrompt.systemBlocks.map(\.text) == DirectorPrompt.systemBlocks.map(\.text))
        for tool in toolbox().tools {
            #expect(!tool.definition.description.contains("\(year)"), "\(tool.name)")
        }
    }

    @Test("The prefix is long enough to be worth caching on every model it runs on")
    func prefixIsCacheable() {
        // Four characters to a token is the rough rule; the minimum is 512 on Opus and Fable and
        // 1024 on Sonnet, so a prefix this size caches everywhere.
        let characters = DirectorPrompt.system.count
            + toolbox().definitions.reduce(0) { $0 + $1.description.count + $1.inputSchema.jsonText.count }
        let tokens = characters / 4
        for model in ClaudeModel.allCases {
            #expect(tokens > model.minimumCacheablePrefix,
                    "\(model): roughly \(tokens) tokens against a minimum of \(model.minimumCacheablePrefix)")
        }
    }

    @Test("A tool the model asks for by the wrong name comes back as an answer, not a throw")
    func unknownToolIsAnAnswer() async {
        let result = await toolbox().run(ClaudeToolUse(id: "t", name: "nope", input: .object([])))
        #expect(result.isError)
        #expect(result.toolUseID == "t")
        #expect(result.content.contains("read_song"))
    }

    @Test("A tool that fails comes back as an answer too, with what it suggested")
    func toolFailureIsAnAnswer() async {
        let result = await toolbox().run(
            ClaudeToolUse(id: "t", name: "describe_feel",
                          input: .object([.init("name", .string("Nothing Like It"))])))
        #expect(result.isError)
        #expect(result.content.contains("list_feels"))
    }

    @Test("A tool that succeeds comes back as JSON the model can read")
    func toolSuccessIsJSON() async throws {
        let result = await toolbox().run(ClaudeToolUse(id: "t", name: "read_song", input: .object([])))
        #expect(!result.isError)
        let value = try DirectorJSON.parse(Data(result.content.utf8))
        #expect(value["is_open"]?.boolValue == true)
        #expect(value["title"]?.stringValue == "Arrival")
    }

    @Test("A decode failure names the key rather than dumping a Swift error")
    func decodeFailureIsReadable() async {
        let result = await toolbox().run(
            ClaudeToolUse(id: "t", name: "chop_bar",
                          input: .object([.init("bar", .string("the loud one"))])))
        #expect(result.isError)
        #expect(result.content.contains("chop_bar"))
    }

    @Test("The schema DSL makes an optional field nullable rather than absent")
    func optionalSchema() {
        let optional = Schema.optional(Schema.integer("A number, or nothing."))
        #expect(optional["type"]?.arrayValue?.compactMap(\.stringValue) == ["integer", "null"])
        #expect(optional["description"]?.stringValue == "A number, or nothing.")
    }
}
