import Foundation
import SongGraph
import SwiftUI
import Testing

@testable import MrRobotoApp

// The milestone's own acceptance line, against the real API and the real library.
//
// **Disabled by default.** Nothing in the shipped suite may need a key or a network, so this whole
// suite is gated on `MRROBOTO_LIVE=1`:
//
//     MRROBOTO_LIVE=1 swift test --filter BandLive
//
// Without that variable the condition trait skips every test in here before any of them touches a
// client, which is why the suite can sit in `AppTests` beside 1,000 offline tests rather than in a
// harness nobody runs. The key is found the way the app finds it — the environment first, then the
// login keychain under `com.mrroboto.anthropic` / `api-key` — and is never printed.
//
// What it is for is the one thing no scripted test can check: whether the band, given a sentence,
// calls the tools in an order that makes sense, opens the surfaces the five rules say it should,
// binds them to versions the song actually holds, and reads its own cached prefix on the second
// turn. It prints a report rather than asserting on the model's judgement — a test that failed
// because Opus chose a different feel would be a test of the weather.

/// A lock-protected record of what a turn did, since the event callback is `@Sendable` and arrives
/// from the conversation's own task group.
final class LiveTurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var toolOrder: [String] = []
    private var failures: [String] = []
    private var surfaces: [String] = []

    func started(_ name: String) { lock.lock(); toolOrder.append(name); lock.unlock() }
    func finished(_ name: String, isError: Bool) {
        guard isError else { return }
        lock.lock(); failures.append(name); lock.unlock()
    }
    func opened(_ kind: SurfaceKind, _ title: String) {
        lock.lock(); surfaces.append("\(kind.rawValue): \(title)"); lock.unlock()
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return toolOrder }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    var opens: [String] { lock.lock(); defer { lock.unlock() }; return surfaces }
}

@Suite("Band: the live acceptance line", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MRROBOTO_LIVE"] == "1",
                "set MRROBOTO_LIVE=1 to run the one test that costs money"))
@MainActor
struct BandLiveTests {

    /// The milestone's acceptance line, word for word.
    static let acceptance = "Chop the drums from bar 9 and give me something slower and dustier"

    /// A second, short turn. Its only job is the measurement nobody has been able to take without a
    /// key: `cache_read_input_tokens > 0` on the second request of a session is the ground truth
    /// that the frozen prefix is actually being read rather than merely being written.
    static let followUp = "Which of those is closest to what the record already does?"

    /// The bytes the API is actually sent. Costs nothing and reaches nothing, but it lives in the
    /// gated suite because it exists for the same reason the gated suite does: the schemas are the
    /// part of this app the offline tests can only check for *stability*, never for *validity*.
    @Test("the tool schemas, as the API receives them")
    func toolSchemas() throws {
        let state = AppState.live()
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(),
                                            workspace: AppStateWorkspace(state),
                                            stage: AppStateStage(state),
                                            pad: DirectorStagePad())
        for (index, definition) in toolbox.definitions.enumerated() {
            let data = try ClaudeCoding.encode(definition)
            report("tools.\(index)", String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// The raw stream, for when the parser and the API disagree about what a reply looks like.
    /// Costs one short request.
    @Test("the raw reply, event by event", .disabled("a probe: enable by hand when the parser and the API disagree"))
    func rawStream() async throws {
        let state = AppState.live()
        let toolbox = DirectorTools.toolbox(workbench: DirectorWorkbench(),
                                            workspace: AppStateWorkspace(state),
                                            stage: AppStateStage(state),
                                            pad: DirectorStagePad())
        let request = ClaudeRequest(model: .opus5, maxTokens: 16000,
                                    system: DirectorPrompt.systemBlocks,
                                    tools: toolbox.definitions,
                                    messages: [.user(Self.acceptance)],
                                    thinking: ClaudeThinkingConfig(),
                                    effort: .high)
        let key = try #require(ClaudeCredentials().apiKey())
        let http = try await ClaudeClient(keySource: ClaudeFixedKey(key)).build(request, key: key)
        let response = try await URLSessionClaudeTransport().send(http)
        report("status", "\(response.status)")
        var parser = ClaudeStreamParser()
        var builder = ClaudeMessageBuilder()
        var chunks = 0
        do {
            for try await chunk in response.body {
                chunks += 1
                for event in try parser.consume(chunk) {
                    report("  event", "\(event)".prefix(160).description)
                    try builder.accept(event)
                }
            }
            for event in try parser.finish() {
                report("  tail event", "\(event)".prefix(160).description)
                try builder.accept(event)
            }
            let message = try builder.finish()
            report("  parsed", "stop \(message.stopReason) · \(message.toolUses.count) tool uses · \(chunks) chunks")
        } catch {
            report("  PARSE FAILED", "after \(chunks) chunks: \(error)")
        }
    }

    @Test("the acceptance line, end to end, against the seeded song")
    func acceptanceLine() async throws {
        // The app's own state, over the app's own library. Not a fixture: the point is the seeded
        // Arrival with its four separated stems.
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)

        let arrival = try #require(state.library.songs.first { $0.title == "Arrival" },
                                   "the seeded song is not in ~/Library/Application Support/MrRoboto/Library")
        state.openSong(arrival.id)
        let song = try #require(state.song)
        report("song", "\(song.title) · \(song.tempo) bpm · \(song.versions.count) versions")
        for version in song.versions {
            report("  version", "\(version.id.description.prefix(8)) \(version.type.rawValue) "
                + "\(version.operation) — \(version.note ?? "")")
        }

        let band = try #require(state.band, "AppState.live() attached no band")
        let status = await band.director.keyStatus()
        try #require(status.hasKey, "no API key in the environment or the keychain")
        report("key", status.sentence)

        // Turn one.
        let log = LiveTurnLog()
        let started = Date()
        let turn = await band.director.direct(Self.acceptance) { event in
            switch event {
            case .toolStarted(let name): log.started(name)
            case .toolFinished(let name, let isError): log.finished(name, isError: isError)
            case .opened(let kind, let title): log.opened(kind, title)
            case .say, .finished: break
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        report("turn 1 ending", "\(turn.ending)")
        report("turn 1 elapsed", String(format: "%.1f s", elapsed))
        report("turn 1 calls", log.calls.isEmpty ? "(none)" : log.calls.joined(separator: " → "))
        report("turn 1 tool failures", log.errors.isEmpty ? "(none)" : log.errors.joined(separator: ", "))
        report("turn 1 said", turn.say)
        describeSpend(turn.spend, label: "turn 1")

        // A turn that ran out of rounds is not a failure and is not lost: the transcript is
        // committed and the design's own answer is to ask again. So the run does what the app tells
        // the user to do, and the report says how many rounds the whole line actually took.
        if case .roundLimit = turn.ending {
            let carry = LiveTurnLog()
            let resumed = Date()
            let more = await band.director.direct("Carry on.") { event in
                switch event {
                case .toolStarted(let name): carry.started(name)
                case .toolFinished(let name, let isError): carry.finished(name, isError: isError)
                case .opened(let kind, let title): carry.opened(kind, title)
                case .say, .finished: break
                }
            }
            report("turn 1b ending", "\(more.ending)")
            report("turn 1b elapsed", String(format: "%.1f s", Date().timeIntervalSince(resumed)))
            report("turn 1b calls", carry.calls.isEmpty ? "(none)" : carry.calls.joined(separator: " → "))
            report("turn 1b tool failures", carry.errors.isEmpty ? "(none)" : carry.errors.joined(separator: ", "))
            report("turn 1b opened", carry.opens.isEmpty ? "(none)" : carry.opens.joined(separator: " · "))
            report("turn 1b said", more.say)
            describeSpend(more.spend, label: "after turn 1b")
        }

        // What landed on the bench, and what each surface is actually bound to.
        for item in state.bench.items {
            let bound = state.bound(for: item.id)
            report("surface", "\(item.kind.rawValue) \"\(item.title)\" ← "
                + (bound.isEmpty ? "nothing" : bound.map { describe($0, in: state) }.joined(separator: ", ")))
            report("  levers", state.levers(for: item.id).map(\.line).joined(separator: " · "))
            report("  resolves", registry.resolve(item, app: state).isPlaceholder ? "PLACEHOLDER" : "a real surface")
            if item.kind == .compare {
                switch SurfaceWiring.shared.compareFilling(for: item, app: state) {
                case .ready(let model):
                    report("  compare", "reference \"\(model.reference.title)\" + "
                        + "\(model.candidates.count) candidates, \(model.features.count) columns, "
                        + "\(model.levers.count) levers")
                    for candidate in model.candidates {
                        report("    candidate", "\(candidate.title) — \(candidate.rationale)")
                    }
                    report("  indistinguishable", "\(model.indistinguishable.count) of \(model.candidates.count)")
                case .unfilled(_, let reason):
                    report("  compare", "UNFILLED: \(reason)")
                }
            }
            if item.kind == .check {
                switch SurfaceWiring.shared.checkFilling(for: item, app: state) {
                case .finding(let model): report("  check", "finding: \(model.title)")
                case .stated(_, let text, _): report("  check", "stated: \(text)")
                case .unfilled(_, let reason): report("  check", "UNFILLED: \(reason)")
                }
            }
        }
        for proposal in state.proposals {
            report("proposal", "[\(proposal.source.label)] \(proposal.title) → "
                + "\(proposal.action.surface.rawValue) — \(proposal.rationale)")
        }
        report("versions after", "\(state.song?.versions.count ?? 0)")
        for version in (state.song?.versions ?? []).suffix(4) {
            report("  made", "\(version.type.rawValue) \(version.operation) · \(version.author) — "
                + "\(version.note ?? "")")
        }
        // The rail, which is what the user would actually have read.
        for entry in state.log.suffix(24) {
            report("  rail [\(entry.source.label)]", entry.text
                + (entry.detail.map { " — \($0)" } ?? ""))
        }

        // Turn two: the cache measurement.
        let secondStarted = Date()
        let second = await band.director.direct(Self.followUp)
        report("turn 2 ending", "\(second.ending)")
        report("turn 2 elapsed", String(format: "%.1f s", Date().timeIntervalSince(secondStarted)))
        report("turn 2 said", second.say)
        describeSpend(second.spend, label: "session after turn 2")

        // The ground truth. The prefix is meant to be read from the second request onwards; the
        // first one writes it. Recorded rather than asserted hard, because a cache entry can expire
        // between two slow turns and that is the API's behaviour rather than this app's bug.
        let entries = second.spend.entries
        let readAfterFirst = entries.dropFirst().contains { $0.usage.cacheReadTokens > 0 }
        report("cache", readAfterFirst
            ? "READ — the frozen prefix is being served from cache"
            : "NOT READ — every request paid full price for the prefix")
        // A write is only expected on a *cold* prefix. Two runs inside the same five minutes and the
        // first request reads an entry an earlier run wrote, which is the cache working rather than
        // failing — so the check is that the prefix was either written or read, never neither.
        #expect(entries.contains { $0.usage.cacheCreationTokens > 0 || $0.usage.cacheReadTokens > 0 },
                "no request wrote or read a cache entry, so the prefix is not cacheable at all")
        #expect(readAfterFirst, "no request after the first read the cached prefix")

        // Nothing is saved: this is an exercise, not an edit the user asked for.
        report("saved", "no — the run is in memory only")
    }

    // MARK: Reporting

    private func describe(_ id: VersionID, in state: AppState) -> String {
        guard let version = state.version(id) else { return "\(id.description.prefix(8)) (missing!)" }
        return "\(version.type.rawValue) \(id.description.prefix(8))"
    }

    private func describeSpend(_ spend: ClaudeSpend, label: String) {
        report("\(label) round trips", "\(spend.turnCount)")
        report("\(label) cost", ClaudeSpend.money(spend.total))
        let usage = spend.usage
        report("\(label) tokens",
               "in \(usage.inputTokens) · out \(usage.outputTokens) · "
                   + "cache write \(usage.cacheCreationTokens) · cache read \(usage.cacheReadTokens) · "
                   + "\(Int((usage.cacheHitRate * 100).rounded()))% of the prompt cached")
        for (index, entry) in spend.entries.enumerated() {
            report("  request \(index + 1)",
                   "\(entry.outcome.rawValue) · in \(entry.usage.inputTokens) "
                       + "· write \(entry.usage.cacheCreationTokens) "
                       + "· read \(entry.usage.cacheReadTokens) "
                       + "· out \(entry.usage.outputTokens) "
                       + "· \(ClaudeSpend.money(entry.cost))")
        }
    }

    private func report(_ key: String, _ value: String) {
        print("[live] \(key.padding(toLength: max(key.count, 24), withPad: " ", startingAt: 0)) \(value)")
    }
}
