import Foundation
import MusicTheory
import Performance
import SongGraph

// M5's one, appended after `convene`: a take read in the band's numbers.

/// The newest take, or one by id: its notes against the key and the grid, and the critics' flags.
public struct ReadTakeTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A take's version id, or empty for the newest.
        public var take: String
    }

    public struct Output: Encodable, Sendable {
        public struct TakeEntry: Encodable, Sendable {
            public var id: String
            public var title: String
            public var section: String?
            public var startBar: Int
            public var seconds: Double
            public var pass: Int
            public var peakDBFS: Double
            enum CodingKeys: String, CodingKey { case id, title, section, seconds, pass; case startBar = "start_bar"; case peakDBFS = "peak_dbfs" }
        }
        public struct Note: Encodable, Sendable {
            public var bar: Int
            public var beat: Double
            public var note: String
            public var cents: Double
            public var timingMS: Double
            enum CodingKeys: String, CodingKey { case bar, beat, note, cents; case timingMS = "timing_ms" }
        }
        public struct Flag: Encodable, Sendable {
            public var critic: String
            public var persona: String
            public var bar: Int
            public var headline: String
            public var measured: Double
            public var unit: String
            public var offered: String
            public var otherwise: String
        }
        public var take: TakeEntry
        public var notes: [Note]
        public var flags: [Flag]
        public var otherTakes: [String]
        public var detail: String
        enum CodingKeys: String, CodingKey { case take, notes, flags, detail; case otherTakes = "other_takes" }
    }

    let workspace: any DirectorWorkspace
    let board: CriticBoard

    public init(workspace: any DirectorWorkspace, board: CriticBoard = .standard) {
        self.workspace = workspace
        self.board = board
    }

    public let name = "read_take"
    public var purpose: String {
        "Read a take the user sang: every note against the key and the grid, in cents and milliseconds, and the band's "
        + "flags with the two fixes each offers. Empty id reads the newest take. Nothing is changed; a fix is offered, never applied."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("take", Schema.string("The take's version id, or empty for the newest take.")),
        ], required: ["take"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Open a song first.")
        }
        let takes = Guidance.takes(in: song)
        let version: PartVersion
        if input.take.isEmpty {
            guard let newest = takes.last else {
                throw DirectorToolFailure(tool: name, reason: "\(song.title) has no takes yet.",
                                          suggestion: "The user sings one in the Booth; open_surface on Booth with nothing bound.")
            }
            version = newest
        } else {
            guard let uuid = UUID(uuidString: input.take), let found = takes.first(where: { $0.id == VersionID(rawValue: uuid) }) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(input.take)\" is not a take in this song.",
                                          suggestion: "Take ids from read_song, or pass an empty id for the newest.")
            }
            version = found
        }
        guard let audio = Guidance.audio(of: version), let take = audio.take else {
            throw DirectorToolFailure(tool: name, reason: "That version is not a take.")
        }
        guard let placed = await workspace.takeAudio(of: version) else {
            throw DirectorToolFailure(tool: name, reason: "The take's audio could not be read.")
        }
        let clock = await workspace.clock
        let analysis = TakeAnalysis.of(placed.planar, sampleRate: placed.sampleRate, alignmentSeconds: placed.alignmentSeconds,
                                       key: song.key, clock: clock, label: PartLabel.title(of: version))
        let findings = board.review(TakeReview(analysis: analysis))
        let sectionName = take.section.flatMap { id in song.sections.first { $0.id == id }?.name }
        let entry = Output.TakeEntry(id: version.id.description, title: PartLabel.title(of: version), section: sectionName,
                                     startBar: take.startBar + 1, seconds: audio.duration, pass: take.pass, peakDBFS: analysis.peakDBFS)
        let notes = analysis.notes.map { Output.Note(bar: $0.bar + 1, beat: $0.beat + 1, note: $0.pitchName,
                                                     cents: ($0.centsFromKey * 10).rounded() / 10, timingMS: $0.timingMS.rounded()) }
        let flags = findings.map { f in
            Output.Flag(critic: f.criticName, persona: f.persona.rawValue, bar: (f.locus.bar ?? 0) + 1, headline: f.headline,
                        measured: (f.measurement.measured * 10).rounded() / 10, unit: f.measurement.unit,
                        offered: f.fixes.first?.title ?? "", otherwise: f.fixes.dropFirst().first?.title ?? "")
        }
        let others = takes.filter { $0.id != version.id }.map { "\(PartLabel.title(of: $0)) \($0.id.description)" }
        var detail = "\(entry.title)\(sectionName.map { " of \($0)" } ?? ""): \(notes.count) notes, \(flags.count) flag\(flags.count == 1 ? "" : "s")"
        if let key = song.key { detail += ", read against \(key)" }
        detail += flags.isEmpty ? ". Nothing past the noticeable line (10 cents, 20 ms)." : ". Each flag offers a correction and the retake; taking one makes a new version with the take underneath."
        return Output(take: entry, notes: notes, flags: flags, otherTakes: others, detail: detail)
    }
}
