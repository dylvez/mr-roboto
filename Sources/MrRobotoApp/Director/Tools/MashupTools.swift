import Foundation
import Performance
import SongGraph

// Mashup: two library songs on one grid, planned in sentences and made as a new song.

private func findSong(_ named: String, in library: Library, open: Song?) -> Song? {
    let songs = (open.map { [$0] } ?? []) + library.songs
    return songs.first { $0.title.caseInsensitiveCompare(named) == .orderedSame } ?? songs.first { $0.id.description == named }
}

private func songFailure(_ tool: String, _ named: String, _ library: Library) -> DirectorToolFailure {
    let analysed = library.songs.filter { Mashups.source(for: $0) != nil }.map(\.title)
    return DirectorToolFailure(tool: tool, reason: "No song called \"\(named)\". Songs that know their bars and key: \(analysed.isEmpty ? "none yet — import two records first" : analysed.joined(separator: ", ")).")
}

private func request(_ tool: String, a: String, b: String, backbone: String, stemsA: [String], stemsB: [String], barShift: Int,
                     library: Library, open: Song?) throws -> (MashupRequest, Song, Song) {
    guard let songA = findSong(a, in: library, open: open) else { throw songFailure(tool, a, library) }
    guard let songB = findSong(b, in: library, open: open) else { throw songFailure(tool, b, library) }
    let side: MashupPlan.Side = backbone.lowercased() == "b" ? .b : .a
    return (MashupRequest(a: songA.id, b: songB.id, backbone: side, stemsA: stemsA.map { $0.lowercased() }, stemsB: stemsB.map { $0.lowercased() }, barShift: barShift), songA, songB)
}

private let stemNames = ["vocals", "drums", "bass", "other", Mashups.full]

// MARK: - plan_mashup

public struct PlanMashupTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var a: String
        public var b: String
        public var backbone: String
        public var bar_shift: Int
    }

    public struct Output: Encodable, Sendable {
        public var key: String
        public var tempo: Double
        public var bars: Int
        public var sentences: [String]
        public var flags: [String]
        public var stems_a: [String]
        public var stems_b: [String]
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "plan_mashup"
    public var purpose: String {
        "Read how two songs in the library would meet as a mashup, before anything is rendered: the key and tempo they settle on, "
        + "how far each moves in semitones and stretch, where their first bars meet, anything flagged, and which stems each can give."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("a", Schema.string("The first song, by title or id.")),
            ("b", Schema.string("The second song, by title or id.")),
            ("backbone", Schema.string("Whose tempo and key stand — usually the instrumental's.", enum: ["a", "b"])),
            ("bar_shift", Schema.integer("The backbone bar the other song's first bar meets, 0 for the first; negative starts the other first.", minimum: -64, maximum: 256)),
        ], required: ["a", "b", "backbone", "bar_shift"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        let (built, songA, songB) = try request(name, a: input.a, b: input.b, backbone: input.backbone, stemsA: [], stemsB: [], barShift: input.bar_shift,
                                                library: library, open: await workspace.song)
        guard songA.id != songB.id else { throw DirectorToolFailure(tool: name, reason: MashupError.sameSong.description) }
        let plan: MashupPlan
        do { plan = try Mashups.plan(built, a: songA, b: songB) } catch { throw DirectorToolFailure(tool: name, reason: "\(error)") }
        return Output(key: plan.target.key?.name ?? "none", tempo: plan.target.tempo ?? 0, bars: plan.lengthInBars, sentences: plan.sentences, flags: plan.flags,
                      stems_a: Mashups.stems(of: songA), stems_b: Mashups.stems(of: songB),
                      detail: plan.sentences.joined(separator: " ") + (plan.flags.isEmpty ? "" : " Flagged: " + plan.flags.joined(separator: " ")))
    }
}

// MARK: - mashup

public struct MashupTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var a: String
        public var b: String
        public var backbone: String
        public var stems_a: [String]
        public var stems_b: [String]
        public var bar_shift: Int
    }

    public struct Output: Encodable, Sendable {
        public var song: String
        public var stems: [String]
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "mashup"
    public var purpose: String {
        "Make the mashup: the chosen stems of two library songs, each moved to the settled key and tempo and set on the backbone's bar "
        + "grid, saved as a new song and opened. Up to four stems between the two. Read plan_mashup first and say the plan."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("a", Schema.string("The first song, by title or id.")),
            ("b", Schema.string("The second song, by title or id.")),
            ("backbone", Schema.string("Whose tempo and key stand — usually the instrumental's.", enum: ["a", "b"])),
            ("stems_a", Schema.array("Stems to take from a; empty takes none.", of: Schema.string("A stem.", enum: stemNames))),
            ("stems_b", Schema.array("Stems to take from b; empty takes none.", of: Schema.string("A stem.", enum: stemNames))),
            ("bar_shift", Schema.integer("The backbone bar the other song's first bar meets, 0 for the first.", minimum: -64, maximum: 256)),
        ], required: ["a", "b", "backbone", "stems_a", "stems_b", "bar_shift"])
    }

    public func run(_ input: Input) async throws -> Output {
        let library = await workspace.library
        let (built, _, _) = try request(name, a: input.a, b: input.b, backbone: input.backbone, stemsA: input.stems_a, stemsB: input.stems_b,
                                        barShift: input.bar_shift, library: library, open: await workspace.song)
        let song: Song
        do { song = try await workspace.makeMashup(built) } catch let failure as DirectorToolFailure { throw failure } catch {
            throw DirectorToolFailure(tool: name, reason: "\(error)")
        }
        let stems = Guidance.stems(in: song).map { $0.note ?? PartLabel.title(of: $0) }
        return Output(song: song.title, stems: stems,
                      detail: "\(song.title) is in the library and open: \(stems.count) stems at \(Int(song.tempo.rounded())) bpm\(song.key.map { " in \($0.name)" } ?? ""), \(song.lengthInBars) bars. Both records are sources to clear.")
    }
}
