import Foundation

// The one place this app touches the network, and the seam every test injects through.
//
// The client above knows nothing about URLSession: it builds a `ClaudeHTTPRequest`, hands it to a
// transport and reads back a status and a byte stream. That is what makes the streaming parser,
// the tool loop, the backoff and the cancellation path all testable without a key or a network.

/// A request, as bytes and headers. Its `description` redacts the key, so it can be logged.
public struct ClaudeHTTPRequest: Sendable, Equatable, CustomStringConvertible {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String = "POST", headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// Headers with anything secret replaced. The only form of this request that is ever printed.
    public var redactedHeaders: [String: String] {
        var copy = headers
        for key in copy.keys where Self.secretHeaders.contains(key.lowercased()) {
            copy[key] = "(redacted)"
        }
        return copy
    }

    static let secretHeaders: Set<String> = ["x-api-key", "authorization", "proxy-authorization"]

    public var description: String {
        "\(method) \(url.path) \(redactedHeaders.keys.sorted().joined(separator: ", ")) \(body.count) bytes"
    }

    /// The body decoded back into a value. Tests assert the request shape through this.
    public func decodedBody<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    /// The body as a tree, for assertions that do not want a type.
    public func bodyJSON() throws -> DirectorJSON { try DirectorJSON.parse(body) }
}

/// A response: a status, headers, and a body that arrives in pieces.
public struct ClaudeHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A response whose body is already in hand.
    public init(status: Int, headers: [String: String] = [:], data: Data) {
        self.init(status: status, headers: headers, body: AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }

    /// Case-insensitive header lookup: HTTP header names are not case-sensitive and URLSession's
    /// capitalisation is not guaranteed.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Collects the whole body. Used for errors, never for a successful stream.
    public func collect() async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return data
    }
}

/// Whoever actually makes the call.
public protocol ClaudeTransport: Sendable {
    func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse
}

/// The real transport.
///
/// `URLSession.bytes(for:)` rather than `data(for:)`: a streamed reply has to be readable while it
/// is still arriving, and cancelling the surrounding task has to tear the connection down rather
/// than leave it running in the background spending tokens.
public struct URLSessionClaudeTransport: ClaudeTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ClaudeError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.transport("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }

        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    // Bytes are regrouped into lines here so the SSE parser is handed whole lines
                    // and never has to own a partial-UTF8 buffer.
                    //
                    // Split by hand rather than with `bytes.lines`, and the reason is the whole
                    // protocol: `AsyncLineSequence` drops empty lines, and in server-sent events the
                    // empty line *is* the delimiter — it is what says one event has ended. Fed from
                    // `.lines`, the parser saw every `data:` payload and never a blank line, so it
                    // accumulated the entire reply and emitted nothing, and every turn ended as
                    // "the reply ended before message_stop". No offline test could see it: the
                    // scripted transport hands the parser the bytes it was written with, blank lines
                    // and all.
                    var line = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        line.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }
                        continuation.yield(line)
                        line.removeAll(keepingCapacity: true)
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ClaudeError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return ClaudeHTTPResponse(status: http.statusCode, headers: headers, body: stream)
    }
}
