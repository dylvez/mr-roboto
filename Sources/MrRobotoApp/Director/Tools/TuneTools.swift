import Analysis
import Foundation
import SongGraph

// MARK: - tune_take

/// A sung take or a comp tuned to the song's key, kept as a new version of the same part.
public struct TuneTakeTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// A take's or a comp's version id, or a part id; empty for the newest take in the song.
        public var take: String
        /// One of `PitchCorrection.Strength`.
        public var strength: String
        public var reason: String
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var tuned: String
        public var key: String
        public var centsBefore: Double
        public var centsAfter: Double
        public var detail: String
        enum CodingKeys: String, CodingKey {
            case version, tuned, key, detail
            case centsBefore = "cents_before"; case centsAfter = "cents_after"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "tune_take"
    public var purpose: String {
        "Tune a sung take or a comp to the song's key, the way Auto-Tune does: "
        + PitchCorrection.Strength.allCases.map { "\($0.rawValue) (\($0.words))" }.joined(separator: "; ")
        + ". Hard is the sound trap, drill, reggaetón, R&B, afrobeats and arabic pop are sung through; natural is what a "
        + "pop vocal gets and nobody hears. Kept as a new version of the same part, where the take was, the take as sung "
        + "a step back. Needs the song's key: set it with set_song first if read_song shows none."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("take", Schema.string("A take's or a comp's version id, or its part id; empty for the newest take in the song.")),
            ("strength", Schema.string("How hard it is tuned.", enum: PitchCorrection.Strength.allCases.map(\.rawValue))),
            ("reason", Schema.string("Why, in the music's terms.")),
        ], required: ["take", "strength", "reason"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Open a song first.")
        }
        guard let strength = PitchCorrection.Strength(rawValue: input.strength.lowercased()) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.strength)\" is not a strength.",
                                      suggestion: PitchCorrection.Strength.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let version = try Self.take(input.take, in: song, tool: name)
        switch await workspace.tuneTake(version, strength: strength) {
        case .failed(let why):
            throw DirectorToolFailure(tool: name, reason: why, suggestion: "Nothing was tuned; the take is as it was sung.")
        case .tuned(let kept, let result, let key):
            let detail = String(format: "%@ is tuned %@ to %@ as %@: %.0f cents off its notes on average before, %.0f after, "
                                + "the largest move %.2f semitones. The take as sung is a step back. Play it, or open_surface on Takes "
                                + "bound to it to hear it beside the take.",
                                PartLabel.title(of: version), strength.rawValue, key.name, PartLabel.title(of: kept),
                                result.centsBefore, result.centsAfter, result.largestShift)
            return Output(version: kept.id.description, tuned: PartLabel.title(of: version), key: key.name,
                          centsBefore: (result.centsBefore * 10).rounded() / 10, centsAfter: (result.centsAfter * 10).rounded() / 10,
                          detail: detail)
        }
    }

    /// The take a tool names: a version id (its part's newest, so a tuned take is not tuned twice
    /// over the old one), a part id, or the song's newest take.
    static func take(_ text: String, in song: Song, tool: String) throws -> PartVersion {
        func isTake(_ version: PartVersion) -> Bool {
            if case .audio(let audio) = version.kind { return audio.role == .take }
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard let newest = song.versions.last(where: isTake) else {
                throw DirectorToolFailure(tool: tool, reason: "The song has no sung takes.",
                                          suggestion: "The user sings one in the Booth: open_surface on Booth with nothing bound.")
            }
            return newest
        }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw DirectorToolFailure(tool: tool, reason: "\"\(trimmed)\" is not an id.", suggestion: "A take's version id from read_song, or empty.")
        }
        let found = song.version(VersionID(rawValue: uuid)) ?? song.versions.last { $0.partID == PartID(rawValue: uuid) }
        guard let found, isTake(found) else {
            throw DirectorToolFailure(tool: tool, reason: "\(trimmed) is not a sung take or a comp in this song.",
                                      suggestion: "read_song lists the takes.")
        }
        return found
    }
}
