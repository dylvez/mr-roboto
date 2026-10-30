import Foundation
import Performance
import SongGraph

// One section at a time, appended after the keys player: a section made more or less intense, and
// a section heard as it is against how it stood before.
//
// Both came out of one session. Asked for "a more restrained chorus", the Director had develop,
// which arranges the whole song, and the writing tools, which rewrite one part: it rewrote the
// hook's drums, said the hooks were quieter, and they read the same. Asked to play "the two
// choruses side by side", it had a Compare of versions of one part, and played two drum beats.

/// The sections a tool's `section` argument names.
enum SectionNaming {
    /// One section by its id, or every section called that. "Chorus" is every hook, and "the
    /// bridge" the bridge: a word that names a kind of section names the sections of that kind.
    static func resolve(_ text: String, in song: Song, tool: String) throws -> [Section] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) {
            guard let section = song.sections.first(where: { $0.id.rawValue == uuid }) else {
                throw DirectorToolFailure(tool: tool, reason: "This song has no section \(trimmed).",
                                          suggestion: "Take a section's id from read_song, or say its name.")
            }
            return [section]
        }
        let named = song.sections.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if !named.isEmpty { return named }
        let role = SectionRole.named(trimmed)
        // A name nobody recognises reads as a groove, which is not a reason to pick every groove.
        let known = role != .groove || trimmed.lowercased().contains("groove")
        let ofThatKind = known && !trimmed.isEmpty ? song.sections.filter { SectionRole.named($0.name) == role } : []
        guard !ofThatKind.isEmpty else {
            throw DirectorToolFailure(tool: tool, reason: "\(song.title) has no section called \"\(trimmed)\".",
                                      suggestion: "Its sections: " + song.sections.map(\.name).joined(separator: ", ") + ".")
        }
        return ofThatKind
    }
}

// MARK: - set_intensity

/// Takes a section, or every section of a name, to another intensity.
public struct SetIntensityTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var section: String
        public var intensity: Double
    }

    public struct Shaded: Encodable, Sendable {
        public var id: String
        public var name: String
        public var was: Double
        public var now: Double
        /// What it plays now, each in a few words.
        public var plays: [String]
        /// What changed, each in a few words. Empty when nothing had further to go.
        public var moved: [String]
        /// The section bounced through the mix before and after. Nil when there is nothing to render with.
        public var lufsBefore: Double?
        public var lufsAfter: Double?

        enum CodingKeys: String, CodingKey {
            case id, name, was, now, plays, moved
            case lufsBefore = "lufs_before"
            case lufsAfter = "lufs_after"
        }
    }

    public struct Output: Encodable, Sendable {
        public var sections: [Shaded]
        public var recorded: Bool
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_intensity"
    public var purpose: String {
        "Make one section more or less intense, and leave the rest of the song as it is. Use it for \"the chorus is "
        + "too much\", \"a more restrained hook\", \"the verse needs more\", \"pull the bridge back\". Intensity is 0 to 1; "
        + "developing puts an intro near 0.25, a verse 0.55, a bridge 0.5, a hook 0.9 and a drop at 1. Going down, the "
        + "drums come down a rung (lifted, as written, thinned, no kick), then the bass (as written, lighter, held "
        + "roots) and the tune (an octave up, as written, its first phrase, out), and the section's levels follow; "
        + "going up, they climb. It moves only the way asked, and leaves alone what gives a section its character: "
        + "a bridge's ride and its own chords, a build's roll, a part held at a version. Name a section by id for one, "
        + "or by name for every section called that. It answers with what moved and the loudness each section read "
        + "before and after: say those numbers, and where they are the same say that it reads the same rather than "
        + "that it is quieter. A step of 0.15 to 0.25 is one a listener hears; compare_section plays the two."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("A section's id from read_song, or a name — \"Hook\", \"chorus\", \"bridge\" — for every section of that name.")),
            ("intensity", Schema.number("Where it should sit, 0 to 1. The answer says where each section was.", minimum: 0, maximum: 1)),
        ], required: ["section", "intensity"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        guard input.intensity.isFinite, (0...1).contains(input.intensity) else {
            throw DirectorToolFailure(tool: name, reason: "\(Schema.figure(input.intensity)) is not an intensity; 0 to 1 is.")
        }
        let sections = try SectionNaming.resolve(input.section, in: song, tool: name)
        var shaded: [Shaded] = []
        var sentences: [String] = []
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        for section in sections {
            let before = await workspace.loudness(section: section.id)
            guard let shading = await workspace.shade(section: section.id, to: input.intensity) else { continue }
            let after = shading.moved.isEmpty ? before : await workspace.loudness(section: section.id)
            func rounded(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil } }
            shaded.append(Shaded(id: section.id.description, name: section.name, was: shading.was, now: shading.intensity,
                                 plays: shading.plays, moved: shading.moved, lufsBefore: rounded(before), lufsAfter: rounded(after)))
            var sentence = "\(section.name): \(percent(shading.was)) to \(percent(shading.intensity)). "
            sentence += shading.moved.isEmpty ? "Nothing in it had further to go that way; it plays as it did."
                                              : shading.moved.joined(separator: "; ") + "."
            if let was = rounded(before), let now = rounded(after) {
                sentence += abs(was - now) < 0.05 ? String(format: " It reads %.1f LUFS, as it did.", now)
                                                  : String(format: " It read %.1f LUFS and reads %.1f.", was, now)
            }
            sentences.append(sentence)
        }
        guard !shaded.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
        }
        return Output(sections: shaded, recorded: true,
                      detail: sentences.joined(separator: " ") + " compare_section plays a section against how it stood before, and taking the earlier one puts it back.")
    }
}

// MARK: - compare_section

/// Opens a Compare on a section as it is and as it stood before.
public struct CompareSectionTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var section: String
    }

    public struct Row: Encodable, Sendable {
        public var title: String
        public var lufs: Double?
        /// What is different about this row against the section as it is now.
        public var differs: [String]
    }

    public struct Output: Encodable, Sendable {
        public var title: String
        public var rows: [Row]
        public var opened: Bool
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "compare_section"
    public var purpose: String {
        "Let the user hear a whole section as it is now against how it stood before it was last changed — the chorus "
        + "before and after, with everything in it playing through the mix, not one part on its own. Opens a Compare "
        + "whose rows are the section now and up to three earlier states, each bounced and read in LUFS, with the "
        + "section beside it at the head to hear them come out of. Taking an earlier row puts the section back as it "
        + "stood. Use it for \"let me hear the two\", \"before and after\", \"which chorus was better\". A Compare "
        + "from open_surface plays versions of one part; this plays the section. The app remembers how a section "
        + "stood only while the song is open."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("A section's id from read_song, or its name; of several with one name, the first that has changed.")),
        ], required: ["section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        let sections = try SectionNaming.resolve(input.section, in: song, tool: name)
        for section in sections {
            guard let comparison = await workspace.compareSection(section.id) else { continue }
            let rows = comparison.rows.map { row in
                Row(title: row.title, lufs: row.lufs.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil }, differs: row.differs)
            }
            let read = rows.compactMap { row in row.lufs.map { String(format: "%@ %.1f LUFS", row.title, $0) } }.joined(separator: "; ")
            return Output(title: comparison.title, rows: rows, opened: true,
                          detail: "The Compare is open on \(comparison.title): each row is the whole section through the mix. "
                              + (read.isEmpty ? "" : read + ". ") + "Taking an earlier row puts the section back as it stood. "
                              + "Asked to hear them again, call this again: the surface may have been closed since.")
        }
        let names = sections.map(\.name).joined(separator: ", ")
        throw DirectorToolFailure(tool: name, reason: "\(names) has not changed since the song was opened, so there is no earlier one to play.",
                                  suggestion: "Change it — set_intensity, or a part it plays written again — and compare then.")
    }
}

// MARK: - set_transition

/// Sets how a section comes in and how its drums leave it: the way in (a crash, or cut to) and the
/// way out (the usual fill, a fill of a named shape at a size, no fill, a cut, a build's roll), or
/// every section's way out chosen by the rule the Structure surface's Choose fills uses.
public struct SetTransitionTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        /// A section's id or name; empty for every section of the form.
        public var section: String
        /// "" to leave it; "crash"; "cut".
        public var wayIn: String
        /// "" to leave it; "choose"; "usual"; "none"; "cut"; "riser"; or a fill shape by name.
        public var wayOut: String
        /// "" for the shape's own size; "beat", "half-bar", "bar", "two-bars".
        public var size: String
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case section, size, reason
            case wayIn = "way_in"
            case wayOut = "way_out"
        }

        public init(section: String, wayIn: String = "", wayOut: String = "", size: String = "", reason: String = "") {
            self.section = section
            self.wayIn = wayIn
            self.wayOut = wayOut
            self.size = size
            self.reason = reason
        }
    }

    public struct Edge: Encodable, Sendable {
        public var id: String
        public var name: String
        public var wayIn: String
        public var wayOut: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case wayIn = "way_in"
            case wayOut = "way_out"
        }
    }

    public struct Output: Encodable, Sendable {
        public var sections: [Edge]
        public var recorded: Bool
        /// What the Beatmaker says of the form's fills now, when the form has enough edges to say.
        public var reading: String?
        public var detail: String
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "set_transition"
    public var purpose: String {
        "Set how a section comes in and how its drums leave it. The way in is a crash on its one or a cut. The way out "
        + "is the fill into the next section: the usual one (the snare down the toms, half a bar), a fill of a named "
        + "shape — " + FillShape.allCases.filter { $0 != .none }.map { "\($0.rawValue) (\($0.name))" }.joined(separator: ", ")
        + " — at a size (a beat, half a bar, a bar, two bars; a whole bar only into a hook or a drop), no fill, a cut, "
        + "or a build's roll run to the bar line. way_out \"choose\" chooses every named section's fill by the feel's "
        + "family, what the edge goes into and the song's seed — the same rule develop uses — with section empty for "
        + "the whole form. Use it when the Beatmaker says every edge plays one fill, when a fill is wanted somewhere "
        + "(\"a roll into the last chorus\", \"the kit out before the break\") or not (\"no fill into the verse\"). "
        + "read_song says each section's way out; compare_section plays a section before and after."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("section", Schema.string("A section's id from read_song, or a name — \"Hook\", \"chorus\" — for every section of that name; empty for every section of the form.")),
            ("way_in", Schema.string("How the section comes in: empty to leave it as it is.", enum: ["", "crash", "cut"])),
            ("way_out", Schema.string("How its drums leave it: empty to leave it as it is; choose for the rule; usual for the fill every song has; none for no fill; cut; riser for a build's roll; or a shape.",
                                      enum: ["", "choose", "usual", "none", "cut", "riser"] + FillShape.allCases.filter { $0 != .none }.map(\.rawValue))),
            ("size", Schema.string("How long the fill is: empty for the shape's own.", enum: [""] + FillSize.allCases.map(\.rawValue))),
            ("reason", Schema.string("Why, in a few words: what was heard or asked for.")),
        ], required: ["section", "way_in", "way_out", "size", "reason"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        if song.isIdea { throw DirectorToolFailure.inAnIdea(name, has: "no next section to fill into") }
        guard song.sections.count >= 2 else {
            throw DirectorToolFailure(tool: name, reason: "\(song.title) has \(song.sections.count == 1 ? "one section" : "no sections"), so there is no edge to set.",
                                      suggestion: "arrange or develop the song first.")
        }
        let named = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = named.isEmpty ? song.sections : try SectionNaming.resolve(named, in: song, tool: name)
        let ids = Set(chosen.map(\.id))
        let beatsPerBar = song.timeSignature.beatsPerBar
        let wayIn = input.wayIn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wayOut = input.wayOut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let size = input.size.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["", "crash", "cut"].contains(wayIn) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.wayIn)\" is not a way in.", suggestion: "crash or cut, or empty to leave it.")
        }
        let fillSize = size.isEmpty ? nil : FillSize.named(size)
        guard size.isEmpty || fillSize != nil else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.size)\" is not a size.", suggestion: FillSize.allCases.map(\.rawValue).joined(separator: ", ") + ", or empty.")
        }
        var sections = song.sections
        var was: [SectionID: String] = [:]
        for section in sections where ids.contains(section.id) {
            was[section.id] = FillChoosing.wayOut(of: section, beatsPerBar: beatsPerBar, fillsOn: song.playsFills)
        }
        if wayOut == "choose" {
            let all = FillChoosing.chosen(sections, family: FillChoosing.family(of: song), seed: Develop.seed(for: song), beatsPerBar: beatsPerBar,
                                          hasTimbales: FillChoosing.hasTimbales(in: song))
            for index in sections.indices where ids.contains(sections[index].id) { sections[index].transitionOut = all[index].transitionOut }
        } else if !wayOut.isEmpty {
            let way: Transition?
            switch wayOut {
            case "usual", "the usual fill", "fill": way = nil
            case "cut": way = Transition(kind: .cut)
            case "riser", "roll", "build's roll", "a build's roll": way = Transition(kind: .riser)
            default:
                guard let shape = FillShape.named(wayOut) else {
                    throw DirectorToolFailure(tool: name, reason: "\"\(input.wayOut)\" is not a way out.",
                                              suggestion: "choose, usual, none, cut, riser, or a shape: " + FillShape.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                way = Transition.fill(Fill(shape: shape, size: fillSize), beatsPerBar: beatsPerBar)
            }
            for index in sections.indices where ids.contains(sections[index].id) { sections[index].transitionOut = way }
        } else if let fillSize {
            // A size alone: the fill the section has, at that size.
            for index in sections.indices where ids.contains(sections[index].id) {
                let shape = sections[index].transitionOut?.fill(beatsPerBar: beatsPerBar)?.shape ?? Fill.usual.shape
                sections[index].transitionOut = Transition.fill(Fill(shape: shape, size: fillSize), beatsPerBar: beatsPerBar)
            }
        }
        if !wayIn.isEmpty {
            for index in sections.indices where ids.contains(sections[index].id) {
                sections[index].transitionIn = wayIn == "cut" ? Transition(kind: .cut) : nil
            }
        }
        guard wayIn.isEmpty == false || wayOut.isEmpty == false || fillSize != nil else {
            throw DirectorToolFailure(tool: name, reason: "Nothing to set: the way in, the way out and the size are all empty.")
        }
        let recorded = await workspace.arrange(sections)
        let now = await workspace.song ?? song
        let edges = now.sections.filter { ids.contains($0.id) }.map { section in
            Edge(id: section.id.description, name: section.name, wayIn: FillChoosing.wayIn(of: section),
                 wayOut: FillChoosing.wayOut(of: section, beatsPerBar: beatsPerBar, fillsOn: now.playsFills))
        }
        var sentences = edges.map { edge -> String in
            let before = was[SectionID(rawValue: UUID(uuidString: edge.id) ?? UUID())] ?? ""
            return before == edge.wayOut ? "\(edge.name): \(edge.wayOut), in on \(edge.wayIn)."
                                        : "\(edge.name): \(before) becomes \(edge.wayOut), in on \(edge.wayIn)."
        }
        let reading = Beatmaker().readFills(of: now.sections, beatsPerBar: beatsPerBar, fillsOn: now.playsFills)
        if let reading { sentences.append("The Beatmaker: \(reading.says)") }
        if !input.reason.isEmpty { sentences.append("Because \(input.reason).") }
        return Output(sections: edges, recorded: recorded, reading: reading?.says,
                      detail: sentences.joined(separator: " ") + " A section's last bar plays it; compare_section plays the section before and after.")
    }
}
