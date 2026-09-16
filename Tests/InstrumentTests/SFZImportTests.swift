import Foundation
import Testing
@testable import Instrument

@Test func sfzImportBuildsZonesWithGroupInheritanceAndDefaultPath() throws {
    let result = SFZImporter.parse(Fixtures.sfzText, name: "Test Kit")
    #expect(result.manifest.name == "Test Kit")
    #expect(result.manifest.kind == .sampled)
    #expect(result.regionCount == 5)
    #expect(result.manifest.zones.count == 4)  // the end=-1 region is dropped

    let kick1 = try #require(result.manifest.zones.first)
    // default_path prefixes the sample, and a value with a space survives the one-line tokeniser.
    #expect(kick1.sample == "samples/kick 1.wav")
    #expect(kick1.key == .note(36))
    #expect(kick1.velocity == 1...63)
    #expect(kick1.seqPosition == 1 && kick1.seqLength == 2)
    // Inherited from <group>, including the opcodes on the group's second line.
    #expect(kick1.group == 1 && kick1.offBy == 1)
    #expect(kick1.gainDB == -3)
    #expect(kick1.envelope.attack == 0.001)
    #expect(kick1.envelope.release == 0.08)

    let kick2 = result.manifest.zones[1]
    #expect(kick2.sample == "samples/kick 2.wav")
    #expect(kick2.seqPosition == 2)

    let hard = result.manifest.zones[2]
    #expect(hard.velocity == 64...127)
    #expect(hard.gainDB == 0)                 // the region overrides the group's volume
    #expect(hard.sampleStart == 64)
    #expect(hard.sampleEnd == 44_100)         // SFZ end is inclusive; sampleEnd is exclusive
    #expect(hard.tuneCents == 90)             // tune=-10 plus transpose=1 semitone
    #expect(hard.pan == -0.5)                 // SFZ pan is -100…100

    let hat = result.manifest.zones[3]
    #expect(hat.sample == "samples/Hats/closed.wav")   // Windows separator normalised
    #expect(hat.key == .note(42))                      // key= sets lokey, hikey and keycenter
    #expect(hat.offMode == .normal)
    #expect(hat.loop == Loop(mode: .loopContinuous, start: 100, end: 2_000))
    #expect(hat.envelope.sustain == 0.5)               // ampeg_sustain is a percentage
    #expect(hat.group == nil && hat.offBy == nil)      // a new <group> resets the inherited opcodes
    #expect(hat.gainDB == 0)
}

@Test func sfzImportReportsWhatItSkipped() throws {
    let result = SFZImporter.parse(Fixtures.sfzText, name: "Test Kit")
    #expect(result.skippedOpcodeNames.contains("bend_up"))
    #expect(result.skippedOpcodeNames.contains("xfin_lokey"))

    let bend = try #require(result.skipped.first { $0.opcode == "bend_up" })
    #expect(bend.value == "200")
    #expect(bend.reason == .unknownOpcode)
    #expect(bend.line > 0)

    // Opcodes inside a header we do not model are reported as such, not applied.
    let curve = try #require(result.skipped.first { $0.opcode == "v000" })
    #expect(curve.reason == .unknownHeader("curve"))

    // end=-1 means "never play" in SFZ; the region is dropped, loudly.
    #expect(result.skipped.contains { $0.opcode == "end" && $0.value == "-1" })
    #expect(result.manifest.zones.contains { $0.sample.contains("dead") } == false)

    // Nothing supported leaked into the report.
    #expect(result.skipped.contains { $0.opcode == "sample" && $0.reason == .unknownOpcode } == false)
}

@Test func sfzImportHandlesCommentsAndNoteNames() {
    let text = """
    <region> sample=a.wav lokey=c4 hikey=c5 pitch_keycenter=c4 // a pitched zone
    /* block
       comment sample=ignored.wav */
    <region> sample=b.wav key=f#3
    """
    let result = SFZImporter.parse(text, name: "Names")
    #expect(result.manifest.zones.count == 2)
    #expect(result.manifest.zones[0].key == .range(60...72, rootNote: 60))
    #expect(result.manifest.zones[1].key == .note(54))
    #expect(result.manifest.zones.contains { $0.sample == "ignored.wav" } == false)
}

@Test func sfzImportGivesStableZoneIDs() {
    let first = SFZImporter.parse(Fixtures.sfzText, name: "Test Kit").manifest.zones.map(\.id)
    let second = SFZImporter.parse(Fixtures.sfzText, name: "Test Kit").manifest.zones.map(\.id)
    #expect(first == second)
    #expect(Set(first).count == first.count)
    #expect(first.first == ZoneID("z001_kick_1"))
}

@Test func importedSFZSavesAsAKitFolderAndLoadsBack() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Imported", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sfz = folder.appendingPathComponent("kit.sfz")
    try Data(Fixtures.sfzText.utf8).write(to: sfz)
    for path in ["samples/kick 1.wav", "samples/kick 2.wav", "samples/kick_hard.wav", "samples/Hats/closed.wav"] {
        try AudioFixtures.writeWAV(at: KitPath.resolve(path, in: folder), frames: 64)
    }

    let result = try SFZImporter.importKit(at: sfz)
    #expect(result.manifest.name == "kit")
    try KitStore.save(result.manifest, to: folder)
    let loaded = try KitStore.load(from: folder)
    #expect(loaded.manifest.zones.count == 4)
    #expect(loaded.validate().errors.isEmpty)
}
