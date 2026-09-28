import Foundation
import MusicTheory
import Performance
import SongGraph

// M4's two, appended after `merge` so every schema before them keeps its bytes: the room read and
// set, and the room convened on a question.

// MARK: - cast

/// Who is in the room for this song, and a way to change it.
public struct CastTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        /// "read", "add" or "remove".
        public var action: String
        /// The persona, by id, for add and remove; empty for read.
        public var persona: String
    }

    public struct Output: Encodable, Sendable {
        public struct Member: Encodable, Sendable {
            public var id: String
            public var name: String
            public var owns: String
            public var listensFirstFor: String
            public var inRoom: Bool
            enum CodingKeys: String, CodingKey { case id, name, owns; case listensFirstFor = "listens_first_for"; case inRoom = "in_room" }
        }
        public var cast: [Member]
        public var houseCalls: Int
        public var detail: String
        enum CodingKeys: String, CodingKey { case cast, detail; case houseCalls = "house_calls" }
    }

    let workspace: any DirectorWorkspace
    let cast: Cast

    public init(workspace: any DirectorWorkspace, cast: Cast = .standard) {
        self.workspace = workspace
        self.cast = cast
    }

    public let name = "cast"
    public var purpose: String {
        "Read who is in the room for the open song — every persona, what each owns, and whether it is in — "
        + "or add or remove one by id. A persona out of the room is not consulted by convene. An empty cast is everyone."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("action", Schema.string("What to do.", enum: ["read", "add", "remove"])),
            ("persona", Schema.string("The persona's id for add or remove: beatmaker, sampler, bassist, producer, engineer, peer, lyricist, harmonist or melodist. Empty for read.")),
        ], required: ["action", "persona"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open, so there is no room to read.",
                                      suggestion: "Open a song first.")
        }
        var ids = await workspace.castIDs
        var detail: String
        switch input.action {
        case "read":
            detail = ids.isEmpty ? "Everyone is in the room for \(song.title)." : "\(ids.count) of \(cast.personas.count) in the room for \(song.title)."
        case "add", "remove":
            guard let persona = cast.persona(PersonaID(input.persona)) else {
                throw DirectorToolFailure(tool: name, reason: "\"\(input.persona)\" is not a persona in this cast.",
                                          suggestion: "Use one of \(cast.ids.map(\.rawValue).joined(separator: ", ")).")
            }
            if ids.isEmpty { ids = cast.ids }
            if input.action == "add" {
                if !ids.contains(persona.bible.id) { ids.append(persona.bible.id) }
            } else {
                ids.removeAll { $0 == persona.bible.id }
            }
            if Set(ids) == Set(cast.ids) { ids = [] }
            guard await workspace.setCast(ids) else {
                throw DirectorToolFailure(tool: name, reason: "The cast could not be set.")
            }
            detail = "\(persona.bible.name) is \(input.action == "add" ? "in" : "out of") the room."
        default:
            throw DirectorToolFailure(tool: name, reason: "\"\(input.action)\" is not read, add or remove.")
        }
        let room = Set(ids.isEmpty ? cast.ids : ids)
        let members = cast.personas.map { persona -> Output.Member in
            let bible = persona.bible
            return Output.Member(id: bible.id.rawValue, name: bible.name, owns: bible.owns,
                                 listensFirstFor: bible.listensFor.min { $0.priority < $1.priority }?.what ?? "",
                                 inRoom: room.contains(bible.id))
        }
        return Output(cast: members, houseCalls: await workspace.houseBook.entries.count, detail: detail)
    }
}

// MARK: - convene

/// The room convened on a question: everyone in it reads the song in their own units, the lines
/// reach the rail in their names, and a disagreement between two of them opens as a Compare.
public struct ConveneTool: DirectorTool {
    public struct Input: Decodable, Sendable {
        public var question: String
        /// A section by name, for the Engineer's bounce. Empty for the first section, or the song.
        public var section: String
        /// Who to ask, by id. Empty asks everyone in the room.
        public var personas: [String]
    }

    public struct Output: Encodable, Sendable {
        public struct Reading: Encodable, Sendable {
            public var persona: String
            public var rule: String
            public var feature: String
            public var value: Double
            public var unit: String
            public var holds: Bool
            public var says: String
            /// How often this has been said, across songs; nil the first time. The numbers stand:
            /// this is so a repeat is said as a repeat, not word for word.
            public var saidBefore: String?
            /// When the house plays the other reading on a question this rule answers to.
            public var houseCall: String?
            enum CodingKeys: String, CodingKey {
                case persona, rule, feature, value, unit, holds, says
                case saidBefore = "said_before", houseCall = "house_call"
            }
        }
        public struct Verdict: Encodable, Sendable {
            public var persona: String
            public var verdict: String
            public var says: String
            /// True when this member was not asked and speaks only because a rule of theirs refuses.
            public var isGuard: Bool
            enum CodingKeys: String, CodingKey { case persona, verdict, says; case isGuard = "is_guard" }
        }
        public struct Disagreement: Encodable, Sendable {
            public var between: [String]
            public var about: String
            public var settledBy: String
            public var compare: String?
            enum CodingKeys: String, CodingKey { case between, about, compare; case settledBy = "settled_by" }
        }
        public var room: [String]
        /// Who was asked, and who in the room was not. Not asked is not the same as nothing to say.
        public var asked: [String]
        public var notAsked: [String]
        public var readings: [Reading]
        public var verdicts: [Verdict]
        public var disagreement: Disagreement?
        /// The house calls in force for the room's questions, each with whose call it is.
        public var houseCalls: [String]
        public var detail: String
        enum CodingKeys: String, CodingKey {
            case room, asked, readings, verdicts, disagreement, detail
            case notAsked = "not_asked", houseCalls = "house_calls"
        }
    }

    let workspace: any DirectorWorkspace
    let cast: Cast

    public init(workspace: any DirectorWorkspace, cast: Cast = .standard) {
        self.workspace = workspace
        self.cast = cast
    }

    public let name = "convene"
    public var purpose: String {
        "Put a question to the room, or to the members named. Each persona asked reads the open song in its own units — parts and "
        + "brief, hook arrival in seconds, the bounce in LUFS and dB, the lines' stresses — and says what holds and what does not; "
        + "the lines reach the rail in their names. A member not asked stays silent unless one of their rules refuses the question "
        + "as a proposal: that comes back marked as a guard. When two of those asked disagree, a Compare of the two readings opens."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("question", Schema.string("What the user asked, in their words.")),
            ("section", Schema.string("A section by name, for the Engineer to bounce. Empty for the first section.")),
            ("personas", Schema.array("Who to ask, by id; empty asks everyone in the room. Use the user's 'Asked of' line when there is one.",
                                      of: Schema.string("A persona id.", enum: ["beatmaker", "sampler", "bassist", "producer", "engineer", "peer", "lyricist", "harmonist", "melodist"]))),
        ], required: ["question", "section", "personas"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open, so there is nothing to convene on.",
                                      suggestion: "Open a song first.")
        }
        let room = cast.inRoom(for: song)
        let book = await workspace.houseBook
        var readings: [(PersonaID, PersonaReading)] = []
        var notes: [String] = []

        // Who is asked: everyone in the room, or the members named who are in it.
        let named = input.personas.map { PersonaID($0.lowercased()) }
        let absent = named.filter { !room.ids.contains($0) }
        let asked = named.isEmpty ? room : Cast(room.personas.filter { named.contains($0.bible.id) })
        if !absent.isEmpty {
            notes.append("\(absent.map { cast.persona($0)?.bible.name ?? $0.rawValue }.joined(separator: ", ")) \(absent.count == 1 ? "is" : "are") not in the room for this song.")
        }
        guard !asked.personas.isEmpty else {
            throw DirectorToolFailure(tool: name, reason: "None of those asked are in the room for this song. " + notes.joined(separator: " "),
                                      suggestion: "Add them with cast, or ask someone who is in the room: \(room.ids.map(\.rawValue).joined(separator: ", ")).")
        }
        let notAsked = room.ids.filter { !asked.ids.contains($0) }
        if !notAsked.isEmpty {
            let names = asked.personas.map(\.bible.name).joined(separator: ", ")
            await workspace.speak("Band", "Asked: \(names).", detail: "\(notAsked.count) in the room not consulted")
        }

        let section = input.section.isEmpty ? nil : song.sections.first { $0.name.caseInsensitiveCompare(input.section) == .orderedSame }
        if !input.section.isEmpty, section == nil {
            notes.append("No section called \(input.section); the Engineer read the first.")
        }

        for persona in asked.personas {
            let id = persona.bible.id
            switch id {
            case .producer:
                readings += Producer().read(SongObservation.of(song)).map { (id, $0) }
            case .peer:
                readings += Peer().read(FormObservation.of(song)).map { (id, $0) }
            case .lyricist:
                if let version = song.versions.last(where: { $0.type == .lyric }), case .lyric(let lyric) = version.kind {
                    let corpus = await workspace.voice
                    // Words set to a tune are read on it too: where the stressed syllables land.
                    let tune = lyric.alignedTo.flatMap { song.version($0) }.flatMap { aligned -> Melody? in
                        if case .melody(let melody) = aligned.kind { return melody }
                        return nil
                    }
                    readings += Lyricist().read(LyricObservation.of(lyric, label: PartLabel.title(of: version), corpus: corpus, title: song.title,
                                                                    melody: tune, beatsPerBar: song.timeSignature.beatsPerBar)).map { (id, $0) }
                } else {
                    notes.append("No lyric yet for the Lyricist to read.")
                }
            case .engineer:
                do {
                    if let observation = try await workspace.bounce(section: section?.id) {
                        readings += Engineer().read(observation).map { (id, $0) }
                    } else {
                        notes.append("Nothing to bounce for the Engineer.")
                    }
                } catch {
                    notes.append("The Engineer's bounce failed: \(error).")
                }
            case .melodist:
                if let version = song.versions.last(where: { $0.type == .melody }), case .melody(let melody) = version.kind {
                    let progression = Guidance.progressions(in: song).last.flatMap { version -> Progression? in
                        if case .progression(let p) = version.kind { return p }
                        return nil
                    }
                    let observation = MelodyObservation.of(melody, label: PartLabel.title(of: version),
                                                           key: song.key ?? Key(tonic: NoteName(.c)),
                                                           progression: progression,
                                                           beatsPerBar: song.timeSignature.beatsPerBar)
                    readings += Melodist().read(observation).map { (id, $0) }
                } else {
                    notes.append("No tune yet for the Melodist to read.")
                }
            case .harmonist:
                if let version = Guidance.progressions(in: song).last, case .progression(let progression) = version.kind {
                    let line = Guidance.basslines(in: song).last.flatMap { version -> Bassline? in
                        if case .bassline(let bassline) = version.kind { return bassline }
                        return nil
                    }
                    let observation = HarmonyObservation.of(progression, label: PartLabel.title(of: version), bassline: line,
                                                            beatsPerBar: song.timeSignature.beatsPerBar)
                    readings += Harmonist().read(observation).map { (id, $0) }
                } else {
                    notes.append("No chords yet for the Harmonist to read.")
                }
            case .beatmaker:
                if let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind {
                    let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                                        options: .stored(groove), tempo: song.tempo, timeSignature: song.timeSignature)
                    readings += Beatmaker(houseCalls: book.calls).read(observation).map { (id, $0) }
                }
            case .bassist:
                if let line = Guidance.basslines(in: song).last, case .bassline(let bassline) = line.kind,
                   let grooveVersion = Guidance.grooves(in: song).last, case .groove(let groove) = grooveVersion.kind {
                    let observation = BassObservation(label: PartLabel.title(of: line), bassline: bassline, groove: groove,
                                                      chords: [], tempo: song.tempo, timeSignature: song.timeSignature)
                    readings += Bassist().read(observation).map { (id, $0) }
                }
            default:
                break
            }
        }

        // The rail: what did not hold, in each persona's name; a persona with nothing to flag says so once.
        for persona in asked.personas {
            let id = persona.bible.id
            let mine = readings.filter { $0.0 == id }.map(\.1)
            guard !mine.isEmpty else { continue }
            let failing = mine.filter { !$0.holds }
            if failing.isEmpty, let first = mine.first {
                await workspace.speak(persona.bible.name, first.says, detail: "nothing to flag")
            }
            for reading in failing {
                await workspace.speak(persona.bible.name, reading.says, detail: reading.rule)
            }
        }

        // The question as a proposal, put to the room.
        let proposal = EngineVocabularyReader().read(input.question, context: PersonaReadingContext(tempo: song.tempo))
        var verdicts: [Output.Verdict] = []
        var answered: [(PersonaID, PersonaVerdict)] = []
        if case .outOfScope = proposal {} else {
            // The whole room hears the proposal, because guards stay on: a member who was not asked
            // speaks only when a rule of theirs refuses, and is marked as a guard, not an opinion.
            for (id, verdict) in room.ask(proposal) {
                if case .defer_ = verdict { continue }
                let wasAsked = asked.ids.contains(id)
                guard wasAsked || verdict.refusedByRule != nil else { continue }
                if wasAsked { answered.append((id, verdict)) }
                verdicts.append(Output.Verdict(persona: id.rawValue, verdict: VerdictShape(verdict).description, says: verdict.spoken, isGuard: !wasAsked))
                let rule = verdict.refusedByRule.map { "refused by \($0)" }
                await workspace.speak(cast.persona(id)?.bible.name ?? id.rawValue, verdict.spoken,
                                      detail: wasAsked ? rule : "guard — not asked, but \(rule ?? "a rule refuses")")
            }
        }

        // A disagreement: two verdicts of different shapes on the proposal, or a declared pair
        // where this side's front-line reading fails while the other's holds.
        var disagreement: Output.Disagreement?
        if let card = Self.disagreement(among: answered, proposal: proposal, readings: readings, room: asked, song: song, section: section) {
            let title = await workspace.openDisagreement(card)
            disagreement = Output.Disagreement(between: card.between.map(\.rawValue), about: card.about, settledBy: card.settledBy, compare: title)
        }

        // What has been said before, counted across songs, and this convening added to it.
        let library = await workspace.library
        let said = SaidBefore.update(library.said ?? [], with: readings, song: song.id, title: song.title, today: SaidBefore.today())
        await workspace.keepSaid(said.records)

        let out = readings.enumerated().map { index, entry -> Output.Reading in
            let (id, r) = entry
            let bible = cast.persona(id)?.bible
            let unit = bible?.vocabulary.first { $0.feature == r.feature }?.unit ?? ""
            return Output.Reading(persona: id.rawValue, rule: r.rule, feature: r.feature.rawValue, value: r.value, unit: unit, holds: r.holds, says: r.says,
                                  saidBefore: said.before[index].map { SaidBefore.sentence($0, now: song.id) },
                                  houseCall: bible.flatMap { book.note(on: r.rule, in: $0) })
        }
        let questions = Set(asked.personas.flatMap { $0.bible.openQuestions.map(\.id) })
        let calls = book.entries.filter { questions.contains($0.call.question) }.map { entry in
            "\(entry.call.question): \(entry.call.choice.rawValue) (\(entry.scope == .song ? "this song only" : entry.scope == .house ? "the house, every song" : "as shipped"), \(entry.call.decidedOn))"
        }
        let flagged = out.filter { !$0.holds }.count
        var detail = notAsked.isEmpty
            ? "\(room.personas.count) in the room; \(out.count) readings, \(flagged) not holding."
            : "Asked \(asked.ids.map(\.rawValue).joined(separator: ", ")) of \(room.personas.count) in the room; \(out.count) readings, \(flagged) not holding."
        let guards = verdicts.filter(\.isGuard)
        if !guards.isEmpty { detail += " Guard: \(guards.map { "\($0.persona) (not asked) refuses" }.joined(separator: "; "))." }
        if let disagreement { detail += " \(disagreement.between.joined(separator: " and ")) disagree about \(disagreement.about); a Compare is open." }
        if !notes.isEmpty { detail += " " + notes.joined(separator: " ") }
        return Output(room: room.ids.map(\.rawValue), asked: asked.ids.map(\.rawValue), notAsked: notAsked.map(\.rawValue), readings: out, verdicts: verdicts, disagreement: disagreement, houseCalls: calls, detail: detail)
    }

    /// The first disagreement that shows.
    static func disagreement(among answered: [(PersonaID, PersonaVerdict)], proposal: PersonaProposal,
                             readings: [(PersonaID, PersonaReading)], room: Cast, song: Song, section: Section?) -> DisagreementCard? {
        // What the section's first lane plays right now, not what it was stitched from once.
        let reference = section.flatMap { song.versions(playing: $0).first?.id } ?? song.versions.last?.id
        // On the proposal: two non-deferring verdicts of different shapes.
        for (i, a) in answered.enumerated() {
            for b in answered[(i + 1)...] where VerdictShape(a.1) != VerdictShape(b.1) {
                guard let pa = room.persona(a.0), let pb = room.persona(b.0) else { continue }
                let declared = pa.bible.disagreements.first { $0.with == b.0 } ?? pb.bible.disagreements.first { $0.with == a.0 }
                let measures = ProposalMeasures.of(proposal)
                func side(_ p: any Persona, _ v: PersonaVerdict) -> DisagreementCard.Side {
                    DisagreementCard.Side(persona: p.bible.id, name: p.bible.name, says: v.spoken,
                                          readings: measures.values.map { feature, value in
                                              CompareReading(feature, value, unit: p.bible.vocabulary.first { $0.feature == feature }?.unit ?? "")
                                          })
                }
                return DisagreementCard(about: declared?.about ?? "the proposal", settledBy: declared?.settledBy ?? "the user",
                                        subject: "the proposal", a: side(pa, a.1), b: side(pb, b.1), reference: reference, vocabulary: pa.bible)
            }
        }
        // On the readings: A's front-line rule fails, B's holds.
        for pa in room.personas {
            for declaration in pa.bible.disagreements {
                guard let ra = declaration.rule, let pb = room.persona(declaration.with),
                      let rb = pb.bible.disagreements.first(where: { $0.with == pa.bible.id })?.rule else { continue }
                guard let mine = readings.first(where: { $0.0 == pa.bible.id && $0.1.rule == ra && !$0.1.holds })?.1,
                      let theirs = readings.first(where: { $0.0 == pb.bible.id && $0.1.rule == rb && $0.1.holds })?.1 else { continue }
                func side(_ p: any Persona, _ r: PersonaReading) -> DisagreementCard.Side {
                    DisagreementCard.Side(persona: p.bible.id, name: p.bible.name, says: r.says,
                                          readings: [CompareReading(r.feature, r.value, unit: p.bible.vocabulary.first { $0.feature == r.feature }?.unit ?? "")])
                }
                return DisagreementCard(about: declaration.about, settledBy: declaration.settledBy,
                                        subject: section.map { "\($0.name), as it is" } ?? "\(song.title), as it is",
                                        a: side(pa, mine), b: side(pb, theirs), reference: reference, vocabulary: pa.bible)
            }
        }
        return nil
    }
}

// MARK: - The card

/// Two personas' readings that disagree, as a Compare: what settles it at the top, one row each.
public struct DisagreementCard: Sendable {
    public struct Side: Sendable {
        public var persona: PersonaID
        public var name: String
        public var says: String
        public var readings: [CompareReading]
    }
    public var about: String
    public var settledBy: String
    public var subject: String
    public var a: Side
    public var b: Side
    public var reference: VersionID?
    public var vocabulary: PersonaBible

    public var between: [PersonaID] { [a.persona, b.persona] }
    public var title: String { "\(a.name) and \(b.name): \(about)" }

    public var brief: CompareBrief {
        CompareBrief(title: title,
                     reference: CompareReference(title: subject, kind: "settled by: \(settledBy)", readings: [], version: reference),
                     candidates: [
                        CompareCandidate(id: a.persona.rawValue, title: a.name, proposedBy: a.persona, rationale: a.says, readings: a.readings),
                        CompareCandidate(id: b.persona.rawValue, title: b.name, proposedBy: b.persona, rationale: b.says, readings: b.readings),
                     ],
                     features: Array(Set((a.readings + b.readings).map(\.feature))).sorted { $0.rawValue < $1.rawValue },
                     levers: [], vocabulary: vocabulary)
    }
}
