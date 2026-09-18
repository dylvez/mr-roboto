import Foundation
import Testing
@testable import SongGraph

@Suite struct SongStoreTests {
    /// A song whose take and sample reference two media files, plus the store holding it.
    private func makePackage(in directory: URL) throws -> (store: SongStore, song: Song, take: MediaRef, sample: MediaRef) {
        let store = SongStore(in: directory, title: "Arrival: First Light")
        #expect(store.packageURL.lastPathComponent == "Arrival- First Light.roboto")
        let take = try store.addMedia(Fixtures.mediaData(10), fileExtension: "wav")
        let sample = try store.addMedia(Fixtures.mediaData(20), fileExtension: ".AIF")
        var song = Song(title: "Arrival: First Light", artist: "Vessel", key: Fixtures.dMajor, tempo: 113)
        song.seeds = [Seed(kind: .hummedTake(take))]
        let audio = Audio(media: take, role: .take, sampleRate: 48000, channelCount: 1, duration: 4.2)
        let takeVersion = PartVersion(partID: PartID(), kind: .audio(audio), author: .user, operation: Operation.hummed, origin: song.seeds[0].id)
        let sampleVersion = PartVersion(partID: PartID(), kind: .sample(Sample(media: sample, slices: [SliceMarker(position: 0.25)])),
                                        author: Fixtures.bassist, operation: Operation.chop)
        try song.append(contentsOf: [takeVersion, sampleVersion])
        try store.save(song)
        return (store, song, take, sample)
    }

    @Test func packageSurvivesRenameAndMove() throws {
        let root = try Fixtures.temporaryDirectory("rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, song, take, sample) = try makePackage(in: root)
        #expect(store.exists)
        #expect(Set(try store.storedMedia()) == [take, sample])
        #expect(sample.fileExtension == "aif")

        // Rename the package in place.
        let renamed = root.appendingPathComponent("Renamed.roboto")
        try FileManager.default.moveItem(at: store.packageURL, to: renamed)
        // Move it into another directory.
        let elsewhere = try Fixtures.temporaryDirectory("moved").appendingPathComponent("Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent()) }
        let moved = elsewhere.appendingPathComponent("Moved Again.roboto")
        try FileManager.default.moveItem(at: renamed, to: moved)

        let reloaded = SongStore(packageURL: moved)
        let loaded = try reloaded.load()
        #expect(loaded == song)
        #expect(loaded.mediaReferences == [take, sample])
        try reloaded.verifyMedia(for: loaded)
        #expect(ContentHash(of: try reloaded.readMedia(take)) == take.hash)
        #expect(ContentHash(of: try reloaded.readMedia(sample)) == sample.hash)
        #expect(try reloaded.mediaURL(for: take).lastPathComponent == take.fileName)

        // Nothing in the document points at where it used to live.
        let text = String(decoding: try Data(contentsOf: reloaded.documentURL), as: UTF8.self)
        #expect(!text.contains(root.path))
        #expect(!text.contains("/"))
    }

    @Test func missingMediaIsATypedError() throws {
        let root = try Fixtures.temporaryDirectory("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, song, take, sample) = try makePackage(in: root)
        try FileManager.default.removeItem(at: try store.mediaURL(for: sample))

        #expect(store.missingMedia(in: song) == [sample])
        #expect(store.hasMedia(take))
        #expect(!store.hasMedia(sample))
        let expected = SongGraphError.missingMedia(sample, searched: [store.mediaDirectoryURL.path])
        #expect(throws: expected) { try store.verifyMedia(for: song) }
        #expect(throws: expected) { try store.mediaURL(for: sample) }
        #expect(throws: expected) { try store.readMedia(sample) }
        #expect(expected.description.contains(sample.fileName))
        // The song itself still loads: media is checked separately from the document.
        #expect(try store.load() == song)
    }

    @Test func corruptedMediaIsAHashMismatch() throws {
        let root = try Fixtures.temporaryDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, take, _) = try makePackage(in: root)
        let url = try store.mediaURL(for: take)
        try Data("not the take".utf8).write(to: url)
        #expect(throws: SongGraphError.self) { try store.readMedia(take) }
        do {
            _ = try store.readMedia(take)
        } catch let error as SongGraphError {
            guard case .hashMismatch(let expected, let actual, let path) = error else {
                Issue.record("expected hashMismatch, got \(error)")
                return
            }
            #expect(expected == take.hash)
            #expect(actual == ContentHash(of: Data("not the take".utf8)))
            #expect(path == url.path)
        }
        #expect(try store.readMedia(take, verifying: false) == Data("not the take".utf8))
    }

    @Test func mediaIsWrittenOncePerHash() throws {
        let root = try Fixtures.temporaryDirectory("once")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongStore(in: root, title: "Once")
        let first = try store.addMedia(Fixtures.mediaData(30), fileExtension: "wav")
        let attributes = try FileManager.default.attributesOfItem(atPath: try store.mediaURL(for: first).path)
        let second = try store.addMedia(Fixtures.mediaData(30), fileExtension: "wav")
        #expect(first == second)
        #expect(try store.storedMedia() == [first])
        let again = try FileManager.default.attributesOfItem(atPath: try store.mediaURL(for: first).path)
        #expect(attributes[.modificationDate] as? Date == again[.modificationDate] as? Date)

        let copied = try store.addMedia(copying: try store.mediaURL(for: first))
        #expect(copied == first)
    }

    @Test func missingDocumentAndNonPackagesAreTypedErrors() throws {
        let root = try Fixtures.temporaryDirectory("doc")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty.roboto")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = SongStore(packageURL: empty)
        #expect(!store.exists)
        #expect(throws: SongGraphError.missingDocument(path: store.documentURL.path)) { try store.load() }

        let file = root.appendingPathComponent("file.roboto")
        try Data().write(to: file)
        #expect(throws: SongGraphError.notAPackage(path: file.path)) { try SongStore(packageURL: file).load() }

        try Data("{ not json".utf8).write(to: store.documentURL)
        #expect(throws: SongGraphError.self) { try store.load() }
        do {
            _ = try store.load()
        } catch let error as SongGraphError {
            guard case .malformedDocument(let path, _) = error else {
                Issue.record("expected malformedDocument, got \(error)")
                return
            }
            #expect(path == store.documentURL.path)
        }
    }

    @Test func schema1PackageLoadsAndResavesAsSchema2() throws {
        let root = try Fixtures.temporaryDirectory("migrate")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongStore(in: root, title: "Old")
        try FileManager.default.createDirectory(at: store.packageURL, withIntermediateDirectories: true)
        try Data(schema1SongFixture.utf8).write(to: store.documentURL)
        let song = try store.load()
        #expect(song.schemaVersion == 2)
        #expect(song.versions[0].operation == "unknown")
        try store.save(song)
        let json = try SongGraphCodec.decode(JSONValue.self, from: try Data(contentsOf: store.documentURL))
        #expect(json["schemaVersion"]?.intValue == 2)
        #expect(try store.load() == song)
    }
}

@Suite struct LibraryStoreTests {
    @Test func twoSongsShareMediaStoredOnce() throws {
        let root = try Fixtures.temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directoryURL: root.appendingPathComponent("Library"))

        // A record and a sample cut from it live at the library level, once.
        let recordMedia = try store.addMedia(Fixtures.mediaData(40), fileExtension: "mp3", kind: .record)
        let sharedSample = try store.addMedia(Fixtures.mediaData(50), fileExtension: "wav", kind: .sample)
        let record = Record(title: "Arrival", artist: "Vessel", media: recordMedia)
        let sample = Sample(media: sharedSample, rootPitch: nil, detectedTempo: 93, sourceRecord: record.id)

        var first = Song(title: "First", artist: "Vessel")
        try first.append(PartVersion(partID: PartID(), kind: .sample(sample), author: .user, operation: Operation.chop))
        var second = Song(title: "Second", artist: "Vessel")
        try second.append(PartVersion(partID: PartID(), kind: .sample(sample), author: Fixtures.bassist, operation: Operation.chop))
        let album = Album(title: "Interior Season", artist: "Vessel", songs: [first.id, second.id])
        let idea = PartVersion(partID: PartID(), kind: .groove(Fixtures.groove), author: .user, operation: Operation.written)
        let library = Library(songs: [first, second], albums: [album], ideas: [idea], records: [record],
                              samples: [LibrarySample(name: "snare", sample: sample, tags: ["drums"])])
        try store.save(library)

        // Layout: library.json, two packages, records/ and samples/ with one file each.
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).sorted()
        #expect(entries == ["First.roboto", "Second.roboto", "ideas", "library.json", "records", "samples"])
        #expect(try store.storedMedia(kind: .record) == [recordMedia])
        #expect(try store.storedMedia(kind: .sample) == [sharedSample])
        // The shared sample is not duplicated into the packages.
        for songStore in try store.songStores() {
            #expect(try songStore.storedMedia().isEmpty)
            #expect(!songStore.hasMedia(sharedSample))
        }
        // …but it resolves for both songs through the library.
        #expect(try store.mediaURL(for: sharedSample, song: first.id) == store.samplesDirectoryURL.appendingPathComponent(sharedSample.fileName))
        #expect(try store.mediaURL(for: sharedSample, song: second.id) == store.samplesDirectoryURL.appendingPathComponent(sharedSample.fileName))
        #expect(store.missingMedia(in: library).isEmpty)
        try store.verifyMedia(for: library)

        let loaded = try store.load()
        #expect(loaded == library)
        #expect(loaded.songs.map(\.title) == ["First", "Second"])
        #expect(try store.songStore(for: second.id).packageURL.lastPathComponent == "Second.roboto")

        // Song-level media still wins for a song's own takes.
        let songStore = try store.songStore(for: first.id)
        let take = try songStore.addMedia(Fixtures.mediaData(60), fileExtension: "wav")
        #expect(try store.mediaURL(for: take, song: first.id) == songStore.mediaDirectoryURL.appendingPathComponent(take.fileName))
        let expected = SongGraphError.missingMedia(take, searched: [store.recordsDirectoryURL.path, store.samplesDirectoryURL.path,
                                                                    store.ideasDirectoryURL.path])
        #expect(throws: expected) { try store.mediaURL(for: take) }
    }

    @Test func songsKeepTheirPackageAcrossRenamesAndTitleChanges() throws {
        let root = try Fixtures.temporaryDirectory("library-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directoryURL: root)
        var library = Library(songs: [Song(title: "Draft")])
        try store.save(library)
        #expect(try store.songStore(for: library.songs[0].id).packageURL.lastPathComponent == "Draft.roboto")

        // The user renames the package on disk and retitles the song; a second song takes the original name.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Draft.roboto"), to: root.appendingPathComponent("Keeper.roboto"))
        library.songs[0].title = "Final"
        library.songs.append(Song(title: "Draft"))
        try store.save(library)
        let packages = try store.songStores().map { $0.packageURL.lastPathComponent }
        #expect(packages == ["Draft.roboto", "Keeper.roboto"])
        #expect(try store.songStore(for: library.songs[0].id).packageURL.lastPathComponent == "Keeper.roboto")
        #expect(try store.songStore(for: library.songs[1].id).packageURL.lastPathComponent == "Draft.roboto")
        let loaded = try store.load()
        #expect(loaded.songs.map(\.title) == ["Final", "Draft"])

        // A third song with a taken title gets a suffixed package.
        library.songs.append(Song(title: "Draft"))
        try store.save(library)
        let names = try store.songStores().map { $0.packageURL.lastPathComponent }
        #expect(names.count == 3)
        #expect(names.filter { $0.hasPrefix("Draft ") && $0.hasSuffix(".roboto") }.count == 1)
        #expect(try store.load().songs.map(\.id) == library.songs.map(\.id))
    }

    @Test func packagesTheDocumentDoesNotListAreStillLoaded() throws {
        let root = try Fixtures.temporaryDirectory("library-stray")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directoryURL: root)
        try store.save(Library(songs: [Song(title: "Listed")]))
        let stray = Song(title: "Dropped In")
        try SongStore(in: root, title: stray.title).save(stray)
        let loaded = try store.load()
        #expect(loaded.songs.map(\.title) == ["Listed", "Dropped In"])
        let unknown = SongID()
        #expect(throws: SongGraphError.missingSongPackage(unknown)) { _ = try store.songStore(for: unknown) }
    }

    @Test func missingLibraryDocumentIsATypedError() throws {
        let root = try Fixtures.temporaryDirectory("library-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directoryURL: root)
        #expect(!store.exists)
        #expect(throws: SongGraphError.missingDocument(path: store.documentURL.path)) { try store.load() }
    }
}
