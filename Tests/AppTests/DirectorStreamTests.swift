import Foundation
import Testing

@testable import MrRobotoApp

/// The streaming parser, against events written by hand.
///
/// Hand-written rather than recorded from a live call: a fixture that can be malformed on purpose
/// is the only way to test the half of this code that exists for when the stream goes wrong.
@Suite("Director: the streaming parser")
struct DirectorStreamTests {

    private func events(_ body: String, chunkSize: Int? = nil) throws -> [ClaudeStreamEvent] {
        var parser = ClaudeStreamParser()
        var collected: [ClaudeStreamEvent] = []
        let data = Data(body.utf8)
        let size = chunkSize ?? data.count
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            collected += try parser.consume(data[index..<end])
            index = end
        }
        collected += try parser.finish()
        return collected
    }

    private func message(_ body: String, chunkSize: Int? = nil) throws -> ClaudeResponse {
        var builder = ClaudeMessageBuilder()
        for event in try events(body, chunkSize: chunkSize) { try builder.accept(event) }
        return try builder.finish()
    }

    @Test("A plain reply parses into one text block and a usage figure")
    func plainReply() throws {
        let response = try message(DirectorSSE.reply("Hello.", inputTokens: 120, outputTokens: 9))
        #expect(response.id == "msg_test")
        #expect(response.model == "claude-opus-5")
        #expect(response.text == "Hello.")
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens == 120)
        #expect(response.usage.outputTokens == 9)
    }

    @Test("The same bytes parse the same whether they arrive whole or seven at a time")
    func chunkingDoesNotMatter() throws {
        let body = DirectorSSE.reply("A longer reply, split across chunk boundaries.")
        let whole = try message(body)
        for size in [1, 3, 7, 64, 1024] {
            let split = try message(body, chunkSize: size)
            #expect(split.text == whole.text, "chunk size \(size)")
            #expect(split.usage == whole.usage, "chunk size \(size)")
        }
    }

    @Test("Tool arguments arriving in pieces are reassembled and parsed")
    func toolArguments() throws {
        let body = DirectorSSE.start()
            + DirectorSSE.toolUse(id: "toolu_1", name: "chop_bar",
                                  jsonPieces: ["{\"audio\":", "\"audio-1\",\"bar\"", ":9}"])
            + DirectorSSE.end(stopReason: "tool_use")
        let response = try message(body, chunkSize: 11)

        #expect(response.stopReason == .toolUse)
        let use = try #require(response.toolUses.first)
        #expect(use.id == "toolu_1")
        #expect(use.name == "chop_bar")
        #expect(use.input["audio"]?.stringValue == "audio-1")
        #expect(use.input["bar"]?.intValue == 9)
    }

    @Test("A tool call with no arguments at all is an empty object, not a failure")
    func emptyToolArguments() throws {
        let body = DirectorSSE.start()
            + DirectorSSE.toolUse(id: "toolu_2", name: "read_song", jsonPieces: [])
            + DirectorSSE.end(stopReason: "tool_use")
        let response = try message(body)
        #expect(response.toolUses.first?.input == .object([]))
    }

    @Test("Text and a tool call in one turn keep their order")
    func mixedBlocks() throws {
        let body = DirectorSSE.start()
            + DirectorSSE.text("Let me look.", index: 0)
            + DirectorSSE.toolUse(id: "toolu_3", name: "read_song", jsonPieces: ["{}"], index: 1)
            + DirectorSSE.end(stopReason: "tool_use")
        let response = try message(body)
        #expect(response.content.count == 2)
        #expect(response.content[0].textValue == "Let me look.")
        #expect(response.content[1].toolUseValue?.name == "read_song")
    }

    @Test("A thinking block and its signature survive the round trip unchanged")
    func thinkingBlock() throws {
        let body = DirectorSSE.start()
            + DirectorSSE.event("content_block_start",
                                #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
            + DirectorSSE.event("content_block_delta",
                                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weighing it up"}}"#)
            + DirectorSSE.event("content_block_delta",
                                #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#)
            + DirectorSSE.event("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + DirectorSSE.end()
        let response = try message(body)
        guard case .thinking(let block) = response.content.first else {
            Issue.record("expected a thinking block")
            return
        }
        #expect(block.thinking == "weighing it up")
        #expect(block.signature == "sig123")
        // It has to go back into the conversation untouched, or the next turn is billed as a miss.
        #expect(response.turn.content.first == .thinking(block))
    }

    @Test("Pings and comments are ignored rather than mistaken for content")
    func keepAlives() throws {
        let body = DirectorSSE.start()
            + ": keep-alive\n\n"
            + DirectorSSE.event("ping", #"{"type":"ping"}"#)
            + DirectorSSE.text("still here")
            + DirectorSSE.end()
        let response = try message(body)
        #expect(response.text == "still here")
    }

    @Test("An event type nobody has written a case for is skipped, not fatal")
    func unknownEvent() throws {
        let body = DirectorSSE.start()
            + DirectorSSE.event("something_new", #"{"type":"something_new","whatever":1}"#)
            + DirectorSSE.text("fine") + DirectorSSE.end()
        #expect(try message(body).text == "fine")
    }

    @Test("An error event mid-stream is raised with what the server said")
    func errorEvent() throws {
        let body = DirectorSSE.start() + DirectorSSE.text("half")
            + DirectorSSE.event("error", #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
        #expect(throws: ClaudeError.streamError(type: "overloaded_error", message: "busy")) {
            _ = try events(body)
        }
    }

    @Test("A stream that stops before message_stop is a failure, not a short reply")
    func truncatedStream() throws {
        let body = DirectorSSE.start() + DirectorSSE.text("half a thou")
        var builder = ClaudeMessageBuilder()
        for event in try events(body) { try builder.accept(event) }
        #expect(!builder.isComplete)
        #expect(throws: ClaudeError.self) { _ = try builder.finish() }
        // And the tokens it did read are still known, so a cancelled turn can be billed honestly.
        #expect(builder.billedSoFar.inputTokens == 1000)
    }

    @Test("Malformed JSON in an event is named rather than swallowed")
    func malformedPayload() throws {
        #expect(throws: ClaudeError.self) {
            _ = try events("event: message_start\ndata: {not json\n\n")
        }
    }

    @Test("Usage arrives in two halves: input at the start, output at the end")
    func usageAccumulates() throws {
        let response = try message(DirectorSSE.reply("x", inputTokens: 500, outputTokens: 77,
                                                     cacheRead: 4000, cacheCreation: 200))
        #expect(response.usage.inputTokens == 500)
        #expect(response.usage.outputTokens == 77)
        #expect(response.usage.cacheReadTokens == 4000)
        #expect(response.usage.cacheCreationTokens == 200)
        #expect(response.usage.promptTokens == 4700)
    }

    @Test("A closing event that repeats the prompt's figures does not count the prompt twice")
    func usageIsCumulative() throws {
        // What the API sends now: the prompt's counts again at the end, beside the output.
        let body = DirectorSSE.start(inputTokens: 4, cacheRead: 33_000, cacheCreation: 600)
            + DirectorSSE.text("Done.")
            + DirectorSSE.event("message_delta", """
                {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},\
                "usage":{"input_tokens":4,"cache_creation_input_tokens":600,"cache_read_input_tokens":33000,"output_tokens":77}}
                """)
            + DirectorSSE.event("message_stop", #"{"type":"message_stop"}"#)
        let response = try message(body)
        #expect(response.usage == ClaudeUsage(inputTokens: 4, outputTokens: 77, cacheCreationTokens: 600, cacheReadTokens: 33_000))
        #expect(response.usage.promptTokens == 33_604)
    }

    @Test("A refusal's stop details come through whole")
    func refusalDetails() throws {
        let body = DirectorSSE.start() + DirectorSSE.refusal(category: "bio", explanation: "No.")
        let response = try message(body)
        #expect(response.stopReason == .refusal(ClaudeRefusal(category: "bio", explanation: "No.")))
        #expect(response.stopReason.isRefusal)
    }

    @Test("The same value always writes the same bytes, however it was built")
    func jsonIsDeterministic() throws {
        // The bug this exists to stop: Foundation's encoder writes a keyed container in a
        // per-process hash order, so the same request can produce different bytes on two runs and
        // the second one misses a cache that never changed. `ClaudeCoding` sorts the keys.
        let value = DirectorJSON.object([
            .init("zebra", .int(1)),
            .init("apple", .int(2)),
            .init("mango", .object([.init("inner", .string("x")), .init("also", .bool(true))])),
        ])
        let expected = #"{"apple":2,"mango":{"also":true,"inner":"x"},"zebra":1}"#
        for _ in 0..<50 { #expect(value.jsonText == expected) }

        // And a round trip is idempotent, which is what a tool call echoed back into the
        // transcript needs.
        let round = try DirectorJSON.parse(Data(value.jsonText.utf8))
        #expect(round.jsonText == expected)
        // Equal despite the member order differing: order is for the reader, not the meaning.
        #expect(round == value)
    }

    @Test("A whole request writes the same bytes every time it is encoded")
    func requestIsDeterministic() throws {
        let request = ClaudeRequest(model: .opus5,
                                    system: DirectorPrompt.systemBlocks,
                                    tools: [ClaudeToolDefinition(
                                        name: "t", description: "A tool.",
                                        inputSchema: Schema.object([
                                            ("zebra", Schema.string("Last alphabetically.")),
                                            ("apple", Schema.string("First alphabetically.")),
                                        ], required: ["zebra", "apple"]))],
                                    messages: [.user("hello")])
        let first = try ClaudeCoding.encode(request)
        for _ in 0..<50 { #expect(try ClaudeCoding.encode(request) == first) }
    }
}
