import Foundation
import MusicTheory
import SongGraph

// The form. Two tools, appended after `write_bassline` so every schema before them keeps its
// bytes: `arrange` states the whole form the way a lead sheet states chords — a line of sections
// with their bars — and `stitch_section` adds one section with the versions it names.
//
// Sections are the one thing in a song that is edited in place: a form is an ordering of
// versions, not a version, and the versions it names are never touched.

/// The section shapes a name implies when no bars are given.
enum SectionShape {
    static func bars(for name: String) -> Int {
        switch name.lowercased() {
        case "intro", "outro", "tag", "turnaround": return 4
        case "verse": return 16
        case "hook", "chorus", "bridge", "break", "breakdown", "drop", "refrain", "pre", "pre-chorus", "interlude": return 8
        default: return 8
        }
    }
}

/// A section as every tool here reports it.
public struct SectionReport: Encodable, Sendable {
    public var id: String
    public var name: String
    public var bars: Int
    /// The version ids stitched into it, in layering order.
    public var versions: [String]
    /// Whether anything in it plays on the transport.
    public var plays: Bool

    init(_ section: Section, in song: Song) {
        id = section.id.description
        name = section.name
        bars = section.lengthInBars
        versions = section.stitch.map(\.description)
        plays = section.stitch.compactMap(song.version).contains { StructureModel.plays($0) }
    }
}

/// The form as the tools hand it back: the sections, the length, and where to look.
public struct FormReport: Encodable, Sendable {
    public var sections: [SectionReport]
    public var bars: Int
    public var seconds: Double
    public var recorded: Bool
    public var detail: String

    init(song: Song, recorded: Bool, detail: String) {
        sections = song.sections.map { SectionReport($0, in: song) }
        bars = song.lengthInBars
        seconds = StructureModel.seconds(bars: song.lengthInBars, tempo: song.tempo, timeSignature: song.timeSignature)
        self.recorded = recorded
        self.detail = detail
    }
}

/// What both tools share: the song's playable versions and the default stitch.
enum FormTools {
    /// The newest of every kind the transport can sound: what a section plays when nobody says
    /// otherwise — the same choice the transport makes for an unarranged song, and the same one
    /// `StructureModel.defaultStitch` makes for a section added by hand.
    ///
    /// Kept in `StructureModel.playableTypes` order, and read through that list rather than a
    /// second hand-written one: this used to name the groove, the bass line and the chop, and go
    /// on naming only those three after the transport learned to play the chords and the tune — so
    /// every form the Director wrote came out without harmony in it.
    static func defaultStitch(in song: Song) -> [VersionID] {
        StructureModel.playableTypes.compactMap { type in
            song.versions.last { $0.type == type && StructureModel.plays($0) }?.id
        }
    }

    /// Resolves the version ids a section names, refusing anything the transport cannot sound.
    static func stitch(_ ids: [String], in song: Song, tool: String) throws -> [VersionID] {
        try ids.map { raw in
            guard let id = VersionID(uuidString: raw), let version = song.version(id) else {
                throw DirectorToolFailure(tool: tool, reason: "This song holds no version \(raw).",
                                          suggestion: "Take version ids from read_song.")
            }
            guard StructureModel.playableTypes.contains(version.type) else {
                throw DirectorToolFailure(
                    tool: tool, reason: "A \(version.type.rawValue) is not something a section plays.",
                    suggestion: "Stitch grooves, bass lines, progressions, melodies and dusty chops; "
                        + "a lyric, an analysis and a sound pick are read elsewhere.")
            }
            guard StructureModel.plays(version) else {
                throw DirectorToolFailure(
                    tool: tool,
                    reason: version.type == .sample ? "\(PartLabel.title(of: version)) is a dry chop, and only a dusty one plays on the transport."
                                                    : "\(PartLabel.title(of: version)) has nothing in it to play.",
                    suggestion: version.type == .sample ? "degrade_part it first, then stitch the dusty version."
                                                        : "Name a version with hits, notes or chords in it.")
            }
            return id
        }
    }

    static let where_ = "Open the Structure surface with nothing bound to see the form; the transport plays the sections in order."
}

// MARK: - arrange

/// States the whole form: a line of sections and their bars, each stitched from the song's newest
/// playable parts, a repeated name sharing one stitch.
public struct ArrangeTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var form: String
    }

    public typealias Output = FormReport

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "arrange"
    public var purpose: String {
        "Arrange the song into sections and replace its form: \"intro 4 | verse 16 | hook 8 | verse 16 | "
        + "hook 8 | outro 4\" is six sections with their bars. Each plays the song's newest groove, bass "
        + "line and dusty chop; a repeated name plays the same stitch as its first; a section already in "
        + "the song by that name keeps what it was stitched from. Bars come from the tempo: a bar of 4/4 "
        + "at 92 bpm is 2.6 seconds, so two minutes is 46 bars. Nothing is versioned — the form is the "
        + "song's — and the transport plays the sections in order."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("form", Schema.string(
                "Sections in order, separated by |, each a name and a length in bars: \"intro 4 | verse 16 | "
                + "hook 8\". A name with no number takes its usual length (intro 4, verse 16, hook 8).")),
        ], required: ["form"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to arrange.")
        }
        let parsed = try Self.parse(input.form, tool: name)
        let stitch = FormTools.defaultStitch(in: song)
        guard !stitch.isEmpty || song.sections.contains(where: { !$0.stitch.isEmpty }) else {
            throw DirectorToolFailure(
                tool: name, reason: "Nothing in \(song.title) plays yet, so there is nothing to arrange.",
                suggestion: "Paint a groove, write a bass line or dust a chop first; then arrange them.")
        }
        var byName: [String: [VersionID]] = [:]
        for section in song.sections where !section.stitch.isEmpty {
            byName[section.name.lowercased()] = byName[section.name.lowercased()] ?? section.stitch
        }
        var sections: [Section] = []
        for (rawName, bars) in parsed {
            let key = rawName.lowercased()
            let layers = byName[key] ?? stitch
            byName[key] = layers
            sections.append(Section(name: rawName, stitch: layers, lengthInBars: bars))
        }
        let recorded = await workspace.arrange(sections)
        let after = await workspace.song ?? song
        return FormReport(song: after, recorded: recorded,
                          detail: recorded ? FormTools.where_ : "No song is open, so nothing was arranged.")
    }

    /// "intro 4 | Verse 16 | hook" → [("intro", 4), ("Verse", 16), ("hook", 8)].
    static func parse(_ form: String, tool: String) throws -> [(String, Int)] {
        let tokens = form.split(whereSeparator: { $0 == "|" || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            throw DirectorToolFailure(tool: tool, reason: "The form names no sections.",
                                      suggestion: "\"intro 4 | verse 16 | hook 8\": names and bars, separated by |.")
        }
        return try tokens.map { token in
            var words = token.split(separator: " ").map(String.init)
            var bars: Int?
            if let last = words.last, let number = Int(last.replacingOccurrences(of: "bars", with: "")) {
                bars = number
                words.removeLast()
            } else if let last = words.last, last.lowercased() == "bars", words.count >= 2, let number = Int(words[words.count - 2]) {
                bars = number
                words.removeLast(2)
            }
            let name = words.joined(separator: " ")
            guard !name.isEmpty else {
                throw DirectorToolFailure(tool: tool, reason: "\"\(token)\" is a length with no section name.",
                                          suggestion: "Every section is a name and its bars: \"verse 16\".")
            }
            let length = bars ?? SectionShape.bars(for: name)
            guard length >= 1 else {
                throw DirectorToolFailure(tool: tool, reason: "\"\(token)\": a section is at least one bar.")
            }
            guard length <= 128 else {
                throw DirectorToolFailure(tool: tool, reason: "\"\(token)\": \(length) bars is longer than a section gets.",
                                          suggestion: "Split it: two sections of 64, or a verse and a hook.")
            }
            return (name.prefix(1).uppercased() + name.dropFirst(), length)
        }
    }
}

// MARK: - stitch_section

/// Adds one section with the versions it names, at a position in the form.
public struct StitchSectionTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var name: String
        public var bars: Int
        public var versions: [String]
        public var position: Int
    }

    public typealias Output = FormReport

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "stitch_section"
    public var purpose: String {
        "Add one section to the song's form: its name, its bars, the versions stitched into it, and "
        + "where it goes. Use it when a section plays something other than the newest of everything — "
        + "a verse on the first groove and a hook on the second, a bridge with no bass. With versions "
        + "empty it plays the newest groove, bass line, progression, melody and dusty chop. To state "
        + "the whole form at once, "
        + "arrange."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("name", Schema.string("The section's name: Intro, Verse, Hook, Bridge, Outro, or your own.")),
            ("bars", Schema.integer("Its length in bars.", minimum: 1, maximum: 128)),
            ("versions", Schema.array(
                "Version ids that play in it, from read_song: grooves, bass lines, progressions, melodies "
                + "and dusty chops. Empty for "
                + "the newest of each.", of: Schema.string("A version id."))),
            ("position", Schema.integer(
                "Where it goes: 0 is first, 1 after the first section, and any number past the end appends.",
                minimum: 0)),
        ], required: ["name", "bars", "versions", "position"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to add a section to.")
        }
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "A section with no name is a block nobody can point at.")
        }
        guard (1...128).contains(input.bars) else {
            throw DirectorToolFailure(tool: name, reason: "\(input.bars) bars is not a section's length; 1 to 128 is.")
        }
        let stitch = input.versions.isEmpty ? FormTools.defaultStitch(in: song)
                                            : try FormTools.stitch(input.versions, in: song, tool: name)
        guard !stitch.isEmpty else {
            throw DirectorToolFailure(
                tool: name, reason: "Nothing in \(song.title) plays yet, so the section would be silent.",
                suggestion: "Paint a groove, write a bass line or dust a chop first.")
        }
        var sections = song.sections
        let section = Section(name: trimmed, stitch: stitch, lengthInBars: input.bars)
        sections.insert(section, at: max(0, min(input.position, sections.count)))
        let recorded = await workspace.arrange(sections)
        let after = await workspace.song ?? song
        return FormReport(song: after, recorded: recorded,
                          detail: recorded ? FormTools.where_ : "No song is open, so nothing was arranged.")
    }
}
