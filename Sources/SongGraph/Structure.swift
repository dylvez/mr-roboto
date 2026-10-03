import Foundation
import MusicTheory

/// The schema version of documents this build reads and writes.
public enum SongGraphSchema {
    public static let current = 4
}

// `TimeSignature` comes from MusicTheory (shared with analysis and the engine).

/// How a section enters or leaves.
public enum TransitionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case cut, fill, riser, fadeIn, fadeOut, breakdown, drop, crossfade
}

/// A transition into or out of a section.
public struct Transition: Hashable, Codable, Sendable {
    public var kind: TransitionKind
    /// Length in beats.
    public var beats: Double

    public init(kind: TransitionKind, beats: Double = 0) {
        self.kind = kind
        self.beats = beats
    }
}

/// One layer of a section's stitch: the part it plays, and — rarely — a version to hold it at.
///
/// A stitch used to be `[VersionID]`, and that is the bug this type exists to end. Every surface
/// commits through `PartVersion.deriving(…)`, which keeps the `partID` and mints a **new**
/// `VersionID`; so the moment you painted one more hat or changed a bass voice, the section still
/// named the version from before it, and the form quietly stopped playing the thing you were
/// working on. Nothing anywhere said so.
///
/// A section names a **part**. The part's newest version is what sounds. `pin` is the deliberate
/// exception — a verse keeping the first groove while the hook takes the second, and an experiment
/// stitched as a section, which *is* a named combination of particular versions.
///
/// Order is presentation order, not precedence: two grooves in a section are two grooves, and you
/// hear both. The old stitch's "two of a kind, the last one wins" is gone with the version ids.
public struct Lane: Hashable, Codable, Sendable, Identifiable {
    public var part: PartID
    /// A version to hold this lane at. Nil — the usual case — follows the part.
    public var pin: VersionID?

    public var id: PartID { part }

    public init(part: PartID, pin: VersionID? = nil) {
        self.part = part
        self.pin = pin
    }

    private enum CodingKeys: String, CodingKey { case part, pin }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(part: try c.decode(PartID.self, forKey: .part),
                  pin: try c.decodeIfPresent(VersionID.self, forKey: .pin))
    }

    /// `pin` is omitted when nil, so a form that pins nothing — which is nearly all of them — reads
    /// on disk as a list of parts.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(part, forKey: .part)
        try c.encodeIfPresent(pin, forKey: .pin)
    }
}

/// A section of a song: a name, the parts stitched together, and its length in bars.
public struct Section: Identifiable, Hashable, Codable, Sendable {
    public let id: SectionID
    public var name: String
    /// The stitch: the parts this section plays, in order of layering.
    public var stitch: [Lane]
    public var lengthInBars: Int
    /// 0…1, when the arrangement has an intensity curve.
    public var intensity: Double?
    public var transitionIn: Transition?
    public var transitionOut: Transition?

    public init(id: SectionID = SectionID(), name: String, stitch: [Lane], lengthInBars: Int,
                intensity: Double? = nil, transitionIn: Transition? = nil, transitionOut: Transition? = nil) {
        self.id = id
        self.name = name
        self.stitch = stitch
        self.lengthInBars = lengthInBars
        self.intensity = intensity
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
    }
}

/// A decision the house made on one of a persona's open questions, kept with the song.
public struct HouseCallRecord: Hashable, Codable, Sendable, Identifiable {
    /// The open question's id, e.g. `beatmaker.oq.snare-direction`.
    public var question: String
    /// "encoded" or "alternative".
    public var choice: String
    public var how: String
    public var decidedOn: String

    public var id: String { question }

    public init(question: String, choice: String, how: String, decidedOn: String) {
        self.question = question
        self.choice = choice
        self.how = how
        self.decidedOn = decidedOn
    }
}

/// One thing a persona has said, and how often: what lets a reading that keeps coming back be
/// said as a pattern ("third song running") rather than word for word. Kept with the library, not
/// a song, because the repetition that matters is across songs.
public struct SaidRecord: Hashable, Codable, Sendable, Identifiable {
    /// The persona's id, e.g. `peer`.
    public var persona: String
    /// The rule the reading was made under, e.g. `peer.hook-inside-thirty`.
    public var rule: String
    /// Whether the reading held. A rule that keeps passing is a different pattern from one that
    /// keeps failing, so they are counted apart.
    public var holds: Bool
    /// Every time it was said, one song or many.
    public var times: Int
    /// The songs it was said about, most recent last, each once, the last `songLimit` of them.
    public var songs: [SongID]
    /// The last song's title when it was said, so it can be named without loading the song.
    public var lastTitle: String
    /// `yyyy-MM-dd`.
    public var lastSaid: String

    public static let songLimit = 12

    public var id: String { "\(rule)|\(holds)" }

    public init(persona: String, rule: String, holds: Bool, times: Int, songs: [SongID], lastTitle: String, lastSaid: String) {
        self.persona = persona
        self.rule = rule
        self.holds = holds
        self.times = times
        self.songs = songs
        self.lastTitle = lastTitle
        self.lastSaid = lastSaid
    }

    /// This record with one more saying of it, about `song`.
    public func saying(about song: SongID, titled title: String, on day: String) -> SaidRecord {
        var next = self
        next.times += 1
        next.songs.removeAll { $0 == song }
        next.songs.append(song)
        if next.songs.count > Self.songLimit { next.songs.removeFirst(next.songs.count - Self.songLimit) }
        next.lastTitle = title
        next.lastSaid = day
        return next
    }
}

/// A proposed combination of versions not yet stitched into a section; personas run these as A/B experiments.
public struct Experiment: Identifiable, Hashable, Codable, Sendable {
    public let id: ExperimentID
    public var name: String
    public var versions: [VersionID]
    public let author: Author
    public let createdAt: Date
    public var note: String?

    public init(id: ExperimentID = ExperimentID(), name: String, versions: [VersionID], author: Author,
                createdAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.name = name
        self.versions = versions
        self.author = author
        self.createdAt = createdAt.graphPrecision
        self.note = note
    }

    // `stitched(as:lengthInBars:)` moved to `Song`. An experiment holds version ids and a stitch
    // holds parts, and only the song knows which part a version belongs to.
}

/// A song: sections in order, every part version ever made for it (append-only), and the seeds it grew from.
public struct Song: Identifiable, Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let id: SongID
    public var title: String
    public var artist: String
    public var key: Key?
    /// Beats per minute.
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var sections: [Section]
    /// Append-only; use `append(_:)`.
    public private(set) var versions: [PartVersion]
    public var seeds: [Seed]
    public var experiments: [Experiment]
    public let createdAt: Date
    /// Who is in the room for this song, by persona id. Nil or empty is the app's standard cast.
    /// Optional so a song written before casts round-trips byte for byte.
    public var cast: [String]?
    /// What this house decided on the cast's open questions, by ear.
    public var houseCalls: [HouseCallRecord]?
    /// Whether the arranged drums play a fill into each section and a crash coming out of it
    /// (`Performance.SectionFill`). Nil is yes: optional so a song written before round-trips
    /// byte for byte, and so fills are what a song does unless someone says otherwise.
    public var fills: Bool?

    /// True unless the song has turned its fills off.
    public var playsFills: Bool { fills ?? true }

    /// The genre the song is in, by the id of a genre profile ("house", "boom-bap"), when someone
    /// has said. Nil leaves it to be guessed from what the song holds. Optional so a song written
    /// before genres round-trips byte for byte.
    public var genre: String?

    public init(id: SongID = SongID(), title: String, artist: String = "", key: Key? = nil, tempo: Double = 120,
                timeSignature: TimeSignature = .fourFour, sections: [Section] = [], versions: [PartVersion] = [],
                seeds: [Seed] = [], experiments: [Experiment] = [], createdAt: Date = Date()) {
        schemaVersion = SongGraphSchema.current
        self.id = id
        self.title = title
        self.artist = artist
        self.key = key
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.sections = sections
        self.versions = versions
        self.seeds = seeds
        self.experiments = experiments
        self.createdAt = createdAt.graphPrecision
    }

    /// Appends a version. Throws `duplicateVersion` if its id is already in the song.
    public mutating func append(_ version: PartVersion) throws {
        guard !versions.contains(where: { $0.id == version.id }) else { throw SongGraphError.duplicateVersion(version.id) }
        versions.append(version)
    }

    /// Appends several versions in order.
    public mutating func append(contentsOf newVersions: [PartVersion]) throws {
        for version in newVersions { try append(version) }
    }

    public func version(_ id: VersionID) -> PartVersion? { versions.first { $0.id == id } }

    /// Every version of a part, oldest first — in the order the graph recorded them.
    ///
    /// Not by timestamp. `createdAt` is kept to the millisecond, and two versions of one part can
    /// share one: a surface keeping itself a moment after an edit, a version restored from the
    /// ledger in the same tick as the keep before it. Sorting then fell back to the ids, which are
    /// random, so "the newest version" — what a section plays — could be an older one. The graph
    /// is append-only, so the order it holds is the order things happened.
    public func versions(of partID: PartID) -> [PartVersion] {
        versions.filter { $0.partID == partID }
    }

    /// The newest version of a part.
    public func latestVersion(of partID: PartID) -> PartVersion? { versions(of: partID).last }

    /// The version a lane plays: its pin when the song still holds it, otherwise the part's newest.
    ///
    /// A pin to a version the song no longer holds follows the part rather than going silent. The
    /// form said "this part"; losing one of its versions is not a reason to stop playing it.
    public func version(playing lane: Lane) -> PartVersion? {
        if let pin = lane.pin, let pinned = version(pin) { return pinned }
        return latestVersion(of: lane.part)
    }

    /// Everything a section plays, in stitch order, skipping any lane whose part the song no longer
    /// holds at all.
    public func versions(playing section: Section) -> [PartVersion] {
        section.stitch.compactMap { version(playing: $0) }
    }

    /// Lanes for these versions: each one's part, following it. What a caller holding version ids
    /// means when it says "a section that plays these".
    public func lanes(_ ids: [VersionID]) -> [Lane] {
        ids.compactMap { version($0).map { Lane(part: $0.partID) } }
    }

    /// An experiment as a section: **pinned**, because an experiment is a named combination of
    /// these particular versions and not of whatever their parts become later. It is the one place
    /// in the app that pins on purpose, and the reason `Lane.pin` exists at all.
    public func stitched(_ experiment: Experiment, as name: String? = nil, lengthInBars: Int) -> Section {
        Section(name: name ?? experiment.name,
                stitch: experiment.versions.compactMap { id in
                    version(id).map { Lane(part: $0.partID, pin: id) }
                },
                lengthInBars: lengthInBars)
    }

    /// Every distinct part in the song, in order of first appearance.
    public var partIDs: [PartID] {
        var seen = Set<PartID>()
        return versions.compactMap { seen.insert($0.partID).inserted ? $0.partID : nil }
    }

    // MARK: Variations

    /// What makes this part a variation, when it is one. Read from any of its versions: a version
    /// written without the mark — by a tool that builds one by hand — does not make the part stop
    /// being what its first version said it was.
    public func variation(of part: PartID) -> Variation? {
        versions.first { $0.partID == part && $0.variation != nil }?.variation
    }

    public func isVariation(_ part: PartID) -> Bool { variation(of: part) != nil }

    /// The part whose strip, instrument and sampler this part sounds through: itself, unless it is
    /// a variation, and then the part it is a variation of. A variation of a variation follows to
    /// the root; a chain that comes back on itself stops where it started.
    public func strip(of part: PartID) -> PartID {
        var current = part
        var seen: Set<PartID> = [part]
        while let next = variation(of: current)?.of, seen.insert(next).inserted, latestVersion(of: next) != nil {
            current = next
        }
        return current
    }

    /// Every variation of a part, by part, in order of first appearance.
    public func variations(of part: PartID) -> [PartID] {
        partIDs.filter { $0 != part && isVariation($0) && strip(of: $0) == part }
    }

    /// The parts a section's lane for `part` must not sound beside: the part it varies, and that
    /// part's other variations. They are one instrument, and one player plays one thing at a time.
    public func family(of part: PartID) -> Set<PartID> {
        let root = strip(of: part)
        return Set([root] + variations(of: root))
    }

    public func section(_ id: SectionID) -> Section? { sections.first { $0.id == id } }
    public func seed(_ id: SeedID) -> Seed? { seeds.first { $0.id == id } }
    public func experiment(_ id: ExperimentID) -> Experiment? { experiments.first { $0.id == id } }

    /// Every media file the song depends on, deduplicated, in order of first reference.
    public var mediaReferences: [MediaRef] {
        var seen = Set<MediaRef>()
        let all = seeds.flatMap(\.mediaReferences) + versions.flatMap(\.mediaReferences)
        return all.filter { seen.insert($0).inserted }
    }

    /// Total length in bars of the sections.
    public var lengthInBars: Int { sections.reduce(0) { $0 + $1.lengthInBars } }
}

/// Loudness targets for delivery.
public struct MasteringTargets: Hashable, Codable, Sendable {
    /// Integrated loudness target in LUFS.
    public var integratedLUFS: Double
    /// True-peak ceiling in dBTP.
    public var truePeakDBTP: Double

    public init(integratedLUFS: Double = -14, truePeakDBTP: Double = -1) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
    }

    public static let streaming = MasteringTargets(integratedLUFS: -14, truePeakDBTP: -1)
}

/// Whether a sampled source has been cleared.
public enum ClearanceStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case uncleared, pending, cleared, notRequired
}

/// The clearance state of one sampled source.
public struct SampleClearance: Hashable, Codable, Sendable {
    /// Human name of the source: "Artist – Title (Label, 1974)".
    public var source: String
    public var status: ClearanceStatus
    /// The library record the samples came from, when it is in the library.
    public var record: RecordID?
    public var note: String?
    /// The media a source with no record points at: what keeps its clearance when the song it is
    /// named after is renamed. Nil for a source with a record, and for one kept before this was.
    public var media: MediaRef?

    public init(source: String, status: ClearanceStatus = .uncleared, record: RecordID? = nil, note: String? = nil,
                media: MediaRef? = nil) {
        self.source = source
        self.status = status
        self.record = record
        self.note = note
        self.media = media
    }

    /// Whether this is the stored state of a source: by its record, else by its media, else — for
    /// one kept before either was — by its name.
    public func matches(source: String, record: RecordID?, media: MediaRef?) -> Bool {
        if let record { return self.record == record }
        guard self.record == nil else { return false }
        if let media, let mine = self.media { return mine == media }
        return self.source == source
    }
}

/// An album: ordered songs, delivery targets, and sample clearances per source. Since M7: the
/// gap before each track, liner notes, a cover, and what each track was released as.
public struct Album: Identifiable, Hashable, Codable, Sendable {
    public let id: AlbumID
    public var title: String
    public var artist: String
    public var songs: [SongID]
    public var targets: MasteringTargets
    public var clearances: [SampleClearance]
    public let createdAt: Date
    /// Seconds of silence before a track; a track not listed gets `Album.defaultGap`.
    public var gaps: [SongID: Double]
    /// Liner notes: what the record is about, in the house's words.
    public var notes: String
    /// The cover: an image in the library, or a design the app draws.
    public var cover: Cover
    /// What each track was cut as, the last time the album was released.
    public var releases: [SongID: TrackRelease]

    public static let defaultGap = 2.0

    public init(id: AlbumID = AlbumID(), title: String, artist: String = "", songs: [SongID] = [],
                targets: MasteringTargets = .streaming, clearances: [SampleClearance] = [], createdAt: Date = Date(),
                gaps: [SongID: Double] = [:], notes: String = "", cover: Cover = .drawn(CoverDesign()), releases: [SongID: TrackRelease] = [:]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.songs = songs
        self.targets = targets
        self.clearances = clearances
        self.createdAt = createdAt.graphPrecision
        self.gaps = gaps
        self.notes = notes
        self.cover = cover
        self.releases = releases
    }

    public func gap(before song: SongID) -> Double { gaps[song] ?? Album.defaultGap }

    private enum CodingKeys: String, CodingKey { case id, title, artist, songs, targets, clearances, createdAt, gaps, notes, cover, releases }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AlbumID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        songs = try c.decode([SongID].self, forKey: .songs)
        targets = try c.decode(MasteringTargets.self, forKey: .targets)
        clearances = try c.decode([SampleClearance].self, forKey: .clearances)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        gaps = try c.decodeIfPresent([SongID: Double].self, forKey: .gaps) ?? [:]
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        cover = try c.decodeIfPresent(Cover.self, forKey: .cover) ?? .drawn(CoverDesign())
        releases = try c.decodeIfPresent([SongID: TrackRelease].self, forKey: .releases) ?? [:]
    }
}

/// The cover: an image in the library, or a design the app draws from the title and the artist.
public enum Cover: Hashable, Codable, Sendable {
    case image(MediaRef)
    case drawn(CoverDesign)

    public var design: CoverDesign? { if case .drawn(let d) = self { return d }; return nil }
    public var image: MediaRef? { if case .image(let m) = self { return m }; return nil }
}

/// A typographic cover: the title and the artist on a two-colour field, in one of four layouts.
public struct CoverDesign: Hashable, Codable, Sendable {
    public enum Layout: String, Codable, Sendable, CaseIterable { case band, corner, stack, monogram }
    public var layout: Layout
    /// Hex colours, "#rrggbb".
    public var paper: String
    public var ink: String

    public init(layout: Layout = .band, paper: String = "#eef0f3", ink: String = "#14171a") {
        self.layout = layout
        self.paper = paper
        self.ink = ink
    }
}

/// What a track was cut as when the album was released.
public struct TrackRelease: Hashable, Codable, Sendable {
    public var mixVersion: VersionID?
    public var integratedLUFS: Double
    public var truePeakDBTP: Double
    public var durationSeconds: Double
    /// The gain applied to match the album's target, dB.
    public var trimDB: Double
    public var releasedAt: Date

    public init(mixVersion: VersionID?, integratedLUFS: Double, truePeakDBTP: Double, durationSeconds: Double, trimDB: Double, releasedAt: Date = Date()) {
        self.mixVersion = mixVersion
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.durationSeconds = durationSeconds
        self.trimDB = trimDB
        self.releasedAt = releasedAt.graphPrecision
    }
}

/// An imported record: media plus metadata and, once analyzed, an analysis part version.
public struct Record: Identifiable, Hashable, Codable, Sendable {
    public let id: RecordID
    public var title: String
    public var artist: String
    public var media: MediaRef
    /// An `.analysis` version describing the record, when analyzed.
    public var analysis: PartVersion?
    public let importedAt: Date
    /// Its stems, separated once and kept beside it in the library's `records/`, so every song
    /// takes from the same files. Nil until it is separated; optional so a library from before it
    /// round-trips byte for byte.
    public var stems: [RecordStem]?
    /// A correction of the grid its analysis read: what `reading` reads it through. Nil: as read.
    public var grid: RecordGrid?

    public init(id: RecordID = RecordID(), title: String, artist: String = "", media: MediaRef,
                analysis: PartVersion? = nil, importedAt: Date = Date(), stems: [RecordStem]? = nil, grid: RecordGrid? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.media = media
        self.analysis = analysis
        self.importedAt = importedAt.graphPrecision
        self.stems = stems
        self.grid = grid
    }

    public var mediaReferences: [MediaRef] { [media] + (stems ?? []).map(\.media) + (analysis?.mediaReferences ?? []) }

    /// The stem by that name, when it has been separated.
    public func stem(named name: String) -> RecordStem? { stems?.first { $0.name == name } }

    /// The analysis it carries, read through its grid's correction, when it has been analysed.
    public var reading: MusicAnalysis? {
        guard let grid else { return readingAsRead }
        return readingAsRead?.regridded(grid)
    }

    /// The analysis as the trackers read it, before any correction.
    public var readingAsRead: MusicAnalysis? {
        if let analysis, case .analysis(let reading) = analysis.kind { return reading }
        return nil
    }
}

/// A correction of a record's beat grid, for bar lines a tracker misread: the second tracker's
/// beats in place of the first's, the tempo halved for a tracker that counted double time or
/// doubled for one that counted half, the downbeat moved by whole beats. Kept on the record; the
/// analysis itself is never rewritten, so "as read" is always one step away.
public struct RecordGrid: Hashable, Codable, Sendable {
    public var secondTracker: Bool
    /// 0.5 halved, 1 as read, 2 doubled.
    public var tempo: Double
    /// Beats the downbeat moves, later when positive.
    public var downbeat: Int

    public init(secondTracker: Bool = false, tempo: Double = 1, downbeat: Int = 0) {
        self.secondTracker = secondTracker
        self.tempo = tempo
        self.downbeat = downbeat
    }

    public var isAsRead: Bool { !secondTracker && tempo == 1 && downbeat == 0 }

    /// "the second tracker's, halved, downbeat a beat later"; "as read" when nothing is changed.
    public var description: String {
        var pieces: [String] = []
        if secondTracker { pieces.append("the second tracker's") }
        if tempo < 1 { pieces.append("halved") } else if tempo > 1 { pieces.append("doubled") }
        if downbeat != 0 {
            let beats = abs(downbeat) == 1 ? "a beat" : "\(abs(downbeat)) beats"
            pieces.append("downbeat \(beats) \(downbeat > 0 ? "later" : "earlier")")
        }
        return pieces.isEmpty ? "as read" : pieces.joined(separator: ", ")
    }
}

/// One stem of a record: its audio, and how much of the record it is.
public struct RecordStem: Hashable, Codable, Sendable {
    /// "vocals", "drums", "bass" or "other".
    public var name: String
    public var media: MediaRef
    public var sampleRate: Double
    public var channelCount: Int
    public var duration: Double
    /// Integrated loudness, LUFS. Nil when it is too quiet to read: a stem the record hardly has.
    public var lufs: Double?
    /// Its loudness against the whole record's, dB: near zero when it is nearly all of the record,
    /// far below when it is hardly there.
    public var relativeDB: Double?
    /// Its level in each of the record's analysed bars, dBFS RMS to a tenth: where it plays and
    /// where it rests. Nil when the record had no bars when it was read.
    public var barLevels: [Double]?

    public init(name: String, media: MediaRef, sampleRate: Double, channelCount: Int, duration: Double,
                lufs: Double? = nil, relativeDB: Double? = nil, barLevels: [Double]? = nil) {
        self.name = name
        self.media = media
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.lufs = lufs
        self.relativeDB = relativeDB
        self.barLevels = barLevels
    }
}

/// One lyric of the house's own, kept whole: a title and its lines.
public struct VoiceLyric: Hashable, Codable, Sendable, Identifiable {
    public var title: String
    public var text: String
    /// Where it came from: an album, a file, a date.
    public var source: String?

    public var id: String { title }

    public init(title: String, text: String, source: String? = nil) {
        self.title = title
        self.text = text
        self.source = source
    }
}

/// A sample in the library's collection.
public struct LibrarySample: Identifiable, Hashable, Codable, Sendable {
    public let id: SampleID
    public var name: String
    public var sample: Sample
    public var tags: [String]
    public let addedAt: Date

    public init(id: SampleID = SampleID(), name: String, sample: Sample, tags: [String] = [], addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sample = sample
        self.tags = tags
        self.addedAt = addedAt.graphPrecision
    }

    public var media: MediaRef { sample.media }
}

/// The library: songs, albums, ideas (part versions belonging to no song), imported records and samples.
public struct Library: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public var songs: [Song]
    public var albums: [Album]
    public var ideas: [PartVersion]
    public var records: [Record]
    public var samples: [LibrarySample]
    /// The house voice: the lyrics this house has written, for a Lyricist to read new words against.
    /// Optional so a library from before it round-trips byte for byte.
    public var voice: [VoiceLyric]?
    /// What this house decided on the cast's open questions, for every song. A song's own call on
    /// the same question overrides it. Optional so a library from before it round-trips.
    public var houseCalls: [HouseCallRecord]?
    /// What the band has said, and how often. Optional for the same reason.
    public var said: [SaidRecord]?

    public init(songs: [Song] = [], albums: [Album] = [], ideas: [PartVersion] = [], records: [Record] = [],
                samples: [LibrarySample] = [], voice: [VoiceLyric]? = nil) {
        schemaVersion = SongGraphSchema.current
        self.songs = songs
        self.albums = albums
        self.ideas = ideas
        self.records = records
        self.samples = samples
        self.voice = voice
    }

    public func song(_ id: SongID) -> Song? { songs.first { $0.id == id } }
    public func album(_ id: AlbumID) -> Album? { albums.first { $0.id == id } }
    public func record(_ id: RecordID) -> Record? { records.first { $0.id == id } }
    public func sample(_ id: SampleID) -> LibrarySample? { samples.first { $0.id == id } }

    /// Replaces the song with the same id, or appends it.
    public mutating func upsert(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song } else { songs.append(song) }
    }

    /// Replaces the album with the same id, or appends it.
    public mutating func upsert(_ album: Album) {
        if let index = albums.firstIndex(where: { $0.id == album.id }) { albums[index] = album } else { albums.append(album) }
    }

    /// The record whose media this is, when the library holds one.
    public func record(forMedia media: MediaRef) -> Record? { records.first { $0.media == media } }

    /// Media referenced at the library level (records, samples, ideas), deduplicated.
    public var mediaReferences: [MediaRef] {
        var seen = Set<MediaRef>()
        let all = records.flatMap(\.mediaReferences) + samples.map(\.media) + ideas.flatMap(\.mediaReferences)
        return all.filter { seen.insert($0).inserted }
    }
}


extension Array where Element == PartVersion {
    /// These versions as lanes that follow their parts: what a default stitch is, and what nearly
    /// every caller that used to hand `Section` a list of version ids actually meant.
    public var lanes: [Lane] { map { Lane(part: $0.partID) } }
}

extension Array where Element == PartID {
    /// These parts as lanes that follow them.
    public var lanes: [Lane] { map { Lane(part: $0) } }
}

extension Array where Element == Lane {
    public func contains(part: PartID) -> Bool { contains { $0.part == part } }
}
