import Foundation
import MusicTheory
import Performance
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
    /// The reason as well as the name. A run that only reported which tools failed could not tell
    /// a refusal by one of the five surface rules — which is the instrument working — from a bug.
    func finished(_ name: String, isError: Bool, message: String) {
        guard isError else { return }
        lock.lock(); failures.append("\(name): \(message)"); lock.unlock()
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
            case .toolFinished(let name, let isError, let message):
                log.finished(name, isError: isError, message: message)
            case .opened(let kind, let title): log.opened(kind, title)
            case .say, .finished: break
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        report("turn 1 ending", "\(turn.ending)")
        report("turn 1 elapsed", String(format: "%.1f s", elapsed))
        report("turn 1 calls", log.calls.isEmpty ? "(none)" : log.calls.joined(separator: " → "))
        report("turn 1 tool failures", log.errors.isEmpty ? "(none)" : "")
        for failure in log.errors { report("  failed", failure) }
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
                case .toolFinished(let name, let isError, let message):
                    carry.finished(name, isError: isError, message: message)
                case .opened(let kind, let title): carry.opened(kind, title)
                case .say, .finished: break
                }
            }
            report("turn 1b ending", "\(more.ending)")
            report("turn 1b elapsed", String(format: "%.1f s", Date().timeIntervalSince(resumed)))
            report("turn 1b calls", carry.calls.isEmpty ? "(none)" : carry.calls.joined(separator: " → "))
            report("turn 1b tool failures", carry.errors.isEmpty ? "(none)" : "")
            for failure in carry.errors { report("  failed", failure) }
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

    /// M2's proof line, word for word.
    static let bassLine = "Give me a bass line under this, laid back like Pino"

    @Test("the M2 line: a bass line under the groove, live")
    func bassLineLive() async throws {
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let arrival = try #require(state.library.songs.first { $0.title == "Arrival" })
        state.openSong(arrival.id)
        // A groove to sit under, in memory only: the boom-bap pocket at the song's own tempo.
        if state.song.map({ Guidance.grooves(in: $0).isEmpty }) ?? true {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            #expect(state.record(PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                             operation: Operation.written, note: "Boom-Bap Pocket")))
        }
        let band = try #require(state.band)
        try #require(await band.director.keyStatus().hasKey, "no API key")

        let log = LiveTurnLog()
        let started = Date()
        let turn = await band.director.direct(Self.bassLine) { event in
            switch event {
            case .toolStarted(let name): log.started(name)
            case .toolFinished(let name, let isError, let message): log.finished(name, isError: isError, message: message)
            case .opened(let kind, let title): log.opened(kind, title)
            case .say, .finished: break
            }
        }
        report("bass ending", "\(turn.ending)")
        report("bass elapsed", String(format: "%.1f s", Date().timeIntervalSince(started)))
        report("bass calls", log.calls.joined(separator: " → "))
        for failure in log.errors { report("  failed", failure) }
        report("bass opened", log.opens.joined(separator: " · "))
        report("bass said", turn.say)
        describeSpend(turn.spend, label: "bass turn")

        let lines = (state.song?.versions ?? []).filter { $0.type == .bassline }
        report("bass lines written", "\(lines.count)")
        for line in lines {
            report("  line", "\(line.author) — \(line.note ?? "")")
        }
        for item in state.bench.items {
            report("surface", "\(item.kind.rawValue) \"\(item.title)\" ← "
                + state.bound(for: item.id).map { describe($0, in: state) }.joined(separator: ", "))
            report("  levers", state.levers(for: item.id).map(\.line).joined(separator: " · "))
            if item.kind == .compare, case .ready(let model) = SurfaceWiring.shared.compareFilling(for: item, app: state) {
                report("  compare", "reference \"\(model.reference.title)\" + \(model.candidates.count) candidates, "
                    + "\(model.features.count) columns, \(model.levers.count) levers")
                for candidate in model.candidates {
                    report("    candidate", "\(candidate.title) — " + candidate.readings.map { "\($0.key) \(String(format: "%.2f", $0.value.value))" }.sorted().joined(separator: ", "))
                }
            }
        }
        for entry in state.log.suffix(16) {
            report("  rail [\(entry.source.label)]", entry.text + (entry.detail.map { " — \($0)" } ?? ""))
        }
        #expect(turn.ending == .answered)
        #expect(!lines.isEmpty, "no bass line was written")
        #expect(lines.allSatisfy { $0.author == .persona("Bassist") })
        #expect(log.opens.contains { $0.hasPrefix("Compare") || $0.hasPrefix("Piano roll") })
        report("saved", "no — the run is in memory only")
    }

    /// M2 Gate C's proof line, word for word.
    static let formLine = "Make this a two-minute song"

    @Test("the Gate C line: a two-minute form the transport plays, live")
    func formLive() async throws {
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let arrival = try #require(state.library.songs.first { $0.title == "Arrival" })
        state.openSong(arrival.id)
        // Something to arrange, in memory only: the boom-bap pocket and a Palladino line under it.
        if state.song.map({ Guidance.grooves(in: $0).isEmpty }) ?? true {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            #expect(state.record(PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                             operation: Operation.written, note: "Boom-Bap Pocket")))
        }
        if let song = state.song, Guidance.basslines(in: song).isEmpty,
           let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
            let key = Guidance.analysis(in: song)?.dominantKey ?? song.key ?? Key(tonic: NoteName(.d))
            let request = BassRequest(key: key, chords: [], groove: groove, tempo: song.tempo,
                                      timeSignature: song.timeSignature, lineage: .palladino, lagMS: 40,
                                      density: 0.4, sound: "finger", seed: 1)
            #expect(state.record(PartVersion(partID: PartID(), kind: .bassline(BassWriter.write(request)),
                                             author: .persona("Bassist"), parents: [grooveVersion.id],
                                             operation: Operation.written, note: "Palladino line, +40 ms")))
        }
        let band = try #require(state.band)
        try #require(await band.director.keyStatus().hasKey, "no API key")
        report("song", "\(state.song?.title ?? "") · \(state.song?.tempo ?? 0) bpm · \(state.song?.timeSignature.description ?? "") · "
            + "\(state.song?.sections.count ?? 0) sections before")

        let log = LiveTurnLog()
        let started = Date()
        let turn = await band.director.direct(Self.formLine) { event in
            switch event {
            case .toolStarted(let name): log.started(name)
            case .toolFinished(let name, let isError, let message): log.finished(name, isError: isError, message: message)
            case .opened(let kind, let title): log.opened(kind, title)
            case .say, .finished: break
            }
        }
        report("form ending", "\(turn.ending)")
        report("form elapsed", String(format: "%.1f s", Date().timeIntervalSince(started)))
        report("form calls", log.calls.joined(separator: " → "))
        for failure in log.errors { report("  failed", failure) }
        report("form opened", log.opens.joined(separator: " · "))
        report("form said", turn.say)
        describeSpend(turn.spend, label: "form turn")

        let song = try #require(state.song)
        let seconds = Double(song.lengthInBars * song.timeSignature.beatsPerBar) * 60 / song.tempo
        report("sections after", "\(song.sections.count) · \(song.lengthInBars) bars · \(String(format: "%.0f", seconds)) s")
        for section in song.sections {
            report("  section", "\(section.name) \(section.lengthInBars) bars ← "
                + (state.song.map { song in song.versions(playing: section).map { describe($0.id, in: state) } } ?? [])
                    .joined(separator: ", "))
        }
        let plan = state.playback
        report("plan", "\(plan.summary) · arranged \(plan.isArranged) · playable \(plan.isPlayable) · "
            + "\(plan.segments.filter(\.isSounding).count) of \(plan.segments.count) segments sound")
        for entry in state.log.suffix(12) {
            report("  rail [\(entry.source.label)]", entry.text + (entry.detail.map { " — \($0)" } ?? ""))
        }
        #expect(turn.ending == .answered)
        #expect(!song.sections.isEmpty, "no sections were arranged")
        #expect(plan.isArranged && plan.isPlayable, "the transport has no form to play")
        #expect(abs(seconds - 120) <= 15, "the form is \(seconds) s, not two minutes")
        #expect(log.opens.contains { $0.hasPrefix("Structure") })
        report("saved", "no — the run is in memory only")
    }

    // MARK: M4 Gate C, P13 — the room convened, live

    static let roomLine = "Is this verse working?"

    /// Arrival as it is, arranged if it is not, with the Producer, the Engineer and the Peer in the
    /// room. One turn: the Director convenes, three personas are heard in their own units, and the
    /// disagreement (if one shows) is a Compare. In memory only; cost reported.
    @Test("M4 P13: \"Is this verse working?\" — one turn, three personas in their own units, cost reported")
    func roomLive() async throws {
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let arrival = try #require(state.library.songs.first { $0.title == "Arrival" })
        state.openSong(arrival.id)
        if state.song.map({ Guidance.grooves(in: $0).isEmpty }) ?? true {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            #expect(state.record(PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                             operation: Operation.written, note: "Boom-Bap Pocket")))
        }
        if let song = state.song, Guidance.basslines(in: song).isEmpty,
           let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
            let key = Guidance.analysis(in: song)?.dominantKey ?? song.key ?? Key(tonic: NoteName(.d))
            let request = BassRequest(key: key, chords: [], groove: groove, tempo: song.tempo,
                                      timeSignature: song.timeSignature, lineage: .palladino, lagMS: 40,
                                      density: 0.4, sound: "finger", seed: 1)
            #expect(state.record(PartVersion(partID: PartID(), kind: .bassline(BassWriter.write(request)),
                                             author: .persona("Bassist"), parents: [grooveVersion.id],
                                             operation: Operation.written, note: "Palladino line, +40 ms")))
        }
        if let song = state.song, song.sections.isEmpty {
            let stitch = [Guidance.grooves(in: song).last, Guidance.basslines(in: song).last].compactMap { $0 }.lanes
            #expect(state.arrange([Section(name: "Verse", stitch: stitch, lengthInBars: 16),
                                   Section(name: "Hook", stitch: stitch, lengthInBars: 8)]))
        }
        #expect(state.setCast([.producer, .engineer, .peer]))
        let band = try #require(state.band)
        try #require(await band.director.keyStatus().hasKey, "no API key")
        report("song", "\(state.song?.title ?? "") · \(state.song?.tempo ?? 0) bpm · "
            + "\(state.song?.sections.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " | ") ?? "") · cast \(state.song?.cast ?? [])")

        let log = LiveTurnLog()
        let started = Date()
        let turn = await band.director.direct(Self.roomLine) { event in
            switch event {
            case .toolStarted(let name): log.started(name)
            case .toolFinished(let name, let isError, let message): log.finished(name, isError: isError, message: message)
            case .opened(let kind, let title): log.opened(kind, title)
            case .say, .finished: break
            }
        }
        report("room ending", "\(turn.ending)")
        report("room elapsed", String(format: "%.1f s", Date().timeIntervalSince(started)))
        report("room calls", log.calls.joined(separator: " → "))
        for failure in log.errors { report("  failed", failure) }
        report("room opened", log.opens.joined(separator: " · "))
        report("room said", turn.say)
        describeSpend(turn.spend, label: "room turn")

        let personas = state.log.compactMap { entry -> (String, String)? in
            if case .persona(let name) = entry.source { return (name, entry.text) }
            return nil
        }
        for (name, text) in personas { report("  \(name)", text) }
        let compares = state.bench.items.filter { $0.kind == .compare }
        for item in compares {
            report("compare", item.title)
            if case .compare(let brief)? = state.answer(for: item.id) {
                report("  against", "\(brief.reference.title) — \(brief.reference.kind)")
                for candidate in brief.candidates { report("  row", "\(candidate.title): \(candidate.rationale)") }
            }
        }
        #expect(turn.ending == .answered)
        #expect(log.calls.contains("convene"), "the Director did not convene the room")
        let heard = Set(personas.map(\.0))
        #expect(heard.isSuperset(of: ["Peer", "Producer", "Engineer"]), "heard: \(heard)")
        #expect(!turn.say.isEmpty)
        report("saved", "no — the run is in memory only")
    }

    // MARK: M6 X9 — the Engineer's hands, live

    static let mixLines = ["The bass is fighting the kick", "Master it"]

    /// Arrival as it is, arranged if it is not, two turns: the Engineer reads the mix, makes one
    /// move, then sets the master. Two mix versions in the song; cost reported. In memory only.
    @Test("M6 X9: the bass is fighting the kick; master it — two turns, the Engineer in dB and Hz, cost reported")
    func mixLive() async throws {
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let arrival = try #require(state.library.songs.first { $0.title == "Arrival" })
        state.openSong(arrival.id)
        if state.song.map({ Guidance.grooves(in: $0).isEmpty }) ?? true {
            let feel = try #require(FeelLibrary.standard.feel(named: "Boom-Bap Pocket"))
            #expect(state.record(PartVersion(partID: PartID(), kind: .groove(feel.groove), author: .user,
                                             operation: Operation.written, note: "Boom-Bap Pocket")))
        }
        if let song = state.song, Guidance.basslines(in: song).isEmpty,
           let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
            let key = Guidance.analysis(in: song)?.dominantKey ?? song.key ?? Key(tonic: NoteName(.d))
            let request = BassRequest(key: key, chords: [], groove: groove, tempo: song.tempo,
                                      timeSignature: song.timeSignature, lineage: .palladino, lagMS: 40,
                                      density: 0.4, sound: "finger", seed: 1)
            #expect(state.record(PartVersion(partID: PartID(), kind: .bassline(BassWriter.write(request)),
                                             author: .persona("Bassist"), parents: [grooveVersion.id],
                                             operation: Operation.written, note: "Palladino line, +40 ms")))
        }
        if let song = state.song, song.sections.isEmpty {
            let stitch = [Guidance.grooves(in: song).last, Guidance.basslines(in: song).last].compactMap { $0 }.lanes
            #expect(state.arrange([Section(name: "Verse", stitch: stitch, lengthInBars: 8), Section(name: "Hook", stitch: stitch, lengthInBars: 8)]))
        }
        let band = try #require(state.band)
        try #require(await band.director.keyStatus().hasKey, "no API key")
        let before = Guidance.mixes(in: state.song!).count
        report("song", "\(state.song?.title ?? "") · \(state.song?.tempo ?? 0) bpm · \(before) mix versions before")

        for line in Self.mixLines {
            let log = LiveTurnLog()
            let started = Date()
            let turn = await band.director.direct(line) { event in
                switch event {
                case .toolStarted(let name): log.started(name)
                case .toolFinished(let name, let isError, let message): log.finished(name, isError: isError, message: message)
                case .opened(let kind, let title): log.opened(kind, title)
                case .say, .finished: break
                }
            }
            report("line", line)
            report("  ending", "\(turn.ending)")
            report("  elapsed", String(format: "%.1f s", Date().timeIntervalSince(started)))
            report("  calls", log.calls.joined(separator: " → "))
            for failure in log.errors { report("  failed", failure) }
            report("  opened", log.opens.joined(separator: " · "))
            report("  said", turn.say)
            describeSpend(turn.spend, label: "  turn")
            #expect(turn.ending == .answered)
        }
        let song = try #require(state.song)
        for version in Guidance.mixes(in: song).dropFirst(before) {
            report("mix version", version.note ?? "")
        }
        #expect(Guidance.mixes(in: song).count >= before + 1, "no mix version was made")
        for entry in state.log.suffix(14) {
            report("  rail [\(entry.source.label)]", entry.text + (entry.detail.map { " — \($0)" } ?? ""))
        }
        report("saved", "no — the run is in memory only")
    }

    // MARK: M7 L6 — the record, live

    static let albumLines = ["Put the record in order", "Release it"]

    /// The first album in the library that holds two or more songs: two turns, the Producer and
    /// the Peer heard on the record, a folder on disk. The order change is in memory only; the
    /// release writes to ~/Music/Mr. Roboto/Exports/<album>.
    @Test("M7 L6: put the record in order; release it — two turns, a folder on disk, cost reported")
    func albumLive() async throws {
        let state = AppState.live()
        let registry = SurfaceRegistry()
        SurfaceRegistry.registerSurfaces(in: registry)
        let album = try #require(state.library.albums.first { $0.songs.count >= 2 }, "no album with two songs in the library")
        state.openSong(album.songs[0])
        let band = try #require(state.band)
        try #require(await band.director.keyStatus().hasKey, "no API key")
        report("album", "\(album.title) · \(album.songs.count) tracks · \(album.songs.compactMap { state.library.song($0)?.title }.joined(separator: " → "))")
        for line in Self.albumLines {
            let log = LiveTurnLog()
            let started = Date()
            let turn = await band.director.direct(line) { event in
                switch event {
                case .toolStarted(let name): log.started(name)
                case .toolFinished(let name, let isError, let message): log.finished(name, isError: isError, message: message)
                case .opened(let kind, let title): log.opened(kind, title)
                case .say, .finished: break
                }
            }
            report("line", line)
            report("  ending", "\(turn.ending)")
            report("  elapsed", String(format: "%.1f s", Date().timeIntervalSince(started)))
            report("  calls", log.calls.joined(separator: " → "))
            for failure in log.errors { report("  failed", failure) }
            report("  said", turn.say)
            describeSpend(turn.spend, label: "  turn")
            #expect(turn.ending == .answered)
        }
        if let after = state.library.album(album.id) {
            report("order after", after.songs.compactMap { state.library.song($0)?.title }.joined(separator: " → "))
            for (id, release) in after.releases { report("  released", "\(state.library.song(id)?.title ?? "?") · \(String(format: "%.1f LUFS · %.1f dBTP", release.integratedLUFS, release.truePeakDBTP))") }
        }
        for entry in state.log.suffix(12) {
            report("  rail [\(entry.source.label)]", entry.text + (entry.detail.map { " — \($0)" } ?? ""))
        }
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
