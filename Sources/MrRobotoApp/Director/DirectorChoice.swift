import Foundation
import SongGraph

// Choosing a surface, as data.
//
// The Director's answer to "chop the drums from bar 9 and give me something slower and dustier" is
// not a paragraph the app then parses. It is a value: a surface from the fixed catalog, a title, the
// part versions it binds to, and at most two levers. This file is that value and the five rules that
// decide whether it is allowed to exist.
//
// The rule the whole file is built around is the last one in the task and the first one in the
// design: **a choice that cannot be performed must be impossible to emit.** So
// `DirectorSurfaceChoice` has no public initializer. The only way to make one is `make(…, in:)`,
// which checks it against the frame — the same `AppState.canPerform` that Gate A's proposals go
// through — and throws a sentence the model can act on when it does not hold. A `DirectorTurn` can
// therefore only ever carry choices the frame can carry out, and that is a property of the type
// rather than of anybody remembering to filter.

// MARK: - What a surface can draw

extension SurfaceKind {

    /// The part types this surface can actually draw.
    ///
    /// Rule 1 — *answer in the notation the question is about* — made checkable. A question about a
    /// feel gets the Grid because the Grid draws grooves; binding a groove to the Sound surface is
    /// not a stylistic mistake, it is a surface asked to draw something it has no marks for.
    ///
    /// The two answer surfaces take anything, because what they draw is the comparison and the
    /// finding rather than the part: a Compare of three grooves and a Compare of three chops are the
    /// same surface. What they may not do is mix — see `DirectorFill`.
    public var notation: Set<PartType> {
        switch self {
        case .importRecord: return [.audio, .analysis]
        case .chopLane: return [.sample, .audio]
        case .grid: return [.groove]
        case .sound: return [.sound]
        case .compare, .check: return Set(PartType.allCases)
        }
    }

    /// The notation, as a sentence for a tool schema or a failure the model reads.
    var notationSentence: String {
        notation.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

// MARK: - A lever

/// One control the Director is allowed to put on a surface it opened.
///
/// Rule 5 — *at most two levers per surface, and only ones that map to a musical quantity you can
/// hear change* — is enforced in two places, and both are in the type rather than in the prompt.
/// The count is checked by `DirectorSurfaceChoice.make`; the "you can hear it" half is `Quantity`
/// being a closed enum. There is no `case other(String)`, so "vibe" and "energy" and "polish" are
/// not expressible: the model cannot name a lever the instrument has no number for.
public struct SurfaceLever: Sendable, Equatable, Hashable {

    /// The musical quantities this instrument can actually move, and the range each moves over.
    public enum Quantity: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
        /// Beats per minute.
        case tempo
        /// How far off the grid the offbeats sit, as the feel library's swing percentage.
        case swing
        /// How hard the hits land, as a multiplier on the performance's velocities.
        case velocity
        /// How much is playing: ghosts in, ghosts out.
        case density
        /// The degradation chain: bit depth, sample rate, saturation, as one amount.
        case dust
        /// Semitones.
        case pitch
        /// Level, in decibels.
        case gain

        /// What the number may be. A lever outside its range is a control that would either do
        /// nothing or break the thing it moves, so it is refused at the door.
        public var range: ClosedRange<Double> {
            switch self {
            case .tempo: return 40...220
            case .swing: return 50...75
            case .velocity: return 0...2
            case .density: return 0...1
            case .dust: return 0...1
            case .pitch: return -12...12
            case .gain: return -24...6
            }
        }

        public var unit: String {
            switch self {
            case .tempo: return "bpm"
            case .swing: return "%"
            case .velocity: return "×"
            case .density, .dust: return ""
            case .pitch: return "st"
            case .gain: return "dB"
            }
        }

        /// The surfaces this quantity means something on. A swing lever on the Sound surface is a
        /// control with nothing behind it; the catalog says so rather than the reviewer.
        public var surfaces: Set<SurfaceKind> {
            switch self {
            case .tempo: return [.chopLane, .grid, .compare]
            case .swing: return [.chopLane, .grid, .compare]
            case .velocity: return [.chopLane, .grid, .compare]
            case .density: return [.grid, .compare]
            case .dust: return [.chopLane, .sound, .compare]
            case .pitch: return [.chopLane, .sound]
            case .gain: return [.chopLane, .grid, .sound, .compare]
            }
        }

        /// One line for the tool schema, so the model picks by meaning rather than by guessing.
        public var sentence: String {
            switch self {
            case .tempo: return "beats per minute, 40 to 220"
            case .swing: return "how late the offbeats sit, 50 (straight) to 75 (hard triplet)"
            case .velocity: return "how hard the hits land, 0 to 2 as a multiplier"
            case .density: return "how much is playing, 0 (bare) to 1 (every ghost in)"
            case .dust: return "the degradation chain as one amount, 0 (clean) to 1 (ruined)"
            case .pitch: return "semitones, -12 to 12"
            case .gain: return "level in decibels, -24 to 6"
            }
        }
    }

    public var quantity: Quantity
    /// What the control says on the surface: "Dustier", "Swing". Written by whoever chose it.
    public var label: String
    /// Where it starts.
    public var value: Double

    public init(quantity: Quantity, label: String, value: Double) {
        self.quantity = quantity
        self.label = label
        self.value = value
    }

    /// The lever as a person reads it: "Dustier · 0.6".
    public var line: String {
        let number = (value * 100).rounded() / 100
        let text = number == number.rounded() ? String(Int(number)) : String(number)
        return unit.isEmpty ? "\(label) · \(text)" : "\(label) · \(text) \(unit)"
    }

    private var unit: String { quantity.unit }
}

// MARK: - What goes in the surface

/// The content of the surface the Director chose, in the shape that surface actually has.
///
/// This is the difference between "the bindings are an array and the first one is special if you
/// remember" and a value that cannot be built wrong. Rule 4 — *on a Compare, the thing the
/// candidates are judged against stays visible at the top* — is the `against:` label: a Compare with
/// no reference is not a badly-configured Compare, it is unrepresentable.
///
/// `bound` flattens back to the `[VersionID]` the frame already stores per surface, reference first.
/// That ordering is the contract the Compare surface reads, and it is produced here rather than
/// assembled by hand at each call site.
public enum DirectorFill: Sendable, Equatable, Hashable {

    /// A surface that opens onto part versions and edits them: Record, Chop lane, Grid, Sound.
    case parts([VersionID])

    /// Alternatives, and the thing they have to beat. `against` is drawn at the top and is never
    /// one of the candidates — comparing something with itself is the failure this shape forbids.
    case compare(against: VersionID, candidates: [VersionID])

    /// One finding about one part. Flagged, never fixed: the finding is the text on the card.
    case check(of: VersionID, finding: String)

    /// What the frame binds the surface to, reference first.
    public var bound: [VersionID] {
        switch self {
        case .parts(let versions): return versions
        case .compare(let against, let candidates): return [against] + candidates
        case .check(let version, _): return [version]
        }
    }

    /// The thing at the top, when this shape has one.
    public var reference: VersionID? {
        switch self {
        case .parts: return nil
        case .compare(let against, _): return against
        case .check(let version, _): return version
        }
    }

    /// The surface kinds this shape belongs on.
    var surfaces: Set<SurfaceKind> {
        switch self {
        case .parts: return Set(SurfaceKind.gateA)
        case .compare: return [.compare]
        case .check: return [.check]
        }
    }
}

// MARK: - Why a choice was refused

/// What is wrong with a choice, written for the model that made it rather than for a log.
///
/// It carries a suggestion for the same reason `DirectorToolFailure` does: a band that is told
/// "bound must not be empty" tries again, and a band that is told "there is no version …" stops.
public struct DirectorChoiceProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public var reason: String
    public var suggestion: String?

    public init(_ reason: String, suggestion: String? = nil) {
        self.reason = reason
        self.suggestion = suggestion
    }

    public var description: String { suggestion.map { "\(reason) \($0)" } ?? reason }

    /// The same thing said as a tool result, so the model sees it in the round it made the mistake.
    public func failure(tool: String) -> DirectorToolFailure {
        DirectorToolFailure(tool: tool, reason: reason, suggestion: suggestion)
    }
}

// MARK: - The choice

/// One surface the Director chose, with everything the frame needs to open it.
///
/// **There is no public initializer.** `make(…, in:)` is the only way to build one, and it runs
/// every rule before it returns. That is what makes the guarantee structural: a `DirectorTurn`
/// holds `[DirectorSurfaceChoice]`, so the frame does not have to trust the Director and a test
/// does not have to assert that it filtered.
public struct DirectorSurfaceChoice: Sendable, Equatable, Hashable, Identifiable {

    /// How many levers one surface may carry. Rule 5.
    public static let maximumLevers = 2

    /// How many candidates a Compare may hold. Two is a choice; five is a menu, and the first proof
    /// asks for three.
    public static let candidateRange = 2...4

    public let surface: SurfaceKind
    public let title: String
    public let fill: DirectorFill
    public let levers: [SurfaceLever]
    /// One line saying why this surface and not another, in the song's own terms. Shown as the
    /// rationale when the choice becomes a proposal, and logged when it is opened directly.
    public let because: String

    private init(surface: SurfaceKind, title: String, fill: DirectorFill,
                 levers: [SurfaceLever], because: String) {
        self.surface = surface
        self.title = title
        self.fill = fill
        self.levers = levers
        self.because = because
    }

    public var id: String { "\(surface.rawValue)|\(fill.bound.map(\.description).joined(separator: ","))" }

    /// The choice as the frame's own vocabulary. Nothing is added here: a choice *is* a
    /// `SurfaceAction` plus the reasons it is allowed to be one.
    public var action: SurfaceAction {
        SurfaceAction(surface: surface, title: title, bound: fill.bound, levers: levers)
    }

    /// The choice as something the rail can offer rather than something already done.
    public func proposal(titled title: String? = nil, source: Proposal.Source = .director) -> Proposal {
        Proposal(title: title ?? self.title, rationale: because, action: action, source: source)
    }

    // MARK: The only way in

    /// Builds a choice, or says why it cannot be one.
    ///
    /// Six checks, in the order a reader would ask them:
    ///
    /// 1. it has a title;
    /// 2. the shape fits the surface (a Compare fill only on a Compare);
    /// 3. a Compare holds two to four distinct candidates and is not judged against one of them;
    /// 4. every bound version exists and is in a notation this surface can draw (rule 1);
    /// 5. at most two levers, no repeats, each one a quantity this surface can move, each value in
    ///    range (rule 5);
    /// 6. `stage.canPerform` — the frame's own gate, unchanged from Gate A.
    ///
    /// The last one is the important one. It is not a second opinion; it is the same function the
    /// rail filters Gate A's proposals through, so the Director is held to exactly the standard the
    /// song graph already sets rather than to one written for it.
    @MainActor
    public static func make(surface: SurfaceKind,
                            title: String,
                            fill: DirectorFill,
                            levers: [SurfaceLever] = [],
                            because: String,
                            in stage: any DirectorStage) throws -> DirectorSurfaceChoice {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DirectorChoiceProblem("A surface with no title is an unlabelled panel on the bench.",
                                        suggestion: "Give it the name a person would use: \"Bar 9 of Arrival\".")
        }

        guard fill.surfaces.contains(surface) else {
            throw DirectorChoiceProblem(
                "A \(surface.rawValue) cannot be filled that way.",
                suggestion: "\(surface.rawValue) takes \(Self.shape(for: surface)).")
        }

        if case .compare(let against, let candidates) = fill {
            guard candidateRange.contains(candidates.count) else {
                throw DirectorChoiceProblem(
                    "A Compare holds \(candidateRange.lowerBound) to \(candidateRange.upperBound) candidates; this one has \(candidates.count).",
                    suggestion: "Make the alternatives first, then compare them.")
            }
            guard Set(candidates).count == candidates.count else {
                throw DirectorChoiceProblem("Two of those candidates are the same version.")
            }
            guard !candidates.contains(against) else {
                throw DirectorChoiceProblem(
                    "The thing the candidates are judged against is also one of them.",
                    suggestion: "Judge them against what the song already has.")
            }
        }

        if case .check(_, let finding) = fill,
           finding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DirectorChoiceProblem("A Check with no finding has nothing to show.",
                                        suggestion: "Say the one thing you found, in the song's own numbers.")
        }

        // Notation. Every bound version has to exist and has to be something this surface draws.
        var types: [PartType] = []
        for id in fill.bound {
            guard let type = stage.partType(of: id) else {
                throw DirectorChoiceProblem("This song holds no version \(id.description).",
                                            suggestion: "Take version ids from read_song or from create_part_version.")
            }
            types.append(type)
        }
        guard let notation = types.first else {
            throw DirectorChoiceProblem("Nothing was bound to the \(surface.rawValue).",
                                        suggestion: "A surface with nothing in it answers nothing.")
        }
        for type in types where !surface.notation.contains(type) {
            throw DirectorChoiceProblem(
                "The \(surface.rawValue) cannot draw a \(type.rawValue).",
                suggestion: "It draws \(surface.notationSentence). Answer in the notation the question is about.")
        }
        if surface.isAnswer, types.contains(where: { $0 != notation }) {
            throw DirectorChoiceProblem(
                "A \(surface.rawValue) of a \(notation.rawValue) and a \(types.first { $0 != notation }!.rawValue) compares two different things.",
                suggestion: "Judge like against like.")
        }

        // Levers.
        guard levers.count <= maximumLevers else {
            throw DirectorChoiceProblem(
                "\(levers.count) levers on one surface; the limit is \(maximumLevers).",
                suggestion: "Keep the two that change what you hear most.")
        }
        guard Set(levers.map(\.quantity)).count == levers.count else {
            throw DirectorChoiceProblem("Two levers move the same quantity.")
        }
        for lever in levers {
            guard lever.quantity.surfaces.contains(surface) else {
                throw DirectorChoiceProblem(
                    "\(lever.quantity.rawValue) is not something the \(surface.rawValue) can move.",
                    suggestion: "On a \(surface.rawValue): \(Self.quantities(on: surface)).")
            }
            guard lever.quantity.range.contains(lever.value) else {
                throw DirectorChoiceProblem(
                    "\(lever.quantity.rawValue) is \(lever.value), outside \(lever.quantity.range.lowerBound)…\(lever.quantity.range.upperBound).")
            }
            guard !lever.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DirectorChoiceProblem("A lever with no label is an unnamed knob.")
            }
        }

        let choice = DirectorSurfaceChoice(surface: surface, title: title, fill: fill,
                                           levers: levers, because: because)
        guard stage.canPerform(choice.action) else {
            throw DirectorChoiceProblem(
                "The frame cannot open that right now.",
                suggestion: "Call read_song and bind to something the song actually holds.")
        }
        return choice
    }

    /// What shape a surface takes, for the sentence in a refusal.
    static func shape(for surface: SurfaceKind) -> String {
        switch surface {
        case .compare: return "a reference and two to four candidates"
        case .check: return "one part and one finding"
        case .importRecord, .chopLane, .grid, .sound: return "part versions, and no reference"
        }
    }

    /// The levers a surface can carry, listed.
    static func quantities(on surface: SurfaceKind) -> String {
        let names = SurfaceLever.Quantity.allCases.filter { $0.surfaces.contains(surface) }.map(\.rawValue)
        return names.isEmpty ? "no levers at all" : names.joined(separator: ", ")
    }
}

// MARK: - A proposal from the band

/// Something the Director offers rather than does.
///
/// It is built *from a choice*, which is the whole point: `Proposal` is a plain value with a public
/// initializer, so the guarantee cannot live there — but a `DirectorProposal` can only exist where a
/// validated `DirectorSurfaceChoice` exists, and `AppState.proposals` filters on `canPerform` a
/// second time at render. Two gates, and the interesting one is this one, because it fires while
/// the model is still in the round and can be told what it got wrong.
public struct DirectorProposal: Sendable, Equatable, Identifiable {
    public let choice: DirectorSurfaceChoice
    /// The verb on the control: "Try the dustier one".
    public let title: String
    public let source: Proposal.Source

    public init(choice: DirectorSurfaceChoice, title: String, source: Proposal.Source = .director) {
        self.choice = choice
        self.title = title
        self.source = source
    }

    public var id: String { "\(source.label)|\(choice.id)" }

    /// The value the rail already renders.
    public var proposal: Proposal { choice.proposal(titled: title, source: source) }
}
