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
        /// A section's id or name for chords of its own there; empty for the song's chords everywhere.
        public var section: String

        public init(chords: String, key: String, section: String = "") {
            self.chords = chords
            self.key = key
            self.section = section
        }

        enum CodingKeys: String, CodingKey { case chords, key, section }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chords = try c.decode(String.self, forKey: .chords)
            key = try c.decode(String.self, forKey: .key)
            section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        }
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
        /// What the Harmonist would say first about the sheet: the readings that did not hold.
        public var flags: [String]
        /// The sections that play these as their own chords; empty when they are the song's.
        public var sections: [String] = []
        /// What became of the bass in those sections: "moved to follow", "already on these chords",
        /// "no bass line"; empty for the song's chords, whose bass write_bassline writes.
        public var bass: String = ""
        /// Where the chords play and what they replaced, in a sentence.
        public var detail: String = ""
    }

    let workspace: any DirectorWorkspace
    let acting: String

    public init(workspace: any DirectorWorkspace, acting: String = CreatePartVersionTool.director) {
        self.workspace = workspace
        self.acting = acting
    }

    public let name = "set_progression"
    public var purpose: String {
        "State chords as a lead sheet does and record them: \"Dm7 G7 | Cmaj7\" is two chords over bar one "
        + "and one over bar two. Bars are separated by |, and the chords in a bar share its beats. With section "
        + "empty they are the song's chords: the next version of its chord part, so they REPLACE the chords in "
        + "every section that plays them (the old ones stay in the ledger). With a section named they are that "
        + "section's own chords: a variation of the chord part that plays only there, on the same strip, with "
        + "the bass line there moved to follow, its rhythm kept — every other section keeps its chords. So when "
        + "the user wants other chords for one part of the song (\"these for the intro\", \"add these chords\" to "
        + "a song that has some), name the section; for a new section with chords of its own, stitch_section it "
        + "first, then name it here. Naming a section again rewrites its own chords. write_bassline reads the "
        + "song's chords; with none, it writes to the key. The Harmonist's flags on the sheet come back: among "
        + "them, that the loop is the usual one, or the one another song here goes round. Those are not errors; "
        + "reharmonize offers ways out to hear."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("chords", Schema.string(
                "Chord symbols, bars separated by |: \"Dm9 G13 | Cmaj9 | Am7\". Qualities: m, 7, maj7, m7, m7b5, dim, "
                + "dim7, aug, sus2, sus4, mMaj7; 6, m6, 6/9, add9, maj9, 9, m9, 11, m11, maj7#11, 13, maj13, m13; 7b9, 7#9, "
                + "7#11, 7b13, 7#5, 7b5, 7sus4, 9sus4; 5. A slash bass is an inversion (C/E).")),
            ("key", Schema.string(
                "The key the numerals are read in, as read_song reports it: \"D major\", \"E♭ minor\", "
                + "\"F# aeolian\".")),
            ("section", Schema.string(
                "Empty for the song's chords, replacing them everywhere. A section's id or name — \"intro\", \"Verse 2\" — "
                + "for chords of its own there, the rest of the song keeping its; of several with one name, all of them.")),
        ], required: ["chords", "key", "section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let key = Key(parsing: input.key) ?? Key(parsing: input.key.replacingOccurrences(of: "♭", with: "b")) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.key)\" is not a key this app can read.",
                                      suggestion: "Say it as read_song does: \"D major\", \"A minor\".")
        }
        let beatsPerBar = await workspace.song?.timeSignature.beatsPerBar ?? 4
        var progression: Progression
        switch Progression.parse(input.chords, key: key, beatsPerBar: beatsPerBar) {
        case .success(let parsed): progression = parsed
        case .failure(let error):
            throw DirectorToolFailure(tool: name, reason: error.description,
                                      suggestion: "Symbols like Dm7, G13, Cmaj9, F#m7b5, Bbmaj7, E7#9, C6/9, C/E; bars separated by |. "
                                          + "A slash bass has to be a note of the chord.")
        }
        // The song's harmony is one part: new chords are its next version, heard wherever the old
        // ones played. A new part each time sat in no section once the form had chords, or — before
        // that — played on top of them. A section's own chords are a variation of it, below.
        let existing = await workspace.song.flatMap { song in Guidance.progressions(in: song).last }
        let named = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        var output: Output
        if !named.isEmpty, let song = await workspace.song {
            output = try await own(progression, key: key, in: try SectionNaming.resolve(named, in: song, tool: name), of: song, root: existing)
        } else {
            // New chords, the same player: how they were played stays, until play_chords says otherwise.
            if let existing, case .progression(let before) = existing.kind { progression.playing = before.playing }
            let note = "\(progression.symbols()) in \(key)" + (progression.playing.map { ": \($0.sentence.lowercased())" } ?? "")
            let version = existing.map { $0.deriving(.progression(progression), by: .persona(acting), operation: Operation.written, note: note) }
                ?? PartVersion(partID: PartID(), kind: .progression(progression), author: .persona(acting),
                               operation: Operation.written, note: note)
            let recorded = await workspace.record(version)
            var was: String?
            if let existing, case .progression(let before) = existing.kind { was = before.symbols() }
            output = Output(version: version.id.description, part: version.partID.description, key: "\(key)", chords: progression.symbols(),
                            numerals: [], bars: progression.bars.count, recorded: recorded, flags: [],
                            detail: was.map { "\(progression.symbols()) replaces \($0) in every section that played it; the old chords stay in the ledger. "
                                + "For chords of one section's own, name the section." } ?? "\(progression.symbols()) are the song's chords.")
        }
        var observation = HarmonyObservation.of(progression, label: "\(progression.symbols()) in \(key)", beatsPerBar: beatsPerBar)
        observation.before = SongsBefore.of(await workspace.library, besides: await workspace.song?.id)
        output.flags = (await workspace.houseBook).settle(
            GenreLens.judge(Harmonist().read(observation), by: Harmonist.bible, in: await workspace.genreLens),
            by: Harmonist.bible).filter { !$0.holds }.map(\.says)
        output.numerals = progression.chords.map { chord in key.romanNumeral(for: chord).map { "\($0)" } ?? chord.symbol(in: key) }
        return output
    }

    /// The chords as the named sections' own: in each, a variation of the song's chord part plays
    /// them in place of what it played, each other player of chords there follows on its own
    /// variation, and the bass there is moved to follow, its rhythm kept. A section already playing
    /// chords of its own that no other section plays has them rewritten: their next version.
    func own(_ progression: Progression, key: Key, in sections: [Section], of song: Song, root: PartVersion?) async throws -> Output {
        let author: Author = .persona(acting)
        let bassAuthor: Author = .persona(WriteBasslineTool.author)
        let beats = song.timeSignature.beatsPerBar
        let symbols = progression.symbols()
        var working = song
        var arranged = song.sections
        var versions: [PartVersion] = []
        var placed: [String] = []
        var replaced: [String] = []
        var bassSays = ReharmonizeTool.noBass
        var first: PartVersion?

        /// What plays a part here and nowhere else: a section's own, to be rewritten in place.
        func onlyIn(_ section: SectionID, _ part: PartID) -> Bool {
            !arranged.contains { $0.id != section && $0.stitch.contains { $0.part == part } }
        }
        /// The chords (or the line) written for this section: the next version of its own part —
        /// one placed there and played nowhere else — or a new variation of the part it varies,
        /// named for the section. One developing wrote is not taken over: developing again would
        /// write over it.
        func write(_ kind: PartKind, over lane: (lane: Lane, version: PartVersion, root: PartID)?, root: PartVersion?, in section: Section,
                   note: String, by who: Author, suffix: String = "") -> PartID? {
            if let lane, lane.lane.part != lane.root, onlyIn(section.id, lane.lane.part), Develop.isHeld(lane.lane, in: working),
               let mine = working.latestVersion(of: lane.lane.part) {
                let version = mine.deriving(kind, by: who, operation: Operation.written, note: note)
                versions.append(version); try? working.append(version)
                return version.partID
            }
            guard let root else { return nil }
            let made = AnotherWay.variation(of: root, named: section.name.lowercased() + suffix, kind: kind, note: note, by: who, in: working)
            if let version = made.version { versions.append(version); try? working.append(version) }
            return made.part
        }

        for section in sections {
            guard let index = arranged.firstIndex(where: { $0.id == section.id }) else { continue }
            let chords = AnotherWay.lane(of: .progression, in: arranged[index], of: working)
            var own = progression
            // The same player as the chords it replaces there, until play_chords says otherwise.
            if let chords, case .progression(let before) = chords.version.kind {
                own.playing = before.playing
                replaced.append(before.symbols())
            } else if let root, case .progression(let before) = root.kind {
                own.playing = before.playing
            }
            let note = "\(symbols) in \(key), the \(section.name.lowercased())'s own" + (own.playing.map { ": \($0.sentence.lowercased())" } ?? "")
            let chordRoot = chords.flatMap { working.latestVersion(of: $0.root) } ?? root
            let part: PartID
            if let written = write(.progression(own), over: chords, root: chordRoot, in: section, note: note, by: author) {
                part = written
            } else {
                // A song with no chords at all: a part of its own, playing only here.
                let version = PartVersion(partID: PartID(), kind: .progression(own), author: author, operation: Operation.written, note: note)
                versions.append(version); try? working.append(version)
                part = version.partID
            }
            if first == nil { first = working.latestVersion(of: part) }
            if let chords {
                arranged[index].stitch = arranged[index].stitch.map { $0.part == chords.lane.part ? Lane(part: part) : $0 }
            } else {
                arranged[index].stitch.append(Lane(part: part))
            }
            // Whoever else plays chords there follows, each its own way: a guitar left on the old
            // sheet under the keys' new one is two harmonies at once.
            for lane in arranged[index].stitch where lane.part != part {
                guard let version = working.version(playing: lane), case .progression(let theirs) = version.kind,
                      let theirRoot = working.latestVersion(of: working.variation(of: lane.part)?.of ?? lane.part) else { continue }
                var followed = progression
                followed.playing = theirs.playing
                let them = (lane: lane, version: version, root: working.variation(of: lane.part)?.of ?? lane.part)
                guard let also = write(.progression(followed), over: them, root: theirRoot, in: section,
                                       note: "\(PartLabel.title(of: theirRoot)): \(symbols), the \(section.name.lowercased())'s own", by: author) else { continue }
                arranged[index].stitch = arranged[index].stitch.map { $0.part == lane.part ? Lane(part: also) : $0 }
            }
            // The bass there, moved onto these chords from the ones it was written to.
            let from: Progression? = {
                if case .progression(let before)? = chords?.version.kind { return before }
                if case .progression(let before)? = root?.kind { return before }
                return nil
            }()
            if let bass = AnotherWay.lane(of: .bassline, in: arranged[index], of: working), case .bassline(let line) = bass.version.kind {
                if bassSays == ReharmonizeTool.noBass { bassSays = ReharmonizeTool.bassFits }
                if let from, let followed = Develop.refit(line, from: from, to: progression, beatsPerBar: beats),
                   let under = write(.bassline(followed), over: bass, root: working.latestVersion(of: bass.root), in: section,
                                     note: "Follows \(symbols), the \(section.name.lowercased())'s own chords", by: bassAuthor, suffix: "-bass") {
                    arranged[index].stitch = arranged[index].stitch.map { $0.part == bass.lane.part ? Lane(part: under) : $0 }
                    bassSays = ReharmonizeTool.bassMoved
                }
            }
            placed.append(section.name)
        }
        let where_ = placed.joined(separator: ", ")
        guard !placed.isEmpty, await workspace.keep(versions, arranged: arranged, mix: nil, saying: "\(where_): \(symbols)",
                                                     detail: "Chords of its own; the rest of the song keeps its") else {
            throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
        }
        let was = Array(Set(replaced)).sorted().joined(separator: " and ")
        let rest = song.sections.count > placed.count ? " The rest of the song keeps its chords." : ""
        return Output(version: first?.id.description ?? "", part: first?.partID.description ?? "", key: "\(key)", chords: symbols,
                      numerals: [], bars: progression.bars.count, recorded: true, flags: [], sections: placed, bass: bassSays,
                      detail: "\(where_) plays \(symbols) as its own chords" + (was.isEmpty ? "" : " in place of \(was)") + "." + rest
                          + ReharmonizeTool.sentence(bassSays) + " compare_section plays it against how it stood.")
    }
}

// MARK: - write_bassline

extension WriteBasslineTool {
    /// How long a line is under stated chords that outlast the groove: as long as the chords, in
    /// whole turns of the groove, sixteen bars at most. Nil is the groove's own length.
    ///
    /// A line used to be as long as the groove whatever the chords: under four bars of chords and
    /// a two-bar break it was two bars, which put the first two chords' roots under all four.
    static func bars(under chords: [ChordSpan], over groove: Groove, in meter: TimeSignature) -> Int? {
        let beats = chords.reduce(0) { $0 + $1.beats }
        let loop = max(1, groove.bars)
        let stated = Int((beats / Double(max(1, meter.beatsPerBar))).rounded(.up))
        guard stated > loop else { return nil }
        return min(16, Int((Double(stated) / Double(loop)).rounded(.up)) * loop)
    }
}

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
        /// 0 draws one nobody chose. Asked to pick "any number", a model picks the same few, and
        /// the same seed is the same line: a year of songs would have had four bass lines.
        public var seed: Int
        /// The bass it is played on; empty is the hands' own.
        public var sound: String

        enum CodingKeys: String, CodingKey {
            case groove, hands, density, seed, sound
            case lagMS = "lag_ms"
        }

        public init(groove: String, hands: String, lagMS: Double, density: Double, seed: Int, sound: String = "") {
            self.groove = groove
            self.hands = hands
            self.lagMS = lagMS
            self.density = density
            self.seed = seed
            self.sound = sound
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            groove = try values.decode(String.self, forKey: .groove)
            hands = try values.decode(String.self, forKey: .hands)
            lagMS = try values.decode(Double.self, forKey: .lagMS)
            density = try values.decode(Double.self, forKey: .density)
            seed = try values.decode(Int.self, forKey: .seed)
            // Absent in every call written before the tool took one.
            sound = try values.decodeIfPresent(String.self, forKey: .sound) ?? ""
        }
    }

    public struct Output: Encodable, Sendable {
        public var version: String
        public var part: String
        public var groove: String
        public var hands: String
        /// The seed the line was written from, to write the same one again.
        public var seed: Int
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
            case version, part, groove, hands, seed, sound, chords, note, readings, flags, recorded, detail
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
        + "the Bassist. Say whose hands — the genre's profile (read_genre) names the ones that fit: "
        + BassLineage.allCases.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + ". The Bassist refuses when nothing is straight, when pushed ahead of the kick, and when a played bass "
        + "would sit under a kick that rings past 400 ms; its reason comes back as the error. Each player has a "
        + "bass of their own; name a sound to put the line on another, and where the song's instruments are "
        + "recordings, on a recorded bass (an id beginning sfz-) rather than a synthesized one."
    }

    /// The basses a line can be put on: the presets, then the recorded basses in the library.
    static var sounds: [BassVoiceSpec] { BassVoiceSpec.all + PianoRollModel.importedBasses }

    public var schema: DirectorJSON {
        Schema.object([
            ("groove", Schema.string("The groove version the line sits under, by id from read_song or create_part_version.")),
            ("hands", Schema.string("Whose hands write it.", enum: BassLineage.allCases.map(\.rawValue))),
            ("lag_ms", Schema.number(
                "Milliseconds behind the kick. For palladino 40 is the default and 20 to 65 the documented window; "
                + "every other player sits on the kick, 0; negative is ahead of it and refused.", maximum: 90)),
            ("density", Schema.number("How busy, 0 (bare) to 1 (every attack the budget allows).", maximum: 1)),
            ("seed", Schema.integer("0 for a new line, which is nearly always. Only to write a line again: the seed an earlier write_bassline returned.")),
            ("sound", Schema.string("The bass it plays on; empty for the player's own. "
                                    + Self.sounds.map { "\($0.id) (\($0.name))" }.joined(separator: ", ") + ".",
                                    enum: [""] + Self.sounds.map(\.id))),
        ], required: ["groove", "hands", "lag_ms", "density", "seed", "sound"])
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
        let asked = input.sound.trimmingCharacters(in: .whitespaces).lowercased()
        guard asked.isEmpty || BassVoiceSpec.resolve(id: asked) != nil else {
            throw DirectorToolFailure(tool: name, reason: "There is no bass called \"\(input.sound)\".",
                                      suggestion: "One of: \(Self.sounds.map(\.id).joined(separator: ", ")); or empty for \(lineage.name)'s own.")
        }
        // The hands' own sound, on a recording of it when the library has one: a player's finger
        // bass is a recorded bass guitar, not the plucked-string model standing in for one.
        let ownRecording = asked.isEmpty ? RecordedSounds.bass(for: lineage.defaultSound) : nil
        let sound = asked.isEmpty ? (ownRecording?.id ?? lineage.defaultSound) : asked
        let builtInRecording = asked.isEmpty ? nil : RecordedSounds.bass(for: asked)

        // The Bassist first.
        let lens = await workspace.genreLens
        let proposal = PersonaProposal.writeBassline(lineage: lineage.rawValue, lagMS: input.lagMS, tempo: tempo,
                                                        hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: kickDecay,
                                                        sound: BassVoiceSpec.preset(id: sound) == nil
                                                            ? BassVoiceSpec.resolve(id: sound)?.name ?? sound : sound)
        let verdict = GenreLens.judge(Bassist().consider(proposal), on: proposal, by: Bassist.bible, in: lens)
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

        let seed = input.seed == 0 ? Int(GrooveFeel.freshSeed()) : input.seed
        let request = BassRequest(key: key, chords: chords, groove: groove, tempo: tempo, timeSignature: signature,
                                  lineage: lineage, lagMS: lag, density: min(1, max(0, input.density)),
                                  sound: sound, seed: UInt64(truncatingIfNeeded: seed),
                                  bars: Self.bars(under: chords, over: groove, in: signature))
        let line = BassWriter.write(request)
        // Read against the groove as the line hears it, so a bar is a bar of the line.
        let observation = BassObservation(label: "\(lineage.name) line", bassline: line, groove: request.lineGroove,
                                          chords: chords, tempo: tempo, timeSignature: signature,
                                          kickDecaySeconds: kickDecay)
        let readings = GenreLens.judge(Bassist().read(observation), by: Bassist.bible, in: lens)
        let flags = readings.filter { !$0.holds }

        var noteParts = ["\(lineage.name) line"]
        if lag != 0 { noteParts.append(String(format: "%+.0f ms behind the kick", lag)) }
        noteParts.append(String(format: "%.0f bpm", tempo))
        noteParts.append(BassVoiceSpec.resolve(id: sound)?.name ?? sound)
        noteParts.append(chords.isEmpty ? "to the key's I–IV–V–I" : "over \(chordVersion.map { PartLabel.title(of: $0) } ?? "the progression")")
        let version = PartVersion(partID: PartID(), kind: .bassline(line), author: .persona(Self.author),
                                  parents: [grooveVersion.id], operation: Operation.written,
                                  note: noteParts.joined(separator: ", "))
        let recorded = await workspace.record(version)
        if recorded, !flags.isEmpty {
            await workspace.note("The Bassist: " + flags.map(\.says).joined(separator: " "), detail: version.note)
        }
        return Output(version: version.id.description, part: version.partID.description,
                      groove: grooveVersion.id.description, hands: lineage.rawValue, seed: seed, sound: sound, lagMS: lag,
                      chords: chords.isEmpty ? "none stated: the key's I–IV–V–I in \(key)"
                                             : chords.map { $0.chord.symbol(in: key) }.joined(separator: " "),
                      noteCount: line.notes.count, note: version.note ?? "",
                      readings: readings.map(\.says), flags: flags.map(\.says), recorded: recorded,
                      detail: recorded
                          ? (ownRecording.map { "It plays on \($0.name) (\($0.id)), the recording of \(lineage.name)'s own \(lineage.defaultSound) bass. " } ?? "")
                              + (builtInRecording.map { "The \(asked) bass is synthesized, and the library has a recording that plays it: \($0.name) (\($0.id)); write it there unless a synthesized sound is the point. " } ?? "")
                              + "Open the Piano roll on \(version.id.description) to see it over the kicks, or a Compare of "
                              + "several lines with the groove as the reference."
                          : "No song is open, so this was not recorded anywhere.")
    }
}
