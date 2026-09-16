import Foundation
import MusicTheory

/// The schema version of documents this build reads and writes.
public enum SongGraphSchema {
    public static let current = 2
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

/// A section of a song: a name, the specific part versions stitched together, and its length in bars.
public struct Section: Identifiable, Hashable, Codable, Sendable {
    public let id: SectionID
    public var name: String
    /// The stitch: the part versions this section plays, in order of layering.
    public var stitch: [VersionID]
    public var lengthInBars: Int
    /// 0…1, when the arrangement has an intensity curve.
    public var intensity: Double?
    public var transitionIn: Transition?
    public var transitionOut: Transition?

    public init(id: SectionID = SectionID(), name: String, stitch: [VersionID], lengthInBars: Int,
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

    /// Turns the experiment into a section that stitches exactly these versions.
    public func stitched(as name: String? = nil, lengthInBars: Int) -> Section {
        Section(name: name ?? self.name, stitch: versions, lengthInBars: lengthInBars)
    }
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

    /// Every version of a part, oldest first.
    public func versions(of partID: PartID) -> [PartVersion] {
        versions.filter { $0.partID == partID }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The newest version of a part.
    public func latestVersion(of partID: PartID) -> PartVersion? { versions(of: partID).last }

    /// Every distinct part in the song, in order of first appearance.
    public var partIDs: [PartID] {
        var seen = Set<PartID>()
        return versions.compactMap { seen.insert($0.partID).inserted ? $0.partID : nil }
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

    public init(source: String, status: ClearanceStatus = .uncleared, record: RecordID? = nil, note: String? = nil) {
        self.source = source
        self.status = status
        self.record = record
        self.note = note
    }
}

/// An album: ordered songs, delivery targets, and sample clearances per source.
public struct Album: Identifiable, Hashable, Codable, Sendable {
    public let id: AlbumID
    public var title: String
    public var artist: String
    public var songs: [SongID]
    public var targets: MasteringTargets
    public var clearances: [SampleClearance]
    public let createdAt: Date

    public init(id: AlbumID = AlbumID(), title: String, artist: String = "", songs: [SongID] = [],
                targets: MasteringTargets = .streaming, clearances: [SampleClearance] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.artist = artist
        self.songs = songs
        self.targets = targets
        self.clearances = clearances
        self.createdAt = createdAt.graphPrecision
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

    public init(id: RecordID = RecordID(), title: String, artist: String = "", media: MediaRef,
                analysis: PartVersion? = nil, importedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.artist = artist
        self.media = media
        self.analysis = analysis
        self.importedAt = importedAt.graphPrecision
    }

    public var mediaReferences: [MediaRef] { [media] + (analysis?.mediaReferences ?? []) }
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

    public init(songs: [Song] = [], albums: [Album] = [], ideas: [PartVersion] = [], records: [Record] = [],
                samples: [LibrarySample] = []) {
        schemaVersion = SongGraphSchema.current
        self.songs = songs
        self.albums = albums
        self.ideas = ideas
        self.records = records
        self.samples = samples
    }

    public func song(_ id: SongID) -> Song? { songs.first { $0.id == id } }
    public func album(_ id: AlbumID) -> Album? { albums.first { $0.id == id } }
    public func record(_ id: RecordID) -> Record? { records.first { $0.id == id } }
    public func sample(_ id: SampleID) -> LibrarySample? { samples.first { $0.id == id } }

    /// Replaces the song with the same id, or appends it.
    public mutating func upsert(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song } else { songs.append(song) }
    }

    /// Media referenced at the library level (records, samples, ideas), deduplicated.
    public var mediaReferences: [MediaRef] {
        var seen = Set<MediaRef>()
        let all = records.flatMap(\.mediaReferences) + samples.map(\.media) + ideas.flatMap(\.mediaReferences)
        return all.filter { seen.insert($0).inserted }
    }
}
