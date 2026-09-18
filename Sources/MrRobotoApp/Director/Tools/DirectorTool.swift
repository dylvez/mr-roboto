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
    ///
    /// **Not strict**, and that is a measurement rather than a preference. Strict tool use compiles
    /// every schema in the request into one grammar, and this toolbox does not fit in it:
    ///
    ///     400 The compiled grammar is too large, which would cause performance issues.
    ///     Simplify your tool schemas or reduce the number of strict tools.
    ///
    /// Sixteen tools carrying the surface catalog, the lever quantities, the slice classes, the
    /// stem names and the feel library is past the ceiling, and the only two ways under it are
    /// fewer tools or a poorer vocabulary — both of which cost the band something real, and neither
    /// of which buys anything this app was not already doing. Every tool validates its own
    /// arguments and answers a bad one with a `DirectorToolFailure` carrying a suggestion, in the
    /// same round the model made the mistake; `DirectorSurfaceChoice.make` does the same for the
    /// five surface rules. Strict mode was a second opinion on top of that, not the only one.
    public var definition: ClaudeToolDefinition {
        ClaudeToolDefinition(name: name, description: purpose, inputSchema: schema, strict: false)
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
    /// An object schema, with optionality spelled the one way the API accepts.
    ///
    /// Every tool in this app passes *all* of its property names in `required` and marks the ones a
    /// model may leave out with `Schema.optional`. That was written on the assumption — true of
    /// another vendor's strict mode — that strict tool use demands every property be required and
    /// that optionality is therefore a nullable type. It is not true here, and the live API says so:
    ///
    ///     400 Schemas contains too many parameters with union types (27 parameters with type
    ///     arrays or anyOf). This causes exponential compilation cost. Reduce the number of nullable
    ///     or union-typed parameters (limit: 16 parameters with unions).
    ///
    /// Twenty-seven nullable parameters against a ceiling of sixteen, so the toolbox could not be
    /// sent at all. So optionality is resolved here instead: a property marked optional keeps its
    /// plain type and is simply left out of `required`, which is both what the API wants and what
    /// the tools' own `Decodable` inputs already expect — a missing key decodes to nil.
    ///
    /// The call sites do not change. `Schema.optional` is still how a tool says "this one may be
    /// left out", and this is still the one place that decides what that means on the wire.
    public static func object(_ properties: [(String, DirectorJSON)], required: [String]) -> DirectorJSON {
        var props = DirectorJSONObject()
        var demanded: [String] = []
        for (name, value) in properties {
            let (plain, isOptional) = Schema.resolveOptional(value)
            props.members.append(.init(name, plain))
            if required.contains(name), !isOptional { demanded.append(name) }
        }
        return .object([
            .init("type", .string("object")),
            .init("properties", .object(props)),
            .init("required", .array(demanded.map { .string($0) })),
            // Strict tool use needs this, and it stops the model inventing arguments.
            .init("additionalProperties", .bool(false)),
        ])
    }

    /// A property with its optional marker taken off: the plain type, and whether it was marked.
    static func resolveOptional(_ value: DirectorJSON) -> (DirectorJSON, Bool) {
        guard case .object(var object) = value,
              case .array(let types)? = object["type"],
              types.contains(.string("null")),
              let plain = types.first(where: { $0 != .string("null") })?.stringValue else {
            return (value, false)
        }
        object["type"] = .string(plain)
        return (.object(object), true)
    }

    public static func string(_ description: String, enum values: [String]? = nil) -> DirectorJSON {
        var members: [DirectorJSONObject.Member] = [
            .init("type", .string("string")),
            .init("description", .string(description)),
        ]
        if let values { members.append(.init("enum", .array(values.map { .string($0) }))) }
        return .object(DirectorJSONObject(members))
    }

    /// An integer property, with its bounds written into the description rather than as keywords.
    ///
    /// The Messages API rejects `minimum` and `maximum` on an `integer`-typed property — every
    /// request this app sent came back
    /// `400 invalid_request_error: tools.3.custom: For 'integer' type, properties maximum, minimum
    /// are not supported` — and it rejects the *whole request*, so one bounded integer anywhere in
    /// the toolbox means no tool call in the app ever runs. The scripted transport the tool tests
    /// use never saw it, which is exactly the class of bug only a live request finds.
    ///
    /// The bound is not dropped, it is moved: the model reads it in the description, which is where
    /// the same information lives for every other constraint this toolbox expresses. Callers keep
    /// passing `minimum:`/`maximum:` so a later API that supports them is a one-line change here.
    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> DirectorJSON {
        .object(DirectorJSONObject([
            .init("type", .string("integer")),
            .init("description", .string(Schema.bounded(description, minimum: minimum, maximum: maximum))),
        ]))
    }

    /// The description with its range appended, when it has one: "Bar to cut, zero-based. 0 or more."
    static func bounded(_ description: String, minimum: Double?, maximum: Double?) -> String {
        let text = description.hasSuffix(" ") ? description : description + " "
        switch (minimum, maximum) {
        case (let low?, let high?): return text + "\(Schema.figure(low)) to \(Schema.figure(high))."
        case (let low?, nil): return text + "\(Schema.figure(low)) or more."
        case (nil, let high?): return text + "At most \(Schema.figure(high))."
        case (nil, nil): return description
        }
    }

    static func bounded(_ description: String, minimum: Int?, maximum: Int?) -> String {
        bounded(description, minimum: minimum.map(Double.init), maximum: maximum.map(Double.init))
    }

    /// A bound as a person writes it: 4, not 4.0.
    static func figure(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// A number property. Bounded the same way, and for the same reason: the API answers a bounded
    /// `number` with `400 … For 'number' type, property 'minimum' is not supported`.
    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> DirectorJSON {
        .object(DirectorJSONObject([
            .init("type", .string("number")),
            .init("description", .string(Schema.bounded(description, minimum: minimum, maximum: maximum))),
        ]))
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
    ///
    /// An enumerated property has to have `null` added to its *values* as well as to its type: the
    /// API validates the two against each other and answers
    /// `400 … Invalid schema: Enum value 'onsets' does not match declared type ['string', 'null']`
    /// otherwise. Another one the scripted transport could never have found.
    public static func optional(_ value: DirectorJSON) -> DirectorJSON {
        guard case .object(var object) = value, let type = object["type"]?.stringValue else { return value }
        object["type"] = .array([.string(type), .string("null")])
        return .object(object)
    }
}
