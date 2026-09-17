import Foundation

/// A JSON value with a stable byte shape.
///
/// The tool list sits at position 0 of every request and has to be byte-identical from one call to
/// the next or the cached prefix is thrown away, silently and expensively. A Swift dictionary
/// cannot promise that — its iteration order is not stable — so every schema in this app is built
/// out of this type instead.
///
/// Two separate things make the bytes stable, and it is worth being clear about which does what.
/// Object members keep the order they were written in, which is for the human reading the schema
/// and for equality; the bytes are pinned by `ClaudeCoding`, which sorts keys on the way out
/// because Foundation's encoder otherwise emits them in a per-process hash order. The decoder
/// sorts too, so a round trip is idempotent.
public indirect enum DirectorJSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DirectorJSON])
    case object(DirectorJSONObject)

    /// Reads a member of an object, or nil for anything else.
    public subscript(key: String) -> DirectorJSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): Int(exactly: d.rounded())
        default: nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [DirectorJSON]? { if case .array(let a) = self { a } else { nil } }
}

/// An object whose members keep their written order.
///
/// Order is for the reader, not for the meaning: two objects with the same members in different
/// orders are equal, because that is what they are in JSON. The bytes are pinned separately, by
/// `ClaudeCoding` sorting keys on the way out.
public struct DirectorJSONObject: Sendable, Equatable, Hashable, ExpressibleByArrayLiteral {
    public struct Member: Sendable, Equatable, Hashable {
        public var key: String
        public var value: DirectorJSON
        public init(_ key: String, _ value: DirectorJSON) {
            self.key = key
            self.value = value
        }
    }

    public var members: [Member]

    public init(_ members: [Member] = []) { self.members = members }
    public init(arrayLiteral elements: Member...) { self.members = elements }

    public subscript(key: String) -> DirectorJSON? {
        get { members.first { $0.key == key }?.value }
        set {
            guard let newValue else {
                members.removeAll { $0.key == key }
                return
            }
            if let index = members.firstIndex(where: { $0.key == key }) {
                members[index].value = newValue
            } else {
                members.append(Member(key, newValue))
            }
        }
    }

    public var keys: [String] { members.map(\.key) }

    public static func == (lhs: DirectorJSONObject, rhs: DirectorJSONObject) -> Bool {
        lhs.sorted == rhs.sorted
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(sorted) }

    private var sorted: [Member] { members.sorted { $0.key < $1.key } }
}

// MARK: - Coding

private struct DirectorJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ key: String) { self.stringValue = key }
}

extension DirectorJSON: Codable {
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let object):
            var container = encoder.container(keyedBy: DirectorJSONKey.self)
            for member in object.members {
                try container.encode(member.value, forKey: DirectorJSONKey(member.key))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(), container.decodeNil() {
            self = .null
            return
        }
        if let container = try? decoder.container(keyedBy: DirectorJSONKey.self) {
            // Decoded object order is not meaningful, so it is sorted: two decodes of the same
            // bytes produce the same value, and re-encoding is stable.
            var object = DirectorJSONObject()
            for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                object.members.append(DirectorJSONObject.Member(key.stringValue, try container.decode(DirectorJSON.self, forKey: key)))
            }
            self = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [DirectorJSON] = []
            while !container.isAtEnd { values.append(try container.decode(DirectorJSON.self)) }
            self = .array(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
    }
}

extension DirectorJSON {
    /// Parses bytes into a value. Used for a tool call's arguments, which arrive as text.
    public static func parse(_ data: Data) throws -> DirectorJSON {
        try ClaudeCoding.decoder().decode(DirectorJSON.self, from: data)
    }

    /// The value's bytes. Deterministic: the same value always writes the same bytes.
    public func encoded() throws -> Data { try ClaudeCoding.encode(self) }

    /// The value as compact JSON text.
    public var jsonText: String {
        (try? String(decoding: encoded(), as: UTF8.self)) ?? "null"
    }

    /// Decodes the value into a type, by way of its bytes. This is how a tool turns the model's
    /// arguments into its own typed input.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ClaudeCoding.decoder().decode(type, from: encoded())
    }
}

// MARK: - Literals

extension DirectorJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}
