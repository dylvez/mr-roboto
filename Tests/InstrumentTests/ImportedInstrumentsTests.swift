import Foundation
import Testing
@testable import Instrument

// An SFZ pack brought in as an instrument: its samples copied into a folder of the app's own, its
// regions a kit, and the whole thing found by id beside the presets.

@Suite("Imported instruments")
struct ImportedInstrumentsTests {

    /// A pack laid out as they come: the .sfz in one folder, samples beside it and one level up,
    /// and one region naming a sample that is not there.
    private func pack(named name: String, in root: URL, missing: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("Pack/Programs", isDirectory: true)
        let samples = root.appendingPathComponent("Pack/Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        for (file, frequency) in [("c3.wav", 130.81), ("c4.wav", 261.63)] {
            let tone = (0..<4_800).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / 48_000)) }
            try SynthesizedKit.writeWAV(tone, to: samples.appendingPathComponent(file), sampleRate: 48_000)
        }
        var sfz = """
        <control> default_path=../Samples/
        <group> ampeg_release=0.3 fil_type=lpf_2p cutoff=2000
        <region> sample=c3.wav lokey=36 hikey=54 pitch_keycenter=48
        <region> sample=c4.wav lokey=55 hikey=84 pitch_keycenter=60
        """
        if missing { sfz += "\n<region> sample=gone.wav lokey=85 hikey=96 pitch_keycenter=90" }
        let url = folder.appendingPathComponent("\(name).sfz")
        try sfz.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("an import copies what plays, says what it left out, and is found by id beside the presets")
    func importsAPack() throws {
        let root = TempDirectory("sfz-import")
        defer { root.remove() }
        let name = "Test Upright \(UUID().uuidString.prefix(6))"
        let url = try pack(named: name, in: root.url)
        let library = root.url.appendingPathComponent("Instruments", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let result = try ImportedInstruments.importSFZ(at: url, into: library)
        defer { ImportedInstruments.unregister(id: result.spec.id) }
        #expect(result.spec.id.hasPrefix("sfz-test-upright-"))
        #expect(result.spec.engine == .sampled && result.spec.family == "keys", "an upright is looked for among the keys")
        #expect(result.zones == 2 && result.samples == 2)
        #expect(result.unusable == ["../Samples/gone.wav"])
        #expect(result.skippedOpcodes.contains("cutoff") && result.skippedOpcodes.contains("fil_type"))
        #expect(!result.replaced)
        #expect(result.spec.summary.contains("2 zones from 2 recordings, C2–C6"), "\(result.spec.summary)")

        // The copy is whole and self-contained; the pack is untouched.
        let folder = try #require(result.spec.sampledKit.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let kit = try KitStore.load(from: folder)
        #expect(kit.manifest.zones.allSatisfy { $0.sample.hasPrefix("samples/") })
        #expect(kit.validate().isClean, "\(kit.validate().findings.map(\.description))")
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Pack/Samples/c3.wav").path))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: library.path)).contains { $0.hasPrefix(".") },
                "no staging folder is left behind")

        // Found the way a song finds its instrument, and played from the kit rather than rendered.
        #expect(InstrumentVoiceSpec.preset(id: result.spec.id)?.name == name)
        #expect(InstrumentVoiceSpec.available.contains { $0.id == result.spec.id })
        #expect(!InstrumentVoiceSpec.all.contains { $0.id == result.spec.id }, "the presets stay the presets")
        let built = try SynthesizedInstrument.build(result.spec, in: root.url.appendingPathComponent("cache"))
        #expect(built.folder.standardizedFileURL == folder.standardizedFileURL)
        #expect(InstrumentSynthesizer.render(result.spec, midi: 60, velocity: 100, seconds: 0.1).allSatisfy { $0 == 0 })

        // Importing it again replaces it in place.
        let again = try ImportedInstruments.importSFZ(at: url, into: library)
        #expect(again.replaced && again.spec.id == result.spec.id)
        #expect(ImportedInstruments.all.filter { $0.id == result.spec.id }.count == 1)
    }

    @Test("what is imported is found again on the next launch, and removing it removes the copy")
    func reloadsAndRemoves() throws {
        let root = TempDirectory("sfz-reload")
        defer { root.remove() }
        let url = try pack(named: "Reloaded \(UUID().uuidString.prefix(6))", in: root.url, missing: false)
        let library = root.url.appendingPathComponent("Instruments", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let spec = try ImportedInstruments.importSFZ(at: url, into: library).spec
        let written = try String(contentsOf: library.appendingPathComponent(URL(fileURLWithPath: spec.sampledKit!).lastPathComponent)
            .appendingPathComponent(ImportedInstruments.specFileName), encoding: .utf8)
        #expect(!written.contains("sampledKit"), "where it lives is not part of what it is")

        ImportedInstruments.unregister(id: spec.id)
        #expect(InstrumentVoiceSpec.preset(id: spec.id) == nil)
        let found = ImportedInstruments.load(from: library)
        #expect(found.map(\.id) == [spec.id])
        #expect(InstrumentVoiceSpec.preset(id: spec.id)?.sampledKit == spec.sampledKit)

        try ImportedInstruments.remove(id: spec.id)
        #expect(InstrumentVoiceSpec.preset(id: spec.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: spec.sampledKit!))
        #expect(FileManager.default.fileExists(atPath: url.path), "the pack is not touched")
    }

    @Test("a pack none of whose samples can be read is refused, and leaves nothing behind")
    func refusesAnEmptyPack() throws {
        let root = TempDirectory("sfz-empty")
        defer { root.remove() }
        let url = root.url.appendingPathComponent("Nothing.sfz")
        try "<region> sample=nowhere.wav lokey=0 hikey=127 pitch_keycenter=60".write(to: url, atomically: true, encoding: .utf8)
        let library = root.url.appendingPathComponent("Instruments", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        #expect(throws: ImportedInstruments.ImportError.noSamples(file: "Nothing.sfz", unusable: ["nowhere.wav"])) {
            try ImportedInstruments.importSFZ(at: url, into: library)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    @Test("a pack's name becomes a folder name")
    func slugs() {
        #expect(ImportedInstruments.slug(of: "Salamander Grand Piano V3") == "salamander-grand-piano-v3")
        #expect(ImportedInstruments.slug(of: "  ..//  ") == "instrument")
        #expect(ImportedInstruments.noteName(21) == "A0" && ImportedInstruments.noteName(60) == "C4")
    }

    @Test("a recording is placed by what it is called, and one nobody can place is among the imported")
    func placed() {
        let expected: [(String, String)] = [
            ("Cello Section", "strings"), ("Violin Section Pizzicato", "plucked"), ("Contrabass Pizzicato", "plucked"),
            ("Contrabass Bowed", "strings"), ("Salamander Grand Piano (Light)", "keys"), ("Upright Piano, Yamaha", "keys"),
            ("Tenor Saxophone - Vibrato", "wind"), ("Bass Clarinet", "wind"), ("Trumpet, Harmon Mute", "brass"),
            ("French Horn", "brass"), ("Pipe Organ", "organ"), ("Vibraphone - Soft Mallets", "bell"), ("Tubular Bells", "bell"),
            ("Concert Harp", "plucked"), ("Shinyguitar", "guitar"), ("Meatbass", "strings"), ("jRhodes3d", "keys"),
            ("Archtop Guitar, Pickup", "guitar"), ("Bass Guitar", "bass"), ("Electric Bass, Fretless", "bass"),
            ("Double Bass Pizzicato", "bass"), ("Double Bass Bowed", "strings"), ("Lyre, Nails", "plucked"),
            ("Something Else", ImportedInstruments.family),
        ]
        for (name, family) in expected {
            #expect(ImportedInstruments.family(named: name) == family, "\(name)")
        }
    }

    @Test("a loop written for a recording at 44.1 kHz is counted at the rate the recording is played at")
    func countsAtThePlayingRate() {
        var zone = Zone(id: ZoneID("z"), sample: "a.wav", key: .note(60), sampleStart: 441, sampleEnd: 44_100)
        zone.loop = Loop(mode: .loopContinuous, start: 22_050, end: 44_099)
        let moved = ImportedInstruments.atPlayingRate(zone, recordedAt: 44_100)
        #expect(moved.sampleStart == 480 && moved.sampleEnd == 48_000)
        #expect(moved.loop?.start == 24_000 && moved.loop?.end == 47_999 && moved.loop?.mode == .loopContinuous)
        // One recorded at the playing rate is where it was, and so is one with nothing to move.
        #expect(ImportedInstruments.atPlayingRate(zone, recordedAt: 48_000) == zone)
        let plain = Zone(id: ZoneID("p"), sample: "b.wav", key: .note(60))
        #expect(ImportedInstruments.atPlayingRate(plain, recordedAt: 44_100) == plain)
    }
}
