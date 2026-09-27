import Foundation
import SongGraph
import Testing

@testable import Instrument
@testable import MrRobotoApp

// File ▸ Import Instrument…: an SFZ pack into the library, into the pickers, and onto a song's
// chords by id, the way a preset is.

@Suite("Import an instrument", .serialized) @MainActor
struct ImportInstrumentTests {

    private func pack(_ name: String, in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tone = (0..<4_800).map { Float(0.4 * sin(2 * .pi * 220 * Double($0) / 48_000)) }
        try SynthesizedKit.writeWAV(tone, to: root.appendingPathComponent("a3.wav"), sampleRate: 48_000)
        let url = root.appendingPathComponent("\(name).sfz")
        try "<region> sample=a3.wav lokey=0 hikey=127 pitch_keycenter=57 lfo01_freq=5"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("imported, it is in the library and the pickers, says what it left behind, and voices the chords")
    func importsAndPlays() throws {
        let (app, directory, _) = CompletenessFixture.app("import-instrument")
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "Glass Harp \(UUID().uuidString.prefix(6))"
        let url = try pack(name, in: directory.deletingLastPathComponent().appendingPathComponent("pack-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let spec = try #require(app.importInstrument(from: url))
        defer { ImportedInstruments.unregister(id: spec.id) }
        #expect(spec.sampledKit?.hasPrefix(app.instrumentsDirectory!.path) == true, "kept in the library, beside the songs")
        #expect(app.importedInstruments.map(\.id) == [spec.id])
        let said = try #require(app.log.last)
        #expect(said.text == "Imported \(name): it is in the instrument picker, under Imported")
        #expect(said.detail?.contains("Not carried over: lfo01_freq") == true, "\(said.detail ?? "")")

        app.open(CompletenessFixture.song("Harp song"))
        #expect(app.setInstrument(spec.id))
        #expect(SongPlayback.instrumentID(in: app.song!) == spec.id)

        // The next launch reads it back from the library before any song asks for it.
        ImportedInstruments.unregister(id: spec.id)
        #expect(InstrumentVoiceSpec.preset(id: spec.id) == nil)
        app.reloadLibrary()
        #expect(app.importedInstruments.map(\.id) == [spec.id])
        #expect(SongPlayback.instrumentID(in: app.song!) == spec.id)
    }

    @Test("removed, the song goes back to its own instrument and the pack is untouched")
    func removes() throws {
        let (app, directory, _) = CompletenessFixture.app("remove-instrument")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try pack("Toy Harp \(UUID().uuidString.prefix(6))", in: directory.deletingLastPathComponent().appendingPathComponent("pack-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spec = try #require(app.importInstrument(from: url))
        app.open(CompletenessFixture.song("Toy song"))
        #expect(app.setInstrument(spec.id))

        #expect(app.removeImportedInstrument(id: spec.id))
        #expect(app.importedInstruments.isEmpty)
        #expect(SongPlayback.instrumentID(in: app.song!) == InstrumentVoiceSpec.rhodes.id)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(app.log.last?.text.hasPrefix("Removed Toy Harp") == true)
    }

    @Test("a file that is not an instrument is said, and nothing is added")
    func refuses() throws {
        let (app, directory, _) = CompletenessFixture.app("import-instrument-bad")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Empty.sfz")
        try "// nothing here".write(to: url, atomically: true, encoding: .utf8)
        #expect(app.importInstrument(from: url) == nil)
        #expect(app.importedInstruments.isEmpty)
        #expect(app.log.last?.text == "Could not import Empty.sfz")
        #expect(app.log.last?.detail == "Empty.sfz has no regions an instrument can play.")
    }
}
