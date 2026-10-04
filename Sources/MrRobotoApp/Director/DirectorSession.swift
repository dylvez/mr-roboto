import Foundation
import Observation

// The composer, and what it is attached to.
//
// `Director` is an actor and knows nothing about SwiftUI. This is the object the rail binds to: the
// text you are typing, whether a turn is in flight, the reply as it arrives, what the session has
// spent, and whether there is a key at all. It owns exactly one rule, and the rule is why it exists
// as its own type rather than as three `@State` variables in a view: **every ending puts the app
// back in the same state it was in before you pressed return**, with the log one line longer.

/// A thread-safe accumulator for a reply that is still arriving.
///
/// The stream is delivered in order from the client's actor, but getting it onto the main actor
/// means one hop per delta and hops are not ordered. So the rail is handed a *snapshot* rather than
/// a delta, and only ever takes a longer one — text that has arrived cannot un-arrive, and the
/// authoritative sentence lands at the end of the turn regardless.
final class DirectorReplyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ piece: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        value += piece
        return value
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The band, as the conversation rail sees it.
@MainActor
@Observable
public final class DirectorSession {

    /// What you are typing. Bound to the composer.
    public var composing: String = ""

    /// Who the next message is for. Empty is everyone in the room. Cleared after each send unless kept.
    public var addressed: Set<PersonaID> = []
    /// Keep the same members for the messages that follow.
    public var keepsAddressing = false

    /// The members in the room for the open song, in the order they answer.
    public var room: [(id: PersonaID, name: String)] {
        Cast.standard.inRoom(for: app?.song).personas.map { ($0.bible.id, $0.bible.name) }
    }

    /// Set when a surface asks for its member: the composer takes focus and the field is theirs.
    /// The rail takes it, so it fires once.
    public var wantsFocus = false

    /// A surface's "Ask": this member only, the rail open, the field ready. A member the song's
    /// cast has left out of the room is not addressed, and the message goes to everyone.
    public func ask(_ id: PersonaID) {
        addressed = room.contains(where: { $0.id == id }) ? [id] : []
        wantsFocus = true
    }

    public func toggleAddressed(_ id: PersonaID) {
        if addressed.contains(id) { addressed.remove(id) } else { addressed.insert(id) }
        // Everyone chosen is everyone: the same as nobody chosen.
        if addressed.count == room.count { addressed = [] }
    }

    /// Who a message is for: the chips, plus anyone named with an at sign ("@engineer", "@Eng").
    /// Only members in the room count. Empty means everyone.
    nonisolated static func addressees(in text: String, chips: Set<PersonaID>, room: [(id: PersonaID, name: String)]) -> [PersonaID] {
        var chosen = chips
        for word in text.split(whereSeparator: { $0.isWhitespace }) where word.hasPrefix("@") && word.count > 2 {
            let handle = word.dropFirst().lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let match = room.first(where: { $0.id.rawValue.hasPrefix(handle) || $0.name.lowercased().hasPrefix(handle) }) { chosen.insert(match.id) }
        }
        let ordered = room.map(\.id).filter { chosen.contains($0) }
        return ordered.count == room.count ? [] : ordered
    }

    /// What the Director is sent: the user's words, and on a line of its own who they are for.
    nonisolated static func addressedText(_ text: String, to ids: [PersonaID]) -> String {
        ids.isEmpty ? text : text + "\n\nAsked of: " + ids.map(\.rawValue).joined(separator: ", ")
    }

    /// True from pressing return to the turn ending, whichever way it ends.
    public private(set) var isWorking = false

    /// The reply so far. Empty when nothing is in flight; the rail draws it as a Director line at
    /// the bottom of the log and replaces it with the real entry when the turn lands.
    public private(set) var streaming = ""

    /// What it is doing right now — "reading the song", "cutting the bar" — or nil.
    public private(set) var activity: String?

    /// Whether there is a key. Read at launch so the composer can say the honest thing *before*
    /// you have typed a sentence and lost it.
    public private(set) var keyStatus: ClaudeKeyStatus = .missing

    /// What this session has spent, as one line, or nil before the first turn.
    public private(set) var spendLine: String?

    /// The model the band runs on, as the rail shows it.
    public private(set) var model: ClaudeModel
    @ObservationIgnored private let models: DirectorModelChoice

    @ObservationIgnored public let director: Director
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// Tools that failed during the turn in flight, each with what it actually said. A failure the
    /// model recovered from is not worth a line of its own, but a turn that had to recover is worth
    /// saying so once — *with the reason*.
    ///
    /// The name on its own was the app withholding the most useful thing it had. In the live run a
    /// user could read that `open_surface` and `propose` were refused and not why, and those two
    /// refusals were the five surface rules working: "A Compare needs the thing its candidates are
    /// judged against." Which is not an internal complaint, it is the instrument saying what a
    /// comparison is — the sort of thing somebody learns the shape of the app from.
    @ObservationIgnored private var stumbles: [Stumble] = []

    /// One failed call: the tool, and the sentence it answered with.
    struct Stumble: Hashable {
        var tool: String
        var reason: String
    }

    /// `runningOn` is the model the director handed in was made with, so the rail never names one
    /// the band is not on.
    public init(director: Director, app: AppState, runningOn model: ClaudeModel = DirectorRole.judgment.model,
                models: DirectorModelChoice = DirectorModelChoice()) {
        self.director = director
        self.app = app
        self.model = model
        self.models = models
    }

    /// The app's own: the live frame, the real client, the real engines, the model last chosen.
    public static func live(for app: AppState) -> DirectorSession {
        let models = DirectorModelChoice()
        return DirectorSession(director: Director.live(for: app, model: models.model), app: app,
                               runningOn: models.model, models: models)
    }

    // MARK: The model

    /// Puts the band on another model, and keeps the choice for the next launch. Its conversation
    /// starts over, because a thread is one model's: the thinking it carries is signed by the model
    /// that did it. The song is the app's and is as it was. Not while a turn is in flight.
    public func choose(_ model: ClaudeModel) {
        guard model != self.model, !isWorking else { return }
        self.model = model
        models.model = model
        let director = self.director
        Task { await director.use(model) }
        app?.note(.session, "The band runs on \(model.label) now",
                  detail: "Its conversation starts over; the song is as it was.")
    }

    // MARK: The key

    /// Asks whether there is a key. Cheap, and never prints one.
    public func refreshKeyStatus() async {
        keyStatus = await director.keyStatus()
    }

    /// Keeps a key the user typed in the rail, then asks again whether there is one. Returns what
    /// went wrong, or nil; the key itself is never held here and never logged.
    public func storeKey(_ text: String) async -> String? {
        if let problem = await director.storeKey(text) { return problem }
        keyWasRefused = false
        await refreshKeyStatus()
        app?.note(.session, "The band has a key", detail: keyStatus.sentence)
        return nil
    }

    /// Takes the keychain's key out, then asks again.
    public func forgetKey() async -> String? {
        if let problem = await director.forgetKey() { return problem }
        await refreshKeyStatus()
        app?.note(.session, "The band's key was forgotten", detail: keyStatus.sentence)
        return nil
    }

    /// What the composer says under the field. Never a stack trace; never a key.
    public var footnote: String {
        if isWorking { return activity ?? "Working…" }
        if !keyStatus.hasKey { return ClaudeError.missingAPIKey.sentence }
        // The key is there, and the API said no to it: "Signed in" would be the one wrong thing.
        if keyWasRefused { return ClaudeError.keyRefused }
        return spendLine ?? keyStatus.sentence
    }

    /// The API refused the key on the last turn. Set again by a key being kept.
    public private(set) var keyWasRefused = false
    /// What was sent from the field, until the turn lands: put back in the box when the turn fails
    /// before the band did anything, so a refused key or a dropped connection loses no words.
    private var sentFromTheField: String?
    private var toolsRan = false

    /// Whether the field can be sent from.
    public var canSend: Bool {
        !isWorking && !composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Sending

    /// Sends what is in the composer.
    ///
    /// Five endings, and the first one is handled before a byte goes out: with no key nothing is
    /// sent, the rail says so in the app's own voice, and **the sentence stays in the box**. Losing
    /// what somebody typed because the app was not configured is the version of this that makes
    /// people stop trusting the field.
    public func send() {
        let text = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }

        guard keyStatus.hasKey else {
            app?.note(.session, ClaudeError.missingAPIKey.sentence,
                      detail: "What you typed is still in the box.")
            return
        }

        composing = ""
        sentFromTheField = text
        let room = self.room
        let ids = Self.addressees(in: text, chips: addressed, room: room)
        let names = ids.compactMap { id in room.first { $0.id == id }?.name }
        app?.note(.you, text, detail: ids.isEmpty ? nil : "to \(names.joined(separator: ", ")) only")
        if !keepsAddressing { addressed = [] }
        start(Self.addressedText(text, to: ids))
    }

    /// The same, for a sentence that did not come from the field: a proposal you accepted in words,
    /// a persona handing the Director something. Kept separate from `send()` so the composer's own
    /// rules — trimming, clearing, keeping your text on a failure — live in one place.
    public func ask(_ text: String) {
        guard !text.isEmpty, !isWorking, keyStatus.hasKey else { return }
        app?.note(.you, text)
        start(text)
    }

    private func start(_ text: String) {
        // The band reads the song as it is on screen, not as it was a moment ago.
        app?.keepSurfaceWork()
        isWorking = true
        streaming = ""
        activity = "Thinking…"
        stumbles = []
        toolsRan = false

        let buffer = DirectorReplyBuffer()
        // Declared outside the turn's task so the only capture of `self` anywhere here is weak: a
        // session that goes away mid-turn must not be kept alive by the reply arriving into it.
        let watch: @Sendable (DirectorEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.observe(event, buffer: buffer) }
        }
        let model = self.model
        turn = Task { [weak self] in
            guard let self else { return }
            // The model chosen in the rail, before the turn rather than whenever its own task got
            // there: a choice made and a sentence sent straight after go out in that order.
            await self.director.use(model)
            let result = await self.director.direct(text, onEvent: watch)
            self.land(result)
        }
    }

    /// Escape, and the Stop control. The song graph is append-only, so everything the turn already
    /// recorded is real and stays; the reply and the round in flight are dropped.
    public func cancel() {
        guard isWorking else { return }
        activity = "Stopping…"
        let director = self.director
        Task { await director.cancel() }
    }

    /// Another song is open: the thread starts over. A turn in flight is stopped first.
    ///
    /// The conversation used to carry across songs untouched, so the Director in song B could be
    /// holding version ids and a reading of song A, and would act on them until the tools refused
    /// it. What the band spent survives; that is the client's ledger, not the thread's.
    public func songChanged() {
        if isWorking { cancel() }
        let director = self.director
        Task { await director.clear() }
    }

    // MARK: Watching a turn

    private func observe(_ event: DirectorEvent, buffer: DirectorReplyBuffer) {
        switch event {
        case .say(let piece):
            let snapshot = buffer.append(piece)
            // Only ever longer: a hop that arrives out of order must not make the reply shrink.
            if snapshot.count > streaming.count { streaming = snapshot }
        case .toolStarted(let name):
            toolsRan = true
            activity = DirectorSession.activity(for: name)
        case .toolFinished(let name, let isError, let message):
            app?.recordTool(name, failed: isError, message: message)
            if isError { stumbles.append(Stumble(tool: name, reason: message)) }
            activity = nil
        case .opened(let kind, let title):
            activity = "Opened \(kind.rawValue.lowercased()): \(title)"
        case .finished:
            // `land` does the work, from the turn's own value; a duplicate here would double the
            // rail line every time.
            break
        }
    }

    /// The one place a turn becomes state. Everything it touches is reset, whatever the ending was.
    private func land(_ result: DirectorTurn) {
        isWorking = false
        streaming = ""
        activity = nil
        turn = nil
        spendLine = result.spend.turnCount == 0 ? nil : result.spend.line

        if case .failed(let why) = result.ending {
            keyWasRefused = why == ClaudeError.keyRefused
            if !toolsRan, composing.isEmpty, let sent = sentFromTheField { composing = sent }
        } else if result.ending.spoke {
            keyWasRefused = false
        }
        sentFromTheField = nil
        app?.note(result.ending.voice, result.say,
                  detail: result.detail ?? (keyWasRefused || composing.isEmpty ? nil : "What you typed is back in the box."))
        // What the band made is kept as soon as the turn lands, not when you remember to save.
        app?.saveIfNeeded()

        if !stumbles.isEmpty, result.ending.spoke {
            app?.note(.session,
                      "\(stumbles.count) tool call\(stumbles.count == 1 ? "" : "s") failed on the way there",
                      detail: DirectorSession.refusals(stumbles)
                          + " The band was told and worked around it; nothing was left half-done.")
        }
        stumbles = []
    }

    /// The failures as one line the user can read: what was refused, and what it was refused for.
    ///
    /// The same refusal twice is one line — a model that gets the same rule wrong in two rounds has
    /// made one mistake as far as the reader is concerned — and a long reason is cut, because the
    /// rail is a column beside the work and not a log viewer. Where the cut falls is after the first
    /// sentence when there is one, which is where these messages put the reason and before where
    /// they put the suggestion to the model.
    static func refusals(_ stumbles: [Stumble], limit: Int = 160) -> String {
        var seen: Set<Stumble> = []
        return stumbles.compactMap { stumble -> String? in
            guard seen.insert(stumble).inserted else { return nil }
            let reason = DirectorSession.firstSentence(stumble.reason, limit: limit)
            return reason.isEmpty ? "\(stumble.tool)" : "\(stumble.tool) — \(reason)"
        }.joined(separator: " · ")
    }

    /// The first sentence of a tool's message, or the first `limit` characters of it, whichever is
    /// shorter. Never a bare truncation mid-word.
    static func firstSentence(_ message: String, limit: Int) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stop = text.firstIndex(of: "."), text.distance(from: text.startIndex, to: stop) < limit {
            return String(text[...stop])
        }
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(head)
        return cut + "…"
    }

    /// What a tool is doing, in the user's words rather than the tool's. Unknown names fall back to
    /// the name itself, which is honest and never wrong.
    static func activity(for tool: String) -> String {
        switch tool {
        case "read_song": return "Reading the song…"
        case "import_record": return "Loading the record…"
        case "analyse_record": return "Listening to the record…"
        case "list_bars": return "Finding the bars…"
        case "separate_stems": return "Separating the stems…"
        case "chop_bar": return "Cutting the bar…"
        case "classify_slices": return "Naming the slices…"
        case "list_feels", "describe_feel": return "Looking through the feels…"
        case "regroove_chop": return "Playing it through the feel…"
        case "set_swing": return "Moving the swing…"
        case "set_velocity": return "Moving the velocities…"
        case "audition": return "Listening back…"
        case "level_chop": return "Levelling the chop…"
        case "split_section": return "Splitting a section…"
        case "fix_grid": return "Correcting the record's grid…"
        case "set_aside": return "Setting it aside…"
        case "create_part_version": return "Recording it into the song…"
        case "degrade_part": return "Putting it through the machine…"
        case "set_progression": return "Writing the chords down…"
        case "write_bassline": return "The Bassist is writing a line…"
        case "stitch_section": return "Stitching a section…"
        case "arrange": return "Laying the sections out…"
        case "read_library": return "Reading the library…"
        case "adopt": return "Bringing it into the song…"
        case "merge": return "The Sampler is bringing them together…"
        case "cast": return "Reading the room…"
        case "convene": return "Convening the room…"
        case "read_take": return "Reading the take…"
        case "read_mix": return "The Engineer is reading the mix…"
        case "set_mix": return "The Engineer is moving a strip…"
        case "master": return "The Engineer is setting the master…"
        case "export": return "Writing the files…"
        case "read_album": return "Reading the record…"
        case "sequence": return "The Producer and the Peer are reading the order…"
        case "release": return "Releasing the record…"
        case "plan_mashup": return "Reading how the two songs would meet…"
        case "mashup": return "Making the mashup…"
        case "start_song": return "Starting a song from the idea…"
        case "write_groove": return "Writing the beat…"
        case "write_melody": return "Writing the tune for the Melodist…"
        case "write_lyrics": return "Writing the words for the Lyricist…"
        case "set_song": return "Setting the song…"
        case "set_instrument": return "Choosing the instrument…"
        case "comp_takes": return "Comping the takes…"
        case "open_song": return "Opening the song…"
        case "list_genres": return "Looking through the genres…"
        case "read_genre": return "Reading up on the genre…"
        case "set_genre": return "Placing the song in its genre…"
        case "develop": return "Arranging the loop into a song…"
        case "play_chords": return "Playing the chords…"
        case "set_intensity": return "Bringing the section up or down…"
        case "compare_section": return "Setting the section beside how it stood…"
        case "reharmonize": return "Saying the chords another way…"
        case "vary_tune": return "Playing the tune another way…"
        case "open_surface": return "Opening a surface…"
        case "propose": return "Writing a suggestion…"
        default: return "\(tool)…"
        }
    }
}
