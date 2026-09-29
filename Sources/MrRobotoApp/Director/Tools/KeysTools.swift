import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The keys player, appended after develop: how the chords are played.
//
// set_progression states the harmony, as a lead sheet does. This is the other half, which a lead
// sheet leaves to the player: where the notes of each chord sit, and the rhythm they are struck in.
// It is kept on the progression it plays, as a bass line keeps its hands, so the chords stay chords.

public struct PlayChordsTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var progression: String
        public var pattern: String
        public var voicing: String
        public var seed: Int
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var chords: String
        public var pattern: String
        public var voicing: String
        /// The seed it is played from, to play it the same way again.
        public var seed: Int
        /// The instrument it plays on, and whether the pattern can be heard on it.
        public var instrument: String
        /// The top note of each chord as voiced: the line the chords are heard as.
        public var topLine: [String]
        /// Semitones a voice moves, a change, as voiced.
        public var movement: Double
        public var notes: Int
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case version, part, chords, pattern, voicing, seed, instrument, movement, notes, recorded, detail
            case topLine = "top_line"
        }
    }

    let workspace: any DirectorWorkspace
    let acting: String

    public init(workspace: any DirectorWorkspace, acting: String = "Harmonist") {
        self.workspace = workspace
        self.acting = acting
    }

    public let name = "play_chords"
    public var purpose: String {
        "Say how the chords are played: the rhythm they are struck in and where the notes of each chord sit. set_progression "
        + "states which chords; this is the player's half, kept on the progression as its next version. Patterns: "
        + KeysPattern.allCases.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + ". Voicings: " + KeysVoicing.allCases.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + ". Use it when the user asks for stabs, a comp, an arpeggio, a strum, voice-leading, smoother chords, or chords that "
        + "move less; and after set_progression when the genre has a way of playing its chords."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("progression", Schema.string("The progression version to play, from read_song or set_progression; empty for the song's newest.")),
            ("pattern", Schema.string("The rhythm the chords are struck in.", enum: KeysPattern.allCases.map(\.rawValue))),
            ("voicing", Schema.string("Where the notes of each chord sit.", enum: KeysVoicing.allCases.map(\.rawValue))),
            ("seed", Schema.integer("0 for a hand nobody chose; the seed a result gave, to play it the same way again.", minimum: 0)),
        ], required: ["progression", "pattern", "voicing", "seed"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song, or open_song for one in the library.")
        }
        guard let pattern = KeysPattern(rawValue: input.pattern.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.pattern)\" is not a way of playing chords this app has.",
                                      suggestion: "One of: \(KeysPattern.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let voicing = KeysVoicing(rawValue: input.voicing.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.voicing)\" is not a voicing this app has.",
                                      suggestion: "One of: \(KeysVoicing.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let named = input.progression.trimmingCharacters(in: .whitespaces)
        let version: PartVersion
        if named.isEmpty {
            guard let newest = Guidance.progressions(in: song).last else {
                throw DirectorToolFailure(tool: name, reason: "\(song.title) has no chords to play.",
                                          suggestion: "State them with set_progression first.")
            }
            version = newest
        } else {
            guard let id = VersionID(uuidString: named), let found = song.version(id) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(named)\" is not a version in this song.",
                                          suggestion: "Take a progression's id from read_song, or leave it empty for the newest.")
            }
            version = found
        }
        guard case .progression(var progression) = version.kind else {
            throw DirectorToolFailure(tool: name, reason: "\(PartLabel.title(of: version)) is a \(version.type.rawValue), not chords.",
                                      suggestion: "Name a progression, or leave it empty for the song's newest.")
        }
        let seed: UInt64 = input.seed > 0 ? UInt64(input.seed) : GrooveFeel.freshSeed()
        let playing = ChordPlaying(pattern, voicing, seed: pattern == .held ? 0 : seed)
        progression.playing = playing.isPlain ? nil : playing

        // Built on the part's newest version, so what is heard wherever the chords play is this.
        let newest = song.latestVersion(of: version.partID) ?? version
        let spelled = progression.symbols()
        let note = "\(spelled) in \(progression.key): \(playing.sentence.lowercased())"
        let kept = newest.deriving(.progression(progression), by: .persona(acting), operation: Operation.written, note: note)
        let recorded = await workspace.record(kept)

        let instrumentID = SongPlayback.instrumentID(for: version.partID, in: song)
        let spec = InstrumentVoiceSpec.preset(id: instrumentID)
        let top = Voicing.topLine(of: progression, as: voicing).map { progression.key.name(of: Pitch(midi: $0)) }
        let movement = (Voicing.movement(of: progression, as: voicing) * 100).rounded() / 100
        let notes = Voicing.notes(for: progression).count
        var detail = recorded
            ? "\(spelled), \(playing.sentence.lowercased()), on the \(spec?.name ?? instrumentID): \(notes) notes a pass, the top line \(top.joined(separator: " ")), "
                + String(format: "the voices moving %.1f semitones a change. It plays wherever the chords play.", movement)
            : "No song would take it, so it was not recorded."
        if recorded, let spec, !pattern.suits(family: spec.family) {
            detail += " \(pattern.name) is short notes and the \(spec.name) swells into a note, so little of it will be heard: "
                + "set_instrument to a piano, an organ or a guitar, or hold the chords."
        }
        return Output(version: kept.id.description, part: kept.partID.description, chords: spelled, pattern: pattern.rawValue,
                      voicing: voicing.rawValue, seed: Int(clamping: playing.seed), instrument: spec?.name ?? instrumentID,
                      topLine: top, movement: movement, notes: notes, recorded: recorded, detail: detail)
    }
}
