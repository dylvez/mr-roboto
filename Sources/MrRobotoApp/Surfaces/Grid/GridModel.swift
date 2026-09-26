import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

// MARK: - Surface identity

/// The Grid surface's entry in the catalog.
public struct GridSurface: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .grid }
    public var bound: [VersionID]
    public var title: String

    public init(id: SurfaceID = SurfaceID(), bound: [VersionID] = [], title: String = "Grid") {
        self.id = id
        self.bound = bound
        self.title = title
    }
}

// MARK: - Painting

/// What a drag is doing to the steps it crosses.
///
/// The first cell of a drag decides: starting on a rest paints the brush tier, starting on a hit
/// erases. Every machine with a step grid works this way and it is the only behaviour that makes a
/// mistake fixable with the same gesture that made it.
public enum GridPaintMode: Sendable, Equatable {
    case paint(VelocityTier)
    case erase
}

/// One cell of the grid, as the view draws it.
public struct GridCell: Sendable, Equatable, Identifiable {
    public var voice: DrumVoice
    public var step: Int
    public var tier: VelocityTier
    /// The MIDI velocity this cell would actually play, tier map and per-voice scaling included.
    public var velocity: Int

    public var id: String { "\(voice.rawValue)#\(step)" }
}

// MARK: - The model

/// The Grid surface's model: a step grid over a `SongGraph.Groove`, played by the groove engine.
///
/// Nothing here is a private pattern format. The grid *is* a `Groove` — steps per bar, bars, a swing
/// factor and one `GroovePattern` per voice — so every edit is a new version of a part the rest of
/// the app already understands, and loading a feel is nothing more exotic than adopting its groove.
@MainActor
@Observable
public final class GridModel {

    // MARK: Identity

    public let surfaceID = SurfaceID()

    public var surface: GridSurface {
        GridSurface(id: surfaceID, bound: versions.map(\.id), title: title)
    }

    /// "Motown, 104" — the feel and the tempo, which is what the header of a grid should say.
    public var title: String {
        let tempoText = String(format: "%.0f", tempo)
        if let feelName { return "\(feelName), \(tempoText)" }
        return "Grid, \(tempoText)"
    }

    // MARK: The pattern

    /// Voice order, top row first. Kept explicitly so a round trip through `Groove` preserves it.
    public private(set) var voices: [DrumVoice]
    public private(set) var steps: [DrumVoice: [VelocityTier]]
    public private(set) var stepsPerBar: Int
    public private(set) var bars: Int

    // MARK: The levers

    /// The stored 0…1 factor. `swingPercent` is what the lever shows.
    public private(set) var swing: Swing
    public private(set) var velocities: VelocityMap
    public private(set) var humanize: Humanize
    public private(set) var voiceFeels: [DrumVoice: VoiceFeel]
    public private(set) var tempo: Double
    public private(set) var timeSignature: TimeSignature

    /// The tier a drag paints with. Modifier keys set it; so does the tier picker.
    public var brush: VelocityTier = .normal

    // MARK: Machine and feel

    public private(set) var machine: SynthMachine
    /// Every machine `Instrument` can synthesize: 808, 909, LinnDrum.
    public var machines: [SynthMachine] { SynthMachine.all }

    /// A chop this groove can play on instead of a machine: the one it plays on, or the one it
    /// was made from. Nil offers machines only.
    public struct ChopKit: Equatable, Sendable {
        public var part: PartID
        /// What the ledger calls the chop: "Bar 9".
        public var name: String

        public init(part: PartID, name: String) {
            self.part = part
            self.name = name
        }
    }

    public private(set) var chopKit: ChopKit?
    /// True when the steps play the chop's slices rather than `machine`.
    public private(set) var playsOnChop = false

    /// Offer a chop as this groove's kit. `playing` says whether the song already plays it there.
    public func offer(_ chop: ChopKit, playing: Bool) {
        chopKit = chop
        playsOnChop = playing
    }

    /// Put the steps on the offered chop's slices, and play a kick on them.
    public func playOnChop() {
        guard let chopKit, !playsOnChop else { return }
        playsOnChop = true
        lastError = nil
        host.chopChosen(chopKit.part, for: (versions.last ?? base)?.partID)
        Task { @MainActor [host] in await host.audition(.kick, velocity: 110) }
    }

    public private(set) var feelName: String?
    /// Where the loaded feel came from. Kept because a persona will cite it out loud.
    public private(set) var provenance: Provenance?
    public var feelLibrary: FeelLibrary

    // MARK: Versions

    /// The version this grid was opened against, when it was opened against one.
    public private(set) var base: PartVersion?
    /// Versions this surface has made, oldest first.
    public private(set) var versions: [PartVersion] = []
    public private(set) var lastError: String?
    /// The version the last keep made, for the header to say so. Nil until one is kept, and set
    /// aside again — by `hasUnkeptChanges` turning true — once the pattern moves on from it.
    public private(set) var lastKept: PartVersion?

    /// Whether the groove on screen differs from the last version kept, or from the one the grid
    /// was opened on. Only the groove counts: it is what a keep files. Tempo, the machine and the
    /// tier map are how it is heard here, not what it is. A fresh grid has something to keep once
    /// a step is painted, and nothing before.
    public var hasUnkeptChanges: Bool {
        guard let kept = versions.last ?? base, case .groove(let keptGroove) = kept.kind else { return isPainted }
        return keptGroove != groove
    }

    /// True once any step is a hit.
    public var isPainted: Bool {
        steps.values.contains { row in row.contains { $0 != .rest } }
    }

    /// Everything an edit can change — a feel load changes nearly all of it at once — held together
    /// so ⌘Z puts back all of it or none of it. One of these per edit.
    public struct Snapshot: Sendable, Equatable {
        let voices: [DrumVoice]
        let steps: [DrumVoice: [VelocityTier]]
        let stepsPerBar: Int
        let bars: Int
        let swing: Swing
        let velocities: VelocityMap
        let humanize: Humanize
        let voiceFeels: [DrumVoice: VoiceFeel]
        let timeSignature: TimeSignature
        let tempo: Double
        let feelName: String?
        let provenance: Provenance?
    }

    /// The chain the groove plays through, carried across an edit untouched: painting a step is not
    /// a request to clean the groove. The Grid does not draw or move it — that is the Sound surface's.
    public private(set) var degradation: [Degradation] = []

    // MARK: Collaborators

    private let host: any GridHosting
    private var paintMode: GridPaintMode?

    // MARK: Keeping as it goes

    /// Every edit, for ⌘Z. A drag is one entry, however many cells it crossed.
    private var history = EditHistory<Snapshot>()
    /// The grid as it stood when the current drag began.
    private var paintBefore: Snapshot?
    /// Keeps the groove a moment after the last edit. A test sets its delay to nil and keeps by hand.
    public let autoKeep = AutoKeep()

    // MARK: The Beatmaker

    /// What the Beatmaker says about the groove on screen, rule by rule, refreshed after every edit.
    /// Empty while nothing is painted: a silent grid has no pocket to read, and "swing 50 %, outside
    /// the corpus" said about silence is noise.
    ///
    /// Read from the grid's own render options — its velocities, swing, pocket and humanize — rather
    /// than from a groove stripped of them, because those are most of what the Beatmaker reads. It is
    /// arithmetic over a few hundred steps, so it runs on every edit without a debounce.
    public private(set) var readings: [PersonaReading] = []
    private let beatmaker = Beatmaker()

    /// The readings that did not hold: what the Beatmaker would say first.
    public var flags: [PersonaReading] { readings.filter { !$0.holds } }
    /// The readings that held.
    public var holds: [PersonaReading] { readings.filter(\.holds) }

    // MARK: Init

    public init(host: any GridHosting,
                groove: Groove = GridModel.emptyGroove(),
                tempo: Double = 90,
                timeSignature: TimeSignature = .fourFour,
                machine: SynthMachine = .tr808,
                velocities: VelocityMap = .standard,
                humanize: Humanize = .none,
                voiceFeels: [DrumVoice: VoiceFeel] = [:],
                feelLibrary: FeelLibrary = .standard) {
        self.host = host
        voices = groove.patterns.map(\.voice)
        steps = Dictionary(uniqueKeysWithValues: groove.patterns.map { ($0.voice, $0.steps) })
        stepsPerBar = max(1, groove.stepsPerBar)
        bars = max(1, groove.bars)
        swing = Swing(factor: groove.swing)
        degradation = groove.degradation
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.machine = machine
        self.velocities = velocities
        self.humanize = humanize
        self.voiceFeels = voiceFeels
        self.feelLibrary = feelLibrary
        refreshReadings()
    }

    /// A grid opened against an existing groove version, so edits derive from it.
    public convenience init(host: any GridHosting, version: PartVersion, tempo: Double = 90,
                            timeSignature: TimeSignature = .fourFour, machine: SynthMachine = .tr808) {
        guard case .groove(let groove) = version.kind else {
            self.init(host: host, tempo: tempo, timeSignature: timeSignature, machine: machine)
            return
        }
        self.init(host: host, groove: groove, tempo: tempo, timeSignature: timeSignature, machine: machine)
        base = version
    }

    /// A silent 16-step bar over the usual five voices: what an empty grid looks like.
    public static func emptyGroove(stepsPerBar: Int = 16, bars: Int = 1,
                                   voices: [DrumVoice] = [.kick, .snare, .closedHat, .openHat, .clap]) -> Groove {
        Groove(stepsPerBar: stepsPerBar, bars: bars, swing: 0,
               patterns: voices.map {
                   GroovePattern(voice: $0, steps: Array(repeating: .rest, count: stepsPerBar * bars))
               })
    }

    // MARK: Reading the grid

    public var stepCount: Int { stepsPerBar * bars }

    /// Steps per beat: 4 for sixteenths in 4/4.
    public var stepsPerBeat: Int { max(1, stepsPerBar / max(1, timeSignature.beatsPerBar)) }

    public func tier(_ voice: DrumVoice, step: Int) -> VelocityTier {
        guard let row = steps[voice], row.indices.contains(step) else { return .rest }
        return row[step]
    }

    /// The MIDI velocity a step would play: the tier's figure from the map, scaled by the voice's
    /// own feel. This is the number the grid renders a cell's weight from, and the one the renderer
    /// will use.
    public func velocity(_ voice: DrumVoice, step: Int) -> Int {
        let tier = tier(voice, step: step)
        guard tier != .rest else { return 0 }
        let scale = voiceFeels[voice]?.velocityScale ?? 1
        return min(127, max(0, Int((Double(velocities[tier]) * scale).rounded())))
    }

    public func cell(_ voice: DrumVoice, step: Int) -> GridCell {
        GridCell(voice: voice, step: step, tier: tier(voice, step: step), velocity: velocity(voice, step: step))
    }

    /// True on the steps swing moves, so the view can mark the lever's effect on the grid itself.
    public func isSwung(step: Int) -> Bool { swing.isSwung(step: step) }

    /// True on the first step of every bar after the first, where the view draws a bar line.
    public func startsBar(step: Int) -> Bool {
        step > 0 && step < stepCount && step % stepsPerBar == 0
    }

    /// What the ruler says over a step. A one-bar grid counts its beats, 1 to 4, as it always has.
    /// Past one bar the bar number leads, the way a sequencer counts: "2" where bar two starts and
    /// "2.3" on its third beat — a bare "3" would not say which bar it was in.
    public func rulerLabel(step: Int) -> String {
        guard step % stepsPerBeat == 0 else { return "" }
        let beat = (step % stepsPerBar) / stepsPerBeat + 1
        guard bars > 1 else { return "\(beat)" }
        let bar = step / stepsPerBar + 1
        return beat == 1 ? "\(bar)" : "\(bar).\(beat)"
    }

    /// The pattern as the graph stores it. The round trip: `GridModel(groove: g).groove == g`.
    public var groove: Groove {
        Groove(stepsPerBar: stepsPerBar, bars: bars, swing: swing.factor,
               patterns: voices.map { GroovePattern(voice: $0, steps: steps[$0] ?? []) },
               degradation: degradation)
    }

    /// Everything the groove engine needs beyond the pattern.
    public var renderOptions: GrooveRenderOptions {
        GrooveRenderOptions(velocities: velocities, swing: swing, humanize: humanize, voices: voiceFeels)
    }

    // MARK: Editing steps

    /// Click: the step takes the brush tier, and a step already at that tier becomes a rest. So a
    /// click puts down what the brush says whatever was there, and a second click takes it back
    /// up — the brush picker means what it shows. Auditions either way, because hearing what you
    /// just removed is how you know you removed the right one.
    public func toggle(_ voice: DrumVoice, step: Int) {
        let paint: VelocityTier = brush == .rest ? .normal : brush
        let next: VelocityTier = tier(voice, step: step) == paint ? .rest : paint
        set(next, voice: voice, step: step)
    }

    /// ⌥-click on the same step walks the tiers: normal → accent → ghost → rest.
    public func cycle(_ voice: DrumVoice, step: Int) {
        let next: VelocityTier
        switch tier(voice, step: step) {
        case .rest: next = .normal
        case .normal: next = .accent
        case .accent: next = .ghost
        case .ghost: next = .rest
        }
        set(next, voice: voice, step: step)
    }

    /// Sets a step outright. The tier picker and the modifier-held click both land here.
    public func set(_ tier: VelocityTier, voice: DrumVoice, step: Int) {
        guard var row = steps[voice], row.indices.contains(step), row[step] != tier else { return }
        let before = snapshot
        row[step] = tier
        steps[voice] = row
        if tier != .rest { play(voice, velocity: velocity(voice, step: step)) }
        // A drag records itself once, when it ends; a click is its own edit.
        if paintMode == nil { edited(from: before) } else { push() }
    }

    // MARK: Painting

    /// The first cell of a drag. Whether the drag paints or erases is decided here and held for the
    /// whole gesture.
    public func beginPaint(_ voice: DrumVoice, step: Int, tier: VelocityTier? = nil) {
        let brushTier = tier ?? brush
        paintBefore = snapshot
        paintMode = self.tier(voice, step: step) == .rest ? .paint(brushTier) : .erase
        continuePaint(voice, step: step)
    }

    /// Every cell the drag crosses after the first.
    public func continuePaint(_ voice: DrumVoice, step: Int) {
        guard let paintMode else { return }
        switch paintMode {
        case .paint(let tier):
            guard self.tier(voice, step: step) != tier else { return }
            set(tier, voice: voice, step: step)
        case .erase:
            guard self.tier(voice, step: step) != .rest else { return }
            set(.rest, voice: voice, step: step)
        }
    }

    public func endPaint() {
        paintMode = nil
        if let before = paintBefore { edited(from: before) }
        paintBefore = nil
    }

    /// Clears one voice's row.
    public func clear(_ voice: DrumVoice) {
        guard steps[voice] != nil else { return }
        let before = snapshot
        steps[voice] = Array(repeating: .rest, count: stepCount)
        edited(from: before)
    }

    public func clearAll() {
        let before = snapshot
        for voice in voices { steps[voice] = Array(repeating: .rest, count: stepCount) }
        edited(from: before)
    }

    // MARK: Length

    /// The lengths the grid offers. Any count in `barRange` is a legal groove; these are the ones a
    /// loop is actually made at.
    public static let lengthChoices = [1, 2, 4, 8]
    /// Sixteen bars of sixteenths is 256 steps a row, which is already more than a grid is for.
    public static let barRange = 1...16

    /// Sets how many bars the loop is. Lengthening repeats what is there, bar by bar, into the new
    /// bars — a one-bar beat becomes four bars of the same beat, ready to vary — because an empty
    /// three bars after a full one is a gap, not a longer groove. Shortening drops the bars past the
    /// new end; ⌘Z brings them back.
    public func setBars(_ count: Int) {
        let target = min(Self.barRange.upperBound, max(Self.barRange.lowerBound, count))
        guard target != bars else { return }
        let before = snapshot
        let oldCount = stepCount
        let newCount = stepsPerBar * target
        for voice in voices {
            let row = steps[voice] ?? []
            // Read as exactly the old length first, so a row stored short or long still repeats
            // from its own first bar.
            let old = (0..<oldCount).map { $0 < row.count ? row[$0] : VelocityTier.rest }
            steps[voice] = (0..<newCount).map { old[$0 % max(1, oldCount)] }
        }
        bars = target
        edited(from: before)
    }

    /// Whether doubling would stay inside `barRange`.
    public var canDoubleLength: Bool { bars * 2 <= Self.barRange.upperBound }

    /// Copies what is there once more: two bars become four, the second two a copy of the first.
    public func doubleLength() {
        guard canDoubleLength else { return }
        setBars(bars * 2)
    }

    // MARK: Voices

    /// Every voice a row can be: the twelve the synthesized machines have sounds for, in the order a
    /// kit lists them, and `perc`, which the feels and MIDI import write but no machine here plays.
    public static let knownVoices: [DrumVoice] = {
        var voices = SynthVoiceKind.allCases.map(\.drumVoice)
        if !voices.contains(.perc) { voices.append(.perc) }
        return voices
    }()

    /// The voices a "+ Voice" menu offers: every known voice not already a row.
    public var addableVoices: [DrumVoice] {
        Self.knownVoices.filter { !voices.contains($0) }
    }

    /// Whether the current machine has a sound for this voice. A row it has none for still paints
    /// and keeps — another kit may play it — but on this machine it is silent, and the grid says so.
    public func machineSounds(_ voice: DrumVoice) -> Bool {
        // A chop has a slice for every voice: the class that voice asks for, or the closest.
        playsOnChop || machine.voices.contains { $0.kind.drumVoice == voice }
    }

    /// What the steps play on, as the grid names it.
    public var kitName: String {
        if playsOnChop, let chopKit { return "\(chopKit.name)'s slices" }
        return machine.name
    }

    /// A voice as a person says it: "closed hat", not "closedHat".
    public static func name(of voice: DrumVoice) -> String {
        var words = ""
        for character in voice.rawValue {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(Character(character.lowercased()))
        }
        return words
    }

    /// Appends an empty row for a voice the grid does not have yet.
    public func addVoice(_ voice: DrumVoice) {
        guard !voices.contains(voice) else { return }
        let before = snapshot
        voices.append(voice)
        steps[voice] = Array(repeating: .rest, count: stepCount)
        edited(from: before)
    }

    /// Whether a row can go: the last one cannot, so the grid is always a grid.
    public var canRemoveVoice: Bool { voices.count > 1 }

    /// Drops a voice's row, hits and all. The voice's own feel — its lag, its swing — stays in the
    /// pocket, so adding the row back plays where it did.
    public func removeVoice(_ voice: DrumVoice) {
        guard canRemoveVoice, voices.contains(voice) else { return }
        let before = snapshot
        voices.removeAll { $0 == voice }
        steps[voice] = nil
        edited(from: before)
    }

    // MARK: The swing lever

    /// What the lever shows: 50 % straight, 66.67 % triplet, 75 % the MPC's maximum.
    ///
    /// The graph stores a 0…1 factor and `Performance.Swing` does the conversion; nothing in this
    /// surface does the arithmetic itself, because the two figures drifting apart is exactly the
    /// bug that makes a "swing" knob mean nothing.
    public var swingPercent: Double {
        get { swing.percent }
        set { setSwing(Swing(percent: newValue)) }
    }

    public static let straightPercent = Swing.minimumPercent
    public static let tripletPercent = Swing.tripletPercent
    public static let maximumPercent = Swing.maximumPercent

    public func setSwing(_ newSwing: Swing) {
        let before = snapshot
        swing = newSwing
        // No reload: the player picks the new options up on the next iteration it renders.
        edited(from: before)
    }

    public func setSwing(percent: Double) { setSwing(Swing(percent: percent)) }

    /// The lever's detents, the ones every machine marks.
    public func snapSwingToTriplet() { setSwing(.triplet) }
    public func snapSwingToStraight() { setSwing(.straight) }

    // MARK: The other levers

    /// How far a ghost note sits under a normal one, 0…1 of the normal velocity. The second
    /// prominent lever beside swing; everything else on this surface is a picker or a step.
    public var ghostLevel: Double {
        get { Double(velocities.ghost) / Double(max(1, velocities.normal)) }
        set { setGhostLevel(newValue) }
    }

    public func setGhostLevel(_ level: Double) {
        let clamped = min(1, max(0, level))
        let before = snapshot
        velocities = VelocityMap(ghost: Int((Double(velocities.normal) * clamped).rounded()),
                                 normal: velocities.normal,
                                 accent: velocities.accent)
        edited(from: before)
    }

    public func setVelocities(_ map: VelocityMap) {
        let before = snapshot
        velocities = map
        edited(from: before)
    }

    /// What the tempo lever runs over. This is the groove's audition tempo — what the loop plays at
    /// on this surface — not the song's, which the header sets.
    public static let tempoRange: ClosedRange<Double> = 20...300

    public func setTempo(_ bpm: Double) {
        tempo = max(Self.tempoRange.lowerBound, min(Self.tempoRange.upperBound, bpm))
        push()
        // Not an edit to the groove, but the Beatmaker reads in milliseconds, and a step is a
        // different number of them at another tempo.
        refreshReadings()
    }

    public func setHumanize(_ value: Humanize) {
        let before = snapshot
        humanize = value
        edited(from: before)
    }

    // MARK: Kit picker

    /// Switches machine and plays a kick, because a kit you cannot hear you have not chosen.
    public func setMachine(_ newMachine: SynthMachine) {
        machine = newMachine
        playsOnChop = false
        lastError = nil
        // What the grid plays on is what the song plays this groove on. The picker used to change
        // only the grid's own audition, so a groove built on the 909 played on the 808.
        host.machineChosen(newMachine, for: (versions.last ?? base)?.partID)
        Task { @MainActor [host, weak self] in
            do {
                try await host.loadMachine(newMachine)
                await host.audition(.kick, velocity: 110)
            } catch {
                self?.lastError = "\(error)"
            }
        }
    }

    // MARK: Feel picker

    /// Loads a feel: its pattern, its velocities, its swing, its pocket, its tempo — and its
    /// provenance, which stays on the surface so it can be shown and later cited.
    ///
    /// Outright, with no question first. A feel replaces the steps, the swing, the velocities and
    /// the tempo in one stroke, and that used to wait for a confirmation and leave a "put back"
    /// chip behind it. Both were ⌘Z by another name: the load is one edit like any other, so one
    /// undo puts back everything it replaced.
    public func load(_ feel: Feel) {
        let before = snapshot
        voices = feel.groove.patterns.map(\.voice)
        steps = Dictionary(uniqueKeysWithValues: feel.groove.patterns.map { ($0.voice, $0.steps) })
        stepsPerBar = max(1, feel.groove.stepsPerBar)
        bars = max(1, feel.groove.bars)
        swing = feel.swing
        velocities = feel.velocities
        humanize = feel.humanize
        voiceFeels = feel.voices
        timeSignature = feel.timeSignature
        tempo = feel.suggestedTempo
        feelName = feel.name
        provenance = feel.provenance
        edited(from: before)
    }

    /// Names the feel a bound groove was made in, without loading it: the steps are the groove's
    /// own. A groove re-grooved from a chop opened as "Grid" and "Choose a feel", while its title
    /// named the feel it was.
    public func recognise(_ version: PartVersion) {
        guard feelName == nil, let note = version.note,
              // The longest name that fits: "Boom-Bap Pocket" rather than "Boom-Bap".
              let feel = feelLibrary.feels.filter({ note.hasPrefix($0.name) }).max(by: { $0.name.count < $1.name.count })
        else { return }
        feelName = feel.name
        provenance = feel.provenance
    }

    /// Loads a feel by name from the library, outright. False when the library has no such feel.
    @discardableResult
    public func loadFeel(named name: String) -> Bool {
        guard let feel = feelLibrary.feel(named: name) else { return false }
        load(feel)
        return true
    }

    /// Puts a whole state back on screen. Undo and redo both come through here.
    private func apply(_ before: Snapshot) {
        voices = before.voices
        steps = before.steps
        stepsPerBar = before.stepsPerBar
        bars = before.bars
        swing = before.swing
        velocities = before.velocities
        humanize = before.humanize
        voiceFeels = before.voiceFeels
        timeSignature = before.timeSignature
        tempo = before.tempo
        feelName = before.feelName
        provenance = before.provenance
    }

    private var snapshot: Snapshot {
        Snapshot(voices: voices, steps: steps, stepsPerBar: stepsPerBar, bars: bars, swing: swing,
                 velocities: velocities, humanize: humanize, voiceFeels: voiceFeels,
                 timeSignature: timeSignature, tempo: tempo, feelName: feelName, provenance: provenance)
    }

    /// Feels worth offering at the grid's current tempo and meter, best first.
    public func suggestedFeels(limit: Int = 8) -> [Feel] {
        feelLibrary.suggest(for: tempo, timeSignature: timeSignature, limit: limit)
    }

    /// The one line a persona says when it cites the loaded feel.
    public var provenanceLine: String? {
        guard let provenance else { return nil }
        var line = provenance.summary
        if !provenance.lineage.isEmpty {
            line += " (" + provenance.lineage.joined(separator: ", ") + ")"
        }
        return line
    }

    // MARK: Versions

    /// Makes a new version of the groove. An edit never mutates the version it came from: this
    /// derives when the grid was opened against one and roots a new part when it was not.
    @discardableResult
    public func commit(note: String? = nil) -> PartVersion {
        // On the part's newest version, not the one this grid last saw: dust added in Sound since
        // is carried, not wiped. The grid owns the steps and the swing; the chain is Sound's.
        let known = versions.last ?? base
        let newest = known.flatMap { host.newest(of: $0.partID) } ?? known
        if case .groove(let current)? = newest?.kind { degradation = current.degradation }
        let payload = PartKind.groove(groove)
        let text = note ?? defaultNote
        let version: PartVersion
        if let previous = newest {
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user,
                                  operation: Operation.written, note: text)
        }
        autoKeep.cancel()
        // Synchronous, so a keep asked for by the frame — play, save, a song switch — is in the
        // song before the frame reads it.
        guard host.commit(version) else {
            lastError = "The song would not take that version."
            return version
        }
        versions.append(version)
        lastKept = version
        lastError = nil
        return version
    }

    /// The note a committed version carries: the feel it came from and where that feel came from,
    /// so the provenance survives into the graph rather than living only on screen.
    private var defaultNote: String {
        var parts: [String] = []
        if let feelName { parts.append(feelName) }
        parts.append(String(format: "%.0f bpm", tempo))
        parts.append(String(format: "swing %.4g%%", swing.percent))
        parts.append(playsOnChop ? "on \(kitName)" : machine.name)
        if let provenance {
            parts.append("from \(provenance.origin.rawValue): \(provenance.summary)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Engine

    /// Hands the engine the current pattern. Called after every edit; the player adopts it on the
    /// next iteration it renders, which is what "audible on the next pass" means.
    private func push() {
        let groove = self.groove
        let options = renderOptions
        let tempo = self.tempo
        let signature = timeSignature
        Task { [host] in
            await host.setPattern(groove, options: options, tempo: tempo, timeSignature: signature)
        }
    }

    /// Plays one voice at a velocity.
    private func play(_ voice: DrumVoice, velocity: Int) {
        Task { [host] in await host.audition(voice, velocity: velocity) }
    }

    /// Plays one voice at the brush's tier — the row header's audition button.
    public func audition(_ voice: DrumVoice) {
        play(voice, velocity: velocities[brush == .rest ? .normal : brush])
    }

    /// Pushes the current pattern without editing anything, for a host that has just come up.
    public func resend() { push() }

    // MARK: Keeping

    /// After every edit to the groove: remember the state before it for ⌘Z, hand the engine the
    /// new pattern, let the Beatmaker read it, and keep it once the edits settle.
    private func edited(from before: Snapshot) {
        history.record(before, now: snapshot)
        push()
        refreshReadings()
        guard hasUnkeptChanges else { autoKeep.cancel(); return }
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    // MARK: Reading

    /// The Beatmaker's reading of what is on screen. Assigned only when it changed, so a drag that
    /// does not move a reading does not redraw the panel under the grid.
    private func refreshReadings() {
        let next: [PersonaReading]
        if isPainted {
            let observation = GrooveObservation(label: title, groove: groove, options: renderOptions,
                                                tempo: tempo, timeSignature: timeSignature)
            // Flags first: what did not hold is what the Beatmaker would say first.
            let read = beatmaker.read(observation)
            next = read.filter { !$0.holds } + read.filter(\.holds)
        } else {
            next = []
        }
        if next != readings { readings = next }
    }
}

extension GridModel: KeepsAsItGoes {
    @discardableResult
    public func keepNow() -> Bool {
        guard hasUnkeptChanges else { autoKeep.cancel(); return true }
        let version = commit()
        return versions.last?.id == version.id
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let previous = history.undo(from: snapshot) else { return }
        apply(previous)
        push()
        refreshReadings()
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    public func redo() {
        guard let next = history.redo(from: snapshot) else { return }
        apply(next)
        push()
        refreshReadings()
        autoKeep.schedule { [weak self] in self?.keepNow() }
    }

    public var keepLine: KeepLine {
        if let lastError { return .refused(lastError) }
        if hasUnkeptChanges { return .pending }
        if let kept = versions.last ?? base { return .kept(title: PartLabel.title(of: kept)) }
        return .untouched
    }
}
