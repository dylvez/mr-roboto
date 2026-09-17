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

    // MARK: Collaborators

    private let host: any GridHosting
    private var paintMode: GridPaintMode?

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
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.machine = machine
        self.velocities = velocities
        self.humanize = humanize
        self.voiceFeels = voiceFeels
        self.feelLibrary = feelLibrary
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

    /// The pattern as the graph stores it. The round trip: `GridModel(groove: g).groove == g`.
    public var groove: Groove {
        Groove(stepsPerBar: stepsPerBar, bars: bars, swing: swing.factor,
               patterns: voices.map { GroovePattern(voice: $0, steps: steps[$0] ?? []) })
    }

    /// Everything the groove engine needs beyond the pattern.
    public var renderOptions: GrooveRenderOptions {
        GrooveRenderOptions(velocities: velocities, swing: swing, humanize: humanize, voices: voiceFeels)
    }

    // MARK: Editing steps

    /// Click: a rest becomes the brush tier, anything else becomes a rest. Auditions either way,
    /// because hearing what you just removed is how you know you removed the right one.
    public func toggle(_ voice: DrumVoice, step: Int) {
        let next: VelocityTier = tier(voice, step: step) == .rest ? brush : .rest
        set(next, voice: voice, step: step)
    }

    /// Repeated click on the same step walks the tiers: normal → accent → ghost → rest.
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
        guard var row = steps[voice], row.indices.contains(step) else { return }
        row[step] = tier
        steps[voice] = row
        if tier != .rest { play(voice, velocity: velocity(voice, step: step)) }
        push()
    }

    // MARK: Painting

    /// The first cell of a drag. Whether the drag paints or erases is decided here and held for the
    /// whole gesture.
    public func beginPaint(_ voice: DrumVoice, step: Int, tier: VelocityTier? = nil) {
        let brushTier = tier ?? brush
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

    public func endPaint() { paintMode = nil }

    /// Clears one voice's row.
    public func clear(_ voice: DrumVoice) {
        guard steps[voice] != nil else { return }
        steps[voice] = Array(repeating: .rest, count: stepCount)
        push()
    }

    public func clearAll() {
        for voice in voices { steps[voice] = Array(repeating: .rest, count: stepCount) }
        push()
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
        swing = newSwing
        // No reload: the player picks the new options up on the next iteration it renders.
        push()
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
        velocities = VelocityMap(ghost: Int((Double(velocities.normal) * clamped).rounded()),
                                 normal: velocities.normal,
                                 accent: velocities.accent)
        push()
    }

    public func setVelocities(_ map: VelocityMap) {
        velocities = map
        push()
    }

    public func setTempo(_ bpm: Double) {
        tempo = max(20, min(300, bpm))
        push()
    }

    public func setHumanize(_ value: Humanize) {
        humanize = value
        push()
    }

    // MARK: Kit picker

    /// Switches machine and plays a kick, because a kit you cannot hear you have not chosen.
    public func setMachine(_ newMachine: SynthMachine) {
        machine = newMachine
        lastError = nil
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
    public func load(_ feel: Feel) {
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
        push()
    }

    /// Loads a feel by name from the library.
    @discardableResult
    public func loadFeel(named name: String) -> Bool {
        guard let feel = feelLibrary.feel(named: name) else { return false }
        load(feel)
        return true
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
        let payload = PartKind.groove(groove)
        let text = note ?? defaultNote
        let version: PartVersion
        if let previous = versions.last ?? base {
            version = previous.deriving(payload, by: .user, operation: Operation.edit, note: text)
        } else {
            version = PartVersion(partID: PartID(), kind: payload, author: .user,
                                  operation: Operation.written, note: text)
        }
        versions.append(version)
        Task { [host] in await host.commit(version) }
        return version
    }

    /// The note a committed version carries: the feel it came from and where that feel came from,
    /// so the provenance survives into the graph rather than living only on screen.
    private var defaultNote: String {
        var parts: [String] = []
        if let feelName { parts.append(feelName) }
        parts.append(String(format: "%.0f bpm", tempo))
        parts.append(String(format: "swing %.4g%%", swing.percent))
        parts.append(machine.name)
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
}
