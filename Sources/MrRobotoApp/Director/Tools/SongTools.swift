import Foundation
import MusicTheory
import Performance
import SongGraph

// Reading the song graph, and writing one immutable version back into it.

// MARK: - read_song

/// What is open, and what is in it.
public struct ReadSongTool: DirectorTool {
    public struct Input: Decodable, Sendable {}

    public struct Output: Encodable, Sendable {
        public var isOpen: Bool
        public var title: String?
        public var artist: String?
        public var tempo: Double?
        public var key: String?
        public var timeSignature: String?
        public var lengthInBars: Int?
        public var sections: [Section]
        public var versions: [Version]
        public var note: String?

        public struct Section: Encodable, Sendable {
            public var name: String
            public var bars: Int
            public var layers: Int
        }

        public struct Version: Encodable, Sendable {
            public var id: String
            public var part: String
            public var type: String
            public var operation: String
            public var author: String
            public var note: String?
            /// Where this version's audio actually is, when it has any and the library holds it.
            ///
            /// Without this the Director cannot reach a single sample of the open song. Every audio
            /// handle comes from `import_record`, which takes an absolute path; a version id is not
            /// a path, and nothing else in the tool layer turns one into one. The live run made that
            /// concrete — asked to chop the drums of a song whose drums stem was already separated
            /// and on disk, the band called `import_record` three times on paths it had guessed,
            /// failed three times, and said so: *"I hit a wall before the chop, and it's a file one,
            /// not a musical one."*
            ///
            /// It is on the **output** rather than in the schema deliberately: a tool's result is not
            /// part of the request prefix, so saying where the audio is costs nothing in cache.
            public var mediaPath: String?

            enum CodingKeys: String, CodingKey {
                case id, part, type, operation, author, note
                case mediaPath = "media_path"
            }
        }

        enum CodingKeys: String, CodingKey {
            case title, artist, tempo, key, sections, versions, note
            case isOpen = "is_open"
            case timeSignature = "time_signature"
            case lengthInBars = "length_in_bars"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "read_song"
    public var purpose: String {
        "Read the open song: its tempo, key, metre, sections, and every part version anyone has "
        + "made in it, newest last. Call this before proposing anything, so a proposal is about "
        + "what is actually there."
    }
    public var schema: DirectorJSON {
        Schema.object([], required: [])
    }

    /// The file behind a version, when it has one and the library can find it. Nil is ordinary — a
    /// groove has no file, and a session with no library directory has no paths at all.
    static func path(of version: PartVersion, song: SongID, store: LibraryStore?) -> String? {
        guard let store else { return nil }
        let media: MediaRef
        switch version.kind {
        case .audio(let audio): media = audio.media
        case .sample(let sample): media = sample.media
        default: return nil
        }
        return (try? store.mediaURL(for: media, song: song))?.path
    }

    public func run(_ input: Input) async throws -> Output {
        let store = await workspace.store
        guard let song = await workspace.song else {
            return Output(isOpen: false, title: nil, artist: nil, tempo: nil, key: nil,
                          timeSignature: nil, lengthInBars: nil, sections: [], versions: [],
                          note: "No song is open. Everything made now has nowhere to be recorded.")
        }
        return Output(isOpen: true,
                      title: song.title,
                      artist: song.artist.isEmpty ? nil : song.artist,
                      tempo: song.tempo,
                      key: song.key.map { "\($0)" },
                      timeSignature: "\(song.timeSignature)",
                      lengthInBars: song.lengthInBars,
                      sections: song.sections.map {
                          Output.Section(name: $0.name, bars: $0.lengthInBars, layers: $0.stitch.count)
                      },
                      versions: song.versions.map { version in
                          Output.Version(id: version.id.description,
                                         part: version.partID.description,
                                         type: version.type.rawValue,
                                         operation: version.operation,
                                         author: version.author.description,
                                         note: version.note,
                                         mediaPath: ReadSongTool.path(of: version, song: song.id,
                                                                     store: store))
                      },
                      note: nil)
    }
}

// MARK: - create_part_version

/// Hands finished work back to the song graph.
public struct CreatePartVersionTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A groove handle or a chop handle.
        public var from: String
        public var note: String
        public var persona: String?
        /// Derive from an existing version rather than starting a new part.
        public var parent: String?
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var type: String
        public var operation: String
        public var author: String
        public var note: String
        public var recorded: Bool
        public var detail: String?
    }

    let workbench: DirectorWorkbench
    let workspace: any DirectorWorkspace
    /// Who signs a version the model did not name anybody for.
    ///
    /// **Not a default argument on the schema, deliberately.** The model was asked to pass a
    /// `persona` and never did, so every version the band made in the first live run went into the
    /// ledger as `user` and the rail read as though Dylan had cut those chops himself. Attribution
    /// is the product — the point of the ledger is knowing who proposed what — so the fix cannot be
    /// a stronger sentence in the prompt asking the model to remember. It has to be a thing the
    /// model cannot forget, which means the tool decides.
    ///
    /// `.user` is now unreachable from here, and that is correct rather than merely convenient: the
    /// user does not call tools. Everything that arrives through `create_part_version` was made by
    /// the band, and the only open question is *which* of them — a named persona when the model
    /// says one, the Director itself when it does not.
    ///
    /// It is a stored property rather than a constant so a persona-scoped Director signs with its
    /// own name; it is kept out of `schema` so the frozen prefix does not vary with it.
    let acting: String

    public init(workbench: DirectorWorkbench, workspace: any DirectorWorkspace,
                acting: String = CreatePartVersionTool.director) {
        self.workbench = workbench
        self.workspace = workspace
        self.acting = acting
    }

    /// What the band signs with when nobody more specific made the thing. The same word the rail
    /// uses for the Director's own voice, so a version and the line announcing it agree.
    public static let director = "Director"

    public let name = "create_part_version"
    public var purpose: String {
        "Record something the band made into the song as a new, immutable part version — a groove "
        + "from regroove_chop, or a chop's slice markers from chop_bar. Nothing is ever edited in "
        + "place; this appends. The note is what the user will read in the ledger, so write it for them."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("from", Schema.string("A groove handle from regroove_chop, or a chop handle from chop_bar.")),
            ("note", Schema.string("One line saying what this is and why, in the user's language rather than the tool's.")),
            ("persona", Schema.optional(Schema.string("Which member of the band made it, by name. Leave it out and the version is signed by the Director, which is who made it — a version is never attributed to the user, because the user does not call this tool."))),
            ("parent", Schema.optional(Schema.string("A version id this derives from, from read_song. Omit to start a new part."))),
        ], required: ["from", "note", "persona", "parent"])
    }

    public func run(_ input: Input) async throws -> Output {
        // Never `.user`: see `acting`. A name the model sent but left blank is the same as no name.
        let named = input.persona?.trimmingCharacters(in: .whitespacesAndNewlines)
        let author: Author = .persona(named.flatMap { $0.isEmpty ? nil : $0 } ?? acting)
        let parentVersion = try await resolveParent(input.parent)

        let kind: PartKind
        let operation: String
        if input.from.hasPrefix("groove") {
            let stored = try await workbench.groove(input.from)
            kind = .groove(try await groove(for: stored.plan))
            operation = Operation.regroove
        } else if input.from.hasPrefix("chop") {
            let stored = try await workbench.chop(input.from)
            let audio = try await workbench.audio(stored.audio)
            guard let media = audio.media else {
                throw DirectorToolFailure(
                    tool: name,
                    reason: "\(stored.audio) was never stored in the library, so a sample version would point at nothing.",
                    suggestion: "Record the groove instead, or import the record into a session that has a library.")
            }
            kind = .sample(stored.chop.samplePart(media: media))
            operation = Operation.chop
        } else {
            throw DirectorToolFailure(
                tool: name,
                reason: "\"\(input.from)\" is neither a groove nor a chop.",
                suggestion: "Pass a handle from regroove_chop or chop_bar.")
        }

        // Every version the band makes is a new part spawned from its parent rather than a new
        // version of that part: the drums the band arrived at are not a revision of the record.
        let version = parentVersion.map {
            $0.spawning(kind, by: author, operation: operation, note: input.note)
        } ?? PartVersion(partID: PartID(), kind: kind, author: author,
                         operation: operation, note: input.note)

        let recorded = await workspace.record(version)
        if recorded {
            await workspace.note(input.note, detail: "\(operation) · \(author.description)")
        }
        return Output(version: version.id.description,
                      part: version.partID.description,
                      type: version.type.rawValue,
                      operation: operation,
                      author: author.description,
                      note: input.note,
                      recorded: recorded,
                      detail: recorded ? nil : "No song is open, so this was not recorded anywhere.")
    }

    private func resolveParent(_ id: String?) async throws -> PartVersion? {
        guard let id else { return nil }
        guard let versionID = VersionID(uuidString: id) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(id)\" is not a version id.",
                                      suggestion: "Take one from read_song.")
        }
        guard let found = await workspace.version(versionID) else {
            throw DirectorToolFailure(tool: name, reason: "This song has no version \(id).",
                                      suggestion: "Call read_song to see what it has.")
        }
        return found
    }

    /// The groove a plan produced, as the graph stores it: the feel's pattern with the plan's
    /// swing. The velocity scale is a performance decision and lives in the note, not the payload.
    private func groove(for plan: DirectorGroovePlan) async throws -> Groove {
        let library = workbench.engines.feels
        guard var feel = library.feel(named: plan.feel) else {
            throw DirectorToolFailure(tool: name, reason: "The feel \"\(plan.feel)\" is no longer in the library.")
        }
        if let percent = plan.swingPercent { feel = feel.swung(percent: percent) }
        return feel.groove
    }
}
