import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// The conformer `Cast.swift` said had no conformer.
//
// `PersonaDirecting` is the personas' side of the seam: four calls, declared where the cast lives so
// that the cast never names the Director. This is the other side — the Director and the frame, seen
// through those four calls — and it is the only place in the app where a persona's opinion becomes
// something a user sees.
//
// What it is *not* is a second Director. `Director` already turns a sentence into work through the
// model and the toolbox; this turns a sentence into a `PersonaProposal`, which is a different and
// much smaller thing: an idea in the vocabulary of engine parameters, so the cast can check it
// against its own rules before anybody acts on it. The two meet in `ask(_:)`, where the cast's
// verdicts become rail lines attributed to the persona that said them and, when somebody refuses, a
// counter the user can press.

/// How a sentence becomes a proposal the cast can check.
///
/// A seam rather than a method, and the reason is honesty about what this step is. The doc comment
/// on `PersonaDirecting.proposal(for:)` calls it "the one genuinely model-shaped step", and it is —
/// but the shipped reader is deliberately *not* a model:
///
/// * a model call here would be a second prompt outside `DirectorPrompt`, which is the frozen
///   prefix every request in the session caches against;
/// * every test of the cast would then need a key or a transport double;
/// * and the enum it has to produce is closed. `PersonaProposal` names engine parameters, so the
///   only thing a reader can do is find the numbers a sentence states and name the ones it means.
///
/// So `EngineVocabularyReader` reads the quantities the sentence actually names and returns
/// `.outOfScope(what:)` when it names none — which is what that case is for, and produces two
/// honest deferrals rather than a guess. A model-backed reader conforms to this and drops in.
public protocol PersonaProposalReading: Sendable {
    /// - Parameters:
    ///   - utterance: what the user said.
    ///   - context: what the open song already is, so a proposal that needs a tempo has one.
    func read(_ utterance: String, context: PersonaReadingContext) -> PersonaProposal
}

/// What the reader knows about the song the sentence was said over.
public struct PersonaReadingContext: Sendable, Equatable {
    public var tempo: Double
    /// The idiom the song is in, when anything has said. "hip-hop" is the instrument's centre of
    /// gravity and the honest default for a song nobody has labelled.
    public var idiom: String
    /// The ghost ratio of the newest groove, for a sentence about taking ghosts out.
    public var ghostRatio: Double
    /// Transients in the bar under discussion, for a sentence about how many slices to cut.
    public var sourceTransients: Int
    /// Where the source's energy stops, in Hz.
    ///
    /// Defaults to full band rather than to zero, and the reason is a refusal the Sampler makes: it
    /// turns a chain down when the source already stops below the chain's corner. That is a true and
    /// useful rule *given a measurement*, and a default of 0 would make it fire on every unmeasured
    /// source with the sentence "the source already stops at 0 Hz", which is the app inventing a
    /// number. Failing full-band fails towards letting the chain through and saying so.
    public var sourceBandwidthHz: Double
    public var sourceNoiseFloorDB: Double

    public init(tempo: Double = 90, idiom: String = "hip-hop", ghostRatio: Double = 0,
                sourceTransients: Int = 0, sourceBandwidthHz: Double = 20_000,
                sourceNoiseFloorDB: Double = -60) {
        self.tempo = tempo
        self.idiom = idiom
        self.ghostRatio = ghostRatio
        self.sourceTransients = sourceTransients
        self.sourceBandwidthHz = sourceBandwidthHz
        self.sourceNoiseFloorDB = sourceNoiseFloorDB
    }
}

/// The shipped reader: the quantities this instrument can move, found in a sentence.
///
/// Every branch below produces a proposal whose parameters came from the sentence or from the song,
/// never from a guess. A sentence that names no quantity is `.outOfScope`, and the cast's answer to
/// that — two deferrals — is the correct answer: nobody in this cast can check "make it better".
public struct EngineVocabularyReader: PersonaProposalReading {
    public init() {}

    public func read(_ utterance: String, context: PersonaReadingContext) -> PersonaProposal {
        let text = utterance.lowercased()

        // Swing, as a percentage the sentence states. "swing 62", "the swing at 62", "62% swing" —
        // the word and the number, in either order and with whatever is between them.
        if text.contains("swing"),
           let percent = Self.percentage(in: text) ?? Self.number(after: ["swing"], in: text)
               ?? Self.firstNumber(in: text) {
            return .setSwing(percent: percent, idiom: context.idiom, tempo: context.tempo)
        }
        if text.contains("straight") || text.contains("quantise") || text.contains("quantize")
            || text.contains("on the grid") {
            return .quantiseHard(idiom: context.idiom)
        }

        // A named voice, displaced by a stated number of milliseconds.
        if let voice = Self.voice(in: text), let ms = Self.milliseconds(in: text) {
            let late = text.contains("early") || text.contains("ahead") ? -abs(ms) : abs(ms)
            return .displaceVoice(voice: voice, milliseconds: late, tempo: context.tempo)
        }
        if let ms = Self.milliseconds(in: text),
           text.contains("humanis") || text.contains("humaniz") || text.contains("jitter")
            || text.contains("loose") {
            return .setHumanizeTiming(milliseconds: ms, tempo: context.tempo)
        }

        if text.contains("ghost") && (text.contains("out") || text.contains("remove")
            || text.contains("without") || text.contains("no ghost")) {
            return .removeGhosts(currentRatio: context.ghostRatio, idiom: context.idiom)
        }

        // Chopping: how many pieces out of a bar.
        if let slices = Self.number(before: ["slice", "slices", "piece", "pieces", "chop", "chops"], in: text),
           text.contains("chop") || text.contains("slice") || text.contains("piece") {
            return .chopDensity(slicesPerBar: Int(slices.rounded()),
                                sourceTransients: context.sourceTransients)
        }
        if let ms = Self.milliseconds(in: text), text.contains("cut") || text.contains("transient") {
            return .moveCutLate(milliseconds: ms)
        }

        // The chain. "Dustier" is this instrument's own word for it and the presets are named, so a
        // sentence that says one is read as that one and a sentence that only says "dusty" is read
        // as the twelve-bit sampler the word comes from.
        if let preset = Self.degradePreset(in: text) {
            return .applyDegrade(preset: preset,
                                 sourceBandwidthHz: context.sourceBandwidthHz,
                                 sourceNoiseFloorDB: context.sourceNoiseFloorDB)
        }
        if text.contains("leave it") || text.contains("leave the source") || text.contains("as it is") {
            return .leaveAlone(sourceBandwidthHz: context.sourceBandwidthHz)
        }

        return .outOfScope(what: utterance.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Reading numbers out of a sentence

    static let voices = ["kick", "snare", "hat", "hihat", "hi-hat", "clap", "rim"]

    static func voice(in text: String) -> String? {
        voices.first { text.contains($0) }.map { $0 == "hihat" || $0 == "hi-hat" ? "hat" : $0 }
    }

    /// "18 ms", "18ms", "18 milliseconds".
    static func milliseconds(in text: String) -> Double? {
        number(before: ["ms", "millisecond", "milliseconds"], in: text)
    }

    static func percentage(in text: String) -> Double? {
        number(before: ["%", "percent"], in: text)
    }

    /// The number immediately before one of `units`.
    static func number(before units: [String], in text: String) -> Double? {
        let tokens = self.tokens(text)
        for (index, token) in tokens.enumerated() {
            // "18ms" arrives as one token; "18 ms" as two.
            for unit in units where token.hasSuffix(unit) && token.count > unit.count {
                if let value = Double(token.dropLast(unit.count)) { return value }
            }
            guard units.contains(token), index > 0, let value = Double(tokens[index - 1]) else { continue }
            return value
        }
        return nil
    }

    /// The number immediately after one of `words`: "swing 62".
    static func number(after words: [String], in text: String) -> Double? {
        let tokens = self.tokens(text)
        for (index, token) in tokens.enumerated() where words.contains(token) {
            guard index + 1 < tokens.count, let value = Double(tokens[index + 1]) else { continue }
            return value
        }
        return nil
    }

    /// The first number anywhere in the sentence. Only ever reached once a branch has established
    /// which quantity the sentence is about, so "at 62" in a sentence about swing is 62 percent.
    static func firstNumber(in text: String) -> Double? {
        tokens(text).compactMap(Double.init).first
    }

    static func degradePreset(in text: String) -> String? {
        for preset in DegradeSettings.Preset.allCases where preset != .clean {
            if text.contains(preset.rawValue) { return preset.rawValue }
        }
        if text.contains("dust") || text.contains("dirt") || text.contains("grit")
            || text.contains("lo-fi") || text.contains("lofi") || text.contains("crunch") {
            return DegradeSettings.Preset.sp1200.rawValue
        }
        if text.contains("tape") || text.contains("cassette") {
            return DegradeSettings.Preset.cassette.rawValue
        }
        if text.contains("vinyl") || text.contains("record crackle") {
            return DegradeSettings.Preset.vinyl.rawValue
        }
        return nil
    }

    /// Words and numbers, punctuation dropped except the `%` and the decimal point.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "%" && $0 != "-" })
            .map(String.init)
            .flatMap { token -> [String] in
                guard token.hasSuffix("%"), token.count > 1 else { return [token] }
                return [String(token.dropLast()), "%"]
            }
    }
}

// MARK: - The conformer

/// The band, wired: the cast on one side, the Director's stage and the frame's surfaces on the other.
///
/// Held by `AppState` for the life of the session, because `CompareModel` and `CheckModel` hold
/// their hosts weakly and something has to own this.
@MainActor
final class BandDirector: PersonaDirecting {

    private let app: AppState
    private let stage: any DirectorStage
    private let wiring: SurfaceWiring
    /// `nonisolated` because `proposal(for:)` is: the protocol declares that call without an actor,
    /// on purpose, since a persona's opinion is a pure function of a proposal.
    nonisolated let cast: Cast
    nonisolated let board: CriticBoard
    nonisolated let reader: any PersonaProposalReading

    init(app: AppState,
                stage: (any DirectorStage)? = nil,
                wiring: SurfaceWiring = .shared,
                cast: Cast = .standard,
                board: CriticBoard = .standard,
                reader: any PersonaProposalReading = EngineVocabularyReader()) {
        self.app = app
        self.stage = stage ?? AppStateStage(app)
        self.wiring = wiring
        self.cast = cast
        self.board = board
        self.reader = reader
    }

    // MARK: PersonaDirecting

    /// Turns a sentence into something the cast can check.
    ///
    /// `nonisolated` on purpose: the protocol declares this without an actor, because a persona's
    /// opinion is a pure function and nothing about reading a sentence needs the frame. The one
    /// thing it does need — what the open song is — is gathered on the main actor first.
    nonisolated func proposal(for utterance: String) async throws -> PersonaProposal {
        let context = await MainActor.run { self.context }
        return reader.read(utterance, context: context)
    }

    /// Opens a Compare with these candidates, through the same gate the Director's own choices go
    /// through.
    ///
    /// The validation is not repeated here, it is *reused*: `DirectorSurfaceChoice.make` runs the
    /// five rules and `AppState.canPerform`, so a persona cannot open a comparison the Director
    /// would have been refused. What this adds is the brief — the readings, the rationales, who
    /// proposed what — which is the part that is not in the graph and therefore not in a choice.
    @discardableResult
    func openCompare(title: String, reference: CompareReference,
                            candidates: [CompareCandidate], features: [Feature],
                            levers: [CompareLever]) throws -> SurfaceID {
        guard let against = reference.version else {
            throw DirectorChoiceProblem(
                "\(reference.title) is not a version in this song, so there is nothing at the top of "
                    + "the comparison.",
                suggestion: "Judge the candidates against what the song already has.")
        }
        let versions = candidates.compactMap { $0.version?.id }
        guard versions.count == candidates.count else {
            throw DirectorChoiceProblem(
                "\(candidates.count - versions.count) of those candidates have no version behind them.",
                suggestion: "Record each one first; a row you cannot take is a row you cannot judge.")
        }
        let choice = try DirectorSurfaceChoice.make(
            surface: .compare, title: title,
            fill: .compare(against: against, candidates: versions),
            levers: levers.compactMap(Self.lever(from:)),
            because: "\(candidates.count) alternatives against \(reference.title) — \(reference.kind).",
            in: stage)
        guard let id = stage.open(choice) else {
            throw DirectorChoiceProblem("The frame would not open that Compare.")
        }
        app.file(.compare(CompareBrief(title: title, reference: reference, candidates: candidates,
                                       features: features, levers: levers,
                                       vocabulary: vocabulary(for: candidates))),
                 for: id)
        return id
    }

    /// Opens a Check on one finding.
    ///
    /// Not validated through `DirectorSurfaceChoice`, and that is deliberate: a finding comes from a
    /// critic that has already run over a part this song holds, so there is nothing left to check
    /// that the critic did not. What the frame is given is the finding itself, whole — the
    /// measurement, the locus and the two fixes — rather than a sentence about it.
    @discardableResult
    func openCheck(_ finding: Finding) -> SurfaceID {
        let bound = subject(of: finding).map { [$0] } ?? []
        let id = app.openSurface(.check, title: "\(finding.criticName): \(finding.subject.named)",
                                 bound: bound)
        app.file(.check(finding), for: id)
        // The card is the finding; the rail is where the band says it found something. Attributed to
        // the persona whose standard it is, so a check that fires reads as somebody noticing rather
        // than as the app complaining.
        app.note(.persona(personaName(finding.persona)), finding.headline,
                 detail: "\(finding.why) \(finding.measurement.description)")
        return id
    }

    /// Draws a critic's findings as marks, and does nothing else with them.
    ///
    /// The one place the catalog's fourth rule could be broken, and it is kept by what is missing:
    /// there is no call from here to `apply`. A finding becomes a mark on the lane it belongs to and
    /// a line in the rail, and it waits.
    func mark(_ findings: [Finding], on surface: SurfaceID) {
        guard !findings.isEmpty else { return }
        let landed = wiring.chopBinding(holding: surface)?.mark(findings.map(\.mark)) ?? false
        guard !landed else { return }
        // A surface that cannot carry a mark still has to say what was found: silently dropping a
        // critic's finding is the one failure that looks exactly like the critic never running.
        for finding in findings {
            app.note(.persona(personaName(finding.persona)), finding.headline,
                     detail: finding.measurement.description)
        }
    }

    // MARK: Putting a question to the band

    /// What a proposal reaches the user as.
    struct BandAnswer: Sendable {
        var proposal: PersonaProposal
        /// Every persona's verdict, in cast order.
        var verdicts: [(persona: PersonaID, verdict: PersonaVerdict)]
        /// The persona whose competence it fell in, or nil when everybody deferred.
        var owner: PersonaID?
        /// True when somebody refused. The counter is in that verdict's own words.
        var wasRefused: Bool { verdicts.contains { $0.verdict.isRefusal } }
    }

    /// Puts one sentence to the whole cast and writes what each of them said into the rail.
    ///
    /// This is the path gap 2 exists for. A persona's line lands as `SessionEntry.Source.persona`,
    /// which the rail already draws in the accent because `isBand` is true for it — nothing was
    /// added to the rail to make that work, which is the point of having built it that way.
    @discardableResult
    func ask(_ utterance: String) async -> BandAnswer {
        let proposal = (try? await self.proposal(for: utterance)) ?? .outOfScope(what: utterance)
        let verdicts = cast.ask(proposal)
        for (persona, verdict) in verdicts {
            // A deferral is not a line worth spending the rail on unless *everybody* deferred, which
            // is the case the next block covers: "not my department" from a persona that was never
            // asked directly is noise.
            guard !Self.isDeferral(verdict) else { continue }
            app.note(.persona(personaName(persona)), verdict.spoken,
                     detail: verdict.refusedByRule.map { "refused by \($0)" })
        }
        if verdicts.allSatisfy({ Self.isDeferral($0.verdict) }) {
            app.note(.session, "Nobody in the band takes that one",
                     detail: "The cast covers feel, swing and pocket, and the source, the chop and the "
                         + "chain. Say it in one of those and somebody will have an opinion.")
        }
        return BandAnswer(proposal: proposal, verdicts: verdicts, owner: cast.owner(of: proposal))
    }

    // MARK: What the frame knows

    /// The song, as the reader needs it.
    var context: PersonaReadingContext {
        guard let song = app.song else { return PersonaReadingContext() }
        var context = PersonaReadingContext(tempo: song.tempo)
        if let version = Guidance.grooves(in: song).last, case .groove(let groove) = version.kind {
            let observation = GrooveObservation(label: PartLabel.title(of: version), groove: groove,
                                                options: GrooveRenderOptions(), tempo: song.tempo)
            context.ghostRatio = observation.ghostRatio
        }
        if let version = Guidance.samples(in: song).last, case .sample(let sample) = version.kind {
            context.sourceTransients = sample.slices.count
        }
        // Nyquist of whatever the song was recorded at, capped at the top of hearing. Not a
        // measurement of the source's own rolloff — that costs a transform and nobody has run one —
        // but it is the honest ceiling, and it is the number that keeps the Sampler's
        // "corner above the source" refusal from firing on a source nobody has measured.
        if let take = Guidance.take(in: song), case .audio(let audio) = take.kind, audio.sampleRate > 0 {
            context.sourceBandwidthHz = min(20_000, audio.sampleRate / 2)
        }
        return context
    }

    /// The persona's own name, as the rail prints it: "Beatmaker", not "beatmaker".
    private func personaName(_ id: PersonaID) -> String {
        cast.persona(id)?.bible.name ?? id.rawValue.capitalized
    }

    /// Whose feature vocabulary decides what counts as a difference on this comparison: the persona
    /// that proposed the rows, when one did.
    private func vocabulary(for candidates: [CompareCandidate]) -> PersonaBible {
        for candidate in candidates {
            if let id = candidate.proposedBy, let persona = cast.persona(id) { return persona.bible }
        }
        return Beatmaker.bible
    }

    /// The version a finding is about, from the surfaces currently open on the bench.
    ///
    /// A `Finding` names a slice or a step, not a version — critics are pure functions over engine
    /// values and deliberately know nothing about the graph — so the part it belongs to is whatever
    /// the frame has open of that notation.
    private func subject(of finding: Finding) -> VersionID? {
        guard let song = app.song else { return nil }
        switch finding.subject {
        case .slice, .source: return Guidance.samples(in: song).last?.id
        case .step, .bar: return Guidance.grooves(in: song).last?.id
        }
    }

    static func isDeferral(_ verdict: PersonaVerdict) -> Bool {
        if case .defer_ = verdict { return true }
        return false
    }
}

// MARK: - Levers

extension BandDirector {
    /// A Compare lever as a frame lever, when the frame has a quantity for it.
    ///
    /// `CompareLever` and `SurfaceLever.Quantity` are two vocabularies for the same knobs and
    /// neither is a subset of the other: the surface's `ghostLevel` is the frame's `density`, and
    /// its `degradeMix` is `dust`. Mapping them here rather than merging the enums keeps the
    /// surface's own contract — at most two levers, applied to every row — where it is written.
    static func lever(from lever: CompareLever) -> SurfaceLever? {
        switch lever {
        case .tempo: return SurfaceLever(quantity: .tempo, label: lever.label, value: lever.defaultValue)
        case .swing: return SurfaceLever(quantity: .swing, label: lever.label, value: lever.defaultValue)
        case .ghostLevel: return SurfaceLever(quantity: .density, label: lever.label, value: lever.defaultValue)
        case .degradeMix: return SurfaceLever(quantity: .dust, label: lever.label, value: lever.defaultValue)
        case .lag: return SurfaceLever(quantity: .lag, label: lever.label, value: lever.defaultValue)
        }
    }
}

extension CompareLever {
    /// The other direction: a lever the Director validated, as the lever the surface draws.
    ///
    /// Nil for the quantities a Compare has no control for — `pitch` and `gain` move a sound rather
    /// than a comparison — so a surface opened with one simply does not draw it, which is better
    /// than drawing a knob that moves nothing.
    init?(quantity: SurfaceLever) {
        switch quantity.quantity {
        case .tempo: self = .tempo
        case .swing: self = .swing
        case .density: self = .ghostLevel
        case .dust: self = .degradeMix
        case .lag: self = .lag
        case .velocity, .pitch, .gain: return nil
        }
    }
}
