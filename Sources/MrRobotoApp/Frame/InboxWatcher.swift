import Foundation

// M5 R11: the inbox. A folder the Mac watches — in iCloud Drive when there is one — and a second
// look at ~/Downloads for what AirDrop leaves there. Anything audio that lands becomes an idea in
// the library, or a take on a song when its name says which.
//
// Polling, not FSEvents: iCloud materialises files late and in pieces, and a file is only ready
// when its size has stopped moving. Two scans at the same size is the test.

/// Watches one or more folders for captures.
@MainActor
public final class InboxWatcher {

    public struct Folder: Sendable, Hashable {
        public var url: URL
        /// Only files whose name starts with this are taken; nil takes every audio file.
        public var prefix: String?
        public init(url: URL, prefix: String? = nil) {
            self.url = url
            self.prefix = prefix
        }
    }

    public nonisolated static let audioExtensions: Set<String> = ["wav", "m4a", "caf", "aif", "aiff", "mp3", "flac"]
    /// What Roboto Capture names its files, so the Downloads folder is not read whole.
    public nonisolated static let capturePrefix = "roboto-capture"

    public let folders: [Folder]
    public private(set) var isWatching = false
    /// Files seen once and their size then; taken when seen again at the same size.
    private var pending: [URL: Int] = [:]
    private let interval: Duration
    private let take: @MainActor (URL) -> Bool
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - folders: what to watch.
    ///   - interval: how often to look.
    ///   - take: what to do with a ready file; true when it was taken and can be moved to `Done/`.
    public init(folders: [Folder], interval: Duration = .seconds(3), take: @escaping @MainActor (URL) -> Bool) {
        self.folders = folders
        self.interval = interval
        self.take = take
    }

    /// The Mr. Roboto folder: in iCloud Drive when the Mac has one, else in ~/Music. The inbox is
    /// in it, and so are the guides (`PhoneGuides`): it is the one folder the phone is pointed at.
    public nonisolated static var robotoFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: cloud.path) ? cloud : home.appendingPathComponent("Music", isDirectory: true)
        return base.appendingPathComponent("Mr. Roboto", isDirectory: true)
    }

    /// `Mr. Roboto/Inbox`: what lands here is taken.
    public nonisolated static var inboxFolder: URL { robotoFolder.appendingPathComponent("Inbox", isDirectory: true) }
    /// `Mr. Roboto/Guides`: what the Mac rendered for the phone to sing to.
    public nonisolated static var guidesFolder: URL { robotoFolder.appendingPathComponent("Guides", isDirectory: true) }

    /// The inbox in iCloud Drive when the Mac has one, else in ~/Music; and ~/Downloads for
    /// captures AirDropped from the phone.
    public static var defaultFolders: [Folder] {
        let inbox = inboxFolder
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [Folder(url: inbox), Folder(url: home.appendingPathComponent("Downloads", isDirectory: true), prefix: capturePrefix)]
    }

    public func start() {
        guard !isWatching else { return }
        isWatching = true
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: self?.interval ?? .seconds(3))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        isWatching = false
    }

    /// One look at every folder. Called by the loop, and by a test.
    public func scan() {
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
            for url in files where Self.isCandidate(url, prefix: folder.prefix) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0 else { continue }
                if pending[url] == size {
                    pending[url] = nil
                    if take(url) { Self.moveToDone(url) }
                } else {
                    pending[url] = size
                }
            }
        }
    }

    nonisolated static func isCandidate(_ url: URL, prefix: String?) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), audioExtensions.contains(url.pathExtension.lowercased()) else { return false }
        if let prefix { return name.lowercased().hasPrefix(prefix) }
        return true
    }

    nonisolated static func moveToDone(_ url: URL) {
        let done = url.deletingLastPathComponent().appendingPathComponent("Done", isDirectory: true)
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        var target = done.appendingPathComponent(url.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = done.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(n).\(url.pathExtension)")
            n += 1
        }
        try? FileManager.default.moveItem(at: url, to: target)
    }
}

/// What a capture's file name says: `roboto-capture--<song>--<section>--<pass>--<stamp>.m4a`,
/// and `--<lead>` after the stamp when the phone played a guide while it recorded.
/// Every field but the stamp is optional; a plain file name says nothing and becomes an idea.
public struct CaptureName: Hashable, Sendable {
    public var song: String?
    public var section: String?
    public var pass: Int?
    public var stamp: String?
    /// Seconds at the head of the file before the section's first beat: the guide's count-in,
    /// plus the latency the phone measured. The inbox trims them off (`AppState.trimmed`).
    public var lead: Double?

    public init(song: String? = nil, section: String? = nil, pass: Int? = nil, stamp: String? = nil, lead: Double? = nil) {
        self.song = song
        self.section = section
        self.pass = pass
        self.stamp = stamp
        self.lead = lead
    }

    public init(fileName: String) {
        let base = (fileName as NSString).deletingPathExtension
        guard base.lowercased().hasPrefix(InboxWatcher.capturePrefix) else { return }
        let fields = base.components(separatedBy: "--").dropFirst().map { $0.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }
        if fields.count > 0, !fields[0].isEmpty { song = fields[0] }
        if fields.count > 1, !fields[1].isEmpty { section = fields[1] }
        if fields.count > 2, let n = Int(fields[2]) { pass = n }
        if fields.count > 3 { stamp = fields[3] }
        if fields.count > 4, let seconds = Double(fields[4]), seconds > 0 { lead = seconds }
    }

    /// The file name for a capture, as the phone writes it.
    public func fileName(extension ext: String = "m4a") -> String {
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "--", with: "-").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        }
        let head = "\(InboxWatcher.capturePrefix)--\(clean(song))--\(clean(section))--\(pass.map(String.init) ?? "")--\(stamp ?? "")"
        let tail = lead.map { String(format: "--%.3f", $0) } ?? ""
        return "\(head)\(tail).\(ext)"
    }
}
