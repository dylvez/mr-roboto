import Foundation
import Performance
import SongGraph

/// The Sources surface's model: a record from the crate or a song from the library, one of its
/// stems, all of it or some bars,
/// where it lands, how far it moves, and which sections play it — and the sources the open song
/// already holds, each of which can be fitted again. The plan is read again on every change, so the
/// sentences and the numbers cannot disagree.
@MainActor
@Observable
public final class SourcesModel {

    public let surfaceID: SurfaceID
    /// The record or song the stem comes from.
    public var from: SourceOrigin? { didSet { if from != oldValue { chooseDefaults() } } }
    public var stem: String?
    /// Some bars, looped like a chop, rather than the whole stem along the song.
    public var isClip = false { didSet { if isClip != oldValue { chooseSections() } } }
    /// The record's bars, 1-based and both included, as the surface shows them.
    public var fromBar = 1 { didSet { if toBar < fromBar { toBar = fromBar } } }
    public var toBar = 2 { didSet { if fromBar > toBar { fromBar = toBar } } }
    /// The song bar, 1-based, a whole stem's first bar lands on. Zero and below: already under way.
    public var atBar = 1
    public private(set) var semitones: Int?
    public var sections: Set<SectionID> = []
    /// Whether a blank song takes the record's key and tempo.
    public var takesItsGrid = false
    /// Each of its bars onto one of the song's. Nil: unless its bar lines look misread.
    public var tighten: Bool?
    /// The bar the preview starts on, 1-based.
    public var previewBar = 1
    /// The preview with the song under it, rather than the source alone.
    public var withSong = true

    nonisolated public static let atBarRange = -63...256

    public private(set) var isAdding = false
    public private(set) var isPreviewing = false
    /// The source being fitted again, while it renders.
    public private(set) var refitting: PartID?
    public private(set) var progress: (what: String, fraction: Double)?
    public private(set) var lastError: String?
    public private(set) var lastAdded: String?

    private let app: AppState
    private let service: AuditionService?

    init(app: AppState, service: AuditionService? = nil, surfaceID: SurfaceID = SurfaceID()) {
        self.app = app
        self.service = service
        self.surfaceID = surfaceID
        from = origins.first
        chooseDefaults()
        takeAsked()
    }

    // MARK: Reading

    public var song: Song? { app.song }
    /// Records in the crate that have been read.
    public var records: [Record] { Sources.records(in: app.library) }
    /// Library songs with something to give.
    public var candidates: [Song] { Sources.candidates(in: app.library, open: app.song) }
    /// Everything there is to take from: the crate's records, then songs.
    public var origins: [SourceOrigin] { records.map { .record($0.id) } + candidates.map { .song($0.id) } }
    public var source: Song? { from?.songID.flatMap { app.librarySong($0) } }
    public var record: Record? { from?.recordID.flatMap { app.library.record($0) } }
    /// What the chosen source is called.
    public var sourceTitle: String? { record?.title ?? source?.title }
    public func title(of origin: SourceOrigin) -> String {
        switch origin {
        case .record(let id): return app.library.record(id)?.title ?? "A record"
        case .song(let id): return app.librarySong(id)?.title ?? "A song"
        }
    }
    public var available: [String] { record.map(Sources.stems(of:)) ?? source.map(Mashups.stems(of:)) ?? [] }
    /// The record's bars, as its analysis counts them.
    public var barsInRecord: Int {
        guard let stem else { return 0 }
        if let record { return Sources.material(of: record, stem: stem)?.material.bars.count ?? 0 }
        guard let source, let (material, _, _, _) = Sources.material(of: source, stem: stem) else { return 0 }
        return material.bars.count
    }
    public var sourceLine: String? {
        if let record, let reading = record.reading {
            return "\(reading.dominantKey?.name ?? "no key") · \(Int((reading.dominantTempo ?? 120).rounded())) bpm · \(barsInRecord) bars · \(StructureModel.clock(reading.duration))"
        }
        guard let source, let found = Mashups.source(for: source) else { return nil }
        return "\(found.key?.name ?? "no key") · \(Int((found.tempo ?? source.tempo).rounded())) bpm · \(barsInRecord) bars · \(StructureModel.clock(found.duration))"
    }
    /// How loud each of a record's stems is against the record, for the chips.
    public func share(of stem: String) -> Double? { record?.stem(named: stem)?.relativeDB }

    public var request: SourceRequest? {
        guard let from, let stem else { return nil }
        return SourceRequest(from, stem: stem, bars: isClip ? (fromBar - 1)..<toBar : nil, atBar: atBar - 1,
                             semitones: semitones, sections: Array(sections), takesItsGrid: takesItsGrid, tighten: tighten)
    }

    var pick: SourcePick? { request.flatMap { try? app.sourcePick($0) } }

    public var sentences: [String] {
        guard let request, let pick else { return [] }
        return app.sentences(for: pick, request: request)
    }
    public var flags: [String] { pick?.plan.flags ?? [] }
    public var plannedSemitones: Int? { pick?.plan.move.semitones }
    /// Whether what is chosen would be tightened, by the switch or by the trackers.
    public var isTightened: Bool { pick?.plan.isTightened ?? (tighten ?? false) }
    public var isDrums: Bool { stem == "drums" }

    /// Why Preview is off, or nil when it is on.
    public var unheard: String? {
        guard app.song != nil else { return SourceError.noSong.description }
        guard app.store != nil else { return SourceError.noLibrary.description }
        guard let request else { return origins.isEmpty ? "No record in the crate has been read yet, and no other song holds one to take from." : "Choose a record and a stem." }
        do { _ = try app.sourcePick(request) } catch { return "\(error)" }
        return nil
    }

    /// Why Add is off, or nil when it is on.
    public var blocker: String? {
        if let unheard { return unheard }
        if choosesSections, sections.isEmpty { return "Choose a section for it to play in." }
        return nil
    }

    /// The song's sections, for the chips that say where it plays.
    public var songSections: [Section] { app.song?.sections ?? [] }
    /// Whether choosing sections means anything: a song whose form names nothing plays it along
    /// with everything else, and a blank song is given the record's form.
    public var choosesSections: Bool { (app.song?.isArranged ?? false) && !(app.song?.isBlank ?? true) }
    public var isBlankSong: Bool { app.song?.isBlank ?? false }

    /// The sources already in the song, newest version of each.
    public var inSong: [PartVersion] { app.song?.fittedSources ?? [] }

    public func fit(of version: PartVersion) -> SourceFit? { SourceFitting.fit(of: version) }

    /// One line of what a source is: "bars 9–10 · +2 st · −3 dB" or "bar 1 on bar 5 · as it is".
    public func line(for version: PartVersion) -> String {
        guard let fit = fit(of: version) else { return "" }
        var pieces: [String] = []
        if let from = fit.fromBar, let to = fit.toBar {
            pieces.append(to - from == 1 ? "bar \(from + 1), looped" : "bars \(from + 1)–\(to), looped")
        } else if let at = fit.atBar {
            pieces.append(at >= 0 ? "its bar 1 on bar \(at + 1)" : "\(-at) bar\(at == -1 ? "" : "s") in at the start")
        }
        pieces.append(fit.semitones == 0 ? "pitch as it is" : String(format: "%+d st%@", fit.semitones, fit.byEar ? " by ear" : ""))
        if abs(fit.ratio - 1) > 1e-3 { pieces.append(String(format: "×%.3f", fit.ratio)) }
        pieces.append(fit.tightened ? "tight to the grid" : "as recorded")
        if let gain = fit.gainDB { pieces.append(String(format: "%+.1f dB", gain)) }
        let sections = app.song?.sections.filter { $0.stitch.contains(part: version.partID) }.count ?? 0
        if app.song?.isArranged == true { pieces.append("in \(sections) section\(sections == 1 ? "" : "s")") }
        return pieces.joined(separator: " · ")
    }

    // MARK: Choosing

    public func choose(stem: String) {
        guard stem != self.stem else { return }
        self.stem = stem
        semitones = nil
    }

    public func toggle(_ section: SectionID) {
        if sections.contains(section) { sections.remove(section) } else { sections.insert(section) }
    }

    /// Moves the pitch by ear, from wherever the key arithmetic put it.
    public func nudge(by step: Int) {
        let current = semitones ?? plannedSemitones ?? 0
        semitones = max(-12, min(12, current + step))
    }

    public func resetSemitones() { semitones = nil }

    /// The switch, flipped from what it would do now.
    public func toggleTighten() { tighten = !isTightened }

    /// The usual: the voice when there is one, the whole of it, its bar 1 on the song's.
    private func chooseDefaults() {
        let stems = available
        stem = stems.first { $0 == "vocals" } ?? stems.first
        semitones = nil
        tighten = nil
        isClip = false
        fromBar = 1
        toBar = 2
        atBar = 1
        takesItsGrid = app.song?.isBlank ?? false
        chooseSections()
    }

    /// Every section for a whole stem; for a clip, the sections that play no chop yet, or all.
    private func chooseSections() {
        guard let song = app.song else { sections = []; return }
        let free = song.sections.filter { section in !section.stitch.contains { song.latestVersion(of: $0.part)?.type == .sample } }
        sections = Set((isClip && !free.isEmpty ? free : song.sections).map(\.id))
    }

    /// The open song changed under the surface: sections that went are let go.
    public func follow() {
        let ids = Set(songSections.map(\.id))
        sections = sections.intersection(ids)
        if sections.isEmpty { chooseSections() }
        if from == nil || !origins.contains(from!) { from = origins.first }
    }

    /// What a drop or a row has asked this surface to choose, not yet taken.
    public var asked: AskedSource? { app.askedSource }

    /// A stem dropped on the song, or asked for from the crate: chosen here, to be heard and added.
    public func takeAsked() {
        guard let asked = app.askedSource else { return }
        app.askedSource = nil
        from = asked.origin
        if let stem = asked.stem, available.contains(stem) { choose(stem: stem) }
        if let section = asked.section, songSections.contains(where: { $0.id == section }) { sections = [section] }
    }

    // MARK: Hearing it, adding it

    /// Eight bars from `previewBar`, through the fit, with the song under it, played now.
    public func preview(bars: Int = 8) async {
        guard let request, unheard == nil, !isPreviewing, let service else { return }
        isPreviewing = true
        lastError = nil
        defer { isPreviewing = false }
        do {
            let (planar, rate) = try await app.previewSource(request, fromBar: max(0, previewBar - 1), bars: bars, withSong: withSong)
            await service.play(planar: planar, sampleRate: rate)
        } catch {
            lastError = "\(error)"
        }
    }

    public func stopPreview() { Task { await service?.stop() } }

    /// File ▸ Import Records, from the surface that has nothing to offer until a record is read.
    public func importRecords() { MrRobotoApp.importRecords(app) }

    @discardableResult
    public func add() async -> PartVersion? {
        guard let request, blocker == nil, !isAdding else { return nil }
        isAdding = true
        lastError = nil
        lastAdded = nil
        defer { isAdding = false; progress = nil }
        do {
            let version = try await app.addSource(request) { [weak self] what, fraction in self?.progress = (what, fraction) }
            lastAdded = "\(PartLabel.title(of: version)) is in \(app.song?.title ?? "the song")."
            follow()
            return version
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// Fits a source again: a semitone either way, a bar either way, tightened or let loose, or to
    /// the song as it is now.
    public func refit(_ part: PartID, semitones step: Int = 0, bars move: Int = 0, tighten: Bool? = nil) async {
        guard refitting == nil, let version = app.song?.latestVersion(of: part), let fit = fit(of: version) else { return }
        refitting = part
        lastError = nil
        defer { refitting = nil }
        let pitch: Int? = step != 0 ? max(-12, min(12, fit.semitones + step)) : (fit.byEar ? fit.semitones : nil)
        do {
            _ = try await app.refitSource(part, semitones: pitch, atBar: fit.atBar.map { $0 + move }, tighten: tighten)
        } catch {
            lastError = "\(error)"
        }
    }
}
