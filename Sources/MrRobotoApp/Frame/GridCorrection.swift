import Foundation
import MusicTheory
import Performance
import SongGraph

// A record's grid corrected: for bar lines a tracker misread, the tempo halved or doubled, the
// downbeat moved by a beat, or the second tracker's grid taken. Kept on the record, read through by
// everything that reads the record — Sources, tightening, its stems' bar levels, the band — and
// never written into the analysis, so "as read" is always one press away.

/// One correction, as the record's row and the band ask for it.
public enum GridMove: String, CaseIterable, Sendable {
    case half
    case double
    case later
    case earlier
    case secondTracker = "second_tracker"
    case asRead = "as_read"

    /// The grid after this move, from `grid` (nil: as read). Moves the downbeat within one bar of
    /// `beatsPerBar` beats, so four beats later is back where it was.
    func applied(to grid: RecordGrid?, beatsPerBar: Int) -> RecordGrid {
        var next = grid ?? RecordGrid()
        let perBar = max(1, beatsPerBar)
        func within(_ beats: Int) -> Int {
            let wrapped = ((beats % perBar) + perBar) % perBar
            return wrapped > perBar / 2 ? wrapped - perBar : wrapped
        }
        switch self {
        case .half: next.tempo = next.tempo > 1 ? 1 : 0.5
        case .double: next.tempo = next.tempo < 1 ? 1 : 2
        case .later: next.downbeat = within(next.downbeat + 1)
        case .earlier: next.downbeat = within(next.downbeat - 1)
        case .secondTracker: next.secondTracker.toggle()
        case .asRead: next = RecordGrid()
        }
        return next
    }

    /// The row's menu item.
    var title: String {
        switch self {
        case .half: return "Half the Tempo"
        case .double: return "Double the Tempo"
        case .later: return "Downbeat a Beat Later"
        case .earlier: return "Downbeat a Beat Earlier"
        case .secondTracker: return "The Second Tracker's Grid"
        case .asRead: return "As It Was Read"
        }
    }
}

public enum GridError: Error, CustomStringConvertible, Equatable {
    case noRecord
    case notRead(String)
    case noSecondTracker(String)
    case unchanged(String)

    public var description: String {
        switch self {
        case .noRecord: return "That record is not in the crate."
        case .notRead(let title): return "\(title) has not been read yet, so it has no grid to correct."
        case .noSecondTracker(let title): return "\(title) was read before the second tracker's beats were kept. Let it listen (Its Grid ▸ Listen with the Second Tracker), its reading kept as it is, and its grid can be taken."
        case .unchanged(let title): return "\(title)'s grid is already that."
        }
    }
}

extension AppState {

    /// Whether `move` can be made on a record now: nil when it can, else why not.
    public func refusal(of move: GridMove, for id: RecordID) -> GridError? {
        guard let record = library.record(id) else { return .noRecord }
        guard let read = record.readingAsRead else { return .notRead(record.title) }
        if move == .secondTracker, record.grid?.secondTracker != true, read.checkerBeats?.isEmpty ?? true {
            return .noSecondTracker(record.title)
        }
        let next = move.applied(to: record.grid, beatsPerBar: Sources.beatsPerBar(in: record.reading ?? read))
        if next == (record.grid ?? RecordGrid()) { return .unchanged(record.title) }
        return nil
    }

    /// Corrects a record's grid and says what it became. Its stems' bar levels are measured again
    /// against the new bars; sources the open song fitted from it are named, to be fitted again.
    @discardableResult
    public func correctGrid(_ id: RecordID, _ move: GridMove, by source: SessionEntry.Source = .you) throws -> Record {
        if let refusal = refusal(of: move, for: id) { throw refusal }
        guard let record = library.record(id), let read = record.readingAsRead else { throw GridError.noRecord }
        let before = record.reading ?? read
        let next = move.applied(to: record.grid, beatsPerBar: Sources.beatsPerBar(in: before))
        var updated = library
        guard let index = updated.records.firstIndex(where: { $0.id == id }) else { throw GridError.noRecord }
        updated.records[index].grid = next.isAsRead ? nil : next
        guard writeLibrary(updated) else { throw CrateError.unwritable }
        let corrected = updated.records[index]
        let after = corrected.reading ?? read
        if corrected.stems?.contains(where: { $0.barLevels != nil }) == true {
            crate.enqueue(CrateJob(kind: .measure, record: id, title: corrected.title))
        }
        var detail = "\(Self.gridLine(before)) → \(Self.gridLine(after))."
        let stale = sourcesReadingAnOlderGrid()
        if !stale.isEmpty {
            detail += " \(stale.map(PartLabel.title(of:)).joined(separator: ", ")) in \(song?.title ?? "the song") "
                + "\(stale.count == 1 ? "was" : "were") fitted to its old bar lines: Fit again on Sources tightens to these."
        }
        note(source, "\(corrected.title)'s grid: \(corrected.grid?.description ?? "as read")", detail: detail)
        return corrected
    }

    /// A correction asked for from the record's row: made, or the reason it was not in the rail.
    public func correctGridAsked(_ id: RecordID, _ move: GridMove) {
        do { try correctGrid(id, move) } catch {
            note(.session, "The grid was not corrected", detail: "\(error)")
        }
    }

    /// "95.7 bpm, 73 bars".
    static func gridLine(_ analysis: MusicAnalysis) -> String {
        "\(analysis.dominantTempo.map { String(format: "%.1f bpm", $0) } ?? "no tempo"), \(analysis.bars.count) bars"
    }

    /// The record a fitted source was read from, as the crate has it now: its own, or the record
    /// of the song it came from.
    func record(of fit: SourceFit) -> Record? {
        if let id = fit.record { return library.record(id) }
        guard let id = fit.song, let source = librarySong(id), let take = Guidance.take(in: source).flatMap(Guidance.audio(of:)) else { return nil }
        return library.record(forMedia: take.media)
    }

    /// Whether a fitted source was read through another grid than its record has now.
    func readsAnOlderGrid(_ fit: SourceFit) -> Bool {
        guard let record = record(of: fit) else { return false }
        return (record.grid ?? RecordGrid()) != (fit.grid ?? RecordGrid())
    }

    /// The open song's sources fitted to bar lines their record has had corrected since.
    func sourcesReadingAnOlderGrid() -> [PartVersion] {
        (song?.fittedSources ?? []).filter { SourceFitting.fit(of: $0).map(readsAnOlderGrid) ?? false }
    }
}

extension CrateWork {

    /// A record's stems' bar levels measured again, against the bars its grid reads now.
    func measure(_ job: CrateJob, app: AppState) async throws {
        guard let id = job.record, let store = app.store else { return }
        guard let record = app.library.record(id), let stems = record.stems, let bars = record.reading?.bars, !bars.isEmpty else { return }
        let measured = try await Task.detached(priority: .utility) {
            try stems.map { stem -> RecordStem in
                var stem = stem
                let (planar, rate) = try BoothAdapter.planar(try store.mediaURL(for: stem.media))
                stem.barLevels = RecordStems.levels(planar, sampleRate: rate, bars: bars)
                return stem
            }
        }.value
        try Task.checkCancellation()
        var library = app.library
        guard let index = library.records.firstIndex(where: { $0.id == id }) else { throw CrateError.gone }
        // Measured against the grid as it was when the job started: a correction made since queues
        // another.
        guard library.records[index].grid == record.grid else { return }
        library.records[index].stems = measured
        guard app.writeLibrary(library) else { throw CrateError.unwritable }
    }
}
