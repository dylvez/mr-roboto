import Foundation

// What a tool is, and how a tool becomes a line in a request.
//
// Two rules hold the whole layer together. Every tool takes and returns small structured data —
// a bar index, a list of slices, a feel's name — and never audio: audio lives on the workbench and
// is referred to by handle. And the tool list is a frozen thing: its order is fixed and its schemas
// are constants encoded through `ClaudeCoding`, so the bytes at position 0 of every request are
// identical from the first call of a session to the last.

/// One capability of the app, as the model sees it.
///
/// `Input` and `Output` are ordinary Codable values, which is the point: a tool's test calls
/// `run(_:)` with a typed input and asserts a typed output, with no model and no JSON anywhere.
public protocol DirectorTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    /// The name the model calls. Stable forever: it is part of the cached prefix.
    var name: String { get }
    /// One or two sentences. What it does and when to reach for it.
    var purpose: String { get }
    /// The JSON Schema for `Input`, written by hand: a constant, never built from session state.
    var schema: DirectorJSON { get }

    func run(_ input: Input) async throws -> Output
}

extension DirectorTool {
    /// The tool as the API wants it.
    public var definition: ClaudeToolDefinition {
        ClaudeToolDefinition(name: name, description: purpose, inputSchema: schema)
    }

    /// Runs the tool from the model's raw arguments. The typed path is `run(_:)`; this is the
    /// bridge the loop uses, and the only place a decode failure can happen.
    public func invoke(arguments: DirectorJSON) async throws -> DirectorJSON {
        let input: Input
        do {
            input = try arguments.decode(Input.self)
        } catch {
            throw ClaudeError.badToolInput(tool: name, reason: Self.reason(for: error))
        }
        let output = try await run(input)
        return try DirectorJSON.parse(try ClaudeCoding.encode(output))
    }

    /// Type erasure, so a toolbox can hold tools of different shapes.
    public func erased() -> AnyDirectorTool {
        AnyDirectorTool(name: name, definition: definition) { arguments in
            try await invoke(arguments: arguments)
        }
    }

    /// A decoding failure said in words a model can act on: which key, and what was wrong.
    static func reason(for error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(Self.path(context)) should be \(type)"
        case .valueNotFound(_, let context):
            return "\(Self.path(context)) was null"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default: return "\(decoding)"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "the arguments" : "\"\(path)\""
    }
}

/// A tool with its types hidden.
public struct AnyDirectorTool: Sendable {
    public let name: String
    public let definition: ClaudeToolDefinition
    private let body: @Sendable (DirectorJSON) async throws -> DirectorJSON

    public init(name: String, definition: ClaudeToolDefinition,
                body: @escaping @Sendable (DirectorJSON) async throws -> DirectorJSON) {
        self.name = name
        self.definition = definition
        self.body = body
    }

    public func invoke(arguments: DirectorJSON) async throws -> DirectorJSON {
        try await body(arguments)
    }
}

/// What a tool says when it cannot do the thing.
///
/// A tool failure is not an app failure: it goes back to the model as a `tool_result` with
/// `is_error`, and the model tries something else. So the message is written for a reader, not
/// for a log.
public struct DirectorToolFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var tool: String
    public var reason: String
    /// What the model could do instead. Optional, and only when there is a real alternative.
    public var suggestion: String?

    public init(tool: String, reason: String, suggestion: String? = nil) {
        self.tool = tool
        self.reason = reason
        self.suggestion = suggestion
    }

    public var description: String {
        suggestion.map { "\(reason) \($0)" } ?? reason
    }
}

// MARK: - The toolbox

/// The app's whole tool surface, in a fixed order.
///
/// The order is the order tools were added, not a sort: the list is authored, and authoring it
/// deliberately is what makes "the tool list never changes mid-session" a thing you can see rather
/// than a thing you hope for. `fingerprint` is what a test asserts against so a careless addition
/// in the middle of the list fails loudly rather than silently costing a session's cache.
public struct DirectorToolbox: Sendable {
    public let tools: [AnyDirectorTool]

    public init(_ tools: [AnyDirectorTool]) { self.tools = tools }

    public var names: [String] { tools.map(\.name) }

    /// The tool list as it goes into a request, with the cache breakpoint on the last one.
    ///
    /// Tools render at position 0, so this marker caches the entire tool list; the system prompt's
    /// own marker then caches tools and system together.
    public var definitions: [ClaudeToolDefinition] {
        var result = tools.map(\.definition)
        if !result.isEmpty { result[result.count - 1].cacheControl = .ephemeral }
        return result
    }

    public func tool(named name: String) -> AnyDirectorTool? {
        tools.first { $0.name == name }
    }

    /// A stable digest of the list: every name and every schema, in order. If this changes between
    /// two releases, every cached prefix in the field is dead, which is worth knowing on purpose.
    public var fingerprint: String {
        let parts = tools.map { tool -> String in
            "\(tool.name):\(tool.definition.inputSchema.jsonText)"
        }
        return parts.joined(separator: "|")
    }

    /// Runs one call and turns whatever happens into a `tool_result`.
    ///
    /// Nothing thrown by a tool escapes here. A tool that fails, a tool that does not exist and a
    /// tool handed unreadable arguments are all answers the model gets to see and respond to —
    /// which is the difference between a band that recovers and a session that dies.
    public func run(_ use: ClaudeToolUse) async -> ClaudeToolResult {
        guard let tool = tool(named: use.name) else {
            return ClaudeToolResult(toolUseID: use.id,
                                    content: "No tool named \"\(use.name)\". Available: \(names.joined(separator: ", ")).",
                                    isError: true)
        }
        do {
            let output = try await tool.invoke(arguments: use.input)
            return ClaudeToolResult(toolUseID: use.id, content: output.jsonText)
        } catch let failure as DirectorToolFailure {
            return ClaudeToolResult(toolUseID: use.id, content: failure.description, isError: true)
        } catch let error as ClaudeError {
            return ClaudeToolResult(toolUseID: use.id, content: error.description, isError: true)
        } catch is CancellationError {
            return ClaudeToolResult(toolUseID: use.id, content: "Cancelled.", isError: true)
        } catch {
            return ClaudeToolResult(toolUseID: use.id, content: "\(error)", isError: true)
        }
    }
}

// MARK: - Schemas

/// A small builder for JSON Schema, so every schema in the app is written the same way and in a
/// fixed key order.
public enum Schema {
    public static func object(_ properties: [(String, DirectorJSON)], required: [String]) -> DirectorJSON {
        var props = DirectorJSONObject()
        for (name, value) in properties { props.members.append(.init(name, value)) }
        return .object([
            .init("type", .string("object")),
            .init("properties", .object(props)),
            .init("required", .array(required.map { .string($0) })),
            // Strict tool use needs this, and it stops the model inventing arguments.
            .init("additionalProperties", .bool(false)),
        ])
    }

    public static func string(_ description: String, enum values: [String]? = nil) -> DirectorJSON {
        var members: [DirectorJSONObject.Member] = [
            .init("type", .string("string")),
            .init("description", .string(description)),
        ]
        if let values { members.append(.init("enum", .array(values.map { .string($0) }))) }
        return .object(DirectorJSONObject(members))
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> DirectorJSON {
        var members: [DirectorJSONObject.Member] = [
            .init("type", .string("integer")),
            .init("description", .string(description)),
        ]
        if let minimum { members.append(.init("minimum", .int(minimum))) }
        if let maximum { members.append(.init("maximum", .int(maximum))) }
        return .object(DirectorJSONObject(members))
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> DirectorJSON {
        var members: [DirectorJSONObject.Member] = [
            .init("type", .string("number")),
            .init("description", .string(description)),
        ]
        if let minimum { members.append(.init("minimum", .double(minimum))) }
        if let maximum { members.append(.init("maximum", .double(maximum))) }
        return .object(DirectorJSONObject(members))
    }

    public static func boolean(_ description: String) -> DirectorJSON {
        .object([.init("type", .string("boolean")), .init("description", .string(description))])
    }

    public static func array(_ description: String, of element: DirectorJSON) -> DirectorJSON {
        .object([
            .init("type", .string("array")),
            .init("description", .string(description)),
            .init("items", element),
        ])
    }

    /// A field the model may omit. Strict tool use requires every property to be listed in
    /// `required`, so optionality is expressed as a nullable type rather than an absent key.
    public static func optional(_ value: DirectorJSON) -> DirectorJSON {
        guard case .object(var object) = value, let type = object["type"]?.stringValue else { return value }
        object["type"] = .array([.string(type), .string("null")])
        return .object(object)
    }
}
