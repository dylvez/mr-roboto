import Foundation

/// A stable, UUID-backed identifier for one kind of graph entity. Each conforming type is distinct at compile time,
/// so a `VersionID` can never be passed where a `PartID` is expected. Encodes as a plain UUID string.
public protocol EntityID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible
where RawValue == UUID {
    init(rawValue: UUID)
}

extension EntityID {
    /// A fresh random identifier.
    public init() { self.init(rawValue: UUID()) }

    /// Parses a UUID string such as "E621E1F8-C36C-495A-93FC-0C247A3E6E5F".
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Orders by UUID string, which gives deterministic ordering for sets of IDs.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

/// Identifies a part: the thing that has versions (a melody, a progression, a take …).
public struct PartID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies one immutable version of a part.
public struct VersionID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies a section of a song.
public struct SectionID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies a song.
public struct SongID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies an album.
public struct AlbumID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies a seed: the hummed take, brief or imported record a song grew from.
public struct SeedID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies an experiment: a proposed combination of versions not yet stitched into a section.
public struct ExperimentID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies an imported record in the library.
public struct RecordID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Identifies a sample in the library's sample collection.
public struct SampleID: EntityID {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// The SHA-256 digest of a media file, as 64 lowercase hex characters. Media is addressed by content, never by path,
/// so a song package survives being renamed, moved or synced.
public struct ContentHash: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// 64 lowercase hexadecimal characters.
    public let hex: String

    /// Accepts exactly 64 hex characters (either case); stores them lowercased.
    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard ContentHash.isValid(lowered) else { return nil }
        self.hex = lowered
    }

    init(validatedHex: String) { hex = validatedHex }

    static func isValid(_ hex: String) -> Bool {
        hex.utf8.count == 64 && hex.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The first 12 characters, for display.
    public var short: String { String(hex.prefix(12)) }

    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let hash = ContentHash(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(text)\" is not a SHA-256 hex digest")
        }
        self = hash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public static func < (lhs: ContentHash, rhs: ContentHash) -> Bool { lhs.hex < rhs.hex }
}

/// A reference to a media file by content hash plus the file extension it is stored under (`media/<hash>.<ext>`).
public struct MediaRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hash: ContentHash
    /// Lowercase extension without the dot, e.g. "wav", "mp3", "m4a".
    public var fileExtension: String

    public init(hash: ContentHash, fileExtension: String) {
        self.hash = hash
        self.fileExtension = MediaRef.normalize(extension: fileExtension)
    }

    /// The file name the media is stored under: `<hash>.<ext>`.
    public var fileName: String { fileExtension.isEmpty ? hash.hex : "\(hash.hex).\(fileExtension)" }

    public var description: String { fileName }

    /// Lowercases and strips a leading dot and surrounding whitespace.
    public static func normalize(extension ext: String) -> String {
        var text = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix(".") { text.removeFirst() }
        return text
    }
}
