import AVFoundation
import Foundation
import Instrument
import Observation
import SongGraph

/// Which panel is in front. The surface is one thing at a time on purpose: the question is either
/// "what is this drum" or "how dusty is it", and asking both at once is the mixer strip the M1 spec
/// says not to build.
public enum SoundPanel: String, Hashable, Sendable, CaseIterable {
    case voice, chain

    public var title: String {
        switch self {
        case .voice: "Voice"
        case .chain: "Chain"
        }
    }
}

/// Which side of the A/B you are hearing.
public enum SoundMonitor: String, Hashable, Sendable, CaseIterable {
    /// Through the degradation chain.
    case chain
    /// True bypass: the synthesizer's own samples, untouched.
    case dry
}

/// What the surface is shaping.
///
/// A drum voice is the surface's first job: a `.sound` part, or a new one from a machine preset,
/// with the voice's knobs and a chain over it. The second is the one this app's first idiom turns
/// on — a clean chop made dusty — and there the surface binds to the chop (or a groove) itself and
/// is only the chain: the part is not a voice, so there are no voice knobs to show.
public enum SoundSubject: Hashable, Sendable {
    /// A drum voice: a `.sound` part, or nothing bound.
    case voice
    /// A sample or a groove being put through the chain. The payload is which.
    case part(PartType)

    public var isPart: Bool { if case .part = self { return true } else { return false } }
}

/// The Sound surface: four to six controls for the voice or the chain in front of you, every one of
/// which makes a sound the moment you move it.
///
/// ## The four rules
///
/// * **Binds to parts.** It opens against the host's selected part version and reads `SoundState`
///   out of it. The only state of its own is a *draft* of the edit in progress plus which panel and
///   which side of the A/B you are on — the things a reopen is allowed to forget.
/// * **Plays on touch.** `setValue` re-renders that one voice and auditions it. `DrumSynthesizer`
///   is a pure generator, so this is a few milliseconds of arithmetic and no engine round trip. It
///   never calls `SynthesizedKit.rerender`: re-rendering twelve voices at three velocity layers to
///   hear one knob would be absurd. Catching the kit folder up is the host's job, once, on commit.
/// * **Two speeds.** Everything here is local. The agent is not involved in turning a knob.
/// * **Flags, never fixes.** Nothing is corrected silently; a control that the machine does not
///   have simply is not shown, and one whose name lies about its wiring says so.
///
/// ## The A/B
///
/// `monitor` switches between the chain and true bypass. Bypass means the synthesizer's samples,
/// not the chain set to `.clean` — `rendered(.dry)` is bit-identical to `DrumSynthesizer.render`.
/// That matters because the degradation research's own finding was that an unmatched A/B is a
/// loudness contest: `CDegrade` normalises every saturation curve by its slope at the origin, so
/// `|y| <= |x|` at any drive and the chain can only compress. A true bypass is what makes that
/// audible rather than merely documented.
@MainActor
@Observable
public final class SoundSurface {

    // MARK: Identity

    public nonisolated let id: SurfaceID

    /// A value the frame can put in its bench and hold across isolation domains.
    public var binding: SoundSurfaceBinding {
        SoundSurfaceBinding(id: id, bound: boundVersion.map { [$0.id] } ?? [], title: title)
    }

    /// `"TR-808 kick"`, or `"TR-808 kick · vinyl"` once the chain is doing something.
    public var title: String {
        if subject.isPart {
            let passes = chainPasses
            return passes.isEmpty ? subjectName : "\(subjectName) · \(Dust.describe(passes))"
        }
        guard !draft.degrade.isBypass else { return draft.label }
        let chain = draft.degrade.matchingPreset?.rawValue ?? "chain"
        return "\(draft.label) · \(chain)"
    }

    /// What is being shaped, as the ledger calls it: `"TR-808 kick"`, or the chop's own name.
    public var subjectName: String {
        if subject.isPart, let boundVersion { return PartLabel.title(of: boundVersion) }
        return draft.label
    }

    // MARK: Host

    private weak var host: (any SoundSurfaceHost)?

    /// Render rate. The sampler's rate, so a commit does not resample what you auditioned.
    public let sampleRate: Double

    /// The velocity an audition is played at. One value, because an audition is a check on the
    /// voice, not a performance.
    public let auditionVelocity: Int

    // MARK: State

    /// The edit in progress. Seeded from the bound version and written back by `commit`; it is a
    /// draft, not state the surface owns, which is why `isDirty` is visible and `revert` exists.
    public private(set) var draft: SoundState

    /// The state as the bound version has it.
    public private(set) var committed: SoundState

    /// The version this surface opened against, if there was one.
    public private(set) var boundVersion: PartVersion?

    public var panel: SoundPanel = .voice

    /// Which side of the A/B. Setting it re-auditions, because that is the whole point of a
    /// comparison: one gesture, the same hit, the other side.
    public var monitor: SoundMonitor = .chain {
        didSet { if monitor != oldValue { audition() } }
    }

    /// The chain panel shows its two prominent levers and the presets; the remaining seven are
    /// behind this. A chain is nine parameters and a surface is four to six controls, so the rest
    /// of it is available rather than present.
    public var showsFullChain = false

    /// Set when a render could not be put through the chain — `DegradeChain` refused the rate or
    /// could not allocate. The dry signal is auditioned instead; nothing is corrected silently.
    public private(set) var chainFailure: String?

    public var isDirty: Bool { draft != committed }

    /// The version the last commit wrote, so the panel can say what a knob let go of became. Nil
    /// until something has been kept here.
    public private(set) var lastKept: PartVersion?
    /// How many versions this surface has written since it opened. The panel cannot number a
    /// version the way the ledger does — it has no song to count in — so it counts its own.
    public private(set) var keptCount = 0
    /// Set when the host refused the last commit, so the draft is still on the knobs and the panel
    /// says so rather than "no change". Cleared by the next commit that lands.
    public private(set) var lastCommitWasRefused = false

    // MARK: Dirtying a part

    /// A voice, or a sample or groove being put through the chain. Decided by what is bound.
    public private(set) var subject: SoundSubject = .voice

    /// The dry part's audio — the part with no chain on it at all — once the host has rendered it.
    /// Nil until then, and nil for a voice, which renders its own.
    public private(set) var dryPart: SoundAudition?

    /// Set when the host could not render the dry part. The panel says so; nothing plays.
    public private(set) var dryFailure: String?

    /// The bound version's passes *beneath* the one being edited. Empty for a dry part. When
    /// `stacksPass` is on this is every pass the version has, and the draft is a new one on top.
    public private(set) var beneath: [Degradation] = []

    /// Whether a commit puts the draft **on top of** the bound version's chain rather than replacing
    /// its top pass. Stacking is allowed — a second machine over the first is a real thing people
    /// do — and it is what `chainFindings` exists to flag.
    public private(set) var stacksPass = false

    /// The chain the part plays through as the draft stands: the passes beneath, then the draft's own
    /// unless it is bypass.
    public var chainPasses: [Degradation] {
        guard subject.isPart else { return [] }
        return draft.degrade.isBypass ? beneath : beneath + [draft.degrade.degradation(from: draft.chainBase)]
    }

    /// What the chain critic says about the draft's chain: a corner above the source's own rolloff,
    /// or a second quantiser over a prior one. Flagged here, before the commit, and never fixed.
    public var chainFindings: [Finding] {
        guard subject.isPart, !chainPasses.isEmpty else { return [] }
        let review = Dust.review(label: subjectName, passes: chainPasses,
                                 duration: dryPart?.durationSeconds ?? 0,
                                 sampleRate: dryPart?.sampleRate ?? 0)
        return DegradeStackCritic().review(review)
    }

    @ObservationIgnored private var dryLoad: Task<Void, Never>?

    // MARK: Init

    public init(id: SurfaceID = SurfaceID(),
                host: any SoundSurfaceHost,
                sampleRate: Double = 48_000,
                auditionVelocity: Int = 100) {
        self.id = id
        self.host = host
        self.sampleRate = sampleRate
        self.auditionVelocity = auditionVelocity
        let state = host.selectedPart.flatMap(SoundState.init) ?? Self.opening(on: host)
        self.draft = state
        self.committed = state
        self.boundVersion = host.selectedPart
        bindPart(host.selectedPart, lever: host.dustLever)
    }

    /// Re-reads the host's selection, discarding any draft. The frame calls this when the selection
    /// changes under the surface.
    public func reload() {
        let version = host?.selectedPart
        let state = version.flatMap(SoundState.init) ?? host.map(Self.opening(on:)) ?? SoundState()
        boundVersion = version
        recordedHit = nil
        draft = state
        committed = state
        chainFailure = nil
        bindPart(version, lever: nil)
    }

    /// What a surface opened on no drum voice opens on: the kick of the machine the song plays —
    /// or of the machine that was picked, when the pick is what is bound — as the song has kept it.
    /// With no song, the TR-808's. It used to be the 808's whatever the song played.
    private static func opening(on host: any SoundSurfaceHost) -> SoundState {
        var machine = host.songMachine
        if case .sound(let sound)? = host.selectedPart?.kind, SynthMachine.preset(id: sound.instrument) != nil {
            machine = sound.instrument
        }
        guard let machine, let preset = SynthMachine.preset(id: machine) else { return SoundState() }
        let voice = preset.voices.first { $0.kind == .kick }?.kind ?? preset.voices.first?.kind ?? .kick
        return host.keptVoice(voice, on: machine).flatMap(SoundState.init) ?? SoundState(machine: machine, voice: voice)
    }

    /// What the recording playing the voice in front of you is called, when one does. Then the
    /// voice has no circuits to turn: LEVEL is its only knob, and what plays on touch is the
    /// recording as the kit plays it.
    public var recordedAs: String? {
        guard !subject.isPart else { return nil }
        return host?.recording(of: draft.voice, on: draft.machine)
    }

    /// The recording's hit as the host's kit played it, and the LEVEL the kit was built at, so a
    /// turn of LEVEL is a gain on what was fetched rather than another kit on disk.
    @ObservationIgnored private var recordedHit: (machine: String, voice: SynthVoiceKind, level: Double, audition: SoundAudition)?
    @ObservationIgnored private var recordedLoad: Task<Void, Never>?

    /// Opens onto a sample or a groove, when that is what is bound: chain panel only, the draft at
    /// the part's top pass, and the dry part asked for from the host.
    private func bindPart(_ version: PartVersion?, lever: Double?) {
        dryLoad?.cancel()
        dryPart = nil
        dryFailure = nil
        stacksPass = false
        guard let version, version.kind.canCarryDegradation else {
            subject = .voice
            beneath = []
            return
        }
        subject = .part(version.type)
        panel = .chain
        rebase()
        if let lever {
            // The Director's lever means what the Compare's does: `Dust.lever`, as a draft to hear
            // and keep or not.
            draft.degrade = Dust.lever(lever)
            draft.chainBase = Dust.leverPreset
        }
        dryLoad = Task { [weak self] in await self?.loadDry(version) }
    }

    /// Draft and committed at the pass being edited: the top one, or a fresh one when stacking.
    private func rebase() {
        let passes = boundVersion?.kind.degradation ?? []
        let top = stacksPass ? nil : passes.last
        beneath = stacksPass ? passes : Array(passes.dropLast())
        let base = top?.preset.flatMap(DegradeSettings.Preset.init(rawValue:)) ?? .clean
        let state = SoundState(degrade: top.map(DegradeSettings.init) ?? .clean, chainBase: base)
        draft = state
        committed = state
    }

    private func loadDry(_ version: PartVersion) async {
        guard let host else { return }
        do {
            let audio = try await host.dryAudio(of: version)
            guard !Task.isCancelled, boundVersion?.id == version.id || boundVersion?.parents.contains(version.id) == true
            else { return }
            dryPart = audio
            dryFailure = nil
        } catch {
            guard !Task.isCancelled else { return }
            dryFailure = "\(error)"
        }
    }

    /// Waits for the dry part the binding asked for. Tests use this; so does anything that wants to
    /// render before the panel draws.
    public func waitForDry() async {
        await dryLoad?.value
    }

    /// Switches between editing the chain's top pass and stacking a new pass on top of it. Drops
    /// the draft either way: they are two different edits.
    public func setStacking(_ on: Bool) {
        guard subject.isPart, on != stacksPass else { return }
        stacksPass = on
        rebase()
        chainFailure = nil
    }

    // MARK: Controls

    /// The controls for the panel in front of you.
    public var controls: [SoundControl] { controls(for: panel) }

    public func controls(for panel: SoundPanel) -> [SoundControl] {
        switch panel {
        case .voice:
            if subject.isPart { [] }
            else if recordedAs != nil { SoundControl.recordedControls(for: draft.spec) }
            else { SoundControl.voiceControls(for: draft.spec) }
        case .chain: SoundControl.chainControls(for: draft.degrade)
        }
    }

    /// At most two. The M1 spec's rule, and the reason this is a surface and not a mixer strip.
    public var prominentControls: [SoundControl] { controls.filter(\.isProminent) }

    public var quietControls: [SoundControl] { controls.filter { !$0.isProminent } }

    /// Moves a control, re-renders that one voice, and plays it.
    ///
    /// Called from a slider's `onChange`, so it runs at gesture rate. That is affordable: a 1.6 s
    /// 808 kick at 48 kHz is about 77 000 samples of straight-line arithmetic.
    public func setValue(_ value: Double, for parameter: SoundControl.Parameter) {
        guard let control = controls(for: panel(of: parameter))
            .first(where: { $0.parameter == parameter }) else { return }
        let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
        guard apply(clamped, to: parameter) else { return }
        audition()
    }

    /// Applies a named parameter set to the chain and plays the result. The presets are read out of
    /// the C, so "sp1200" here means exactly what it means everywhere else.
    public func apply(_ preset: DegradeSettings.Preset) {
        draft.degrade = DegradeSettings(preset: preset)
        draft.chainBase = preset
        chainFailure = nil
        audition()
        // A machine picked is a choice, kept at once. It used to wait for a knob to be let go,
        // so clicking SP-1200 — or Clean, to go back — kept nothing.
        commit()
    }

    /// Switches voice within the same machine. The chain is unchanged — it is a chain, not part of
    /// the voice — and the new voice's own knob positions come from the machine preset.
    public func select(_ voice: SynthVoiceKind) {
        guard !subject.isPart, voice != draft.voice, draft.availableVoices.contains(voice) else { return }
        draft.voice = voice
        // As the song has kept it, when it has; the machine preset's otherwise.
        draft.controls = host?.keptVoice(voice, on: draft.machine).flatMap(SoundState.init)?.controls
            ?? SoundState.factorySpec(machine: draft.machine, voice: voice).controls
        panel = .voice
        audition()
    }

    /// Whether a control sits where the machine preset (or the chain's base preset) put it, so the
    /// panel can offer "back to the preset" only where there is somewhere to go back to.
    public func isAtPreset(_ parameter: SoundControl.Parameter) -> Bool {
        guard let current = controls(for: panel(of: parameter)).first(where: { $0.parameter == parameter })?.value
        else { return true }
        return abs(current - presetValue(of: parameter)) < 1e-9
    }

    private func presetValue(of parameter: SoundControl.Parameter) -> Double {
        switch parameter {
        case .machine(let knob): return value(of: knob, in: draft.factorySpec.controls)
        case .chain: return chainValue(of: parameter, in: DegradeSettings(preset: draft.chainBase)) ?? 0
        }
    }

    /// Puts one control back where the machine preset had it.
    public func reset(_ parameter: SoundControl.Parameter) {
        switch parameter {
        case .machine(let knob):
            let factory = draft.factorySpec.controls
            _ = apply(value(of: knob, in: factory), to: parameter)
        case .chain:
            let base = DegradeSettings(preset: draft.chainBase)
            _ = apply(chainValue(of: parameter, in: base) ?? 0, to: parameter)
        }
        audition()
    }

    /// Drops the draft and goes back to what the bound version says.
    public func revert() {
        draft = committed
        chainFailure = nil
    }

    /// The part being dirtied, on one side of the A/B, as planar channels at `dryPart`'s rate.
    ///
    /// `.dry` is the dry part exactly as the host rendered it — not even the passes beneath the one
    /// being edited — so the comparison is always against the clean chop. `.chain` is that through
    /// `chainPasses`, by `Dust.render`: the same call the transport and the audition service make.
    /// Empty until the dry part has arrived, and for a voice.
    public func renderedPart(_ monitor: SoundMonitor) -> [[Float]] {
        guard subject.isPart, let dry = dryPart else { return [] }
        let passes = chainPasses
        guard monitor == .chain, !passes.isEmpty else { return dry.planar }
        return (try? Dust.render(dry.planar, sampleRate: dry.sampleRate, passes: passes)) ?? dry.planar
    }

    // MARK: Rendering and audition

    /// Renders the current draft. Pure: the same draft and the same monitor always give the same
    /// samples, which is what makes an A/B a comparison rather than a coin toss.
    ///
    /// `.dry` is a true bypass — the synthesizer's own output, not the chain set to clean.
    public func rendered(_ monitor: SoundMonitor) -> [Float] {
        if subject.isPart { return renderedPart(monitor).first ?? [] }
        let dry = recordedDry()?.samples ?? DrumSynthesizer.render(draft.spec, velocity: auditionVelocity, sampleRate: sampleRate)
        guard monitor == .chain, !draft.degrade.isBypass else { return dry }
        do {
            return try Self.throughChain(dry, settings: draft.degrade, sampleRate: sampleRate)
        } catch {
            return dry
        }
    }

    /// Renders the current draft on the current side of the A/B and hands it to the host.
    public func audition() {
        if subject.isPart {
            auditionPart()
            return
        }
        if recordedAs != nil {
            auditionRecording()
            return
        }
        let dry = DrumSynthesizer.render(draft.spec, velocity: auditionVelocity, sampleRate: sampleRate)
        var samples = dry
        var isDry = true
        if monitor == .chain, !draft.degrade.isBypass {
            do {
                samples = try Self.throughChain(dry, settings: draft.degrade, sampleRate: sampleRate)
                isDry = false
                chainFailure = nil
            } catch {
                chainFailure = "\(error)"
            }
        } else {
            chainFailure = nil
        }
        host?.audition(SoundAudition(samples: samples, sampleRate: sampleRate,
                                     label: draft.label, isDry: isDry))
    }

    /// The recording in front of you at the draft's LEVEL, when it has been fetched for this voice.
    private func recordedDry() -> SoundAudition? {
        guard recordedAs != nil, let hit = recordedHit, hit.machine == draft.machine, hit.voice == draft.voice else { return nil }
        let gain = hit.level > 0 ? Float(draft.controls.level / hit.level) : 1
        var audition = hit.audition
        if gain != 1 { audition.planar = audition.planar.map { $0.map { $0 * gain } } }
        return audition
    }

    /// Plays the recording a voice is, through the chain when that is the side you are on. The
    /// first touch of a voice asks the host for the hit, which builds the kit if nobody has; every
    /// touch after is the same hit at the draft's LEVEL.
    private func auditionRecording() {
        guard let dry = recordedDry() else {
            let machine = draft.machine, voice = draft.voice
            // The kit the song plays, not one built for the draft: the host shapes the machine as
            // its song has, and that is the LEVEL the hit comes back at.
            let preset = draft.synthMachine
            let level = host?.keptVoice(voice, on: machine).flatMap(SoundState.init)?.controls.level
                ?? draft.factorySpec.controls.level
            recordedLoad?.cancel()
            recordedLoad = Task { [weak self] in
                guard let host = self?.host else { return }
                do {
                    let hit = try await host.kitHit(of: voice, on: preset)
                    guard let self, !Task.isCancelled, self.draft.machine == machine, self.draft.voice == voice else { return }
                    self.recordedHit = (machine, voice, level, hit)
                    self.chainFailure = nil
                    self.auditionRecording()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.chainFailure = "\(error)"
                }
            }
            return
        }
        var planar = dry.planar
        var isDry = true
        if monitor == .chain, !draft.degrade.isBypass {
            do {
                planar = try planar.map { try Self.throughChain($0, settings: draft.degrade, sampleRate: dry.sampleRate) }
                isDry = false
                chainFailure = nil
            } catch {
                chainFailure = "\(error)"
            }
        } else {
            chainFailure = nil
        }
        host?.audition(SoundAudition(planar: planar, sampleRate: dry.sampleRate, label: draft.label, isDry: isDry))
    }

    /// Waits for the recording a voice is to arrive from the host. Tests use this.
    public func waitForRecording() async {
        await recordedLoad?.value
    }

    private func auditionPart() {
        // Before the dry part arrives there is nothing to put through the chain, and the panel is
        // already saying so; a touch is not the place to say it again.
        guard let dry = dryPart else { return }
        var planar = dry.planar
        var isDry = true
        let passes = chainPasses
        if monitor == .chain, !passes.isEmpty {
            do {
                planar = try Dust.render(dry.planar, sampleRate: dry.sampleRate, passes: passes)
                isDry = false
                chainFailure = nil
            } catch {
                chainFailure = "\(error)"
            }
        } else {
            chainFailure = nil
        }
        host?.audition(SoundAudition(planar: planar, sampleRate: dry.sampleRate,
                                     label: title, isDry: isDry))
    }

    /// One offline pass through a fresh chain, latency-compensated, so sample *n* out is sample *n*
    /// in and the A/B does not slip by the wow delay line.
    static func throughChain(_ samples: [Float], settings: DegradeSettings,
                             sampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let input = source.floatChannelData else {
            throw DegradeChain.Failure.couldNotCreate(sampleRate: sampleRate, channelCount: 1)
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input[0].update(from: $0.baseAddress!, count: samples.count) }

        let processed = try DegradeChain.rendered(source, settings: settings)
        guard let output = processed.floatChannelData else { return samples }
        return Array(UnsafeBufferPointer(start: output[0], count: Int(processed.frameLength)))
    }

    // MARK: Commit

    /// Writes the draft back as a **new** part version and hands it to the host.
    ///
    /// Never mutates the version it opened against: an edit derives from it, keeping the same part
    /// and naming it as a parent. With nothing selected, this starts a part instead.
    ///
    /// - Returns: the version written, or `nil` when nothing moved or the host refused it.
    @discardableResult
    public func commit(note: String? = nil) -> PartVersion? {
        guard isDirty else { return nil }
        if subject.isPart { return commitPart(note: note) }
        let kind = PartKind.sound(draft.sound)
        // A voice is a part of its own: the next version of what the song has kept of it, or of
        // what is bound when that is this voice, and a new part otherwise. An edit of the snare
        // used to go on whatever was bound — the kick's part, or the pick of the machine itself.
        let bound = boundVersion.flatMap { version in
            SoundState(version).flatMap { $0.machine == draft.machine && $0.voice == draft.voice ? version : nil }
        }
        let parent = host?.keptVoice(draft.voice, on: draft.machine) ?? bound
        let version = parent?.deriving(kind, by: .user, operation: Operation.edit, note: note)
            ?? PartVersion(partID: PartID(), kind: kind, author: .user,
                           operation: Operation.written, note: note)
        guard host?.record(version) == true else {
            lastCommitWasRefused = true
            return nil
        }
        boundVersion = version
        committed = draft
        kept(version)
        return version
    }

    private func kept(_ version: PartVersion) {
        lastKept = version
        keptCount += 1
        lastCommitWasRefused = false
    }

    /// A dirtied part: a new version of the **same** part — the bound version as its parent,
    /// `Operation.degrade` as the operation — carrying `chainPasses`. The bound version is not
    /// touched, so the dry chop is one parent away and still plays clean. The seed goes in as the
    /// `UInt64` the draft holds; nothing here passes it through a `Double`.
    private func commitPart(note: String?) -> PartVersion? {
        // On the part's newest version: steps kept on the Grid since this surface opened stay kept.
        guard let opened = boundVersion else { return nil }
        let bound = host?.newest(of: opened.partID) ?? opened
        guard let version = Dust.version(dirtying: bound, through: chainPasses, by: .user, note: note)
        else { return nil }
        guard host?.record(version) == true else {
            lastCommitWasRefused = true
            return nil
        }
        boundVersion = version
        stacksPass = false
        let heard = draft
        rebase()
        // `rebase` rebuilds the state from the stored pass; the draft is what was heard, so keep it
        // exactly (it is equal, bar a preset name the pass could not name).
        draft = heard
        committed = heard
        kept(version)
        return version

    }

    // MARK: Applying a value

    private func panel(of parameter: SoundControl.Parameter) -> SoundPanel {
        if case .machine = parameter { return .voice }
        return .chain
    }

    /// - Returns: whether anything actually moved, so an audition is not fired for a no-op.
    private func apply(_ value: Double, to parameter: SoundControl.Parameter) -> Bool {
        let before = draft
        switch parameter {
        case .machine(let knob):
            switch knob {
            case .tune: draft.controls.tune = value
            case .decay: draft.controls.decay = value
            case .tone: draft.controls.tone = value
            case .snappy: draft.controls.snappy = value
            case .attack: draft.controls.attack = value
            case .level: draft.controls.level = value
            }
        case .chain(let knob):
            switch knob {
            case .bitDepth: draft.degrade.bitDepth = value
            case .sampleRate: draft.degrade.targetSampleRate = value
            case .drive:
                draft.degrade.drive = value
                // DRIVE with `saturation == .none` is a plain linear gain, and the A/B's whole
                // claim is that the chain never adds level. This surface does not offer a curve
                // control — the curve belongs to the preset — so pushing drive up on a chain that
                // has no curve gives it the soft clip to drive into, and backing off restores the
                // preset's own curve. Not silent: the DRIVE readout names the curve it is using.
                let curve = DegradeSettings(preset: draft.chainBase).saturation
                draft.degrade.saturation = value > 1 && curve == .none ? .soft : curve
            case .wow: draft.degrade.wowDepth = value
            case .flutter: draft.degrade.flutterDepth = value
            case .noise: draft.degrade.noiseLevel = value
            case .crackle: draft.degrade.crackleDensity = value
            case .highCut: draft.degrade.highCut = value
            case .mix: draft.degrade.mix = value
            }
        }
        return draft != before
    }

    private func value(of knob: SoundControl.MachineControl, in controls: SynthControls) -> Double {
        switch knob {
        case .tune: controls.tune
        case .decay: controls.decay
        case .tone: controls.tone
        case .snappy: controls.snappy
        case .attack: controls.attack
        case .level: controls.level
        }
    }

    private func chainValue(of parameter: SoundControl.Parameter,
                            in settings: DegradeSettings) -> Double? {
        guard case .chain(let knob) = parameter else { return nil }
        switch knob {
        case .bitDepth: return settings.bitDepth
        case .sampleRate: return settings.targetSampleRate
        case .drive: return settings.drive
        case .wow: return settings.wowDepth
        case .flutter: return settings.flutterDepth
        case .noise: return settings.noiseLevel
        case .crackle: return settings.crackleDensity
        case .highCut: return settings.highCut
        case .mix: return settings.mix
        }
    }
}

/// The catalog entry for an open Sound surface.
///
/// `Surface` is a `Sendable` value contract and `SoundSurface` is a `@MainActor` observable model,
/// so the conformance lives here rather than on the model: the frame holds one of these in its
/// bench, and the model is what the view talks to.
public struct SoundSurfaceBinding: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .sound }
    public let bound: [VersionID]
    public let title: String

    public init(id: SurfaceID, bound: [VersionID], title: String) {
        self.id = id
        self.bound = bound
        self.title = title
    }
}
