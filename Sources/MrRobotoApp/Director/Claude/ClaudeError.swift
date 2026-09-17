import Foundation

/// Everything that can go wrong between the Director and the API, named.
///
/// The point of naming them is the rail: "the band needs a key" and "the band is busy, trying
/// again in four seconds" and "the band declined that one" are three different things to say to a
/// person, and a single `NSError` cannot tell them apart.
public enum ClaudeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No key in the environment and none in the keychain. Not a crash, and not a silent no-op.
    case missingAPIKey
    /// The API answered with a status we cannot use. `retryAfter` is the server's own wait, in
    /// seconds, when it sent one.
    case http(status: Int, type: String, message: String, requestID: String?, retryAfter: TimeInterval? = nil)
    /// Rate limited, and still rate limited after every retry the policy allows.
    case rateLimited(retriesUsed: Int, lastDelay: TimeInterval)
    /// The stream said something the parser does not understand.
    case malformedStream(String)
    /// The stream carried an `error` event partway through.
    case streamError(type: String, message: String)
    /// The transport failed before any status arrived: no network, DNS, TLS.
    case transport(String)
    /// A request this model would reject, caught before it was sent.
    case unsupportedParameter(String)
    /// The model asked for a tool nobody registered.
    case unknownTool(String)
    /// A tool was called with arguments it could not read.
    case badToolInput(tool: String, reason: String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            "The band needs a key. Set ANTHROPIC_API_KEY, or put one in the keychain."
        case .http(let status, let type, let message, let requestID, _):
            "HTTP \(status) \(type): \(message)" + (requestID.map { " (\($0))" } ?? "")
        case .rateLimited(let retries, let delay):
            "Rate limited after \(retries) attempt\(retries == 1 ? "" : "s"); the last wait was \(String(format: "%.1f", delay))s."
        case .malformedStream(let reason):
            "The reply could not be read: \(reason)"
        case .streamError(let type, let message):
            "The reply broke off (\(type)): \(message)"
        case .transport(let reason):
            "Could not reach the API: \(reason)"
        case .unsupportedParameter(let reason):
            "That request would be refused as written: \(reason)"
        case .unknownTool(let name):
            "No tool named \"\(name)\"."
        case .badToolInput(let tool, let reason):
            "\(tool) could not read its arguments: \(reason)"
        }
    }

    /// What a person should be told. The same as `description` for everything but a key, which
    /// deserves a sentence rather than a diagnostic.
    public var sentence: String { description }

    /// The wait the server asked for, in seconds, when it named one.
    public var retryAfter: TimeInterval? {
        if case .http(_, _, _, _, let wait) = self { wait } else { nil }
    }

    /// Whether waiting and trying again could plausibly work.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _, _, _): status == 429 || status == 408 || status == 409 || status >= 500
        case .transport: true
        case .rateLimited, .missingAPIKey, .malformedStream, .streamError,
             .unsupportedParameter, .unknownTool, .badToolInput: false
        }
    }
}

/// The API's own error envelope.
struct ClaudeErrorEnvelope: Decodable {
    struct Payload: Decodable {
        var type: String
        var message: String
    }
    var error: Payload
    var requestID: String?

    enum CodingKeys: String, CodingKey {
        case error
        case requestID = "request_id"
    }

    /// Reads an error body, falling back to the raw text when the body is not the envelope at all
    /// (a proxy's HTML, an empty 502).
    static func read(_ data: Data, status: Int, retryAfter: TimeInterval? = nil) -> ClaudeError {
        if let envelope = try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: data) {
            return .http(status: status, type: envelope.error.type,
                         message: envelope.error.message, requestID: envelope.requestID,
                         retryAfter: retryAfter)
        }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        return .http(status: status, type: "unknown", message: text, requestID: nil, retryAfter: retryAfter)
    }
}
