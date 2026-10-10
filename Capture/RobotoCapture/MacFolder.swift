import Foundation
import Observation

/// The Mr. Roboto folder on the Mac, reached through iCloud Drive: chosen once in the Files
/// picker and kept as a bookmark. `Inbox/` is where a capture goes — the Mac takes what lands
/// there on its own — and `Guides/` is what the Mac rendered for the phone: each section of a
/// song with a count-in of click in front, and `guides.json` saying which.
@MainActor
@Observable
final class MacFolder {
    private(set) var url: URL?
    /// True when the folder is in iCloud Drive, so what goes in it reaches the Mac. A folder under
    /// On My iPhone is the phone's alone, and the Mac never sees it.
    private(set) var isInCloud = false
    private(set) var manifest: Manifest?
    private(set) var problem: String?
    /// True while the manifest is on its way down from iCloud.
    private(set) var loading = false

    static let bookmarkKey = "macFolder.bookmark"
    static let manifestName = "guides.json"

    // The Mac writes these (`PhoneGuides` there); the phone keeps the same shape.
    struct Manifest: Codable, Equatable {
        var version: Int
        var writtenAt: String
        var songs: [SongEntry]
    }

    struct SongEntry: Codable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var tempo: Double
        var beatsPerBar: Int
        var beatUnit: Int
        var sections: [SectionEntry]
    }

    struct SectionEntry: Codable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var bars: Int
        /// The guide's path under `Guides/`.
        var file: String
        var countInBars: Int
        /// Seconds of click before the section's first beat.
        var countInSeconds: Double
        var seconds: Double
    }

    init() { restore() }

    var name: String? { url?.lastPathComponent }

    /// Where a capture goes. The folder to choose is Mr. Roboto itself; its Inbox, when that is
    /// what was chosen, is taken as it is, with no guides to read beside it.
    var inbox: URL? {
        guard let url else { return nil }
        return url.lastPathComponent == "Inbox" ? url : url.appendingPathComponent("Inbox", isDirectory: true)
    }

    var guides: URL? {
        guard let url, url.lastPathComponent != "Inbox" else { return nil }
        return url.appendingPathComponent("Guides", isDirectory: true)
    }

    /// True for the Mr. Roboto folder itself, or its Inbox: named so, or holding an Inbox or a
    /// Guides folder. A folder inside it — a song's guides, say — is not, and a capture put there
    /// is one the Mac never looks for.
    nonisolated static func looksLikeTheMacFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "Mr. Roboto" || name == "Inbox" { return true }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return children.contains("Inbox") || children.contains("Guides")
    }

    func choose(_ picked: URL) {
        forget()
        guard picked.startAccessingSecurityScopedResource() else {
            problem = "That folder could not be opened."
            return
        }
        guard Self.looksLikeTheMacFolder(picked) else {
            picked.stopAccessingSecurityScopedResource()
            problem = "\(picked.lastPathComponent) is not the Mr. Roboto folder. Choose the folder named Mr. Roboto at the top of iCloud Drive, not one inside it."
            return
        }
        do {
            let bookmark = try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            url = picked
            isInCloud = FileManager.default.isUbiquitousItem(at: picked)
            reload()
        } catch {
            picked.stopAccessingSecurityScopedResource()
            problem = "That folder could not be kept: \(error.localizedDescription)"
        }
    }

    func forget() {
        url?.stopAccessingSecurityScopedResource()
        url = nil
        isInCloud = false
        manifest = nil
        problem = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              resolved.startAccessingSecurityScopedResource() else {
            problem = "The Mac folder could not be reached. Choose it again."
            return
        }
        url = resolved
        isInCloud = FileManager.default.isUbiquitousItem(at: resolved)
        if stale, let fresh = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        reload()
    }

    /// Reads `Guides/guides.json`. A coordinated read: iCloud brings the file down first when it
    /// is not on the phone yet, so this waits off the main actor.
    func reload() {
        guard let guides else { manifest = nil; return }
        let file = guides.appendingPathComponent(Self.manifestName)
        loading = true
        Task {
            defer { loading = false }
            do {
                let data = try await Self.read(file)
                manifest = try JSONDecoder().decode(Manifest.self, from: data)
                problem = nil
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // No guides yet: nothing to sing to, and nothing wrong.
                manifest = nil
                problem = nil
            } catch {
                manifest = nil
                problem = "The guides could not be read: \(error.localizedDescription)"
            }
        }
    }

    /// The guide's audio, whole: on the phone already, or brought down from iCloud first.
    func guideData(for section: SectionEntry) async throws -> Data {
        guard let guides else { throw CocoaError(.fileNoSuchFile) }
        return try await Self.read(guides.appendingPathComponent(section.file))
    }

    /// Where a capture of this name has got to, read off the folder: still going up to iCloud,
    /// in iCloud waiting for the Mac, or taken by the Mac — which moves what it takes into
    /// `Inbox/Done`, and iCloud brings that move back to the phone.
    enum Delivery: Equatable {
        case waiting, uploading, inCloud, taken, missing
    }

    func delivery(of name: String) -> Delivery {
        guard let inbox else { return .missing }
        if FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Done").appendingPathComponent(name).path) {
            return .taken
        }
        let file = inbox.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard isInCloud,
              let values = try? file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]) else {
            return .inCloud
        }
        if values.ubiquitousItemIsUploaded == true { return .inCloud }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        return .waiting
    }

    /// The capture copied into the Inbox, where the Mac takes it by its name.
    func send(_ capture: URL) async throws {
        guard let inbox else { throw CocoaError(.fileNoSuchFile) }
        try await Self.copy(capture, into: inbox)
    }

    nonisolated static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var coordinatorError: NSError?
            var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actual in
                result = Result { try Data(contentsOf: actual) }
            }
            if let coordinatorError { throw coordinatorError }
            return try result.get()
        }.value
    }

    nonisolated static func copy(_ source: URL, into folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { actual in
                do {
                    if FileManager.default.fileExists(atPath: actual.path) { try FileManager.default.removeItem(at: actual) }
                    try FileManager.default.copyItem(at: source, to: actual)
                } catch { copyError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let copyError { throw copyError }
        }.value
    }
}
