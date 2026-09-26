import AudioEngine
import Foundation
import MusicTheory
import Performance
import SongGraph

/// What the Takes surface needs from its host: the takes' audio, an audition, and a comp kept.
@MainActor
public protocol TakesHosting: AnyObject {
    var clock: TransportClock { get }
    /// The song's key, for the critics.
    var key: Key? { get }
    /// A take's audio, placed in the song. Nil when the file is missing.
    func audio(of version: PartVersion) -> Comp.TakeAudio?
    /// The song the takes are in, so a take is drawn where its section is now.
    var song: Song? { get }
    /// Opens a Check on one finding about one take.
    func openCheck(_ finding: Finding, on take: PartVersion)
    func audition(_ version: PartVersion) async
    func stopAudition()
    /// Keeps a rendered comp as a version whose parents are the takes. Nil, with the reason in
    /// the rail, when it cannot be.
    func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion?
    func note(_ text: String, detail: String?)
    /// Opens the Booth, where takes come from. A host with no frame does nothing.
    func openBooth()
    /// Plays rendered audio now: the comp lane, heard before it is made. A host with no audio
    /// does nothing.
    func audition(_ rendered: Comp.Rendered) async
}

public extension TakesHosting {
    var song: Song? { nil }
    func openBooth() {}
    func audition(_ rendered: Comp.Rendered) async {}
}

/// The Takes surface: lanes of takes against the bars, a comp chosen bar by bar, and the band's
/// flags on the bars they belong to. The Booth draws the same lanes for the section it records.
@MainActor
@Observable
public final class TakesModel {

    public let surfaceID: SurfaceID
    public private(set) var takes: [PartVersion]
    public private(set) var sectionName: String?
    /// The bars the lanes span, 0-based, end exclusive.
    public private(set) var bars: Range<Int>
    /// Which take each bar comes from. A bar with no choice comes from the newest take.
    public private(set) var choices: [Int: VersionID] = [:]
    public private(set) var comp: PartVersion?
    /// The plan `comp` was made from, so the comp lane can tell a comp that stands from one the
    /// choices have moved on from.
    private var compPlan: CompPlan?
    public private(set) var playing: VersionID?
    /// The comp lane is sounding, rendered but not kept.
    public private(set) var isHearingComp = false
    /// The bar choices "Pick the clean bars" replaced, for Put back. Gone once a bar is chosen by
    /// hand, since putting back then would undo that choice too.
    public private(set) var choicesBeforePick: [Int: VersionID]?
    public private(set) var lastError: String?
    /// The band's findings on the takes, by version: cents and milliseconds at the bar.
    public private(set) var flags: [VersionID: [Finding]] = [:]
    /// Each take read: its notes against the key and the grid.
    public private(set) var analyses: [VersionID: TakeAnalysis] = [:]

    private let host: any TakesHosting
    private let board: CriticBoard
    /// Clears `playing` when the auditioned take runs out. See `audition(_:)` for why this exists.
    private var playingUntilEnd: Task<Void, Never>?

    public init(host: any TakesHosting, takes: [PartVersion], song: Song?, surfaceID: SurfaceID = SurfaceID(),
                board: CriticBoard = .standard) {
        self.host = host
        self.board = board
        self.surfaceID = surfaceID
        self.takes = takes
        let span = Self.span(of: takes, song: song, clock: host.clock)
        sectionName = span.name
        bars = span.bars
        read()
    }

    public var clock: TransportClock { host.clock }

    /// The section the takes were sung to and the bars it spans; takes sung to the whole song span
    /// from the first one's start to the last one's end.
    private static func span(of takes: [PartVersion], song: Song?, clock: TransportClock) -> (name: String?, bars: Range<Int>) {
        let taken = takes.compactMap { Guidance.audio(of: $0) }
        if let song, let section = taken.compactMap(\.take?.section).first,
           let index = song.sections.firstIndex(where: { $0.id == section }) {
            let start = song.sections.prefix(index).map(\.lengthInBars).reduce(0, +)
            return (song.sections[index].name, start..<(start + song.sections[index].lengthInBars))
        }
        let spans = takes.compactMap { seconds(of: $0, clock: clock, song: song) }
        let first = spans.map { clock.position(forSeconds: max(0, $0.start)).bar }.min() ?? 0
        let last = spans.map { Int(($0.end / clock.secondsPerBar).rounded(.up)) }.max() ?? first + 1
        return (nil, first..<max(first + 1, last))
    }

    /// Where a take's audio sits in the song, in seconds. It starts where the take says it begins —
    /// the section's first bar, for a take that was counted in — and ends where its audio ends,
    /// which is measured from the audio's own alignment: a counted-in take's audio starts in the
    /// count-in, before the take does.
    static func seconds(of version: PartVersion, clock: TransportClock, song: Song? = nil) -> (start: Double, end: Double)? {
        guard let audio = Guidance.audio(of: version), let take = audio.take else { return nil }
        // Moved with its section, and at the song's tempo, as the song plays it.
        let moved = song.map { Double(audio.barsMoved(in: $0)) * clock.secondsPerBar } ?? 0
        let start = clock.seconds(forBar: take.startBar) + take.startBeat * clock.secondsPerBeat + moved
        let aligned = audio.alignmentOffset != nil ? TakePlacement.alignment(of: audio, in: song, clock: clock) : start
        return (start, aligned + TakePlacement.duration(of: audio, in: song))
    }

    /// Takes the lanes' takes again: a take just stopped in the Booth, or a section's takes read
    /// again from the song. Choices on takes still here are kept, and only takes not read before
    /// are read, so the band does not re-read a whole evening for one new take.
    public func update(takes newTakes: [PartVersion], song: Song?) {
        guard newTakes.map(\.id) != takes.map(\.id) else { return }
        takes = newTakes
        let span = Self.span(of: newTakes, song: song, clock: host.clock)
        sectionName = span.name
        bars = span.bars
        let here = Set(newTakes.map(\.id))
        choices = choices.filter { here.contains($0.value) && bars.contains($0.key) }
        analyses = analyses.filter { here.contains($0.key) }
        flags = flags.filter { here.contains($0.key) }
        if let playing, !here.contains(playing) { stopAudition() }
        read(newTakes.filter { analyses[$0.id] == nil })
    }

    /// Reads every take and asks the critics. Called once on open.
    public func read() { read(takes) }

    private func read(_ takes: [PartVersion]) {
        for take in takes {
            guard let audio = host.audio(of: take) else { continue }
            let analysis = TakeAnalysis.of(audio.planar, sampleRate: audio.sampleRate, alignmentSeconds: audio.alignmentSeconds,
                                           key: host.key, clock: host.clock, label: PartLabel.title(of: take))
            analyses[take.id] = analysis
            flags[take.id] = board.review(TakeReview(analysis: analysis))
        }
    }

    public func openCheck(_ finding: Finding, on take: PartVersion) {
        host.openCheck(finding, on: take)
    }

    /// The take a bar comes from.
    public func take(forBar bar: Int) -> VersionID? {
        choices[bar] ?? takes.last?.id
    }

    public func choose(_ take: VersionID, forBar bar: Int) {
        guard takes.contains(where: { $0.id == take }), bars.contains(bar) else { return }
        choices[bar] = take
        choicesBeforePick = nil
    }

    /// Whether a take has audio under this bar.
    public func covers(_ version: PartVersion, bar: Int) -> Bool {
        guard let span = Self.seconds(of: version, clock: host.clock, song: host.song) else { return false }
        let barStart = host.clock.seconds(forBar: bar), barEnd = host.clock.seconds(forBar: bar + 1)
        return span.end > barStart + 0.05 && span.start < barEnd - 0.05
    }

    /// Whether there is anything to pick between: two takes the band has read.
    public var canPickClean: Bool { takes.filter { analyses[$0.id] != nil }.count >= 2 }

    /// "Pick the clean bars": every bar from the take the band flags least there, a tie to the later
    /// pass — what the Director's comp_takes does, done on the lanes, where it can be heard and
    /// changed before anything is made. A take only competes for a bar it sang in, so a take that
    /// went quiet cannot win a bar for having nothing to flag. Put back restores the bars as they were.
    public func pickCleanBars() {
        lastError = nil
        let ordered = takes.enumerated().sorted { a, b in
            let pa = Guidance.audio(of: a.element)?.take?.pass ?? 0, pb = Guidance.audio(of: b.element)?.take?.pass ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        var candidates: [CompPlanner.Candidate] = []
        for take in ordered {
            guard let analysis = analyses[take.id] else { continue }
            var perBar: [Int: Int] = [:]
            for finding in board.review(TakeReview(analysis: analysis, limit: Int.max)) {
                if let bar = finding.locus.bar, bars.contains(bar) { perBar[bar, default: 0] += 1 }
            }
            candidates.append(CompPlanner.Candidate(take: take.id, flags: perBar, sung: Set(analysis.notes.map(\.bar)),
                                                    covers: Set(bars.filter { covers(take, bar: $0) })))
        }
        guard candidates.count >= 2 else {
            lastError = "Picking needs two takes the band could read."
            return
        }
        let before = choices
        let picked = CompPlanner.choose(bars: bars, from: candidates)
        for (bar, take) in picked { choices[bar] = take }
        choicesBeforePick = before
    }

    /// The bars as they were before the pick.
    public func putBackPick() {
        guard let before = choicesBeforePick else { return }
        choices = before
        choicesBeforePick = nil
    }

    public func choose(_ take: VersionID, forBars range: Range<Int>) {
        for bar in range { choose(take, forBar: bar) }
    }

    /// The plan as it stands: runs of bars from the same take, merged.
    public var plan: CompPlan {
        var spans: [CompPlan.Span] = []
        for bar in bars {
            guard let take = take(forBar: bar) else { continue }
            if var last = spans.last, last.take == take, last.endBar == bar {
                last.endBar = bar + 1
                spans[spans.count - 1] = last
            } else {
                spans.append(.init(startBar: bar, endBar: bar + 1, take: take))
            }
        }
        return CompPlan(spans: spans)
    }

    /// The Booth, from the empty state: where a first take comes from.
    public func openBooth() { host.openBooth() }

    /// The part's comp, as the lanes open: what the song plays, pinned as the lanes' choices. A
    /// surface reopened on a comped part used to start with no comp, its lane showing the newest
    /// take rather than what plays.
    public func adoptComp(_ version: PartVersion, song: Song?) {
        guard let audio = Guidance.audio(of: version), let kept = audio.comp else { return }
        let moved = song.map { audio.barsMoved(in: $0) } ?? 0
        let here = Set(takes.map(\.id))
        for span in kept.spans where here.contains(span.take) {
            for bar in (span.startBar + moved)..<(span.endBar + moved) where bars.contains(bar) { choices[bar] = span.take }
        }
        comp = version
        compPlan = plan
    }

    /// Whether the comp lane is the comp last made: false before one is made, and false again once
    /// a bar is chosen differently. Making the same comp twice would file the same audio twice.
    public var compIsCurrent: Bool { comp != nil && compPlan == plan }

    /// Renders the plan and keeps it as a version — "Make the comp". A new version out of takes is
    /// a decision, so this is a button and never happens by itself. False, with the reason, when
    /// it cannot be.
    @discardableResult
    public func keepComp() -> Bool {
        lastError = nil
        let plan = self.plan
        guard let rendered = render(plan) else { return false }
        guard let version = host.keepComp(rendered, plan: plan, takes: takes.filter { plan.takes.contains($0.id) }) else {
            lastError = "The comp could not be kept."
            return false
        }
        comp = version
        compPlan = plan
        // The comp's choices, pinned: a take sung after it must not quietly become every
        // unchosen bar of the comp lane, which would read as the comp changing by itself.
        for span in plan.spans { for bar in span.startBar..<span.endBar { choices[bar] = span.take } }
        return true
    }

    /// The comp lane as audio: each bar from its take, the seams crossfaded. Nil, with the reason
    /// in `lastError`, when a take's audio is missing or there are no bars.
    private func render(_ plan: CompPlan) -> Comp.Rendered? {
        guard !plan.spans.isEmpty else { lastError = "No bars to comp."; return nil }
        var audio: [VersionID: Comp.TakeAudio] = [:]
        for id in plan.takes {
            guard let version = takes.first(where: { $0.id == id }), let take = host.audio(of: version) else {
                lastError = "A take's audio is missing."
                return nil
            }
            audio[id] = take
        }
        do {
            return try Comp.render(plan, takes: audio, clock: host.clock)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// "Hear the comp": the comp lane rendered and played, nothing kept. Choosing bars used to be
    /// blind — the only way to hear a choice was to make it a version, so trying three comps left
    /// three comps in the ledger.
    public func hearComp() async {
        lastError = nil
        guard let rendered = render(plan) else { return }
        playingUntilEnd?.cancel()
        playing = nil
        isHearingComp = true
        await host.audition(rendered)
        guard isHearingComp else { return }
        let seconds = rendered.sampleRate > 0 ? Double(rendered.planar.first?.count ?? 0) / rendered.sampleRate : 0
        playingUntilEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.isHearingComp = false
        }
    }

    /// Plays a take and shows it as playing for as long as it lasts.
    ///
    /// The host's audition is fire-and-forget: it returns once the take is handed to the player,
    /// not when the take ends, and nothing reports the end. So the surface counts the take's own
    /// length and puts the play control back itself — otherwise a take that has finished still
    /// reads as playing until you press Stop on silence.
    public func audition(_ version: PartVersion) async {
        playingUntilEnd?.cancel()
        isHearingComp = false
        playing = version.id
        await host.audition(version)
        guard playing == version.id else { return }
        let seconds = Self.duration(of: version, in: host)
        playingUntilEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.playing == version.id else { return }
            self.playing = nil
        }
    }

    public func stopAudition() {
        playingUntilEnd?.cancel()
        playingUntilEnd = nil
        playing = nil
        isHearingComp = false
        host.stopAudition()
    }

    /// How long a take plays for: the version's own record of its length at the song's tempo, else
    /// the audio's, else nothing — a take with no audio plays nothing and stops at once.
    private static func duration(of version: PartVersion, in host: any TakesHosting) -> Double {
        if let audio = Guidance.audio(of: version), audio.duration > 0 { return TakePlacement.duration(of: audio, in: host.song) }
        guard let audio = host.audio(of: version), audio.sampleRate > 0 else { return 0 }
        return Double(audio.planar.first?.count ?? 0) / audio.sampleRate
    }
}
