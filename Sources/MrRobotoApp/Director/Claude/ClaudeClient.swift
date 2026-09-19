import Foundation

// The client. An actor because a session's ledger is mutable state that several surfaces read.

/// Whether this machine can talk to the API at all, and how it knows.
public enum ClaudeKeyStatus: Sendable, Equatable {
    case present(ClaudeCredentials.Origin)
    case missing

    public var hasKey: Bool { if case .present = self { true } else { false } }

    /// What the frame says. Never a stack trace, never a key.
    public var sentence: String {
        switch self {
        case .present(.environment): "Signed in from the environment."
        case .present(.keychain): "Signed in from the keychain."
        case .present(.absent): "Signed in."
        case .missing: ClaudeError.missingAPIKey.sentence
        }
    }
}

/// How long to wait before trying again, and how many times.
public struct ClaudeRetryPolicy: Sendable, Equatable {
    /// Total attempts including the first. 1 disables retrying.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 0.5,
                multiplier: Double = 2, maxDelay: TimeInterval = 30) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    /// The wait before attempt `attempt` (1-based: the delay before attempt 2 is the first wait).
    /// `retry-after` wins when the server sent one — it knows when the window resets and we do not.
    public func delay(beforeAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, maxDelay) }
        let exponent = max(0, attempt - 2)
        return min(baseDelay * pow(multiplier, Double(exponent)), maxDelay)
    }

    public static let none = ClaudeRetryPolicy(maxAttempts: 1)
}

/// Waiting, behind a door, so a backoff test finishes in microseconds.
public protocol ClaudeSleeper: Sendable {
    func sleep(_ seconds: TimeInterval) async throws
}

public struct SystemSleeper: ClaudeSleeper {
    public init() {}
    public func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// The Director's line to the API.
///
/// Everything it does is one method — send a request, stream the reply, fold it into a message —
/// wrapped in the four things that make that safe to do for real money: a key it never prints,
/// a backoff that treats a 429 as a wait rather than a failure, a ledger that says what the
/// session spent, and a cancellation path that leaves nothing half-written.
public actor ClaudeClient {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"
    /// The documented ceiling. More than four and the request is rejected.
    public static let maximumCacheBreakpoints = 4

    private let keySource: any ClaudeKeySource
    private let transport: any ClaudeTransport
    private let sleeper: any ClaudeSleeper
    private let baseURL: URL
    public let retry: ClaudeRetryPolicy

    /// What this session has spent. Read by the header; written by every turn.
    public private(set) var spend = ClaudeSpend()

    public init(keySource: any ClaudeKeySource = ClaudeCredentials(),
                transport: any ClaudeTransport = URLSessionClaudeTransport(),
                sleeper: any ClaudeSleeper = SystemSleeper(),
                retry: ClaudeRetryPolicy = ClaudeRetryPolicy(),
                baseURL: URL = ClaudeClient.defaultBaseURL) {
        self.keySource = keySource
        self.transport = transport
        self.sleeper = sleeper
        self.retry = retry
        self.baseURL = baseURL
    }

    // MARK: The key

    /// Whether there is a key, without ever handing one out. Asked at launch so the app can say
    /// "the band needs a key" in the rail rather than failing at the first request.
    ///
    /// It looks and does not read: the secret is only read when the first request is sent, and then
    /// once for the life of the client, so launching the app never raises the keychain's dialog.
    public func keyStatus() -> ClaudeKeyStatus {
        guard keySource.hasKey() else { return .missing }
        if let credentials = keySource as? ClaudeCredentials { return .present(credentials.origin) }
        return .present(.absent)
    }

    /// The key, read once and kept for this client's life.
    private var heldKey: ClaudeAPIKey?
    private func key() -> ClaudeAPIKey? {
        if let heldKey { return heldKey }
        guard let read = keySource.apiKey(), !read.isEmpty else { return nil }
        heldKey = read
        return read
    }

    // MARK: Sending

    /// Sends one request and returns the finished turn.
    ///
    /// - Parameters:
    ///   - request: what to ask. Validated against the model's own rules before a byte goes out.
    ///   - role: which budget line this turn belongs to, for the ledger.
    ///   - onEvent: called for every stream event, on the actor, as the reply arrives. The rail
    ///     renders text deltas through this; it is optional and never required for correctness.
    /// - Throws: `ClaudeError` for anything the API or the network did, `CancellationError` if the
    ///   caller cancelled. A refusal is not an error — it comes back as the message's stop reason.
    @discardableResult
    public func send(_ request: ClaudeRequest,
                     role: DirectorRole,
                     onEvent: (@Sendable (ClaudeStreamEvent) -> Void)? = nil) async throws -> ClaudeResponse {
        try validate(request)
        guard let key = key() else {
            record(.zero, model: request.model, role: role, outcome: .failed)
            throw ClaudeError.missingAPIKey
        }

        let httpRequest = try build(request, key: key)
        var lastDelay: TimeInterval = 0

        for attempt in 1...max(1, retry.maxAttempts) {
            try Task.checkCancellation()
            do {
                return try await attemptSend(httpRequest, request: request, role: role, onEvent: onEvent)
            } catch let error as ClaudeError {
                let isLast = attempt >= retry.maxAttempts
                guard error.isRetryable, !isLast else {
                    if case .http(let status, _, _, _, _) = error, status == 429, isLast {
                        record(.zero, model: request.model, role: role, outcome: .failed)
                        throw ClaudeError.rateLimited(retriesUsed: attempt, lastDelay: lastDelay)
                    }
                    record(.zero, model: request.model, role: role, outcome: .failed)
                    throw error
                }
                lastDelay = retry.delay(beforeAttempt: attempt + 1, retryAfter: error.retryAfter)
                try await sleeper.sleep(lastDelay)
            }
        }
        // Unreachable: the loop either returns or throws. Kept honest rather than force-unwrapped.
        throw ClaudeError.rateLimited(retriesUsed: retry.maxAttempts, lastDelay: lastDelay)
    }

    /// One attempt: send, read the status, stream the body.
    private func attemptSend(_ httpRequest: ClaudeHTTPRequest,
                             request: ClaudeRequest,
                             role: DirectorRole,
                             onEvent: (@Sendable (ClaudeStreamEvent) -> Void)?) async throws -> ClaudeResponse {
        let response = try await transport.send(httpRequest)
        guard response.status == 200 else {
            // The server's own wait, when it sent one: it knows when the window resets.
            let wait = response.header("retry-after").flatMap(TimeInterval.init)
            throw ClaudeErrorEnvelope.read(try await response.collect(),
                                           status: response.status, retryAfter: wait)
        }

        var parser = ClaudeStreamParser()
        var builder = ClaudeMessageBuilder()
        do {
            for try await chunk in response.body {
                // Checked per chunk rather than per event: this is the point where a cancelled
                // task stops reading, and the builder is dropped with whatever it had.
                try Task.checkCancellation()
                for event in try parser.consume(chunk) {
                    try builder.accept(event)
                    onEvent?(event)
                }
            }
            // A cancelled task ends the byte stream rather than throwing out of it, so the loop
            // above can exit cleanly on a turn that never finished. Without this check that would
            // surface as "the reply ended before message_stop" instead of the truth.
            try Task.checkCancellation()
            for event in try parser.finish() {
                try builder.accept(event)
                onEvent?(event)
            }
        } catch is CancellationError {
            // The turn is abandoned, but the tokens it read were still billed, so the ledger is
            // told. Nothing else survives: no message, no partial text, no tool call.
            record(builder.billedSoFar, model: request.model, role: role, outcome: .cancelled)
            throw CancellationError()
        }

        let message = try builder.finish()
        record(message.usage, model: request.model, role: role,
               outcome: message.stopReason.isRefusal ? .refused : .completed)
        return message
    }

    // MARK: Building

    /// Turns a request into bytes and headers.
    func build(_ request: ClaudeRequest, key: ClaudeAPIKey) throws -> ClaudeHTTPRequest {
        // Through `ClaudeCoding`, which sorts keys. Foundation's default order is a per-process
        // hash order, so without this the same request writes different bytes on two runs and
        // every cached prefix in the field is a miss. See `ClaudeCoding`.
        let body = try ClaudeCoding.encode(request)
        return ClaudeHTTPRequest(
            url: baseURL.appending(path: "v1/messages"),
            headers: [
                "content-type": "application/json",
                "anthropic-version": Self.apiVersion,
                "x-api-key": key.secret,
            ],
            body: body)
    }

    /// The rules this client enforces before the API does, so a mistake is a Swift error at the
    /// call site rather than a 400 in front of a person.
    func validate(_ request: ClaudeRequest) throws {
        if request.toolChoice.isForced && !request.model.allowsForcedToolChoice {
            throw ClaudeError.unsupportedParameter(
                "\(request.model) rejects a forced tool_choice; ask for the tool by name in the prompt instead")
        }
        if request.messages.contains(where: { $0.role == .system }) && !request.model.allowsMidConversationSystem {
            throw ClaudeError.unsupportedParameter(
                "\(request.model) has no mid-conversation system message; put the instruction in a user turn")
        }
        if let first = request.messages.first, first.role != .user {
            throw ClaudeError.unsupportedParameter("the first message must be a user turn")
        }
        if request.messages.isEmpty {
            throw ClaudeError.unsupportedParameter("a request needs at least one message")
        }
        let breakpoints = Self.cacheBreakpoints(in: request)
        if breakpoints > Self.maximumCacheBreakpoints {
            throw ClaudeError.unsupportedParameter(
                "\(breakpoints) cache breakpoints; the maximum is \(Self.maximumCacheBreakpoints)")
        }
    }

    /// How many `cache_control` markers a request carries.
    static func cacheBreakpoints(in request: ClaudeRequest) -> Int {
        var count = request.system.filter { $0.cacheControl != nil }.count
        count += request.tools.filter { $0.cacheControl != nil }.count
        for message in request.messages {
            for block in message.content {
                switch block {
                case .text(let text): if text.cacheControl != nil { count += 1 }
                case .toolResult(let result): if result.cacheControl != nil { count += 1 }
                case .toolUse, .thinking: break
                }
            }
        }
        return count
    }

    // MARK: Ledger

    private func record(_ usage: ClaudeUsage, model: ClaudeModel, role: DirectorRole,
                        outcome: ClaudeSpendEntry.Outcome) {
        // A failure with no usage is still a line in the ledger: "we tried this and it cost
        // nothing" is information, and an empty ledger after a bad night is not.
        spend.record(ClaudeSpendEntry(model: model, role: role, usage: usage, outcome: outcome))
    }

    /// Starts the session's accounting over. The frame calls this when a song is closed.
    public func resetSpend() { spend = ClaudeSpend() }

}
