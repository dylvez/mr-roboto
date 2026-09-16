import Foundation

/// Every error loading, saving or importing a kit. Plain data: paths are strings, so an error can be
/// logged, compared in a test, or shown to a person without carrying a URL around.
public enum KitError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No `kit.json` in the folder.
    case missingManifest(path: String)
    case malformedManifest(path: String, reason: String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case migrationFailed(from: Int, to: Int, reason: String)
    /// A zone names a sample the kit folder does not contain. **Named on purpose**: the
    /// `AVAudioUnitSampler` path this replaces loaded a kit with a missing file and then played
    /// silence with no diagnostic, which cost real debugging time. A kit with a missing sample
    /// fails loudly here.
    case missingSample(zone: ZoneID, path: String, folder: String)
    /// A manifest holds an absolute sample path, which would break as soon as the folder moved.
    case absoluteSamplePath(zone: ZoneID, path: String)
    case notADirectory(path: String)
    case writeFailed(path: String, reason: String)
    /// The `.sfz` file could not be read.
    case sfzUnreadable(path: String, reason: String)
    /// An audio file asked for by absolute path is not there (the kit-less `SampleCache` path).
    case sampleFileMissing(path: String)
    /// The audio file exists but could not be decoded.
    case decodeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .missingManifest(let path):
            return "No \(KitManifest.fileName) in \(path)."
        case .malformedManifest(let path, let reason):
            return "Could not read \(path.isEmpty ? KitManifest.fileName : path): \(reason)"
        case .unsupportedFormatVersion(let found, let supported):
            return "Kit format \(found) is newer than the supported format \(supported)."
        case .migrationFailed(let from, let to, let reason):
            return "Migrating kit format \(from) to \(to) failed: \(reason)"
        case .missingSample(let zone, let path, let folder):
            return "Zone \(zone) references \"\(path)\", which is not in the kit folder \(folder)."
        case .absoluteSamplePath(let zone, let path):
            return "Zone \(zone) uses the absolute path \"\(path)\"; kit samples must be relative to the kit folder."
        case .notADirectory(let path):
            return "\(path) is not a kit folder."
        case .writeFailed(let path, let reason):
            return "Could not write \(path): \(reason)"
        case .sfzUnreadable(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .sampleFileMissing(let path):
            return "No audio file at \(path)."
        case .decodeFailed(let path, let reason):
            return "Could not decode \(path): \(reason)"
        }
    }
}

/// Relative-path handling for kits. Paths in a manifest are always `/`-separated and relative to
/// the folder holding `kit.json`; Windows separators from an SFZ pack are normalised on import.
public enum KitPath {
    /// True for paths that would not survive moving the kit folder: POSIX absolute, a Windows drive
    /// letter, a UNC path, or a `~` home reference.
    public static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("\\\\") { return true }
        if path.count >= 2 {
            let chars = Array(path)
            if chars[0].isLetter && chars[1] == ":" { return true }
        }
        return false
    }

    /// `path` with Windows separators turned into `/` and any leading `./` removed.
    public static func normalized(_ path: String) -> String {
        var cleaned = path.replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
        return cleaned
    }

    /// Resolves a manifest-relative path against the kit folder.
    public static func resolve(_ path: String, in folder: URL) -> URL {
        var url = folder
        for component in normalized(path).split(separator: "/") where component != "." {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }
}

/// A kit folder that has been loaded: the manifest plus the folder its relative paths resolve
/// against. Sample URLs are computed, never stored in the manifest, so the value stays movable.
public struct LoadedKit: Hashable, Sendable {
    public var manifest: KitManifest
    /// The folder holding `kit.json`.
    public var folder: URL

    public init(manifest: KitManifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
    }

    /// Identity used by `SampleCache` for eviction: the standardized folder path.
    public var id: KitID { KitID(folder.standardizedFileURL.path) }

    public func url(for zone: Zone) -> URL { KitPath.resolve(zone.sample, in: folder) }

    /// Absolute URLs for every distinct sample the kit references, in first-use order.
    public var sampleURLs: [URL] { manifest.samplePaths.map { KitPath.resolve($0, in: folder) } }

    public func validate() -> KitValidation { manifest.validate(resolvingSamplesAgainst: folder) }
}

/// Identifies a loaded kit for cache ownership.
public struct KitID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Reads and writes kit folders.
public enum KitStore {
    /// Loads the kit in `folder`: decodes `kit.json` (migrating older format versions), rejects
    /// absolute sample paths, and checks that every referenced file exists.
    ///
    /// - Parameter checkingSamples: pass false to load a manifest whose audio is not present yet
    ///   (a kit being assembled). The default is true and is what playback paths must use: a
    ///   missing sample throws `KitError.missingSample` naming the zone and the file, instead of
    ///   loading a kit that plays silence.
    public static func load(from folder: URL, checkingSamples: Bool = true) throws -> LoadedKit {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KitError.notADirectory(path: folder.path)
        }
        let manifestURL = folder.appendingPathComponent(KitManifest.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw KitError.missingManifest(path: folder.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw KitError.malformedManifest(path: manifestURL.path, reason: "\(error)")
        }
        let manifest = try KitMigrator.current.decode(data, path: manifestURL.path)
        let kit = LoadedKit(manifest: manifest, folder: folder)
        for zone in manifest.zones {
            if KitPath.isAbsolute(zone.sample) {
                throw KitError.absoluteSamplePath(zone: zone.id, path: zone.sample)
            }
            guard checkingSamples else { continue }
            let url = KitPath.resolve(zone.sample, in: folder)
            if !FileManager.default.fileExists(atPath: url.path) {
                throw KitError.missingSample(zone: zone.id, path: zone.sample, folder: folder.path)
            }
        }
        return kit
    }

    /// Writes `manifest` to `folder/kit.json`, creating the folder if needed. Sample files are not
    /// touched: a kit folder's audio is put there by whoever produced it (an import, a recording,
    /// a copy), and saving only ever rewrites the manifest.
    @discardableResult
    public static func save(_ manifest: KitManifest, to folder: URL) throws -> LoadedKit {
        for zone in manifest.zones where KitPath.isAbsolute(zone.sample) {
            throw KitError.absoluteSamplePath(zone: zone.id, path: zone.sample)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw KitError.writeFailed(path: folder.path, reason: "\(error)")
        }
        var stamped = manifest
        stamped.formatVersion = KitManifest.currentFormatVersion
        let url = folder.appendingPathComponent(KitManifest.fileName)
        do {
            try KitCodec.encode(stamped).write(to: url, options: .atomic)
        } catch {
            throw KitError.writeFailed(path: url.path, reason: "\(error)")
        }
        return LoadedKit(manifest: stamped, folder: folder)
    }
}
