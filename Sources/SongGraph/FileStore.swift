import CryptoKit
import Foundation

// MARK: - Hashing

extension ContentHash {
    /// The SHA-256 digest of `data`.
    public init(of data: Data) {
        let digest = SHA256.hash(data: data)
        let table = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(table[Int(byte >> 4)])
            bytes.append(table[Int(byte & 0x0f)])
        }
        self.init(validatedHex: String(decoding: bytes, as: UTF8.self))
    }
}

// MARK: - File coordination

/// Every read and write goes through NSFileCoordinator so the same packages can live in iCloud Drive later.
enum FileCoordination {
    private final class Box<T> {
        var result: Result<T, Error>?
    }

    static func read<T>(_ url: URL, options: NSFileCoordinator.ReadingOptions = [], _ body: (URL) throws -> T) throws -> T {
        let box = Box<T>()
        var coordinationError: NSError?
        withoutActuallyEscaping(body) { body in
            NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError) { accessURL in
                box.result = Result { try body(accessURL) }
            }
        }
        if let coordinationError {
            throw SongGraphError.fileCoordination(path: url.path, reason: coordinationError.localizedDescription)
        }
        guard let result = box.result else {
            throw SongGraphError.fileCoordination(path: url.path, reason: "accessor was not called")
        }
        return try result.get()
    }

    static func write<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> T) throws -> T {
        let box = Box<T>()
        var coordinationError: NSError?
        withoutActuallyEscaping(body) { body in
            NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { accessURL in
                box.result = Result { try body(accessURL) }
            }
        }
        if let coordinationError {
            throw SongGraphError.fileCoordination(path: url.path, reason: coordinationError.localizedDescription)
        }
        guard let result = box.result else {
            throw SongGraphError.fileCoordination(path: url.path, reason: "accessor was not called")
        }
        return try result.get()
    }
}

private enum Files {
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func subdirectories(of url: URL, withExtension ext: String) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == ext && isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func files(in url: URL) throws -> [URL] {
        guard isDirectory(url) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Writes `data` under `directory` as `<hash>.<ext>` unless that file already exists.
    static func storeMedia(_ data: Data, fileExtension: String, in directory: URL) throws -> MediaRef {
        let ref = MediaRef(hash: ContentHash(of: data), fileExtension: fileExtension)
        let target = directory.appendingPathComponent(ref.fileName)
        try ensureDirectory(directory)
        try FileCoordination.write(target, options: []) { url in
            if !exists(url) { try data.write(to: url, options: .atomic) }
        }
        return ref
    }

    static func mediaRefs(in directory: URL) throws -> [MediaRef] {
        try files(in: directory).compactMap { url in
            guard let hash = ContentHash(hex: url.deletingPathExtension().lastPathComponent) else { return nil }
            return MediaRef(hash: hash, fileExtension: url.pathExtension)
        }
    }

    static func readMedia(_ ref: MediaRef, at url: URL, verifying: Bool) throws -> Data {
        let data = try FileCoordination.read(url) { try Data(contentsOf: $0) }
        if verifying {
            let actual = ContentHash(of: data)
            guard actual == ref.hash else { throw SongGraphError.hashMismatch(expected: ref.hash, actual: actual, path: url.path) }
        }
        return data
    }

    /// A file-system-safe package name for a title.
    static func safeName(_ title: String) -> String {
        let cleaned = title
            .map { $0 == "/" || $0 == ":" || $0 == "\\" || $0.isNewline ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return stripped.isEmpty ? "Untitled" : stripped
    }
}

// MARK: - Song package

/// A song on disk: a `<Title>.roboto/` package holding `song.json` and `media/<hash>.<ext>`.
/// Nothing inside refers to an absolute path, so the package survives rename, move and sync.
public struct SongStore: Sendable {
    public static let packageExtension = "roboto"
    public static let documentName = "song.json"
    public static let mediaDirectoryName = "media"

    public let packageURL: URL

    /// A store for an existing or to-be-created package at `packageURL`.
    public init(packageURL: URL) {
        self.packageURL = packageURL.standardizedFileURL
    }

    /// A store for the package `<Title>.roboto` inside `directory`.
    public init(in directory: URL, title: String) {
        self.init(packageURL: directory.appendingPathComponent(SongStore.packageName(for: title)))
    }

    /// `<Title>.roboto`, with path separators replaced.
    public static func packageName(for title: String) -> String {
        "\(Files.safeName(title)).\(packageExtension)"
    }

    public var documentURL: URL { packageURL.appendingPathComponent(SongStore.documentName) }
    public var mediaDirectoryURL: URL { packageURL.appendingPathComponent(SongStore.mediaDirectoryName) }

    /// True when the package directory holds a `song.json`.
    public var exists: Bool { Files.isDirectory(packageURL) && Files.exists(documentURL) }

    /// Reads and, if needed, migrates the song. Media is not checked; see `verifyMedia(for:)`.
    public func load() throws -> Song {
        try FileCoordination.read(packageURL) { url in
            guard Files.isDirectory(url) else { throw SongGraphError.notAPackage(path: url.path) }
            let document = url.appendingPathComponent(SongStore.documentName)
            guard Files.exists(document) else { throw SongGraphError.missingDocument(path: document.path) }
            let data = try Data(contentsOf: document)
            do {
                return try SongGraphCodec.decodeSong(from: data)
            } catch let error as SongGraphError {
                throw error
            } catch {
                throw SongGraphError.malformedDocument(path: document.path, reason: "\(error)")
            }
        }
    }

    /// Writes `song.json` (atomically), creating the package and its media directory if needed.
    public func save(_ song: Song) throws {
        let data = try SongGraphCodec.encodeSong(song)
        let options: NSFileCoordinator.WritingOptions = Files.exists(packageURL) ? [.forMerging] : []
        try FileCoordination.write(packageURL, options: options) { url in
            try Files.ensureDirectory(url.appendingPathComponent(SongStore.mediaDirectoryName))
            try data.write(to: url.appendingPathComponent(SongStore.documentName), options: .atomic)
        }
    }

    /// Stores media by content hash; a hash already present is not written again.
    @discardableResult
    public func addMedia(_ data: Data, fileExtension: String) throws -> MediaRef {
        try Files.storeMedia(data, fileExtension: fileExtension, in: mediaDirectoryURL)
    }

    /// Copies a file into the package, keeping its extension.
    @discardableResult
    public func addMedia(copying fileURL: URL) throws -> MediaRef {
        let data = try FileCoordination.read(fileURL) { try Data(contentsOf: $0) }
        return try addMedia(data, fileExtension: fileURL.pathExtension)
    }

    public func hasMedia(_ ref: MediaRef) -> Bool { Files.exists(mediaDirectoryURL.appendingPathComponent(ref.fileName)) }

    /// The file for a media reference; throws `missingMedia` when it is not in the package.
    public func mediaURL(for ref: MediaRef) throws -> URL {
        let url = mediaDirectoryURL.appendingPathComponent(ref.fileName)
        guard Files.exists(url) else { throw SongGraphError.missingMedia(ref, searched: [mediaDirectoryURL.path]) }
        return url
    }

    /// Reads media, checking that the bytes still hash to their name unless `verifying` is false.
    public func readMedia(_ ref: MediaRef, verifying: Bool = true) throws -> Data {
        try Files.readMedia(ref, at: try mediaURL(for: ref), verifying: verifying)
    }

    /// Media the song references that the package does not hold.
    public func missingMedia(in song: Song) -> [MediaRef] { song.mediaReferences.filter { !hasMedia($0) } }

    /// Throws `missingMedia` for the first reference the package does not hold.
    public func verifyMedia(for song: Song) throws {
        if let missing = missingMedia(in: song).first {
            throw SongGraphError.missingMedia(missing, searched: [mediaDirectoryURL.path])
        }
    }

    /// Every media file in the package, by name.
    public func storedMedia() throws -> [MediaRef] {
        try FileCoordination.read(mediaDirectoryURL) { try Files.mediaRefs(in: $0) }
    }
}

// MARK: - Library directory

/// A library on disk: a directory holding `library.json`, one `.roboto` package per song, and `records/`,
/// `samples/` and `ideas/` media by hash. Media shared by songs is stored once, at the library level.
public struct LibraryStore: Sendable {
    public static let documentName = "library.json"
    public static let recordsDirectoryName = "records"
    public static let samplesDirectoryName = "samples"
    public static let ideasDirectoryName = "ideas"

    /// Where library-level media lives.
    public enum MediaKind: String, Sendable, CaseIterable {
        case record, sample, idea

        var directoryName: String {
            switch self {
            case .record: return LibraryStore.recordsDirectoryName
            case .sample: return LibraryStore.samplesDirectoryName
            case .idea: return LibraryStore.ideasDirectoryName
            }
        }
    }

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public var documentURL: URL { directoryURL.appendingPathComponent(LibraryStore.documentName) }
    public var recordsDirectoryURL: URL { directoryURL.appendingPathComponent(LibraryStore.recordsDirectoryName) }
    public var samplesDirectoryURL: URL { directoryURL.appendingPathComponent(LibraryStore.samplesDirectoryName) }
    public var ideasDirectoryURL: URL { directoryURL.appendingPathComponent(LibraryStore.ideasDirectoryName) }

    public func mediaDirectoryURL(for kind: MediaKind) -> URL { directoryURL.appendingPathComponent(kind.directoryName) }

    /// True when the directory holds a `library.json`.
    public var exists: Bool { Files.exists(documentURL) }

    /// What `library.json` holds: songs are listed by package, everything else inline.
    struct Document: Codable {
        struct SongEntry: Codable {
            var id: SongID
            var title: String
            var package: String
        }

        var schemaVersion: Int
        var songs: [SongEntry]
        var albums: [Album]
        var ideas: [PartVersion]
        var records: [Record]
        var samples: [LibrarySample]
    }

    /// Just enough of `song.json` to identify a package without a full decode.
    private struct SongHeader: Decodable {
        var id: SongID
        var title: String
    }

    /// Reads `library.json` and every `.roboto` package in the directory. Packages the document does not list
    /// are appended; listed packages that are gone are dropped.
    public func load() throws -> Library {
        let document: Document = try FileCoordination.read(documentURL) { url in
            guard Files.exists(url) else { throw SongGraphError.missingDocument(path: url.path) }
            do {
                return try SongGraphCodec.decode(Document.self, from: try Data(contentsOf: url), migrating: .library)
            } catch let error as SongGraphError {
                throw error
            } catch {
                throw SongGraphError.malformedDocument(path: url.path, reason: "\(error)")
            }
        }
        var songs: [Song] = []
        var seen = Set<SongID>()
        var byPackage: [String: SongStore] = [:]
        for store in try songStores() { byPackage[store.packageURL.lastPathComponent] = store }
        for entry in document.songs {
            guard let store = byPackage[entry.package] else { continue }
            let song = try store.load()
            if seen.insert(song.id).inserted { songs.append(song) }
        }
        for store in try songStores() where byPackage[store.packageURL.lastPathComponent] != nil {
            let song = try store.load()
            if seen.insert(song.id).inserted { songs.append(song) }
        }
        var library = Library(songs: songs, albums: document.albums, ideas: document.ideas,
                              records: document.records, samples: document.samples)
        library.songs = songs
        return library
    }

    /// Writes every song into its package and `library.json` alongside. A song keeps the package it already has,
    /// even after a rename; a new song gets `<Title>.roboto`, suffixed if that name is taken.
    public func save(_ library: Library) throws {
        try FileCoordination.write(directoryURL, options: Files.exists(directoryURL) ? [.forMerging] : []) { url in
            try Files.ensureDirectory(url)
            try Files.ensureDirectory(url.appendingPathComponent(LibraryStore.recordsDirectoryName))
            try Files.ensureDirectory(url.appendingPathComponent(LibraryStore.samplesDirectoryName))
            try Files.ensureDirectory(url.appendingPathComponent(LibraryStore.ideasDirectoryName))
        }
        var existing: [SongID: SongStore] = [:]
        for store in try songStores() {
            if let header = try? headerOf(store) { existing[header.id] = store }
        }
        var taken = Set(existing.values.map { $0.packageURL.lastPathComponent })
        var entries: [Document.SongEntry] = []
        for song in library.songs {
            let store: SongStore
            if let found = existing[song.id] {
                store = found
            } else {
                var name = SongStore.packageName(for: song.title)
                if taken.contains(name) {
                    name = SongStore.packageName(for: "\(Files.safeName(song.title)) \(String(song.id.rawValue.uuidString.prefix(8)))")
                }
                store = SongStore(packageURL: directoryURL.appendingPathComponent(name))
            }
            taken.insert(store.packageURL.lastPathComponent)
            try store.save(song)
            entries.append(.init(id: song.id, title: song.title, package: store.packageURL.lastPathComponent))
        }
        let document = Document(schemaVersion: SongGraphSchema.current, songs: entries, albums: library.albums,
                                ideas: library.ideas, records: library.records, samples: library.samples)
        let data = try SongGraphCodec.encode(document)
        try FileCoordination.write(documentURL, options: [.forReplacing]) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// Writes `library.json` only — albums, ideas, records and samples — listing the song packages
    /// already on disk. For a library-level change (an idea kept, a sample saved, an album made)
    /// nothing in any song moved, and rewriting every package to record it would touch a song you
    /// have open with the copy the library last saw.
    public func saveDocument(_ library: Library) throws {
        try FileCoordination.write(directoryURL, options: Files.exists(directoryURL) ? [.forMerging] : []) { url in
            try Files.ensureDirectory(url)
            for kind in MediaKind.allCases { try Files.ensureDirectory(url.appendingPathComponent(kind.directoryName)) }
        }
        var entries: [Document.SongEntry] = []
        for store in try songStores() {
            guard let header = try? headerOf(store) else { continue }
            entries.append(.init(id: header.id, title: header.title, package: store.packageURL.lastPathComponent))
        }
        let document = Document(schemaVersion: SongGraphSchema.current, songs: entries, albums: library.albums,
                                ideas: library.ideas, records: library.records, samples: library.samples)
        let data = try SongGraphCodec.encode(document)
        try FileCoordination.write(documentURL, options: [.forReplacing]) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    private func headerOf(_ store: SongStore) throws -> SongHeader {
        try FileCoordination.read(store.documentURL) { url in
            try SongGraphCodec.decode(SongHeader.self, from: try Data(contentsOf: url))
        }
    }

    /// Every `.roboto` package in the directory, by name.
    public func songStores() throws -> [SongStore] {
        guard Files.isDirectory(directoryURL) else { return [] }
        return try FileCoordination.read(directoryURL) { url in
            try Files.subdirectories(of: url, withExtension: SongStore.packageExtension).map { SongStore(packageURL: $0) }
        }
    }

    /// The package holding a song, found by the id inside `song.json`.
    public func songStore(for id: SongID) throws -> SongStore {
        for store in try songStores() {
            if let header = try? headerOf(store), header.id == id { return store }
        }
        throw SongGraphError.missingSongPackage(id)
    }

    /// Stores media at the library level by content hash; a hash already present is not written again.
    @discardableResult
    public func addMedia(_ data: Data, fileExtension: String, kind: MediaKind) throws -> MediaRef {
        try Files.storeMedia(data, fileExtension: fileExtension, in: mediaDirectoryURL(for: kind))
    }

    /// Copies a file into the library, keeping its extension.
    @discardableResult
    public func addMedia(copying fileURL: URL, kind: MediaKind) throws -> MediaRef {
        let data = try FileCoordination.read(fileURL) { try Data(contentsOf: $0) }
        return try addMedia(data, fileExtension: fileURL.pathExtension, kind: kind)
    }

    /// The directories a reference is looked up in: the song's package first, then records, then samples.
    private func searchDirectories(song: SongID?) -> [URL] {
        var directories: [URL] = []
        if let song, let store = try? songStore(for: song) { directories.append(store.mediaDirectoryURL) }
        directories.append(recordsDirectoryURL)
        directories.append(samplesDirectoryURL)
        directories.append(ideasDirectoryURL)
        return directories
    }

    /// The file for a media reference, looking in the song's package (when given) then `records/`, `samples/`
    /// and `ideas/`.
    public func mediaURL(for ref: MediaRef, song: SongID? = nil) throws -> URL {
        let directories = searchDirectories(song: song)
        for directory in directories {
            let url = directory.appendingPathComponent(ref.fileName)
            if Files.exists(url) { return url }
        }
        throw SongGraphError.missingMedia(ref, searched: directories.map(\.path))
    }

    public func hasMedia(_ ref: MediaRef, song: SongID? = nil) -> Bool { (try? mediaURL(for: ref, song: song)) != nil }

    /// Reads media, checking that the bytes still hash to their name unless `verifying` is false.
    public func readMedia(_ ref: MediaRef, song: SongID? = nil, verifying: Bool = true) throws -> Data {
        try Files.readMedia(ref, at: try mediaURL(for: ref, song: song), verifying: verifying)
    }

    /// Every media reference in the library and its songs that no searched directory holds.
    public func missingMedia(in library: Library) -> [MediaRef] {
        var missing: [MediaRef] = []
        var seen = Set<MediaRef>()
        for ref in library.mediaReferences where !hasMedia(ref) && seen.insert(ref).inserted { missing.append(ref) }
        for song in library.songs {
            for ref in song.mediaReferences where !hasMedia(ref, song: song.id) && seen.insert(ref).inserted { missing.append(ref) }
        }
        return missing
    }

    /// Throws `missingMedia` for the first reference nothing holds.
    public func verifyMedia(for library: Library) throws {
        if let missing = missingMedia(in: library).first {
            throw SongGraphError.missingMedia(missing, searched: [recordsDirectoryURL.path, samplesDirectoryURL.path])
        }
    }

    /// Every media file stored at the library level.
    public func storedMedia(kind: MediaKind) throws -> [MediaRef] {
        try FileCoordination.read(mediaDirectoryURL(for: kind)) { try Files.mediaRefs(in: $0) }
    }
}
