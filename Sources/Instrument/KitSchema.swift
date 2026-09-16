import Foundation
import SongGraph

/// One step of kit-format migration, from one `formatVersion` to the next.
///
/// Migrations run on the raw JSON tree (`SongGraph.JSONValue`), never on the Swift types, so a build
/// can upgrade a document whose shape its current `KitManifest` could not decode. Same shape as
/// `SongGraph.SchemaMigration`; the kit format keeps its own chain because it versions independently
/// of `song.json`, and its version key is `formatVersion` rather than `schemaVersion`.
public struct KitMigration: Sendable {
    public let from: Int
    public let to: Int
    public let summary: String
    public let transform: @Sendable (JSONValue) throws -> JSONValue

    public init(from: Int, to: Int, summary: String,
                transform: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        self.from = from
        self.to = to
        self.summary = summary
        self.transform = transform
    }
}

/// Upgrades a `kit.json` document to the current format version by applying registered migrations
/// in order. A document with no `formatVersion` is treated as version 1.
public struct KitMigrator: Sendable {
    public let migrations: [KitMigration]
    public let current: Int

    public init(migrations: [KitMigration] = [], current: Int = KitManifest.currentFormatVersion) {
        self.migrations = migrations
        self.current = current
    }

    /// The migrator `KitStore` uses. Empty today: version 1 is the first format. When the format
    /// changes, bump `KitManifest.currentFormatVersion` and add the step here.
    public static let current = KitMigrator()

    public static func formatVersion(of document: JSONValue) -> Int {
        document["formatVersion"]?.intValue ?? 1
    }

    public func isCurrent(_ document: JSONValue) -> Bool {
        KitMigrator.formatVersion(of: document) == current
    }

    /// The document at the current format version. Throws for documents written by a newer build,
    /// and for gaps in the migration chain.
    public func upgrade(_ document: JSONValue) throws -> JSONValue {
        guard document.objectValue != nil else {
            throw KitError.malformedManifest(path: "", reason: "kit.json is not a JSON object")
        }
        var version = KitMigrator.formatVersion(of: document)
        guard version <= current else {
            throw KitError.unsupportedFormatVersion(found: version, supported: current)
        }
        var upgraded = document
        while version < current {
            guard let step = migrations.first(where: { $0.from == version }) else {
                throw KitError.migrationFailed(from: version, to: current,
                                               reason: "no migration registered from format \(version)")
            }
            do {
                upgraded = try step.transform(upgraded)
            } catch let error as KitError {
                throw error
            } catch {
                throw KitError.migrationFailed(from: step.from, to: step.to, reason: "\(error)")
            }
            version = step.to
            upgraded["formatVersion"] = .integer(version)
        }
        return upgraded
    }

    /// Decodes a manifest from `data`, migrating it first when it is older than the current format.
    public func decode(_ data: Data, path: String) throws -> KitManifest {
        let decoder = KitCodec.makeDecoder()
        let document: JSONValue
        do {
            document = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw KitError.malformedManifest(path: path, reason: "\(error)")
        }
        let upgraded = isCurrent(document) ? document : try upgrade(document)
        do {
            var manifest = try decoder.decode(KitManifest.self, from: try KitCodec.makeEncoder().encode(upgraded))
            manifest.formatVersion = current
            return manifest
        } catch let error as KitError {
            throw error
        } catch {
            throw KitError.malformedManifest(path: path, reason: "\(error)")
        }
    }
}

/// The JSON coding kits use: pretty printed with sorted keys, so a kit.json diffs cleanly in git
/// and two saves of the same manifest are byte-identical.
public enum KitCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    public static func encode(_ manifest: KitManifest) throws -> Data {
        try makeEncoder().encode(manifest)
    }
}
