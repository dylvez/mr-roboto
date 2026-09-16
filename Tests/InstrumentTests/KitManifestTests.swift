import Foundation
import SongGraph
import Testing
@testable import Instrument

// MARK: - JSON round trip

@Test func manifestRoundTripsEveryFieldThroughJSON() throws {
    let manifest = Fixtures.fullyPopulatedKit()
    let data = try KitCodec.encode(manifest)
    let decoded = try KitCodec.makeDecoder().decode(KitManifest.self, from: data)
    #expect(decoded == manifest)

    // Field by field, so a future change to Codable cannot quietly drop one.
    let drum = try #require(decoded.zones.first { $0.id == "drum" })
    #expect(drum.sample == "samples/kick hard.wav")
    #expect(drum.key == .note(36))
    #expect(drum.velocity == 64...127)
    #expect(drum.seqPosition == 2 && drum.seqLength == 3)
    #expect(drum.group == 1 && drum.offBy == 2 && drum.offMode == .normal)
    #expect(drum.sampleStart == 64 && drum.sampleEnd == 44_100)
    #expect(drum.gainDB == -3.5 && drum.pan == -0.25 && drum.tuneCents == 12.5)
    #expect(drum.envelope == Envelope(delay: 0.01, attack: 0.002, hold: 0.03, decay: 0.25, sustain: 0.5, release: 0.125))
    #expect(drum.loop == Loop(mode: .loopSustain, start: 1_000, end: 5_000))

    let pad = try #require(decoded.zones.first { $0.id == "pad" })
    #expect(pad.key == .range(48...72, rootNote: 60))

    #expect(decoded.formatVersion == 1)
    #expect(decoded.name == "Everything Kit")
    #expect(decoded.description == "Every field populated.")
    #expect(decoded.kind == .hybrid)
    #expect(decoded.velocityCurve == .table([0, 0.25, 0.5, 1]))
    #expect(decoded.voices == ["kick": 36, "snare": 38])
    #expect(decoded.synthesis != nil)
}

@Test func kitJSONUsesSFZFamiliarKeysAndRelativePaths() throws {
    let data = try KitCodec.encode(Fixtures.fullyPopulatedKit())
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let zones = try #require(json["zones"] as? [[String: Any]])
    let drum = try #require(zones.first { $0["id"] as? String == "drum" })
    #expect(drum["lovel"] as? Int == 64)
    #expect(drum["hivel"] as? Int == 127)
    #expect(drum["note"] as? Int == 36)
    let pad = try #require(zones.first { $0["id"] as? String == "pad" })
    #expect(pad["lowNote"] as? Int == 48 && pad["highNote"] as? Int == 72 && pad["rootNote"] as? Int == 60)
    #expect((pad["sample"] as? String)?.hasPrefix("/") == false)
    let curve = try #require(json["velocityCurve"] as? [String: Any])
    #expect(curve["kind"] as? String == "table")
}

// MARK: - Format version and migration

@Test func formatVersion1FixtureDecodesWithDefaults() throws {
    let fixture = """
    {
      "formatVersion": 1,
      "name": "Minimal",
      "kind": "sampled",
      "velocityCurve": {"kind": "squared"},
      "zones": [{"id": "kick", "sample": "kick.wav", "note": 36}]
    }
    """
    let manifest = try KitMigrator.current.decode(Data(fixture.utf8), path: "kit.json")
    #expect(manifest.formatVersion == KitManifest.currentFormatVersion)
    #expect(manifest.zones.count == 1)
    let zone = try #require(manifest.zones.first)
    #expect(zone.velocity == 1...127)          // lovel/hivel default to the full range
    #expect(zone.seqPosition == 1 && zone.seqLength == 1)
    #expect(zone.offMode == .fast)             // SFZ's default
    #expect(zone.envelope == .default)
    #expect(zone.loop == nil && zone.group == nil)
}

@Test func migrationHookUpgradesAnOlderDocument() throws {
    // Stands in for the first real migration: registered 1 → 2 step, current version 2.
    let step = KitMigration(from: 1, to: 2, summary: "test: kits gain a suffix") { document in
        var updated = document
        updated["name"] = .string((document["name"]?.stringValue ?? "") + " (v2)")
        return updated
    }
    let migrator = KitMigrator(migrations: [step], current: 2)
    let fixture = #"{"formatVersion": 1, "name": "Old Kit", "zones": []}"#
    let manifest = try migrator.decode(Data(fixture.utf8), path: "kit.json")
    #expect(manifest.name == "Old Kit (v2)")
    #expect(manifest.formatVersion == 2)
}

@Test func documentFromANewerBuildIsRejected() throws {
    let fixture = #"{"formatVersion": 99, "name": "Future Kit", "zones": []}"#
    #expect(throws: KitError.unsupportedFormatVersion(found: 99, supported: 1)) {
        try KitMigrator.current.decode(Data(fixture.utf8), path: "kit.json")
    }
}

@Test func aMissingMigrationStepIsAnError() throws {
    let migrator = KitMigrator(migrations: [], current: 3)
    let fixture = #"{"formatVersion": 1, "name": "Old Kit", "zones": []}"#
    #expect(throws: KitError.self) { try migrator.decode(Data(fixture.utf8), path: "kit.json") }
}

// MARK: - Velocity curves

@Test func velocityCurvesFollowTheirLaws() {
    #expect(VelocityCurve.squared.gain(forVelocity: 127) == 1)
    #expect(abs(VelocityCurve.squared.gain(forVelocity: 64) - powf(64.0 / 127, 2)) < 1e-6)
    #expect(VelocityCurve.linear.gain(forVelocity: 0) == 0)
    #expect(abs(VelocityCurve.exponent(1).gain(forVelocity: 100) - 100.0 / 127) < 1e-6)
    let table = VelocityCurve.table([0, 1])
    #expect(abs(table.gain(forVelocity: 64) - 64.0 / 127) < 1e-6)
    #expect(table.gain(forVelocity: 127) == 1)
}

// MARK: - Zone lookup

@Test func lookupPicksTheVelocityLayer() throws {
    let kit = Fixtures.roundRobinKit()
    #expect(kit.zone(note: 38, velocity: 30)?.id == "snare_soft_1")
    #expect(kit.zone(note: 38, velocity: 100)?.id == "snare_hard_1")
    #expect(kit.zone(note: 36, velocity: 1)?.id == "kick")
    #expect(kit.zone(note: 60, velocity: 100) == nil)
}

@Test func roundRobinWalksThePositionsAndWrapsAround() {
    let kit = Fixtures.roundRobinKit()
    let played = (0..<7).map { kit.zone(note: 38, velocity: 100, roundRobin: $0)?.id }
    #expect(played == ["snare_hard_1", "snare_hard_2", "snare_hard_3",
                       "snare_hard_1", "snare_hard_2", "snare_hard_3", "snare_hard_1"])
    // Deterministic: the same counter always picks the same sample.
    #expect(kit.zone(note: 38, velocity: 100, roundRobin: 4)?.id == "snare_hard_2")
    // A negative counter is folded into the set rather than returning nil.
    #expect(kit.zone(note: 38, velocity: 100, roundRobin: -1)?.id == "snare_hard_3")
}

@Test func roundRobinWithAHoleFallsBackDeterministically() {
    let kit = Fixtures.roundRobinKit()
    let played = (0..<5).map { kit.zone(note: 38, velocity: 30, roundRobin: $0)?.id }
    // Slot 3 is missing, so it repeats slot 2 instead of dropping the hit.
    #expect(played == ["snare_soft_1", "snare_soft_2", "snare_soft_2", "snare_soft_4", "snare_soft_1"])
}

@Test func grooveVoicesAndVelocityTiersAddressZones() {
    let kit = Fixtures.roundRobinKit()
    #expect(kit.zone(for: .kick, tier: .normal)?.id == "kick")
    #expect(kit.zone(for: .snare, tier: .accent)?.id == "snare_hard_1")     // 120
    #expect(kit.zone(for: .snare, tier: .ghost)?.id == "snare_soft_1")      // 40
    #expect(kit.zone(for: .snare, tier: .rest) == nil)                      // a rest plays nothing
    #expect(kit.zone(for: .crash, tier: .accent) == nil)                    // unmapped voice
    #expect(kit.zone(for: .snare, tier: .accent, roundRobin: 1)?.id == "snare_hard_2")
    #expect(kit.note(for: .snare) == 38)
}

// MARK: - Validation

@Test func validationCatchesOverlappingZones() {
    let kit = KitManifest(name: "Overlap", zones: [
        .drum(id: "a", sample: "a.wav", note: 36, velocity: 1...127),
        .drum(id: "b", sample: "b.wav", note: 36, velocity: 100...127),
    ])
    let findings = kit.validate().findings
    #expect(findings.contains(.overlappingZones("a", "b", notes: 36...36, velocities: 100...127)))
    // Round-robin members share a region on purpose, so they are not flagged.
    #expect(Fixtures.roundRobinKit().validate().findings.contains { if case .overlappingZones = $0 { return true } else { return false } } == false)
}

@Test func validationCatchesVelocityGaps() {
    let kit = KitManifest(name: "Gap", zones: [
        .drum(id: "soft", sample: "soft.wav", note: 36, velocity: 1...50),
        .drum(id: "hard", sample: "hard.wav", note: 36, velocity: 80...127),
    ])
    #expect(kit.validate().findings.contains(.velocityGap(notes: 36...36, missing: 51...79)))
}

@Test func validationCatchesRoundRobinHoles() {
    let findings = Fixtures.roundRobinKit().validate().findings
    #expect(findings.contains(.roundRobinHole(notes: 38...38, velocities: 1...63, seqLength: 4, missing: [3])))
    #expect(findings.contains { if case .roundRobinHole(_, let velocities, _, _) = $0 { return velocities == 64...127 } else { return false } } == false)
}

@Test func validationCatchesMissingSamplesAndAbsolutePaths() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    temp.touch("there.wav")
    let kit = KitManifest(name: "Files", zones: [
        .drum(id: "there", sample: "there.wav", note: 36),
        .drum(id: "gone", sample: "nested/gone.wav", note: 38),
        .drum(id: "absolute", sample: "/Users/someone/kick.wav", note: 40),
    ])
    let validation = kit.validate(resolvingSamplesAgainst: temp.url)
    #expect(validation.findings.contains(.missingSample("gone", path: "nested/gone.wav")))
    #expect(validation.findings.contains(.absoluteSamplePath("absolute", path: "/Users/someone/kick.wav")))
    #expect(validation.findings.contains(.missingSample("there", path: "there.wav")) == false)
    #expect(validation.isPlayable == false)
    #expect(validation.errors.count == 2)
    // Without a folder the file checks are skipped, but the absolute path is still wrong.
    #expect(kit.validate().findings.contains { if case .missingSample = $0 { return true } else { return false } } == false)
}

@Test func aCleanKitValidatesClean() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    temp.touch("kick.wav")
    let kit = KitManifest(name: "Clean", zones: [.drum(id: "kick", sample: "kick.wav", note: 36)])
    #expect(kit.validate(resolvingSamplesAgainst: temp.url).isClean)
}
