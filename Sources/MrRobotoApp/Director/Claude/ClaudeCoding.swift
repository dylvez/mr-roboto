import Foundation

/// The one encoder every request goes through.
///
/// `.sortedKeys` is not tidiness. Foundation's `JSONEncoder` writes a keyed container's members in
/// the order its internal dictionary happens to hash them, which is seeded per process — two runs
/// of the same build produce different bytes for the same request, and the second one is a cache
/// miss on a prefix that has not changed. Sorting the keys is what makes the frozen prefix actually
/// frozen. `DirectorJSONTests` proves it by encoding the same value many times.
///
/// `.withoutEscapingSlashes` keeps a file path in a tool result readable and, more to the point,
/// keeps it byte-identical to what a later request will write.
public enum ClaudeCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }
}
