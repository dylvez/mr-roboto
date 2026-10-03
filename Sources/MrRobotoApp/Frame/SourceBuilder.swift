import Foundation
import MusicTheory
import Performance
import SongGraph

// Sources: a stem, or a few bars, of a record in the crate or a song in the library pulled into the
// open song, fitted to its key, tempo and bars. Any number of them, one at a time, whenever you
// like. A mashup is two records made into a third song; this is the open song taking from as many
// records as it wants.

/// Where a source is taken from: a record on the library's shelf, its stems kept beside it, or a
/// song that holds a record and the stems separated in it.
public enum SourceOrigin: Hashable, Sendable {
    case record(RecordID)
    case song(SongID)

    public var recordID: RecordID? { if case .record(let id) = self { return id }; return nil }
    public var songID: SongID? { if case .song(let id) = self { return id }; return nil }
}

/// What a drop or a row asked the Sources surface to choose: the record, maybe a stem of it, and
/// the section it was dropped on.
public struct AskedSource: Equatable, Sendable {
    public var origin: SourceOrigin
    public var stem: String?
    public var section: SectionID?

    public init(origin: SourceOrigin, stem: String? = nil, section: SectionID? = nil) {
        self.origin = origin
        self.stem = stem
        self.section = section
    }
}

/// What to pull in: whose stem, all of it or some bars, where, how far moved, and where it plays.
public struct SourceRequest: Equatable, Sendable {
    public var origin: SourceOrigin
    /// The library song the stem comes from, when it is a song's.
    public var song: SongID? { origin.songID }
    /// The record on the shelf the stem comes from, when it is a record's.
    public var record: RecordID? { origin.recordID }
    /// "vocals", "drums", "bass", "other", or `Mashups.full` for the whole record.
    public var stem: String
    /// Bars of the record, 0-based, the end not included: a clip that loops like a chop. Nil is
    /// the whole stem, laid along the song.
    public var bars: Range<Int>?
    /// For a whole stem: the song bar (0-based) its first bar lands on. Below zero, it is already
    /// under way when the song starts.
    public var atBar: Int
    /// Semitones by ear, in place of the key arithmetic.
    public var semitones: Int?
    /// The sections that play it. Nil: every section for a whole stem, the sections with no chop
    /// for a clip.
    public var sections: [SectionID]?
    /// Whether the song takes the record's key and tempo rather than the record taking the song's.
    /// Nil: when the song has nothing in it yet.
    public var takesItsGrid: Bool?
    /// Each of its bars stretched onto one of the song's, rather than one ratio for all. Nil: unless
    /// so many of its bars would be held that its bar lines look misread (`TightenMap.mostHeld`).
    public var tighten: Bool?

    public init(_ origin: SourceOrigin, stem: String, bars: Range<Int>? = nil, atBar: Int = 0, semitones: Int? = nil,
                sections: [SectionID]? = nil, takesItsGrid: Bool? = nil, tighten: Bool? = nil) {
        self.origin = origin
        self.stem = stem
        self.bars = bars
        self.atBar = atBar
        self.semitones = semitones
        self.sections = sections
        self.takesItsGrid = takesItsGrid
        self.tighten = tighten
    }

    public init(song: SongID, stem: String, bars: Range<Int>? = nil, atBar: Int = 0, semitones: Int? = nil,
                sections: [SectionID]? = nil, takesItsGrid: Bool? = nil, tighten: Bool? = nil) {
        self.init(.song(song), stem: stem, bars: bars, atBar: atBar, semitones: semitones, sections: sections,
                  takesItsGrid: takesItsGrid, tighten: tighten)
    }

    public init(record: RecordID, stem: String, bars: Range<Int>? = nil, atBar: Int = 0, semitones: Int? = nil,
                sections: [SectionID]? = nil, takesItsGrid: Bool? = nil, tighten: Bool? = nil) {
        self.init(.record(record), stem: stem, bars: bars, atBar: atBar, semitones: semitones, sections: sections,
                  takesItsGrid: takesItsGrid, tighten: tighten)
    }

    public var isClip: Bool { bars != nil }
}

public enum SourceError: Error, CustomStringConvertible, Equatable {
    case noSong
    case noLibrary
    case noSuchSong
    case noSuchRecord
    case notRead(String)
    case sameSong
    case notAnalysed(String)
    case noStem(String, String)
    case noBars(String, Int)
    case missingMedia(String)
    case notFitted
    case sourceGone(String)

    public var description: String {
        switch self {
        case .noSong: return "No song is open to bring a source into."
        case .noLibrary: return "There is no library to render into."
        case .noSuchSong: return "That song is not in the library."
        case .noSuchRecord: return "That record is not in the crate any more."
        case .notRead(let title): return "\(title) has not been read yet, so its bars and key are not known. It is read as it comes into the crate; read it again from its row."
        case .sameSong: return "That is the open song; its own stems are already in it."
        case .notAnalysed(let title): return "\(title) has no analysis — import it as a record first, so its bars and key are known."
        case .noStem(let stem, let title): return "\(title) has no \(stem) stem — separate it from its row in the library, or take the full record."
        case .noBars(let title, let bars): return "\(title) has \(bars) bars; choose bars inside them."
        case .missingMedia(let what): return "The audio for \(what) is not on disk."
        case .notFitted: return "That part was not pulled in from another record, so there is nothing to fit again."
        case .sourceGone(let what): return "\(what) is not in the library any more, so it cannot be fitted again. The audio already in the song stays."
        }
    }
}

/// One source, resolved: the file, what the fit knows of it, and the plan.
struct SourcePick: Sendable {
    var url: URL
    var material: SourceMaterial
    var plan: SourcePlan
    /// The fit as it will be stored; `ratio`, `semitones` and the level are the plan's.
    var fit: SourceFit
    var record: RecordID?
    var title: String
    /// Left as recorded unasked because tightened, this many of its bars of so many would have been
    /// held: its bar lines look misread.
    var declined: (held: Int, bars: Int)?
    /// The source's own meter and reading: what a blank song takes from it.
    var meter: TimeSignature
    var analysis: MusicAnalysis?
}

enum Sources {
    /// What a stem of a song is called once it is in another: "Vocals of russianfreedom".
    static func label(stem: String, of title: String) -> String {
        stem == Mashups.full || stem == "record" ? "The record of \(title)" : "\(stem.capitalized) of \(title)"
    }

    /// The name a fit's stem is stored under: "record" for the full mix, as a mashup stores it.
    static func stored(_ stem: String) -> String { stem == Mashups.full ? "record" : stem }

    /// Library songs with something to give: analysed, and holding a record or stems.
    static func candidates(in library: Library, open: Song?) -> [Song] {
        library.songs.filter { $0.id != open?.id && Mashups.source(for: $0) != nil && !Mashups.stems(of: $0).isEmpty }
    }

    /// Records on the shelf with something to give: read, so their bars and key are known.
    static func records(in library: Library) -> [Record] {
        library.records.filter { $0.reading != nil }
    }

    /// The stems a record can give: those separated, in the usual order, and always the whole record.
    static func stems(of record: Record) -> [String] {
        (record.stems ?? []).map(\.name).sorted { RecordStems.order($0) < RecordStems.order($1) } + [Mashups.full]
    }

    /// A record's stem as the fit reads it: its bars, key and tempo from the record's reading.
    static func material(of record: Record, stem: String) -> (material: SourceMaterial, media: MediaRef, analysis: MusicAnalysis)? {
        guard let analysis = record.reading else { return nil }
        let media: MediaRef, duration: Double
        if stem == Mashups.full || stem == "record" {
            media = record.media
            duration = analysis.duration
        } else {
            guard let found = record.stem(named: stem) else { return nil }
            media = found.media
            duration = found.duration > 0 ? found.duration : analysis.duration
        }
        let material = SourceMaterial(label: label(stem: stem, of: record.title), key: analysis.dominantKey, tempo: analysis.dominantTempo,
                                      bars: bars(of: analysis), duration: duration, isDrums: stem == "drums")
        return (material, media, analysis)
    }

    /// The analysis's bars; with none found but downbeats, a bar from each to the next.
    static func bars(of analysis: MusicAnalysis) -> [SongGraph.TimeRange] {
        guard analysis.bars.isEmpty else { return analysis.bars }
        let downbeats = analysis.downbeats
        return zip(downbeats, downbeats.dropFirst()).map { SongGraph.TimeRange(start: $0, end: $1) }
    }

    /// The beats in a bar as the record's own beats count them: the commonest count from one
    /// downbeat to the next, four when it cannot say.
    static func beatsPerBar(in analysis: MusicAnalysis) -> Int {
        var counts: [Int: Int] = [:], since: Int?
        for beat in analysis.beats {
            if beat.isDownbeat {
                if let since, since > 1, since < 13 { counts[since, default: 0] += 1 }
                since = 1
            } else if since != nil {
                since! += 1
            }
        }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 4
    }

    /// A song's stem as the fit reads it: its bars, key and tempo from the analysis of the record
    /// it was separated from.
    static func material(of song: Song, stem: String) -> (material: SourceMaterial, version: PartVersion, audio: Audio, analysis: MusicAnalysis)? {
        guard let version = Mashups.version(named: stem, in: song), let audio = Guidance.audio(of: version),
              let analysis = Guidance.analysis(for: version, in: song) ?? Guidance.analysis(in: song) else { return nil }
        let bars = bars(of: analysis)
        let duration = audio.duration > 0 ? audio.duration : analysis.duration
        let material = SourceMaterial(label: label(stem: stem, of: song.title), key: analysis.dominantKey ?? song.key,
                                      tempo: analysis.dominantTempo ?? song.tempo, bars: bars, duration: duration,
                                      isDrums: stem == "drums")
        return (material, version, audio, analysis)
    }

    /// The loudness the open song's records already sit at: a source fitted before (its record's
    /// loudness plus the gain it was given), else a mashup's records, else the song's own record.
    /// Nil when nothing in the song has been read, and the first record is left as it is.
    static func levelTarget(in song: Song, library: Library) -> Double? {
        for version in song.versions {
            if let fit = SourceFitting.fit(of: version), let lufs = fit.recordLUFS {
                return lufs + (fit.gainDB ?? 0)
            }
        }
        for version in Guidance.stems(in: song) where version.operation == Operation.mashup {
            guard let id = Guidance.audio(of: version)?.sourceRecord, let analysis = library.record(id)?.analysis,
                  case .analysis(let read) = analysis.kind, let lufs = read.loudness?.integrated else { continue }
            return lufs
        }
        return Guidance.analysis(in: song)?.loudness?.integrated
    }

    /// Reads the region, moves it, levels it, and writes it. Off the main actor: minutes of audio.
    static func render(_ pick: SourcePick, to url: URL) throws -> (sampleRate: Double, channels: Int, duration: Double) {
        let span = try AudioRegion.read(pick.url, from: pick.plan.region.start, to: pick.plan.region.end)
        guard let first = span.planar.first, !first.isEmpty else { throw SourceError.missingMedia(pick.material.label) }
        var moved = try MergeRender.audio(span.planar, sampleRate: span.sampleRate, move: pick.plan.move, anchors: pick.plan.anchors)
        if let gain = pick.fit.gainDB, gain != 0 {
            let factor = Float(pow(10, gain / 20))
            moved = moved.map { $0.map { $0 * factor } }
        }
        if pick.plan.isClip {
            // A clip is exactly its bars: the stretch lands within a frame or two of them, and a
            // loop a frame long or short drifts against the song.
            let frames = Int((Double(pick.plan.bars) * pick.plan.secondsPerBar * span.sampleRate).rounded())
            moved = moved.map { lane in
                lane.count >= frames ? Array(lane.prefix(frames)) : lane + [Float](repeating: 0, count: frames - lane.count)
            }
        }
        try BoothAdapter.write(moved, sampleRate: span.sampleRate, to: url)
        return (span.sampleRate, moved.count, Double(moved.first?.count ?? 0) / span.sampleRate)
    }

    /// Some bars of the song with the source in them, as the source alone: a whole stem's stretch
    /// of those bars, or a clip looped through them. For hearing a bar or a semitone before minutes
    /// of audio are rendered.
    static func preview(_ pick: SourcePick, fromBar: Int, bars: Int) throws -> (planar: [[Float]], sampleRate: Double) {
        let plan = pick.plan
        let window = Double(bars) * plan.secondsPerBar
        let start = Double(fromBar) * plan.secondsPerBar
        // The record's seconds that land in the window: a whole stem's from where it is laid, a
        // clip's all of it, looped from the window's start.
        let from: Double, to: Double
        if plan.isClip {
            (from, to) = (plan.region.start, plan.region.end)
        } else {
            from = max(plan.region.start, plan.region.start + plan.source(atOutput: start - plan.offset))
            to = min(plan.region.end, plan.region.start + plan.source(atOutput: start + window - plan.offset))
        }
        var span = try AudioRegion.read(pick.url, from: from, to: max(from, to))
        let rate = span.sampleRate > 0 ? span.sampleRate : 48_000
        let frames = Int(window * rate)
        var mix = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        guard let first = span.planar.first, !first.isEmpty else { return (mix, rate) }
        if let gain = pick.fit.gainDB, gain != 0 {
            let factor = Float(pow(10, gain / 20))
            span.planar = span.planar.map { $0.map { $0 * factor } }
        }
        let anchors = plan.anchors(from: from - plan.region.start, to: max(from, to) - plan.region.start)
        let moved = try MergeRender.audio(span.planar, sampleRate: rate, move: plan.move, anchors: anchors)
        let landing = plan.isClip ? 0 : max(0, plan.offset + plan.output(atSource: from - plan.region.start) - start)
        let loop = plan.isClip ? Int((Double(plan.bars) * plan.secondsPerBar * rate).rounded()) : Int.max
        for channel in 0..<2 {
            let source = moved[min(channel, moved.count - 1)]
            var at = Int(landing * rate)
            repeat {
                for i in 0..<min(source.count, loop) where at + i < frames { mix[channel][at + i] += source[i] * 0.7 }
                at += loop
            } while plan.isClip && at < frames
        }
        return (mix, rate)
    }

    /// The sections a new song takes from a whole stem's record: each analysed section from the
    /// song bar it lands on, as a mashup takes its backbone's.
    static func sections(for plan: SourcePlan, analysis: MusicAnalysis, downbeat: Double) -> [Section] {
        var starts: [(bar: Int, name: String)] = []
        var counts: [String: Int] = [:]
        for range in analysis.sections {
            let bar = Int(((plan.offset + plan.output(atSource: range.start - plan.region.start)) / plan.secondsPerBar).rounded())
            guard bar < plan.bars, (starts.last?.bar ?? -1) < bar else { continue }
            let label = (range.label?.isEmpty == false ? range.label! : "Part").capitalized
            counts[label, default: 0] += 1
            starts.append((max(0, bar), counts[label]! > 1 ? "\(label) \(counts[label]!)" : label))
        }
        if starts.isEmpty { starts.append((0, "Song")) }
        if starts[0].bar > 0 { starts.insert((0, "Intro"), at: 0) }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].bar : plan.bars
            return end > start.bar ? Section(name: start.name, stitch: [], lengthInBars: end - start.bar) : nil
        }
    }
}

extension Song {
    /// Nothing in it but a drum machine's pick: a song a first source can set the key and tempo of.
    var isBlank: Bool { versions.allSatisfy { $0.type == .sound } }

    /// Whether the form says what plays: some section names something.
    var isArranged: Bool { sections.contains { !$0.stitch.isEmpty } }

    /// The parts pulled in from other records, each by its newest version, oldest first.
    var fittedSources: [PartVersion] {
        partIDs.compactMap { part in
            guard let newest = latestVersion(of: part), SourceFitting.fit(of: newest) != nil else { return nil }
            return newest
        }
    }
}

extension SourceFitting {
    /// The fit a version carries: a whole stem's or a clip's.
    static func fit(of version: PartVersion) -> SourceFit? {
        switch version.kind {
        case .audio(let audio): return audio.fit
        case .sample(let sample): return sample.fit
        default: return nil
        }
    }
}

extension AppState {

    /// Whether this request has the song take the record's grid.
    func takesGrid(_ request: SourceRequest) -> Bool { request.takesItsGrid ?? (song?.isBlank ?? false) }

    /// The request resolved to a file, a fit and a plan, against the open song as it is.
    func sourcePick(_ request: SourceRequest) throws -> SourcePick {
        guard let song else { throw SourceError.noSong }
        guard let store else { throw SourceError.noLibrary }
        let sourceID: SongID
        switch request.origin {
        case .record(let id):
            guard let record = library.record(id) else { throw SourceError.noSuchRecord }
            guard record.reading != nil else { throw SourceError.notRead(record.title) }
            guard let (material, media, analysis) = Sources.material(of: record, stem: request.stem) else {
                throw SourceError.noStem(request.stem, record.title)
            }
            guard let url = try? store.mediaURL(for: media) else { throw SourceError.missingMedia(material.label) }
            if let bars = request.bars, material.bars.count > 0, bars.lowerBound >= material.bars.count || bars.isEmpty {
                throw SourceError.noBars(record.title, material.bars.count)
            }
            return try pick(material, url: url, media: media, origin: request.origin, stem: request.stem, title: record.title,
                            record: record.id, lufs: analysis.loudness?.integrated, request: request,
                            meter: TimeSignature(beatsPerBar: Sources.beatsPerBar(in: analysis)), analysis: analysis, grid: record.grid)
        case .song(let id):
            sourceID = id
        }
        guard sourceID != song.id else { throw SourceError.sameSong }
        guard let source = librarySong(sourceID) else { throw SourceError.noSuchSong }
        guard Mashups.source(for: source) != nil else { throw SourceError.notAnalysed(source.title) }
        guard var (material, version, audio, _) = Sources.material(of: source, stem: request.stem) else {
            throw SourceError.noStem(request.stem, source.title)
        }
        // The song's record, its grid corrected in the crate: its bars are read through that.
        let corrected = Guidance.take(in: source).flatMap(Guidance.audio(of:)).flatMap { library.record(forMedia: $0.media) }
            .flatMap { record in record.grid == nil ? nil : record }
        if let corrected, let reading = corrected.reading {
            material.bars = Sources.bars(of: reading)
            material.tempo = reading.dominantTempo ?? material.tempo
        }
        guard let url = try? store.mediaURL(for: audio.media, song: source.id) else {
            throw SourceError.missingMedia(material.label)
        }
        if let bars = request.bars, material.bars.count > 0, bars.lowerBound >= material.bars.count || bars.isEmpty {
            throw SourceError.noBars(source.title, material.bars.count)
        }
        let fallback = Guidance.take(in: source).flatMap { Guidance.audio(of: $0) }.flatMap { library.record(forMedia: $0.media)?.id }
        let record = audio.sourceRecord ?? Guidance.sourceRecord(of: version, in: source) ?? fallback
        let analysis = corrected?.reading ?? Guidance.analysis(for: version, in: source) ?? Guidance.analysis(in: source)
        return try pick(material, url: url, media: audio.media, origin: request.origin, stem: request.stem, title: source.title,
                        record: record, lufs: analysis?.loudness?.integrated, request: request,
                        meter: source.timeSignature, analysis: analysis, grid: corrected?.grid)
    }

    /// The plan for a material against the open song's grid (or its own, when the song takes it).
    private func pick(_ material: SourceMaterial, url: URL, media: MediaRef, origin: SourceOrigin?, stem: String, title: String,
                      record: RecordID?, lufs: Double?, request: SourceRequest, meter own: TimeSignature?,
                      analysis: MusicAnalysis?, grid: RecordGrid? = nil) throws -> SourcePick {
        guard let song else { throw SourceError.noSong }
        let ownGrid = takesGrid(request)
        let target = ownGrid ? MergeTarget(key: material.key, tempo: material.tempo) : MergeTarget(key: song.key, tempo: song.tempo)
        let meter = (ownGrid ? (own ?? song.timeSignature) : song.timeSignature).beatsPerBar
        let shape: SourceShape = request.bars.map { .clip(from: $0.lowerBound, to: $0.upperBound) } ?? .whole(atBar: request.atBar)
        func planned(tightened: Bool) -> SourcePlan {
            SourceFitting.plan(material, into: target, beatsPerBar: meter, shape: shape, semitones: request.semitones, tighten: tightened)
        }
        // Tightened unless asked not to, or unless its bar lines look misread: bar lines that are
        // wrong are worse to tighten to than none, each wrong one a bar sped up and the next slowed.
        var declined: (held: Int, bars: Int)?
        var plan = planned(tightened: request.tighten ?? true)
        if request.tighten == nil, plan.looksMisread {
            declined = (plan.held, plan.pinned)
            plan = planned(tightened: false)
        }
        // One level for every stem of a record, toward the records already in the song — bars of it
        // too, or a clip of a hot record came in 7 dB over the same record's whole stem. It is in the
        // render; a clip of a quiet bar is then brought up like any chop (`ChopLevel`) as it comes in.
        let gain = SourceFitting.level(record: lufs, toward: Sources.levelTarget(in: song, library: library))
        var sourceSong: SongID?, sourceRecord: RecordID?
        switch origin {
        case .song(let id): sourceSong = id
        case .record(let id): sourceRecord = id
        case nil: break
        }
        let fit = SourceFit(label: title, media: media, song: sourceSong, stem: Sources.stored(stem),
                            start: plan.isClip ? plan.region.start : material.firstDownbeat, end: plan.isClip ? plan.region.end : nil,
                            fromBar: request.bars?.lowerBound, toBar: request.bars?.upperBound,
                            atBar: plan.isClip ? nil : request.atBar,
                            semitones: plan.move.semitones, byEar: request.semitones != nil, ratio: plan.move.ratio,
                            tightened: plan.isTightened, key: material.key, tempo: material.tempo, recordLUFS: lufs,
                            gainDB: gain.flatMap { $0 == 0 ? nil : $0 }, record: sourceRecord, grid: grid)
        return SourcePick(url: url, material: material, plan: plan, fit: fit, record: record, title: title, declined: declined,
                          meter: own ?? song.timeSignature, analysis: analysis)
    }

    /// The plan's sentences with the level and the grid said, the way the surface and the Director
    /// say them.
    func sentences(for pick: SourcePick, request: SourceRequest) -> [String] {
        var out = pick.plan.sentences
        if let gain = pick.fit.gainDB {
            out.append(String(format: "%@ %.1f dB, so it sits with the records already in the song.", gain > 0 ? "Up" : "Down", abs(gain)))
        }
        if takesGrid(request) {
            out.append("The song takes its key and tempo: \(pick.material.key?.name ?? "no key"), \(Int((pick.material.tempo ?? song?.tempo ?? 120).rounded())) bpm.")
        }
        if request.tighten == nil, let line = Self.tightenLine(pick) { out.append(line) }
        return out
    }

    /// Why a source was left as recorded unasked: its bar lines look misread.
    static func tightenLine(_ pick: SourcePick) -> String? {
        guard let declined = pick.declined else { return nil }
        return "Played as recorded, drift and all: tightened, \(declined.held) of its \(declined.bars) bars would hit the "
            + "\(Int(TightenMap.limit * 100))% limit on a bar's stretch, so its bar lines look misread rather than played, and "
            + "tightening to them would lurch. Correct its grid from its row in the library (half or double the tempo, move the "
            + "downbeat, or take the second tracker's), or tighten it to try anyway."
    }

    /// Some bars of the source as the song would have them, rendered off the main actor. With the
    /// song, those bars of the song as it plays now are under it.
    func previewSource(_ request: SourceRequest, fromBar: Int, bars: Int, withSong: Bool = true) async throws -> (planar: [[Float]], sampleRate: Double) {
        let pick = try sourcePick(request)
        var (mix, rate) = try await Task.detached(priority: .userInitiated) { try Sources.preview(pick, fromBar: fromBar, bars: bars) }.value
        guard withSong, !takesGrid(request), playback.isPlayable else { return (mix, rate) }
        var plan = playback.looping(false).starting(atBar: fromBar)
        plan.lengthInBars = bars
        let under = try await SectionBounce.render(plan, section: nil, kitsDirectory: AuditionService.defaultKitsDirectory,
                                                   sampleRate: rate, tailSeconds: 0, onlyTheMix: true, mastered: false, upTo: bars).mix
        for channel in mix.indices {
            let lane = under[min(channel, max(0, under.count - 1))]
            for i in mix[channel].indices where i < lane.count { mix[channel][i] += lane[i] }
        }
        return (Limiter.apply(mix, sampleRate: rate, ceilingDBTP: -1), rate)
    }

    /// Pulls the source into the open song: renders it through its fit into the song's package
    /// and records it, then seats it in the sections that play it. A whole stem is an `.audio` stem
    /// laid along the song; bars of the record are a `.sample` that is exactly those bars and loops
    /// like a chop. Into a blank song, the first source brings its key, its tempo and — a whole
    /// stem — its sections.
    @discardableResult
    func addSource(_ request: SourceRequest, by author: Author = .user,
                   progress: (@MainActor (String, Double) -> Void)? = nil) async throws -> PartVersion {
        guard let store, libraryIsWritable else { throw SourceError.noLibrary }
        guard let opened = song else { throw SourceError.noSong }
        let pick = try sourcePick(request)
        let ownGrid = takesGrid(request)
        progress?(pick.material.label, 0)
        if (try? store.songStore(for: opened.id)) == nil || hasUnsavedChanges { save() }
        let package = try store.songStore(for: opened.id)
        let media = try await renderedMedia(pick, into: package)
        // Rendered into this song: kept in it, even if another was opened while it ran.
        guard song?.id == opened.id else { throw SourceError.noSong }
        progress?("Seating it", 1)

        if ownGrid {
            updateSong { song in
                song.tempo = pick.material.tempo ?? song.tempo
                song.key = pick.material.key ?? song.key
                song.timeSignature = pick.meter
            }
        }
        let version = PartVersion(partID: PartID(), kind: kind(for: pick, media: media), author: author,
                                  operation: Operation.fitted, note: note(for: pick))
        guard record(version, joiningForm: false) else { throw SourceError.noSong }
        seat(version, pick: pick, request: request, blank: opened.isBlank, ownGrid: ownGrid)
        return song?.latestVersion(of: version.partID) ?? version
    }

    /// Fits a source again from its untouched record: another semitone, another bar, the song's
    /// key or tempo as they are now. A new version of the same part, so every section that plays
    /// it plays the new fit.
    @discardableResult
    func refitSource(_ part: PartID, semitones: Int?, atBar: Int? = nil, tighten: Bool? = nil, by author: Author = .user) async throws -> PartVersion {
        guard let store, libraryIsWritable else { throw SourceError.noLibrary }
        guard let opened = song else { throw SourceError.noSong }
        guard let current = opened.latestVersion(of: part), let fit = SourceFitting.fit(of: current) else { throw SourceError.notFitted }
        guard let url = try? store.mediaURL(for: fit.media, song: fit.song) else { throw SourceError.sourceGone(Sources.label(stem: fit.stem, of: fit.label)) }
        let origin: SourceOrigin = fit.record.map { .record($0) } ?? .song(fit.song ?? SongID())
        // Its record's grid corrected since: whether it is tightened is decided again, against the
        // new bar lines, unless asked; it may have been left loose only because the old ones were wrong.
        let request = SourceRequest(origin, stem: fit.stem == "record" ? Mashups.full : fit.stem,
                                    bars: fit.fromBar.flatMap { from in fit.toBar.map { from..<$0 } },
                                    atBar: atBar ?? fit.atBar ?? 0, semitones: semitones, takesItsGrid: false,
                                    tighten: tighten ?? (readsAnOlderGrid(fit) ? nil : fit.tightened))
        // From the record as the library has it now — a corrected grid is read — or, with its song
        // gone, from what the fit kept.
        let pick: SourcePick
        if let fresh = try? sourcePick(request) {
            pick = fresh
        } else {
            let info = try await Task.detached { try AudioFileInfo.read(url) }.value
            let record: RecordID? = switch current.kind {
            case .audio(let audio): audio.sourceRecord
            case .sample(let sample): sample.sourceRecord
            default: nil
            }
            pick = try self.pick(Self.material(from: fit, duration: info.duration), url: url, media: fit.media,
                                 origin: fit.record.map { .record($0) } ?? fit.song.map { .song($0) },
                                 stem: request.stem, title: fit.label, record: record, lufs: fit.recordLUFS, request: request,
                                 meter: nil, analysis: nil)
        }
        if (try? store.songStore(for: opened.id)) == nil || hasUnsavedChanges { save() }
        let media = try await renderedMedia(pick, into: try store.songStore(for: opened.id))
        guard song?.id == opened.id else { throw SourceError.noSong }
        var kind = kind(for: pick, media: media)
        // A clip keeps the level it was given and its cut; only the fit moved.
        if case .sample(var sample) = kind, case .sample(let before) = current.kind {
            sample.gainDB = before.gainDB
            sample.degradation = before.degradation
            kind = .sample(sample)
        }
        let derived = current.deriving(kind, by: author, operation: Operation.fitted, note: note(for: pick))
        guard record(derived, joiningForm: false) else { throw SourceError.noSong }
        return derived
    }

    /// What a fit kept, as material, for a source whose song has gone.
    static func material(from fit: SourceFit, duration: Double) -> SourceMaterial {
        var bars: [SongGraph.TimeRange] = []
        if let end = fit.end, let from = fit.fromBar, let to = fit.toBar, to > from {
            let length = (end - fit.start) / Double(to - from)
            bars = (0..<to).map { index in
                index < from ? SongGraph.TimeRange(start: fit.start, end: fit.start)
                             : SongGraph.TimeRange(start: fit.start + Double(index - from) * length, end: fit.start + Double(index - from + 1) * length)
            }
        } else {
            bars = [SongGraph.TimeRange(start: fit.start, end: fit.start)]
        }
        return SourceMaterial(label: Sources.label(stem: fit.stem, of: fit.label), key: fit.key, tempo: fit.tempo, bars: bars,
                              duration: duration, isDrums: fit.stem == "drums")
    }

    private func renderedMedia(_ pick: SourcePick, into package: SongStore) async throws -> (media: MediaRef, sampleRate: Double, channels: Int, duration: Double) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mrroboto-source-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let info = try await Task.detached(priority: .userInitiated) { try Sources.render(pick, to: scratch) }.value
        return (try package.addMedia(copying: scratch), info.sampleRate, info.channels, info.duration)
    }

    private func kind(for pick: SourcePick, media: (media: MediaRef, sampleRate: Double, channels: Int, duration: Double)) -> PartKind {
        let plan = pick.plan
        if plan.isClip {
            // Exactly its bars, from zero: one marker on each of the song's downbeats in it.
            let markers = (0..<plan.bars).map { SliceMarker(position: Double($0) * plan.secondsPerBar) }
            return .sample(Sample(media: media.media, slices: markers, detectedTempo: plan.move.tempo, sourceRecord: pick.record,
                                  key: plan.move.key ?? pick.material.key,
                                  span: SongGraph.TimeRange(start: 0, end: Double(plan.bars) * plan.secondsPerBar), fit: pick.fit))
        }
        return .audio(Audio(media: media.media, role: .stem, stem: pick.fit.stem, sampleRate: media.sampleRate,
                            channelCount: media.channels, duration: media.duration, alignmentOffset: plan.offset,
                            sourceRecord: pick.record, fit: pick.fit))
    }

    /// "Bass of Arrival, bars 2–3. Bass of Arrival stays in D major at 100." The part's name is
    /// what comes before the first full stop.
    private func note(for pick: SourcePick) -> String {
        var what = pick.material.label
        if case .clip(let from, let to) = pick.plan.shape {
            what += to - from == 1 ? ", bar \(from + 1)" : ", bars \(from + 1)–\(to)"
        }
        return "\(what). " + pick.plan.move.sentence
    }

    /// Seats a new source in the form. A blank song is given the record's sections (a whole stem)
    /// or a loop of its bars (a clip). An arranged song plays it in the sections asked for. A song
    /// whose form names nothing yet is left unarranged: the source plays along with the rest of it,
    /// and the form it is given later carries it.
    private func seat(_ version: PartVersion, pick: SourcePick, request: SourceRequest, blank: Bool, ownGrid: Bool) {
        guard let current = song else { return }
        var sections = current.sections
        var chosen = Set(request.sections ?? [])
        if blank {
            if pick.plan.isClip {
                let repeats = max(1, Int((8.0 / Double(pick.plan.bars)).rounded(.up)))
                sections = [Section(name: "Loop", stitch: [], lengthInBars: pick.plan.bars * repeats)]
            } else if let analysis = pick.analysis {
                sections = Sources.sections(for: pick.plan, analysis: analysis, downbeat: pick.material.firstDownbeat)
            }
            chosen = Set(sections.map(\.id))
        } else if !current.isArranged {
            return
        } else if request.sections == nil {
            let free = sections.filter { section in !section.stitch.contains { current.latestVersion(of: $0.part)?.type == .sample } }
            chosen = Set((pick.plan.isClip && !free.isEmpty ? free : sections).map(\.id))
        }
        for index in sections.indices where chosen.contains(sections[index].id) && !sections[index].stitch.contains(part: version.partID) {
            sections[index].stitch.append(Lane(part: version.partID))
        }
        guard sections != current.sections else { return }
        updateSong { $0.sections = sections }
        let count = sections.filter { $0.stitch.contains(part: version.partID) }.count
        note(.session, "\(PartLabel.title(of: version)) plays in \(count) section\(count == 1 ? "" : "s")",
             detail: blank ? "The song's form is \(pick.material.label)'s: \(sections.map { "\($0.name) \($0.lengthInBars)" }.joined(separator: " · "))."
                           : "Open Structure to take it out of one, or bring it into another.")
    }
}
