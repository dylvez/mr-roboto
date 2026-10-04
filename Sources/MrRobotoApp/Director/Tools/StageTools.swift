import Foundation
import SongGraph

// The two tools that turn an answer into a surface.
//
// This is where "surface selection as data, not prose" is actually cashed. The Director does not
// finish a turn with a sentence the app then reads for the word "compare"; it *calls a tool*, with
// a surface named from the catalog and version ids taken from what the other tools made. The call
// is validated inside the same round, so a choice the frame could not carry out comes back as a
// tool error the model can recover from — one more round, not one wrong panel.
//
// Both tools are appended to the toolbox rather than inserted, so every schema before them keeps
// its bytes and the session's cached prefix survives.

// MARK: - Shared argument shapes

/// A lever, as the model writes one.
public struct StageLeverArgument: Decodable, Sendable {
    public var quantity: String
    public var label: String
    public var value: Double

    /// The typed lever, or the sentence saying why it is not one.
    func lever(tool: String) throws -> SurfaceLever {
        guard let quantity = SurfaceLever.Quantity(rawValue: quantity) else {
            throw DirectorToolFailure(
                tool: tool,
                reason: "\"\(self.quantity)\" is not a quantity this instrument can move.",
                suggestion: "One of: \(SurfaceLever.Quantity.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return SurfaceLever(quantity: quantity, label: label, value: value)
    }
}

/// Everything both tools need out of the model's arguments, turned into a validated choice.
enum StageChoiceBuilder {

    static func versions(_ ids: [String], tool: String) throws -> [VersionID] {
        try ids.map { id in
            guard let version = VersionID(uuidString: id) else {
                throw DirectorToolFailure(tool: tool, reason: "\"\(id)\" is not a version id.",
                                          suggestion: "Take one from read_song or create_part_version.")
            }
            return version
        }
    }

    static func surface(_ raw: String, tool: String) throws -> SurfaceKind {
        guard let kind = SurfaceKind(rawValue: raw) else {
            throw DirectorToolFailure(
                tool: tool,
                reason: "\"\(raw)\" is not a surface in the catalog.",
                suggestion: "One of: \(SurfaceKind.directable.map(\.rawValue).joined(separator: ", ")).")
        }
        return kind
    }

    /// The fill, from the three fields the schema offers. Which one is used is decided by the
    /// surface, not by which fields happen to be present — that is what keeps the shape honest
    /// when the model sends a reference to a Grid.
    static func fill(surface: SurfaceKind, bound: [VersionID], reference: VersionID?,
                     finding: String?, tool: String) throws -> DirectorFill {
        switch surface {
        case .compare:
            guard let reference else {
                throw DirectorToolFailure(
                    tool: tool,
                    reason: "A Compare needs the thing its candidates are judged against.",
                    suggestion: "Pass `reference`: what the song already has, which stays at the top.")
            }
            return .compare(against: reference, candidates: bound)
        case .check:
            guard let subject = reference ?? bound.first else {
                throw DirectorToolFailure(tool: tool, reason: "A Check needs the part it is about.")
            }
            guard let finding, !finding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DirectorToolFailure(
                    tool: tool,
                    reason: "A Check with no finding has nothing to show.",
                    suggestion: "Pass `finding`: the one thing you found, in the song's own numbers.")
            }
            return .check(of: subject, finding: finding)
        case .importRecord, .chopLane, .grid, .sound, .chords, .pianoRoll, .structure, .album, .merge, .cast, .lyrics, .booth, .takes, .mixer, .master, .mashup, .sources, .library:
            guard reference == nil else {
                throw DirectorToolFailure(
                    tool: tool,
                    reason: "Only a Compare or a Check is judged against something.",
                    suggestion: "Put every version in `bound` and leave `reference` out.")
            }
            return .parts(bound)
        }
    }

    /// The schema both tools share, minus the fields that differ.
    static func properties(titleDescription: String) -> [(String, DirectorJSON)] {
        [
            ("surface", Schema.string(
                "Which surface from the fixed catalog. Chords get a lead sheet, feel gets a grid, "
                + "a bar of audio gets the chop lane; alternatives get a Compare and a single "
                + "finding gets a Check. Never invent a layout.",
                enum: SurfaceKind.directable.map(\.rawValue))),
            ("title", Schema.string(titleDescription)),
            ("bound", Schema.array(
                "Version ids the surface opens on, from read_song or create_part_version. On a "
                + "Compare these are the candidates, two to four of them, all of the same kind.",
                of: Schema.string("A version id."))),
            ("reference", Schema.optional(Schema.string(
                "Compare and Check only: the version the candidates are judged against, or the part "
                + "the finding is about. It stays visible at the top. Null for every other surface."))),
            ("finding", Schema.optional(Schema.string(
                "Check only: the one thing you found, in the song's own numbers. Flagged, never fixed."))),
            ("because", Schema.string(
                "One line saying why this surface answers the question, in the song's own terms "
                + "rather than as a slogan. The user reads this.")),
            // An empty list rather than a nullable one, and the same for every list in this
            // toolbox. The API caps how many optional parameters a tool set may carry
            // ("too many optional parameters (27) … limit: 24") and a list already has a way of
            // saying "none of them" that costs nothing: itself, empty.
            ("levers", Schema.array(
                "At most two controls, and only quantities you can hear change: "
                + SurfaceLever.Quantity.allCases.map { "\($0.rawValue) (\($0.sentence))" }.joined(separator: "; ")
                + ". Leave it empty when the surface's own controls are enough.",
                of: Schema.object([
                    ("quantity", Schema.string("Which quantity the lever moves.",
                                               enum: SurfaceLever.Quantity.allCases.map(\.rawValue))),
                    ("label", Schema.string("What the control says on the surface: \"Dustier\".")),
                    ("value", Schema.number("Where it starts, inside that quantity's range.")),
                ], required: ["quantity", "label", "value"]))),
        ]
    }

    static var propertyNames: [String] {
        ["surface", "title", "bound", "reference", "finding", "because", "levers"]
    }
}

// MARK: - open_surface

/// Opens one surface from the catalog, filled with parts the song actually holds.
///
/// It opens immediately rather than at the end of the turn, which is the difference between an
/// instrument that answers while it works and one that goes quiet for twenty seconds and then
/// redraws itself.
public struct OpenSurfaceTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var surface: String
        public var title: String
        public var bound: [String]
        public var reference: String?
        public var finding: String?
        public var because: String
        public var levers: [StageLeverArgument]?
    }

    public struct Output: Encodable, Sendable {
        public var surface: String
        public var title: String
        public var opened: Bool
        public var bound: [String]
        public var levers: [String]
        public var openSurfaces: Int
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case surface, title, opened, bound, levers, note
            case openSurfaces = "open_surfaces"
        }
    }

    let stage: any DirectorStage
    let pad: DirectorStagePad

    public init(stage: any DirectorStage, pad: DirectorStagePad) {
        self.stage = stage
        self.pad = pad
    }

    public let name = "open_surface"
    public var purpose: String {
        "Answer by opening one surface from the fixed catalog and binding it to part versions the "
        + "song holds. This is how you show something rather than describe it. The bench holds one "
        + "surface of each kind: opening a kind that is already open turns it to what you bind. "
        + "One answer opens three at most, and never more than one surface per thing you are saying."
    }
    public var schema: DirectorJSON {
        Schema.object(StageChoiceBuilder.properties(
            titleDescription: "What the surface is called on the bench, as a person would say it: "
                + "\"Bar 9 of Arrival\", \"Three slower reads\"."),
                      required: StageChoiceBuilder.propertyNames)
    }

    public func run(_ input: Input) async throws -> Output {
        let surface = try StageChoiceBuilder.surface(input.surface, tool: name)
        let bound = try StageChoiceBuilder.versions(input.bound, tool: name)
        let reference = try input.reference.map {
            try StageChoiceBuilder.versions([$0], tool: name)[0]
        }
        let levers = try (input.levers ?? []).map { try $0.lever(tool: name) }
        let fill = try StageChoiceBuilder.fill(surface: surface, bound: bound, reference: reference,
                                               finding: input.finding, tool: name)

        let choice: DirectorSurfaceChoice
        do {
            choice = try await DirectorSurfaceChoice.make(surface: surface, title: input.title,
                                                          fill: fill, levers: levers,
                                                          because: input.because, in: stage)
        } catch let problem as DirectorChoiceProblem {
            throw problem.failure(tool: name)
        }

        do {
            try await pad.record(choice)
        } catch let problem as DirectorChoiceProblem {
            throw problem.failure(tool: name)
        }

        let opened = await MainActor.run { stage.open(choice) != nil }
        let count = await MainActor.run { stage.openSurfaceCount }
        return Output(surface: surface.rawValue,
                      title: choice.title,
                      opened: opened,
                      bound: choice.fill.bound.map(\.description),
                      levers: choice.levers.map(\.line),
                      openSurfaces: count,
                      note: opened ? nil : "The frame declined to open it; the song may have moved on.")
    }
}

// MARK: - propose

/// Offers a surface rather than opening one.
///
/// The same validated choice, put in the rail as a control the user presses. Rule 2's third clause:
/// a persona's initiative is a proposal, not a panel that appears while you are working.
public struct ProposeTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var surface: String
        public var title: String
        public var bound: [String]
        public var reference: String?
        public var finding: String?
        public var because: String
        public var levers: [StageLeverArgument]?
        /// Which member of the band is proposing. Omitted for the Director's own.
        public var persona: String?
    }

    public struct Output: Encodable, Sendable {
        public var proposed: Bool
        public var title: String
        public var surface: String
        public var source: String
        public var proposals: Int
    }

    let stage: any DirectorStage
    let pad: DirectorStagePad

    public init(stage: any DirectorStage, pad: DirectorStagePad) {
        self.stage = stage
        self.pad = pad
    }

    public let name = "propose"
    public var purpose: String {
        "Offer something worth doing next as a control in the conversation rail, instead of doing "
        + "it. Same catalog, same bindings, same validation as open_surface — a proposal that would "
        + "not open is refused here rather than failing under the user's finger."
    }
    public var schema: DirectorJSON {
        var properties = StageChoiceBuilder.properties(
            titleDescription: "The verb on the control, as an instruction: \"Try the dustier read\".")
        properties.append(("persona", Schema.string(
            "Which member of the band is proposing this. Empty for the Director's own suggestion.")))
        return Schema.object(properties, required: StageChoiceBuilder.propertyNames + ["persona"])
    }

    public func run(_ input: Input) async throws -> Output {
        let surface = try StageChoiceBuilder.surface(input.surface, tool: name)
        let bound = try StageChoiceBuilder.versions(input.bound, tool: name)
        let reference = try input.reference.map {
            try StageChoiceBuilder.versions([$0], tool: name)[0]
        }
        let levers = try (input.levers ?? []).map { try $0.lever(tool: name) }
        let fill = try StageChoiceBuilder.fill(surface: surface, bound: bound, reference: reference,
                                               finding: input.finding, tool: name)

        let choice: DirectorSurfaceChoice
        do {
            choice = try await DirectorSurfaceChoice.make(surface: surface, title: input.title,
                                                          fill: fill, levers: levers,
                                                          because: input.because, in: stage)
        } catch let problem as DirectorChoiceProblem {
            throw problem.failure(tool: name)
        }

        let source: Proposal.Source = input.persona.flatMap { $0.isEmpty ? nil : .persona($0) } ?? .director
        await pad.record(DirectorProposal(choice: choice, title: input.title, source: source))
        let count = await pad.proposals.count
        return Output(proposed: true, title: input.title, surface: surface.rawValue,
                      source: source.label, proposals: count)
    }
}
