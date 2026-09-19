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
            ("persona", Schema.string("The persona's id for add or remove: beatmaker, sampler, bassist, producer, engineer, peer or lyricist. Empty for read.")),
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
        return Output(cast: members, houseCalls: song.houseCalls?.count ?? 0, detail: detail)
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
        }
        public struct Verdict: Encodable, Sendable {
            public var persona: String
            public var verdict: String
            public var says: String
        }
        public struct Disagreement: Encodable, Sendable {
            public var between: [String]
            public var about: String
            public var settledBy: String
            public var compare: String?
            enum CodingKeys: String, CodingKey { case between, about, compare; case settledBy = "settled_by" }
        }
        public var room: [String]
        public var readings: [Reading]
        public var verdicts: [Verdict]
        public var disagreement: Disagreement?
        public var detail: String
    }

    let workspace: any DirectorWorkspace
    let cast: Cast

    public init(workspace: any DirectorWorkspace, cast: Cast = .standard) {
        self.workspace = workspace
        self.cast = cast
    }

    public let name = "convene"
    public var purpose: String {
        "Put a question to everyone in the room. Each persona reads the open song in its own units — parts and brief, "
        + "hook arrival in seconds, the bounce in LUFS and dB, the lines' stresses — and says what holds and what does not; "
        + "the lines reach the rail in their names. When two disagree, a Compare of the two readings opens, with what settles it."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("question", Schema.string("What the user asked, in their words.")),
            ("section", Schema.string("A section by name, for the Engineer to bounce. Empty for the first section.")),
        ], required: ["question", "section"])
    }

    public func run(_ input: Input) async throws -> Output {
        guard let song = await workspace.song else {
            throw DirectorToolFailure(tool: name, reason: "No song is open, so there is nothing to convene on.",
                                      suggestion: "Open a song first.")
        }
        let room = cast.inRoom(for: song)
        var readings: [(PersonaID, PersonaReading)] = []
        var notes: [String] = []

        let section = input.section.isEmpty ? nil : song.sections.first { $0.name.caseInsensitiveCompare(input.section) == .orderedSame }
        if !input.section.isEmpty, section == nil {
            notes.append("No section called \(input.section); the Engineer read the first.")
        }

        for persona in room.personas {
            let id = persona.bible.id
            switch id {
            case .producer:
                readings += Producer().read(SongObservation.of(song)).map { (id, $0) }
            case .peer:
                readings += Peer().read(FormObservation.of(song)).map { (id, $0) }
            case .lyricist:
                if let version = song.versions.last(where: { $0.type == .lyric }), case .lyric(let lyric) = version.kind {
                    let corpus = await workspace.voice
                    readings += Lyricist().read(LyricObservation.of(lyric, label: PartLabel.title(of: version), corpus: corpus, title: song.title)).map { (id, $0) }
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
            case .beatmaker:
                if let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind {
                    let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                                        options: GrooveRenderOptions(), tempo: song.tempo, timeSignature: song.timeSignature)
                    readings += Beatmaker().read(observation).map { (id, $0) }
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
        for persona in room.personas {
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
            for (id, verdict) in room.ask(proposal) {
                if case .defer_ = verdict { continue }
                answered.append((id, verdict))
                verdicts.append(Output.Verdict(persona: id.rawValue, verdict: VerdictShape(verdict).description, says: verdict.spoken))
                await workspace.speak(cast.persona(id)?.bible.name ?? id.rawValue, verdict.spoken, detail: verdict.refusedByRule.map { "refused by \($0)" })
            }
        }

        // A disagreement: two verdicts of different shapes on the proposal, or a declared pair
        // where this side's front-line reading fails while the other's holds.
        var disagreement: Output.Disagreement?
        if let card = Self.disagreement(among: answered, proposal: proposal, readings: readings, room: room, song: song, section: section) {
            let title = await workspace.openDisagreement(card)
            disagreement = Output.Disagreement(between: card.between.map(\.rawValue), about: card.about, settledBy: card.settledBy, compare: title)
        }

        let out = readings.map { id, r -> Output.Reading in
            let unit = cast.persona(id)?.bible.vocabulary.first { $0.feature == r.feature }?.unit ?? ""
            return Output.Reading(persona: id.rawValue, rule: r.rule, feature: r.feature.rawValue, value: r.value, unit: unit, holds: r.holds, says: r.says)
        }
        let flagged = out.filter { !$0.holds }.count
        var detail = "\(room.personas.count) in the room; \(out.count) readings, \(flagged) not holding."
        if let disagreement { detail += " \(disagreement.between.joined(separator: " and ")) disagree about \(disagreement.about); a Compare is open." }
        if !notes.isEmpty { detail += " " + notes.joined(separator: " ") }
        return Output(room: room.ids.map(\.rawValue), readings: out, verdicts: verdicts, disagreement: disagreement, detail: detail)
    }

    /// The first disagreement that shows.
    static func disagreement(among answered: [(PersonaID, PersonaVerdict)], proposal: PersonaProposal,
                             readings: [(PersonaID, PersonaReading)], room: Cast, song: Song, section: Section?) -> DisagreementCard? {
        let reference = section?.stitch.first ?? song.versions.last?.id
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
