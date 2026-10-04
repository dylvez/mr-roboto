import Foundation
import MusicTheory
import SongGraph

// The form. Two tools, appended after `write_bassline` so every schema before them keeps its
// bytes: `arrange` states the whole form the way a lead sheet states chords — a line of sections
// with their bars — and `stitch_section` adds one section with what it names, or changes what a
// section the song already has is stitched from.
//
// Sections are the one thing in a song that is edited in place: a form is an ordering of *parts*,
// not a version, and the parts it names are never touched. A section plays each part's newest
// version, so a form does not go stale when a part is worked on.

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
    /// What the section plays right now — the version each of its lanes resolves to, in layering
    /// order. Reported as versions rather than parts because that is what every other tool's
    /// arguments and readings are in.
    public var versions: [String]
    /// Whether anything in it plays on the transport.
    public var plays: Bool

    init(_ section: Section, in song: Song) {
        id = section.id.description
        name = section.name
        bars = section.lengthInBars
        // What the lanes play right now, which is what the model should be told about.
        let playing = song.versions(playing: section)
        versions = playing.map(\.id.description)
        plays = playing.contains { StructureModel.plays($0) }
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
    static func defaultStitch(in song: Song) -> [Lane] {
        let song = song.withoutAsides
        // The loop, not a variation of it written since for one section.
        var lanes: [Lane] = []
        for type in StructureModel.playableTypes {
            guard let newest = song.versions.last(where: { $0.type == type && StructureModel.plays($0) && !song.isVariation($0.partID) })
                ?? song.versions.last(where: { $0.type == type && StructureModel.plays($0) }) else { continue }
            // The looped bar stays out from under its own re-groove, as `StructureModel` leaves it.
            if type == .sample, lanes.contains(where: { SongPlayback.chop(under: $0.part, in: song)?.partID == newest.partID }) { continue }
            lanes.append(Lane(part: newest.partID))
        }
        // And every stem the form is playing: a section written without saying what it plays is
        // not a section with the record taken out.
        return lanes + song.seatedStems.map { Lane(part: $0) }
    }

    /// Resolves the ids a section names into lanes, refusing anything the transport cannot sound.
    ///
    /// Either a version id or a part id is accepted. A version id names its part and the section
    /// follows that part — which is the whole change: a form does not go stale when you keep a new
    /// version of what it plays. Pinning a section to one particular version is deliberate and
    /// rare, and no tool offers it yet.
    static func stitch(_ ids: [String], in song: Song, tool: String) throws -> [Lane] {
        try ids.map { raw in
            // A part id is accepted too, and resolves to whatever that part plays now.
            let version = VersionID(uuidString: raw).flatMap(song.version)
                ?? PartID(uuidString: raw).flatMap(song.latestVersion(of:))
            guard let version else {
                throw DirectorToolFailure(tool: tool, reason: "This song holds no version \(raw).",
                                          suggestion: "Take version ids from read_song.")
            }
            // A stem is named like anything else: the section plays its stretch of it.
            if StructureModel.isStem(version) { return Lane(part: version.partID) }
            guard StructureModel.playableTypes.contains(version.type) else {
                throw DirectorToolFailure(
                    tool: tool, reason: "A \(version.type.rawValue) is not something a section plays.",
                    suggestion: "Stitch grooves, bass lines, progressions, melodies, chops and stems; "
                        + "the record itself, a take, a lyric, an analysis and a sound pick are read elsewhere.")
            }
            guard StructureModel.plays(version) else {
                throw DirectorToolFailure(
                    tool: tool,
                    reason: "\(PartLabel.title(of: version)) has nothing in it to play.",
                    suggestion: version.type == .sample ? "Name a chop with slices in it."
                                                        : "Name a version with hits, notes or chords in it.")
            }
            return Lane(part: version.partID)
        }
    }

    static let where_ = "Open the Structure surface with nothing bound to see the form; the transport plays the sections in order."

    /// Where a part plays across the form, counted. "Everywhere" is a claim about every section, and
    /// it is read off the song rather than left to whoever restitched three of them: a form whose
    /// intro has no bass plays the bass line in seven sections of eight. A section playing a
    /// variation of the part is not playing the part as written, and is named as that.
    static func reach(of part: PartID, in song: Song) -> String? {
        guard let version = song.latestVersion(of: part), !song.sections.isEmpty else { return nil }
        let title = PartLabel.title(of: version)
        let strip = song.strip(of: part)
        func name(_ index: Int) -> String {
            let section = song.sections[index]
            return song.sections.filter { $0.name == section.name }.count > 1 ? "\(section.name) (section \(index + 1))" : section.name
        }
        let with = song.sections.indices.filter { index in song.sections[index].stitch.contains { $0.part == part } }
        let without = song.sections.indices.filter { !with.contains($0) }
        let total = song.sections.count
        if with.isEmpty { return "\(title) plays in no section now." }
        if without.isEmpty { return "\(title) plays in all \(total) sections." }
        let count = "\(title) plays in \(with.count) of \(total) sections"
        if with.count < without.count { return count + ": only in \(with.map(name).joined(separator: ", "))." }
        let missing = without.map { index -> String in
            // What sits on its strip there instead, when something does.
            let other = song.sections[index].stitch.first { $0.part != part && song.strip(of: $0.part) == strip }
            guard let variation = other.flatMap({ song.variation(of: $0.part) }) else { return name(index) }
            return "\(name(index)), which plays a variation of it (\(variation.name))"
        }
        return count + ": not in \(missing.joined(separator: "; "))."
    }
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
        + "line and chop; a repeated name plays the same stitch as its first; a section already in "
        + "the song by that name keeps what it was stitched from and the levels the mix gives it. Bars come from the tempo: a bar of 4/4 "
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
        var byName: [String: [Lane]] = [:]
        for section in song.sections where !section.stitch.isEmpty {
            byName[section.name.lowercased()] = byName[section.name.lowercased()] ?? section.stitch
        }
        // A section the song already has stays that section: its id, and with it the levels a mix
        // sets there, its intensity and its transitions. A form stated again used to be all new
        // sections, and every section level of the mix was left naming one that was gone.
        var standing = song.sections
        var sections: [Section] = []
        for (rawName, bars) in parsed {
            let key = rawName.lowercased()
            if let index = standing.firstIndex(where: { $0.name.lowercased() == key }) {
                var kept = standing.remove(at: index)
                kept.name = rawName
                kept.lengthInBars = bars
                if kept.stitch.isEmpty { kept.stitch = byName[key] ?? stitch }
                byName[key] = byName[key] ?? kept.stitch
                sections.append(kept)
                continue
            }
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

/// Adds one section with the versions it names, at a position in the form — or, given a section
/// the song already has, changes what that section plays and leaves it the section it was.
public struct StitchSectionTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var name: String
        public var bars: Int
        public var versions: [String]
        public var position: Int
        /// The id of a section the song already has, to restitch it in place; empty adds one.
        public var section: String

        enum CodingKeys: String, CodingKey { case name, bars, versions, position, section }

        public init(name: String, bars: Int, versions: [String], position: Int, section: String = "") {
            self.name = name
            self.bars = bars
            self.versions = versions
            self.position = position
            self.section = section
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            bars = try values.decode(Int.self, forKey: .bars)
            versions = try values.decode([String].self, forKey: .versions)
            position = try values.decode(Int.self, forKey: .position)
            // Absent in every call written before a standing section could be restitched.
            section = try values.decodeIfPresent(String.self, forKey: .section) ?? ""
        }
    }

    public typealias Output = FormReport

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "stitch_section"
    public var purpose: String {
        "Add one section to the song's form: its name, its bars, what is stitched into it, and where "
        + "it goes. A section names *parts*, so it plays each one's newest version and goes on playing "
        + "it as the part is worked on — naming a version id here names its part. Use it when a section "
        + "plays something other than the newest of everything: a verse with no bass, a hook with a "
        + "second groove over the first. With versions empty it plays the newest groove, bass line, "
        + "progression, melody and chop, and every stem the form is playing. A stem is named like any part: a "
        + "section plays the stretch of it that falls there, and leaving it out of a section is silence there, not a level. "
        + "Name everything the section plays, its stems included. To change what a section the song already has plays — the "
        + "bridge with the original bass line instead of the one written for it — name that section's id: "
        + "it stays the same section, in its place, with its levels in the mix, its intensity and its way "
        + "in. Adding a new one and arranging the old one away loses all of those. To state the whole form "
        + "at once, arrange."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("name", Schema.string("The section's name: Intro, Verse, Hook, Bridge, Outro, or your own. Empty keeps the name of a section being restitched.")),
            ("bars", Schema.integer("Its length in bars, 1 to 128. 0 keeps the length of a section being restitched.", minimum: 0, maximum: 128)),
            ("versions", Schema.array(
                "Ids of what plays in it, from read_song: grooves, bass lines, progressions, melodies "
                + "and chops, dry or dusty. A section follows the part an id belongs to, so it keeps playing that "
                + "part as newer versions of it are made. Empty for the newest of each kind.",
                of: Schema.string("A version id, or the id of the part it belongs to."))),
            ("position", Schema.integer(
                "Where it goes: 0 is first, 1 after the first section, and any number past the end appends. "
                + "A section being restitched stays where it is.",
                minimum: 0)),
            ("section", Schema.string("The id of a section the song already has, from read_song, to change what it plays; empty to add a new section.")),
        ], required: ["name", "bars", "versions", "position", "section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to add a section to.")
        }
        let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let standing = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standing.isEmpty { return try await restitch(standing, named: trimmed, input: input, in: song) }
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

    /// A section the song has, playing what is named now. Its id is its own, so everything that
    /// names it still does: the mix's levels for it, its intensity, its transitions, its place.
    private func restitch(_ id: String, named: String, input: Input, in song: Song) async throws -> Output {
        guard let uuid = UUID(uuidString: id), let index = song.sections.firstIndex(where: { $0.id.rawValue == uuid }) else {
            throw DirectorToolFailure(tool: name, reason: "This song has no section \(id).",
                                      suggestion: "Take a section's id from read_song; leave it empty to add a new section.")
        }
        guard input.bars == 0 || (1...128).contains(input.bars) else {
            throw DirectorToolFailure(tool: name, reason: "\(input.bars) bars is not a section's length; 1 to 128 is, and 0 keeps the length it has.")
        }
        let stitch = input.versions.isEmpty ? FormTools.defaultStitch(in: song)
                                            : try FormTools.stitch(input.versions, in: song, tool: name)
        guard !stitch.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "Nothing was named for \(song.sections[index].name) to play.",
                                      suggestion: "Name the versions it plays; a section with nothing in it is silent.")
        }
        var sections = song.sections
        let before = sections[index].stitch.map(\.part)
        sections[index].stitch = stitch
        if !named.isEmpty { sections[index].name = named }
        if input.bars > 0 { sections[index].lengthInBars = input.bars }
        let recorded = await workspace.arrange(sections)
        let after = await workspace.song ?? song
        // What this call brought into the section and what it took out, each counted across the
        // form: three sections restitched is not yet "everywhere".
        let now = stitch.map(\.part)
        let moved = now.filter { !before.contains($0) } + before.filter { !now.contains($0) }
        let reach = moved.compactMap { FormTools.reach(of: $0, in: after) }
        let counted = reach.isEmpty ? "" : reach.joined(separator: " ") + " Say a part plays in every section only when the count here says all of them. "
        return FormReport(song: after, recorded: recorded,
                          detail: recorded ? "\(sections[index].name) is the same section, playing what was named. " + counted + FormTools.where_
                                           : "No song is open, so nothing was arranged.")
    }
}

// MARK: - split_section

/// Cuts a section in two at a bar, so a part can come in or go out part-way through it.
public struct SplitSectionTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// The section: its id from read_song, or its name.
        public var section: String
        public var afterBar: Int
        enum CodingKeys: String, CodingKey { case section; case afterBar = "after_bar" }
    }

    public typealias Output = FormReport

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "split_section"
    public var purpose: String {
        "Cut a section in two after one of its bars. Both halves play what it played and keep its name; the first keeps "
        + "its id, the seam is a cut with no fill and no crash, and the song's length does not change. This is how a part "
        + "comes in or drops out part-way: \"the drums from bar 3\" is the first section split after bar 2, then "
        + "stitch_section on the first half without the drums. Never resize two sections to do it, and never use a level."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("The section's id from read_song, or its name when only one section has it.")),
            ("after_bar", Schema.integer("The bar of the section the first half ends on: 2 splits a section into its first two bars and the rest.", minimum: 1, maximum: 127)),
        ], required: ["section", "after_bar"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.")
        }
        let asked = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = song.sections.filter { $0.name.caseInsensitiveCompare(asked) == .orderedSame }
        guard let section = song.sections.first(where: { $0.id.description == asked }) ?? (named.count == 1 ? named.first : nil) else {
            throw DirectorToolFailure(tool: name, reason: named.count > 1 ? "\(named.count) sections are called \(asked)." : "This song has no section \(asked).",
                                      suggestion: "Name it by its id from read_song.")
        }
        guard let cut = StructureModel.splitting(song.sections, section.id, afterBar: input.afterBar) else {
            throw DirectorToolFailure(tool: name, reason: "\(section.name) is \(section.lengthInBars) bars, so it cannot be split after bar \(input.afterBar).",
                                      suggestion: section.lengthInBars > 1 ? "A bar from 1 to \(section.lengthInBars - 1)." : "A one-bar section has no bar to split at.")
        }
        let recorded = await workspace.arrange(cut.sections)
        let after = await workspace.song ?? song
        return FormReport(song: after, recorded: recorded,
                          detail: recorded ? "\(section.name) is two sections now: \(input.afterBar) bars, then \(section.lengthInBars - input.afterBar). "
                              + "The second half's id is \(cut.second.id). Both play what it played; restitch either to change that."
                              : "No song is open, so nothing was split.")
    }
}
