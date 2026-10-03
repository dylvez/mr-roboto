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
            public var id: String
            public var name: String
            public var bars: Int
            /// What the section plays right now: the version each of its lanes resolves to, in
            /// layering order. A section names parts, so this follows them.
            public var versions: [String]
        }

        public struct Version: Encodable, Sendable {
            public var id: String
            public var part: String
            public var type: String
            public var operation: String
            public var author: String
            public var note: String?
            /// The key the part stands in, when it says: a chop's from where it was cut, a bass
            /// line's from where it was written, a progression's own. What a merge reads.
            public var key: String?
            /// A chop's tempo, when it was detected.
            public var tempo: Double?
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
            /// The part this one is a variation of, when it is one — the drums, for the drums with
            /// no kick — and the treatment. It plays through that part's strip and instrument.
            public var variationOf: String?
            public var variation: String?
            /// What a groove is heard on: a drum machine, or a chop's own slices.
            ///
            /// A groove on a chop is that chop in a rhythm. In the live session that asked for
            /// this, the song's only groove was a bar of the other stem played in a feel; the user
            /// said they could not hear the beat, and the band, reading `type: groove`, raised the
            /// master 18.8 dB and cut 85 Hz on "the sample" to let "the kick" through. There was
            /// no kick. Nothing it could read said so.
            public var playsOn: String?
            /// Set aside: in no section and not playing, until set_aside brings it back. And why.
            public var setAside: Bool?
            public var asideBecause: String?

            enum CodingKeys: String, CodingKey {
                case id, part, type, operation, author, note, key, tempo, variation
                case setAside = "set_aside"
                case asideBecause = "aside_because"
                case mediaPath = "media_path"
                case variationOf = "variation_of"
                case playsOn = "plays_on"
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
                          Output.Section(id: $0.id.description, name: $0.name, bars: $0.lengthInBars,
                                         versions: song.versions(playing: $0).map(\.id.description))
                      },
                      versions: song.versions.map { version in
                          Output.Version(id: version.id.description,
                                         part: version.partID.description,
                                         type: version.type.rawValue,
                                         operation: version.operation,
                                         author: version.author.description,
                                         note: version.note,
                                         key: ReadSongTool.key(of: version).map { "\($0)" },
                                         tempo: ReadSongTool.tempo(of: version),
                                         mediaPath: ReadSongTool.path(of: version, song: song.id,
                                                                     store: store),
                                         variationOf: song.variation(of: version.partID)?.of.description,
                                         variation: song.variation(of: version.partID)?.name,
                                         playsOn: ReadSongTool.playsOn(version, in: song),
                                         setAside: song.isAside(version.partID) ? true : nil,
                                         asideBecause: song.aside(version.partID)?.note)
                      },
                      note: nil)
    }
}

extension ReadSongTool {
    /// The key a version stands in, when it carries one.
    static func key(of version: PartVersion) -> Key? {
        switch version.kind {
        case .sample(let sample): return sample.key
        case .bassline(let line): return line.key
        case .progression(let progression): return progression.key
        default: return nil
        }
    }

    static func tempo(of version: PartVersion) -> Double? {
        if case .sample(let sample) = version.kind { return sample.detectedTempo }
        return nil
    }

    /// What a groove's part is heard on now, in words the band can act on. Nil for anything else.
    static func playsOn(_ version: PartVersion, in song: Song) -> String? {
        guard version.type == .groove else { return nil }
        guard let chop = SongPlayback.chop(under: version.partID, in: song) else {
            return "the \(SongPlayback.machine(for: version.partID, in: song).name) drum machine"
        }
        let slices = "the slices of chop \(chop.partID.description) (\(PartLabel.title(of: chop)))"
        return Guidance.hasDrums(chop, in: song)
            ? "\(slices): that chop re-grooved, not a drum machine"
            : "\(slices), cut from a stem with no drums in it: this is that chop played in a rhythm, not drums. "
                + "A beat under it is a second groove, from write_groove, stitched beside it."
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
        /// Made only to be read, not to play: joins no section and is set aside.
        public var reference: Bool?
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var type: String
        public var operation: String
        public var author: String
        public var note: String
        public var recorded: Bool
        /// Set aside as reference, joining no section.
        public var reference: Bool?
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
        + "place; this appends. The note is what the user will read in the ledger, so write it for them. "
        + "A new part joins the sections that play none of its kind; with reference true it joins none and "
        + "is set aside, for a chop cut only to read — a stem's hits mapped to write a kit from — that the "
        + "user did not ask to hear."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("from", Schema.string("A groove handle from regroove_chop, or a chop handle from chop_bar.")),
            ("note", Schema.string("One line saying what this is and why, in the user's language rather than the tool's.")),
            ("persona", Schema.optional(Schema.string("Which member of the band made it, by name. Leave it out and the version is signed by the Director, which is who made it — a version is never attributed to the user, because the user does not call this tool."))),
            ("parent", Schema.optional(Schema.string("A version id this derives from, from read_song. Omit to start a new part."))),
            ("reference", Schema.boolean("True for something made only to be read, not played: it joins no section and is set aside. False for a part the song plays.")),
        ], required: ["from", "note", "persona", "parent", "reference"])
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

        let reference = input.reference == true
        let recorded = reference ? await workspace.recordReference(version, note: input.note) : await workspace.record(version)
        if recorded, !reference {
            await workspace.note(input.note, detail: "\(operation) · \(author.description)")
            // A groove re-grooved from a chop the song holds plays that chop's slices, where the
            // chop played: what the Chop lane's Make the groove does.
            if case .groove = kind, let parentVersion, parentVersion.type == .sample {
                await workspace.playGroove(version.partID, onChop: parentVersion.partID)
            }
        }
        return Output(version: version.id.description,
                      part: version.partID.description,
                      type: version.type.rawValue,
                      operation: operation,
                      author: author.description,
                      note: input.note,
                      recorded: recorded,
                      reference: reference ? true : nil,
                      detail: !recorded ? "No song is open, so this was not recorded anywhere."
                          : reference ? "Set aside as reference: in no section, and not playing. set_aside with back true brings it into the song." : nil)
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

// MARK: - set_aside

/// A part taken out of the song without deleting it, or brought back.
public struct SetAsideTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var part: String
        public var back: Bool
        public var reason: String
    }

    public struct Output: Encodable, Sendable {
        public var part: String
        public var title: String
        public var setAside: Bool
        /// The sections it plays in now.
        public var sections: [String]
        public var detail: String

        enum CodingKeys: String, CodingKey { case part, title, sections, detail; case setAside = "set_aside" }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_aside"
    public var purpose: String {
        "Take a part out of the song without deleting it: out of every section that plays it, and out of what plays, "
        + "the Mixer and Structure, until it is brought back with back true, into the sections it left. This is how a "
        + "part is taken away — \"lose the strings\", \"I don't want the second bass line\" — rather than resizing sections "
        + "or turning it down. Nothing made is ever deleted; the user brings it back from Parts as easily."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("part", Schema.string("A version or part id from read_song.")),
            ("back", Schema.boolean("True brings a part set aside back into the sections it left; false sets it aside.")),
            ("reason", Schema.string("Why, in a few words, shown beside it in Parts; empty for none.")),
        ], required: ["part", "back", "reason"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else { throw DirectorToolFailure(tool: name, reason: "No song is open.") }
        let part = VersionID(uuidString: input.part).flatMap(song.version)?.partID ?? PartID(uuidString: input.part)
        guard let part, let version = song.latestVersion(of: part) else {
            throw DirectorToolFailure(tool: name, reason: "This song has no part \(input.part).", suggestion: "Take a version or part id from read_song.")
        }
        let reason = input.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = input.back ? await workspace.bringBack(part) : await workspace.setAside(part, note: reason.isEmpty ? nil : reason)
        guard done else {
            throw DirectorToolFailure(tool: name, reason: input.back ? "\(PartLabel.title(of: version)) is not set aside." : "\(PartLabel.title(of: version)) is set aside already.")
        }
        let after = await workspace.song ?? song
        let sections = after.sections.filter { $0.stitch.contains(part: part) }.map(\.name)
        return Output(part: part.description, title: PartLabel.title(of: version), setAside: !input.back, sections: sections,
                      detail: input.back ? (sections.isEmpty ? "Back in the song; no section it played in is still in the form, so stitch_section puts it somewhere."
                                                            : "Back in \(sections.joined(separator: ", ")).")
                                         : "Out of the song and listed under Set aside in Parts; set_aside with back true brings it back.")
    }
}
