import Foundation
import Testing
@testable import Instrument

// A drum kit of recordings, brought in from an SFZ laid out as General MIDI lays a kit out, and
// listed beside the machines as one of them.

@Suite("Recorded kits")
struct RecordedKitsTests {

    /// A burst of noise that dies away: enough of a drum to be levelled and told from another.
    private func hit(seed: UInt64, seconds: Double = 0.2, level: Float = 0.5) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let frames = Int(seconds * 48_000)
        return (0..<frames).map { frame in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int64(bitPattern: state >> 11) % 2_000) / 1_000 - 1
            return noise * level * Float(exp(-6 * Double(frame) / Double(frames)))
        }
    }

    /// A kit as the baker writes one: a file a hit, a key a piece, two layers on the kick.
    private func pack(named name: String, in root: URL, keys: [Int] = [36, 38, 42, 46, 41, 43, 45]) throws -> URL {
        let folder = root.appendingPathComponent("Pack", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("samples"), withIntermediateDirectories: true)
        var sfz = "<control>\n<global> loop_mode=one_shot\n"
        for key in keys {
            let layers: [(ClosedRange<Int>, Float)] = key == 36 ? [(1...63, 0.2), (64...127, 0.6)] : [(1...127, 0.5)]
            for (index, layer) in layers.enumerated() {
                let file = "samples/k\(key)_\(index).wav"
                try SynthesizedKit.writeWAV(hit(seed: UInt64(key * 10 + index), level: layer.1),
                                            to: folder.appendingPathComponent(file), sampleRate: 48_000)
                sfz += "<region> sample=\(file) key=\(key) lovel=\(layer.0.lowerBound) hivel=\(layer.0.upperBound)\n"
            }
        }
        let url = folder.appendingPathComponent("\(name).sfz")
        try sfz.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a kit's recordings play its pieces, a machine plays the rest, and it is found by id beside the machines")
    func importsAKit() throws {
        let root = TempDirectory("recorded-kit")
        defer { root.remove() }
        let name = "Test Kit \(UUID().uuidString.prefix(6))"
        let library = root.url.appendingPathComponent("Kits", isDirectory: true)
        let result = try RecordedKits.importSFZ(at: try pack(named: name, in: root.url), into: library, base: "vintage")
        defer { RecordedKits.unregister(id: result.kit.id) }

        #expect(result.kit.id.hasPrefix("kit-test-kit-"))
        #expect(result.kit.base == "vintage")
        #expect(result.recorded == [.kick, .snare, .closedHat, .openHat, .lowTom, .midTom, .highTom])
        #expect(result.synthesized.contains(.crash) && result.synthesized.contains(.ride) && result.synthesized.contains(.rim))
        #expect(!result.synthesized.contains(.shaker), "hand percussion is not the kit's to cover")
        #expect(result.kit.summary.contains("kick, snare, hats and toms"), "\(result.kit.summary)")
        #expect(result.kit.summary.contains("The Vintage Kit plays the"), "\(result.kit.summary)")
        #expect(result.kit.assignments.first { $0.kind == .midTom }?.note == 43)

        // Found the way a song finds its machine, listed for a picker, and not among the presets.
        let machine = try #require(SynthMachine.preset(id: result.kit.id))
        #expect(machine.name == name && machine.family == .recorded)
        #expect(machine.voices == SynthMachine.vintage.voices)
        #expect(SynthMachine.available.contains { $0.id == result.kit.id })
        #expect(!SynthMachine.all.contains { $0.id == result.kit.id })
        #expect(SynthMachine.all.count == 17)

        // Built, the kit plays the recordings where there are some.
        let built = try SynthesizedKit.build(machine, in: root.url.appendingPathComponent("built"), recorded: nil)
        #expect(built.validate().isClean, "\(built.validate().findings.map(\.description))")
        func zones(_ kind: SynthVoiceKind) -> [Zone] { built.manifest.zones.filter { $0.key.noteRange.contains(kind.generalMIDINote) } }
        #expect(zones(.kick).count == 2 && zones(.kick).allSatisfy { $0.sample.hasPrefix("samples/recorded/") })
        #expect(Set(zones(.kick).map(\.velocity)) == [1...63, 64...127], "the kit's own layers")
        #expect(zones(.snare).count == 1 && zones(.snare)[0].sample.hasPrefix("samples/recorded/"))
        #expect(zones(.crash).allSatisfy { !$0.sample.contains("recorded") } && !zones(.crash).isEmpty)
        // The toms are on the keys the app plays them on, whatever keys the pack had them on.
        #expect(zones(.midTom).allSatisfy { $0.sample.hasPrefix("samples/recorded/") } && !zones(.midTom).isEmpty)
        // One pair of hats: either cuts the other.
        for hat in zones(.closedHat) + zones(.openHat) {
            #expect(hat.group == SynthesizedKit.hatChokeGroup && hat.offBy == SynthesizedKit.hatChokeGroup)
            #expect(hat.sample.hasPrefix("samples/recorded/"))
        }
        #expect(zones(.kick).allSatisfy { $0.group == nil && $0.offBy == nil })
        #expect(built.manifest.note(for: .kick) == SynthVoiceKind.kick.generalMIDINote)

        // Both layers of the kick at the loudness of the machine's own, the soft one no quieter on
        // disk: the kit's velocity curve is what makes a soft hit soft.
        let gains = zones(.kick).sorted { $0.velocity.lowerBound < $1.velocity.lowerBound }.map(\.gainDB)
        #expect(gains[0] > gains[1] + 6, "\(gains)")

        // Its folder is its own, and a kit with other recordings is another folder.
        let folder = SynthesizedKit.folderName(for: machine, recorded: nil)
        #expect(folder.hasPrefix("\(result.kit.id)-"))
        #expect(folder != SynthesizedKit.folderName(for: SynthMachine(id: "kit-nobody", name: "x", summary: "", voices: machine.voices), recorded: nil)
                    .replacingOccurrences(of: "kit-nobody", with: result.kit.id))

        // Read again from disk, as the app does when the library opens.
        RecordedKits.unregister(id: result.kit.id)
        #expect(SynthMachine.preset(id: result.kit.id) == nil)
        #expect(RecordedKits.load(from: library).map(\.id) == [result.kit.id])
        #expect(SynthMachine.preset(id: result.kit.id)?.name == name)

        // Taken out, its folder goes with it.
        try RecordedKits.remove(id: result.kit.id, from: library)
        #expect(RecordedKits.kit(id: result.kit.id) == nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: library.path)).isEmpty)
    }

    @Test("two toms are the low and the high; an instrument's SFZ is not a kit")
    func whatIsAKit() throws {
        let twoToms = RecordedKits.assignments(forKeys: [36, 41, 45], source: "k", name: "K")
        #expect(twoToms.first { $0.kind == .lowTom }?.note == 41)
        #expect(twoToms.first { $0.kind == .highTom }?.note == 45)
        #expect(RecordedKits.assignments(forKeys: [35, 40], source: "k", name: "K").map(\.note) == [35, 40], "the second kick and the second snare")
        // Stirs where the congas would be, a splash where the tambourine would: left alone.
        #expect(RecordedKits.assignments(forKeys: [54, 60, 61, 63, 64], source: "k", name: "K").isEmpty)

        let root = TempDirectory("not-a-kit")
        defer { root.remove() }
        let folder = root.url.appendingPathComponent("Pack", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SynthesizedKit.writeWAV(hit(seed: 1), to: folder.appendingPathComponent("c3.wav"), sampleRate: 48_000)
        let url = folder.appendingPathComponent("Piano.sfz")
        try "<region> sample=c3.wav lokey=36 hikey=60 pitch_keycenter=48".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: RecordedKits.ImportError.notAKit(file: "Piano.sfz")) {
            try RecordedKits.importSFZ(at: url, into: root.url.appendingPathComponent("Kits"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Kits/piano").path), "nothing was copied")
    }

    @Test("an imported instrument is a bass voice when a line names it, and the presets are still the presets")
    func bassOnARecording() throws {
        let spec = InstrumentVoiceSpec(id: "sfz-test-contrabass-\(UUID().uuidString.prefix(6))", name: "Contrabass", family: ImportedInstruments.family,
                                       engine: .sampled, summary: "Sampled, from Contrabass.sfz.", sampledKit: "/nonexistent")
        ImportedInstruments.register(spec)
        defer { ImportedInstruments.unregister(id: spec.id) }
        let voice = try #require(BassVoiceSpec.resolve(id: spec.id))
        #expect(voice.isImported && voice.name == "Contrabass" && voice.family == .played)
        #expect(voice.synth?.id == spec.id)
        #expect(BassVoiceSpec.resolve(id: "finger") == BassVoiceSpec.finger)
        #expect(BassVoiceSpec.resolve(id: "finger")?.isImported == false)
        #expect(BassVoiceSpec.resolve(id: "sfz-nobody") == nil)
        #expect(!BassVoiceSpec.all.contains { $0.id == spec.id })
    }
}
