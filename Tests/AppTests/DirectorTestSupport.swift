import Analysis
import AVFAudio
import Foundation
import MusicTheory
import Performance
import SongGraph
import Testing

@testable import MrRobotoApp

// What the Director's tests run against instead of the network.
//
// There is no API key in this shell and no network in CI, so every test in this suite injects a
// transport that replays server-sent events written by hand. That is not a compromise: a recorded
// stream is a better test of the parser than a live one, because it can be malformed on purpose.

// MARK: - A transport that replays a script

/// Replays prepared replies, in order, and keeps every request it was given.
actor DirectorScriptedTransport: ClaudeTransport {
    /// One prepared reply.
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        /// The body. For a 200 this is server-sent events; for anything else, an error envelope.
        var body: String
        /// How many bytes to hand over at a time, so a parser that assumes whole lines fails here
        /// rather than in the field. Nil delivers it in one piece.
        var chunkSize: Int?

        static func events(_ body: String, chunkSize: Int? = nil) -> Reply {
            Reply(body: body, chunkSize: chunkSize)
        }

        static func error(status: Int, type: String, message: String,
                          headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers,
                  body: #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_test"}"#)
        }
    }

    private var replies: [Reply]
    private(set) var requests: [ClaudeHTTPRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requestCount: Int { requests.count }

    func request(_ index: Int) -> ClaudeHTTPRequest { requests[index] }

    func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else {
            throw ClaudeError.transport("the script ran out after \(requests.count) request(s)")
        }
        let reply = replies.removeFirst()
        let data = Data(reply.body.utf8)
        let size = reply.chunkSize ?? data.count
        return ClaudeHTTPResponse(status: reply.status, headers: reply.headers,
                                  body: AsyncThrowingStream { continuation in
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                continuation.yield(data[index..<end])
                index = end
            }
            continuation.finish()
        })
    }
}

/// A transport that hands over the start of a reply and then never finishes, so cancellation can
/// be tested at the one moment that matters: mid-stream, with a half-built message in hand.
struct DirectorStallingTransport: ClaudeTransport {
    let prefix: String
    /// Signalled once the prefix has been handed over.
    let started: @Sendable () -> Void

    func send(_ request: ClaudeHTTPRequest) async throws -> ClaudeHTTPResponse {
        let prefix = self.prefix
        let started = self.started
        return ClaudeHTTPResponse(status: 200, body: AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(Data(prefix.utf8))
                started()
                // Long enough that the test's cancellation always wins, short enough that a
                // broken test fails rather than hangs the suite.
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}

/// Records what it was asked to wait for instead of waiting.
actor DirectorRecordingSleeper: ClaudeSleeper {
    private(set) var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws { delays.append(seconds) }
}

// MARK: - Fixtures

/// Server-sent event bodies, written by hand.
enum DirectorSSE {
    static func event(_ type: String, _ payload: String) -> String {
        "event: \(type)\ndata: \(payload)\n\n"
    }

    static func start(id: String = "msg_test", model: String = "claude-opus-5",
                      inputTokens: Int = 1000, cacheRead: Int = 0, cacheCreation: Int = 0) -> String {
        event("message_start", """
            {"type":"message_start","message":{"id":"\(id)","type":"message","role":"assistant",\
            "model":"\(model)","content":[],"usage":{"input_tokens":\(inputTokens),\
            "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),\
            "output_tokens":0}}}
            """)
    }

    static func text(_ body: String, index: Int = 0) -> String {
        event("content_block_start",
              #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
        + event("content_block_delta",
                #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(body)"}}"#)
        + event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
    }

    /// A tool call whose arguments arrive in pieces, as they really do.
    static func toolUse(id: String, name: String, jsonPieces: [String], index: Int = 0) -> String {
        var body = event("content_block_start", """
            {"type":"content_block_start","index":\(index),\
            "content_block":{"type":"tool_use","id":"\(id)","name":"\(name)","input":{}}}
            """)
        for piece in jsonPieces {
            let escaped = piece.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            body += event("content_block_delta", """
                {"type":"content_block_delta","index":\(index),\
                "delta":{"type":"input_json_delta","partial_json":"\(escaped)"}}
                """)
        }
        return body + event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func end(stopReason: String = "end_turn", outputTokens: Int = 40) -> String {
        event("message_delta", """
            {"type":"message_delta","delta":{"stop_reason":"\(stopReason)","stop_sequence":null},\
            "usage":{"output_tokens":\(outputTokens)}}
            """)
        + event("message_stop", #"{"type":"message_stop"}"#)
    }

    static func refusal(category: String, explanation: String) -> String {
        event("message_delta", """
            {"type":"message_delta","delta":{"stop_reason":"refusal",\
            "stop_details":{"type":"refusal","category":"\(category)","explanation":"\(explanation)"}},\
            "usage":{"output_tokens":5}}
            """)
        + event("message_stop", #"{"type":"message_stop"}"#)
    }

    /// A plain reply: one text block, one end.
    static func reply(_ body: String, inputTokens: Int = 1000, outputTokens: Int = 40,
                      cacheRead: Int = 0, cacheCreation: Int = 0) -> String {
        start(inputTokens: inputTokens, cacheRead: cacheRead, cacheCreation: cacheCreation)
            + text(body) + end(outputTokens: outputTokens)
    }
}

// MARK: - A client wired for tests

enum DirectorTestClient {
    static let key = ClaudeFixedKey("sk-ant-test-0123456789")

    static func make(_ replies: [DirectorScriptedTransport.Reply],
                     retry: ClaudeRetryPolicy = .none,
                     sleeper: any ClaudeSleeper = DirectorRecordingSleeper(),
                     keySource: any ClaudeKeySource = DirectorTestClient.key)
        -> (ClaudeClient, DirectorScriptedTransport) {
        let transport = DirectorScriptedTransport(replies)
        let client = ClaudeClient(keySource: keySource, transport: transport,
                                  sleeper: sleeper, retry: retry)
        return (client, transport)
    }

    static func request(_ messages: [ClaudeTurn] = [.user("hello")],
                        model: ClaudeModel = .opus5,
                        tools: [ClaudeToolDefinition] = []) -> ClaudeRequest {
        ClaudeRequest(model: model, system: DirectorPrompt.systemBlocks,
                      tools: tools, messages: messages)
    }
}

// MARK: - Audio a test can make

/// A short synthetic break: a kick, a hat, a snare and a hat, one bar at 90 BPM.
///
/// Real audio, made in the test rather than checked in: the chopper's onset detector and the
/// classifier both run on it for real, and nothing about them is stubbed.
enum DirectorAudioFixture {
    static let sampleRate: Double = 48_000
    static let tempo: Double = 90

    /// One bar, four hits on the beat.
    static func bar() -> [[Float]] {
        let barLength = 4 * 60 / tempo
        let frames = Int(barLength * sampleRate)
        var left = [Float](repeating: 0, count: frames)
        let beat = frames / 4
        write(&left, at: 0, kick())
        write(&left, at: beat, hat())
        write(&left, at: beat * 2, snare())
        write(&left, at: beat * 3, hat())
        return [left, left]
    }

    /// Four bars of the same, so there is something to find bars in.
    static func fourBars() -> [[Float]] {
        let one = bar()
        return one.map { channel in Array(repeating: channel, count: 4).flatMap { $0 } }
    }

    /// Writes a temporary WAV and returns its URL. The caller deletes the directory.
    static func write(_ planar: [[Float]], named name: String = "fixture.wav") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MrRobotoDirectorTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try ChopAudio.writeWAV(planar, to: url, sampleRate: sampleRate)
        return url
    }

    // A low sine that decays fast: bright enough to be a kick and nothing else.
    private static func kick() -> [Float] { tone(frequency: 60, seconds: 0.18, decay: 22) }
    // Noise with a short tail: a snare.
    private static func snare() -> [Float] { noise(seconds: 0.14, decay: 26, highpass: 0.45) }
    // Very short, very bright: a hat.
    private static func hat() -> [Float] { noise(seconds: 0.035, decay: 140, highpass: 0.88) }

    private static func tone(frequency: Double, seconds: Double, decay: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            return Float(sin(2 * .pi * frequency * t) * exp(-decay * t) * 0.9)
        }
    }

    /// Deterministic noise, one-pole high-passed so the classifier sees a real centroid.
    private static func noise(seconds: Double, decay: Double, highpass: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        var generator = SeededRandom(seed: 0x9E37_79B9_7F4A_7C15)
        var previous: Double = 0
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let white = Double(generator.next() % 2000) / 1000 - 1
            let filtered = white - highpass * previous
            previous = white
            output[index] = Float(filtered * exp(-decay * t) * 0.8)
        }
        return output
    }

    private static func write(_ buffer: inout [Float], at offset: Int, _ hit: [Float]) {
        for (index, sample) in hit.enumerated() where offset + index < buffer.count {
            buffer[offset + index] += sample
        }
    }
}

// MARK: - Analysis providers that need no model

/// A beat tracker that answers with a perfect grid. Stands in for Apple's Music Understanding,
/// which needs a real framework session and is not what a tool test is testing.
struct DirectorStubBeatTracker: BeatTracker {
    let providerName = "stub-beats"
    var bpm: Double = DirectorAudioFixture.tempo
    var bars: Int = 4

    func trackBeats(url: URL) async throws -> BeatTrackingResult {
        let grid = BeatGrid.regular(bpm: bpm, bars: bars)
        return BeatTrackingResult(beats: grid.beats, downbeats: grid.bars, bpm: bpm)
    }
}

/// A separator that hands back the input as one "drums" stem.
struct DirectorStubSeparator: StemSeparator {
    let providerName = "stub-separator"
    var models: [StemSeparationModel] { [StemSeparationModel(name: "stub", stems: [.drums])] }

    func separate(_ input: StemSeparationInput, options: StemSeparationOptions,
                  progress: @escaping StemSeparationProgress) async throws -> StemSeparationResult {
        progress(1)
        guard case .file(let url) = input else {
            throw AnalysisError.unsupportedAsset(URL(fileURLWithPath: "/"), reason: "buffers only in the real one")
        }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AnalysisError.unsupportedAsset(url, reason: "no buffer")
        }
        try file.read(into: buffer)
        return StemSeparationResult(model: "stub",
                                    stems: [Stem(name: .drums, buffer: AVReadOnlyAudioPCMBuffer(copying: buffer))],
                                    wallTime: 0.01)
    }
}

/// Engines wired for a test: real chopper, real classifier, real feels, stubbed analysis.
enum DirectorTestEngines {
    static func make(bars: Int = 4, separator: (any StemSeparator)? = DirectorStubSeparator()) -> DirectorEngines {
        var providers = AnalysisProviders()
        providers.register(DirectorStubBeatTracker(bars: bars), for: [.beats])
        return DirectorEngines(providers: providers, separator: separator)
    }
}

/// Nothing to play on, said out loud. What every automated shell gets.
@MainActor
final class DirectorSilentAudition: DirectorAudition {
    private(set) var requests: [DirectorAuditionRequest] = []

    func audition(_ request: DirectorAuditionRequest) async -> DirectorAuditionOutcome {
        requests.append(request)
        return .silent
    }
}

// MARK: - A song to record into

enum DirectorSongFixture {
    static func song() -> Song {
        Song(title: "Arrival", artist: "Test", tempo: DirectorAudioFixture.tempo)
    }
}
