import AudioEngine
import Foundation
import SongGraph

/// What the Booth needs from its host: the song, the transport, a recorder, and a way to keep a take.
@MainActor
public protocol BoothHosting: AnyObject {
    var song: Song? { get }
    var clock: TransportClock { get }
    var isPlaying: Bool { get }
    /// Song time. While a count-in runs it reads before the section's first bar — below zero when
    /// the section is the song's first.
    var playhead: Double { get }
    func play() async
    /// Plays from a section's first bar, so a take is sung against the section it is for rather
    /// than after everything before it. Nil, or a section the song does not hold, is the top.
    func play(from section: SectionID?) async
    /// Plays from `countInBars` bars before a section's first bar, with a click through those bars;
    /// `click` keeps the click going for the whole take. A take started during the count-in is
    /// placed in song time like any other, so its alignment sits before the section's start.
    func play(from section: SectionID?, countInBars: Int, click: Bool) async
    func stop() async
    /// A recorder against the running transport, on the chosen input. Throws when there is no input.
    func recorder() async throws -> Recorder
    /// The input devices here now, the system's default first.
    var inputs: [AudioInputDevice] { get }
    /// Which device and channel a take comes from; remembered across launches.
    var input: InputChoice { get set }
    /// Where a take is written while it records.
    func scratchURL() -> URL
    /// Keeps a recording as a take version. Nil, with the reason in the rail, when it cannot be.
    func keep(_ recording: Recorder.Recording, take: Take) -> PartVersion?
    func note(_ text: String, detail: String?)
    /// The take started: a controller in Kit, Bass or Keys mode is captured alongside it.
    func recordingStarted(section: SectionID?, startedAt: Double)
    /// The take stopped, whatever it held.
    func recordingEnded(endedAt: Double)
    /// Whether the running transport comes round. A take is one pass, so Record over a loop
    /// starts the song again, unlooped, from the section.
    var isLooping: Bool { get }
    /// What the Booth's own takes lanes read the takes through, and keep a comp through. The
    /// Booth's host is usually the Takes surface's host as well, so by default it is itself.
    var takesHost: (any TakesHosting)? { get }
}

public extension BoothHosting {
    var isLooping: Bool { false }
    func recordingStarted(section: SectionID?, startedAt: Double) {}
    func recordingEnded(endedAt: Double) {}
    /// A host with no notion of sections plays from the top.
    func play(from section: SectionID?) async { await play() }
    /// A host with no count-in starts on the section's first bar, as it always did.
    func play(from section: SectionID?, countInBars: Int, click: Bool) async { await play(from: section) }
    var takesHost: (any TakesHosting)? { self as? any TakesHosting }
}

/// The Booth: the one place you sing. Pick a section, press Record, sing to the words, stop — that
/// is a take, and it lands at once in the section's lanes underneath, where the comp is chosen.
@MainActor
@Observable
public final class BoothModel {

    public enum State: Equatable, Sendable {
        case idle
        case armed
        case recording
    }

    public let surfaceID: SurfaceID
    public private(set) var state: State = .idle
    /// The section the take is for. Nil records against the whole song.
    public var section: SectionID? {
        didSet { if section != oldValue { showLanes() } }
    }
    /// Stop on the section's last bar by itself.
    public var punchesOut = true
    /// Keep going: at the section's end the take is kept and the song starts again from the
    /// section, counted in — every pass a take — until Stop. Singing a verse five times used to be
    /// five presses of Record. Remembered, like the count-in.
    public var keepsGoing: Bool {
        didSet { defaults.set(keepsGoing, forKey: Self.keepGoingKey) }
    }
    /// Takes kept in the run Keep going is on; 0 outside one.
    public private(set) var passesInRun = 0
    /// Whether the input is heard through the engine while recording.
    public var monitors = false
    /// The last buffer's peak, 0…1, while recording.
    public private(set) var level: Float = 0
    /// The song's takes, newest last.
    public private(set) var takes: [PartVersion] = []
    public private(set) var lastError: String?
    /// Song seconds the recorder started at, for the display.
    public private(set) var startedAt: Double?
    /// The device and channel the next take comes from.
    public var input: InputChoice {
        didSet { host.input = input }
    }

    // MARK: Count-in and click

    /// The count-ins on offer. Two bars is as long as anyone waits to sing; more is a rehearsal.
    public static let countInChoices = [0, 1, 2]
    static let countInKey = "booth.countInBars"
    static let clickKey = "booth.click"
    static let keepGoingKey = "booth.keepGoing"

    /// Bars of click before the section's first bar when Record starts the song. Remembered, since
    /// a singer who wants two bars wants them every take.
    public var countInBars: Int {
        didSet {
            let bounded = Self.bounded(countInBars)
            if bounded != countInBars { countInBars = bounded; return }
            defaults.set(countInBars, forKey: Self.countInKey)
        }
    }
    /// The click through the whole take, not just the count-in. Remembered.
    public var click: Bool {
        didSet { defaults.set(click, forKey: Self.clickKey) }
    }
    /// Bars of count-in still to go, while the song is in the bars before the section. Nil
    /// otherwise — including when the song was already playing, since then nothing counted in.
    public private(set) var countInBarsLeft: Int?

    // MARK: The takes of the chosen section

    /// The chosen section's takes as lanes, with the comp. Nil when the host cannot read takes.
    public private(set) var lanes: TakesModel?

    private let host: any BoothHosting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// Keep going's next pass, starting: Stop cancels it.
    @ObservationIgnored private var continuing: Task<Void, Never>?
    /// Song seconds the count-in ends at — the section's first bar — for the take being recorded,
    /// when Record started the song with a count-in. The take begins there, whatever the recorder
    /// caught before it.
    @ObservationIgnored private var countInEnds: Double?
    /// How many bars this take was counted in with, so the count reads "2… 1…" and not just "1…".
    @ObservationIgnored private var countedIn = 0
    /// One lanes model per section, so a comp half-chosen on the Verse is still there after a look
    /// at the Hook, and a section's takes are read once rather than on every chip press.
    @ObservationIgnored private var lanesBySection: [SectionID?: TakesModel] = [:]

    public init(host: any BoothHosting, surfaceID: SurfaceID = SurfaceID(), defaults: UserDefaults = .standard) {
        self.host = host
        self.surfaceID = surfaceID
        self.defaults = defaults
        self.section = host.song?.sections.first?.id
        self.takes = host.song.map(Guidance.takes(in:)) ?? []
        self.input = host.input
        self.countInBars = Self.bounded((defaults.object(forKey: Self.countInKey) as? Int) ?? 1)
        self.click = defaults.bool(forKey: Self.clickKey)
        self.keepsGoing = defaults.bool(forKey: Self.keepGoingKey)
        showLanes()
    }

    private static func bounded(_ bars: Int) -> Int {
        min(max(bars, countInChoices.first ?? 0), countInChoices.last ?? 2)
    }

    /// The input devices here now.
    public var inputs: [AudioInputDevice] { host.inputs }

    /// The chosen device, when it is here.
    public var inputDevice: AudioInputDevice? { input.device(in: inputs) }

    /// What the next take will say it came from — or why it falls back.
    public var inputLine: String { input.describe(in: inputs) }

    public var song: Song? { host.song }
    public var clock: TransportClock { host.clock }
    public var sections: [Section] { host.song?.sections ?? [] }
    public var isPlaying: Bool { host.isPlaying }
    public var playhead: Double { host.playhead }

    /// The bars the chosen section spans, 0-based, end exclusive.
    /// Whether the song is playing beyond the chosen section's last bar.
    private var isPastSection: Bool {
        guard let bars = sectionBars else { return false }
        return host.playhead >= host.clock.seconds(forBar: bars.upperBound) - 0.05
    }

    public var sectionBars: Range<Int>? {
        guard let song = host.song, let section else { return nil }
        var start = 0
        for candidate in song.sections {
            if candidate.id == section { return start..<(start + candidate.lengthInBars) }
            start += candidate.lengthInBars
        }
        return nil
    }

    /// Which pass of this section the next take is.
    public var nextPass: Int {
        (sectionTakes.compactMap { Guidance.audio(of: $0)?.take }.map(\.pass).max() ?? 0) + 1
    }

    /// The takes sung to the chosen section, oldest first.
    public var sectionTakes: [PartVersion] { takes(of: section) }

    /// The takes sung to a section, oldest first; nil is the takes sung to the whole song.
    public func takes(of section: SectionID?) -> [PartVersion] {
        takes.filter { Guidance.audio(of: $0)?.take?.section == section }
    }

    // MARK: The words

    /// The song's newest lyric: the words in view while you sing. Graph order, not timestamps,
    /// because two versions kept in the same millisecond tie on time.
    public var lyric: PartVersion? { host.song?.versions.last { $0.type == .lyric } }

    /// The newest lyric's lines, blank lines kept: they are the gaps between stanzas.
    public var lyricLines: [LyricLine] {
        guard let lyric, case .lyric(let words) = lyric.kind else { return [] }
        return words.lines
    }

    /// Whether there is anything to sing: a lyric of only blank lines is no words.
    public var hasWords: Bool { lyricLines.contains { !$0.syllables.isEmpty } }

    /// A line of the words as the Booth shows it, with the section name written above it when a
    /// labelled stanza starts there.
    public struct WordsLine: Equatable, Sendable {
        public var label: String?
        public var line: LyricLine
    }

    /// The newest lyric's lines with their labels: the whole lyric, as the pane shows it when no
    /// stanza is the chosen section's.
    public var wordsLines: [WordsLine] {
        guard let lyric, case .lyric(let words) = lyric.kind else { return [] }
        return Self.labelled(words, lines: Array(words.lines.indices))
    }

    /// The words for the chosen section: its stanza, sung first, and the rest of the lyric under it.
    public struct SectionWords: Equatable, Sendable {
        /// The label as the lyric writes it.
        public var name: String
        public var stanza: [LyricLine]
        /// Everything else, in order, one blank line between stanzas, each with its label.
        public var rest: [WordsLine]
    }

    /// The stanza labelled with the chosen section's name, when the lyric has one. The second
    /// Verse of the form shows the second stanza labelled Verse, when the words have two; with
    /// only one, every Verse sings it.
    public var sectionWords: SectionWords? {
        guard let lyric, case .lyric(let words) = lyric.kind,
              let chosen = section, let index = sections.firstIndex(where: { $0.id == chosen }),
              let found = words.stanza(forSectionAt: index, in: sections) else { return nil }
        let rest = Array(words.lines.indices.filter { $0 < found.label.line || $0 >= found.lines.upperBound })
        return SectionWords(name: found.label.name, stanza: Array(words.lines[found.lines]),
                            rest: Self.labelled(words, lines: rest, skipping: found.label))
    }

    /// What the pane says when a section is chosen and no stanza carries its name — or nil when
    /// there is no section, no words, or the stanza is found.
    public var sectionWordsHint: String? {
        guard hasWords, sectionWords == nil, let chosen = section,
              let name = sections.first(where: { $0.id == chosen })?.name else { return nil }
        return "Label a stanza [\(name)] on the Lyrics surface to see it here."
    }

    /// `lines` of a lyric with their labels, gaps between stanzas one blank line each and none at
    /// either end — so what is left around a stanza taken out does not open a hole.
    private static func labelled(_ words: Lyric, lines: [Int], skipping taken: Lyric.StanzaLabel? = nil) -> [WordsLine] {
        var names: [Int: String] = [:]
        for label in words.labels ?? [] where label != taken && names[label.line] == nil { names[label.line] = label.name }
        var out: [WordsLine] = []
        var pending: String?
        for index in lines {
            let line = words.lines[index]
            if let name = names[index] { pending = name }
            if line.syllables.isEmpty {
                if let last = out.last, !last.line.syllables.isEmpty { out.append(WordsLine(label: nil, line: line)) }
            } else {
                // A label written on a blank line above its stanza is shown on the stanza's first line.
                if pending != nil, let last = out.last, !last.line.syllables.isEmpty {
                    out.append(WordsLine(label: nil, line: LyricLine(syllables: [])))
                }
                out.append(WordsLine(label: pending, line: line))
                pending = nil
            }
        }
        while out.last?.line.syllables.isEmpty == true { out.removeLast() }
        return out
    }

    // MARK: Recording

    public func arm() {
        guard state == .idle else { return }
        state = .armed
        lastError = nil
    }

    public func disarm() {
        guard state == .armed else { return }
        state = .idle
    }

    /// Starts the song if it is not playing — counted in, from the section — and the recorder with it.
    public func record() async {
        guard state != .recording else { return }
        lastError = nil
        lastHeard = nil
        countInEnds = nil
        countedIn = 0
        // From the section the take is for. The song used to start from bar 1 whatever section
        // was picked, so singing the hook meant waiting through everything before it. The count-in
        // only applies when Record starts the song: joining a song already playing has nothing to
        // count in to.
        // A song already past the section — or going round a loop — would punch the take out at
        // once, or land it past the song's end: it used to keep a fifth of a second of the Hook as
        // the Verse's newest take. The song starts again from the section instead, counted in.
        if host.isPlaying, host.isLooping || isPastSection { await host.stop() }
        if !host.isPlaying {
            await host.play(from: section, countInBars: countInBars, click: click)
            // Stop pressed while Keep going was starting the next pass.
            if Task.isCancelled { await host.stop(); return }
            if countInBars > 0 {
                countInEnds = host.clock.seconds(forBar: sectionBars?.lowerBound ?? 0)
                countedIn = countInBars
            }
        }
        guard host.isPlaying else {
            lastError = "The song did not start, so there is nothing to sing to."
            state = .idle
            countInEnds = nil
            return
        }
        do {
            let recorder = try await host.recorder()
            try recorder.start(to: host.scratchURL())
            self.recorder = recorder
            startedAt = host.playhead
            state = .recording
            countInBarsLeft = barsLeftToCount(at: host.playhead)
            host.recordingStarted(section: section, startedAt: host.playhead)
            watch()
        } catch {
            lastError = "\(error)"
            state = .idle
            countInEnds = nil
        }
    }

    /// Stops the recorder; the recording becomes a take. The song keeps playing unless asked.
    @discardableResult
    public func stopRecording(stopSong: Bool = false) async -> PartVersion? {
        continuing?.cancel()
        continuing = nil
        let version = finishTake(keeping: true)
        passesInRun = 0
        if stopSong { await host.stop() }
        return version
    }

    /// Ends the take now, without waiting on anything: Stop, or the song being left. Kept as a
    /// take of the song it was sung in when `keeping`; let go otherwise (the song is being thrown
    /// away). A take still running when the song changed used to go on recording under the next
    /// song — its recorder never stopped, so the next Record crashed on the input it still held.
    @discardableResult
    public func finishTake(keeping: Bool) -> PartVersion? {
        watching?.cancel()
        watching = nil
        guard state == .recording, let recorder else { return nil }
        let begins = countInEnds
        // Where the song was when it stopped. A stop from outside the Booth — the space bar, the
        // transport's Stop, the song's own end — puts the playhead back to 0 before the watch
        // notices, and a take ending at 0 read as one stopped during its count-in and was dropped.
        let endedAt = host.isPlaying ? host.playhead : max(host.playhead, lastHeard ?? 0)
        lastHeard = nil
        self.recorder = nil
        state = .idle
        level = 0
        countInBarsLeft = nil
        countInEnds = nil
        host.recordingEnded(endedAt: endedAt)
        let recording: Recorder.Recording
        do {
            recording = try recorder.stop()
        } catch {
            lastError = "\(error)"
            return nil
        }
        guard keeping else { return nil }
        // Stopped before the section began: all the recorder heard was the click. Every take
        // stays, but this was never a take, and filing it would put an empty lane in the comp.
        if let begins, endedAt < begins {
            lastError = "Stopped during the count-in, so there was no take to keep."
            return nil
        }
        guard recording.frames > 0 else {
            lastError = "Nothing was recorded."
            return nil
        }
        var placed = recording.alignmentSeconds ?? startedAt ?? 0
        // A take counted in begins on the section's first bar: what the recorder caught before it
        // is the click and a breath. The audio keeps its own alignment, so nothing is lost and
        // playback knows where to trim.
        if let begins, placed < begins { placed = begins }
        let position = host.clock.position(forSeconds: max(0, placed))
        let take = Take(section: section, startBar: position.bar, startBeat: position.beat, input: recording.input,
                        latencyCompensation: recording.latencySeconds, pass: nextPass,
                        sectionStartBar: sectionBars?.lowerBound, tempo: host.clock.tempo)
        guard let version = host.keep(recording, take: take) else {
            lastError = "The take could not be kept."
            return nil
        }
        if !takes.contains(where: { $0.id == version.id }) { takes.append(version) }
        // Into the lanes at once, so the take just sung is there to hear and to comp from.
        showLanes()
        return version
    }

    /// What the Booth says while it counts in: "Counting in: 2… 1…", a number added each bar the
    /// way a person counts a band in. Nil once the section starts.
    public var countInLine: String? {
        guard let left = countInBarsLeft else { return nil }
        let from = max(countedIn, left)
        return "Counting in: " + stride(from: from, through: left, by: -1).map { "\($0)…" }.joined(separator: " ")
    }

    /// Bars of count-in left at a song time: 2 through the first of two bars, 1 through the last.
    private func barsLeftToCount(at playhead: Double) -> Int? {
        guard let ends = countInEnds, playhead < ends else { return nil }
        let bars = Int(((ends - playhead) / host.clock.secondsPerBar).rounded(.up))
        return max(1, min(bars, max(1, countedIn)))
    }

    /// Follows the level and the count-in, and punches out at the section's end.
    /// The last song time the watch saw while the song played. See `finishTake`.
    private var lastHeard: Double?

    private func watch() {
        watching?.cancel()
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                self.level = recorder.peak
                let playhead = self.host.playhead
                if self.host.isPlaying { self.lastHeard = playhead }
                let left = self.barsLeftToCount(at: playhead)
                if left != self.countInBarsLeft { self.countInBarsLeft = left }
                if !self.host.isPlaying {
                    await self.stopRecording()
                    return
                }
                // Never during the count-in: those bars are before the take, and the section's
                // end is measured from where the take begins.
                if self.countInBarsLeft == nil, self.punchesOut || self.keepsGoing, let bars = self.sectionBars,
                   playhead >= self.host.clock.seconds(forBar: bars.upperBound) {
                    guard self.keepsGoing else {
                        await self.stopRecording()
                        return
                    }
                    // The pass is a take; the song goes back to the section and counts in again. From
                    // a task of its own: ending the take ends this watch.
                    if self.finishTake(keeping: true) != nil { self.passesInRun += 1 }
                    self.continuing = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.host.stop()
                        guard !Task.isCancelled, self.keepsGoing else { return }
                        await self.record()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: The lanes

    /// The song changed under the Booth — a take kept elsewhere, the words rewritten, a section
    /// removed. Takes are read again from the song, and a section that is gone falls back to the first.
    public func songChanged() {
        guard let song = host.song else { return }
        if let section, !song.sections.contains(where: { $0.id == section }) {
            self.section = song.sections.first?.id
        }
        let fresh = Guidance.takes(in: song)
        guard fresh.map(\.id) != takes.map(\.id) else { return }
        takes = fresh
        showLanes()
    }

    /// Puts the chosen section's lanes up, built the first time the section is shown and brought
    /// up to date with its takes after that.
    private func showLanes() {
        guard let takesHost = host.takesHost else { lanes = nil; return }
        let wanted = sectionTakes
        if let existing = lanesBySection[section] {
            existing.update(takes: wanted, song: host.song)
            lanes = existing
        } else {
            let made = TakesModel(host: takesHost, takes: wanted, song: host.song)
            lanesBySection[section] = made
            lanes = made
        }
    }
}
