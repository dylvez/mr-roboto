import Foundation

// Server-sent events, turned into something the app can watch, and then into a finished message.
//
// Two halves on purpose. `ClaudeStreamParser` is a pure function from bytes to events — it can be
// fed a fixture by hand and asserted on. `ClaudeMessageBuilder` folds those events into a
// `ClaudeResponse`, and holds the half-built message so that a cancellation can drop it whole.

/// One thing that happened in a streamed reply.
public enum ClaudeStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String, usage: ClaudeUsage)
    case contentBlockStart(index: Int, kind: BlockKind)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case signatureDelta(index: Int, signature: String)
    case inputJSONDelta(index: Int, partial: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, refusal: ClaudeRefusal?, usage: ClaudeUsage)
    case messageStop
    case ping

    public enum BlockKind: Sendable, Equatable {
        case text
        case thinking
        case toolUse(id: String, name: String)
    }
}

/// Bytes in, events out.
public struct ClaudeStreamParser: Sendable {
    private var pending = Data()
    /// The `data:` payloads of the event currently being assembled.
    private var dataLines: [String] = []

    public init() {}

    /// Feeds a chunk and returns whatever events completed. A chunk may be a partial line.
    public mutating func consume(_ chunk: Data) throws -> [ClaudeStreamEvent] {
        pending.append(chunk)
        var events: [ClaudeStreamEvent] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let event = try consume(line: line) { events.append(event) }
        }
        // Keep the tail contiguous so `firstIndex(of:)` stays cheap across many small chunks.
        pending = Data(pending)
        return events
    }

    /// Anything the stream left half-written. Called when the body ends.
    public mutating func finish() throws -> [ClaudeStreamEvent] {
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return try consume(line: line).map { [$0] } ?? []
    }

    private mutating func consume(line: String) throws -> ClaudeStreamEvent? {
        if line.isEmpty {
            // A blank line ends an event. The `event:` name is ignored: the payload carries its
            // own `type`, and trusting one source rather than two is one fewer way to disagree.
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            return try Self.event(from: payload)
        }
        if line.hasPrefix(":") { return nil }                       // a comment; keep-alives arrive as these
        if line.hasPrefix("event:") { return nil }
        if line.hasPrefix("data:") {
            var value = line.dropFirst("data:".count)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            dataLines.append(String(value))
            return nil
        }
        return nil
    }

    // MARK: Payloads

    private struct Envelope: Decodable {
        var type: String
        var index: Int?
        var message: Message?
        var contentBlock: Block?
        var delta: Delta?
        var usage: ClaudeUsage.Wire?
        var error: ErrorPayload?

        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: ClaudeUsage.Wire?
        }

        struct Block: Decodable {
            var type: String
            var id: String?
            var name: String?
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var thinking: String?
            var signature: String?
            var partialJSON: String?
            var stopReason: String?
            var stopDetails: ClaudeRefusal?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature
                case partialJSON = "partial_json"
                case stopReason = "stop_reason"
                case stopDetails = "stop_details"
            }
        }

        struct ErrorPayload: Decodable {
            var type: String
            var message: String
        }

        enum CodingKeys: String, CodingKey {
            case type, index, message, delta, usage, error
            case contentBlock = "content_block"
        }
    }

    static func event(from payload: String) throws -> ClaudeStreamEvent? {
        guard let data = payload.data(using: .utf8) else {
            throw ClaudeError.malformedStream("event payload was not UTF-8")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ClaudeError.malformedStream("could not read an event: \(payload.prefix(120))")
        }

        switch envelope.type {
        case "message_start":
            guard let message = envelope.message else {
                throw ClaudeError.malformedStream("message_start with no message")
            }
            return .messageStart(id: message.id ?? "", model: message.model ?? "",
                                 usage: message.usage?.value ?? .zero)
        case "content_block_start":
            guard let index = envelope.index, let block = envelope.contentBlock else {
                throw ClaudeError.malformedStream("content_block_start with no block")
            }
            switch block.type {
            case "text": return .contentBlockStart(index: index, kind: .text)
            case "thinking": return .contentBlockStart(index: index, kind: .thinking)
            case "tool_use":
                return .contentBlockStart(index: index,
                                          kind: .toolUse(id: block.id ?? "", name: block.name ?? ""))
            case let other:
                throw ClaudeError.malformedStream("unsupported content block \"\(other)\"")
            }
        case "content_block_delta":
            guard let index = envelope.index, let delta = envelope.delta else {
                throw ClaudeError.malformedStream("content_block_delta with no delta")
            }
            switch delta.type {
            case "text_delta": return .textDelta(index: index, text: delta.text ?? "")
            case "thinking_delta": return .thinkingDelta(index: index, text: delta.thinking ?? "")
            case "signature_delta": return .signatureDelta(index: index, signature: delta.signature ?? "")
            case "input_json_delta": return .inputJSONDelta(index: index, partial: delta.partialJSON ?? "")
            case let other:
                throw ClaudeError.malformedStream("unsupported delta \"\(other ?? "none")\"")
            }
        case "content_block_stop":
            guard let index = envelope.index else {
                throw ClaudeError.malformedStream("content_block_stop with no index")
            }
            return .contentBlockStop(index: index)
        case "message_delta":
            return .messageDelta(stopReason: envelope.delta?.stopReason,
                                 refusal: envelope.delta?.stopDetails,
                                 usage: envelope.usage?.value ?? .zero)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            throw ClaudeError.streamError(type: envelope.error?.type ?? "unknown",
                                          message: envelope.error?.message ?? "")
        default:
            // An event type added after this was written. Skipping it is the documented behaviour.
            return nil
        }
    }
}

/// Folds a stream into a finished message.
///
/// The half-built message never leaves this type until `finish()` is called, which is what makes
/// cancellation clean: drop the builder and there is no partial turn anywhere.
public struct ClaudeMessageBuilder: Sendable {
    private enum Partial {
        case text(String)
        case thinking(text: String, signature: String?)
        case toolUse(id: String, name: String, json: String)
    }

    private var blocks: [Int: Partial] = [:]
    private var order: [Int] = []

    public private(set) var id: String = ""
    public private(set) var model: String = ""
    public private(set) var usage: ClaudeUsage = .zero
    public private(set) var stopReasonRaw: String?
    public private(set) var refusal: ClaudeRefusal?
    public private(set) var isComplete = false

    public init() {}

    /// Folds one event in.
    public mutating func accept(_ event: ClaudeStreamEvent) throws {
        switch event {
        case .messageStart(let id, let model, let usage):
            self.id = id
            self.model = model
            // `message_start` carries the input side of the bill; `message_delta` carries output.
            self.usage = usage
        case .contentBlockStart(let index, let kind):
            if blocks[index] == nil { order.append(index) }
            switch kind {
            case .text: blocks[index] = .text("")
            case .thinking: blocks[index] = .thinking(text: "", signature: nil)
            case .toolUse(let id, let name): blocks[index] = .toolUse(id: id, name: name, json: "")
            }
        case .textDelta(let index, let text):
            guard case .text(let existing)? = blocks[index] else {
                throw ClaudeError.malformedStream("text delta for a block that is not text")
            }
            blocks[index] = .text(existing + text)
        case .thinkingDelta(let index, let text):
            guard case .thinking(let existing, let signature)? = blocks[index] else {
                throw ClaudeError.malformedStream("thinking delta for a block that is not thinking")
            }
            blocks[index] = .thinking(text: existing + text, signature: signature)
        case .signatureDelta(let index, let signature):
            guard case .thinking(let text, let existing)? = blocks[index] else {
                throw ClaudeError.malformedStream("signature delta for a block that is not thinking")
            }
            blocks[index] = .thinking(text: text, signature: (existing ?? "") + signature)
        case .inputJSONDelta(let index, let partial):
            guard case .toolUse(let id, let name, let json)? = blocks[index] else {
                throw ClaudeError.malformedStream("input delta for a block that is not a tool call")
            }
            blocks[index] = .toolUse(id: id, name: name, json: json + partial)
        case .contentBlockStop:
            break
        case .messageDelta(let stopReason, let refusal, let usage):
            if let stopReason { stopReasonRaw = stopReason }
            if let refusal { self.refusal = refusal }
            self.usage += usage
        case .messageStop:
            isComplete = true
        case .ping:
            break
        }
    }

    /// The finished message, or a `malformedStream` if the stream ended mid-turn.
    public func finish() throws -> ClaudeResponse {
        guard isComplete else { throw ClaudeError.malformedStream("the reply ended before message_stop") }
        var content: [ClaudeContentBlock] = []
        for index in order {
            switch blocks[index] {
            case .text(let text):
                content.append(.text(ClaudeText(text)))
            case .thinking(let text, let signature):
                content.append(.thinking(ClaudeThinking(thinking: text, signature: signature)))
            case .toolUse(let id, let name, let json):
                // Arguments arrive as text and may be truncated when a turn hits `max_tokens`, so
                // the parse is guarded and a failure names the tool rather than the stream.
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                let source = trimmed.isEmpty ? "{}" : trimmed
                guard let data = source.data(using: .utf8),
                      let input = try? DirectorJSON.parse(data) else {
                    throw ClaudeError.badToolInput(tool: name, reason: "the arguments were not valid JSON")
                }
                content.append(.toolUse(ClaudeToolUse(id: id, name: name, input: input)))
            case nil:
                continue
            }
        }
        return ClaudeResponse(id: id, model: model, content: content,
                              stopReason: ClaudeStopReason(stopReasonRaw ?? "end_turn", details: refusal),
                              usage: usage)
    }

    /// What has been billed so far, whether or not the turn finished. A cancelled turn still costs
    /// what it read, and the ledger is told.
    public var billedSoFar: ClaudeUsage { usage }
}
