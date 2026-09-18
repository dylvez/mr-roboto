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
    case toolFinished(name: String, isError: Bool)
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
    /// The turn in flight, so `cancel()` has something to cancel.
    private var inFlight: Task<DirectorTurn, Never>?

    public init(client: ClaudeClient,
                toolbox: DirectorToolbox,
                stage: any DirectorStage,
                pad: DirectorStagePad,
                role: DirectorRole = .judgment,
                persona: String? = nil,
                maxRounds: Int = 12) {
        self.client = client
        self.stage = stage
        self.pad = pad
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
    @MainActor
    public static func live(for app: AppState,
                            client: ClaudeClient = ClaudeClient(),
                            engines: DirectorEngines = DirectorEngines(),
                            audition: (any DirectorAudition)? = nil) -> Director {
        let stage = AppStateStage(app)
        let pad = DirectorStagePad()
        let workbench = DirectorWorkbench(engines: engines)
        let rig = audition ?? DirectorAuditionRig(workbench: workbench,
                                                  service: SurfaceWiring.shared.service(for: app),
                                                  app: app)
        let toolbox = DirectorTools.toolbox(workbench: workbench,
                                            workspace: AppStateWorkspace(app),
                                            audition: rig,
                                            stage: stage,
                                            pad: pad)
        return Director(client: client, toolbox: toolbox, stage: stage, pad: pad)
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
                case .toolFinished(let name, let isError):
                    onEvent?(.toolFinished(name: name, isError: isError))
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
        case .stoppedAtRoundLimit(let rounds):
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
        return DirectorTurn(ending: ending,
                            say: text.isEmpty ? Self.wordless(ending, opened: opened) : text,
                            detail: detail ?? Self.costLine(spend),
                            opened: opened,
                            proposals: offered,
                            calls: calls,
                            spend: spend)
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
