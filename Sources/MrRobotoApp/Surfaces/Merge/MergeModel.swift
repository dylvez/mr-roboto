import Foundation
import MusicTheory
import Performance
import SongGraph

/// The Merge surface's entry in the catalog: two versions, one plan.
public struct MergeSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .merge }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Merge") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

/// What the Merge surface needs from whatever hosts it.
@MainActor
public protocol MergeHosting: AnyObject {
    /// One fragment, moved as the plan says, played once on its own.
    func audition(_ version: PartVersion, move: MergeMove) async
    /// Both together, each moved.
    func audition(_ a: (PartVersion, MergeMove), with b: (PartVersion, MergeMove)) async
    func stop() async
    /// Carries a move out and records the result as a version derived from `version`. An
    /// untouched move returns `version` itself: nothing is rendered to do nothing.
    func render(_ version: PartVersion, move: MergeMove) async throws -> PartVersion
    /// Appends a section to the song's form. `false` when the host refused.
    func stitch(_ section: Section) async -> Bool
}

/// The Merge surface's model: two fragments, the plan between them, and the section they become.
///
/// The plan is `Merge.plan` over what the fragments say about themselves — key, tempo, whether
/// they are audio — against the open song's key and tempo. Everything on the surface that can be
/// changed changes an input to that call and reads the plan again, so the sentences and the
/// numbers can never disagree.
@MainActor
@Observable
public final class MergeModel {

    public enum Lane: Sendable { case a, b }

    public let surfaceID: SurfaceID
    public var surface: MergeSurface {
        MergeSurface(id: surfaceID, bound: [a, b].compactMap { $0?.id }, title: title)
    }

    public private(set) var a: PartVersion?
    public private(set) var b: PartVersion?
    public private(set) var fragmentA: MergeFragment?
    public private(set) var fragmentB: MergeFragment?

    /// The song's key and tempo, which the target starts from.
    public let songKey: Key?
    public let songTempo: Double?
    public let timeSignature: TimeSignature

    public var targetKey: Key? { didSet { replan() } }
    public var targetTempo: Double? { didSet { replan() } }
    /// A hand on the stepper: semitones for a lane, replacing what the rules chose.
    public private(set) var overrideA: Int? { didSet { replan() } }
    public private(set) var overrideB: Int? { didSet { replan() } }

    public private(set) var plan: MergePlan?
    public var sectionName = "Verse"
    public var bars: Int
    public private(set) var isWorking = false
    public private(set) var lastError: String?
    /// The section stitched from this surface, once it has been.
    public private(set) var stitched: Section?

    private let host: any MergeHosting

    public init(host: any MergeHosting, a: PartVersion?, b: PartVersion?, song: Song?, library: Library,
                surfaceID: SurfaceID = SurfaceID()) {
        self.host = host
        self.surfaceID = surfaceID
        self.a = a
        self.b = b
        songKey = song?.key
        songTempo = song?.tempo
        timeSignature = song?.timeSignature ?? .fourFour
        targetKey = song?.key
        targetTempo = song?.tempo
        fragmentA = a.map { Self.fragment(of: $0, in: song, library: library) }
        fragmentB = b.map { Self.fragment(of: $0, in: song, library: library) }
        bars = Self.defaultBars(a, b, in: song)
        replan()
    }

    // MARK: Reading

    public var title: String {
        switch (a, b) {
        case (let a?, let b?): return "\(PartLabel.title(of: a)) + \(PartLabel.title(of: b))"
        case (let one?, nil), (nil, let one?): return "\(PartLabel.title(of: one)) + …"
        default: return "Merge"
        }
    }

    public var isReady: Bool { a != nil && b != nil && plan != nil }

    /// The keys worth offering as a target: the song's, each fragment's own, deduplicated by
    /// pitch collection and mode.
    public var keyOptions: [Key] {
        var out: [Key] = []
        for key in [songKey, fragmentA?.key, fragmentB?.key].compactMap({ $0 })
        where !out.contains(where: { $0.signature == key.signature && $0.mode == key.mode }) {
            out.append(key)
        }
        return out
    }

    /// The tempos worth offering: the song's and each fragment's own.
    public var tempoOptions: [Double] {
        var out: [Double] = []
        for tempo in [songTempo, fragmentA?.tempo, fragmentB?.tempo].compactMap({ $0 }).map({ $0.rounded() })
        where !out.contains(tempo) {
            out.append(tempo)
        }
        return out
    }

    public func move(_ lane: Lane) -> MergeMove? { lane == .a ? plan?.a : plan?.b }
    public func fragment(_ lane: Lane) -> MergeFragment? { lane == .a ? fragmentA : fragmentB }
    public func version(_ lane: Lane) -> PartVersion? { lane == .a ? a : b }
    public func override(_ lane: Lane) -> Int? { lane == .a ? overrideA : overrideB }

    /// "Horns · D major · 98 bpm · chop"
    public func summary(_ lane: Lane) -> String {
        guard let fragment = fragment(lane) else { return "Nothing here yet — drop a library row or a part." }
        var pieces = [fragment.label]
        if let key = fragment.key { pieces.append(key.name) }
        if let tempo = fragment.tempo { pieces.append("\(Int(tempo.rounded())) bpm") }
        pieces.append(fragment.kind == .sample ? "audio" : fragment.kind == .groove ? "groove" : "written")
        return pieces.joined(separator: " · ")
    }

    // MARK: Changing

    public func nudge(_ lane: Lane, by semitones: Int) {
        guard let move = move(lane), fragment(lane)?.kind != .groove else { return }
        let next = max(-12, min(12, move.semitones + semitones))
        if lane == .a { overrideA = next } else { overrideB = next }
    }

    public func resetOverride(_ lane: Lane) {
        if lane == .a { overrideA = nil } else { overrideB = nil }
    }

    private func replan() {
        guard let fragmentA, let fragmentB else { plan = nil; return }
        let target = MergeTarget(key: targetKey, tempo: targetTempo)
        var plan = Merge.plan(fragmentA, fragmentB, target: target)
        if let overrideA { plan.a = Merge.move(fragmentA, to: plan.target, semitones: overrideA) }
        if let overrideB { plan.b = Merge.move(fragmentB, to: plan.target, semitones: overrideB) }
        self.plan = plan
    }

    // MARK: Playing

    public func play(_ lane: Lane) {
        guard let version = version(lane), let move = move(lane) else { return }
        Task { await host.audition(version, move: move) }
    }

    public func playBoth() {
        guard let a, let b, let plan else { return }
        Task { await host.audition((a, plan.a), with: (b, plan.b)) }
    }

    public func stop() { Task { await host.stop() } }

    // MARK: Stitching

    /// Renders both moves, records them, and appends a section that plays them together.
    @discardableResult
    public func stitch() async -> Section? {
        guard let a, let b, let plan else { return nil }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let movedA = try await host.render(a, move: plan.a)
            let movedB = try await host.render(b, move: plan.b)
            let name = sectionName.trimmingCharacters(in: .whitespaces)
            let section = Section(name: name.isEmpty ? "Verse" : name, stitch: [movedA.id, movedB.id], lengthInBars: max(1, bars))
            guard await host.stitch(section) else {
                lastError = "The song refused the section."
                return nil
            }
            stitched = section
            return section
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    // MARK: Fragments

    /// Whether this kind of version can be merged at all.
    public static func canMerge(_ version: PartVersion) -> Bool {
        [PartType.sample, .bassline, .progression, .groove].contains(version.type)
    }

    /// The other mergeable versions in the song, newest per part, excluding this one's own part.
    public static func partners(for version: PartVersion, in song: Song) -> [PartVersion] {
        var newest: [PartID: PartVersion] = [:]
        for candidate in song.versions where canMerge(candidate) && candidate.partID != version.partID {
            newest[candidate.partID] = candidate
        }
        return newest.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// What the plan needs to know about a version: its label, whether it is audio, its key and
    /// tempo, and whether it carries the drums.
    ///
    /// A chop's key is the one stamped on it when it was cut, else its record's key at the bar,
    /// else the song's. A bass line's key is the one it was written in, else the song's. A
    /// progression's key is its own. A groove has none.
    public static func fragment(of version: PartVersion, in song: Song?, library: Library) -> MergeFragment {
        let label = PartLabel.title(of: version)
        switch version.kind {
        case .sample(let sample):
            var key = sample.key
            if key == nil, let recordID = sample.sourceRecord ?? library.record(forMedia: sample.media)?.id,
               let record = library.record(recordID), let analysisVersion = record.analysis,
               case .analysis(let analysis) = analysisVersion.kind {
                let region = ChopLaneBinding.region(of: sample, bars: analysis.bars, tempo: sample.detectedTempo)
                key = analysis.key(at: region.start)
            }
            let parent = version.parents.compactMap { song?.version($0) }.first
            let drums = parent.flatMap { Guidance.audio(of: $0) }.flatMap { PartLabel.instrument(of: $0) } == .drums
            return MergeFragment(label: label, kind: .sample, key: key ?? song?.key,
                                 tempo: sample.detectedTempo ?? song?.tempo, isDrums: drums)
        case .bassline(let line):
            return MergeFragment(label: label, kind: .written, key: line.key ?? song?.key, tempo: nil)
        case .progression(let progression):
            return MergeFragment(label: label, kind: .written, key: progression.key, tempo: nil)
        case .groove:
            return MergeFragment(label: label, kind: .groove, key: nil, tempo: nil, isDrums: true)
        default:
            return MergeFragment(label: label, kind: .written, key: song?.key, tempo: nil)
        }
    }

    /// How long the section is by default: the longer fragment in bars, or four.
    static func defaultBars(_ a: PartVersion?, _ b: PartVersion?, in song: Song?) -> Int {
        let beatsPerBar = Double(song?.timeSignature.beatsPerBar ?? 4)
        var bars = 0
        for version in [a, b].compactMap({ $0 }) {
            switch version.kind {
            case .groove(let groove): bars = max(bars, groove.bars)
            case .bassline(let line): bars = max(bars, Int((line.lengthInBeats / beatsPerBar).rounded(.up)))
            case .progression(let progression): bars = max(bars, progression.bars.count)
            default: break
            }
        }
        return bars > 0 ? bars : 4
    }
}
