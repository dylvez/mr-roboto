import Foundation

// The Messages API as Swift values. Nothing here does any work; it is the shape of what goes out
// and what comes back, written once so the client, the parser and the tests all agree on it.

// MARK: - Cache control

/// A cache breakpoint. Placed on the last block of a stable prefix, never on anything that varies.
public struct ClaudeCacheControl: Sendable, Equatable, Hashable, Encodable {
    public enum TTL: String, Sendable, Equatable, Hashable, Codable {
        case fiveMinutes = "5m"
        case oneHour = "1h"
    }

    public var type: String = "ephemeral"
    public var ttl: TTL

    public init(ttl: TTL = .fiveMinutes) { self.ttl = ttl }

    enum CodingKeys: String, CodingKey { case type, ttl }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        // The five-minute TTL is the default; sending it explicitly is harmless but sending
        // nothing keeps the bytes shorter and matches the documented shape.
        if ttl != .fiveMinutes { try container.encode(ttl, forKey: .ttl) }
    }

    public static let ephemeral = ClaudeCacheControl()
    public static let hour = ClaudeCacheControl(ttl: .oneHour)
}

// MARK: - Content blocks

/// A block of text, optionally carrying a cache breakpoint.
public struct ClaudeText: Sendable, Equatable, Hashable, Codable {
    public var text: String
    public var cacheControl: ClaudeCacheControl?

    public init(_ text: String, cacheControl: ClaudeCacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.cacheControl = nil
    }
}

/// A call the model wants made. `input` is kept as a value rather than a dictionary so echoing the
/// block back on the next turn produces the same bytes it did the first time.
public struct ClaudeToolUse: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var input: DirectorJSON

    public init(id: String, name: String, input: DirectorJSON) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// What a tool returned, handed back in the next user turn.
public struct ClaudeToolResult: Sendable, Equatable, Hashable {
    public var toolUseID: String
    public var content: String
    public var isError: Bool
    public var cacheControl: ClaudeCacheControl?

    public init(toolUseID: String, content: String, isError: Bool = false,
                cacheControl: ClaudeCacheControl? = nil) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
        self.cacheControl = cacheControl
    }
}

/// A thinking block. Echoed back unchanged on the same model; never inspected by this app.
public struct ClaudeThinking: Sendable, Equatable, Hashable {
    public var thinking: String
    public var signature: String?

    public init(thinking: String, signature: String? = nil) {
        self.thinking = thinking
        self.signature = signature
    }
}

/// One block of a message.
public enum ClaudeContentBlock: Sendable, Equatable, Hashable {
    case text(ClaudeText)
    case toolUse(ClaudeToolUse)
    case toolResult(ClaudeToolResult)
    case thinking(ClaudeThinking)

    public static func text(_ text: String, cacheControl: ClaudeCacheControl? = nil) -> ClaudeContentBlock {
        .text(ClaudeText(text, cacheControl: cacheControl))
    }

    /// The plain text of a text block, or nil.
    public var textValue: String? { if case .text(let block) = self { block.text } else { nil } }
    public var toolUseValue: ClaudeToolUse? { if case .toolUse(let use) = self { use } else { nil } }
}

extension ClaudeContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, thinking, signature, content
        case toolUseID = "tool_use_id"
        case isError = "is_error"
        case cacheControl = "cache_control"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let use):
            try container.encode("tool_use", forKey: .type)
            try container.encode(use.id, forKey: .id)
            try container.encode(use.name, forKey: .name)
            try container.encode(use.input, forKey: .input)
        case .toolResult(let result):
            try container.encode("tool_result", forKey: .type)
            try container.encode(result.toolUseID, forKey: .toolUseID)
            try container.encode(result.content, forKey: .content)
            if result.isError { try container.encode(true, forKey: .isError) }
            try container.encodeIfPresent(result.cacheControl, forKey: .cacheControl)
        case .thinking(let block):
            try container.encode("thinking", forKey: .type)
            try container.encode(block.thinking, forKey: .thinking)
            try container.encodeIfPresent(block.signature, forKey: .signature)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(ClaudeText(try container.decode(String.self, forKey: .text)))
        case "tool_use":
            self = .toolUse(ClaudeToolUse(id: try container.decode(String.self, forKey: .id),
                                          name: try container.decode(String.self, forKey: .name),
                                          input: try container.decode(DirectorJSON.self, forKey: .input)))
        case "tool_result":
            self = .toolResult(ClaudeToolResult(toolUseID: try container.decode(String.self, forKey: .toolUseID),
                                                content: try container.decode(String.self, forKey: .content),
                                                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false))
        case "thinking":
            self = .thinking(ClaudeThinking(thinking: try container.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                                            signature: try container.decodeIfPresent(String.self, forKey: .signature)))
        case let other:
            throw ClaudeError.malformedStream("unknown content block type \"\(other)\"")
        }
    }
}

// MARK: - Messages

/// One turn. `system` is the mid-conversation operator channel, not the top-level system prompt.
public struct ClaudeTurn: Sendable, Equatable, Hashable, Codable {
    public enum Role: String, Sendable, Equatable, Hashable, Codable {
        case user, assistant, system
    }

    public var role: Role
    public var content: [ClaudeContentBlock]

    public init(role: Role, content: [ClaudeContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ClaudeTurn { ClaudeTurn(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ClaudeTurn { ClaudeTurn(role: .assistant, content: [.text(text)]) }
    /// An operator instruction that leaves the cached prefix intact. Only on models that take one.
    public static func system(_ text: String) -> ClaudeTurn { ClaudeTurn(role: .system, content: [.text(text)]) }

    enum CodingKeys: String, CodingKey { case role, content }
}

// MARK: - Tools

/// A tool as the API sees it: a name, a sentence, and a schema.
public struct ClaudeToolDefinition: Sendable, Equatable, Hashable, Encodable {
    public var name: String
    public var description: String
    public var inputSchema: DirectorJSON
    /// Guarantees the arguments validate against the schema exactly.
    public var strict: Bool
    public var cacheControl: ClaudeCacheControl?

    public init(name: String, description: String, inputSchema: DirectorJSON,
                strict: Bool = true, cacheControl: ClaudeCacheControl? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey {
        case name, description, strict
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        if strict { try container.encode(true, forKey: .strict) }
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

/// Whether the model may choose a tool, must choose one, or must not.
public enum ClaudeToolChoice: Sendable, Equatable, Hashable, Codable {
    case auto
    case any
    case tool(String)
    case none

    enum CodingKeys: String, CodingKey { case type, name }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try container.encode("auto", forKey: .type)
        case .any: try container.encode("any", forKey: .type)
        case .none: try container.encode("none", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "any": self = .any
        case "none": self = .none
        case "tool": self = .tool(try container.decode(String.self, forKey: .name))
        default: self = .auto
        }
    }

    /// Whether this choice forces a call, which some models reject.
    var isForced: Bool {
        switch self {
        case .any, .tool: true
        case .auto, .none: false
        }
    }
}

// MARK: - Thinking and effort

/// How hard the model thinks, and whether we see a summary of it.
public struct ClaudeThinkingConfig: Sendable, Equatable, Hashable, Encodable {
    public enum Display: String, Sendable, Equatable, Hashable, Codable {
        case omitted, summarized
    }

    public var display: Display

    public init(display: Display = .omitted) { self.display = display }

    enum CodingKeys: String, CodingKey { case type, display }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Adaptive is the only on-mode on every model this app uses. `budget_tokens` is a 400.
        try container.encode("adaptive", forKey: .type)
        try container.encode(display, forKey: .display)
    }
}

/// Token spend and thinking depth within one model.
public enum ClaudeEffort: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case low, medium, high, xhigh, max
}

// MARK: - The request

/// One call to `/v1/messages`.
///
/// The field order here is the order the prompt renders in — tools, then system, then messages —
/// which is also the order of increasing volatility. That is not decoration: it is the whole
/// caching strategy, visible in the type.
public struct ClaudeRequest: Sendable, Equatable {
    public var model: ClaudeModel
    public var maxTokens: Int
    /// The frozen prefix. Blocks here never vary within a session.
    public var system: [ClaudeText]
    /// The frozen tool list. Order is stable; the registry sorts it.
    public var tools: [ClaudeToolDefinition]
    public var toolChoice: ClaudeToolChoice
    public var messages: [ClaudeTurn]
    public var thinking: ClaudeThinkingConfig?
    public var effort: ClaudeEffort?
    public var stream: Bool

    public init(model: ClaudeModel,
                maxTokens: Int = 16000,
                system: [ClaudeText] = [],
                tools: [ClaudeToolDefinition] = [],
                toolChoice: ClaudeToolChoice = .auto,
                messages: [ClaudeTurn],
                thinking: ClaudeThinkingConfig? = ClaudeThinkingConfig(),
                effort: ClaudeEffort? = .high,
                stream: Bool = true) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.messages = messages
        self.thinking = thinking
        self.effort = effort
        self.stream = stream
    }
}

extension ClaudeRequest: Encodable {
    enum CodingKeys: String, CodingKey {
        case model, system, tools, messages, thinking, stream
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
    }

    private struct OutputConfig: Encodable {
        var effort: ClaudeEffort
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model.id, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(stream, forKey: .stream)
        // Fable 5.1 rejects any explicit thinking configuration; it thinks always.
        if let thinking, model.allowsExplicitThinking { try container.encode(thinking, forKey: .thinking) }
        if let effort { try container.encode(OutputConfig(effort: effort), forKey: .outputConfig) }
        if !system.isEmpty { try container.encode(system, forKey: .system) }
        if !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
            if toolChoice != .auto { try container.encode(toolChoice, forKey: .toolChoice) }
        }
        try container.encode(messages, forKey: .messages)
        // Deliberately absent: temperature, top_p, top_k and budget_tokens. All four are 400s on
        // every model in `ClaudeModel`.
    }
}

// MARK: - The response

/// Why the model stopped.
public enum ClaudeStopReason: Sendable, Equatable, Hashable {
    case endTurn
    case maxTokens
    case toolUse
    case pauseTurn
    /// A safety classifier declined. Carries what the API said about it, verbatim.
    case refusal(ClaudeRefusal)
    case other(String)

    init(_ raw: String, details: ClaudeRefusal?) {
        switch raw {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "tool_use": self = .toolUse
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal(details ?? ClaudeRefusal(category: nil, explanation: nil))
        case let other: self = .other(other)
        }
    }

    public var isRefusal: Bool { if case .refusal = self { true } else { false } }
}

/// The `stop_details` of a refusal. Populated only when the stop reason is `refusal`.
public struct ClaudeRefusal: Sendable, Equatable, Hashable, Codable {
    /// An open set: "cyber", "bio", "reasoning_extraction", … or nothing at all.
    public var category: String?
    public var explanation: String?

    public init(category: String?, explanation: String?) {
        self.category = category
        self.explanation = explanation
    }

    /// What the rail says when the band declines. No euphemism, no invented reason.
    public var sentence: String {
        if let explanation, !explanation.isEmpty { return explanation }
        if let category, !category.isEmpty { return "The band declined this one (\(category))." }
        return "The band declined this one."
    }
}

/// A finished assistant turn.
public struct ClaudeResponse: Sendable, Equatable {
    public var id: String
    /// The model that actually served the turn, as reported by the API.
    public var model: String
    public var content: [ClaudeContentBlock]
    public var stopReason: ClaudeStopReason
    public var usage: ClaudeUsage

    public init(id: String, model: String, content: [ClaudeContentBlock],
                stopReason: ClaudeStopReason, usage: ClaudeUsage) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    /// Every text block, joined. The reply as a person would read it.
    public var text: String {
        content.compactMap(\.textValue).joined(separator: "\n")
    }

    /// The calls the model wants made, in order.
    public var toolUses: [ClaudeToolUse] { content.compactMap(\.toolUseValue) }

    /// The turn as it goes back into the conversation. Thinking blocks are kept: on the same model
    /// they must be echoed unchanged.
    public var turn: ClaudeTurn { ClaudeTurn(role: .assistant, content: content) }
}
