import Foundation
import Performance
import SongGraph

// Developing, appended after the genres: the loop arranged into a song in one move.
//
// Everything `develop` does the Director could already do a call at a time — write a groove for
// the intro, stitch it, write another for the breakdown, set a level in the hook — and at forty
// calls for a song it never did. This is the whole arrangement as one tool, worked out by the app
// from the parts the song holds, so what the Director spends its turn on is what to say about it.

/// One section of a developed song, as the tool reports it.
public struct DevelopedSection: Encodable, Sendable {
    public var name: String
    public var bars: Int
    /// What the name was read as: intro, verse, hook, breakdown, build, drop…
    public var role: String
    /// 0 to 1: how much is happening.
    public var intensity: Double
    /// What it plays, each in a few words: "drums, thinned", "chords".
    public var plays: [String]
}

public struct DevelopTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var form: String
        public var putBack: Bool

        enum CodingKeys: String, CodingKey { case form; case putBack = "put_back" }
    }

    public struct Output: Encodable, Sendable {
        /// Where the form came from, in words.
        public var form: String
        public var sections: [DevelopedSection]
        public var bars: Int
        public var seconds: Double
        /// The variations written, by name. Each is a part of its own that plays through the
        /// strip and the instrument of the part it came from.
        public var written: [String]
        public var genre: String?
        public var targetLUFS: Double?
        /// The whole song bounced through its mix once everything was in. Nil when this
        /// workspace has nothing to render with.
        public var integratedLUFS: Double?
        public var truePeakDBTP: Double?
        public var masterGainDB: Double?
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case form, sections, bars, seconds, written, genre, recorded, detail
            case targetLUFS = "target_lufs"
            case integratedLUFS = "integrated_lufs"
            case truePeakDBTP = "true_peak_dbtp"
            case masterGainDB = "master_gain_db"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "develop"
    public var purpose: String {
        "Develop the song: arrange the loop it holds into a whole song in one move. The form is the song's own when it "
        + "has been arranged, else its genre's usual one, else a verse-and-hook form — or the one you give. Each section "
        + "then plays the loop its own way: the drums thinned for an intro, no kick under a breakdown, a roll through a "
        + "build, a layer on top for a hook or a drop; the bass out, lighter, holding its roots or pulsing; the tune "
        + "saved for where the song arrives and lifted an octave the last time. Each variation is written from the part "
        + "the song already has and plays through that part's strip and instrument. Sections get a level each, and the "
        + "master is brought to the loudness the genre is delivered at. Use it for \"make this a song\", \"arrange it\", "
        + "\"finish it\", \"it is just a loop\". put_back undoes the last one."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("form", Schema.string(
                "Sections in order, separated by |, each a name and its bars: \"intro 8 | verse 16 | hook 8 | breakdown 8 | "
                + "hook 16 | outro 8\". A section's name says how it is played, so name them for what they are. Empty takes "
                + "the song's own form, its genre's, or the app's.")),
            ("put_back", Schema.boolean(
                "True puts the song back as it was before it was last developed — its form and its mix — and does nothing else.")),
        ], required: ["form", "put_back"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open to develop.",
                                      suggestion: "Call start_song, or open_song for one in the library.")
        }
        if input.putBack {
            guard await workspace.putBackDevelopment() else {
                throw DirectorToolFailure(tool: name, reason: "\(song.title) has not been developed since it was opened, so there is nothing to put back.",
                                          suggestion: "arrange states a form by hand.")
            }
            let after = await workspace.song ?? song
            return Output(form: "the form it had before", sections: after.sections.map { section in
                DevelopedSection(name: section.name, bars: section.lengthInBars, role: SectionRole.named(section.name).rawValue,
                                 intensity: section.intensity ?? SectionRole.named(section.name).intensity,
                                 plays: after.versions(playing: section).map(PartLabel.title(of:)))
            }, bars: after.lengthInBars,
                          seconds: StructureModel.seconds(bars: after.lengthInBars, tempo: after.tempo, timeSignature: after.timeSignature),
                          written: [], genre: nil, targetLUFS: nil, integratedLUFS: nil, truePeakDBTP: nil, masterGainDB: nil,
                          recorded: true, detail: "The form and the mix are as they were. What was written for the arrangement is still in the song, in no section.")
        }
        let trimmed = input.form.trimmingCharacters(in: .whitespacesAndNewlines)
        let form = trimmed.isEmpty ? nil : try ArrangeTool.parse(trimmed, tool: name).map { (name: $0.0, bars: $0.1) }
        guard !Develop.loop(of: song).isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "Nothing in \(song.title) plays yet, so there is no loop to develop.",
                                      suggestion: "Write a groove, a bass line, chords or a tune first; then develop them.")
        }
        guard let result = await workspace.develop(form: form) else {
            throw DirectorToolFailure(tool: name, reason: "\(song.title) could not be developed.")
        }
        let development = result.development
        let seconds = StructureModel.seconds(bars: development.bars, tempo: song.tempo, timeSignature: song.timeSignature)
        var detail = "\(development.shape), \(StructureModel.clock(seconds)), in \(development.form.words). "
        detail += development.written.isEmpty ? "Nothing new was written: the song already held every variation it plays. "
                                              : "\(development.written.count) variations written. "
        if let loudness = result.loudness {
            detail += String(format: "Bounced through the mix it reads %.1f LUFS, true peak %.1f dBTP, with the master at %+.1f dB. ",
                             loudness.integratedLUFS, loudness.truePeakDBTP, loudness.masterGainDB)
        }
        detail += "Open Structure to see it; put_back undoes it."
        return Output(form: development.form.words,
                      sections: development.plays.map { DevelopedSection(name: $0.name, bars: $0.bars, role: $0.role.rawValue,
                                                                         intensity: $0.intensity, plays: $0.parts) },
                      bars: development.bars, seconds: (seconds * 10).rounded() / 10, written: development.written,
                      genre: development.genre, targetLUFS: development.targetLUFS,
                      integratedLUFS: result.loudness.map { ($0.integratedLUFS * 10).rounded() / 10 },
                      truePeakDBTP: result.loudness.map { ($0.truePeakDBTP * 10).rounded() / 10 },
                      masterGainDB: result.loudness.map { ($0.masterGainDB * 10).rounded() / 10 },
                      recorded: true, detail: detail)
    }
}
