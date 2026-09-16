import Foundation
import Testing
@testable import SongGraph

/// A `song.json` as schema 1 wrote it: no top-level `schemaVersion`, and versions carried no `operation`.
let schema1SongFixture = """
{
  "id": "0B4A6C1E-2D3F-4E5A-8B9C-0D1E2F3A4B5C",
  "title": "Arrival",
  "artist": "Vessel",
  "key": { "tonic": { "letter": 1, "accidental": 0 }, "mode": 1 },
  "tempo": 113,
  "timeSignature": { "beatsPerBar": 4, "beatUnit": 4 },
  "createdAt": "2026-09-01T10:00:00.000Z",
  "seeds": [
    { "id": "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C6D", "createdAt": "2026-09-01T10:00:00.000Z",
      "kind": { "type": "brief", "text": "something slow" } }
  ],
  "versions": [
    { "id": "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "partID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "createdAt": "2026-09-01T10:01:00.000Z", "author": { "role": "user" }, "parents": [],
      "origin": "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C6D",
      "kind": { "type": "melody", "notes": [ { "pitch": { "midi": 62 }, "start": 0, "duration": 1, "velocity": 96 } ] } },
    { "id": "2A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "partID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "createdAt": "2026-09-01T10:02:00.000Z", "author": { "role": "persona", "name": "Bassist" },
      "parents": ["1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"], "operation": "transpose",
      "kind": { "type": "melody", "notes": [ { "pitch": { "midi": 64 }, "start": 0, "duration": 1, "velocity": 96 } ] } }
  ],
  "sections": [
    { "id": "3A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "name": "Verse", "lengthInBars": 8,
      "stitch": ["2A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"] }
  ],
  "experiments": []
}
"""

@Suite struct SchemaTests {
    @Test func schema1SongMigratesToSchema2() throws {
        let song = try SongGraphCodec.decodeSong(from: Data(schema1SongFixture.utf8))
        #expect(song.schemaVersion == 2)
        #expect(song.title == "Arrival")
        #expect(song.key == Fixtures.dMajor)
        #expect(song.versions.count == 2)
        #expect(song.versions[0].operation == Operation.unknown)
        #expect(song.versions[1].operation == "transpose")
        #expect(song.versions[1].author == .persona("Bassist"))
        #expect(song.versions[0].origin == song.seeds[0].id)
        #expect(song.sections[0].stitch == [song.versions[1].id])
        // Re-encoding writes the current schema.
        let json = try SongGraphCodec.decode(JSONValue.self, from: try SongGraphCodec.encodeSong(song))
        #expect(json["schemaVersion"]?.intValue == 2)
        #expect(json["versions"]?[0]?["operation"]?.stringValue == "unknown")
    }

    @Test func migratorFillsOnlyMissingOperations() throws {
        let document = try SongGraphCodec.decode(JSONValue.self, from: Data(schema1SongFixture.utf8))
        #expect(SchemaMigrator.schemaVersion(of: document) == 1)
        #expect(!SchemaMigrator.song.isCurrent(document))
        let upgraded = try SchemaMigrator.song.upgrade(document)
        #expect(upgraded["schemaVersion"]?.intValue == 2)
        #expect(upgraded["versions"]?[0]?["operation"]?.stringValue == "unknown")
        #expect(upgraded["versions"]?[1]?["operation"]?.stringValue == "transpose")
        #expect(SchemaMigrator.song.isCurrent(upgraded))
        #expect(try SchemaMigrator.song.upgrade(upgraded) == upgraded)
    }

    @Test func libraryMigrationCoversIdeasAndRecordAnalyses() throws {
        let document: JSONValue = .object([
            "ideas": .array([.object(["id": .string("x")])]),
            "records": .array([
                .object(["title": .string("a"), "analysis": .object(["id": .string("y")])]),
                .object(["title": .string("b"), "analysis": .null]),
                .object(["title": .string("c")]),
            ]),
        ])
        let upgraded = try SchemaMigrator.library.upgrade(document)
        #expect(upgraded["ideas"]?[0]?["operation"]?.stringValue == "unknown")
        #expect(upgraded["records"]?[0]?["analysis"]?["operation"]?.stringValue == "unknown")
        #expect(upgraded["records"]?[1]?["analysis"]?.isNull == true)
        #expect(upgraded["records"]?[2]?["analysis"] == nil)
        #expect(upgraded["schemaVersion"]?.intValue == 2)
    }

    @Test func newerDocumentsAreRefused() throws {
        let document: JSONValue = .object(["schemaVersion": .integer(99)])
        #expect(throws: SongGraphError.unsupportedSchemaVersion(found: 99, supported: 2)) {
            try SchemaMigrator.song.upgrade(document)
        }
        #expect(throws: SongGraphError.migrationFailed(from: 0, to: 2, reason: "document is not a JSON object")) {
            try SchemaMigrator.song.upgrade(.array([]))
        }
    }

    @Test func gapsInTheChainAreReported() {
        let migrator = SchemaMigrator(migrations: [], current: 2)
        #expect(throws: SongGraphError.self) { try migrator.upgrade(.object([:])) }
    }

    @Test func jsonValueRoundTripsNumbersDistinctly() throws {
        let value: JSONValue = .object(["i": .integer(2), "d": .number(2.5), "b": .bool(true), "n": .null, "a": .array([.string("s")])])
        let decoded = try SongGraphCodec.decode(JSONValue.self, from: try SongGraphCodec.encode(value))
        #expect(decoded == value)
        #expect(decoded["i"]?.intValue == 2)
        #expect(decoded["d"]?.doubleValue == 2.5)
        #expect(decoded["d"]?.intValue == nil)
    }
}
