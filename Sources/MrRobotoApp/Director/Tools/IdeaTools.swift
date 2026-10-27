import Foundation
import MusicTheory
import SongGraph

// Ideas, for the band (ideas-first, Phase 6): one started, one put into the open song, a song made
// of several. What the frame does with File ▸ New Idea, Add to This Song… and New Song from
// Ideas…, with the same arithmetic and the same words. Every field is required, with an empty
// answer for none: the API allows twenty-four optional parameters across the toolbox.

/// An idea of the library's, by id or by title, case aside.
private func findIdea(_ asked: String, in library: Library) -> Song? {
    let text = asked.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return library.ideaSongs.first { $0.id.description.caseInsensitiveCompare(text) == .orderedSame }
        ?? library.ideaSongs.first { $0.title.caseInsensitiveCompare(text) == .orderedSame }
}

private func ideaNames(_ library: Library) -> String {
    library.ideaSongs.isEmpty ? "There are no ideas of their own on the shelf." : "The ideas: " + library.ideaSongs.map(\.title).joined(separator: ", ") + "."
}

// MARK: - new_idea

public struct NewIdeaTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var title: String
        public var tempo: Double
        public var key: String
        public var meter: String
        public var bars: Int
    }

    public struct Output: Encodable, Sendable {
        public var idea: String
        public var title: String
        public var tempo: Double
        public var key: String
        public var meter: String
        public var bars: Int
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "new_idea"
    public var purpose: String {
        "Open a new idea: a few bars at a tempo, key and meter of their own with no song around them, kept on the library's "
        + "Ideas shelf to be put into songs later. The open song is saved first. Write into it as into a song — write_groove, "
        + "set_progression, write_bassline, write_melody, write_lyrics — and a longer part makes it longer. Use it when the "
        + "user wants to try a part on its own, not start a song."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("title", Schema.string("A working title; empty dates it.")),
            ("tempo", Schema.number("Beats per minute; 0 for the starting 120.", minimum: 0, maximum: 300)),
            ("key", Schema.string("Like \"A minor\" or \"Eb major\"; empty for none yet.")),
            ("meter", Schema.string("Like \"4/4\" or \"6/8\"; empty for 4/4.")),
            ("bars", Schema.integer("How long it is to start with; it grows to hold what is written or sung longer.", minimum: 1, maximum: 256)),
        ], required: ["title", "tempo", "key", "meter", "bars"])
    }

    public func run(_ input: Input) async throws -> Output {
        let keyText = input.key.trimmingCharacters(in: .whitespaces)
        let key = keyText.isEmpty ? nil : Key(parsing: keyText)
        if key == nil, !keyText.isEmpty {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.key)\" is not a key I can read.", suggestion: "Say it like \"D minor\" or \"Bb major\", or leave it empty.")
        }
        let meterText = input.meter.trimmingCharacters(in: .whitespaces)
        guard let meter = meterText.isEmpty ? .fourFour : AppState.timeSignature(parsing: meterText) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.meter)\" is not a meter.", suggestion: "Two numbers over a slash, like 4/4 or 6/8, or empty.")
        }
        guard let idea = await workspace.newIdea(title: input.title, tempo: input.tempo > 0 ? input.tempo : Song.startingTempo,
                                                 key: key, meter: meter, bars: input.bars) else {
            throw DirectorToolFailure(tool: name, reason: "No idea could be opened here.", suggestion: "Ideas live in the app's library; open it first.")
        }
        let bars = idea.sections.first?.lengthInBars ?? input.bars
        return Output(idea: idea.id.description, title: idea.title, tempo: idea.tempo, key: idea.key?.name ?? "none",
                      meter: idea.timeSignature.description, bars: bars,
                      detail: "\(idea.title) is open: an idea, \(AppState.ideaLine(idea)). Write into it as into a song; it goes round, and a "
                        + "longer part makes it longer. place_idea puts it into a song, song_from_ideas makes a song of several.")
    }
}

// MARK: - place_idea

public struct PlaceIdeaTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var idea: String
        public var section: String
        public var parts: [String]
        public var words: Bool
        public var replace: Bool
    }

    public struct Output: Encodable, Sendable {
        public var section: String
        public var versions: [String]
        /// What each part did on the way in, and what the section says of it.
        public var sentences: [String]
        public var flags: [String]
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "place_idea"
    public var purpose: String {
        "Put an idea from the library into the open song: into one of its sections, or a new section after the last as long "
        + "as the idea and named after it. Its parts come in moved onto the song's key and tempo by the merge's rules — chords, "
        + "a bass line and a tune by arithmetic at no cost, a groove as it is, audio (a take, a comp, a capture from the phone) "
        + "shifted and stretched, the drums never shifted — and go round to fill the section as they went round in the idea. "
        + "Chords, a bass line or a groove take the place of the section's own unless replace is false, when they play together "
        + "— an organ's bubble over a guitar's skank; the idea's words become the section's unless it has some. The idea is copied and left as it was. Say the sentences that come back, with the numbers, and any flag."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("idea", Schema.string("The idea's id or title, from read_library's ideas.")),
            ("section", Schema.string("The open song's section, by id or name, from read_song; empty for a new section after the last.")),
            ("parts", Schema.array("Which of its parts, by name as read_library's note says them (\"Take 1\", \"Chords\"); empty for all of them.",
                                   of: Schema.string("A part of the idea, by name or id."))),
            ("words", Schema.boolean("Whether the idea's words come too, as the section's stanza.")),
            ("replace", Schema.boolean("Whether its chords, bass line or groove take the place of the section's own of that kind; false plays them together.")),
        ], required: ["idea", "section", "parts", "words", "replace"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to put the idea in.", suggestion: "open_song, start_song, or song_from_ideas for a new song made of ideas.")
        }
        let library = await workspace.library
        guard let idea = findIdea(input.idea, in: library) else {
            throw DirectorToolFailure(tool: name, reason: "The library has no idea \"\(input.idea)\".", suggestion: ideaNames(library))
        }
        guard idea.id != song.id else {
            throw DirectorToolFailure(tool: name, reason: "\(idea.title) is the idea that is open.", suggestion: "Open the song it goes in first.")
        }
        let asked = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        let spot: IdeaSpot
        if asked.isEmpty || asked.caseInsensitiveCompare("new") == .orderedSame {
            if song.isIdea, let only = song.sections.first {
                spot = .section(only.id)
            } else {
                spot = .end
            }
        } else if let section = song.sections.first(where: { $0.id.description.caseInsensitiveCompare(asked) == .orderedSame })
                    ?? song.sections.first(where: { $0.name.caseInsensitiveCompare(asked) == .orderedSame }) {
            spot = .section(section.id)
        } else {
            throw DirectorToolFailure(tool: name, reason: "\(song.title) has no section \"\(asked)\".",
                                      suggestion: "Its sections: \(song.sections.map(\.name).joined(separator: ", ")); empty for a new one after the last.")
        }
        guard let plan = await workspace.ideaPlacement(idea.id, at: spot) else {
            throw DirectorToolFailure(tool: name, reason: "\(idea.title) could not be put in \(song.title) there.")
        }
        var chosen: Set<PartID>?
        let names = input.parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !names.isEmpty {
            var found = Set<PartID>()
            for name in names {
                guard let piece = plan.pieces.first(where: { piece in
                    piece.title.caseInsensitiveCompare(name) == .orderedSame || piece.id.description.caseInsensitiveCompare(name) == .orderedSame
                        || piece.version.id.description.caseInsensitiveCompare(name) == .orderedSame
                }) else {
                    throw DirectorToolFailure(tool: self.name, reason: "\(idea.title) has no part \"\(name)\".",
                                              suggestion: "Its parts: \(plan.pieces.map(\.title).joined(separator: ", ")); empty for all of them.")
                }
                found.insert(piece.id)
            }
            chosen = found
        }
        let coming = plan.placeable.filter { chosen?.contains($0.id) ?? true }
        let refused = plan.pieces.filter(\.isRefused)
        if coming.isEmpty, !(input.words && plan.words?.comes == true) {
            throw DirectorToolFailure(tool: name, reason: "Nothing of \(idea.title) can come in: \(refused.flatMap(\.flags).joined(separator: " "))",
                                      suggestion: "Choose another part, or another idea.")
        }
        let placed: [PartVersion]
        do {
            placed = try await workspace.place(plan, parts: chosen, words: input.words, replacing: input.replace)
        } catch let failure as IdeaPlacingError {
            throw DirectorToolFailure(tool: name, reason: failure.description)
        }
        let after = await workspace.song
        let section = after?.sections.last { $0.name == plan.sectionName }.map(\.name) ?? plan.sectionName
        var sentences = plan.sentences + coming.map { piece in
            piece.sentence + (piece.replaces.isEmpty ? ""
                : input.replace ? " In the \(plan.sectionName), in place of \(SectionWriting.list(piece.replaces))."
                : " In the \(plan.sectionName), with \(SectionWriting.list(piece.replaces)).")
        }
        if let words = plan.words, input.words { sentences.append(words.sentence) }
        return Output(section: section, versions: placed.map(\.id.description), sentences: sentences,
                      flags: coming.flatMap(\.flags) + refused.flatMap(\.flags),
                      detail: "\(idea.title) is in the \(section) of \(song.title): \(Guidance.count(placed.count, "part")). The idea is as it was.")
    }
}

// MARK: - song_from_ideas

public struct SongFromIdeasTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var sections: [String]
        public var grid: String
        public var title: String
    }

    public struct Output: Encodable, Sendable {
        public var song: String
        public var title: String
        public var tempo: Double
        public var key: String
        public var sections: [String]
        /// What taking that grid did to each of the other ideas.
        public var sentences: [String]
        public var flags: [String]
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "song_from_ideas"
    public var purpose: String {
        "Make a new song of ideas from the library, laid end to end: a section for each entry, named after its idea and as long "
        + "as it, two or more joined with \" + \" playing together in one section. The song takes the tempo, key and meter of "
        + "the idea that would lose most by moving — a sung or recorded idea before written ones, which move at no cost — "
        + "unless grid names another; every other idea is moved onto it as place_idea moves one. The open song is saved first "
        + "and the new one opens on Structure, to repeat, reorder or develop. The ideas are left as they were."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("sections", Schema.array("In the order the song plays them: an idea's id or title, or several joined with \" + \" for one section.",
                                      of: Schema.string("One section's idea or ideas."))),
            ("grid", Schema.string("The idea whose tempo, key and meter the song takes, by id or title; empty for the one that moves the rest least.")),
            ("title", Schema.string("The song's title; empty dates it.")),
        ], required: ["sections", "grid", "title"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        var rows: [[SongID]] = []
        for entry in input.sections {
            var row: [SongID] = []
            for asked in entry.components(separatedBy: "+") where !asked.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let idea = findIdea(asked, in: library) else {
                    throw DirectorToolFailure(tool: name, reason: "The library has no idea \"\(asked.trimmingCharacters(in: .whitespaces))\".",
                                              suggestion: ideaNames(library))
                }
                row.append(idea.id)
            }
            if !row.isEmpty { rows.append(row) }
        }
        guard !rows.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "No ideas were named.", suggestion: ideaNames(library))
        }
        var grid: SongID?
        if !input.grid.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let found = findIdea(input.grid, in: library), rows.contains(where: { $0.contains(found.id) }) else {
                throw DirectorToolFailure(tool: name, reason: "The grid must be one of the ideas named; \"\(input.grid)\" is not.",
                                          suggestion: "Name one of the sections' ideas, or leave grid empty.")
            }
            grid = found.id
        }
        let ideas = rows.flatMap { $0 }.compactMap { id in library.ideaSongs.first { $0.id == id } }
        let grids = SongFromIdeas.grids(for: ideas)
        let taken = grids.first { $0.idea == grid } ?? grids.first
        let id: SongID
        do {
            id = try await workspace.makeSong(from: rows, grid: taken?.idea, title: input.title)
        } catch let failure as IdeaPlacingError {
            throw DirectorToolFailure(tool: name, reason: failure.description)
        }
        guard let song = await workspace.song, song.id == id else {
            throw DirectorToolFailure(tool: name, reason: "The song was made but is not open.")
        }
        return Output(song: id.description, title: song.title, tempo: song.tempo, key: song.key?.name ?? "none",
                      sections: song.sections.map { "\($0.name) \($0.lengthInBars)" },
                      sentences: taken?.sentences ?? [], flags: taken?.flags ?? [],
                      detail: "\(song.title) is open on Structure: \(Guidance.count(song.sections.count, "section")) at "
                        + "\(taken.map(SongFromIdeas.line) ?? "its grid"), \(taken?.title ?? "the first idea")'s. Repeat, reorder or develop it from here; the ideas are as they were.")
    }
}
