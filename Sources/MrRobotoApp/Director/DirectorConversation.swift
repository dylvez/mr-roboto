import Foundation

// The tool loop: ask, run whatever came back, ask again, until the model has nothing left to call.

/// How one exchange ended.
public enum DirectorOutcome: Sendable, Equatable {
    /// The model finished and this is what it said.
    case finished(ClaudeResponse)
    /// A safety classifier declined. Not an error: an answer, with a reason.
    case refused(ClaudeRefusal)
    /// The model hit its output ceiling mid-thought.
    case truncated(ClaudeResponse)
    /// The loop ran out of rounds. The transcript is intact and can be continued.
    case stoppedAtRoundLimit(rounds: Int)

    /// The reply as a person reads it.
    public var text: String {
        switch self {
        case .finished(let response), .truncated(let response): response.text
        case .refused(let refusal): refusal.sentence
        case .stoppedAtRoundLimit(let rounds):
            "This went round \(rounds) times without finishing. Nothing was lost; ask again to carry on."
        }
    }

    public var response: ClaudeResponse? {
        switch self {
        case .finished(let response), .truncated(let response): response
        case .refused, .stoppedAtRoundLimit: nil
        }
    }
}

/// One thread of work with the band: a transcript, a toolbox, and the loop between them.
///
/// The transcript is append-only and is only ever committed when a turn completes. A cancelled
/// turn, a failed turn and a turn that broke off mid-stream all leave it exactly as it was, which
/// is what makes "press escape" a safe thing to do rather than a thing that corrupts a session.
public actor DirectorConversation {
    /// The events a caller can watch, so a surface can show work happening.
    public enum Progress: Sendable {
        case stream(ClaudeStreamEvent)
        /// A tool is about to run, with the arguments the model chose.
        case toolStarted(name: String, arguments: DirectorJSON)
        /// It finished. `isError` is the model's own view of it, not a crash.
        case toolFinished(name: String, isError: Bool)
        case roundFinished(round: Int)
    }

    private let client: ClaudeClient
    private let toolbox: DirectorToolbox
    private let role: DirectorRole
    private let system: [ClaudeText]
    private let maxTokens: Int
    private let effort: ClaudeEffort
    /// How many times round the loop before giving up. Twelve is a whole re-groove with room to
    /// recover from two mistakes.
    public let maxRounds: Int

    /// The whole transcript, oldest first.
    public private(set) var messages: [ClaudeTurn] = []

    public init(client: ClaudeClient,
                toolbox: DirectorToolbox,
                role: DirectorRole = .judgment,
                persona: String? = nil,
                maxRounds: Int = 12,
                maxTokens: Int = 16000,
                effort: ClaudeEffort = .high) {
        self.client = client
        self.toolbox = toolbox
        self.role = role
        self.system = DirectorPrompt.systemBlocks(persona: persona)
        self.maxRounds = maxRounds
        self.maxTokens = maxTokens
        self.effort = effort
    }

    /// Adds a turn without sending anything. For seeding a conversation with context.
    public func append(_ turn: ClaudeTurn) { messages.append(turn) }

    /// Asks, and runs whatever comes back, until the model stops calling tools.
    public func ask(_ text: String,
                    onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> DirectorOutcome {
        try await run(appending: .user(text), onProgress: onProgress)
    }

    /// The loop.
    private func run(appending first: ClaudeTurn,
                     onProgress: (@Sendable (Progress) -> Void)?) async throws -> DirectorOutcome {
        // The transcript as it was. Every exit that is not a completed turn restores this.
        let committed = messages
        var working = messages
        working.append(first)

        do {
            for round in 1...maxRounds {
                try Task.checkCancellation()
                let request = ClaudeRequest(model: role.model,
                                            maxTokens: maxTokens,
                                            system: system,
                                            tools: toolbox.definitions,
                                            messages: Self.breakpointed(working),
                                            effort: effort)
                let response = try await client.send(request, role: role) { event in
                    onProgress?(.stream(event))
                }
                working.append(response.turn)

                switch response.stopReason {
                case .refusal(let refusal):
                    // The transcript keeps nothing: a refused turn is not history, and replaying it
                    // would only invite the same refusal on the next request.
                    messages = committed
                    return .refused(refusal)
                case .maxTokens:
                    messages = working
                    return .truncated(response)
                case .toolUse, .pauseTurn:
                    let results = await runTools(response.toolUses, onProgress: onProgress)
                    guard !results.isEmpty else {
                        messages = working
                        return .finished(response)
                    }
                    // All results in one user message: splitting them teaches the model to stop
                    // making parallel calls.
                    working.append(ClaudeTurn(role: .user, content: results.map { .toolResult($0) }))
                    onProgress?(.roundFinished(round: round))
                case .endTurn, .other:
                    messages = working
                    return .finished(response)
                }
            }
            messages = working
            return .stoppedAtRoundLimit(rounds: maxRounds)
        } catch {
            messages = committed
            throw error
        }
    }

    /// Runs every call in a turn at once, and puts the results back in the order they were asked.
    private func runTools(_ uses: [ClaudeToolUse],
                          onProgress: (@Sendable (Progress) -> Void)?) async -> [ClaudeToolResult] {
        guard !uses.isEmpty else { return [] }
        let toolbox = self.toolbox
        return await withTaskGroup(of: (Int, ClaudeToolResult).self) { group in
            for (index, use) in uses.enumerated() {
                group.addTask {
                    onProgress?(.toolStarted(name: use.name, arguments: use.input))
                    let result = await toolbox.run(use)
                    onProgress?(.toolFinished(name: use.name, isError: result.isError))
                    return (index, result)
                }
            }
            var collected: [(Int, ClaudeToolResult)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Puts the moving cache breakpoint on the last block of the newest turn.
    ///
    /// The frozen prefix already has one, on the system prompt; this second one lets each request
    /// read everything the conversation has accumulated so far and write only what the last round
    /// added. Two markers total, well under the four a request may carry.
    static func breakpointed(_ messages: [ClaudeTurn]) -> [ClaudeTurn] {
        var copy = messages
        guard var last = copy.last, !last.content.isEmpty else { return copy }
        switch last.content[last.content.count - 1] {
        case .text(var text):
            text.cacheControl = .ephemeral
            last.content[last.content.count - 1] = .text(text)
        case .toolResult(var result):
            result.cacheControl = .ephemeral
            last.content[last.content.count - 1] = .toolResult(result)
        case .toolUse, .thinking:
            // Neither takes a marker in this app's requests; the turn before it is already cached.
            return copy
        }
        copy[copy.count - 1] = last
        return copy
    }

    /// What the session has spent so far.
    public func spend() async -> ClaudeSpend { await client.spend }

    /// Starts over. The ledger is the client's and is not touched.
    public func clear() { messages = [] }
}
