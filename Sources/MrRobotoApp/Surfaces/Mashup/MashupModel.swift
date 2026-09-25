import Foundation
import Performance
import SongGraph

/// The Mashup surface's model: two songs from the library, whose grid they meet on, which stems
/// each gives, and the plan between them — read again on every change, so the sentences and the
/// numbers cannot disagree.
@MainActor
@Observable
public final class MashupModel {
    public typealias Side = MashupPlan.Side

    public let surfaceID: SurfaceID
    public var a: SongID? { didSet { if a != oldValue { chooseDefaults() } } }
    public var b: SongID? { didSet { if b != oldValue { chooseDefaults() } } }
    public var backbone: Side = .a
    public private(set) var stemsA: [String] = []
    public private(set) var stemsB: [String] = []
    public var barShift = 0
    public private(set) var semitonesA: Int?
    public private(set) var semitonesB: Int?
    public var title = ""
    /// The bar the preview starts on, 1-based as the surface shows it.
    public var previewBar = 1

    /// How far the other song can slide against the grid, in bars: back over a minute of it, or
    /// forward past the end of most records. The stepper and the typed field both keep to it.
    nonisolated public static let barShiftRange = -64...256

    /// A shift inside the range, so a typed 999 lands on the edge rather than in the plan.
    nonisolated public static func clampedBarShift(_ bars: Int) -> Int {
        max(barShiftRange.lowerBound, min(barShiftRange.upperBound, bars))
    }

    public private(set) var isMaking = false
    public private(set) var isPreviewing = false
    public private(set) var progress: (what: String, fraction: Double)?
    public private(set) var lastError: String?

    private let app: AppState
    private let service: AuditionService?

    init(app: AppState, service: AuditionService? = nil, surfaceID: SurfaceID = SurfaceID()) {
        self.app = app
        self.service = service
        self.surfaceID = surfaceID
        // The open song is one side when it can be.
        if let open = app.song, Mashups.source(for: open) != nil { a = open.id }
        chooseDefaults()
    }

    /// Songs that know their bars and key: the ones a mashup can be made of.
    public var candidates: [Song] {
        var songs = app.library.songs
        if let open = app.song {
            if let index = songs.firstIndex(where: { $0.id == open.id }) { songs[index] = open } else { songs.append(open) }
        }
        return songs.filter { Mashups.source(for: $0) != nil }
    }

    public func song(_ side: Side) -> Song? { (side == .a ? a : b).flatMap { app.librarySong($0) } }
    public func source(_ side: Side) -> MashupSource? { song(side).flatMap(Mashups.source(for:)) }
    public func available(_ side: Side) -> [String] { song(side).map(Mashups.stems(of:)) ?? [] }
    public func stems(_ side: Side) -> [String] { side == .a ? stemsA : stemsB }
    public func semitones(_ side: Side) -> Int? { side == .a ? semitonesA : semitonesB }
    public var chosenCount: Int { stemsA.count + stemsB.count }

    public var request: MashupRequest? {
        guard let a, let b else { return nil }
        return MashupRequest(a: a, b: b, backbone: backbone, stemsA: stemsA, stemsB: stemsB, barShift: barShift,
                             semitonesA: semitonesA, semitonesB: semitonesB, title: title.isEmpty ? nil : title)
    }

    public var plan: MashupPlan? {
        guard let request, let songA = song(.a), let songB = song(.b), a != b else { return nil }
        return try? Mashups.plan(request, a: songA, b: songB)
    }

    /// Why Make is off, or nil when it is on.
    public var blocker: String? {
        if a == nil || b == nil { return "Choose two songs." }
        if a == b { return MashupError.sameSong.description }
        if chosenCount == 0 { return MashupError.nothingChosen.description }
        if chosenCount > Mashups.maximumStems { return MashupError.tooManyStems(chosenCount).description }
        return nil
    }

    public func toggle(_ stem: String, on side: Side) {
        var list = stems(side)
        if let index = list.firstIndex(of: stem) {
            list.remove(at: index)
        } else {
            // The full record and its stems are the same sound twice.
            if stem == Mashups.full { list = [] } else { list.removeAll { $0 == Mashups.full } }
            list.append(stem)
        }
        if side == .a { stemsA = list } else { stemsB = list }
    }

    /// Moves a side's pitch by ear, from wherever the key arithmetic put it.
    public func nudge(_ side: Side, by step: Int) {
        let current = semitones(side) ?? plan?.move(side).semitones ?? 0
        let next = max(-12, min(12, current + step))
        if side == .a { semitonesA = next } else { semitonesB = next }
    }

    public func resetSemitones(_ side: Side) { if side == .a { semitonesA = nil } else { semitonesB = nil } }

    /// File ▸ Import Record, from the surface that has nothing to offer until two records are in:
    /// the open dialog, then the Record surface reading what was chosen.
    public func importRecord() { MrRobotoApp.importRecord(app) }

    /// The usual mashup: everything but the voice from the backbone, the voice from the other.
    private func chooseDefaults() {
        semitonesA = nil
        semitonesB = nil
        let spine = available(backbone).filter { $0 != Mashups.full && $0 != "vocals" }
        let voice = available(backbone == .a ? .b : .a).contains("vocals") ? ["vocals"] : []
        let spinePick = spine.isEmpty ? (available(backbone).contains(Mashups.full) ? [Mashups.full] : []) : Array(spine.prefix(Mashups.maximumStems - voice.count))
        let otherPick = voice.isEmpty ? (available(backbone == .a ? .b : .a).contains(Mashups.full) && spinePick.count < Mashups.maximumStems ? [Mashups.full] : []) : voice
        stemsA = song(.a) == nil ? [] : (backbone == .a ? spinePick : otherPick)
        stemsB = song(.b) == nil ? [] : (backbone == .a ? otherPick : spinePick)
    }

    public func setBackbone(_ side: Side) {
        guard side != backbone else { return }
        backbone = side
        barShift = 0
        chooseDefaults()
    }

    // MARK: Hearing it, making it

    /// Eight bars from `previewBar`, rendered through the plan and played now.
    public func preview(bars: Int = 8) async {
        guard let request, blocker == nil, !isPreviewing, let service else { return }
        isPreviewing = true
        lastError = nil
        defer { isPreviewing = false }
        do {
            let (planar, rate) = try await app.previewMashup(request, fromBar: max(0, previewBar - 1), bars: bars)
            await service.play(planar: planar, sampleRate: rate)
        } catch {
            lastError = "\(error)"
        }
    }

    public func stopPreview() { Task { await service?.stop() } }

    @discardableResult
    public func make() async -> Song? {
        guard let request, blocker == nil, !isMaking else { return nil }
        isMaking = true
        lastError = nil
        defer { isMaking = false; progress = nil }
        do {
            return try await app.makeMashup(request) { [weak self] what, fraction in self?.progress = (what, fraction) }
        } catch {
            lastError = "\(error)"
            return nil
        }
    }
}
