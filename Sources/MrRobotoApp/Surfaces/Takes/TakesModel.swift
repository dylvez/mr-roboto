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
    /// Opens a Check on one finding about one take.
    func openCheck(_ finding: Finding, on take: PartVersion)
    func audition(_ version: PartVersion) async
    func stopAudition()
    /// Keeps a rendered comp as a version whose parents are the takes. Nil, with the reason in
    /// the rail, when it cannot be.
    func keepComp(_ rendered: Comp.Rendered, plan: CompPlan, takes: [PartVersion]) -> PartVersion?
    func note(_ text: String, detail: String?)
}

/// The Takes surface: lanes of takes against the bars, a comp chosen bar by bar, and the band's
/// flags on the bars they belong to.
@MainActor
@Observable
public final class TakesModel {

    public let surfaceID: SurfaceID
    public private(set) var takes: [PartVersion]
    public let sectionName: String?
    /// The bars the lanes span, 0-based, end exclusive.
    public private(set) var bars: Range<Int>
    /// Which take each bar comes from. A bar with no choice comes from the newest take.
    public private(set) var choices: [Int: VersionID] = [:]
    public private(set) var comp: PartVersion?
    public private(set) var playing: VersionID?
    public private(set) var lastError: String?
    /// The band's findings on the takes, by version: cents and milliseconds at the bar.
    public private(set) var flags: [VersionID: [Finding]] = [:]
    /// Each take read: its notes against the key and the grid.
    public private(set) var analyses: [VersionID: TakeAnalysis] = [:]

    private let host: any TakesHosting
    private let board: CriticBoard

    public init(host: any TakesHosting, takes: [PartVersion], song: Song?, surfaceID: SurfaceID = SurfaceID(),
                board: CriticBoard = .standard) {
        self.host = host
        self.board = board
        self.surfaceID = surfaceID
        self.takes = takes
        let taken = takes.compactMap { Guidance.audio(of: $0) }
        if let song, let section = taken.compactMap(\.take?.section).first,
           let index = song.sections.firstIndex(where: { $0.id == section }) {
            let start = song.sections.prefix(index).map(\.lengthInBars).reduce(0, +)
            sectionName = song.sections[index].name
            bars = start..<(start + song.sections[index].lengthInBars)
        } else {
            sectionName = nil
            let clock = host.clock
            let first = taken.compactMap(\.take?.startBar).min() ?? 0
            let last = taken.map { ($0.take?.startBar ?? 0) + Int(($0.duration / clock.secondsPerBar).rounded(.up)) }.max() ?? first + 1
            bars = first..<max(first + 1, last)
        }
        read()
    }

    public var clock: TransportClock { host.clock }

    /// Reads every take and asks the critics. Called once on open; again after a new take.
    public func read() {
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

    /// Renders the plan and keeps it as a version. False, with the reason, when it cannot be.
    @discardableResult
    public func keepComp() -> Bool {
        lastError = nil
        let plan = self.plan
        guard !plan.spans.isEmpty else { lastError = "No bars to comp."; return false }
        var audio: [VersionID: Comp.TakeAudio] = [:]
        for id in plan.takes {
            guard let version = takes.first(where: { $0.id == id }), let take = host.audio(of: version) else {
                lastError = "A take's audio is missing."
                return false
            }
            audio[id] = take
        }
        do {
            let rendered = try Comp.render(plan, takes: audio, clock: host.clock)
            guard let version = host.keepComp(rendered, plan: plan, takes: takes.filter { plan.takes.contains($0.id) }) else {
                lastError = "The comp could not be kept."
                return false
            }
            comp = version
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    public func audition(_ version: PartVersion) async {
        playing = version.id
        await host.audition(version)
    }

    public func stopAudition() {
        playing = nil
        host.stopAudition()
    }
}
