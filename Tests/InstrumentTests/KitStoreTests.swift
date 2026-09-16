import Foundation
import Testing
@testable import Instrument

@Test func storeSavesAndLoadsAKitFolder() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("MyKit", isDirectory: true)
    let manifest = Fixtures.fullyPopulatedKit()
    try KitStore.save(manifest, to: folder)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/kick hard.wav", in: folder), frames: 256)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/pad.wav", in: folder), frames: 256)

    let loaded = try KitStore.load(from: folder)
    #expect(loaded.manifest == manifest)
    #expect(loaded.folder == folder)
    #expect(loaded.url(for: loaded.manifest.zones[0]).lastPathComponent == "kick hard.wav")
    #expect(loaded.sampleURLs.count == 2)
    // The fixture is deliberately partial (one velocity layer per zone), so it warns but plays.
    #expect(loaded.validate().isPlayable)
    #expect(loaded.validate().errors.isEmpty)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kit.json").path))
}

@Test func aMovedKitFolderStillResolvesItsSamples() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let original = temp.url.appendingPathComponent("Original", isDirectory: true)
    let manifest = KitManifest(name: "Movable", zones: [
        .drum(id: "kick", sample: "samples/kick.wav", note: 36),
    ])
    try KitStore.save(manifest, to: original)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/kick.wav", in: original), frames: 128)
    _ = try KitStore.load(from: original)

    let moved = temp.url.appendingPathComponent("Somewhere Else/Moved", isDirectory: true)
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: original, to: moved)

    let loaded = try KitStore.load(from: moved)
    #expect(loaded.manifest == manifest)
    #expect(loaded.url(for: loaded.manifest.zones[0]).path.hasPrefix(moved.path))
    #expect(FileManager.default.fileExists(atPath: loaded.url(for: loaded.manifest.zones[0]).path))
}

@Test func aMissingSampleFailsTheLoadAndNamesTheFile() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Broken", isDirectory: true)
    let manifest = KitManifest(name: "Broken", zones: [
        .drum(id: "kick", sample: "samples/kick.wav", note: 36),
        .drum(id: "snare", sample: "samples/snare.wav", note: 38),
    ])
    try KitStore.save(manifest, to: folder)
    try AudioFixtures.writeWAV(at: KitPath.resolve("samples/kick.wav", in: folder), frames: 64)

    // The Apple sampler loaded this kit and played silence. We refuse it, and say which zone and file.
    let error = #expect(throws: KitError.self) { try KitStore.load(from: folder) }
    guard case .missingSample(let zone, let path, _) = try #require(error) else {
        Issue.record("expected a missingSample error, got \(String(describing: error))")
        return
    }
    #expect(zone == "snare")
    #expect(path == "samples/snare.wav")
    #expect("\(try #require(error))".contains("samples/snare.wav"))

    // A kit still being assembled can be loaded without its audio, explicitly.
    #expect(throws: Never.self) { try KitStore.load(from: folder, checkingSamples: false) }
}

@Test func absoluteSamplePathsAreRefusedOnSaveAndLoad() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Absolute", isDirectory: true)
    let manifest = KitManifest(name: "Absolute", zones: [
        .drum(id: "kick", sample: "/Users/someone/kick.wav", note: 36),
    ])
    #expect(throws: KitError.absoluteSamplePath(zone: "kick", path: "/Users/someone/kick.wav")) {
        try KitStore.save(manifest, to: folder)
    }

    // Hand-edited on disk: caught on load too.
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let json = #"{"formatVersion":1,"name":"Absolute","zones":[{"id":"kick","sample":"C:\\Packs\\kick.wav","note":36}]}"#
    try Data(json.utf8).write(to: folder.appendingPathComponent("kit.json"))
    #expect(throws: KitError.self) { try KitStore.load(from: folder) }
}

@Test func missingOrMalformedManifestsAreTypedErrors() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    #expect(throws: KitError.missingManifest(path: temp.url.path)) { try KitStore.load(from: temp.url) }
    #expect(throws: KitError.notADirectory(path: temp.file("nope").path)) {
        try KitStore.load(from: temp.file("nope"))
    }
    try Data("{ not json".utf8).write(to: temp.file("kit.json"))
    let error = #expect(throws: KitError.self) { try KitStore.load(from: temp.url) }
    guard case .malformedManifest = try #require(error) else {
        Issue.record("expected malformedManifest, got \(String(describing: error))")
        return
    }
}

@Test func savingTwiceProducesIdenticalBytes() throws {
    let temp = TempDirectory()
    defer { temp.remove() }
    let folder = temp.url.appendingPathComponent("Stable", isDirectory: true)
    let manifest = Fixtures.roundRobinKit()
    try KitStore.save(manifest, to: folder)
    let first = try Data(contentsOf: folder.appendingPathComponent("kit.json"))
    try KitStore.save(manifest, to: folder)
    let second = try Data(contentsOf: folder.appendingPathComponent("kit.json"))
    #expect(first == second)
}
