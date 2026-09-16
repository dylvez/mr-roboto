/// SongGraph — the versioned song graph: parts, versions with provenance, sections, songs, albums, a library,
/// and the `.roboto` package format. See the M0 spec, tasks 1.2 and 1.3.
public enum SongGraphModule {
    public static let version = "0.1.0"
    /// The document schema this build reads and writes; see `SongGraphSchema`.
    public static var schemaVersion: Int { SongGraphSchema.current }
}
