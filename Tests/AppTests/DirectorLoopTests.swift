import Foundation
import Testing

@testable import MrRobotoApp

/// The tool loop: several round trips, in order, with the transcript checked after each one.
@Suite("Director: the tool loop")
struct DirectorLoopTests {

    /// A toolbox of two tools that do nothing but answer, so the loop is the only thing under test.
    private struct EchoTool: DirectorTool {
        struct Input: Decodable, Sendable { var value: String }
        struct Output: Encodable, Sendable { var echoed: String }
        let name: String
        var purpose: String { "Echo \(name)." }
        var schema: DirectorJSON {
            Schema.object([("value", Schema.string("Anything."))], required: ["value"])
        }
        func run(_ input: Input) async throws -> Output { Output(echoed: input.value) }
    }

    private struct FailingTool: DirectorTool {
        struct Input: Decodable, Sendable {}
        struct Output: Encodable, Sendable {}
        let name = "always_fails"
        var purpose: String { "Always fails." }
        var schema: DirectorJSON { Schema.object([], required: []) }
        func run(_ input: Input) async throws -> Output {
            throw DirectorToolFailure(tool: name, reason: "It did not work.", suggestion: "Try read_song.")
        }
    }

    private var toolbox: DirectorToolbox {
        DirectorToolbox([EchoTool(name: "echo_a").erased(),
                         EchoTool(name: "echo_b").erased(),
                         FailingTool().erased()])
    }

    private func toolTurn(_ id: String, _ tool: String, _ json: String, index: Int = 0) -> String {
        DirectorSSE.toolUse(id: id, name: tool, jsonPieces: [json], index: index)
    }

    // MARK: Rounds

    @Test("A call, a result, and a reply: three messages and two requests")
    func oneRoundTrip() async throws {
        let (client, transport) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("toolu_1", "echo_a", #"{"value":"one"}"#)
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Done.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let outcome = try await conversation.ask("do it")

        #expect(outcome.text == "Done.")
        #expect(await transport.requestCount == 2)

        let messages = await conversation.messages
        #expect(messages.count == 4)                       // user, assistant(tool_use), user(result), assistant
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)
        guard case .toolResult(let result) = messages[2].content[0] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.toolUseID == "toolu_1")
        #expect(result.content.contains("\"echoed\":\"one\""))
        #expect(!result.isError)
    }

    @Test("Three round trips carry the whole transcript forward each time")
    func severalRoundTrips() async throws {
        let (client, transport) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("t1", "echo_a", #"{"value":"1"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.start() + toolTurn("t2", "echo_b", #"{"value":"2"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.start() + toolTurn("t3", "echo_a", #"{"value":"3"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("All three.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("go")

        #expect(await transport.requestCount == 4)
        #expect(await conversation.messages.count == 8)

        // Each request resends everything before it: the fourth carries seven prior turns.
        let last = try await transport.request(3).bodyJSON()
        #expect(last["messages"]?.arrayValue?.count == 7)
        let first = try await transport.request(0).bodyJSON()
        #expect(first["messages"]?.arrayValue?.count == 1)
    }

    @Test("Two calls in one turn run in the order asked and come back in one user message")
    func parallelCalls() async throws {
        let body = DirectorSSE.start()
            + toolTurn("p1", "echo_a", #"{"value":"first"}"#, index: 0)
            + toolTurn("p2", "echo_b", #"{"value":"second"}"#, index: 1)
            + DirectorSSE.end(stopReason: "tool_use")
        let (client, _) = DirectorTestClient.make([.events(body), .events(DirectorSSE.reply("both"))])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("both please")

        let messages = await conversation.messages
        let results = messages[2].content.compactMap { block -> ClaudeToolResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
        #expect(messages[2].content.count == 2, "one message, not two")
        #expect(results.map(\.toolUseID) == ["p1", "p2"], "in the order they were asked")
    }

    @Test("A tool that fails answers the model rather than ending the session")
    func toolFailureIsAnAnswer() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("f1", "always_fails", "{}") + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("I will try something else.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let outcome = try await conversation.ask("break it")

        #expect(outcome.text == "I will try something else.")
        guard case .toolResult(let result) = (await conversation.messages)[2].content[0] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.isError)
        #expect(result.content.contains("It did not work."))
        #expect(result.content.contains("Try read_song."))
    }

    @Test("A tool nobody registered comes back named, with the list of ones that exist")
    func unknownTool() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("u1", "make_a_sandwich", "{}") + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Sorry.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("sandwich")

        guard case .toolResult(let result) = (await conversation.messages)[2].content[0] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.isError)
        #expect(result.content.contains("make_a_sandwich"))
        #expect(result.content.contains("echo_a"))
    }

    @Test("Arguments a tool cannot read are reported by key rather than as a crash")
    func badArguments() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("b1", "echo_a", #"{"wrong":"key"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Fixed.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("go")

        guard case .toolResult(let result) = (await conversation.messages)[2].content[0] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.isError)
        #expect(result.content.contains("value"))
    }

    // MARK: Caching within the loop

    @Test("Each request carries two breakpoints: the frozen prefix, and the newest turn")
    func movingBreakpoint() async throws {
        let (client, transport) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("c1", "echo_a", #"{"value":"x"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("done")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("go")

        for index in 0..<2 {
            let body = try await transport.request(index).bodyJSON()
            let system = try #require(body["system"]?.arrayValue)
            #expect(system.last?["cache_control"] != nil, "request \(index): the frozen prefix")
            let messages = try #require(body["messages"]?.arrayValue)
            let lastBlock = messages.last?["content"]?.arrayValue?.last
            #expect(lastBlock?["cache_control"] != nil, "request \(index): the newest turn")
            // The prefix is kept an hour and the conversation five minutes, the longer one first.
            #expect(system.last?["cache_control"]?["ttl"]?.stringValue == "1h")
            #expect(body["tools"]?.arrayValue?.last?["cache_control"]?["ttl"]?.stringValue == "1h")
            #expect(lastBlock?["cache_control"]?["ttl"] == nil, "request \(index): five minutes is the default, unsaid")
        }

        // Second request: the marker is on the tool result, which is where the conversation grew.
        let second = try await transport.request(1).bodyJSON()
        let lastMessage = try #require(second["messages"]?.arrayValue?.last)
        #expect(lastMessage["content"]?.arrayValue?.last?["type"]?.stringValue == "tool_result")
    }

    @Test("The tool list is byte-identical in every request of a session")
    func toolListIsFrozen() async throws {
        let (client, transport) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("c1", "echo_a", #"{"value":"x"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("done")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("go")

        let first = try await transport.request(0).bodyJSON()["tools"]?.jsonText
        let second = try await transport.request(1).bodyJSON()["tools"]?.jsonText
        #expect(first != nil)
        #expect(first == second)
    }

    // MARK: Ending

    @Test("A refusal ends the exchange and leaves the transcript as it was")
    func refusalLeavesNothing() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + DirectorSSE.refusal(category: "cyber", explanation: "No.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let outcome = try await conversation.ask("something off")

        #expect(outcome == .refused(ClaudeRefusal(category: "cyber", explanation: "No.")))
        #expect(outcome.text == "No.")
        #expect(await conversation.messages.isEmpty, "a refused turn is not history")
    }

    @Test("A truncated turn is kept and said honestly")
    func truncated() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + DirectorSSE.text("It goes on and") + DirectorSSE.end(stopReason: "max_tokens")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let outcome = try await conversation.ask("write forever")
        guard case .truncated = outcome else {
            Issue.record("expected truncated, got \(outcome)")
            return
        }
        #expect(await conversation.messages.count == 2)
    }

    @Test("A model that will not stop calling tools is stopped, with the transcript intact")
    func roundLimit() async throws {
        let calling = DirectorScriptedTransport.Reply.events(
            DirectorSSE.start() + toolTurn("loop", "echo_a", #"{"value":"again"}"#)
                + DirectorSSE.end(stopReason: "tool_use"))
        let (client, transport) = DirectorTestClient.make(Array(repeating: calling, count: 4))
        let conversation = DirectorConversation(client: client, toolbox: toolbox, maxRounds: 3)
        let outcome = try await conversation.ask("go")

        guard case .stoppedAtRoundLimit(let rounds, let last) = outcome else {
            Issue.record("expected the round limit, got \(outcome)")
            return
        }
        #expect(rounds == 3)
        // The reply the limit interrupted is carried out rather than dropped: it is the most
        // specific thing anybody has about where the turn got to.
        #expect(last?.toolUses.first?.name == "echo_a")
        #expect(await transport.requestCount == 3)
        #expect(await conversation.messages.count == 7)
    }

    @Test("A failure part-way through leaves the transcript where it started")
    func failureRollsBack() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("r1", "echo_a", #"{"value":"x"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .error(status: 400, type: "invalid_request_error", message: "no"),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        await #expect(throws: ClaudeError.self) { _ = try await conversation.ask("go") }
        #expect(await conversation.messages.isEmpty, "nothing half-written survives")
    }

    @Test("A second exchange builds on the first")
    func continuing() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.reply("First.")),
            .events(DirectorSSE.reply("Second.")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        _ = try await conversation.ask("one")
        _ = try await conversation.ask("two")
        #expect(await conversation.messages.count == 4)
        await conversation.clear()
        #expect(await conversation.messages.isEmpty)
    }

    @Test("Progress is reported as it happens, tool by tool")
    func progress() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start() + toolTurn("p", "echo_a", #"{"value":"x"}"#) + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("done")),
        ])
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let seen = DirectorProgressLog()
        _ = try await conversation.ask("go") { progress in seen.record(progress) }

        #expect(seen.toolsStarted == ["echo_a"])
        #expect(seen.toolsFinished == ["echo_a"])
        #expect(seen.text == "done")
        #expect(seen.rounds == [1])
    }
}

/// Collects what a conversation reported while it ran. A class with a lock rather than an actor:
/// the progress callback is synchronous and cannot await.
final class DirectorProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedTools: [String] = []
    private var finishedTools: [String] = []
    private var messages: [String] = []
    private var roundsSeen: [Int] = []
    private var accumulated = ""

    func record(_ progress: DirectorConversation.Progress) {
        lock.lock()
        defer { lock.unlock() }
        switch progress {
        case .toolStarted(let name, _): startedTools.append(name)
        case .toolFinished(let name, _, let message): finishedTools.append(name); messages.append(message)
        case .roundFinished(let round): roundsSeen.append(round)
        case .stream(let event):
            if case .textDelta(_, let text) = event { accumulated += text }
        }
    }

    var toolsStarted: [String] { lock.withLock { startedTools } }
    var toolsFinished: [String] { lock.withLock { finishedTools } }
    /// What each finished tool actually said, in the same order.
    var toolMessages: [String] { lock.withLock { messages } }
    var rounds: [Int] { lock.withLock { roundsSeen } }
    var text: String { lock.withLock { accumulated } }
}
