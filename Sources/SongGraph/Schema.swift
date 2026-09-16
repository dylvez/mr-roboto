/// A plain JSON tree. Schema migrations operate on this, so they can rewrite documents written by older builds
/// without depending on the current Swift types.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Integers, and doubles with no fractional part.
    public var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d) where d.rounded() == d && abs(d) < 9e15: return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let d): return d
        default: return nil
        }
    }

    /// Member access on objects; nil for other values. Setting on a non-object is ignored.
    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    /// Element access on arrays; nil when out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Applies `transform` to every element of the array at `key`, if present.
    public func mappingArray(at key: String, _ transform: (JSONValue) throws -> JSONValue) rethrows -> JSONValue {
        guard case .object(var object) = self, case .array(let items)? = object[key] else { return self }
        object[key] = .array(try items.map(transform))
        return .object(object)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .integer(let integer): try container.encode(integer)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

/// One step of schema migration, from one version to the next.
public struct SchemaMigration: Sendable {
    public let from: Int
    public let to: Int
    public let summary: String
    public let transform: @Sendable (JSONValue) throws -> JSONValue

    public init(from: Int, to: Int, summary: String, transform: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        self.from = from
        self.to = to
        self.summary = summary
        self.transform = transform
    }
}

/// Upgrades a JSON document to the current schema by applying registered migrations in sequence.
/// A document without `schemaVersion` is treated as schema 1.
public struct SchemaMigrator: Sendable {
    public let migrations: [SchemaMigration]
    public let current: Int

    public init(migrations: [SchemaMigration], current: Int = SongGraphSchema.current) {
        self.migrations = migrations
        self.current = current
    }

    /// The migrator for `song.json`.
    public static let song = SchemaMigrator(migrations: [.songOperationsV1ToV2])

    /// The migrator for `library.json`.
    public static let library = SchemaMigrator(migrations: [.libraryOperationsV1ToV2])

    /// The schema version a document declares (1 when absent).
    public static func schemaVersion(of document: JSONValue) -> Int {
        document["schemaVersion"]?.intValue ?? 1
    }

    /// True when the document is already at the current schema.
    public func isCurrent(_ document: JSONValue) -> Bool { SchemaMigrator.schemaVersion(of: document) == current }

    /// Returns the document at the current schema. Throws for documents newer than this build or for gaps in the chain.
    public func upgrade(_ document: JSONValue) throws -> JSONValue {
        guard document.objectValue != nil else {
            throw SongGraphError.migrationFailed(from: 0, to: current, reason: "document is not a JSON object")
        }
        var version = SchemaMigrator.schemaVersion(of: document)
        guard version <= current else { throw SongGraphError.unsupportedSchemaVersion(found: version, supported: current) }
        var upgraded = document
        while version < current {
            guard let step = migrations.first(where: { $0.from == version }) else {
                throw SongGraphError.migrationFailed(from: version, to: current, reason: "no migration registered from schema \(version)")
            }
            do {
                upgraded = try step.transform(upgraded)
            } catch let error as SongGraphError {
                throw error
            } catch {
                throw SongGraphError.migrationFailed(from: step.from, to: step.to, reason: "\(error)")
            }
            version = step.to
            upgraded["schemaVersion"] = .integer(version)
        }
        return upgraded
    }
}

extension SchemaMigration {
    /// Schema 1 versions had no `operation`; schema 2 requires one. Fills "unknown".
    static func fillingMissingOperation(_ version: JSONValue) -> JSONValue {
        guard version.objectValue != nil else { return version }
        var filled = version
        if filled["operation"]?.stringValue == nil { filled["operation"] = .string(Operation.unknown) }
        return filled
    }

    /// song.json 1 → 2: every entry of `versions` gains `operation` ("unknown" when absent).
    public static let songOperationsV1ToV2 = SchemaMigration(
        from: 1, to: 2, summary: "Versions record the operation that made them; older versions get \"unknown\"."
    ) { document in
        document.mappingArray(at: "versions", fillingMissingOperation)
    }

    /// library.json 1 → 2: `ideas` and each record's `analysis` gain `operation`.
    public static let libraryOperationsV1ToV2 = SchemaMigration(
        from: 1, to: 2, summary: "Ideas and record analyses record the operation that made them; older ones get \"unknown\"."
    ) { document in
        document
            .mappingArray(at: "ideas", fillingMissingOperation)
            .mappingArray(at: "records") { record in
                guard var updated = Optional(record), let analysis = record["analysis"], !analysis.isNull else { return record }
                updated["analysis"] = fillingMissingOperation(analysis)
                return updated
            }
    }
}
