import Foundation

extension Date {
    /// Timestamps in the graph are kept at millisecond precision so a JSON round trip compares equal.
    public var graphPrecision: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
    }
}

/// Who made a version: the user, or a persona (an AI band member) by name.
public enum Author: Hashable, Sendable, CustomStringConvertible {
    case user
    case persona(String)

    public var description: String {
        switch self {
        case .user: return "user"
        case .persona(let name): return name
        }
    }

    public var isPersona: Bool { if case .persona = self { return true } else { return false } }
}

extension Author: Codable {
    private enum CodingKeys: String, CodingKey { case role, name }
    private enum Role: String, Codable { case user, persona }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Role.self, forKey: .role) {
        case .user: self = .user
        case .persona: self = .persona(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode(Role.user, forKey: .role)
        case .persona(let name):
            try container.encode(Role.persona, forKey: .role)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Well-known operation names. Operations are free strings; these are the ones the app and personas agree on.
public enum Operation {
    public static let hummed = "hummed"
    public static let recorded = "recorded"
    public static let imported = "imported"
    public static let written = "written"
    public static let analyzed = "analyzed"
    public static let harmonize = "harmonize"
    public static let transpose = "transpose"
    public static let chop = "chop"
    public static let stretch = "stretch"
    public static let reharmonize = "reharmonize"
    public static let separate = "separate"
    public static let regroove = "regroove"
    public static let edit = "edit"
    /// A chop given a level of its own, or put back as recorded: a new version of the same part
    /// whose `Sample.gainDB` is the only thing that moved.
    public static let level = "level"
    /// A sample or a groove put through a degradation chain: a new version of the same part whose
    /// parent is the version it dirtied. See `Degradation`.
    public static let degrade = "degrade"
    /// A version brought into a song from the library — an idea, a sample, a record's take — as a
    /// new part with no parents here. Its note names where it came from.
    public static let adopted = "adopted"
    /// A fragment moved to sit with another: pitch-shifted and stretched audio, or a written part
    /// transposed by arithmetic. Its note is the plan's sentence; its parent is what it moved.
    public static let merge = "merge"
    /// Takes of one part chosen bar by bar and rendered into one audio version. Its parents are
    /// every take it drew from; its `Audio.comp` is the plan.
    public static let comped = "comped"
    /// An older version made current again: the same music as the version it restores, as a new
    /// version whose parents are the one it replaced and the one it restores, so "back one" twice
    /// knows where it has got to. Nothing is removed; the history only grows.
    public static let restored = "restored"
    /// A fix the band offered and you took — a note shifted by its measured cents, an onset nudged
    /// by its milliseconds — as a new version whose parent is the take. The take is never changed.
    public static let corrected = "corrected"
    /// A mix move: a strip's level, pan, EQ, compressor or send, or the master, as a new mix
    /// version whose parent is the mix it moved and whose note says what and by how much.
    public static let mix = "mix"
    /// A stem of another record, moved to this song's key and tempo and set on its bar grid.
    public static let mashup = "mashup"
    /// A stem, or a few bars, of another record pulled into a song and fitted to its key, tempo and
    /// bars. Its `fit` says from what and how; fitted again, it is a new version of the same part
    /// whose parent is the one it replaces, rendered from the untouched source.
    public static let fitted = "fitted"
    /// Played in on a controller while the song ran — a groove, a bass line or a tune as the hands put it.
    public static let played = "played"
    /// A part written for a section from the part the loop plays: the kit thinned for an intro, the
    /// bass held under a breakdown. Its parent is what it was made from; see `Variation`.
    public static let developed = "developed"
    /// A part played another way for the sections somebody named — the last chorus's chords with a
    /// borrowed chord, the second hook's tune pushed over its bar lines. A variation like one
    /// developing writes, but asked for by name, so developing leaves it where it was put.
    public static let placed = "placed"
    /// Filled in by the schema 1 → 2 migration for versions that predate provenance operations.
    public static let unknown = "unknown"
}

/// What makes a part a variation of another: the part it was made from, and the treatment.
///
/// A song is a loop until its sections differ, and what differs is mostly the same part played
/// another way — the drums without their kick, the bass holding its roots. Each of those is a part
/// of its own, so a section names it, a surface edits it and the ledger shows it like any other.
/// What it shares with the part it came from is everything about how it sounds: one strip on the
/// Mixer, one instrument, one sampler. `Song.strip(of:)` is where that is read.
public struct Variation: Hashable, Codable, Sendable {
    /// The part this is a variation of.
    public var of: PartID
    /// The treatment, as a word the app knows: "thin", "no-kick", "build", "lift", "held".
    public var name: String

    public init(of part: PartID, name: String) {
        self.of = part
        self.name = name
    }
}

/// One immutable version of a part, with provenance: who made it, from which parents, by which operation.
/// A new version never mutates an old one; derive with `deriving(...)` instead.
public struct PartVersion: Identifiable, Hashable, Codable, Sendable {
    public let id: VersionID
    public let partID: PartID
    public let kind: PartKind
    public let createdAt: Date
    public let author: Author
    /// The versions this one was made from (empty for roots).
    public let parents: [VersionID]
    /// Short operation name such as "hummed", "harmonize", "transpose", "chop", "stretch", "reharmonize".
    public let operation: String
    public let note: String?
    /// The seed this version grew directly from, for roots that came from a hummed take, brief or record.
    public let origin: SeedID?
    /// Set when this part is a variation of another. Nil — nearly always — is a part of its own.
    /// Synthesized coding omits it when nil, so older documents round-trip byte for byte.
    public let variation: Variation?

    public init(id: VersionID = VersionID(), partID: PartID, kind: PartKind, createdAt: Date = Date(),
                author: Author, parents: [VersionID] = [], operation: String, note: String? = nil, origin: SeedID? = nil,
                variation: Variation? = nil) {
        self.id = id
        self.partID = partID
        self.kind = kind
        self.createdAt = createdAt.graphPrecision
        self.author = author
        self.parents = parents
        self.operation = operation
        self.note = note
        self.origin = origin
        self.variation = variation
    }

    public var type: PartType { kind.type }

    /// A new version of the same part with this one as its parent. A variation stays one.
    public func deriving(_ kind: PartKind, by author: Author, operation: String, note: String? = nil,
                         createdAt: Date = Date(), alsoFrom otherParents: [VersionID] = []) -> PartVersion {
        PartVersion(partID: partID, kind: kind, createdAt: createdAt, author: author,
                    parents: [id] + otherParents, operation: operation, note: note, variation: variation)
    }

    /// A first version of a new part that is a variation of this one's: the same kind of thing,
    /// played another way for a section, sounding through this part's strip and instrument.
    public func varying(_ kind: PartKind, as name: String, of root: PartID? = nil, by author: Author, note: String? = nil,
                        createdAt: Date = Date()) -> PartVersion {
        PartVersion(partID: PartID(), kind: kind, createdAt: createdAt, author: author, parents: [id],
                    operation: Operation.developed, note: note,
                    variation: Variation(of: root ?? variation?.of ?? partID, name: name))
    }

    /// A first version of a new part made from this one (a melody harmonized into a progression, a take chopped into a sample).
    public func spawning(_ kind: PartKind, by author: Author, operation: String, note: String? = nil,
                         createdAt: Date = Date(), alsoFrom otherParents: [VersionID] = []) -> PartVersion {
        PartVersion(partID: PartID(), kind: kind, createdAt: createdAt, author: author,
                    parents: [id] + otherParents, operation: operation, note: note)
    }

    /// Media files this version depends on.
    public var mediaReferences: [MediaRef] { kind.mediaReferences }
}

/// What a song grew from: a hummed take, a written brief, or an imported record.
public enum SeedKind: Hashable, Sendable {
    case hummedTake(MediaRef)
    case brief(String)
    case importedRecord(RecordID)

    public var mediaReferences: [MediaRef] {
        if case .hummedTake(let media) = self { return [media] }
        return []
    }
}

extension SeedKind: Codable {
    private enum CodingKeys: String, CodingKey { case type, media, text, record }
    private enum Kind: String, Codable { case hummedTake, brief, importedRecord }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hummedTake: self = .hummedTake(try container.decode(MediaRef.self, forKey: .media))
        case .brief: self = .brief(try container.decode(String.self, forKey: .text))
        case .importedRecord: self = .importedRecord(try container.decode(RecordID.self, forKey: .record))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hummedTake(let media):
            try container.encode(Kind.hummedTake, forKey: .type)
            try container.encode(media, forKey: .media)
        case .brief(let text):
            try container.encode(Kind.brief, forKey: .type)
            try container.encode(text, forKey: .text)
        case .importedRecord(let record):
            try container.encode(Kind.importedRecord, forKey: .type)
            try container.encode(record, forKey: .record)
        }
    }
}

/// A seed of a song.
public struct Seed: Identifiable, Hashable, Codable, Sendable {
    public let id: SeedID
    public var kind: SeedKind
    public let createdAt: Date
    public var note: String?

    public init(id: SeedID = SeedID(), kind: SeedKind, createdAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt.graphPrecision
        self.note = note
    }

    public var mediaReferences: [MediaRef] { kind.mediaReferences }
}
