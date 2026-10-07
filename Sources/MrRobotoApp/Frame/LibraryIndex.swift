import CryptoKit
import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The library browser's index: what is known about everything in the library, so a list can be
// searched, filtered and sorted, and a song described, without opening anything.
//
// Nothing here reads the disk. Every song is in `AppState.library` from the moment the library is
// read, so the facts are a reading of what the frame already holds, with the open song as it
// stands in place of the copy last saved. A package's file date is not when its song was last
// worked on: a save writes every package in the library, so every `song.json` carries the date of
// the last save of any song. The newest version a song holds is.

/// The shelves of the library browser.
public enum LibraryShelf: String, CaseIterable, Codable, Sendable {
    case songs, records, ideas, samples, albums
    /// What the parts play on: the built-in instruments and those imported from SFZ packs.
    case instruments
    /// What the drums play on: the machines, and the kits of recordings brought in beside them.
    case kits

    public var title: String { rawValue.capitalized }

    /// The shelves that hold what the house made and brought in, as against what it plays on.
    public var isLibrary: Bool { self != .instruments && self != .kits }
}

/// One item in the library, by its shelf and its id.
public struct LibraryItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var shelf: LibraryShelf
    public var id: UUID

    public init(_ shelf: LibraryShelf, _ id: UUID) {
        self.shelf = shelf
        self.id = id
    }

    public static func song(_ id: SongID) -> Self { Self(.songs, id.rawValue) }
    public static func record(_ id: RecordID) -> Self { Self(.records, id.rawValue) }
    public static func idea(_ id: VersionID) -> Self { Self(.ideas, id.rawValue) }
    public static func sample(_ id: SampleID) -> Self { Self(.samples, id.rawValue) }
    public static func album(_ id: AlbumID) -> Self { Self(.albums, id.rawValue) }
    /// An instrument or a kit, by its own id: a UUID made from that, the same at every launch.
    public static func instrument(_ id: String) -> Self { Self(.instruments, UUID(stableFrom: "instrument:" + id)) }
    public static func kit(_ id: String) -> Self { Self(.kits, UUID(stableFrom: "kit:" + id)) }

    public var description: String { "\(shelf.rawValue):\(id.uuidString)" }
}

extension UUID {
    /// A UUID made from text, the same for the same text: an instrument's id as an item's.
    init(stableFrom text: String) {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// What the index knows about one item: enough to list it, search it, filter it and sort it. A
/// fact an item does not have is nil — a groove has no key, a record not yet read has no tempo.
public struct LibraryFacts: Hashable, Sendable, Identifiable {
    public var id: LibraryItemID
    public var title: String
    /// A song's, record's or album's artist. Empty when nobody said.
    public var artist = ""
    public var key: Key?
    /// Beats per minute.
    public var tempo: Double?
    public var bars: Int?
    /// How long it plays: a song's form at its tempo, a record's reading, an album's songs and
    /// the gaps between them, an idea's audio.
    public var seconds: Double?
    /// The genre's profile id and name. `genreIsGuessed` when it was read from a groove's feel
    /// rather than said.
    public var genreID: String?
    public var genre: String?
    public var genreIsGuessed = false
    /// What a song is about, when someone wrote it down.
    public var brief: String?
    /// When it was last worked on: a song's newest version, a record's import, a sample's keeping,
    /// an album's last release.
    public var changed: Date
    /// Integrated loudness, LUFS, where it was measured: a song's last release on an album, a
    /// record's reading.
    public var loudness: Double?
    /// A record's stems. Nil until it is separated.
    public var stems: Int?
    /// Cents a record sits off concert pitch, once measured.
    public var tuning: Double?
    /// A record's grid correction, as said ("halved"). Nil when it is read as the tracker read it.
    public var grid: String?
    /// An idea's kind of part.
    public var kind: PartType?
    /// An idea's note, or what made it; a sample's chain.
    public var note: String?
    /// A sample's root.
    public var root: Pitch?
    public var slices: Int?
    public var tags: [String] = []
    /// The record an idea or a sample came from, by title, when it is still on the shelf.
    public var source: String?
    /// Songs it is in: a record's, idea's or sample's takers; an album's tracks.
    public var songs = 0
    /// Records a song takes from.
    public var records = 0
    /// Albums a song is on.
    public var albums = 0
    /// How it goes with the open song: a record's, an idea's or a sample's, while a song is open.
    public var fit: LibraryFit?
    /// An instrument's or a kit's own id ("rhodes", "tr808"): what a part's pick names.
    public var code: String?
    /// An instrument's family ("Keys", "Pads & voices"), a kit's ("Drum machines").
    public var family: String?
    /// The keys an instrument's recordings reach ("E1–G4"), and the lowest of them, to sort by.
    public var range: String?
    public var rangeLow: Int?
    /// Where an instrument or a kit comes from: "Built in", or the SFZ file it was imported from.
    public var pack: String?
    /// Brought in, so it can be taken out again.
    public var isImported = false
    /// Marked a favourite.
    public var favourite = false
    /// The tags put on it (its mark's), apart from the ones it came with (a sample's).
    public var markedTags: [String] = []
    /// Everything the text search reads, folded (`LibraryIndex.fold`).
    public var searchText = ""

    /// Off concert pitch by enough that fitting it moves it (`SourceFitting.leastCents`).
    public var isOffPitch: Bool { tuning.map { abs($0) >= SourceFitting.leastCents } ?? false }
}

/// One way a song takes from a record: a part made from it, or the record the song grew from.
public struct RecordUse: Hashable, Sendable {
    public var song: SongID
    public var record: RecordID
    /// The part, or nil for a song that grew from the record (a seed) with no part from it.
    public var part: PartID?
    /// What the part is called ("Drums stem of Drifter", "Bar 12"); empty for a seed.
    public var title: String
    /// "vocals", "drums", "bass", "other", or nil for the whole record.
    public var stem: String?
    /// The record's bars a clip takes, 0-based, the end not included; nil for a whole stem.
    public var bars: Range<Int>? = nil
}

/// The facts about everything in the library, and how its things are related, both ways.
public struct LibraryIndex: Sendable {

    /// Everything, shelf by shelf, each shelf in the library's own order.
    public private(set) var items: [LibraryFacts] = []
    private var position: [LibraryItemID: Int] = [:]

    // What a song is made of, kept per song so the open song can be read again alone.
    private var readings: [SongID: SongReading] = [:]
    private var songOrder: [SongID] = []

    // The other way round.
    private var usesByRecord: [RecordID: [RecordUse]] = [:]
    private var holders: [LibraryItemID: [SongID]] = [:]
    private var albumsBySong: [SongID: [AlbumID]] = [:]
    private var sources: [LibraryItemID: RecordID] = [:]
    private var chopsByRecord: [RecordID: [SampleID]] = [:]

    // What reading a song needs from the rest of the library.
    private var lookups = Lookups()
    /// The library's marks, put back on a song read again.
    private var marks: [LibraryMark] = []
    private let genres: GenreBook

    /// The open song's key, tempo and meter, which every record, idea and sample is fitted to.
    /// Nil with no song open.
    public private(set) var fitTarget: FitTarget?

    /// The index of `library`, reading `openSong` in place of the library's copy of it. A song
    /// the library does not hold yet is not listed, as the sidebar does not list it. `sounds`: the
    /// instruments and kits it lists beside the library.
    public init(library: Library, openSong: Song? = nil, genres: GenreBook = .standard, sounds: LibrarySounds = .builtIn) {
        self.genres = genres
        lookups = Lookups(library)

        for album in library.albums {
            for song in album.songs where albumsBySong[song]?.contains(album.id) != true {
                albumsBySong[song, default: []].append(album.id)
            }
        }
        for entry in library.samples {
            if let record = lookups.record(of: .sample(entry.sample))?.record {
                sources[.sample(entry.id)] = record
                chopsByRecord[record, default: []].append(entry.id)
            }
        }
        for idea in library.ideas {
            if let record = lookups.record(of: idea.kind)?.record { sources[.idea(idea.id)] = record }
        }

        var songFacts: [LibraryFacts] = []
        for stored in library.songs {
            let song = openSong?.id == stored.id ? openSong! : stored
            let reading = read(song)
            readings[song.id] = reading
            songOrder.append(song.id)
            for use in reading.uses { usesByRecord[use.record, default: []].append(use) }
            for item in reading.holds { holders[item, default: []].append(song.id) }
            songFacts.append(reading.facts)
        }

        var all = songFacts
        all += library.records.map(Self.facts(of:))
        all += library.ideas.map(ideaFacts)
        all += library.samples.map(sampleFacts)
        all += library.albums.map(albumFacts)
        all += sounds.instruments.map(Self.facts(of:))
        all += sounds.kits.map(Self.facts(of:))
        // What people put on things to find them again: a favourite, tags, searched like the rest.
        for index in all.indices {
            guard let mark = library.mark(all[index].id.markKind, all[index].id.id) else { continue }
            all[index].favourite = mark.isFavourite
            all[index].markedTags = mark.tags ?? []
            all[index].tags = Self.unique(all[index].tags + all[index].markedTags)
            if !all[index].markedTags.isEmpty { all[index].searchText += " · " + Self.fold(all[index].markedTags.joined(separator: " · ")) }
        }
        marks = library.marks ?? []
        items = all
        for (index, facts) in items.enumerated() { position[facts.id] = index }
        for index in items.indices { count(&items[index]) }
        fit(to: FitTarget.of(openSong))
    }

    // MARK: Reading it

    public func facts(_ id: LibraryItemID) -> LibraryFacts? { position[id].map { items[$0] } }

    /// One shelf, in the library's order.
    public func items(on shelf: LibraryShelf) -> [LibraryFacts] { items.filter { $0.id.shelf == shelf } }

    /// The records a song takes from, in the order its parts first take from them.
    public func records(in song: SongID) -> [RecordID] { readings[song]?.records ?? [] }

    /// Every part of every song that takes from a record, songs in the library's order.
    public func uses(of record: RecordID) -> [RecordUse] { usesByRecord[record] ?? [] }

    /// The songs that take from a record.
    public func songs(using record: RecordID) -> [SongID] { Self.unique(uses(of: record).map(\.song)) }

    /// The songs holding an idea's or a sample's music.
    public func songs(holding item: LibraryItemID) -> [SongID] { holders[item] ?? [] }

    /// The albums a song is on.
    public func albums(holding song: SongID) -> [AlbumID] { albumsBySong[song] ?? [] }

    /// The record an idea or a sample came from, when it is on the shelf.
    public func source(of item: LibraryItemID) -> RecordID? { sources[item] }

    /// The samples cut from a record.
    public func chops(of record: RecordID) -> [SampleID] { chopsByRecord[record] ?? [] }

    // MARK: The open song

    /// Reads one song again — the open one, after a change — and what it touches: the records it
    /// takes from and took from, the ideas and samples it holds and held, its albums. A song the
    /// index does not list is left out, as `init` leaves it.
    public mutating func refresh(_ song: Song) {
        // What everything is fitted to follows the open song, saved or not.
        if FitTarget.of(song) != fitTarget { fit(to: FitTarget.of(song)) }
        guard let old = readings[song.id] else { return }
        var new = read(song)
        if let mark = marks.first(where: { $0.kind == .song && $0.id == song.id.rawValue }) {
            new.facts.favourite = mark.isFavourite
            new.facts.markedTags = mark.tags ?? []
            new.facts.tags = new.facts.markedTags
            if !new.facts.markedTags.isEmpty { new.facts.searchText += " · " + Self.fold(new.facts.markedTags.joined(separator: " · ")) }
        }
        readings[song.id] = new
        if let index = position[.song(song.id)] { items[index] = new.facts }

        for record in Self.unique(old.records + new.records) {
            usesByRecord[record] = songOrder.flatMap { id in readings[id]?.uses.filter { $0.record == record } ?? [] }
            if usesByRecord[record]?.isEmpty == true { usesByRecord[record] = nil }
        }
        let touched = Self.unique(old.holds + new.holds)
        for item in touched {
            holders[item] = songOrder.filter { readings[$0]?.holds.contains(item) == true }
            if holders[item]?.isEmpty == true { holders[item] = nil }
        }
        var recount: [LibraryItemID] = [.song(song.id)]
        recount += Self.unique(old.records + new.records).map { LibraryItemID.record($0) }
        recount += touched
        for album in albums(holding: song.id) {
            guard let index = position[.album(album)], let stored = lookups.albums[album] else { continue }
            items[index] = albumFacts(stored)
            recount.append(.album(album))
        }
        for id in recount { if let index = position[id] { count(&items[index]) } }
    }

    // MARK: Songs

    /// A song as the index keeps it: its facts, and what it takes from the rest of the library.
    private struct SongReading: Sendable {
        var facts: LibraryFacts
        var records: [RecordID]
        var uses: [RecordUse]
        /// Ideas and samples whose music it holds.
        var holds: [LibraryItemID]
    }

    /// Every tag on a shelf, in the order the shelf first has them.
    public func tags(on shelf: LibraryShelf) -> [String] { Self.unique(items(on: shelf).flatMap(\.tags)) }

    private func read(_ song: Song) -> SongReading {
        var facts = LibraryFacts(id: .song(song.id), title: song.title, changed: song.createdAt)
        facts.artist = song.artist
        facts.key = song.key
        facts.tempo = song.tempo
        facts.bars = song.lengthInBars
        if song.lengthInBars > 0, song.tempo > 0 {
            facts.seconds = Double(song.lengthInBars * song.timeSignature.beatsPerBar) * 60 / song.tempo
        }
        if let genre = genres.genre(of: song) {
            facts.genreID = genre.profile.id
            facts.genre = genre.profile.name
            facts.genreIsGuessed = genre.source != .set
        }
        facts.brief = song.brief
        facts.changed = song.versions.map(\.createdAt).max().map { max($0, song.createdAt) } ?? song.createdAt
        facts.loudness = lookups.releases[song.id]?.integratedLUFS

        // What it takes from the crate: one use per part, said the way its newest version says it,
        // and the record it grew from when no part of it takes from that record.
        var uses: [RecordUse] = []
        var usePlace: [PartID: Int] = [:]
        var holds: [LibraryItemID] = []
        for version in song.versions {
            if let found = lookups.record(of: version.kind) {
                let use = RecordUse(song: song.id, record: found.record, part: version.partID,
                                    title: PartLabel.title(of: version), stem: found.stem, bars: Lookups.bars(of: version.kind))
                if let place = usePlace[version.partID] { uses[place] = use } else {
                    usePlace[version.partID] = uses.count
                    uses.append(use)
                }
            }
            holds += lookups.held(by: version)
        }
        for seed in song.seeds {
            guard case .importedRecord(let record) = seed.kind, lookups.records[record] != nil,
                  !uses.contains(where: { $0.record == record }) else { continue }
            uses.append(RecordUse(song: song.id, record: record, part: nil, title: "", stem: nil))
        }
        let records = Self.unique(uses.map(\.record))
        facts.searchText = Self.searchText(facts, extra: [])
        return SongReading(facts: facts, records: records, uses: uses, holds: Self.unique(holds))
    }

    // MARK: Everything else

    /// A record's facts, as far as the record itself says: everything but what takes from it.
    static func facts(of record: Record) -> LibraryFacts {
        var facts = LibraryFacts(id: .record(record.id), title: record.title, changed: record.importedAt)
        facts.artist = record.artist
        let reading = record.reading
        facts.key = reading?.dominantKey
        facts.tempo = reading?.dominantTempo
        facts.bars = reading.flatMap { $0.bars.isEmpty ? nil : $0.bars.count }
        facts.seconds = reading?.duration ?? record.stems?.first?.duration
        facts.loudness = reading?.loudness?.integrated
        facts.stems = record.stems?.count
        facts.tuning = record.tuning
        facts.grid = record.grid.flatMap { $0.isAsRead ? nil : $0.description }
        facts.searchText = Self.searchText(facts, extra: (record.stems ?? []).map(\.name))
        return facts
    }

    private func ideaFacts(_ idea: PartVersion) -> LibraryFacts {
        var facts = LibraryFacts(id: .idea(idea.id), title: PartLabel.title(of: idea), changed: idea.createdAt)
        facts.kind = idea.type
        facts.note = idea.note ?? idea.operation
        switch idea.kind {
        case .progression(let progression):
            facts.key = progression.key
            facts.bars = progression.bars.count
        case .melody(let melody):
            facts.bars = melody.lengthInBars
        case .groove(let groove):
            facts.bars = groove.bars
        case .bassline(let bassline):
            facts.key = bassline.key
            facts.bars = bassline.lengthInBars
        case .sample(let sample):
            facts.key = sample.key
            facts.tempo = sample.detectedTempo
            facts.root = sample.rootPitch
            facts.slices = sample.slices.count
        case .audio(let audio):
            facts.seconds = audio.duration
        case .lyric, .sound, .analysis, .mix:
            break
        }
        facts.source = sources[.idea(idea.id)].flatMap { lookups.records[$0]?.title }
        facts.searchText = Self.searchText(facts, extra: [idea.type.rawValue])
        return facts
    }

    private func sampleFacts(_ entry: LibrarySample) -> LibraryFacts {
        Self.facts(of: entry, source: sources[.sample(entry.id)].flatMap { lookups.records[$0]?.title })
    }

    /// A sample's facts, as far as the sample itself says, and the title of the record it was cut from.
    static func facts(of entry: LibrarySample, source: String? = nil) -> LibraryFacts {
        var facts = LibraryFacts(id: .sample(entry.id), title: entry.name, changed: entry.addedAt)
        facts.key = entry.sample.key
        facts.tempo = entry.sample.detectedTempo
        facts.root = entry.sample.rootPitch
        facts.slices = entry.sample.slices.count
        facts.note = entry.sample.degradation.isEmpty ? nil : Dust.describe(entry.sample.degradation)
        facts.tags = entry.tags
        facts.source = source
        facts.searchText = Self.searchText(facts, extra: [])
        return facts
    }

    private func albumFacts(_ album: Album) -> LibraryFacts {
        var facts = LibraryFacts(id: .album(album.id), title: album.title,
                                 changed: album.releases.values.map(\.releasedAt).max().map { max($0, album.createdAt) } ?? album.createdAt)
        facts.artist = album.artist
        let lengths = album.songs.compactMap { id in readings[id]?.facts.seconds.map { $0 + album.gap(before: id) } }
        facts.seconds = lengths.isEmpty ? nil : lengths.reduce(0, +)
        facts.searchText = Self.searchText(facts, extra: [])
        return facts
    }

    /// Every record, idea and sample fitted to `target`, or to nothing.
    private mutating func fit(to target: FitTarget?) {
        fitTarget = target
        for index in items.indices {
            let id = items[index].id
            guard let target else {
                items[index].fit = nil
                continue
            }
            switch id.shelf {
            case .records: items[index].fit = lookups.records[RecordID(rawValue: id.id)].flatMap { LibraryFitting.fit($0, into: target) }
            case .ideas: items[index].fit = lookups.ideas[VersionID(rawValue: id.id)].flatMap { LibraryFitting.fit($0, into: target) }
            case .samples: items[index].fit = lookups.samples[SampleID(rawValue: id.id)].flatMap { LibraryFitting.fit($0, into: target) }
            case .songs, .albums, .instruments, .kits: items[index].fit = nil
            }
        }
    }

    /// The counts, which read the relations rather than the item.
    private func count(_ facts: inout LibraryFacts) {
        switch facts.id.shelf {
        case .songs:
            let id = SongID(rawValue: facts.id.id)
            facts.records = records(in: id).count
            facts.albums = albums(holding: id).count
        case .records:
            facts.songs = songs(using: RecordID(rawValue: facts.id.id)).count
        case .ideas, .samples:
            facts.songs = songs(holding: facts.id).count
        case .albums:
            facts.songs = lookups.albums[AlbumID(rawValue: facts.id.id)]?.songs.count ?? 0
        case .instruments, .kits:
            break
        }
    }

    // MARK: Instruments and kits

    /// An instrument as a shelf lists it: its family, the keys its recordings reach, where it
    /// came from, and what it sounds like.
    static func facts(of spec: InstrumentVoiceSpec) -> LibraryFacts {
        var facts = LibraryFacts(id: .instrument(spec.id), title: spec.name, changed: .distantPast)
        facts.code = spec.id
        facts.family = InstrumentPicker.families.first { $0.id == spec.family }?.title ?? spec.family.capitalized
        facts.note = InstrumentPicker.character(spec)
        if spec.engine == .sampled {
            let range = ImportedInstruments.range(of: spec)
            facts.range = range.map { "\(Pitch(midi: $0.lowerBound))–\(Pitch(midi: $0.upperBound))" }
            facts.rangeLow = range?.lowerBound
            // A section is made of the recordings in the library, not brought in: nothing to remove.
            facts.pack = spec.isEnsemble ? "Recorded section" : Self.sfz(in: spec.summary) ?? "Recorded"
            facts.isImported = !spec.isEnsemble && ImportedInstruments.spec(id: spec.id) != nil
        } else {
            facts.pack = "Built in"
        }
        facts.searchText = Self.searchText(facts, extra: [facts.family, facts.pack, spec.engine == .sampled ? "recorded" : "synthesized"].compactMap { $0 })
        return facts
    }

    /// A drum machine or a recorded kit as a shelf lists it.
    static func facts(of machine: SynthMachine) -> LibraryFacts {
        var facts = LibraryFacts(id: .kit(machine.id), title: machine.name, changed: .distantPast)
        facts.code = machine.id
        facts.family = machine.family.title
        facts.note = machine.summary
        facts.isImported = machine.family == .recorded
        facts.pack = facts.isImported ? "Recorded" : "Built in"
        facts.searchText = Self.searchText(facts, extra: [facts.family, facts.pack].compactMap { $0 })
        return facts
    }

    /// "Alto Recorder.sfz", from "Sampled, from Alto Recorder.sfz: 12 zones…".
    static func sfz(in summary: String) -> String? {
        guard let from = summary.range(of: "from "), let end = summary.range(of: ".sfz", range: from.upperBound..<summary.endIndex) else { return nil }
        return String(summary[from.upperBound..<end.upperBound])
    }

    // MARK: Searching

    /// Text as the search compares it: without case, accents or curly quotes, and with ♯ and ♭
    /// written the way a keyboard writes them, so "f# minor" finds F♯ minor.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
    }

    private static func searchText(_ facts: LibraryFacts, extra: [String]) -> String {
        var pieces = [facts.title, facts.artist]
        if let key = facts.key { pieces.append(key.name) }
        if let tempo = facts.tempo { pieces.append("\(Int(tempo.rounded())) bpm") }
        pieces += [facts.genre, facts.brief, facts.note, facts.source, facts.grid].compactMap { $0 }
        if let root = facts.root { pieces.append("\(root)") }
        pieces += facts.tags + extra
        return fold(pieces.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// The instruments and kits a library is listed with: process-wide, so passed in.
public struct LibrarySounds: Sendable {
    public var instruments: [InstrumentVoiceSpec]
    public var kits: [SynthMachine]

    public init(instruments: [InstrumentVoiceSpec] = [], kits: [SynthMachine] = []) {
        self.instruments = instruments
        self.kits = kits
    }

    /// The presets, the instruments imported and the kits brought in, as registered now.
    public static var builtIn: LibrarySounds {
        LibrarySounds(instruments: InstrumentVoiceSpec.all + ImportedInstruments.all, kits: SynthMachine.available)
    }
}

// MARK: - What reading a song needs

/// The rest of the library, as a song is read against it: which record a medium belongs to, which
/// ideas and samples a part's music is, what each song was last released as.
private struct Lookups: Sendable {
    var records: [RecordID: Record] = [:]
    var albums: [AlbumID: Album] = [:]
    var ideas: [VersionID: PartVersion] = [:]
    var samples: [SampleID: LibrarySample] = [:]
    /// A record's mix and each of its stems, by medium: the stem's name, or nil for the mix.
    var media: [MediaRef: (record: RecordID, stem: String?)] = [:]
    var samplesByMedia: [MediaRef: [SampleID]] = [:]
    var ideasByMedia: [MediaRef: [VersionID]] = [:]
    /// Ideas with no media, by their music: adopting one copies its kind into the song as it is.
    var ideasByKind: [PartKind: [VersionID]] = [:]
    var ideaTypes: Set<PartType> = []
    /// Each song's newest release on any album.
    var releases: [SongID: TrackRelease] = [:]

    init() {}

    init(_ library: Library) {
        for record in library.records {
            records[record.id] = record
            if media[record.media] == nil { media[record.media] = (record.id, nil) }
            for stem in record.stems ?? [] where media[stem.media] == nil { media[stem.media] = (record.id, stem.name) }
        }
        for album in library.albums {
            albums[album.id] = album
            for (song, release) in album.releases where releases[song].map({ $0.releasedAt < release.releasedAt }) ?? true {
                releases[song] = release
            }
        }
        for entry in library.samples {
            samplesByMedia[entry.media, default: []].append(entry.id)
            samples[entry.id] = entry
        }
        for idea in library.ideas {
            ideas[idea.id] = idea
            if let medium = idea.mediaReferences.first {
                ideasByMedia[medium, default: []].append(idea.id)
            } else {
                ideasByKind[idea.kind, default: []].append(idea.id)
                ideaTypes.insert(idea.type)
            }
        }
    }

    /// The record on the shelf this part's music was taken from, and which stem of it: a fit names
    /// it, a chop or a mashup's stem says where it was cut, or the medium is the record's own.
    func record(of kind: PartKind) -> (record: RecordID, stem: String?)? {
        let fit: SourceFit?, named: RecordID?, medium: MediaRef, stem: String?
        switch kind {
        case .sample(let sample):
            (fit, named, medium, stem) = (sample.fit, sample.sourceRecord, sample.media, nil)
        case .audio(let audio):
            (fit, named, medium, stem) = (audio.fit, audio.sourceRecord, audio.media, audio.role == .stem ? audio.stem : nil)
        default:
            return nil
        }
        let fitStem = fit.flatMap { $0.stem == "record" ? nil : $0.stem }
        if let id = fit?.record, records[id] != nil { return (id, fitStem ?? fit.flatMap { media[$0.media]?.stem }) }
        if let fit, let found = media[fit.media] { return (found.record, fitStem ?? found.stem) }
        if let id = named, records[id] != nil { return (id, stem ?? media[medium]?.stem) }
        if let found = media[medium] { return (found.record, found.stem ?? stem) }
        return nil
    }

    /// The record's bars a fitted clip takes: what its fit says.
    static func bars(of kind: PartKind) -> Range<Int>? {
        let fit: SourceFit?
        switch kind {
        case .sample(let sample): fit = sample.fit
        case .audio(let audio): fit = audio.fit
        default: return nil
        }
        guard let from = fit?.fromBar, let to = fit?.toBar, to > from else { return nil }
        return from..<to
    }

    /// The ideas and samples in the library whose music this version is.
    func held(by version: PartVersion) -> [LibraryItemID] {
        var held: [LibraryItemID] = []
        if case .sample(let sample) = version.kind {
            held += (samplesByMedia[sample.media] ?? []).map { .sample($0) }
        }
        if let medium = version.mediaReferences.first {
            held += (ideasByMedia[medium] ?? []).map { .idea($0) }
        } else if ideaTypes.contains(version.type) {
            held += (ideasByKind[version.kind] ?? []).map { .idea($0) }
        }
        return held
    }
}

// MARK: - The frame's index

extension AppState {
    /// Opens the Library surface, or brings it forward, with `item` chosen on its shelf.
    public func showInLibrary(_ item: LibraryItemID? = nil) {
        libraryAsk = item
        showSurface(.library)
    }

    /// Opens the Library surface, or brings it forward, on a search.
    public func showInLibrary(_ query: LibraryQuery) {
        libraryQueryAsk = query
        showSurface(.library)
    }

    /// The library as the browser reads it: every item's facts and how they are related, with the
    /// open song as it stands rather than as it was last saved. Built the first time it is read
    /// after the library changes; after a change to the open song, only that song is read again.
    public var libraryIndex: LibraryIndex {
        // Both read every time, so a view that reads the index follows the library and the song.
        let library = self.library, song = self.song
        // And what it plays on, as the frame has it, so an import or a removal is listed at once.
        _ = (importedInstruments, recordedKits)
        if var index = indexCache {
            if indexFollowsSong, let song {
                index.refresh(song)
                indexCache = index
            }
            indexFollowsSong = false
            return index
        }
        let index = LibraryIndex(library: library, openSong: song)
        indexCache = index
        indexFollowsSong = false
        return index
    }
}
