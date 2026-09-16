/// Every error the song graph and its stores throw. Paths are strings so the error stays plain data.
public enum SongGraphError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A version with this id is already in the graph; versions are append-only and immutable.
    case duplicateVersion(VersionID)
    /// A section, experiment or parent refers to a version the graph does not hold.
    case unknownVersion(VersionID)
    case unknownSection(SectionID)
    case unknownExperiment(ExperimentID)
    /// `song.json` / `library.json` is not where it should be.
    case missingDocument(path: String)
    /// The document exists but could not be decoded.
    case malformedDocument(path: String, reason: String)
    /// The document was written by a newer build.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case migrationFailed(from: Int, to: Int, reason: String)
    /// A referenced media file is not in any of the searched locations.
    case missingMedia(MediaRef, searched: [String])
    /// A media file's bytes do not hash to the name it is stored under.
    case hashMismatch(expected: ContentHash, actual: ContentHash, path: String)
    /// The URL is not a `.roboto` package or a library directory.
    case notAPackage(path: String)
    /// NSFileCoordinator refused the access.
    case fileCoordination(path: String, reason: String)
    /// The library directory holds no package for this song.
    case missingSongPackage(SongID)

    public var description: String {
        switch self {
        case .duplicateVersion(let id):
            return "Version \(id) is already in the graph; versions are immutable and append-only."
        case .unknownVersion(let id):
            return "Version \(id) is not in the graph."
        case .unknownSection(let id):
            return "Section \(id) is not in the song."
        case .unknownExperiment(let id):
            return "Experiment \(id) is not in the song."
        case .missingDocument(let path):
            return "No document at \(path)."
        case .malformedDocument(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "Document schema \(found) is newer than the supported schema \(supported)."
        case .migrationFailed(let from, let to, let reason):
            return "Migrating schema \(from) to \(to) failed: \(reason)"
        case .missingMedia(let ref, let searched):
            return "Media \(ref.fileName) is missing; searched \(searched.joined(separator: ", "))."
        case .hashMismatch(let expected, let actual, let path):
            return "Media at \(path) hashes to \(actual.short)…, expected \(expected.short)…."
        case .notAPackage(let path):
            return "\(path) is not a song package or library."
        case .fileCoordination(let path, let reason):
            return "File coordination failed for \(path): \(reason)"
        case .missingSongPackage(let id):
            return "The library holds no package for song \(id)."
        }
    }
}
