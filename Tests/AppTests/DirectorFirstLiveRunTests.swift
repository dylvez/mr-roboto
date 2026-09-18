import Analysis
import Foundation
import MusicTheory
import SongGraph
import Testing

@testable import MrRobotoApp

// The four things the first run against the real API found, each held down by a test that would
// have failed before it was fixed.
//
// None of them needs a key or a network, and that is the point rather than a convenience: three of
// the four were *decisions* the app had made — a round budget, an author, a discarded message —
// and a decision is exactly the kind of thing a scripted test can pin. Only the fourth needed the
// live run to be *noticed*; once noticed it reproduces offline in a second, which is why the stub
// below throws the same error Apple's Music Understanding throws for a drums stem.

// MARK: - Analysers that answer the way the live ones did

/// A key estimator that ran and found nothing, which is what Music Understanding does with a drums
/// stem: there is no tonal content in it, so there is no key in it, and the estimator says so by
/// throwing `missingResult` rather than by returning a guess.
struct DirectorSilentKeyEstimator: KeyEstimator {
    let providerName = "stub-no-key"
    func estimateKey(url: URL) async throws -> KeyEstimate {
        throw AnalysisError.missingResult(.key, provider: providerName)
    }
}

/// A key estimator that actually broke. Told apart from the one above on purpose: "this audio has
/// no key" is a finding and "the file is not there" is a failure, and an aggregate that cannot tell
/// them apart either throws away four good analyses or hides a broken one.
struct DirectorBrokenKeyEstimator: KeyEstimator {
    let providerName = "stub-broken"
    func estimateKey(url: URL) async throws -> KeyEstimate {
        throw AnalysisError.fileNotFound(url)
    }
}

@Suite("Director: what the first live run found")
@MainActor
struct DirectorFirstLiveRunTests {

    // MARK: 1 — the round budget

    @Test("The round budget fits the acceptance line rather than half of it")
    func budgetFitsTheWork() {
        // The measured shape of "chop the drums from bar 9 and give me something slower and
        // dustier": about twenty-three calls, and the model does not batch most of them. Twelve
        // could not finish it once; the budget has to clear it with room to recover.
        #expect(DirectorConversation.defaultMaxRounds >= 23,
                "the acceptance line takes about 23 calls and the budget must clear it")
        #expect(DirectorConversation.defaultMaxRounds == 32)
    }

    @Test("A Director built the app's way gets the whole budget")
    func directorTakesTheDefault() async {
        let (client, _) = DirectorTestClient.make([])
        let conversation = DirectorConversation(client: client, toolbox: DirectorToolbox([]))
        #expect(await conversation.maxRounds == DirectorConversation.defaultMaxRounds)
    }

    // MARK: 1b — and says what it did when it stops

    @Test("The round limit accounts for the work, not for the loop")
    func roundLimitSaysWhatItDid() throws {
        let calls = ["read_song", "import_record", "analyse_record", "list_bars", "chop_bar",
                     "classify_slices", "regroove_chop", "regroove_chop", "regroove_chop",
                     "create_part_version"]
        let line = try #require(Director.account(for: .roundLimit(rounds: 32), calls: calls,
                                                 opened: [], proposals: []))
        // The work, in the user's words and counted rather than listed.
        #expect(line.contains("read the song"))
        #expect(line.contains("cut the bar into slices"))
        #expect(line.contains("played it through 3 feels"))
        #expect(line.contains("recorded one version into the song"))
        // The gaps, read off the same record: three reads made, one recorded, nothing shown.
        #expect(line.contains("3 things made but not recorded"))
        #expect(line.contains("nothing shown or offered yet"))
        // And the number, in the place where a number belongs.
        #expect(line.contains("32 rounds"))
        #expect(line.contains("10 tool calls"))
        #expect(line.contains("carry on"))
    }

    @Test("A turn that finished has no account to give")
    func noAccountForAnEndingThatWorked() {
        for ending in [DirectorEnding.answered, .truncated, .cancelled, .noKey] {
            #expect(Director.account(for: ending, calls: ["read_song"], opened: [], proposals: []) == nil,
                    "\(ending) is not a turn that ran out of room")
        }
    }

    @Test("A turn that ran out of rounds having shown something does not claim it showed nothing")
    func accountKnowsWhatReachedTheBench() throws {
        let app = AppState(library: Library(), song: nil, store: nil,
                           status: .empty(FileManager.default.temporaryDirectory),
                           transportHost: StubTransportHost())
        app.open(Song(title: "Arrival", tempo: 90))
        let version = PartVersion(partID: PartID(), kind: .groove(Groove(patterns: [])),
                                  author: .persona("Director"),
                                  operation: Operation.regroove, note: "One read.")
        _ = app.record(version)
        let choice = try DirectorSurfaceChoice.make(surface: .grid, title: "Bar 9",
                                                    fill: .parts([version.id]), levers: [],
                                                    because: "A groove is a grid.",
                                                    in: AppStateStage(app))
        let line = try #require(Director.account(for: .roundLimit(rounds: 32),
                                                 calls: ["regroove_chop", "create_part_version", "open_surface"],
                                                 opened: [choice], proposals: []))
        #expect(line.contains("opened a surface"))
        #expect(!line.contains("nothing shown or offered"), "something did reach the bench: \(line)")
    }

    // MARK: 2 — the band signs its work

    @Test("A version the model signed nobody for is the Director's, never the user's")
    func unsignedWorkIsTheBands() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(withGroove: true)
        defer { rig.clean() }
        let tool = CreatePartVersionTool(workbench: rig.workbench, workspace: rig.workspace)

        for persona in [nil, "", "   "] as [String?] {
            let output = try await tool.run(.init(from: rig.groove, note: "Slower.",
                                                  persona: persona, parent: nil))
            #expect(output.author == "Director",
                    "persona \(persona.map { "\"\($0)\"" } ?? "nil") must not sign as the user")
            #expect(output.author != Author.user.description)
        }
    }

    @Test("A version the model did sign keeps that name")
    func namedWorkKeepsItsName() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(withGroove: true)
        defer { rig.clean() }
        let tool = CreatePartVersionTool(workbench: rig.workbench, workspace: rig.workspace)
        let output = try await tool.run(.init(from: rig.groove, note: "Dustier.",
                                              persona: "Sampler", parent: nil))
        #expect(output.author == "Sampler")
    }

    @Test("A persona-scoped session signs with its own name without the model doing anything")
    func aPersonaSignsItsOwnWork() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(withGroove: true)
        defer { rig.clean() }
        let tool = CreatePartVersionTool(workbench: rig.workbench, workspace: rig.workspace,
                                         acting: "Beatmaker")
        let output = try await tool.run(.init(from: rig.groove, note: "On the pocket.",
                                              persona: nil, parent: nil))
        #expect(output.author == "Beatmaker")
        let song = try #require(rig.workspace.song)
        #expect(song.versions.last?.author == .persona("Beatmaker"))
        #expect(song.versions.allSatisfy { $0.author.isPersona }, "nothing the band made is the user's")
    }

    @Test("The acting persona stays out of the frozen prefix")
    func signingDoesNotMoveTheCachedBytes() throws {
        let plain = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                          workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song()),
                                          audition: DirectorSilentAudition())
        let signed = DirectorTools.toolbox(workbench: DirectorWorkbench(engines: DirectorTestEngines.make()),
                                           workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song()),
                                           audition: DirectorSilentAudition(),
                                           persona: "Beatmaker")
        // Who signs is a fact about `run`, not about the schema. If it ever reached the schema,
        // every persona in the app would be paying for its own copy of the tool list.
        #expect(plain.fingerprint == signed.fingerprint)
    }

    // MARK: 3 — a refusal reaches the user with its reason

    @Test("A tool failure carries its reason out of the loop")
    func toolFailureCarriesItsReason() async throws {
        let (client, _) = DirectorTestClient.make([
            .events(DirectorSSE.start()
                    + DirectorSSE.toolUse(id: "t1", name: "chop_bar",
                                          jsonPieces: [#"{"audio":"audio-9","bar":0,"start_seconds":null,"end_seconds":null,"method":"onsets","division":4}"#])
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("Nothing is loaded yet.")),
        ])
        let rig = try await DirectorFirstLiveRunTests.rig()
        defer { rig.clean() }
        let toolbox = DirectorTools.toolbox(workbench: rig.workbench, workspace: rig.workspace,
                                            audition: DirectorSilentAudition())
        let conversation = DirectorConversation(client: client, toolbox: toolbox)
        let watcher = DirectorFirstLiveRunTests.Watcher()
        _ = try await conversation.ask("chop bar one") { watcher.record($0) }

        let failure = try #require(watcher.failures.first)
        #expect(failure.tool == "chop_bar")
        #expect(failure.reason.contains("audio-9"), "the reason, not just the name: \(failure.reason)")
    }

    @Test("The rail says which call was refused and what it was refused for")
    func theRailSaysWhy() {
        let line = DirectorSession.refusals([
            .init(tool: "open_surface",
                  reason: "A Compare needs the thing its candidates are judged against. "
                      + "Pass `reference`: what the song already has, which stays at the top."),
            .init(tool: "propose", reason: "\"Waveform\" is not a surface in the catalog."),
        ])
        #expect(line.contains("open_surface — A Compare needs the thing its candidates are judged against."))
        #expect(line.contains("propose — "))
        // The suggestion to the model is not the user's business; the reason is.
        #expect(!line.contains("Pass `reference`"))
    }

    @Test("The same refusal twice is one line, because it is one mistake")
    func repeatedRefusalsAreOneLine() {
        let same = DirectorSession.Stumble(tool: "open_surface", reason: "A Compare needs a reference.")
        #expect(DirectorSession.refusals([same, same]) == "open_surface — A Compare needs a reference.")
    }

    @Test("The reason reaches the rail end to end, under the band's own answer")
    func theReasonReachesTheRail() async {
        let rig = DirectorEndingTests.rig([
            .events(DirectorSSE.start()
                    + DirectorSSE.toolUse(id: "t1", name: "open_surface",
                                          jsonPieces: [#"{"surface":"Compare","title":"Three reads","bound":[],"reference":null,"finding":null,"because":"Three ways of hearing bar 9.","levers":[]}"#])
                    + DirectorSSE.end(stopReason: "tool_use")),
            .events(DirectorSSE.reply("I need something to judge them against first.")),
        ])
        defer { rig.clean() }

        await DirectorEndingTests.send(rig, "compare those")

        let last = rig.app.log.last
        #expect(last?.source == .session)
        #expect(last?.text.contains("failed on the way") == true)
        let detail = last?.detail ?? ""
        #expect(detail.contains("open_surface"))
        // Rule 4, doing its job, in words the user can learn the instrument from.
        #expect(detail.contains("judged against"), "the rail should carry the reason: \(detail)")
    }

    // MARK: 4 — analyse_record on a stem

    @Test("A record with no key in it still analyses, and says there is no key in it")
    func analysingAStemWithNoKey() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(keys: DirectorSilentKeyEstimator())
        defer { rig.clean() }

        let imported = try await ImportRecordTool(workbench: rig.workbench, workspace: rig.workspace)
            .run(.init(path: rig.url.path))
        let output = try await AnalyseRecordTool(workbench: rig.workbench).run(.init(audio: imported.audio))

        // The one that used to fail the whole call. A drums stem has no tonal content; that is a
        // finding about the music, and the beat grid underneath it is exactly what the chop needs.
        #expect(output.key == nil)
        #expect(output.barCount > 0, "the grid survived the missing key")
        #expect(output.tempo != nil)
        #expect(output.notes.contains { $0.contains("no key") }, "it says so: \(output.notes)")
        #expect(!output.analysers.contains("stub-no-key"), "a capability with no result is not claimed")
    }

    @Test("Everything after it can still use the analysis")
    func theGridIsKeptForTheToolsAfterIt() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(keys: DirectorSilentKeyEstimator())
        defer { rig.clean() }
        let imported = try await ImportRecordTool(workbench: rig.workbench, workspace: rig.workspace)
            .run(.init(path: rig.url.path))
        _ = try await AnalyseRecordTool(workbench: rig.workbench).run(.init(audio: imported.audio))

        let bars = try await ListBarsTool(workbench: rig.workbench)
            .run(.init(audio: imported.audio, fromBar: 0, count: 4))
        #expect(bars.bars.count == 4, "list_bars works off an analysis that found no key")
    }

    @Test("An analyser that actually broke still fails the call")
    func abrokenAnalyserIsStillAFailure() async throws {
        let rig = try await DirectorFirstLiveRunTests.rig(keys: DirectorBrokenKeyEstimator())
        defer { rig.clean() }
        let imported = try await ImportRecordTool(workbench: rig.workbench, workspace: rig.workspace)
            .run(.init(path: rig.url.path))
        await #expect(throws: DirectorToolFailure.self) {
            _ = try await AnalyseRecordTool(workbench: rig.workbench).run(.init(audio: imported.audio))
        }
    }

    // MARK: - The rig

    struct Rig {
        var workbench: DirectorWorkbench
        var workspace: DirectorScratchWorkspace
        var url: URL
        var directory: URL
        /// A groove handle, ready to be recorded into the song.
        var groove: String = ""

        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Four bars of synthetic break, a library to store it in, a song to record into, and — where a
    /// test asks for one — an analyser that answers the way the live one did.
    static func rig(keys: (any KeyEstimator)? = nil, withGroove: Bool = false) async throws -> Rig {
        let url = try DirectorAudioFixture.write(DirectorAudioFixture.fourBars(), named: "break.wav")
        let library = url.deletingLastPathComponent().appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var engines = DirectorTestEngines.make()
        if let keys { engines.providers.register(keys, for: [.key]) }
        var rig = Rig(workbench: DirectorWorkbench(engines: engines),
                      workspace: DirectorScratchWorkspace(song: DirectorSongFixture.song(),
                                                          store: LibraryStore(directoryURL: library)),
                      url: url,
                      directory: url.deletingLastPathComponent())
        guard withGroove else { return rig }

        // The real chain, on real audio: import, analyse, cut, name, re-groove. Nothing here is
        // stubbed except the beat tracker, so the handle the attribution tests record is a handle
        // to something the engines actually made.
        let audio = try await ImportRecordTool(workbench: rig.workbench, workspace: rig.workspace)
            .run(.init(path: url.path)).audio
        _ = try await AnalyseRecordTool(workbench: rig.workbench).run(.init(audio: audio))
        let chop = try await ChopBarTool(workbench: rig.workbench)
            .run(.init(audio: audio, bar: 1, startSeconds: nil, endSeconds: nil,
                       method: .onsets, division: 4)).chop
        _ = try await ClassifySlicesTool(workbench: rig.workbench).run(.init(chop: chop, overrides: nil))
        rig.groove = try await RegrooveChopTool(workbench: rig.workbench)
            .run(.init(chop: chop, feel: "Boom-Bap", tempo: 90, bars: 2, overlap: nil, rotate: nil)).groove
        return rig
    }

    /// Records the failures a turn produced, with their reasons.
    final class Watcher: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [DirectorSession.Stumble] = []

        func record(_ progress: DirectorConversation.Progress) {
            guard case .toolFinished(let name, let isError, let message) = progress, isError else { return }
            lock.lock()
            defer { lock.unlock() }
            seen.append(DirectorSession.Stumble(tool: name, reason: message))
        }

        var failures: [DirectorSession.Stumble] { lock.lock(); defer { lock.unlock() }; return seen }
    }
}
