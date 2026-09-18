import Foundation
import SongGraph
import Testing

@testable import MrRobotoApp

// Double-clicking a .roboto in Finder. A song's audio is resolved through the library, so a package
// from elsewhere is copied in before it opens — and one already there is opened, not duplicated.

@Suite("Opening a song package from Finder") @MainActor
struct OpenPackageTests {

    private func library() -> (AppState, URL) {
        let directory = GuidanceFixture.temporaryDirectory("open-library")
        let app = AppState(library: Library(), store: LibraryStore(directoryURL: directory),
                           status: .empty(directory), transportHost: StubTransportHost())
        return (app, directory)
    }

    @Test("a package from elsewhere is copied into the library, then opened")
    func fromElsewhere() throws {
        let (app, directory) = library()
        let elsewhere = GuidanceFixture.temporaryDirectory("open-elsewhere")
        defer { [directory, elsewhere].forEach { try? FileManager.default.removeItem(at: $0) } }
        let song = GuidanceFixture.grooved().song
        let store = SongStore(in: elsewhere, title: song.title)
        try store.save(song)

        let opened = app.openPackage(at: store.packageURL)
        #expect(opened, "\(app.log.map { "\($0.text) — \($0.detail ?? "")" })")
        #expect(app.song?.id == song.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(store.packageURL.lastPathComponent).path))
        #expect(app.library.song(song.id) != nil)
    }

    @Test("a package already in the library opens without a second copy")
    func alreadyThere() throws {
        let (app, directory) = library()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = GuidanceFixture.grooved().song
        let store = SongStore(in: directory, title: song.title)
        try store.save(song)
        try LibraryStore(directoryURL: directory).save(Library())
        app.reloadLibrary()

        #expect(app.openPackage(at: store.packageURL))
        #expect(app.song?.id == song.id)
        let packages = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".roboto") }
        #expect(packages.count == 1)
    }

    @Test("something that is not a song package is refused and said so")
    func notASong() throws {
        let (app, directory) = library()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bogus = directory.appendingPathComponent("Nothing.roboto")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        #expect(!app.openPackage(at: bogus))
        #expect(app.song == nil)
        #expect(app.log.last?.text.contains("Could not read") == true)
    }
}
