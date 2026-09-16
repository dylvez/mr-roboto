import Foundation

/// The JSON coding used by every document in the graph: sorted keys, pretty printed, dates as ISO 8601 with
/// millisecond precision. Documents pass through the schema migrator on the way in.
public enum SongGraphCodec {
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDateFormat = Date.ISO8601FormatStyle()

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        return encoder
    }

    /// "2026-09-16T16:04:13.926Z": whole seconds from the ISO 8601 style, milliseconds rounded by hand, because the
    /// style truncates fractional seconds and a millisecond-precision date can sit just below its decimal value.
    static func format(_ date: Date) -> String {
        let seconds = date.graphPrecision.timeIntervalSinceReferenceDate
        let whole = seconds.rounded(.down)
        let milliseconds = min(999, max(0, Int(((seconds - whole) * 1000).rounded())))
        var text = wholeSecondDateFormat.format(Date(timeIntervalSinceReferenceDate: whole))
        if text.hasSuffix("Z") { text.removeLast() }
        let padded = String(milliseconds)
        return text + "." + String(repeating: "0", count: 3 - padded.count) + padded + "Z"
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? dateFormat.parse(text) { return date.graphPrecision }
            if let date = try? wholeSecondDateFormat.parse(text) { return date.graphPrecision }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(text)\" is not an ISO 8601 date")
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Decodes a document, first upgrading it with `migrator` when it is older than the current schema.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, migrating migrator: SchemaMigrator) throws -> T {
        let document = try decode(JSONValue.self, from: data)
        if migrator.isCurrent(document) { return try decode(type, from: data) }
        let upgraded = try migrator.upgrade(document)
        return try decode(type, from: try encode(upgraded))
    }

    /// Decodes a song document, migrating old schemas.
    public static func decodeSong(from data: Data) throws -> Song {
        try decode(Song.self, from: data, migrating: .song)
    }

    /// Encodes a song document.
    public static func encodeSong(_ song: Song) throws -> Data { try encode(song) }
}
