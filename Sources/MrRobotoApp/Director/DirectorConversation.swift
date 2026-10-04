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
    ///
    /// `last` is the reply the round limit interrupted, when there was one. It is carried rather
    /// than dropped because the model is usually mid-sentence about the work when the loop stops —
    /// "that's three reads recorded, now to show them" — and that sentence is the most specific
    /// thing anybody has about where the turn got to. Throwing it away to print a round count was
    /// the app telling the user a number they cannot act on instead of the news they can.
    case stoppedAtRoundLimit(rounds: Int, last: ClaudeResponse?)

    /// The reply as a person reads it.
    public var text: String {
        switch self {
        case .finished(let response), .truncated(let response): response.text
        case .refused(let refusal): refusal.sentence
        case .stoppedAtRoundLimit(_, let last):
            (last?.text).flatMap { $0.isEmpty ? nil : $0 } ?? "That is as far as this turn got."
        }
    }

    public var response: ClaudeResponse? {
        switch self {
        case .finished(let response), .truncated(let response): response
        case .stoppedAtRoundLimit(_, let last): last
        case .refused: nil
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
        /// It finished. `isError` is the model's own view of it, not a crash, and `message` is what
        /// the tool actually said — the reason, carried rather than thrown away, because a refusal
        /// the user can see the name of but not the reason for is worse than no refusal at all.
        case toolFinished(name: String, isError: Bool, message: String)
        case roundFinished(round: Int)
    }

    private let client: ClaudeClient
    private let toolbox: DirectorToolbox
    private let role: DirectorRole
    /// The model the thread runs on: the role's, unless one was chosen.
    private var model: ClaudeModel
    private let system: [ClaudeText]
    private let maxTokens: Int
    private let effort: ClaudeEffort
    /// How many times round the loop before giving up.
    ///
    /// Twelve was measured against a sketch of the work rather than the work. The milestone's own
    /// acceptance line — chop the drums from bar 9 and give me something slower and dustier — takes
    /// about twenty-three calls end to end: read the song, load and analyse a stem, find the bars,
    /// cut one, name the slices, look through the feels, play the chop through three of them,
    /// adjust two of those, audition, record four versions, open a Compare. The model batches some
    /// of that, but not most of it, so twelve rounds ran out every single time and the design's
    /// carry-on path — which works — was being used to paper over a budget that was simply too
    /// small for the job it was set for.
    ///
    /// Thirty-two is that line with room to recover from several mistakes, and it is a ceiling
    /// rather than a target: a turn that finishes in nine rounds still costs nine.
    public let maxRounds: Int

    /// The budget every Director gets unless a test asks for a smaller one. Written down once so
    /// there is one number to change rather than three defaults to keep in step.
    public static let defaultMaxRounds = 32

    /// The whole transcript, oldest first.
    public private(set) var messages: [ClaudeTurn] = []

    /// What the model said in the turn just run, reply by reply: the words between the calls as
    /// well as the last ones. One model gives its account once the work is done; another gives it
    /// before it opens the surface and only signs off afterwards, and the last reply alone is then
    /// "That's open as a Compare" with the loudness it read left behind.
    public private(set) var spoken: [String] = []

    public init(client: ClaudeClient,
                toolbox: DirectorToolbox,
                role: DirectorRole = .judgment,
                model: ClaudeModel? = nil,
                persona: String? = nil,
                maxRounds: Int = DirectorConversation.defaultMaxRounds,
                maxTokens: Int = 16000,
                effort: ClaudeEffort = .high) {
        self.client = client
        self.toolbox = toolbox
        self.role = role
        self.model = model ?? role.model
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
        // Which thread the turn belongs to: one cleared under it — the song changed — must not
        // get the old song's transcript written back when the turn unwinds.
        let thread = generation
        var working = messages
        working.append(first)
        /// The newest reply, kept so a turn that runs out of rounds can hand back what the model
        /// was in the middle of saying rather than only how many times it went round.
        var lastResponse: ClaudeResponse?
        spoken = []

        do {
            for round in 1...maxRounds {
                try Task.checkCancellation()
                let request = ClaudeRequest(model: model,
                                            maxTokens: maxTokens,
                                            system: system,
                                            tools: toolbox.definitions,
                                            messages: Self.breakpointed(working),
                                            effort: effort)
                let response = try await client.send(request, role: role) { event in
                    onProgress?(.stream(event))
                }
                working.append(response.turn)
                lastResponse = response
                let words = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { spoken.append(words) }

                switch response.stopReason {
                case .refusal(let refusal):
                    // The transcript keeps nothing: a refused turn is not history, and replaying it
                    // would only invite the same refusal on the next request.
                    settle(committed, thread: thread)
                    return .refused(refusal)
                case .maxTokens:
                    settle(working, thread: thread)
                    return .truncated(response)
                case .toolUse, .pauseTurn:
                    let results = await runTools(response.toolUses, onProgress: onProgress)
                    guard !results.isEmpty else {
                        settle(working, thread: thread)
                        return .finished(response)
                    }
                    // All results in one user message: splitting them teaches the model to stop
                    // making parallel calls.
                    working.append(ClaudeTurn(role: .user, content: results.map { .toolResult($0) }))
                    onProgress?(.roundFinished(round: round))
                case .endTurn, .other:
                    settle(working, thread: thread)
                    return .finished(response)
                }
            }
            settle(working, thread: thread)
            return .stoppedAtRoundLimit(rounds: maxRounds, last: lastResponse)
        } catch {
            settle(committed, thread: thread)
            throw error
        }
    }

    /// Runs every call in a turn, in the order they were asked, and hands the results back together.
    private func runTools(_ uses: [ClaudeToolUse],
                          onProgress: (@Sendable (Progress) -> Void)?) async -> [ClaudeToolResult] {
        guard !uses.isEmpty else { return [] }
        // One after another, in the order the model asked for them. They used to run at once, so
        // "start_song, then write_groove" in one round could write the groove into the song being
        // left, and two writes to the same part raced. The frame is on one actor anyway: running
        // them together bought little but the race.
        var results: [ClaudeToolResult] = []
        for use in uses {
            onProgress?(.toolStarted(name: use.name, arguments: use.input))
            let result = await toolbox.run(use)
            onProgress?(.toolFinished(name: use.name, isError: result.isError, message: result.content))
            results.append(result)
        }
        return results
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

    /// The model the thread runs on.
    public var runsOn: ClaudeModel { model }

    /// Puts the thread on another model, and starts it over when that is a change: a transcript
    /// carries the thinking of the model that wrote it, signed, and another model is not to be
    /// handed it as its own. The cache is per model too, so nothing read is lost by it.
    public func use(_ model: ClaudeModel) {
        guard model != self.model else { return }
        self.model = model
        clear()
    }

    /// Starts over. The ledger is the client's and is not touched.
    public func clear() {
        messages = []
        generation += 1
    }

    /// Bumped by `clear()`, so a turn can tell its thread was started over while it ran.
    private var generation = 0

    /// The transcript a turn leaves, unless the thread was cleared under it.
    private func settle(_ transcript: [ClaudeTurn], thread: Int) {
        guard generation == thread else { return }
        messages = transcript
    }
}
