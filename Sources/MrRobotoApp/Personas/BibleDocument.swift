import Foundation

/// Bibles on disk.
///
/// A bible is a value, and a value can be a file: `Resources/Bibles/<id>.json` for the ones the
/// app ships, `<library>/bibles/<id>.json` for ones written for a project. The encoding is fixed
/// — sorted keys, pretty-printed, no escaping of slashes — so a bible exported today and the same
/// bible exported tomorrow are the same bytes, and a diff of two bibles is a diff of what they say.
public enum BibleDocument {
    public static let directoryName = "Bibles"
    public static let fileExtension = "json"

    public static func encode(_ bible: PersonaBible) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bible)
    }

    public static func decode(_ data: Data) throws -> PersonaBible {
        try JSONDecoder().decode(PersonaBible.self, from: data)
    }

    /// Reads a bible and holds it to the method. Throws on a malformed file; a bible that reads
    /// but does not hold comes back with its violations, so the caller can say which.
    public static func load(_ url: URL, cast: [PersonaID] = PersonaID.roster) throws -> (bible: PersonaBible, violations: [BibleMethod.Violation]) {
        let bible = try decode(try Data(contentsOf: url))
        return (bible, BibleMethod.lint(bible, cast: cast))
    }

    /// The bibles the app ships, as files in its bundle. Empty until the export has been run
    /// (`MRROBOTO_EXPORT_BIBLES=1 swift test --filter BibleExport`), which is why the shipped
    /// personas keep their Swift values as the source of truth for now.
    public static func bundled() -> [PersonaBible] {
        guard let bundle = FontRegistration.resourceBundle,
              let urls = bundle.urls(forResourcesWithExtension: fileExtension, subdirectory: "Resources/\(directoryName)") else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            try? decode(try Data(contentsOf: url))
        }
    }
}
