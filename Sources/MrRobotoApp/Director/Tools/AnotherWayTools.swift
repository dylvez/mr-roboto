import Foundation
import MusicTheory
import Performance
import SongGraph

// Two moves for a song that reads as fine and sounds like the last one: the chords said another
// way, and the tune played another way. Each is a named change made by arithmetic — a borrowed
// chord, a secondary dominant, a push over the bar line — so what comes back is what was done, in
// a sentence, and a Compare of the options is a Compare of things that differ in one way each.

/// What "the song's chords" and "the song's tune" mean to these two, in a section or in the song.
enum AnotherWay {

    /// The lane in a section that plays a part of this kind, the version it plays and the part
    /// it is a variation of (itself, when it is nobody's).
    static func lane(of type: PartType, in section: Section, of song: Song) -> (lane: Lane, version: PartVersion, root: PartID)? {
        for lane in section.stitch {
            guard let version = song.version(playing: lane), version.type == type, !Develop.isAnswer(version) else { continue }
            return (lane, version, song.variation(of: lane.part)?.of ?? lane.part)
        }
        return nil
    }

    /// A variation of `root` that plays `kind`: one placed before that plays the same, or a new
    /// part under a name no other variation of the root has. One developing wrote is not reused,
    /// though it play the same: developing may write it again, and this one is to stay.
    static func variation(of root: PartVersion, named name: String, kind: PartKind, note: String, by author: Author,
                          in song: Song) -> (part: PartID, version: PartVersion?) {
        let existing = song.variations(of: root.partID)
        if let same = existing.first(where: { part in
            song.latestVersion(of: part)?.kind == kind && song.versions.first { $0.partID == part }?.operation == Operation.placed
        }) { return (same, nil) }
        let taken = Set(existing.compactMap { song.variation(of: $0)?.name })
        var unique = name
        var count = 2
        while taken.contains(unique) { unique = "\(name)-\(count)"; count += 1 }
        // Placed, not developed: developing and shading leave it in the section it was asked for.
        let version = PartVersion(partID: PartID(), kind: kind, author: author, parents: [root.id], operation: Operation.placed,
                                  note: note, variation: Variation(of: song.variation(of: root.partID)?.of ?? root.partID, name: unique))
        return (version.partID, version)
    }

    /// How much of a tune sits on a chord sheet, by length, as a whole percentage.
    static func sits(_ tune: Melody, on sheet: Progression, key: Key, beatsPerBar: Int) -> Int {
        Int((MelodyObservation.of(tune, label: "", key: key, progression: sheet, beatsPerBar: beatsPerBar).chordToneRatio * 100).rounded())
    }

    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

// MARK: - reharmonize

/// The chords said another way: one named move, or the moves the sheet has room for, to hear.
public struct ReharmonizeTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var move: String
        public var section: String
        public var variant: Int

        public init(move: String, section: String = "", variant: Int = 0) {
            self.move = move
            self.section = section
            self.variant = variant
        }

        enum CodingKeys: String, CodingKey { case move, section, variant }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            move = try c.decodeIfPresent(String.self, forKey: .move) ?? ""
            section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
            variant = try c.decodeIfPresent(Int.self, forKey: .variant) ?? 0
        }
    }

    public struct Way: Encodable, Sendable {
        public var move: String
        public var name: String
        public var chords: String
        /// What the move did, in a sentence.
        public var says: String
        /// How much of the song's tune sits on these chords, by length, 0 to 100. Nil with no tune.
        public var tuneOnChords: Int?
        /// Whether it is a row on the Compare that was opened.
        public var onCompare: Bool

        enum CodingKeys: String, CodingKey {
            case move, name, chords, says
            case tuneOnChords = "tune_on_chords"
            case onCompare = "on_compare"
        }
    }

    public struct Output: Encodable, Sendable {
        /// The chords as they stood.
        public var was: String
        /// The chords now, when a move was made. Empty when options were offered.
        public var chords: String
        public var version: String
        public var part: String
        /// The sections that play it; empty for the whole song.
        public var sections: [String]
        /// What became of the bass under them: "moved to follow", "already on these chords" (every
        /// note it plays is a note of the new chord, so nothing had to move), or "no bass line".
        public var bass: String
        /// The ways this sheet can be said, when none was asked for.
        public var ways: [Way]
        public var opened: Bool
        public var recorded: Bool
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case was, chords, version, part, sections, bass, ways, opened, recorded, detail
        }
    }

    public static let author = "Harmonist"

    static let bassMoved = "moved to follow"
    static let bassFits = "already on these chords"
    static let noBass = "no bass line"

    /// What became of the bass, as a sentence for the answer. A bass that did not move is one that
    /// already fits: said, so nobody reads "did not move" as "still on the old chords".
    static func sentence(_ bass: String) -> String {
        switch bass {
        case bassMoved: return " The bass line was moved to follow, its rhythm kept."
        case bassFits: return " The bass line already plays notes of these chords, so it is as it was and nothing clashes."
        default: return ""
        }
    }
    /// The order the moves are offered in: the ones a listener hears as a new chord first, the
    /// ones that rearrange the same chords last.
    static let offered: [Reharmonization] = [.borrowed, .bassLine, .secondaryDominant, .passing, .tritone, .uneven, .turnaround, .rotated]

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "reharmonize"
    public var purpose: String {
        "Say the song's chords another way, by one named move, in the Harmonist's name. Use it when the Harmonist "
        + "flags the loop as the usual one or as another song's, and for \"the chords are boring\", \"something less "
        + "predictable\", \"surprise me in the last chorus\". The moves: "
        + Reharmonization.allCases.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + ". With a move, the chords are written that way — the next version of the song's chords, or with a section "
        + "named, a variation that plays only there — and the bass line is moved to follow where it has to, its rhythm kept; "
        + "the answer's bass says which: moved, or already on these chords. With move "
        + "empty nothing is written: a Compare opens on the chords as they are against up to four ways this sheet has "
        + "room for, each to be heard, and taking a row keeps it with its bass. Prefer the Compare when the user has "
        + "not said which way; say each row's sentence. The answer says how much of the tune still sits on the chords: "
        + "a move that takes the tune off them is one to hear before keeping. A move the sheet gives nothing to work "
        + "on — no dominant to substitute — is refused with the ones that apply."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("move", Schema.string("The move, or empty to open a Compare of the ways this sheet has room for.",
                                   enum: [""] + Reharmonization.allCases.map(\.rawValue))),
            ("section", Schema.string("Empty for the song's chords everywhere. A section's id or name — \"bridge\", \"Hook 3\" — "
                                      + "for a variation that plays only there; of several with one name, all of them.")),
            ("variant", Schema.integer("0 for the move's first way; 1 for its other, where it has one (a borrowed chord has two).")),
        ], required: ["move", "section", "variant"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        let beats = song.timeSignature.beatsPerBar
        let asked = input.move.trimmingCharacters(in: .whitespaces).lowercased()
        let move = Reharmonization(rawValue: asked)
        guard asked.isEmpty || move != nil else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.move)\" is not a move.",
                                      suggestion: "One of: " + Reharmonization.allCases.map(\.rawValue).joined(separator: ", ") + "; or empty for a Compare.")
        }
        let named = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = named.isEmpty ? [] : try SectionNaming.resolve(named, in: song, tool: name)

        // The chords in question: what the first of the sections plays, or the song's own. A
        // Compare is always of the song's own: taking a row makes it the song's chords.
        let standing: PartVersion?
        if move != nil, let first = sections.first {
            standing = AnotherWay.lane(of: .progression, in: first, of: song)?.version
            if standing == nil {
                throw DirectorToolFailure(tool: name, reason: "\(first.name) plays no chords.",
                                          suggestion: "stitch_section puts the chords in it; or name a section that has them.")
            }
        } else {
            standing = Guidance.progressions(in: song).last
        }
        guard let standing, case .progression(let sheet) = standing.kind else {
            throw DirectorToolFailure(tool: name, reason: "\(song.title) has no chords to say another way.",
                                      suggestion: "set_progression states them first.")
        }
        let key = sheet.key
        let was = sheet.symbols()
        let tune = Guidance.melodies(in: song).last.flatMap { version -> Melody? in
            if case .melody(let melody) = version.kind { return melody }
            return nil
        }
        func sits(_ on: Progression) -> Int? { tune.map { AnotherWay.sits($0, on: on, key: song.key ?? key, beatsPerBar: beats) } }
        let author: Author = .persona(Self.author)
        let bassAuthor: Author = .persona(WriteBasslineTool.author)

        // MARK: Options, on a Compare

        guard let move else {
            let options = Self.offered.compactMap { Reharmonize.apply($0, to: sheet) }
            guard !options.isEmpty else {
                throw DirectorToolFailure(tool: name, reason: "\(was) gives none of the moves anything to work on.",
                                          suggestion: "A sheet of one chord has nowhere to go; set_progression writes more.")
            }
            let shown = Array(options.prefix(CompareModel.maximumCandidates))
            let root = song.latestVersion(of: song.variation(of: standing.partID)?.of ?? standing.partID) ?? standing
            let bass = Guidance.basslines(in: song).last
            func departures(_ p: Progression) -> CompareReading {
                CompareReading(.harmonyDepartures, Double(HarmonyObservation.of(p, label: "", beatsPerBar: beats).departures.count), unit: "of its own")
            }
            let candidates = shown.map { option -> CompareCandidate in
                let note = "\(option.progression.symbols()) in \(key): \(option.move.name.lowercased())"
                // Taken from a Compare, it is the song's chords: the next version of the part they are.
                let version = root.deriving(.progression(option.progression), by: author, operation: Operation.reharmonize, note: note)
                var candidate = CompareCandidate(id: option.move.rawValue, title: "\(option.move.name): \(option.progression.symbols())",
                                                 proposedBy: .harmonist, rationale: option.says,
                                                 readings: [departures(option.progression)], version: version)
                if let bass, case .bassline(let line) = bass.kind,
                   let followed = Develop.refit(line, from: sheet, to: option.progression, beatsPerBar: beats) {
                    candidate.companions = [bass.deriving(.bassline(followed), by: bassAuthor, operation: Operation.reharmonize,
                                                          note: "Follows \(option.progression.symbols())")]
                }
                return candidate
            }
            let brief = CompareBrief(title: "\(was), another way",
                                     reference: CompareReference(title: "\(was), as it is", kind: "the chords the song plays",
                                                                 readings: [departures(sheet)], version: standing.id),
                                     candidates: candidates, features: [.harmonyDepartures], vocabulary: Harmonist.bible)
            let opened = await workspace.openCompare(brief)
            let ways = options.map { option in
                Way(move: option.move.rawValue, name: option.move.name, chords: option.progression.symbols(), says: option.says,
                    tuneOnChords: sits(option.progression), onCompare: opened && shown.contains { $0.move == option.move })
            }
            let list = ways.map { "\($0.name): \($0.chords)" }.joined(separator: "; ")
            return Output(was: was, chords: "", version: "", part: standing.partID.description, sections: [], bass: "",
                          ways: ways, opened: opened, recorded: false,
                          detail: (opened ? "The Compare is open on \(was) against \(AnotherWay.count(shown.count, "way")) of saying it. "
                                          : "Nothing was written. ")
                              + "\(list). Taking a row makes it the song's chords everywhere, with the bass moved to follow. "
                              + "For one section only, call reharmonize with the move and the section.")
        }

        // MARK: One move, written

        guard let made = Reharmonize.apply(move, to: sheet, variant: max(0, input.variant)) ?? (input.variant > 0 ? Reharmonize.apply(move, to: sheet) : nil) else {
            let apply = Self.offered.filter { Reharmonize.apply($0, to: sheet) != nil }.map(\.rawValue)
            throw DirectorToolFailure(tool: name, reason: "\(was) gives \(move.name.lowercased()) nothing to work on.",
                                      suggestion: apply.isEmpty ? "None of the moves applies to this sheet." : "These apply: \(apply.joined(separator: ", ")).")
        }
        let now = made.progression.symbols()
        let note = "\(now) in \(key): \(move.name.lowercased())"
        var tuneLine = ""
        if let before = sits(sheet), let after = sits(made.progression) {
            tuneLine = before == after ? " The tune sits on \(after)% of them by length, as it did."
                                       : " The tune sat on \(before)% of the old chords by length and sits on \(after)% of these."
        }

        if sections.isEmpty {
            let root = song.latestVersion(of: standing.partID) ?? standing
            let version = root.deriving(.progression(made.progression), by: author, operation: Operation.reharmonize, note: note)
            guard await workspace.record(version) else {
                throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
            }
            var bassSays = Self.noBass
            if let bass = Guidance.basslines(in: song).last, case .bassline(let line) = bass.kind {
                bassSays = Self.bassFits
                if let followed = Develop.refit(line, from: sheet, to: made.progression, beatsPerBar: beats),
                   await workspace.record(bass.deriving(.bassline(followed), by: bassAuthor, operation: Operation.reharmonize,
                                                        note: "Follows \(now)")) {
                    bassSays = Self.bassMoved
                }
            }
            await workspace.speak(Self.author, made.says, detail: move.name)
            // What was written from the old sheet and still plays it.
            let stale = song.sections.filter { section in
                section.stitch.contains { lane in
                    guard let variation = song.variation(of: lane.part), let version = song.version(playing: lane) else { return false }
                    return (version.type == .progression || version.type == .bassline) && variation.of != lane.part
                }
            }
            let staleLine = stale.isEmpty ? "" : " \(AnotherWay.count(stale.count, "section")) "
                + "(\(stale.map(\.name).joined(separator: ", "))) play\(stale.count == 1 ? "s" : "") a variation written from the old chords; develop writes those again from these."
            return Output(was: was, chords: now, version: version.id.description, part: version.partID.description, sections: [],
                          bass: bassSays, ways: [], opened: false, recorded: true,
                          detail: "\(was) is now \(now). \(made.says)" + Self.sentence(bassSays) + tuneLine + staleLine)
        }

        // In the sections named: a variation of the chords, and of the bass that follows them.
        var versions: [PartVersion] = []
        var arranged = song.sections
        var working = song
        var placed: [String] = []
        var bassSays = Self.noBass
        for section in sections {
            guard let index = arranged.firstIndex(where: { $0.id == section.id }),
                  let chords = AnotherWay.lane(of: .progression, in: arranged[index], of: working),
                  case .progression(let own) = chords.version.kind,
                  let way = Reharmonize.apply(move, to: own, variant: max(0, input.variant)) ?? Reharmonize.apply(move, to: own),
                  let root = working.latestVersion(of: chords.root) else { continue }
            let made = AnotherWay.variation(of: root, named: move.rawValue, kind: .progression(way.progression),
                                            note: "\(way.progression.symbols()) in \(key): \(move.name.lowercased())", by: author, in: working)
            if let version = made.version { versions.append(version); try? working.append(version) }
            arranged[index].stitch = arranged[index].stitch.map { $0.part == chords.lane.part ? Lane(part: made.part) : $0 }
            if let bass = AnotherWay.lane(of: .bassline, in: arranged[index], of: working), case .bassline(let line) = bass.version.kind {
                if bassSays == Self.noBass { bassSays = Self.bassFits }
                if let followed = Develop.refit(line, from: own, to: way.progression, beatsPerBar: beats),
                   let bassRoot = working.latestVersion(of: bass.root) {
                    let under = AnotherWay.variation(of: bassRoot, named: "under-\(move.rawValue)", kind: .bassline(followed),
                                                     note: "Follows \(way.progression.symbols())", by: bassAuthor, in: working)
                    if let version = under.version { versions.append(version); try? working.append(version) }
                    arranged[index].stitch = arranged[index].stitch.map { $0.part == bass.lane.part ? Lane(part: under.part) : $0 }
                    bassSays = Self.bassMoved
                }
            }
            placed.append(section.name)
        }
        guard !placed.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "None of \(sections.map(\.name).joined(separator: ", ")) plays chords this move works on.")
        }
        let where_ = placed.joined(separator: ", ")
        guard await workspace.keep(versions, arranged: arranged, mix: nil, saying: "\(where_): \(now)", detail: made.says) else {
            throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
        }
        await workspace.speak(Self.author, made.says, detail: "\(move.name), in \(where_)")
        return Output(was: was, chords: now, version: versions.first?.id.description ?? "", part: versions.first?.partID.description ?? "",
                      sections: placed, bass: bassSays, ways: [], opened: false, recorded: true,
                      detail: "\(where_) plays \(now) where the song plays \(was). \(made.says)" + Self.sentence(bassSays) + tuneLine
                          + " The rest of the song is as it was; compare_section plays the section against how it stood.")
    }
}

// MARK: - vary_tune

/// The tune played another way: one treatment, or the treatments it has room for, to hear.
public struct VaryTuneTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var treatment: String
        public var section: String

        public init(treatment: String, section: String = "") {
            self.treatment = treatment
            self.section = section
        }

        enum CodingKeys: String, CodingKey { case treatment, section }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            treatment = try c.decodeIfPresent(String.self, forKey: .treatment) ?? ""
            section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        }
    }

    public struct Way: Encodable, Sendable {
        public var treatment: String
        public var what: String
        public var bars: Int
        public var onCompare: Bool

        enum CodingKeys: String, CodingKey {
            case treatment, what, bars
            case onCompare = "on_compare"
        }
    }

    public struct Output: Encodable, Sendable {
        public var tune: String
        public var treatment: String
        public var version: String
        public var part: String
        public var sections: [String]
        public var ways: [Way]
        public var opened: Bool
        public var recorded: Bool
        public var detail: String
    }

    /// The line that answers the tune in its rests: a part of its own, not the tune another way.
    static let answers = "answers"
    /// The order the treatments are offered in: the ones that change what the tune says first.
    static let offered: [TuneTreatment] = [.pushed, .sequenced, .answered, .lift, .sparse]

    let workspace: any DirectorWorkspace

    public init(workspace: any DirectorWorkspace) { self.workspace = workspace }

    public let name = "vary_tune"
    public var purpose: String {
        "Play the song's tune another way without writing a new one, in the Melodist's name. Use it when the Melodist "
        + "flags the tune as plain or as coming in the way another song's does, and for \"the melody is the same every "
        + "time\", \"do something with the second chorus\", \"it needs an answer\". The treatments: "
        + Self.offered.map { "\($0.rawValue) (\($0.about))" }.joined(separator: "; ")
        + "; and answers (a second line of its own that says the tune's phrase endings again in its rests, an octave "
        + "away and under it). With a treatment and a section, a variation of the tune is written and that section "
        + "plays it, the rest of the song as it was; with a treatment and no section, the tune itself is written that "
        + "way, everywhere. answers needs a section. With treatment empty nothing is written: a Compare opens on the "
        + "tune against the ways it has room for, each to be heard. A treatment the tune gives nothing to work on — no "
        + "note on a bar line to push, no rest long enough to answer in — is refused with the ones that apply. "
        + "write_melody writes a different tune; this keeps the one the song has."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("treatment", Schema.string("The treatment, or empty to open a Compare of the ways the tune has room for.",
                                        enum: [""] + Self.offered.map(\.rawValue) + [Self.answers])),
            ("section", Schema.string("A section's id or name for a variation that plays only there; of several with one name, "
                                      + "all of them. Empty to write the tune itself that way.")),
        ], required: ["treatment", "section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open.", suggestion: "Call start_song or open_song first.")
        }
        let beats = song.timeSignature.beatsPerBar
        let asked = input.treatment.trimmingCharacters(in: .whitespaces).lowercased()
        let treatment = TuneTreatment(rawValue: asked)
        guard asked.isEmpty || asked == Self.answers || treatment != nil else {
            throw DirectorToolFailure(tool: name, reason: "\"\(input.treatment)\" is not a treatment.",
                                      suggestion: "One of: " + (Self.offered.map(\.rawValue) + [Self.answers]).joined(separator: ", ") + "; or empty for a Compare.")
        }
        let named = input.section.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = named.isEmpty ? [] : try SectionNaming.resolve(named, in: song, tool: name)

        // The tune in question: the one the first section plays, or the song's own.
        let inSection = sections.lazy.compactMap { AnotherWay.lane(of: .melody, in: $0, of: song) }.first
        let root = inSection.flatMap { song.latestVersion(of: $0.root) } ?? Guidance.melodies(in: song).last
        guard let root, case .melody(let tune) = root.kind, !tune.notes.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "\(song.title) has no tune to play another way.",
                                      suggestion: "write_melody writes one first.")
        }
        let title = PartLabel.title(of: root)
        let loop = tune.loopBars(beatsPerBar: beats)
        let key = song.key ?? Guidance.progressions(in: song).last.flatMap { version -> Key? in
            if case .progression(let p) = version.kind { return p.key }
            return nil
        }
        let spans = Guidance.progressions(in: song).last.flatMap { version -> [ChordSpan]? in
            if case .progression(let p) = version.kind { return p.spans }
            return nil
        } ?? []
        let author: Author = .persona(WriteMelodyTool.author)
        func vary(_ treatment: TuneTreatment, bars: Int) -> Melody? {
            TuneVariation.vary(tune, as: treatment, bars: bars, beatsPerBar: beats, key: key, chords: spans)
        }
        func applying() -> [String] {
            Self.offered.filter { vary($0, bars: loop * 2) != nil }.map(\.rawValue)
                + (TuneVariation.answers(to: tune, beatsPerBar: beats) == nil ? [] : [Self.answers])
        }
        func refused(_ what: String) -> DirectorToolFailure {
            let apply = applying()
            return DirectorToolFailure(tool: name, reason: "\(title) gives \(what) nothing to work on.",
                                       suggestion: apply.isEmpty ? "None of the treatments applies to this tune; write_melody writes another."
                                                                 : "These apply: \(apply.joined(separator: ", ")).")
        }

        // MARK: Options, on a Compare

        if asked.isEmpty {
            let options = Self.offered.compactMap { treatment in vary(treatment, bars: loop * 2).map { (treatment, $0) } }
            guard !options.isEmpty else { throw refused("any treatment") }
            let shown = Array(options.prefix(CompareModel.maximumCandidates))
            func readings(_ melody: Melody) -> [CompareReading] {
                let read = MelodyObservation(label: "", key: key ?? Key.cMajor, beatsPerBar: beats, notes: melody.notes,
                                             chords: Self.starts(of: spans))
                return [CompareReading(.melodySurprises, Double(read.surprises.count), unit: "of its own"),
                        CompareReading(.chordToneRatio, read.chordToneRatio, unit: "on the chords")]
            }
            let candidates = shown.map { treatment, melody -> CompareCandidate in
                let twice = (melody.lengthInBars ?? 0) > loop
                let version = root.deriving(.melody(melody), by: author, operation: Operation.written,
                                            note: "\(Develop.tuneTitle(treatment, twice: twice)) of \(title)")
                return CompareCandidate(id: treatment.rawValue, title: "\(Develop.tuneTitle(treatment, twice: twice)) of \(title)",
                                        proposedBy: .melodist, rationale: treatment.about.prefix(1).uppercased() + treatment.about.dropFirst() + ".",
                                        readings: readings(melody), version: version)
            }
            let brief = CompareBrief(title: "\(title), another way",
                                     reference: CompareReference(title: "\(title), as it is", kind: "the tune the song plays",
                                                                 readings: readings(tune), version: root.id),
                                     candidates: candidates, features: [.melodySurprises, .chordToneRatio], vocabulary: Melodist.bible)
            let opened = await workspace.openCompare(brief)
            let ways = options.map { treatment, melody in
                Way(treatment: treatment.rawValue, what: treatment.about, bars: melody.loopBars(beatsPerBar: beats),
                    onCompare: opened && shown.contains { $0.0 == treatment })
            }
            return Output(tune: title, treatment: "", version: "", part: root.partID.description, sections: [], ways: ways,
                          opened: opened, recorded: false,
                          detail: (opened ? "The Compare is open on \(title) against \(AnotherWay.count(shown.count, "way")) of playing it. "
                                          : "Nothing was written. ")
                              + ways.map { "\($0.treatment): \($0.what)" }.joined(separator: "; ")
                              + ". Taking a row makes it the tune, everywhere. For one section only, call vary_tune with the treatment and the section.")
        }

        // MARK: A line that answers it

        if asked == Self.answers {
            guard !sections.isEmpty else {
                throw DirectorToolFailure(tool: name, reason: "A line that answers the tune goes in one place, and no section was named.",
                                          suggestion: "Name the section: the last hook is where it usually goes.")
            }
            guard let line = TuneVariation.answers(to: tune, beatsPerBar: beats) else { throw refused("an answering line") }
            let note = Develop.answerNote(to: root)
            var versions: [PartVersion] = []
            let part: PartID
            if let existing = Develop.loop(of: song).first(where: { Develop.isAnswer($0) }) {
                part = existing.partID
                if existing.kind != .melody(line) {
                    versions.append(existing.deriving(.melody(line), by: author, operation: Operation.developed, note: note))
                }
            } else {
                let version = PartVersion(partID: PartID(), kind: .melody(line), author: author, operation: Operation.developed, note: note)
                versions.append(version)
                part = version.partID
            }
            var arranged = song.sections
            var mix = Guidance.mix(in: song) ?? Mix()
            var placed: [String] = []
            for section in sections {
                guard let index = arranged.firstIndex(where: { $0.id == section.id }),
                      AnotherWay.lane(of: .melody, in: arranged[index], of: song) != nil else { continue }
                if !arranged[index].stitch.contains(part: part) { arranged[index].stitch.append(Lane(part: part)) }
                if !mix.sectionGains.contains(where: { $0.section == section.id && $0.part == part }) {
                    mix.sectionGains.append(SectionGain(section: section.id, part: part,
                                                        gainDB: (mix.strip(for: part)?.gainDB ?? 0) + Develop.answeringLevel))
                }
                placed.append(section.name)
            }
            guard !placed.isEmpty else {
                throw DirectorToolFailure(tool: name, reason: "\(sections.map(\.name).joined(separator: ", ")) plays no tune for a line to answer.",
                                          suggestion: "Name a section the tune is in.")
            }
            let where_ = placed.joined(separator: ", ")
            guard await workspace.keep(versions, arranged: arranged, mix: mix, saying: "\(where_): a line answers \(title)",
                                       detail: "Its phrase endings again in the rests, an octave away, \(Int(-Develop.answeringLevel)) dB under it.") else {
                throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
            }
            return Output(tune: title, treatment: Self.answers, version: versions.first?.id.description ?? "", part: part.description,
                          sections: placed, ways: [], opened: false, recorded: true,
                          detail: "A line answers \(title) in \(where_): \(AnotherWay.count(line.notes.count, "note")), the tune's phrase endings again "
                              + "in its rests, an octave away and \(Int(-Develop.answeringLevel)) dB under it. It is a part of its own, on its own strip; "
                              + "set_instrument gives it another sound.")
        }

        // MARK: One treatment, written

        guard let treatment else { throw refused("that") }

        if sections.isEmpty {
            guard let varied = vary(treatment, bars: loop * 2) else { throw refused(treatment.word) }
            let twice = (varied.lengthInBars ?? 0) > loop
            let version = root.deriving(.melody(varied), by: author, operation: Operation.written,
                                        note: "\(Develop.tuneTitle(treatment, twice: twice)) of \(title)")
            guard await workspace.record(version) else {
                throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
            }
            return Output(tune: title, treatment: treatment.rawValue, version: version.id.description, part: version.partID.description,
                          sections: [], ways: [], opened: false, recorded: true,
                          detail: "\(title) is now played \(treatment.word): \(treatment.about). It is the tune's next version, heard "
                              + "wherever the tune plays; the one before is still in the ledger.")
        }

        var versions: [PartVersion] = []
        var arranged = song.sections
        var working = song
        var placed: [String] = []
        for section in sections {
            guard let index = arranged.firstIndex(where: { $0.id == section.id }),
                  let varied = vary(treatment, bars: max(loop, section.lengthInBars)) else { continue }
            let twice = (varied.lengthInBars ?? 0) > loop
            let variationName = treatment == .lift ? (twice ? "lift" : "raised") : treatment.rawValue
            let made = AnotherWay.variation(of: root, named: variationName, kind: .melody(varied),
                                            note: "\(Develop.tuneTitle(treatment, twice: twice)) of \(title)", by: author, in: working)
            if let version = made.version { versions.append(version); try? working.append(version) }
            if let playing = AnotherWay.lane(of: .melody, in: arranged[index], of: working) {
                arranged[index].stitch = arranged[index].stitch.map { $0.part == playing.lane.part ? Lane(part: made.part) : $0 }
            } else {
                arranged[index].stitch.append(Lane(part: made.part))
            }
            placed.append(section.name)
        }
        guard !placed.isEmpty else { throw refused(treatment.word) }
        let where_ = placed.joined(separator: ", ")
        guard await workspace.keep(versions, arranged: arranged, mix: nil, saying: "\(where_): \(title), \(treatment.word)",
                                   detail: treatment.about.prefix(1).uppercased() + treatment.about.dropFirst() + ".") else {
            throw DirectorToolFailure(tool: name, reason: "The song would not take it.")
        }
        return Output(tune: title, treatment: treatment.rawValue, version: versions.first?.id.description ?? "",
                      part: versions.first?.partID.description ?? "", sections: placed, ways: [], opened: false, recorded: true,
                      detail: "\(where_) plays \(title) \(treatment.word): \(treatment.about). The rest of the song plays it as it was; "
                          + "compare_section plays the section against how it stood.")
    }

    /// Chord spans with where each starts, as an observation reads them.
    static func starts(of spans: [ChordSpan]) -> [(chord: Chord, start: Double)] {
        var beat = 0.0
        return spans.map { span in
            defer { beat += span.beats }
            return (span.chord, beat)
        }
    }
}
