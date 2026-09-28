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

// MARK: - The preprocessor and the opcodes that choose which regions sound

@Test func sfzDefinesSubstituteAndIncludesSplice() throws {
    let main = """
    #define $EXT wav
    #define $EXTRA_GAIN -6
    <control> default_path=Samples/
    #include "mapping/keys.sfz"
    <region> sample=top.$EXT key=72 volume=$EXTRA_GAIN
    #include "missing.sfz"
    """
    let files = ["mapping/keys.sfz": "<group> ampeg_release=0.4\n#include \"mapping/low.sfz\"\n<region> sample=mid.$EXT key=60",
                 "mapping/low.sfz": "<region> sample=low.$EXT key=48"]
    let result = SFZImporter.parse(main, name: "Split") { files[$0] }
    #expect(result.manifest.zones.map(\.sample) == ["Samples/low.wav", "Samples/mid.wav", "Samples/top.wav"])
    #expect(result.manifest.zones.map(\.key) == [.note(48), .note(60), .note(72)])
    #expect(result.manifest.zones[2].gainDB == -6, "$EXTRA_GAIN is not eaten by $EXT")
    #expect(result.skipped.contains { $0.opcode == "#include" && $0.value == "missing.sfz" })
    #expect(!result.skipped.contains { $0.opcode.hasPrefix("#define") })

    // An include that includes itself stops, and says so.
    let loop = SFZImporter.parse("#include \"self.sfz\"\n<region> sample=a.wav", name: "Loop") { _ in "#include \"self.sfz\"" }
    #expect(loop.manifest.zones.count == 1)
    #expect(loop.skipped.contains { $0.opcode == "#include" })
}

@Test func sfzReleaseTriggersKeyswitchesAndPedalLayersAreReduced() throws {
    let text = """
    <control> set_cc64=0 note_offset=12
    <global> sw_default=c1
    <group> sw_last=c1
    <region> sample=legato.wav lokey=48 hikey=60 pitch_keycenter=54
    <group> sw_last=d1
    <region> sample=staccato.wav lokey=48 hikey=60
    <group> trigger=release
    <region> sample=release.wav lokey=48 hikey=60
    <group> locc64=64 hicc64=127
    <region> sample=pedal-down.wav lokey=48 hikey=60 sw_last=c1
    <group> locc64=0 hicc64=63
    <region> sample=pedal-up.wav lokey=61 hikey=72 sw_last=c1
    """
    let result = SFZImporter.parse(text, name: "Piano")
    #expect(result.manifest.zones.map(\.sample) == ["legato.wav", "pedal-up.wav"])
    // note_offset moves every key up an octave.
    #expect(result.manifest.zones[0].key == .range(60...72, rootNote: 66))
    let reasons = result.skipped.map(\.description).joined(separator: "\n")
    #expect(reasons.contains("1 release-trigger"))
    #expect(reasons.contains("controller 64"))
    #expect(reasons.contains("keyswitched"))

    // Pedal noise: fired by the controller, on no key.
    let pedal = SFZImporter.parse("<region> sample=note.wav key=60\n<group> lokey=-1 hikey=-1 on_locc64=126 on_hicc64=127\n<region> sample=pedal.wav",
                                  name: "Pedal")
    #expect(pedal.manifest.zones.map(\.sample) == ["note.wav"])
    #expect(pedal.skipped.contains { $0.description.contains("pedal noise") })
}

@Test func sfzRandomAlternativesBecomeARoundRobin() throws {
    let text = """
    <group> key=38 lovel=1 hivel=127
    <region> sample=snare-c.wav lorand=0.66 hirand=1
    <region> sample=snare-a.wav lorand=0 hirand=0.33
    <region> sample=snare-b.wav lorand=0.33 hirand=0.66
    <region> sample=kick.wav key=36
    """
    let result = SFZImporter.parse(text, name: "Kit")
    let snares = result.manifest.zones.filter { $0.key == .note(38) }
    #expect(snares.count == 3)
    #expect(snares.allSatisfy { $0.seqLength == 3 })
    #expect(snares.sorted { $0.seqPosition < $1.seqPosition }.map(\.sample) == ["snare-a.wav", "snare-b.wav", "snare-c.wav"])
    // One hit plays one of them.
    #expect(result.manifest.zone(note: 38, velocity: 100, roundRobin: 1)?.sample == "snare-b.wav")
    #expect(result.manifest.validate().findings.allSatisfy { !"\($0)".contains("overlap") })
    #expect(result.manifest.zones.first { $0.key == .note(36) }?.seqLength == 1)
}

@Test func sfzWithWindowsLineEndingsImports() {
    let text = "<group> ampeg_release=1\r\n<region> sample=a\\A0v1.wav lokey=21 hikey=22\r\n<region> sample=a\\C1v1.wav key=24\r\n"
    let result = SFZImporter.parse(text, name: "CRLF")
    #expect(result.manifest.zones.map(\.sample) == ["a/A0v1.wav", "a/C1v1.wav"])
    #expect(result.manifest.zones.allSatisfy { $0.envelope.release == 1 })
}
