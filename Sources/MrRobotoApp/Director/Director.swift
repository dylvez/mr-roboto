import Foundation
import SongGraph

// The Director.
//
// One sentence in, one turn of work out. Everything underneath it already existed: the client
// streams, the conversation loops, the fourteen tools run the engines. What this adds is the two
// ends — a user's sentence at one, and a validated result the frame can apply at the other — plus
// the thing between them that has to be true whatever happens in the middle: **no ending leaves the
// app half-done.**
//
// That is why `direct(_:)` does not throw. A missing key, a refusal, a cancelled turn, a tool that
// failed and a turn that ran out of rounds are five different endings, not five different errors,
// and each of them is a thing to say in the rail. The song graph is append-only, so whatever landed
// before the ending is real and stays; nothing is rolled back because nothing was ever provisional.

/// How a turn ended, and what that means for the app.
public enum DirectorEnding: Sendable, Equatable {
    /// The Director finished. Whatever it opened is open.
    case answered
    /// A safety classifier declined. An answer, with a reason — not a failure.
    case refused(ClaudeRefusal)
    /// The model hit its output ceiling mid-thought. The work it did before that is still real.
    case truncated
    /// The loop ran out of rounds. The transcript is intact and the next turn carries on.
    case roundLimit(rounds: Int)
    /// You pressed escape. Anything already recorded is kept; the reply is dropped.
    case cancelled
    /// There is no API key anywhere. Not pretended around.
    case noKey
    /// Something went wrong between here and the API, in its own words.
    case failed(String)

    /// Whether the band actually said something this turn.
    public var spoke: Bool {
        switch self {
        case .answered, .truncated, .roundLimit, .refused: return true
        case .cancelled, .noKey, .failed: return false
        }
    }

    /// Who the rail attributes the line to. The Director speaks for itself when it spoke; the app
    /// speaks when the app is the one with the news, which is the whole point of two voices.
    public var voice: SessionEntry.Source { spoke ? .director : .session }
}

/// What one turn did.
///
/// Everything the frame needs to apply an answer, and everything a test needs to assert one: the
/// surfaces (already opened, with their bindings), the proposals (validated, and therefore
/// performable), the line for the rail, and the tool names in the order they ran.
public struct DirectorTurn: Sendable, Equatable {
    public var ending: DirectorEnding
    /// What the rail says, attributed to `ending.voice`.
    public var say: String
    /// The quieter second line: what it cost, or why it stopped.
    public var detail: String?
    /// Surfaces this turn opened, in order. Already on the bench by the time you read this.
    public var opened: [DirectorSurfaceChoice]
    /// What the rail now offers. Every one is a validated choice, so every one works when pressed.
    public var proposals: [DirectorProposal]
    /// Tool names in call order — `["read_song", "chop_bar", …]`. The shape of the work.
    public var calls: [String]
    /// The session's ledger after this turn.
    public var spend: ClaudeSpend

    public init(ending: DirectorEnding, say: String, detail: String? = nil,
                opened: [DirectorSurfaceChoice] = [], proposals: [DirectorProposal] = [],
                calls: [String] = [], spend: ClaudeSpend = ClaudeSpend()) {
        self.ending = ending
        self.say = say
        self.detail = detail
        self.opened = opened
        self.proposals = proposals
        self.calls = calls
        self.spend = spend
    }

    /// The surfaces, as the frame's own vocabulary.
    public var actions: [SurfaceAction] { opened.map(\.action) }
}

/// What the rail can watch while a turn is in flight.
public enum DirectorEvent: Sendable {
    /// A piece of the reply, as it arrives. The rail appends these; that is the streaming.
    case say(String)
    case toolStarted(String)
    /// A tool finished. `message` is what it said — for a failure, the reason, which the rail shows.
    /// The five surface rules refuse through this path, and a refusal whose reason never leaves the
    /// loop is the app keeping the most useful thing it knows to itself.
    case toolFinished(name: String, isError: Bool, message: String)
    /// A surface landed on the bench mid-turn.
    case opened(SurfaceKind, title: String)
    case finished(DirectorTurn)
}

/// The tool names of the turn in flight, in the order the loop announced them.
///
/// A lock rather than an actor, and that is the point: the progress callback is synchronous and
/// runs inside the loop's task group, so an actor would mean an unstructured `Task` per call and an
/// order that is no longer the order things happened. Two mutexed appends cost nothing and keep the
/// record exactly true.
final class DirectorCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func append(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        names.append(name)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

// MARK: - The actor

/// One thread of work with the band, wired to a frame.
///
/// An actor for the same reason `ClaudeClient` is: a turn is long, several things watch it, and the
/// transcript and the pad are mutable state that must not be read mid-write. Every method that
/// touches the frame hops to the main actor and hops back.
public actor Director {

    private let client: ClaudeClient
    private let conversation: DirectorConversation
    private let stage: any DirectorStage
    private let pad: DirectorStagePad
    /// The workbench the tools share, when `live` built them around one. Nil for a Director
    /// assembled from a hand-made toolbox. Kept so a test can ask what the band was handed.
    nonisolated let workbench: DirectorWorkbench?
    /// The turn in flight, so `cancel()` has something to cancel.
    private var inFlight: Task<DirectorTurn, Never>?

    public init(client: ClaudeClient,
                toolbox: DirectorToolbox,
                stage: any DirectorStage,
                pad: DirectorStagePad,
                role: DirectorRole = .judgment,
                persona: String? = nil,
                maxRounds: Int = DirectorConversation.defaultMaxRounds,
                workbench: DirectorWorkbench? = nil) {
        self.client = client
        self.stage = stage
        self.pad = pad
        self.workbench = workbench
        self.conversation = DirectorConversation(client: client, toolbox: toolbox, role: role,
                                                 persona: persona, maxRounds: maxRounds)
    }

    /// The Director as the app builds it: one workbench, the frame as both workspace and stage.
    ///
    /// The pad is made here and handed to both the toolbox and the actor, because the two surface
    /// tools write into it and the actor reads it — one object, not a copy on each side.
    ///
    /// The same is now true of the workbench and the audition. `audition` used to default to nil,
    /// which made the `audition` tool honestly report silence in the *running app* as well as in a
    /// test — the band could describe a groove and never play one. The default is the app's own rig,
    /// built around the workbench made here (it has to be the same one: a groove handle only means
    /// something on the workbench that stored it) and the one `AuditionService` every surface
    /// already plays through. Passing an explicit `audition` still wins, which is how a test keeps
    /// its silence.
    ///
    /// And of the engines. They defaulted to `DirectorEngines()`, whose separator is nil, so
    /// `separate_stems` said "no separation model loaded" in a build with Demucs linked and the
    /// weights on disk. The default is now `DirectorEngines.app()`: the registry the Import surface
    /// uses, and its separator — the same instance, so the model is loaded once, on first use.
    @MainActor
    public static func live(for app: AppState,
                            client: ClaudeClient = ClaudeClient(),
                            engines: DirectorEngines = .app(),
                            audition: (any DirectorAudition)? = nil,
                            persona: String? = nil) -> Director {
        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let workbench = DirectorWorkbench(engines: engines)
        let rig = audition ?? DirectorAuditionRig(workbench: workbench,
                                                  service: SurfaceWiring.shared.service(for: app),
                                                  app: app)
        // The persona goes to both ends of the same session: the prompt it works under, and the
        // name it signs with. Passing it to one and not the other is how a band member reads as
        // somebody in the conversation and as nobody in the ledger.
        let toolbox = DirectorTools.toolbox(workbench: workbench,
                                            workspace: AppStateWorkspace(app),
                                            audition: rig,
                                            stage: stage,
                                            pad: pad,
                                            persona: persona)
        return Director(client: client, toolbox: toolbox, stage: stage, pad: pad, persona: persona,
                        workbench: workbench)
    }

    // MARK: Asking

    /// Whether the band can be reached at all. Asked before the first turn, so the rail can say
    /// "the band needs a key" rather than swallowing a sentence and failing at the request.
    public func keyStatus() async -> ClaudeKeyStatus { await client.keyStatus() }

    public func spend() async -> ClaudeSpend { await client.spend }

    /// What the session has spent, as one line. Shown under the composer.
    public func spendLine() async -> String { await client.spend.line }

    /// Turns a sentence into work.
    ///
    /// Never throws. Every way this can end is a `DirectorEnding` with something to say, because the
    /// caller is a text field in a rail and a thrown error there is a crash or a swallowed sentence.
    ///
    /// - Parameter onEvent: called as the reply arrives and as tools run. Text deltas come through
    ///   `.say`, so the rail fills in while the work is happening rather than after it.
    @discardableResult
    public func direct(_ message: String,
                       onEvent: (@Sendable (DirectorEvent) -> Void)? = nil) async -> DirectorTurn {
        let task = Task { await self.run(message, onEvent: onEvent) }
        inFlight = task
        let turn = await task.value
        inFlight = nil
        onEvent?(.finished(turn))
        return turn
    }

    /// Stops the turn in flight. The song graph is append-only, so everything already recorded is
    /// still there and still correct; what is dropped is the reply and the round that was running.
    public func cancel() {
        inFlight?.cancel()
    }

    public var isWorking: Bool { inFlight != nil }

    /// Starts the thread over. The ledger is the client's and survives.
    public func clear() async {
        await conversation.clear()
    }

    // MARK: The turn

    private func run(_ message: String,
                     onEvent: (@Sendable (DirectorEvent) -> Void)?) async -> DirectorTurn {
        let status = await client.keyStatus()
        guard status.hasKey else {
            // Said, not pretended around. Nothing is sent, nothing is opened, and the sentence the
            // user typed is still theirs — the composer keeps it.
            return DirectorTurn(ending: .noKey,
                                say: ClaudeError.missingAPIKey.sentence,
                                detail: "Nothing was sent, and what you typed is still in the box.",
                                spend: await client.spend)
        }

        // A new answer replaces the last one's proposals rather than sitting under them: a control
        // that was right for the previous question is not advice, it is clutter.
        await pad.begin { choice in onEvent?(.opened(choice.surface, title: choice.title)) }
        await MainActor.run { stage.setProposals([]) }

        let log = DirectorCallLog()
        let outcome: DirectorOutcome
        do {
            outcome = try await conversation.ask(message) { progress in
                switch progress {
                case .stream(.textDelta(_, let text)):
                    onEvent?(.say(text))
                case .toolStarted(let name, _):
                    log.append(name)
                    onEvent?(.toolStarted(name))
                case .toolFinished(let name, let isError, let message):
                    onEvent?(.toolFinished(name: name, isError: isError, message: message))
                case .stream, .roundFinished:
                    break
                }
            }
        } catch is CancellationError {
            return await finish(.cancelled, log: log,
                                say: "Stopped.",
                                detail: "Nothing was half-written: anything already recorded is in the song, and the rest was dropped.")
        } catch let error as ClaudeError {
            return await finish(.failed(error.sentence), log: log, say: error.sentence, detail: nil)
        } catch {
            return await finish(.failed("\(error)"), log: log, say: "\(error)", detail: nil)
        }

        switch outcome {
        case .finished(let response):
            return await finish(.answered, log: log, say: response.text, detail: nil)
        case .truncated(let response):
            return await finish(.truncated, log: log, say: response.text,
                                detail: "That reply hit its ceiling mid-thought. Ask again to carry on; nothing was lost.")
        case .refused(let refusal):
            return await finish(.refused(refusal), log: log, say: refusal.sentence, detail: nil)
        case .stoppedAtRoundLimit(let rounds, _):
            // The detail is built in `finish`, where the call log and the pad are both in hand.
            return await finish(.roundLimit(rounds: rounds), log: log, say: outcome.text, detail: nil)
        }
    }

    /// Collects what the turn did and hands the proposals to the rail.
    ///
    /// The one place a turn becomes a result, so there is exactly one place that could leave the app
    /// half-applied — and it applies the pad's contents wholesale, after the loop has stopped.
    private func finish(_ ending: DirectorEnding, log: DirectorCallLog,
                        say: String, detail: String?) async -> DirectorTurn {
        let opened = await pad.opened
        let proposals = await pad.proposals
        let calls = log.calls
        let spend = await client.spend

        // A refused or cancelled turn keeps whatever it opened — those surfaces are real and the
        // versions under them are in the graph — but offers nothing further. Proposing off the back
        // of a turn that did not finish is the band speaking for a conversation that stopped.
        let offered = ending.spoke ? proposals : []
        await MainActor.run { stage.setProposals(offered.map(\.proposal)) }

        let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Self.account(for: ending, calls: calls, opened: opened, proposals: offered)
        return DirectorTurn(ending: ending,
                            say: text.isEmpty ? Self.wordless(ending, opened: opened) : text,
                            detail: detail ?? account ?? Self.costLine(spend),
                            opened: opened,
                            proposals: offered,
                            calls: calls,
                            spend: spend)
    }

    /// The second line for a turn that ran out of rounds: what it did, and what it did not.
    ///
    /// Nil for every other ending. "This went round twelve times without finishing" is a number
    /// about the loop, and the loop is not a thing the user can see or act on; what they can act on
    /// is that the record is loaded, the bar is cut, three reads are recorded and nothing has been
    /// put in front of them yet. Every clause below is read off the call log and the pad — a record
    /// of what actually happened rather than the model's account of it, which is the one version of
    /// this that cannot be wrong about its own work.
    static func account(for ending: DirectorEnding, calls: [String],
                        opened: [DirectorSurfaceChoice], proposals: [DirectorProposal]) -> String? {
        guard case .roundLimit(let rounds) = ending else { return nil }
        let done = Self.did(calls)
        let left = Self.leftToDo(calls, opened: opened, proposals: proposals)
        var line = "It ran out of room after \(rounds) rounds and \(calls.count) tool "
            + "call\(calls.count == 1 ? "" : "s")."
        if !done.isEmpty { line += " Done: \(Self.list(done))." }
        if !left.isEmpty { line += " Not yet: \(Self.list(left))." }
        return line + " Everything already recorded is in the song; say \"carry on\" and it picks up"
            + " from there."
    }

    /// What the calls add up to, in the order the work happened rather than in alphabetical order.
    ///
    /// Counted rather than listed: "played the chop through 4 feels" is the shape of the turn, and
    /// four lines saying "played the chop through a feel" is a log.
    static func did(_ calls: [String]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for call in calls {
            if counts[call] == nil { order.append(call) }
            counts[call, default: 0] += 1
        }
        return order.compactMap { name in Self.phrase(name, counts[name] ?? 1) }
    }

    /// One tool's contribution, in the user's words. Unknown names fall back to the name and a
    /// count, which is honest and never wrong.
    static func phrase(_ tool: String, _ times: Int) -> String? {
        let many = times > 1
        switch tool {
        case "read_song": return "read the song"
        case "import_record": return many ? "loaded \(times) files" : "loaded the record"
        case "analyse_record": return many ? "analysed \(times) of them" : "analysed it"
        case "list_bars": return "found the bars"
        case "separate_stems": return "separated the stems"
        case "chop_bar": return many ? "cut \(times) bars into slices" : "cut the bar into slices"
        case "classify_slices": return "named the slices"
        case "list_feels", "describe_feel": return "looked through the feels"
        case "regroove_chop": return many ? "played it through \(times) feels" : "played it through a feel"
        case "set_swing": return "moved the swing"
        case "set_velocity": return "moved the velocities"
        case "audition": return many ? "listened back \(times) times" : "listened back"
        case "create_part_version":
            return many ? "recorded \(times) versions into the song" : "recorded one version into the song"
        case "degrade_part":
            return many ? "put \(times) parts through a machine" : "put it through a machine"
        case "set_progression": return "wrote the chords down"
        case "write_bassline": return many ? "had the Bassist write \(times) lines" : "had the Bassist write a line"
        case "stitch_section": return many ? "stitched \(times) sections" : "stitched a section"
        case "arrange": return "arranged the form"
        case "read_library": return "read the library"
        case "adopt": return many ? "adopted \(times) library items" : "adopted a library item"
        case "merge": return many ? "merged \(times) pairs" : "merged two fragments"
        case "open_surface": return many ? "opened \(times) surfaces" : "opened a surface"
        case "propose": return many ? "offered \(times) suggestions" : "offered a suggestion"
        default: return many ? "\(tool) ×\(times)" : tool
        }
    }

    /// The gaps, read off the same record. Only things that are certainly outstanding: the Director
    /// cannot know what the model intended next, but it can see that four grooves were made and two
    /// were recorded, and that nothing has reached the bench.
    static func leftToDo(_ calls: [String], opened: [DirectorSurfaceChoice],
                         proposals: [DirectorProposal]) -> [String] {
        var left: [String] = []
        let made = calls.filter { $0 == "regroove_chop" || $0 == "chop_bar" }.count
        let recorded = calls.filter { $0 == "create_part_version" }.count
        if made > recorded {
            let pending = made - recorded
            left.append("\(pending) thing\(pending == 1 ? "" : "s") made but not recorded into the song")
        }
        if opened.isEmpty && proposals.isEmpty {
            left.append(recorded > 0 ? "nothing shown or offered yet, so the work is in the ledger"
                            + " rather than in front of you"
                        : "nothing shown or offered yet")
        }
        return left
    }

    /// A list as a sentence: "a, b and c".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What to say when the model opened something and said nothing about it. Rare, and silence in
    /// the rail beside a new panel is worse than a plain sentence.
    static func wordless(_ ending: DirectorEnding, opened: [DirectorSurfaceChoice]) -> String {
        guard ending.spoke else { return "Nothing came back." }
        guard let first = opened.first else { return "Nothing to show for that one." }
        if opened.count == 1 { return "Opened \(first.surface.rawValue.lowercased()): \(first.title)." }
        return "Opened \(opened.map { $0.surface.rawValue.lowercased() }.joined(separator: " and ")) for you."
    }

    /// The ledger as one quiet line. Nothing when the session has not spent anything yet, because
    /// "$0.00 · 0 turns" under every message is noise rather than honesty.
    static func costLine(_ spend: ClaudeSpend) -> String? {
        spend.turnCount == 0 ? nil : spend.line
    }
}
