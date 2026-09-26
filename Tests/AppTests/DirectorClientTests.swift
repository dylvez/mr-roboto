import Foundation
import Testing

@testable import MrRobotoApp

/// The client, with no network and no key.
///
/// Every test here asserts something that only shows up in production otherwise: the exact bytes
/// of a request, what a 429 does, what a cancelled turn leaves behind, and what a session cost.
@Suite("Director: the Claude client")
struct DirectorClientTests {

    // MARK: The request

    @Test("The request carries the model, the frozen system prompt and the tool list, in that order")
    func requestShape() async throws {
        let (client, transport) = DirectorTestClient.make([.events(DirectorSSE.reply("ok"))])
        let tools = DirectorToolbox([]).definitions
        _ = try await client.send(DirectorTestClient.request(tools: tools), role: .judgment)

        let request = await transport.request(0)
        #expect(request.url.path == "/v1/messages")
        #expect(request.headers["anthropic-version"] == ClaudeClient.apiVersion)

        let body = try request.bodyJSON()
        #expect(body["model"]?.stringValue == "claude-opus-5")
        #expect(body["max_tokens"]?.intValue == 16000)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["system"]?.arrayValue?.count == 1)
        #expect(body["system"]?.arrayValue?.first?["text"]?.stringValue == DirectorPrompt.system)
        #expect(body["messages"]?.arrayValue?.count == 1)
        #expect(body["output_config"]?["effort"]?.stringValue == "high")
        #expect(body["thinking"]?["type"]?.stringValue == "adaptive")
    }

    @Test("Nothing the 2026 models reject is ever sent")
    func noRemovedParameters() async throws {
        let (client, transport) = DirectorTestClient.make([.events(DirectorSSE.reply("ok"))])
        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        let body = try await transport.request(0).bodyJSON()
        for removed in ["temperature", "top_p", "top_k"] {
            #expect(body[removed] == nil, "\(removed) is a 400 on every model this app uses")
        }
        #expect(body["thinking"]?["budget_tokens"] == nil)
    }

    @Test("Fable thinks always, so no thinking block is sent to it")
    func fableOmitsThinking() async throws {
        let (client, transport) = DirectorTestClient.make([.events(DirectorSSE.reply("ok", inputTokens: 10))])
        _ = try await client.send(DirectorTestClient.request(model: .fable51), role: .hardest)
        let body = try await transport.request(0).bodyJSON()
        #expect(body["thinking"] == nil)
        #expect(body["model"]?.stringValue == "claude-fable-5-1")
    }

    @Test("The key goes in the header and nowhere else, and never into a description")
    func keyIsNotPrinted() async throws {
        let (client, transport) = DirectorTestClient.make([.events(DirectorSSE.reply("ok"))])
        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        let request = await transport.request(0)
        #expect(request.headers["x-api-key"] == "sk-ant-test-0123456789")
        #expect(request.redactedHeaders["x-api-key"] == "(redacted)")
        #expect(!request.description.contains("0123456789"))
        #expect(!String(decoding: request.body, as: UTF8.self).contains("sk-ant"))

        let key = ClaudeAPIKey("sk-ant-secretsecret")
        #expect(!"\(key)".contains("secretsecret"))
        #expect(!String(reflecting: key).contains("secretsecret"))
    }

    // MARK: Caching

    @Test("One breakpoint, on the last system block, so tools and system cache together")
    func cacheBreakpoints() async throws {
        let request = DirectorTestClient.request(tools: DirectorToolbox([]).definitions)
        #expect(request.system.count == 1)
        #expect(request.system[0].cacheControl != nil)
        #expect(ClaudeClient.cacheBreakpoints(in: request) == 1)
    }

    @Test("A persona adds a second breakpoint and leaves the shared one alone")
    func personaPrefix() {
        let blocks = DirectorPrompt.systemBlocks(persona: "You are Nyx.")
        #expect(blocks.count == 2)
        #expect(blocks[0].text == DirectorPrompt.system)
        #expect(blocks[0].cacheControl != nil)
        #expect(blocks[1].cacheControl != nil)
    }

    @Test("More breakpoints than the API allows is caught here, not there")
    func tooManyBreakpoints() async throws {
        let blocks = (0..<5).map { ClaudeText("block \($0)", cacheControl: .ephemeral) }
        let request = ClaudeRequest(model: .opus5, system: blocks, messages: [.user("hi")])
        let (client, _) = DirectorTestClient.make([])
        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(request, role: .judgment)
        }
    }

    @Test("The frozen prefix is byte-identical from one request to the next")
    func prefixIsStable() async throws {
        let (client, transport) = DirectorTestClient.make([
            .events(DirectorSSE.reply("one")),
            .events(DirectorSSE.reply("two")),
        ])
        let tools = DirectorToolbox([]).definitions
        _ = try await client.send(DirectorTestClient.request([.user("first")], tools: tools), role: .judgment)
        _ = try await client.send(DirectorTestClient.request([.user("second")], tools: tools), role: .judgment)

        let first = try await transport.request(0).bodyJSON()
        let second = try await transport.request(1).bodyJSON()
        #expect(first["system"]?.jsonText == second["system"]?.jsonText)
        #expect(first["tools"]?.jsonText == second["tools"]?.jsonText)
        #expect(first["messages"]?.jsonText != second["messages"]?.jsonText)
    }

    // MARK: Validation

    @Test("A forced tool choice is refused for Fable before it becomes a 400")
    func fableRejectsForcedToolChoice() async throws {
        let request = ClaudeRequest(model: .fable51, toolChoice: .any, messages: [.user("hi")])
        let (client, transport) = DirectorTestClient.make([])
        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(request, role: .hardest)
        }
        #expect(await transport.requestCount == 0, "nothing should have gone out")
    }

    @Test("A mid-conversation system message is refused for Sonnet, which has none")
    func sonnetRejectsSystemMessage() async throws {
        let request = ClaudeRequest(model: .sonnet5,
                                    messages: [.user("hi"), .system("terse mode")])
        let (client, _) = DirectorTestClient.make([])
        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(request, role: .chatter)
        }
    }

    // MARK: The key

    @Test("With no key anywhere the client says so cleanly and sends nothing")
    func missingKey() async throws {
        let (client, transport) = DirectorTestClient.make([.events(DirectorSSE.reply("never"))],
                                                          keySource: ClaudeFixedKey.none)
        #expect(await client.keyStatus() == .missing)
        await #expect(throws: ClaudeError.missingAPIKey) {
            _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        }
        #expect(await transport.requestCount == 0)
        #expect(ClaudeError.missingAPIKey.sentence.contains("needs an Anthropic API key"))
    }

    @Test("The environment is read before the keychain, and neither means absent")
    func keyLookupOrder() {
        let keychain = ClaudeMemoryKeychain(["\(ClaudeCredentials.keychainService)/\(ClaudeCredentials.keychainAccount)": "sk-ant-from-keychain"])
        let both = ClaudeCredentials(environment: ["ANTHROPIC_API_KEY": "sk-ant-from-env"], keychain: keychain)
        #expect(both.apiKey()?.secret == "sk-ant-from-env")
        #expect(both.origin == .environment)

        let keychainOnly = ClaudeCredentials(environment: [:], keychain: keychain)
        #expect(keychainOnly.apiKey()?.secret == "sk-ant-from-keychain")
        #expect(keychainOnly.origin == .keychain)

        let neither = ClaudeCredentials(environment: [:], keychain: ClaudeMemoryKeychain())
        #expect(neither.apiKey() == nil)
        #expect(neither.origin == .absent)
    }

    @Test("Launch looks for the key and never reads it; the secret is read once, on the first request")
    func keychainIsNotReadAtLaunch() async throws {
        let keychain = CountingKeychain(secret: "sk-ant-from-keychain")
        let credentials = ClaudeCredentials(environment: [:], keychain: keychain)
        let body = DirectorSSE.reply("ok")
        let (client, _) = DirectorTestClient.make([.events(body), .events(body)], keySource: credentials)

        // What the app does on launch: is there a key, and where from?
        let status = await client.keyStatus()
        #expect(status.hasKey && credentials.origin == .keychain && credentials.hasKey())
        #expect(keychain.reads == 0, "reading the secret is what raises the keychain's password dialog")
        #expect(keychain.looks >= 1)

        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        #expect(keychain.reads == 1, "one read for the life of the client")

        let empty = ClaudeCredentials(environment: [:], keychain: CountingKeychain(secret: nil))
        #expect(!empty.hasKey() && empty.origin == .absent)
    }

    @Test("An empty environment variable is not a key")
    func emptyEnvironmentKey() {
        let credentials = ClaudeCredentials(environment: ["ANTHROPIC_API_KEY": "   "],
                                            keychain: ClaudeMemoryKeychain())
        #expect(credentials.apiKey() == nil)
    }

    // MARK: Refusal

    @Test("A refusal comes back as a stop reason with its reason intact, not as a crash")
    func refusal() async throws {
        let body = DirectorSSE.start() + DirectorSSE.refusal(category: "cyber", explanation: "Declined.")
        let (client, _) = DirectorTestClient.make([.events(body)])
        let response = try await client.send(DirectorTestClient.request(), role: .judgment)

        guard case .refusal(let refusal) = response.stopReason else {
            Issue.record("expected a refusal, got \(response.stopReason)")
            return
        }
        #expect(refusal.category == "cyber")
        #expect(refusal.sentence == "Declined.")
        #expect(await client.spend.entries.last?.outcome == .refused)
    }

    @Test("A refusal with no explanation still says something a person can read")
    func bareRefusal() {
        let refusal = ClaudeRefusal(category: nil, explanation: nil)
        #expect(refusal.sentence == "The band declined this one.")
    }

    // MARK: Rate limits

    @Test("A 429 backs off and retries rather than failing")
    func rateLimitBacksOff() async throws {
        let sleeper = DirectorRecordingSleeper()
        let (client, transport) = DirectorTestClient.make([
            .error(status: 429, type: "rate_limit_error", message: "slow down"),
            .error(status: 429, type: "rate_limit_error", message: "slow down"),
            .events(DirectorSSE.reply("finally")),
        ], retry: ClaudeRetryPolicy(maxAttempts: 4, baseDelay: 0.5), sleeper: sleeper)

        let response = try await client.send(DirectorTestClient.request(), role: .judgment)
        #expect(response.text == "finally")
        #expect(await transport.requestCount == 3)
        #expect(await sleeper.delays == [0.5, 1.0], "exponential, from the base delay")
    }

    @Test("The server's own retry-after wins over the exponent")
    func retryAfterHeaderWins() async throws {
        let sleeper = DirectorRecordingSleeper()
        let (client, _) = DirectorTestClient.make([
            .error(status: 429, type: "rate_limit_error", message: "slow down",
                   headers: ["retry-after": "7"]),
            .events(DirectorSSE.reply("ok")),
        ], retry: ClaudeRetryPolicy(maxAttempts: 3, baseDelay: 0.5), sleeper: sleeper)

        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        #expect(await sleeper.delays == [7])
    }

    @Test("Rate limited to the end says how many times it tried")
    func rateLimitedOut() async throws {
        let sleeper = DirectorRecordingSleeper()
        let (client, transport) = DirectorTestClient.make([
            .error(status: 429, type: "rate_limit_error", message: "no"),
            .error(status: 429, type: "rate_limit_error", message: "no"),
        ], retry: ClaudeRetryPolicy(maxAttempts: 2, baseDelay: 0.25), sleeper: sleeper)

        do {
            _ = try await client.send(DirectorTestClient.request(), role: .judgment)
            Issue.record("expected to be rate limited")
        } catch let error as ClaudeError {
            guard case .rateLimited(let retries, _) = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
            #expect(retries == 2)
        }
        #expect(await transport.requestCount == 2)
    }

    @Test("A 400 is not retried: waiting cannot fix a malformed request")
    func badRequestIsNotRetried() async throws {
        let (client, transport) = DirectorTestClient.make([
            .error(status: 400, type: "invalid_request_error", message: "messages: too short"),
            .events(DirectorSSE.reply("never")),
        ], retry: ClaudeRetryPolicy(maxAttempts: 4))

        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        }
        #expect(await transport.requestCount == 1)
    }

    @Test("A 529 is retried; the policy knows which statuses are worth waiting for")
    func overloadedIsRetryable() {
        #expect(ClaudeError.http(status: 529, type: "overloaded_error", message: "", requestID: nil).isRetryable)
        #expect(ClaudeError.http(status: 500, type: "api_error", message: "", requestID: nil).isRetryable)
        #expect(!ClaudeError.http(status: 401, type: "authentication_error", message: "", requestID: nil).isRetryable)
        #expect(!ClaudeError.missingAPIKey.isRetryable)
    }

    // MARK: Cancellation

    @Test("Cancelling mid-stream leaves no message behind, and says what it cost")
    func cancellationLeavesNothing() async throws {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        let transport = DirectorStallingTransport(
            prefix: DirectorSSE.start(inputTokens: 1200) + DirectorSSE.text("half a th"),
            started: { continuation.yield(()) })
        let client = ClaudeClient(keySource: DirectorTestClient.key, transport: transport,
                                  sleeper: DirectorRecordingSleeper(), retry: .none)

        let task = Task { try await client.send(DirectorTestClient.request(), role: .judgment) }
        var iterator = signal.makeAsyncIterator()
        _ = await iterator.next()
        // The stream has handed over its prefix; the client is mid-message.
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }

        let spend = await client.spend
        #expect(spend.entries.count == 1)
        #expect(spend.entries[0].outcome == .cancelled)
        #expect(spend.entries[0].usage.inputTokens == 1200, "the tokens it read were still billed")
    }

    // MARK: Cost

    @Test("A turn's cost is the sum of its parts at that model's prices")
    func cost() {
        let usage = ClaudeUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        #expect(usage.cost(on: .opus5) == Decimal(30))     // $5 in, $25 out
        #expect(usage.cost(on: .sonnet5) == Decimal(12))   // $2 in, $10 out
        #expect(usage.cost(on: .fable51) == Decimal(60))   // $10 in, $50 out
    }

    @Test("Cache reads are cheap, and Fable's are cheaper still")
    func cacheCost() {
        let read = ClaudeUsage(cacheReadTokens: 1_000_000)
        #expect(read.cost(on: .opus5) == Decimal(string: "0.5")!)
        #expect(read.cost(on: .fable51) == Decimal(string: "0.25")!,
                "Fable reads at 0.025x, not the usual 0.1x")

        let write = ClaudeUsage(cacheCreationTokens: 1_000_000)
        #expect(write.cost(on: .opus5) == Decimal(string: "6.25")!, "1.25x input at the five-minute TTL")
    }

    @Test("The prompt is the uncached remainder plus both cache figures")
    func promptTokens() {
        let usage = ClaudeUsage(inputTokens: 400, outputTokens: 100,
                                cacheCreationTokens: 600, cacheReadTokens: 9000)
        #expect(usage.promptTokens == 10_000)
        #expect(abs(usage.cacheHitRate - 0.9) < 0.0001)
    }

    @Test("A session's ledger adds up across models and outcomes")
    func ledger() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.reply("one", inputTokens: 2000, outputTokens: 100, cacheRead: 8000)),
            .events(DirectorSSE.reply("two", inputTokens: 1000, outputTokens: 50, cacheRead: 9000)),
        ])
        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        _ = try await client.send(DirectorTestClient.request(model: .sonnet5), role: .chatter)

        let spend = await client.spend
        #expect(spend.turnCount == 2)
        #expect(spend.usage.cacheReadTokens == 17_000)
        #expect(spend.usage(for: .opus5).inputTokens == 2000)
        #expect(spend.usage(for: .sonnet5).inputTokens == 1000)
        #expect(spend.total > 0)
        #expect(spend.total == spend.total(for: .opus5) + spend.total(for: .sonnet5))
        #expect(spend.line.contains("2 turns"))
    }

    @Test("Sub-cent spend is shown as sub-cent rather than as nothing")
    func moneyFormatting() {
        #expect(ClaudeSpend.money(Decimal(string: "0.0004")!) == "<$0.01")
        #expect(ClaudeSpend.money(Decimal(string: "1.25")!) == "$1.25")
        #expect(ClaudeSpend.money(0) == "$0.00")
    }

    @Test("Resetting the ledger clears it")
    func resetSpend() async throws {
        let (client, _) = DirectorTestClient.make([.events(DirectorSSE.reply("one"))])
        _ = try await client.send(DirectorTestClient.request(), role: .judgment)
        #expect(await client.spend.turnCount == 1)
        await client.resetSpend()
        #expect(await client.spend.turnCount == 0)
    }

    // MARK: Roles

    @Test("A role picks its model and nothing else does")
    func roles() {
        #expect(DirectorRole.judgment.model == .opus5)
        #expect(DirectorRole.chatter.model == .sonnet5)
        #expect(DirectorRole.hardest.model == .fable51)
        #expect(ClaudeModel.opus5.id == "claude-opus-5")
        #expect(ClaudeModel.sonnet5.id == "claude-sonnet-5")
        #expect(ClaudeModel.fable51.id == "claude-fable-5-1")
    }
}

/// A keychain that counts how often its secret is read, as opposed to looked for.
final class CountingKeychain: ClaudeKeychain, @unchecked Sendable {
    private let secret: String?
    private let lock = NSLock()
    private var readCount = 0, lookCount = 0
    init(secret: String?) { self.secret = secret }
    var reads: Int { lock.withLock { readCount } }
    var looks: Int { lock.withLock { lookCount } }
    func password(service: String, account: String) -> String? { lock.withLock { readCount += 1 }; return secret }
    func exists(service: String, account: String) -> Bool { lock.withLock { lookCount += 1 }; return secret != nil }
}
