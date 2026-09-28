import Foundation
import Performance

// The genres, as the Director reads them: which there are, what one is, and which the song is in.
// What comes back is the app's own knowledge — the profiles under Resources/Genres, researched and
// cited — so the Director works from the same numbers the band judges by rather than its own
// recollection of a genre.

// MARK: - list_genres

public struct ListGenresTool: DirectorTool {
    public struct Input: Decodable, Sendable {}

    public struct Output: Encodable, Sendable {
        public struct Genre: Encodable, Sendable {
            public var id: String
            public var name: String
            public var family: String
            public var tempo: String
            public var aliases: [String]
        }
        public var genres: [Genre]
        /// The open song's genre, and how it is known.
        public var song: String?
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    let book: GenreBook

    public init(workspace: any DirectorWorkspace, book: GenreBook = .standard) {
        self.workspace = workspace
        self.book = book
    }

    public let name = "list_genres"
    public var purpose: String {
        "List the genres this app knows — each a researched profile: tempo, meter, groove, form, harmony, bass, sounds, mix "
        + "and lyrics, with the records and players it comes from — and which one the open song is in."
    }
    public var schema: DirectorJSON { Schema.object([], required: []) }

    public func run(_ input: Input) async throws -> Output {
        let genres = book.profiles.map {
            Output.Genre(id: $0.id, name: $0.name, family: $0.family, tempo: $0.tempo?.span ?? "", aliases: $0.aliases)
        }
        let song = await workspace.genre?.description
        return Output(genres: genres, song: song,
                      detail: "\(genres.count) genres. " + (song.map { "The open song is \($0)." } ?? "The open song has no genre yet; set_genre places it."))
    }
}

// MARK: - read_genre

public struct ReadGenreTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A genre by id, name or alias; empty for the open song's.
        public var genre: String
    }

    public struct Output: Encodable, Sendable {
        public var id: String
        public var name: String
        public var family: String
        public var summary: String
        public var tempo: String
        public var meters: [String]
        /// "feature: range unit", every number the band judges this genre by.
        public var ranges: [String]
        /// Feels in the library that belong to it.
        public var feels: [String]
        public var bassHands: [String]
        public var sounds: GenreSounds
        /// "Intro 16 | Groove 32 | …", when the profile gives a typical form.
        public var form: String?
        public var progressions: [String]
        /// What is true of it that is not a number, by area.
        public var notes: [String: [String]]
        public var players: [String]
        public var records: [String]
        public var pitfalls: [String]
        /// How many claims are cited and how many inferred.
        public var evidence: String

        enum CodingKeys: String, CodingKey {
            case id, name, family, summary, tempo, meters, ranges, feels, sounds, form, progressions, notes, players, records, pitfalls, evidence
            case bassHands = "bass_hands"
        }
    }

    let workspace: any DirectorWorkspace
    let book: GenreBook

    public init(workspace: any DirectorWorkspace, book: GenreBook = .standard) {
        self.workspace = workspace
        self.book = book
    }

    public let name = "read_genre"
    public var purpose: String {
        "Read what this app knows about a genre: its tempo and meter, the numbers the band judges it by, the feels, bass "
        + "hands and sounds that fit, a typical form, its progressions, notes on groove, form, harmony, bass, arrangement, "
        + "sound, mix, melody and lyrics, the players and records it comes from, and what newcomers get wrong. Use it "
        + "before writing in a genre, and say its numbers rather than your own."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("genre", Schema.string("A genre by id, name or alias, like \"house\" or \"drum & bass\"; empty for the open song's.")),
        ], required: ["genre"])
    }

    public func run(_ input: Input) async throws -> Output {
        let asked = input.genre.trimmingCharacters(in: .whitespaces)
        let profile: GenreProfile
        if asked.isEmpty {
            guard let reading = await workspace.genre else {
                throw DirectorToolFailure(tool: name, reason: "The open song has no genre yet.",
                                          suggestion: "Name one, or place the song with set_genre; list_genres has them.")
            }
            profile = reading.profile
        } else {
            guard let found = book.profile(named: asked) else {
                throw DirectorToolFailure(tool: name, reason: "This app has no profile for \"\(asked)\".",
                                          suggestion: "list_genres has the ones it knows: \(book.profiles.map(\.id).joined(separator: ", ")).")
            }
            profile = found
        }
        let cited = profile.evidence.filter(\.isCited).count
        return Output(
            id: profile.id, name: profile.name, family: profile.family, summary: profile.summary,
            tempo: profile.tempo?.span ?? "not stated", meters: profile.meters,
            ranges: profile.ranges.map { "\($0.feature): \($0.span)" + ($0.typical.map { ", typically \(Self.number($0))" } ?? "") },
            feels: profile.feels, bassHands: profile.bassHands, sounds: profile.sounds,
            form: profile.form.map { $0.sections.map { "\($0.name) \($0.bars)" }.joined(separator: " | ") },
            progressions: profile.progressions.map { "\($0.roman)\($0.mode.map { " (\($0))" } ?? ""): \($0.text)" },
            notes: Dictionary(grouping: profile.notes, by: \.area).mapValues { $0.map(\.text) },
            players: profile.lineages.map { "\($0.name) (\($0.period)): \($0.why)" },
            records: profile.references.map { "\($0.artist) — \($0.title)\($0.year.map { " (\($0))" } ?? ""): \($0.listenFor)" },
            pitfalls: profile.pitfalls.map(\.text),
            evidence: "\(cited) claims cited, \(profile.evidence.count - cited) inferred")
    }

    static func number(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.3g", x) }
}

// MARK: - set_genre

public struct SetGenreTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var genre: String
    }

    public struct Output: Encodable, Sendable {
        public var genre: String?
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_genre"
    public var purpose: String {
        "Place the open song in a genre. From then on the band judges it by that genre's numbers — the Engineer's loudness, "
        + "the Peer's hook time, the Beatmaker's swing, the Bassist's pocket — and says both its own number and the genre's. "
        + "Without it the genre is guessed from the feel the newest groove was written in. Empty clears it back to the guess."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("genre", Schema.string("A genre by id, name or alias, like \"house\"; empty to leave it to be guessed.")),
        ], required: ["genre"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard await workspace.song != nil else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to place in a genre.", suggestion: "Call start_song or open_song first.")
        }
        guard await workspace.setGenre(input.genre) else {
            throw DirectorToolFailure(tool: name, reason: "This app has no profile for \"\(input.genre)\".",
                                      suggestion: "list_genres has the ones it knows.")
        }
        let reading = await workspace.genre
        guard let reading else {
            return Output(genre: nil, detail: "The song has no genre: nothing it holds points to one yet.")
        }
        let judged = reading.profile.ranges.map(\.feature.rawValue).prefix(8).joined(separator: ", ")
        return Output(genre: reading.profile.id,
                      detail: "\(reading.description). The band now judges it by \(reading.profile.name)'s numbers on \(judged)"
                        + (reading.profile.ranges.count > 8 ? " and \(reading.profile.ranges.count - 8) more" : "") + ".")
    }
}
