import Foundation

// The models the band runs on, what they cost, and the handful of ways they differ from each other
// that this client has to know about. Everything here is a fact about the 2026 Messages API rather
// than a preference, so it is written down once and asserted in tests: a wrong model id is a 404
// and a wrong price is an invisible lie about what a session spent.

/// A model the Director can call.
///
/// Three, deliberately. Every call in the app picks a `DirectorRole` and the role picks the model,
/// so "which model does the critic use" is answered in one place rather than at every call site.
public enum ClaudeModel: String, Sendable, Codable, Hashable, CaseIterable, CustomStringConvertible {
    /// Judgment: choosing a surface, reading a song, deciding what to propose.
    case opus5 = "claude-opus-5"
    /// The frequent cheap calls: labels, one-line critiques, classifying an intent.
    case sonnet5 = "claude-sonnet-5"
    /// The hardest reasoning, and the most expensive: arranging a whole song, resolving an argument.
    case fable51 = "claude-fable-5-1"

    /// The exact string the API wants. Never date-suffixed.
    public var id: String { rawValue }
    public var description: String { rawValue }

    /// Price per million tokens, first-party Claude API rates.
    public var pricing: ClaudePricing {
        switch self {
        case .opus5: ClaudePricing(input: 5, output: 25)
        case .sonnet5: ClaudePricing(input: 2, output: 10)
        // Fable 5.1 reads cache at a flat $0.25/MTok — 0.025×, not the usual 0.1× — which changes
        // every break-even on it, so it is spelled out rather than derived.
        case .fable51: ClaudePricing(input: 10, output: 50, cacheRead: 0.25)
        }
    }

    /// Below this many tokens a `cache_control` marker is silently ignored. Model-dependent, and
    /// not monotonic across generations, so the prefix builder checks it rather than assuming.
    public var minimumCacheablePrefix: Int {
        switch self {
        case .opus5, .fable51: 512
        case .sonnet5: 1024
        }
    }

    /// Whether `tool_choice` may be `any` or a named tool. Fable 5.1 returns a 400 for both; the
    /// client refuses to send one rather than letting the request fail in the field.
    public var allowsForcedToolChoice: Bool {
        switch self {
        case .opus5, .sonnet5: true
        case .fable51: false
        }
    }

    /// Whether a `{"role": "system"}` message may be appended mid-conversation. Where it is
    /// available it is the operator channel that does not invalidate the cached prefix; Sonnet 5
    /// does not have it, so an instruction for that model goes in a user turn instead.
    public var allowsMidConversationSystem: Bool {
        switch self {
        case .opus5, .fable51: true
        case .sonnet5: false
        }
    }

    /// Whether an explicit `thinking` block may be sent. Fable 5.1 thinks always and rejects any
    /// explicit configuration, so the client omits the parameter for it.
    public var allowsExplicitThinking: Bool {
        switch self {
        case .opus5, .sonnet5: true
        case .fable51: false
        }
    }
}

/// What a call is for. The Director asks for a role; the role, not the call site, picks the model.
public enum DirectorRole: String, Sendable, Codable, Hashable, CaseIterable {
    /// Reading the song and deciding what to do about it.
    case judgment
    /// The cheap chatter: labels, short critiques, classification.
    case chatter
    /// The hardest reasoning in the app, and the only thing worth Fable prices.
    case hardest

    public var model: ClaudeModel {
        switch self {
        case .judgment: .opus5
        case .chatter: .sonnet5
        case .hardest: .fable51
        }
    }
}

/// Dollars per million tokens, by kind of token.
///
/// Cache writes are 1.25× input at the five-minute TTL and 2× at an hour; cache reads are 0.1× of
/// input unless a model says otherwise. `Decimal` rather than `Double`: this arithmetic ends up in
/// front of a person as money.
public struct ClaudePricing: Sendable, Equatable, Hashable {
    public var input: Decimal
    public var output: Decimal
    public var cacheWrite5m: Decimal
    public var cacheWrite1h: Decimal
    public var cacheRead: Decimal

    public init(input: Decimal, output: Decimal,
                cacheWrite5m: Decimal? = nil, cacheWrite1h: Decimal? = nil, cacheRead: Decimal? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m ?? input * Decimal(string: "1.25")!
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.cacheRead = cacheRead ?? input / 10
    }
}
