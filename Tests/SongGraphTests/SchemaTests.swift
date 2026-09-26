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

/// A `song.json` as schema 2 wrote it: stitches are arrays of version ids, and this one exercises
/// all three of the 2→3 rules at once — two versions of *one* part, an id the document no longer
/// holds, and two versions of two *different* parts.
let schema2SongFixture = """
{
  "schemaVersion": 2,
  "id": "1B4A6C1E-2D3F-4E5A-8B9C-0D1E2F3A4B5C",
  "title": "Still Water",
  "artist": "Vessel",
  "tempo": 72,
  "timeSignature": { "beatsPerBar": 4, "beatUnit": 4 },
  "createdAt": "2026-09-01T10:00:00.000Z",
  "seeds": [],
  "experiments": [],
  "versions": [
    { "id": "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "partID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "createdAt": "2026-09-01T10:01:00.000Z", "author": { "role": "user" }, "parents": [], "operation": "written",
      "kind": { "type": "melody", "notes": [ { "pitch": { "midi": 62 }, "start": 0, "duration": 1, "velocity": 96 } ] } },
    { "id": "2A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "partID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "createdAt": "2026-09-01T10:02:00.000Z", "author": { "role": "user" },
      "parents": ["1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"], "operation": "edit",
      "kind": { "type": "melody", "notes": [ { "pitch": { "midi": 64 }, "start": 0, "duration": 1, "velocity": 96 } ] } },
    { "id": "4A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "partID": "CCCCCCCC-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
      "createdAt": "2026-09-01T10:03:00.000Z", "author": { "role": "user" }, "parents": [], "operation": "written",
      "kind": { "type": "lyric", "lines": [] } }
  ],
  "sections": [
    { "id": "3A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D", "name": "Verse", "lengthInBars": 8,
      "stitch": ["1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D",
                 "2A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D",
                 "9F9F9F9F-5E6F-4A7B-8C9D-0E1F2A3B4C5D",
                 "4A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"] }
  ]
}
"""

@Suite struct SchemaTests {

    @Test("schema 2 to 3: a stitch of versions becomes a stitch of parts, following them")
    func schema2SongRestitches() throws {
        let song = try SongGraphCodec.decodeSong(from: Data(schema2SongFixture.utf8))
        #expect(song.schemaVersion == 3)
        let verse = try #require(song.sections.first)

        let melodyPart = try #require(song.versions.first).partID
        let lyricPart = try #require(song.versions.last).partID
        // Two versions of one part collapse to one lane; a dangling id is dropped; a second part
        // stays. Order is the order the stitch named them in.
        #expect(verse.stitch.map(\.part) == [melodyPart, lyricPart])
        #expect(verse.stitch.allSatisfy { $0.pin == nil }, "migrating pins nothing")

        // And the lane follows: it plays the *newer* of the two melodies, which is what the stitch
        // was already sounding, and would go on following a third if one were kept.
        #expect(song.version(playing: verse.stitch[0])?.id.description
                == "2A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D")
    }

    @Test func schema1SongMigratesToTheCurrentSchema() throws {
        let song = try SongGraphCodec.decodeSong(from: Data(schema1SongFixture.utf8))
        #expect(song.schemaVersion == 3)
        #expect(song.title == "Arrival")
        #expect(song.key == Fixtures.dMajor)
        #expect(song.versions.count == 2)
        #expect(song.versions[0].operation == Operation.unknown)
        #expect(song.versions[1].operation == "transpose")
        #expect(song.versions[1].author == .persona("Bassist"))
        #expect(song.versions[0].origin == song.seeds[0].id)
        // The stitch named a version; it names that version's part now, and follows it.
        #expect(song.sections[0].stitch == [Lane(part: song.versions[1].partID)])
        #expect(song.version(playing: song.sections[0].stitch[0])?.id == song.versions[1].id)
        // Re-encoding writes the current schema.
        let json = try SongGraphCodec.decode(JSONValue.self, from: try SongGraphCodec.encodeSong(song))
        #expect(json["schemaVersion"]?.intValue == 3)
        #expect(json["sections"]?[0]?["stitch"]?[0]?["pin"] == nil, "a following lane writes no pin")
        #expect(json["versions"]?[0]?["operation"]?.stringValue == "unknown")
    }

    @Test func migratorFillsOnlyMissingOperations() throws {
        let document = try SongGraphCodec.decode(JSONValue.self, from: Data(schema1SongFixture.utf8))
        #expect(SchemaMigrator.schemaVersion(of: document) == 1)
        #expect(!SchemaMigrator.song.isCurrent(document))
        let upgraded = try SchemaMigrator.song.upgrade(document)
        #expect(upgraded["schemaVersion"]?.intValue == 3)
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
        #expect(upgraded["schemaVersion"]?.intValue == 3)
    }

    @Test func newerDocumentsAreRefused() throws {
        let document: JSONValue = .object(["schemaVersion": .integer(99)])
        #expect(throws: SongGraphError.unsupportedSchemaVersion(found: 99, supported: 3)) {
            try SchemaMigrator.song.upgrade(document)
        }
        #expect(throws: SongGraphError.migrationFailed(from: 0, to: 3, reason: "document is not a JSON object")) {
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

@Suite("A chop's pad trims")
struct PadTrimTests {
    @Test("trims round-trip, and a chop with none writes what it always wrote")
    func roundTrip() throws {
        var sample = Fixtures.sample
        let plain = try JSONEncoder().encode(sample)
        #expect(!String(decoding: plain, as: UTF8.self).contains("pads"), "no key for a chop with no trims")
        #expect(try JSONDecoder().decode(Sample.self, from: plain).pads.isEmpty)

        sample.pads = [PadTrim(slice: 1, tuneCents: -1200, gainDB: -3, reverse: true, stretchRatio: 1.5)]
        let trimmed = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(sample))
        #expect(trimmed == sample)
    }
}
