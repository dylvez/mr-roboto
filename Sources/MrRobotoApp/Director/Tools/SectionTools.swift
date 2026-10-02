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
                              + (read.isEmpty ? "" : read + ". ") + "Taking an earlier row puts the section back as it stood.")
        }
        let names = sections.map(\.name).joined(separator: ", ")
        throw DirectorToolFailure(tool: name, reason: "\(names) has not changed since the song was opened, so there is no earlier one to play.",
                                  suggestion: "Change it — set_intensity, or a part it plays written again — and compare then.")
    }
}
