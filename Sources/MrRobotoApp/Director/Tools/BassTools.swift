import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The band's first written parts: a progression stated as chord symbols, and a bass line under a
// groove in a named player's hands.
//
// Both are appended after `degrade_part`, never among the earlier tools, so every schema before
// them keeps its bytes and the session's cached prefix survives. Both have only required, plain
// parameters — no optionals, no unions — so the API's schema budget (`DirectorToolboxTests` quotes
// its refusals) does not move.

// MARK: - set_progression

/// Writes a `.progression` version from a line of chord symbols in a key.
public struct SetProgressionTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var chords: String
        public var key: String
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var key: String
        /// The progression as symbols, bars separated by `|`.
        public var chords: String
        /// The same chords as Roman numerals in the key, non-diatonic ones kept as symbols.
        public var numerals: [String]
        public var bars: Int
        public var recorded: Bool
    }

    let workspace: any DirectorWorkspace
    let acting: String

    public init(workspace: any DirectorWorkspace, acting: String = CreatePartVersionTool.director) {
        self.workspace = workspace
        self.acting = acting
    }

    public let name = "set_progression"
    public var purpose: String {
        "State the song's harmony as a lead sheet does and record it as a progression version: "
        + "\"Dm7 G7 | Cmaj7\" is two chords over bar one and one over bar two. Bars are separated by "
        + "|, and the chords in a bar share its beats. write_bassline reads the newest progression; "
        + "with none, it writes to the key."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("chords", Schema.string(
                "Chord symbols, bars separated by |: \"Dm7 G7 | Cmaj7 | Am7\". Qualities: m, 7, maj7, "
                + "m7, m7b5, dim, dim7, aug, sus2, sus4, mMaj7; a slash bass is an inversion (C/E).")),
            ("key", Schema.string(
                "The key the numerals are read in, as read_song reports it: \"D major\", \"E♭ minor\", "
                + "\"F# aeolian\".")),
        ], required: ["chords", "key"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let key = Key(parsing: input.key) ?? Key(parsing: input.key.replacingOccurrences(of: "♭", with: "b")) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.key)\" is not a key this app can read.",
                                      suggestion: "Say it as read_song does: \"D major\", \"A minor\".")
        }
        let beatsPerBar = await workspace.song?.timeSignature.beatsPerBar ?? 4
        let progression: Progression
        switch Progression.parse(input.chords, key: key, beatsPerBar: beatsPerBar) {
        case .success(let parsed): progression = parsed
        case .failure(let error):
            throw DirectorToolFailure(tool: name, reason: error.description,
                                      suggestion: "Symbols like Dm7, G7, Cmaj7, F#m7b5, Bbmaj7, C/E; bars separated by |.")
        }
        // The song's harmony is one part: new chords are its next version, heard wherever the old
        // ones played. A new part each time sat in no section once the form had chords, or — before
        // that — played on top of them.
        let existing = await workspace.song.flatMap { song in song.versions.last { $0.type == .progression } }
        let note = "\(progression.symbols()) in \(key)"
        let version = existing.map { $0.deriving(.progression(progression), by: .persona(acting), operation: Operation.written, note: note) }
            ?? PartVersion(partID: PartID(), kind: .progression(progression), author: .persona(acting),
                           operation: Operation.written, note: note)
        let recorded = await workspace.record(version)
        return Output(version: version.id.description, part: version.partID.description, key: "\(key)",
                      chords: progression.symbols(),
                      numerals: progression.chords.map { chord in
                          key.romanNumeral(for: chord).map { "\($0)" } ?? chord.symbol(preferring: key.signature.preference)
                      },
                      bars: progression.bars.count, recorded: recorded)
    }
}

// MARK: - write_bassline

/// Writes a bass line under a groove, in a named player's hands, and records it as the Bassist's.
///
/// The Bassist is asked first. `Bassist.consider(.writeBassline(…))` sees the lag, the tempo, the
/// kick's decay (from the song's kit sound) and the bass sound, and a refusal — nothing straight,
/// ahead of the kick, a played bass under an 808, past the 90 ms ceiling — is this tool's failure,
/// with the Bassist's own reason and counter as the reason and suggestion. That is the path every
/// refusal takes to the rail, so the user reads why.
///
/// What is written goes back through `BassObservation`, and the readings ride on the result: the
/// model sees the line in the Bassist's units, and the flags go to the rail in the Bassist's name.
public struct WriteBasslineTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var groove: String
        public var hands: String
        public var lagMS: Double
        public var density: Double
        public var seed: Int

        enum CodingKeys: String, CodingKey {
            case groove, hands, density, seed
            case lagMS = "lag_ms"
        }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var groove: String
        public var hands: String
        public var sound: String
        public var lagMS: Double
        public var chords: String
        public var noteCount: Int
        public var note: String
        /// Every reading the Bassist made of the line, holds and flags alike, in its own words.
        public var readings: [String]
        /// The readings that did not hold.
        public var flags: [String]
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case version, part, groove, hands, sound, chords, note, readings, flags, recorded, detail
            case lagMS = "lag_ms"
            case noteCount = "note_count"
        }
    }

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    /// Every bass line is the Bassist's, whoever holds the toolbox.
    public static let author = "Bassist"

    public let name = "write_bassline"
    public var purpose: String {
        "Write a bass line under a groove and record it as a version of a new bass part, signed by "
        + "the Bassist. Say whose hands: palladino (Voodoo — behind the kick, note-off on the beat, "
        + "roots and slides), thundercat (harmony and register, voicings on the change), or programmed "
        + "(the 808 as the bass: the kick's own pattern, re-pitched, through the sub). The Bassist "
        + "refuses when nothing is straight, when pushed ahead of the kick, and when a played bass "
        + "would sit under a kick that rings past 400 ms; its reason comes back as the error."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("groove", Schema.string("The groove version the line sits under, by id from read_song or create_part_version.")),
            ("hands", Schema.string("Whose hands write it.", enum: BassLineage.allCases.map(\.rawValue))),
            ("lag_ms", Schema.number(
                "Milliseconds behind the kick. 40 is the default and 20 to 65 the documented window; "
                + "0 is on the kick; negative is ahead of it and refused.", maximum: 90)),
            ("density", Schema.number("How busy, 0 (bare) to 1 (every attack the budget allows).", maximum: 1)),
            ("seed", Schema.integer("Any whole number. The same seed writes the same line; a different one writes another.")),
        ], required: ["groove", "hands", "lag_ms", "density", "seed"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let grooveID = VersionID(uuidString: input.groove) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.groove)\" is not a version id.",
                                      suggestion: "Take a groove's id from read_song or create_part_version.")
        }
        guard let grooveVersion = await workspace.version(grooveID), case .groove(let groove) = grooveVersion.kind else {
            throw DirectorToolFailure(tool: name, reason: "\(input.groove) is not a groove version.",
                                      suggestion: "A bass line sits under a groove; name one from read_song.")
        }
        guard let lineage = BassLineage(rawValue: input.hands.lowercased()) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.hands)\" is not a player this band has.",
                                      suggestion: "One of: \(BassLineage.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard input.lagMS.isFinite, input.density.isFinite else {
            throw DirectorToolFailure(tool: name, reason: "The lag and density have to be numbers.")
        }

        let song = await workspace.song
        let tempo = song?.tempo ?? 90
        let signature = song?.timeSignature ?? .fourFour
        let key = Guidance.analysis(in: song)?.dominantKey ?? song?.key ?? Key(tonic: NoteName(.c))
        let chordVersion = song.flatMap { Guidance.progressions(in: $0).last }
        var chords: [ChordSpan] = []
        if let chordVersion, case .progression(let p) = chordVersion.kind { chords = p.spans }
        let kickDecay = SurfaceWiring.kickDecay(in: song)
        let sound = lineage.defaultSound

        // The Bassist first.
        let verdict = Bassist().consider(.writeBassline(lineage: lineage.rawValue, lagMS: input.lagMS, tempo: tempo,
                                                        hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: kickDecay,
                                                        sound: sound))
        if case .refuse(let rule, let because, let counter) = verdict {
            // The reason first and on its own: the rail keeps a failure's first sentence, and a
            // rule id carries a full stop, so it goes with the suggestion.
            throw DirectorToolFailure(tool: name, reason: "The Bassist: \(because)",
                                      suggestion: "Nothing was written. \(counter) (Rule \(rule).)")
        }
        var lag = input.lagMS
        if case .agreeWithCaveat = verdict, tempo >= Bassist.houseTempoBPM {
            lag = min(lag, Bassist.houseLagCapMS)
        }

        let request = BassRequest(key: key, chords: chords, groove: groove, tempo: tempo, timeSignature: signature,
                                  lineage: lineage, lagMS: lag, density: min(1, max(0, input.density)),
                                  sound: sound, seed: UInt64(truncatingIfNeeded: input.seed))
        let line = BassWriter.write(request)
        let observation = BassObservation(label: "\(lineage.name) line", bassline: line, groove: groove,
                                          chords: chords, tempo: tempo, timeSignature: signature,
                                          kickDecaySeconds: kickDecay)
        let readings = Bassist().read(observation)
        let flags = readings.filter { !$0.holds }

        var noteParts = ["\(lineage.name) line"]
        if lag != 0 { noteParts.append(String(format: "%+.0f ms behind the kick", lag)) }
        noteParts.append(String(format: "%.0f bpm", tempo))
        noteParts.append(BassVoiceSpec.all.first { $0.id == sound }?.name ?? sound)
        noteParts.append(chords.isEmpty ? "to the key's I–IV–V–I" : "over \(chordVersion.map { PartLabel.title(of: $0) } ?? "the progression")")
        let version = PartVersion(partID: PartID(), kind: .bassline(line), author: .persona(Self.author),
                                  parents: [grooveVersion.id], operation: Operation.written,
                                  note: noteParts.joined(separator: ", "))
        let recorded = await workspace.record(version)
        if recorded, !flags.isEmpty {
            await workspace.note("The Bassist: " + flags.map(\.says).joined(separator: " "), detail: version.note)
        }
        return Output(version: version.id.description, part: version.partID.description,
                      groove: grooveVersion.id.description, hands: lineage.rawValue, sound: sound, lagMS: lag,
                      chords: chords.isEmpty ? "none stated: the key's I–IV–V–I in \(key)"
                                             : chords.map { $0.chord.symbol(preferring: key.signature.preference) }.joined(separator: " "),
                      noteCount: line.notes.count, note: version.note ?? "",
                      readings: readings.map(\.says), flags: flags.map(\.says), recorded: recorded,
                      detail: recorded
                          ? "Open the Piano roll on \(version.id.description) to see it over the kicks, or a Compare of "
                              + "several lines with the groove as the reference."
                          : "No song is open, so this was not recorded anywhere.")
    }
}
