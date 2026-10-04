import Foundation
import MusicTheory
import Performance
import SongGraph

// M3's three, appended after `arrange` so every schema before them keeps its bytes: the library
// read, an item adopted into the song, and two fragments merged by the Sampler's rules.

// MARK: - read_library

/// Everything the library holds, with the key and tempo of each thing so a merge can be planned.
public struct ReadLibraryTool: DirectorTool {
    public struct Input: Decodable, Sendable {}

    public struct Output: Encodable, Sendable {
        public struct Idea: Encodable, Sendable {
            public var id: String
            public var title: String
            public var type: String
            public var key: String?
            public var note: String?
        }
        public struct RecordEntry: Encodable, Sendable {
            public var id: String
            public var title: String
            public var artist: String
            public var key: String?
            public var tempo: Double?
            public var bars: Int?
            /// Whether the open song already holds this record.
            public var inSong: Bool
            /// Its stems as the crate keeps them, each with how much of the record it is; "full" is
            /// always there for the whole record. Empty until it has been read.
            public var stems: [StemEntry]
            /// What the crate is doing to it, or why it last failed. Nil when nothing.
            public var status: String?
            /// The correction its grid is read through, when there is one: what key, tempo and bars
            /// above are read through.
            public var grid: String?
            /// How far the two beat trackers agreed, 0…1: well under 0.8 and its bar lines may be misread.
            public var trackersAgree: Double?
            /// The second tracker's tempo, and whether its beats are kept for fix_grid to take.
            public var secondTrackerTempo: Double?
            public var secondTrackerKept: Bool
            /// Cents it sits above concert pitch (below when negative), when it is far enough off to
            /// say: what adopt takes off as it fits a stem of it.
            public var tuningCents: Double?

            enum CodingKeys: String, CodingKey {
                case id, title, artist, key, tempo, bars, stems, status, grid
                case inSong = "in_song"
                case trackersAgree = "trackers_agree"
                case secondTrackerTempo = "second_tracker_tempo"
                case secondTrackerKept = "second_tracker_kept"
                case tuningCents = "tuning_cents"
            }
        }
        public struct StemEntry: Encodable, Sendable {
            public var name: String
            /// Its loudness against the whole record, dB: near 0 is most of the record.
            public var dbAgainstRecord: Double?
            /// The record's bar, 1-based, it first plays in at its usual level.
            public var comesInAtBar: Int?

            enum CodingKeys: String, CodingKey {
                case name
                case dbAgainstRecord = "db_against_record"
                case comesInAtBar = "comes_in_at_bar"
            }
        }
        public struct SampleEntry: Encodable, Sendable {
            public var id: String
            public var name: String
            public var key: String?
            public var tempo: Double?
            public var slices: Int
            public var dusty: Bool
            public var source: String?
            public var sourceRecord: String?

            enum CodingKeys: String, CodingKey { case id, name, key, tempo, slices, dusty, source; case sourceRecord = "source_record" }
        }
        public struct AlbumEntry: Encodable, Sendable {
            public var id: String
            public var title: String
            public var songs: [String]
        }
        public struct SongEntry: Encodable, Sendable {
            public var id: String
            public var title: String
            public var key: String?
            public var tempo: Double
            public var bars: Int
            public var isOpen: Bool
            /// What the song can give another: its stems by name, and "full" for its record. Empty
            /// when it has no analysed record.
            public var stems: [String]
            /// Its record as the analysis read it: what adopt's `bars` count in.
            public var recordKey: String?
            public var recordTempo: Double?
            public var recordBars: Int?

            enum CodingKeys: String, CodingKey {
                case id, title, key, tempo, bars, stems
                case isOpen = "is_open"
                case recordKey = "record_key"
                case recordTempo = "record_tempo"
                case recordBars = "record_bars"
            }
        }

        public var ideas: [Idea]
        public var records: [RecordEntry]
        public var samples: [SampleEntry]
        public var albums: [AlbumEntry]
        public var songs: [SongEntry]
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "read_library"
    public var purpose: String {
        "Read the library: ideas (parts kept with no song), records (the crate: each record read for its key, "
        + "tempo and bars, and its stems kept with it, each with how much of the record it is and the bar it "
        + "comes in at), samples (chops saved with their slices and chain), albums and songs — each with its "
        + "key and tempo where it has one, and for each song the stems its record gives and its record's bars. "
        + "Ids here go to adopt, which brings an item, or a record's or a song's stem, into the open song."
    }
    public var schema: DirectorJSON { Schema.object([], required: []) }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        let song = await workspace.song
        let media = Set((song?.versions ?? []).compactMap { version -> MediaRef? in
            if case .audio(let audio) = version.kind { return audio.media }
            return nil
        })
        func recordName(_ id: RecordID?) -> String? {
            guard let id, let record = library.record(id) else { return nil }
            return record.artist.isEmpty ? record.title : "\(record.artist) – \(record.title)"
        }
        let ideas = library.ideas.map { idea in
            Output.Idea(id: idea.id.description, title: PartLabel.title(of: idea), type: idea.type.rawValue,
                        key: ReadSongTool.key(of: idea).map { "\($0)" }, note: idea.note)
        }
        var records: [Output.RecordEntry] = []
        for record in library.records {
            var key: Key?, tempo: Double?, bars: Int?
            if let analysis = record.reading {
                key = analysis.dominantKey
                tempo = analysis.dominantTempo
                bars = analysis.bars.isEmpty ? nil : analysis.bars.count
            }
            let stems: [Output.StemEntry] = record.reading == nil ? [] : Sources.stems(of: record).map { name in
                let stem = record.stem(named: name)
                return Output.StemEntry(name: name, dbAgainstRecord: stem?.relativeDB,
                                        comesInAtBar: stem?.barLevels.flatMap(RecordStems.firstPlayedBar).map { $0 + 1 })
            }
            let held = Set([record.media] + (record.stems ?? []).map(\.media))
            let check = record.readingAsRead?.beatCheck
            records.append(Output.RecordEntry(id: record.id.description, title: record.title, artist: record.artist,
                                              key: key.map { "\($0)" }, tempo: tempo, bars: bars,
                                              inSong: !media.isDisjoint(with: held), stems: stems,
                                              status: await workspace.crateStatus(of: record.id), grid: record.grid?.description,
                                              trackersAgree: check?.agreement.map { ($0 * 100).rounded() / 100 },
                                              secondTrackerTempo: check?.checkerBPM.map { ($0 * 10).rounded() / 10 },
                                              secondTrackerKept: !(record.readingAsRead?.checkerBeats?.isEmpty ?? true),
                                              tuningCents: record.tuning.flatMap { abs($0) >= SourceFitting.leastCents ? $0 : nil }))
        }
        let samples = library.samples.map { entry in
            Output.SampleEntry(id: entry.id.description, name: entry.name, key: entry.sample.key.map { "\($0)" },
                               tempo: entry.sample.detectedTempo, slices: entry.sample.slices.count,
                               dusty: !entry.sample.degradation.isEmpty,
                               source: recordName(entry.sample.sourceRecord ?? library.record(forMedia: entry.sample.media)?.id),
                               sourceRecord: entry.sample.sourceRecord?.description)
        }
        let albums = library.albums.map { album in
            Output.AlbumEntry(id: album.id.description, title: album.title,
                              songs: album.songs.compactMap { library.song($0)?.title })
        }
        let songs = library.songs.map { entry in
            let record = Mashups.source(for: entry)
            let bars = Mashups.stems(of: entry).first.flatMap { Sources.material(of: entry, stem: $0)?.material.bars.count }
            return Output.SongEntry(id: entry.id.description, title: entry.title, key: entry.key.map { "\($0)" },
                                    tempo: entry.tempo, bars: entry.lengthInBars, isOpen: entry.id == song?.id,
                                    stems: record == nil ? [] : Mashups.stems(of: entry), recordKey: record?.key.map { "\($0)" },
                                    recordTempo: record?.tempo.map { ($0 * 10).rounded() / 10 }, recordBars: record == nil ? nil : bars)
        }
        let counts = "\(ideas.count) ideas, \(records.count) records, \(samples.count) samples, \(albums.count) albums, \(songs.count) songs"
        return Output(ideas: ideas, records: records, samples: samples, albums: albums, songs: songs,
                      detail: song == nil ? "\(counts). No song is open, so nothing can be adopted yet."
                                          : "\(counts). adopt brings an idea, a sample or a record into \(song!.title), "
                                              + "or a record's or a song's stem — whole, or some bars — fitted to it.")
    }
}

// MARK: - adopt

/// Brings a library item into the open song as a version of its own; or a library song's stem —
/// the whole of it, or some bars — fitted to the open song's key, tempo and bars; or fits again a
/// source the song already holds.
public struct AdoptTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var kind: String
        public var id: String
        public var stem: String?
        public var bars: [Int]?
        public var atBar: Int?
        public var semitones: Int?
        public var tighten: String?

        enum CodingKeys: String, CodingKey {
            case kind, id, stem, bars, semitones, tighten
            case atBar = "at_bar"
        }

        /// "on", "off", or nil for as the record's beat trackers say (or, fitting again, as it was).
        var tightens: Bool? {
            switch tighten?.lowercased() {
            case "on": return true
            case "off": return false
            default: return nil
            }
        }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var type: String
        public var key: String?
        public var tempo: Double?
        public var note: String?
        /// For a stem brought in: how it was moved, and anything flagged.
        public var sentences: [String]?
        public var flags: [String]?
        /// The sections that play it.
        public var sections: [String]?
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "adopt"
    public var purpose: String {
        "Bring a library item into the open song as a new version: an idea as the part it is, a sample as "
        + "a chop, a record as its take and analysis (chop a bar of it afterwards). The library keeps its "
        + "copy; the song gets its own, audio and all. kind record with a stem, or kind song, brings a "
        + "record's stem (from the crate) or a library song's stem in, fitted to the open song: the song's "
        + "key, tempo and bars stand and the record is moved onto them — the whole stem laid along the song "
        + "from at_bar, or bars of the record fitted to whole bars and looped like a chop in the sections "
        + "with none. Into a song with nothing in it, the first stem brings its key, tempo and form. A record "
        + "not yet separated is queued for separation and the call says so; adopt again once it is. kind fitted takes a source the song already holds (a version "
        + "or part id from read_song) and fits it again from the untouched record: other semitones, "
        + "another at_bar, tightened or let loose, or the song's key and tempo as they are now. Tightened, "
        + "each of the record's bars is stretched onto one of the song's so it keeps time with a programmed "
        + "kit; it is unless its bar lines look misread, when tightening to them would lurch."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("kind", Schema.string("What the id names.", enum: ["idea", "sample", "record", "song", "fitted"])),
            ("id", Schema.string("The item's id from read_library; for fitted, the source's version or part id from read_song.")),
            // Required with an empty answer rather than optional: the API allows twenty-four
            // optional parameters across the toolbox, and these three would have spent the last.
            ("stem", Schema.string("For song, or record: which stem, as read_library lists them; full is the whole record. Empty for "
                                   + "any other kind, and for a record adopted as its take and analysis.",
                                   enum: ["", "vocals", "drums", "bass", "other", Mashups.full])),
            ("bars", Schema.array("With a stem: the record's first and last bar to take, 1-based, both included, as [9, 10]. "
                                  + "Empty for the whole stem, and for any other kind.", of: Schema.integer("A bar of the record.", minimum: 1))),
            ("at_bar", Schema.integer("For a whole stem: the song bar its bar 1 lands on, 1 for the first; below 0, already that "
                                      + "many bars under way when the song starts. 0 is bar 1 for a new stem and where it is for fitted.",
                                      minimum: -63, maximum: 256)),
            ("semitones", Schema.optional(Schema.integer("Semitones by ear in place of the key arithmetic; left out, by the key.",
                                                         minimum: -12, maximum: 12))),
            ("tighten", Schema.string("For song or fitted: on stretches each of its bars onto one of the song's, off keeps one "
                                      + "stretch and the record's drift. Empty: on unless its bar lines look misread, or as it was.",
                                      enum: ["", "on", "off"])),
        ], required: ["kind", "id", "stem", "bars", "at_bar", "semitones", "tighten"])
    }

    public func run(_ input: Input) async throws -> Output {
        if input.kind == "song" { return try await source(input) }
        if input.kind == "record", input.stem?.isEmpty == false { return try await crateSource(input) }
        if input.kind == "fitted" { return try await refit(input) }
        guard let kind = LibraryDragPayload.Kind(rawValue: input.kind), [.idea, .sample, .record].contains(kind) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.kind)\" is not something adopt brings in.",
                                      suggestion: "One of: idea, sample, record, song, fitted.")
        }
        guard let uuid = UUID(uuidString: input.id) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.id)\" is not an id.", suggestion: "Take ids from read_library.")
        }
        guard await workspace.song != nil else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to adopt into.")
        }
        guard let id = await workspace.adopt(LibraryDragPayload(kind: kind, id: uuid, title: "")),
              let version = await workspace.version(id) else {
            throw DirectorToolFailure(tool: name, reason: "The library holds no \(input.kind) \(input.id), or its audio is missing.",
                                      suggestion: "Call read_library and use an id it lists.")
        }
        return Output(version: version.id.description, type: version.type.rawValue,
                      key: ReadSongTool.key(of: version).map { "\($0)" }, tempo: ReadSongTool.tempo(of: version),
                      note: version.note,
                      detail: version.type == .audio
                          ? "The record's take and analysis are in the song; chop a bar of it with the Chop lane, or merge it."
                          : "In the song as \(PartLabel.title(of: version)); merge it, stitch it, or open it on its surface.")
    }

    /// A library song's stem, fitted to the open song.
    private func source(_ input: Input) async throws -> Output {
        guard let open = await workspace.song else { throw DirectorToolFailure(tool: name, reason: "No song is open to bring a stem into.") }
        let library = await workspace.library
        guard let from = library.songs.first(where: { $0.id.description == input.id || $0.title.caseInsensitiveCompare(input.id) == .orderedSame }) else {
            throw DirectorToolFailure(tool: name, reason: "The library holds no song \(input.id).", suggestion: "Take song ids from read_library.")
        }
        let offers = Mashups.stems(of: from)
        let stem = (input.stem.flatMap { $0.isEmpty ? nil : $0 } ?? (offers.contains("vocals") ? "vocals" : offers.first) ?? "").lowercased()
        guard Mashups.source(for: from) != nil, offers.contains(stem) else {
            throw DirectorToolFailure(tool: name, reason: Mashups.source(for: from) == nil ? SourceError.notAnalysed(from.title).description
                                                                                          : SourceError.noStem(stem, from.title).description,
                                      suggestion: offers.isEmpty ? "Choose a song read_library lists stems for." : "One of: \(offers.joined(separator: ", ")).")
        }
        var range: Range<Int>?
        if let bars = input.bars, !bars.isEmpty {
            let first = bars[0], last = bars.count > 1 ? bars[1] : bars[0]
            guard first >= 1, last >= first else {
                throw DirectorToolFailure(tool: name, reason: "Bars \(bars) are not a first and a last bar.", suggestion: "As [9, 10]: 1-based, both included.")
            }
            range = (first - 1)..<last
        }
        let request = SourceRequest(song: from.id, stem: stem, bars: range, atBar: Self.atBar(input.atBar) ?? 0, semitones: input.semitones,
                                    tighten: input.tightens)
        let added: (version: PartVersion, sentences: [String], flags: [String])
        do { added = try await workspace.addSource(request) } catch let failure as DirectorToolFailure { throw failure } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        return await output(added.version, sentences: added.sentences, flags: added.flags,
                            detail: "\(PartLabel.title(of: added.version)) is in \(open.title)\(range == nil ? ", laid along the song" : ", looped like a chop"). ")
    }

    /// A record's stem from the crate, fitted to the open song. A record not yet separated is
    /// queued for it.
    private func crateSource(_ input: Input) async throws -> Output {
        guard let open = await workspace.song else { throw DirectorToolFailure(tool: name, reason: "No song is open to bring a stem into.") }
        let library = await workspace.library
        guard let record = library.records.first(where: { $0.id.description == input.id || $0.title.caseInsensitiveCompare(input.id) == .orderedSame }) else {
            throw DirectorToolFailure(tool: name, reason: "The crate holds no record \(input.id).", suggestion: "Take record ids from read_library.")
        }
        guard record.reading != nil else {
            throw DirectorToolFailure(tool: name, reason: SourceError.notRead(record.title).description,
                                      suggestion: (await workspace.crateStatus(of: record.id)).map { "The crate says: \($0)." } ?? "Try again shortly.")
        }
        let stem = (input.stem ?? "").lowercased()
        let offers = Sources.stems(of: record)
        guard offers.contains(stem) else {
            let queued = await workspace.separateRecord(record.id)
            throw DirectorToolFailure(tool: name, reason: SourceError.noStem(stem, record.title).description,
                                      suggestion: queued ? "Its separation is queued in the crate; adopt it again once read_library lists its stems, or take full now."
                                                         : "One of: \(offers.joined(separator: ", ")).")
        }
        let request = SourceRequest(record: record.id, stem: stem, bars: try Self.range(input.bars, tool: name),
                                    atBar: Self.atBar(input.atBar) ?? 0, semitones: input.semitones, tighten: input.tightens)
        let added: (version: PartVersion, sentences: [String], flags: [String])
        do { added = try await workspace.addSource(request) } catch let failure as DirectorToolFailure { throw failure } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        return await output(added.version, sentences: added.sentences, flags: added.flags,
                            detail: "\(PartLabel.title(of: added.version)) is in \(open.title)\(request.isClip ? ", looped like a chop" : ", laid along the song"). ")
    }

    /// `bars` as a range of the record's bars, 0-based, the end not included; nil for none.
    static func range(_ bars: [Int]?, tool: String) throws -> Range<Int>? {
        guard let bars, !bars.isEmpty else { return nil }
        let first = bars[0], last = bars.count > 1 ? bars[1] : bars[0]
        guard first >= 1, last >= first else {
            throw DirectorToolFailure(tool: tool, reason: "Bars \(bars) are not a first and a last bar.", suggestion: "As [9, 10]: 1-based, both included.")
        }
        return (first - 1)..<last
    }

    /// A source the song holds, fitted again from its untouched record.
    private func refit(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else { throw DirectorToolFailure(tool: name, reason: "No song is open.") }
        let part = VersionID(uuidString: input.id).flatMap(song.version)?.partID ?? PartID(uuidString: input.id)
        guard let part, let current = song.latestVersion(of: part), let fit = SourceFitting.fit(of: current) else {
            throw DirectorToolFailure(tool: name, reason: "\(input.id) is not a source this song pulled in from another record.",
                                      suggestion: "Take the id of a fitted stem or clip from read_song.")
        }
        let version: PartVersion
        do {
            version = try await workspace.refitSource(part, semitones: input.semitones ?? (fit.byEar ? fit.semitones : nil),
                                                      atBar: Self.atBar(input.atBar) ?? fit.atBar, tighten: input.tightens)
        } catch let failure as DirectorToolFailure { throw failure } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        return await output(version, sentences: [version.note ?? ""].filter { !$0.isEmpty }, flags: [],
                            detail: "Fitted again from the untouched record, as a new version of the same part; every section that played it plays this. ")
    }

    /// `at_bar` as the song counts from zero: 1 is bar 0, −2 is two bars under way, 0 is "not said".
    static func atBar(_ said: Int?) -> Int? {
        guard let said, said != 0 else { return nil }
        return said > 0 ? said - 1 : said
    }

    private func output(_ version: PartVersion, sentences: [String], flags: [String], detail: String) async -> Output {
        let sections = (await workspace.song?.sections ?? []).filter { $0.stitch.contains(part: version.partID) }.map(\.name)
        let placed = sections.isEmpty ? "No section names it: the song's form names nothing yet, so it plays along with everything; "
                                        + "the form it is given later carries it."
                                      : "It plays in \(sections.joined(separator: ", ")); stitch_section takes it out of one or brings it into another."
        return Output(version: version.id.description, type: version.type.rawValue,
                      key: ReadSongTool.key(of: version).map { "\($0)" }, tempo: ReadSongTool.tempo(of: version), note: version.note,
                      sentences: sentences, flags: flags.isEmpty ? nil : flags, sections: sections,
                      detail: detail + placed)
    }
}

// MARK: - merge

/// Two fragments brought to one key and one tempo by the Sampler's rules; with a section name,
/// rendered and stitched.
public struct MergeTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var a: String
        public var b: String
        public var key: String
        public var tempo: Double
        public var section: String
        public var bars: Int
    }

    public struct Move: Encodable, Sendable {
        public var label: String
        public var semitones: Int
        public var ratio: Double
        public var key: String?
        public var tempo: Double?
        public var sentence: String
    }

    public struct Output: Encodable, Sendable {
        public var targetKey: String?
        public var targetTempo: Double?
        public var a: Move
        public var b: Move
        /// What the plan and the Sampler want said: the timbre past four semitones, an uncleared source.
        public var flags: [String]
        public var stitched: Bool
        public var section: String?
        public var sectionName: String?
        public var bars: Int?
        /// The moved versions, when stitched; the originals when nothing moved.
        public var versions: [String]
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case a, b, flags, stitched, section, bars, versions, detail
            case targetKey = "target_key"
            case targetTempo = "target_tempo"
            case sectionName = "section_name"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "merge"
    public var purpose: String {
        "Bring two fragments — a chop, a bass line, a progression or a groove each — to one key and one "
        + "tempo. Audio is shifted and stretched, a written part moves by arithmetic, a groove stays. The "
        + "rules: the smallest transposition wins, relative keys are one key, tempo is doubled or halved "
        + "before it is stretched past 12%, a sample past four semitones is flagged and past seven refused. "
        + "With a section name it renders both and stitches them as a section the transport plays; with "
        + "none it only plans, and you open the Merge surface on the two."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("a", Schema.string("A version id from read_song: a chop, a bass line, a progression or a groove.")),
            ("b", Schema.string("The other version id.")),
            ("key", Schema.string("The key to bring them into, as read_song says it (\"D major\"); empty for the song's.")),
            ("tempo", Schema.number("The tempo to bring them to; 0 for the song's.", minimum: 0, maximum: 300)),
            ("section", Schema.string("A section name (\"Verse\") to render and stitch them as; empty to plan only.")),
            ("bars", Schema.integer("The section's length in bars; 0 for the longer fragment's, or four.", minimum: 0, maximum: 128)),
        ], required: ["a", "b", "key", "tempo", "section", "bars"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else { throw DirectorToolFailure(tool: name, reason: "No song is open.") }
        let library = await workspace.library
        func version(_ raw: String) async throws -> PartVersion {
            guard let id = VersionID(uuidString: raw), let version = await workspace.version(id) else {
                throw DirectorToolFailure(tool: name, reason: "This song holds no version \(raw).", suggestion: "Take ids from read_song.")
            }
            guard MergeModel.canMerge(version) else {
                throw DirectorToolFailure(tool: name, reason: "A \(version.type.rawValue) is not something a merge moves.",
                                          suggestion: "A chop, a bass line, a progression or a groove.")
            }
            return version
        }
        let a = try await version(input.a)
        let b = try await version(input.b)
        guard a.id != b.id else { throw DirectorToolFailure(tool: name, reason: "Both ids are the same version.") }

        var targetKey = song.key
        if !input.key.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = Key(parsing: input.key) ?? Key(parsing: input.key.replacingOccurrences(of: "♭", with: "b")) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(input.key)\" is not a key this app can read.",
                                          suggestion: "Say it as read_song does: \"D major\", \"A minor\".")
            }
            targetKey = parsed
        }
        let targetTempo = input.tempo > 0 ? input.tempo : song.tempo

        let fragmentA = MergeModel.fragment(of: a, in: song, library: library)
        let fragmentB = MergeModel.fragment(of: b, in: song, library: library)
        let plan = Merge.plan(fragmentA, fragmentB, target: MergeTarget(key: targetKey, tempo: targetTempo))

        // The Sampler first: a sample past seven is refused, past four flagged; two drum sources refused.
        var flags = plan.flags
        let sampler = Sampler()
        for (fragment, move) in [(fragmentA, plan.a), (fragmentB, plan.b)] where fragment.kind == .sample {
            switch sampler.consider(.transposeSample(label: fragment.label, semitones: move.semitones)) {
            case .refuse(let rule, let because, let counter):
                throw DirectorToolFailure(tool: name, reason: "The Sampler: \(because)",
                                          suggestion: "Nothing was rendered. \(counter) (Rule \(rule).)")
            case .agreeWithCaveat(_, let caveat): flags.append("The Sampler: \(caveat)")
            default: break
            }
        }
        func source(_ version: PartVersion) -> (name: String?, uncleared: Bool) {
            guard case .sample(let sample) = version.kind,
                  let recordID = sample.sourceRecord ?? library.record(forMedia: sample.media)?.id,
                  let record = library.record(recordID) else { return (nil, false) }
            let name = record.artist.isEmpty ? record.title : "\(record.artist) – \(record.title)"
            let cleared = library.albums.flatMap(\.clearances).contains { $0.record == recordID && ($0.status == .cleared || $0.status == .notRequired) }
            return (name, !cleared)
        }
        let seconds = Double(max(1, input.bars > 0 ? input.bars : MergeModel.defaultBars(a, b, in: song)) * song.timeSignature.beatsPerBar) * 60 / max(1, targetTempo)
        let review = MergeReview.of(plan, a: a, b: b, aFragment: fragmentA, bFragment: fragmentB, sources: source, seconds: seconds)
        switch sampler.consider(.mergeSources(drumSources: review.drumSources, uncleared: review.uncleared)) {
        case .refuse(let rule, let because, let counter):
            throw DirectorToolFailure(tool: name, reason: "The Sampler: \(because)",
                                      suggestion: "Nothing was rendered. \(counter) (Rule \(rule).)")
        case .agreeWithCaveat(_, let caveat): flags.append("The Sampler: \(caveat)")
        default: break
        }
        for finding in CriticBoard.standard.review(review) where !flags.contains(where: { $0.contains(finding.headline) }) {
            flags.append("\(finding.criticName): \(finding.headline) — \(finding.why)")
        }

        func move(_ m: MergeMove) -> Move {
            Move(label: m.label, semitones: m.semitones, ratio: (m.ratio * 1000).rounded() / 1000,
                 key: m.key.map { "\($0)" }, tempo: m.tempo, sentence: m.sentence)
        }
        let sectionName = input.section.trimmingCharacters(in: .whitespaces)
        guard !sectionName.isEmpty else {
            return Output(targetKey: targetKey.map { "\($0)" }, targetTempo: targetTempo, a: move(plan.a), b: move(plan.b),
                          flags: flags, stitched: false, section: nil, sectionName: nil, bars: nil,
                          versions: [a.id.description, b.id.description],
                          detail: "Planned, nothing rendered. Open the Merge surface bound to these two so the user hears "
                              + "each and both; call again with a section name to render and stitch.")
        }

        let movedA = try await workspace.merge(a, move: plan.a)
        let movedB = try await workspace.merge(b, move: plan.b)
        // The renders kept themselves in their own song; the section goes nowhere else.
        guard await workspace.song?.id == song.id else {
            throw DirectorToolFailure(tool: name, reason: "The song changed while the merge was rendering.",
                                      suggestion: "The moved parts are in \(song.title); open it and stitch them into a section there.")
        }
        let bars = input.bars > 0 ? input.bars : MergeModel.defaultBars(a, b, in: song)
        let section = Section(name: sectionName, stitch: [movedA, movedB].lanes, lengthInBars: bars)
        let current = await workspace.song?.sections ?? song.sections
        let recorded = await workspace.arrange(current + [section])
        return Output(targetKey: targetKey.map { "\($0)" }, targetTempo: targetTempo, a: move(plan.a), b: move(plan.b),
                      flags: flags, stitched: recorded, section: section.id.description, sectionName: section.name, bars: bars,
                      versions: [movedA.id.description, movedB.id.description],
                      detail: recorded
                          ? "Stitched as \(section.name), \(bars) bars; the transport plays it and Structure shows it. "
                              + "Open the Merge surface on the two originals to let the user hear the move."
                          : "Rendered, but the song refused the section.")
    }
}

// MARK: - fix_grid

/// A record's beat grid corrected in the crate, for bar lines a tracker misread.
public struct FixGridTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var record: String
        public var move: String
    }

    public struct Output: Encodable, Sendable {
        public var record: String
        public var grid: String
        public var tempo: Double?
        public var bars: Int
        /// The open song's sources fitted to the old bar lines: adopt kind fitted on each.
        public var fitAgain: [String]
        public var detail: String

        enum CodingKeys: String, CodingKey { case record, grid, tempo, bars, detail; case fitAgain = "fit_again" }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "fix_grid"
    public var purpose: String {
        "Correct a record's beat grid in the crate when its bar lines are misread. The tells: read_library's trackers_agree "
        + "well under 0.8, a second tracker's tempo half or twice the record's, or adopt leaving a source as recorded because "
        + "its bar lines look misread. half halves the tempo (the tracker counted double time), double doubles it, later and "
        + "earlier move the downbeat by a beat, second_tracker takes the second tracker's beats in bars of the record's meter "
        + "(or goes back to the first's; a record read before they were kept is listened to first), as_read undoes every correction. The analysis itself is never rewritten. Sources the open "
        + "song fitted from the record are listed: adopt kind fitted on each fits it to the new bar lines, tightened unless they "
        + "still look misread."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("record", Schema.string("The record's id from read_library, or its title.")),
            ("move", Schema.string("The correction.", enum: GridMove.allCases.map(\.rawValue))),
        ], required: ["record", "move"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        guard let found = library.records.first(where: { $0.id.description == input.record || $0.title.caseInsensitiveCompare(input.record) == .orderedSame }) else {
            throw DirectorToolFailure(tool: name, reason: "The crate holds no record \(input.record).", suggestion: "Take record ids from read_library.")
        }
        guard let move = GridMove(rawValue: input.move) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.move)\" is not a correction.",
                                      suggestion: "One of: \(GridMove.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let record: Record
        do { record = try await workspace.correctGrid(found.id, move) } catch GridError.noSecondTracker(let title) {
            let queued = await workspace.listenForSecondTracker(found.id)
            throw DirectorToolFailure(tool: name, reason: "\(title) was read before the second tracker's beats were kept.",
                                      suggestion: queued ? "The second tracker is listening to it now, its reading kept as it is; fix_grid again once read_library says second_tracker_kept."
                                                         : "There is no second tracker here to listen.")
        } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        let song = await workspace.song
        let stale = (song?.fittedSources ?? []).filter { version in
            guard let fit = SourceFitting.fit(of: version) else { return false }
            return fit.record == record.id && (fit.grid ?? RecordGrid()) != (record.grid ?? RecordGrid())
        }
        let reading = record.reading
        return Output(record: record.title, grid: record.grid?.description ?? "as read",
                      tempo: reading?.dominantTempo.map { ($0 * 10).rounded() / 10 }, bars: reading?.bars.count ?? 0,
                      fitAgain: stale.map(\.partID.description),
                      detail: stale.isEmpty ? "\(record.title) reads through it now; anything fitted from it next is fitted to these bars."
                                            : "\(stale.count) source\(stale.count == 1 ? "" : "s") in \(song?.title ?? "the song") \(stale.count == 1 ? "was" : "were") fitted to its old bar lines; adopt kind fitted on each part id fits it again.")
    }
}
